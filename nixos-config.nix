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
      needsRoot = action != "dry-activate";
      cmd = { pkgs, lib, config, node, ... }:
        pkgs.writeScript "nixos-${action}-${node}" ''
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

    build = {
      host = "build";
      phases = phases: with phases;
        [ instantiate upload build execAction ];
      cmd = { pkgs, lib, config, node, ... }:
        pkgs.writeScript "nixos-build-${node}" ''
          #!${pkgs.bash}/bin/bash
          echo "${config.system.build.toplevel}"
        '';
    };

    diff = {
      phases = phases: with phases; let
          diff_phase = args: with args; ''
            echo "Downloading current system derivation..." >&2
            current_sys="$(${target_host_prefix} readlink -f /run/current-system)"
            current_sys_drv="$(${target_host_prefix} nix-store -q --deriver $current_sys)"

            if [ -f "$current_sys_drv" ]; then
              :
            elif ${target_host_prefix} [ -f "$current_sys_drv" ]; then
              ${copy_helper target_host null ''"$current_sys_drv"''}
            elif ${build_host_prefix} [ -f "$current_sys_drv" ]; then
              ${copy_helper build_host null ''"$current_sys_drv"''}
            else
              echo "Could not find the derivation $current_sys_drv on any host. Aborting."
              exit 1
            fi

            sys_drv=''${system_drvs["${node}"]}
            echo "nix-diff $current_sys_drv $sys_drv"
            ${pkgs.nix-diff}/bin/nix-diff $current_sys_drv $sys_drv
          '';
        in [ instantiate_sys diff_phase ];
      cmd = { pkgs, lib, config, node, ... }: config.system.build.toplevel;
    };

    gc = {
      forceFast = true;
      needsRoot = true;
      cmd = { pkgs, lib, config, node, ... }:
        pkgs.writeScript "nixos-gc-${node}" ''
          #!${pkgs.bash}/bin/bash
          ${pkgs.nix}/bin/nix-collect-garbage -d
        '';
    };

    version = {
      forceFast = true;
      cmd = { pkgs, lib, config, node, ... }:
        pkgs.writeScript "nixos-version-${node}" ''
          #!${pkgs.bash}/bin/bash
          source /etc/os-release
          echo "${node}: $PRETTY_NAME"
        '';
    };

    build-image.host = "provision";
    build-image.needsRoot = true;
    build-image.cmd = { pkgs, lib, config, node, ... }: let
        image = import "${config.deployment.internal.nixosPath}/lib/make-disk-image.nix"
                  ({ inherit pkgs lib config; } // config.deployment.imageOptions);
        imgPath = config.deployment.imagePath;
      in pkgs.writeScript "nixos-image-${node}" ''
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
    install.cmd = { pkgs, lib, config, node, ... }: let
        nixos-install = (import "${config.deployment.internal.nixosPath}/modules/installer/tools/tools.nix" {
          inherit pkgs lib config; modulesPath = null;
        }).config.system.build.nixos-install;
      in pkgs.writeScript "nixos-install-${node}" ''
        #!${pkgs.bash}/bin/bash
        ${nixos-install}/bin/nixos-install --closure ${config.system.build.toplevel} "$@"
      '';
  };


  phases = let
    instantiate = nix: args: with args; let
        arr = if nix then "nix_drvs" else "system_drvs";
        expr = if nix
            then "$BASE_CONFIG_EXPR.nodes.${node}.nix.package"
            else ''$BASE_CONFIG_EXPR.deployCommand \"${node}\" \"${action.name}\"'';
      in ''
        echo "Instantiating ${if nix then "nix" else "system"}..." >&2
        declare -A ${arr}

        root="$tmpDir/inst-${if nix then "nix" else "system"}"
        drv="$(nix-instantiate --expr "${expr}" --indirect --add-root "$root" "${"$"}{extraInstantiateFlags[@]}")"
        drv="$(readlink -f "$drv")"
        if [ -z "$drv" ]; then
          echo "nix-instantiate failed for node ${node}" >&2
          exit 1
        fi
        ${arr}["${node}"]="$drv"
      '';

    upload = nix: args: with args; ''
      echo "Uploading ${if nix then "nix" else "system"}..." >&2
      drv=''${${if nix then "nix_drvs" else "system_drvs"}["${node}"]}
      ${copy_helper null build_host ''"$drv"''}
    '';

    build = nix: args: with args; let
        path_prefix =
          lib.optionalString (!nix && !fast)
              ''PATH="''${remotePaths["${node}"]}"'';
      in ''
        echo "Building ${if nix then "nix" else "system"}..." >&2
        drv=''${${if nix then "nix_drvs" else "system_drvs"}["${node}"]}
        ${build_host_prefix} ${path_prefix} nix-store -r "$drv" "''${extraBuildFlags[@]}" \
            2>&1 > /dev/null | ( grep -v -- "--add-root" || true )
        ${if nix then ''
          outPath="$(nix-store -q --outputs "$drv" | tail -1)"
          remotePath="$outPath/bin"
          declare -A remotePaths
          remotePaths["${node}"]="$remotePath"
        '' else ''
          cmd="$(nix-store -q --outputs "$drv" | tail -1)"
          declare -A cmds
          cmds["${node}"]="$cmd"
        ''}
      '';

    copy = args: with args; ''
      echo "Copying..." >&2
      cmd=''${cmds["${node}"]}
      ${copy_helper build_host target_host ''"$cmd"''}
    '';

    execAction = args: with args; ''
      echo "Deploying..." >&2
      cmd=''${cmds["${node}"]}
      ${if target_host == null then ''
        ${lib.optionalString (action.needsRoot or false) "sudo "}"$cmd"
      '' else if build_host == null || build_host == target_host then ''
        ssh $NIX_SSHOPTS "${target_host}" "$cmd"
      '' else ''
        ssh $NIX_SSHOPTS "${build_host}" ssh "${target_host}" "$cmd"
      ''}
    '';


    copy_helper = from: to: drv:
      if from == to then ''
        :
      '' else if from == null then ''
        nix-copy-closure --to "${to}" ${drv}
      '' else if to == null then ''
        sudo nix-copy-closure --from "${from}" ${drv}
      '' else ''
        ssh $NIX_SSHOPTS "${from}" nix-copy-closure --to "${to}" ${drv}
      '';

    unless_fast = phase: args:
      local_lib.optionalString (!args.fast) (phase args);

    if_build_host = phase: args:
      local_lib.optionalString (args.build_host != null) (phase args);

    sequence = phases: args:
      local_lib.concatMapStringsSep "\n" (p: p args) phases;

    sys_and_nix = phase: sequence [
      (unless_fast (phase true))
      (phase false)
    ];

    in {
      inherit unless_fast if_build_host sequence sys_and_nix copy_helper;

      instantiate = sys_and_nix instantiate;
      instantiate_nix = unless_fast (instantiate true);
      instantiate_sys = instantiate false;
      build = sys_and_nix build;
      build_nix = unless_fast (build true);
      build_sys = build false;
      upload = if_build_host (sys_and_nix upload);
      upload_nix = if_build_host (unless_fast (upload true));
      upload_sys = if_build_host (upload false);
      inherit copy execAction;
    };

  nixosDeploy = node: action: fast: let
      default_phases = phases: with phases;
          [ instantiate upload build copy execAction ];
      action_phases = action.phases or default_phases;
      combined_phases = phases.sequence (action_phases phases);

      args = rec {
        inherit node fast action;
        config = nodesBuilt.${node};
        pkgs = config._module.args.pkgs;
        lib = pkgs.lib;
        build_host = config.deployment.buildHost;
        build_host_prefix =
          lib.optionalString (build_host != null)
              ''ssh $NIX_SSHOPTS "${build_host}"'';
        target_host = if (action.host or "target") == "target"
            then config.deployment.targetHost
          else if action.host == "provision"
            then config.deployment.provisionHost
            else config.deployment.buildHost;
        target_host_prefix =
          lib.optionalString (target_host != null)
              ''ssh $NIX_SSHOPTS "${target_host}"'';
      };
    in ''
      export NIX_SSHOPTS="${args.config.deployment.ssh_options}"
      NIX_SSHOPTS="$NIX_SSHOPTS $SSH_MULTIPLEXING"
      ${combined_phases args}
    '';




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

  hosts_list = builtins.toJSON (["all"] ++ builtins.attrNames nodesBuilt);
  commands_list = builtins.toJSON (builtins.attrNames deployCommands);

  stage1 = action: hosts_json: fast: let
      nodes = builtins.fromJSON hosts_json;
      nodes_filtered = if nodes == []
        then local_lib.filter
          (node: nodesBuilt.${node}.deployment.includeInAll)
          (builtins.attrNames nodesBuilt)
        else nodes;


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


        ${(local_lib.concatMapStringsSep "\necho\n" (node: ''
          echo "Deploying ${node}..."
          ${nixosDeploy node
              (deployCommands.${action} // {name=action;})
              (fast || deployCommands.${action}.forceFast or false)}
        '') nodes_filtered)}


        if [ -n "$sshMultiplexing" ]; then
          for ctrl in "$tmpDir"/ssh/ssh-*; do
              ssh -o ControlPath="$ctrl" -O exit dummyhost 2>/dev/null || true
          done
        fi
        rm -rf "$tmpDir"
      '';


  deployCommand = node: action:
    deployCommands.${action}.cmd rec {
      inherit node;
      config = nodesBuilt.${node};
      pkgs = config._module.args.pkgs;
      lib = pkgs.lib;
    };

}

