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
    activate = action: { pkgs, lib, config, name, ... }: let
        cfg = config.system.build.toplevel;
      in pkgs.writeScript "nixos-${action}-${name}" ''
        #!${pkgs.bash}/bin/bash
        action="${action}"
        pathToConfig="${cfg}"

        echo "Activating configuration..."
        if [ "$action" = switch -o "$action" = boot ]; then
            nix-env -p /nix/var/nix/profiles/system --set "$pathToConfig"
        fi
        "$pathToConfig/bin/switch-to-configuration" "$action"
      '';

  in {
    switch = activate "switch";
    boot = activate "boot";
    test = activate "test";
    dry-activate = activate "dry-activate";

    build-image = { pkgs, lib, config, name, ... }: let
        image = import "${config.deployment.internal.nixosPath}/lib/make-disk-image.nix" ({
          inherit pkgs lib config;
        } // config.deployment.imageOptions);
      in pkgs.writeScript "nixos-image-${name}" ''
        #!${pkgs.bash}/bin/bash
        ${if config.deployment.imagePath == null
        then "echo ${image}"
        else ''
          if [ ! -f "${config.deployment.imagePath}" ]; then
            cp "${image}/nixos.qcow2" "${config.deployment.imagePath}"
            chmod 640 "${config.deployment.imagePath}"
            echo "Image has been copied to ${config.deployment.imagePath}"
          else
            echo "File ${config.deployment.imagePath} already exists ! Aborting."
            exit 1
          fi
        ''}
      '';

    install = { pkgs, lib, config, name, ... }: let
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

    in if !deployCommands?${action}
      then local_pkgs.writeScript "unknown-action" ''
          #!${local_pkgs.bash}/bin/bash
          echo "Error: unknown action '${action}'"
          exit 1
        ''
      else local_pkgs.writeScript "nixos-deploy-stage1" ''
        #!${local_pkgs.bash}/bin/bash
        export extraInstantiateFlags extraBuildFlags sshMultiplexing
        export BASE_CONFIG_EXPR

        ${(local_lib.concatMapStringsSep "\necho\n" (node: ''
          echo "Deploying ${node}..."
          export CONFIG_EXPR="$BASE_CONFIG_EXPR.nodes.${node}"
          ${stage1_script node action fast}
        '') nodes_filtered)}
      '';

  stage1_script = name: action: fast: let
      config = nodesBuilt.${name};
      pkgs = config._module.args.pkgs;
      lib = config._module.args.pkgs.lib;

      build_host = config.deployment.buildHost;
      target_host = config.deployment.targetHost;
      provision_host = config.deployment.provisionHost;

      default = d: x: if x == null then d else x;

      remote_build = expr: let
          run_on_build_host = force_deft_path: cmd:
            if build_host == null then
              cmd
            else if fast || force_deft_path then
              ''ssh $NIX_SSHOPTS "${build_host}" ${cmd}''
            else
              ''ssh $NIX_SSHOPTS "${build_host}" PATH="$remotePath" ${cmd}'';

        in pkgs.writeScript "remote-build-${name}" ''
          #!${pkgs.bash}/bin/bash
          export NIX_SSHOPTS
          set -e

          drv="$(nix-instantiate --expr "${expr}" "${"$"}{extraInstantiateFlags[@]}")"
          if [ -a "$drv" ]; then
              ${lib.optionalString (build_host != null)
                ''nix-copy-closure --to "${build_host}" "$drv"''
              }
              outPaths=($(${run_on_build_host true ''nix-store -r "$drv" "${"$"}{extraBuildFlags[@]}"''}))

              echo "${"$"}{outPaths[@]}"
          else
              echo "nix-instantiate failed" >&2
              exit 1
          fi
      '';

      run_on = host: cmd: ''
        ${if host == null then "sudo" else "ssh $NIX_SSHOPTS \"${host}\""} ${cmd}
      '';

    in pkgs.writeScript "nixos-deploy-${name}" ''
      #!${pkgs.bash}/bin/bash
      set -e
      export NIX_SSHOPTS="${config.deployment.ssh_options}"

      if [ -n "$sshMultiplexing" ]; then
          tmpDir=$(mktemp -t -d nixos-deploy.XXXXXX)
          # TODO: split SSHOPTS into build/target ssh opts
          NIX_SSHOPTS="$NIX_SSHOPTS -o ControlMaster=auto -o ControlPath=$tmpDir/ssh-%n -o ControlPersist=60"

          cleanup() {
              for ctrl in "$tmpDir"/ssh-*; do
                  ssh -o ControlPath="$ctrl" -O exit dummyhost 2>/dev/null || true
              done
              rm -rf "$tmpDir"
          }
          trap cleanup EXIT
      fi


      ${if fast == false then ''
        echo "Building Nix..."
        outPaths=($(${remote_build "$CONFIG_EXPR.nix.package.out"}))
        remotePath=
        for p in "${"$"}{outPaths[@]}"; do
            remotePath="$p/bin:$remotePath"
        done
      '' else ""}

      echo "Building system..."
      ${let host = if action == "build-image" || action == "install"
          then provision_host else target_host;
      in if host == null then ''
        script="$(${remote_build "$BASE_CONFIG_EXPR.stage3 \\\"${name}\\\" \\\"${action}\\\""})"
        ${lib.optionalString (build_host != null) ''nix-copy-closure --from "${build_host}" "$script"''}
        sudo $script
      '' else ''
        script="$(${remote_build "$BASE_CONFIG_EXPR.stage2 \\\"${build_host}\\\" \\\"${name}\\\" \\\"${host}\\\" \\\"${action}\\\""})"
        ${run_on build_host ''"$script"''}
      ''}
    '';


  stage2 = current_host: target_node: target_host: action:
    local_pkgs.writeScript "nixos-${target_node}-stage2"''
      #!${local_pkgs.bash}/bin/bash
      drv="${stage3 target_node action}"
      ${if target_host != current_host then ''
        nix-copy-closure --to "${target_host}" "$drv"
        ssh "${target_host}" "$drv"
      '' else ''
        $drv
      ''}
  '';

  stage3 = name: action:
    deployCommands.${action} rec {
      inherit name;
      config = nodesBuilt.${name};
      pkgs = config._module.args.pkgs;
      lib = pkgs.lib;
    };

}

