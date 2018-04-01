hostsFile:

let
  local_pkgs = (import <nixos> {});
  local_lib = local_pkgs.lib;

  deploymentConf = { name, nodes, config, pkgs, lib, ... }: {
    options = {
      deployment.buildHost = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        description = ''
          This option specifies the hostname or IP address of the host to build on.
          If null, uses local machine; otherwise, local machine needs to be able to ssh into buildHost.
          By default builds on targetHost.
        '';
      };

      deployment.ssh_options = lib.mkOption {
        type = lib.types.str;
        default = "-A";
        description = ''
          ssh options to use to connect to buildHost.
        '';
      };

      deployment.targetHost = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        description = ''
          This option specifies the hostname or IP address of the host to deploy to.
          If null, targets local machine; otherwise, buildHost needs to be able to ssh into targetHost.
        '';
      };

      deployment.provisionHost = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = ''
          This option specifies the hostname or IP address of the host that can provision the current node (e.g. the host running the VM).
          If null, targets local machine; otherwise, buildHost needs to be able to ssh into provisionHost.
        '';
      };

      deployment.imageOptions = lib.mkOption {
        type = lib.types.attrsOf lib.types.unspecified;
        default = {
          name = "nixos-${name}-disk-image";
          format = "qcow2";
          diskSize = "15000";
        };
      };

      deployment.imagePath = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = "/var/lib/libvirt/images/${name}.qcow2";
      };

      deployment.includeInAll = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Whether to deploy this host when deploying all hosts.
        '';
      };

      deployment.internal = lib.mkOption {
        type = lib.types.attrsOf lib.types.unspecified;
        internal = true;
        default = {};
      };
    };

    config = {
      deployment.buildHost = lib.mkDefault config.deployment.targetHost;
    };
  };


  deployCommands = let
    activate = action: {
      host = "target";
      needsRoot = action != "dry-activate";

      cmd = { pkgs, lib, config, name, ... }:
        pkgs.writeScript "nixos-${action}-${name}" ''
          #!${pkgs.bash}/bin/bash
          pathToConfig="${config.system.build.toplevel}"

          echo "Activating configuration..."
          ${lib.optionalString (action == "switch" || action == "boot") ''
            nix-env -p /nix/var/nix/profiles/system --set "$pathToConfig"
          ''}
          "$pathToConfig/bin/switch-to-configuration" "${action}"
        '';
    };

  in {
    switch = activate "switch";
    boot = activate "boot";
    test = activate "test";
    dry-activate = activate "dry-activate";

    build-image.host = "provision";
    build-image.needsRoot = true;
    build-image.cmd = { pkgs, lib, config, name, ... }: let
        image = import "${config.deployment.internal.nixosPath}/lib/make-disk-image.nix"
                  ({ inherit pkgs lib config; } // config.deployment.imageOptions);
        imgPath = config.deployment.imagePath;
      in pkgs.writeScript "nixos-image-${name}" ''
        #!${pkgs.bash}/bin/bash
        ${if imgPath == null
        then "echo ${image}"
        else ''
          if [ ! -f "${imgPath}" ]; then
            cp "${image}/nixos.qcow2" "${imgPath}"
            chmod 640 "${imgPath}"
            echo "Image has been copied to ${imgPath}"
          else
            echo "File ${imgPath} already exists ! Aborting."
            exit 1
          fi
        ''}
      '';

    install.host = "provision";
    install.needsRoot = true;
    install.cmd = { pkgs, lib, config, name, ... }: let
        nixos-install = (import "${config.deployment.internal.nixosPath}/modules/installer/tools/tools.nix" {
          inherit pkgs lib config; modulesPath = null;
        }).config.system.build.nixos-install;
      in pkgs.writeScript "nixos-install-${name}" ''
        #!${pkgs.bash}/bin/bash
        ${nixos-install}/bin/nixos-install --closure ${config.system.build.toplevel} "$@"
      '';
  };


  overrideNixosConf = { name, config, pkgs, lib, ... }: {
    options = {
      overrideNixosPath = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
        description = ''
          This option specifies the path to be used to build the nixos configuration.
        '';
      };
    };
  };

  buildNixOSSystem = configuration:
    let impureLightConfig = (import <nixos/nixos/lib/eval-config.nix> {
          baseModules = [];
          modules = [ configuration ];
          check = false;
        }).config;
        nixosPath = if impureLightConfig.overrideNixosPath != null
          then "${impureLightConfig.overrideNixosPath}/nixos"
          else <nixos/nixos>;
    in (import nixosPath { configuration = {
          imports = [ configuration ];
          deployment.internal.nixosPath = nixosPath;
        }; }).config;


  nodes = import hostsFile;

  nodesBuilt = local_lib.mapAttrs (host: conf: buildNixOSSystem {
    imports = [
      deploymentConf
      overrideNixosConf
      conf
    ];
    _module.args = {
      nodes = nodesBuilt;
      name = host;
    };
  }) nodes;

in

rec {
  nodes = nodesBuilt;

  stage1 = action: hosts_json: fast: let
      nodes = builtins.fromJSON hosts_json;
      nodes_filtered = if nodes == []
        then local_lib.filter
          (node: nodesBuilt.${node}.deployment.includeInAll)
          (builtins.attrNames nodesBuilt)
        else nodes;

      instanciate_to_array = expr: ''
        declare -A drvs

        ${(local_lib.concatMapStringsSep "\n" (node: ''
          drv="$(nix-instantiate --expr "${expr node}" "${"$"}{extraInstantiateFlags[@]}")"
          if [ -z "$drv" ]; then
              echo "nix-instantiate failed for node ${node}" >&2
              exit 1
          fi
          drvs["${node}"]="$drv"
        '') nodes_filtered)}

        declare -p drvs
      '';

    in if !deployCommands?${action}
      then local_pkgs.writeScript "unknown-action" ''
          #!${local_pkgs.bash}/bin/bash
          echo "Error: unknown action '${action}'"
          exit 1
        ''
      else local_pkgs.writeScript "nixos-deploy-stage1" ''
        #!${local_pkgs.bash}/bin/bash
        set -e
        export tmpDir=$(mktemp -t -d nixos-deploy.XXXXXX)
        export extraInstantiateFlags extraBuildFlags sshMultiplexing
        export BASE_CONFIG_EXPR

        if [ -n "$sshMultiplexing" ]; then
            mkdir -p $tmpDir/ssh
            SSH_MULTIPLEXING="-o ControlMaster=auto -o ControlPath=$tmpDir/ssh/ssh-%n -o ControlPersist=60"
            export SSH_MULTIPLEXING
        fi


        echo "Instantiating..."
        ${local_lib.optionalString (!fast) ''
          nix_drvs="$(${instanciate_to_array
              (node: "$BASE_CONFIG_EXPR.nodes.${node}.nix.package")})"
          export nix_drvs
        ''}
        system_drvs="$(${instanciate_to_array
            (node: ''$BASE_CONFIG_EXPR.deployCommand \"${node}\" \"${action}\"'')})"
        export system_drvs
        echo

        echo "Uploading derivations..."
        ${(local_lib.concatMapStringsSep "\necho\n" (node:
            uploadScript node fast)
        nodes_filtered)}
        echo

        ${(local_lib.concatMapStringsSep "\necho\n" (node: ''
          echo "Building ${node}..."
          cmd="$(${buildScript node action fast})"

          echo "Copying ${node}..."
          ${copyScript node deployCommands.${action}} "$cmd"

          echo "Deploying ${node}..."
          ${deployScript node deployCommands.${action}} "$cmd"
        '') nodes_filtered)}


        if [ -n "$sshMultiplexing" ]; then
          for ctrl in "$tmpDir"/ssh/ssh-*; do
              ssh -o ControlPath="$ctrl" -O exit dummyhost 2>/dev/null || true
          done
        fi
        rm -rf "$tmpDir"
      '';

  uploadScript = name: fast: let
      config = nodesBuilt.${name};
      pkgs = config._module.args.pkgs;
      lib = pkgs.lib;

      build_host = config.deployment.buildHost;

    in if build_host != null then
        pkgs.writeScript "nixos-deploy-upload-${name}" ''
      #!${pkgs.bash}/bin/bash
      set -e
      export NIX_SSHOPTS="${config.deployment.ssh_options}"
      NIX_SSHOPTS="$NIX_SSHOPTS $SSH_MULTIPLEXING"

      ${lib.optionalString (!fast) ''
        eval "$nix_drvs"
        nix-copy-closure --to "${build_host}" "''${drvs["${name}"]}" \
          2>&1 | head -1
      ''}

      eval "$system_drvs"
      nix-copy-closure --to "${build_host}" "''${drvs["${name}"]}" \
        2>&1 | head -1
    '' else "";

  buildToBuildHost = node: fast: building_nix: let
      config = nodesBuilt.${node};
      pkgs = config._module.args.pkgs;
      lib = pkgs.lib;

      build_host = config.deployment.buildHost;
      build_host_prefix =
        lib.optionalString (build_host != null)
            ''ssh $NIX_SSHOPTS "${build_host}"'';
      path_prefix =
        lib.optionalString (!building_nix && !fast)
            ''PATH="$remotePath"'';

    in pkgs.writeScript "nixos-deploy-remote-build-${node}" ''
      #!${pkgs.bash}/bin/bash
      set -e
      export NIX_SSHOPTS="${config.deployment.ssh_options}"
      NIX_SSHOPTS="$NIX_SSHOPTS $SSH_MULTIPLEXING"
      drv="$1"

      ${build_host_prefix} ${path_prefix} nix-store -r "$drv" "''${extraBuildFlags[@]}" > /dev/null

      # Get only the main path
      nix-store -q --outputs "$drv" | tail -1
  '';

  buildScript = name: action: fast: let
      config = nodesBuilt.${name};
      pkgs = config._module.args.pkgs;
      lib = pkgs.lib;

      build_host = config.deployment.buildHost;


    in pkgs.writeScript "nixos-deploy-build-${name}" ''
      #!${pkgs.bash}/bin/bash
      set -e

      ${lib.optionalString (!fast) ''
        echo "Building Nix..." >&2
        eval "$nix_drvs"
        drv=''${drvs["${name}"]}
        outPath="$(${buildToBuildHost name fast true} "$drv")"
        remotePath="$outPath/bin"
        export remotePath
      ''}

      echo "Building system..." >&2
      eval "$system_drvs"
      drv=''${drvs["${name}"]}
      ${buildToBuildHost name fast false} "$drv"
    '';

  copyScript = name: cmd: let
      config = nodesBuilt.${name};
      pkgs = config._module.args.pkgs;
      lib = pkgs.lib;

      build_host = config.deployment.buildHost;
      target_host = if cmd.host == "target"
          then config.deployment.targetHost
          else config.deployment.provisionHost;

    in pkgs.writeScript "nixos-deploy-copy-${name}" ''
      set -e
      export NIX_SSHOPTS="${config.deployment.ssh_options}"
      NIX_SSHOPTS="$NIX_SSHOPTS $SSH_MULTIPLEXING"
      cmd="$1"

      ${if target_host == null && build_host == null then ''
      '' else if target_host == null then ''
        sudo nix-copy-closure --from "${build_host}" "$cmd"
      '' else if build_host == null then ''
        nix-copy-closure --to "${target_host}" "$cmd"
      '' else if build_host == target_host then ''
      '' else ''
        ssh $NIX_SSHOPTS "${build_host}" nix-copy-closure --to "${target_host}" "$cmd"
      ''}
    '';

  deployScript = name: cmd: let
      config = nodesBuilt.${name};
      pkgs = config._module.args.pkgs;
      lib = pkgs.lib;

      build_host = config.deployment.buildHost;
      target_host = if cmd.host == "target"
          then config.deployment.targetHost
          else config.deployment.provisionHost;

    in pkgs.writeScript "nixos-deploy-deploy-${name}" ''
      set -e
      export NIX_SSHOPTS="${config.deployment.ssh_options}"
      NIX_SSHOPTS="$NIX_SSHOPTS $SSH_MULTIPLEXING"
      cmd="$1"

      ${if target_host == null && build_host == null then ''
        ${lib.optionalString cmd.needsRoot "sudo "}"$cmd"
      '' else if target_host == null then ''
        ${lib.optionalString cmd.needsRoot "sudo "}"$cmd"
      '' else if build_host == null then ''
        ssh "${target_host}" "$cmd"
      '' else if build_host == target_host then ''
        ssh $NIX_SSHOPTS "${build_host}" "$cmd"
      '' else ''
        ssh $NIX_SSHOPTS "${build_host}" ssh "${target_host}" "$cmd"
      ''}
    '';

  deployCommand = name: action:
    deployCommands.${action}.cmd rec {
      inherit name;
      config = nodesBuilt.${name};
      pkgs = config._module.args.pkgs;
      lib = pkgs.lib;
    };

}

