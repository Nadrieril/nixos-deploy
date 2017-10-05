let
  lib = (import <nixos> {}).lib;

  deploymentConf = { name, config, pkgs, lib, ... }: {
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

      deployment.internal.script = let
        default = d: x: if x == null then d else x;
        option = f: x: if x == null then "" else f x;
        target_host_opt = x: "--target-host \"${default "localhost" x}\"";
        build_host_opt = x: "--build-host \"${default "localhost" x}\"";
        bh = config.deployment.buildHost;
        th = config.deployment.targetHost;
        ph = config.deployment.provisionHost;
      in pkgs.writeScript "nixos-deploy-${name}" ''
        export NIX_SSHOPTS="${config.deployment.ssh_options}"

        function buildToBuildHost() {
          remoteBuild ${build_host_opt bh} ${target_host_opt bh} "$@"
        }

        function buildToTargetHost() {
          remoteBuild ${build_host_opt bh} ${target_host_opt th} "$@"
        }

        function buildToProvisionHost() {
          remoteBuild ${build_host_opt bh} ${target_host_opt ph} "$@"
        }

        function runOnTarget() {
          ${if th == null then "sudo" else "ssh \"${th}\""} "$@"
        }

        function runOnProvisionHost() {
          ${if bh == null then "sudo" else "ssh \"${ph}\""} "$@"
        }

        includeInAll=${if config.deployment.includeInAll then "true" else ""}
      '';

      deployment.internal.activate = let
        cfg = config.system.build.toplevel;
      in pkgs.writeScript "nixos-activate-${name}" ''
        #!${pkgs.bash}/bin/bash
        action="$1"
        pathToConfig="${cfg}"

        echo "Activating configuration..."
        if [ "$action" = switch -o "$action" = boot ]; then
            nix-env -p /nix/var/nix/profiles/system --set "$pathToConfig"
        fi
        "$pathToConfig/bin/switch-to-configuration" "$action"
      '';

      deployment.internal.build-image = let
        image = import <nixos/nixos/lib/make-disk-image.nix> ({
          inherit pkgs lib config;
        } // config.deployment.imageOptions);
      in pkgs.writeScript "nixos-image-${name}" ''
        #!${pkgs.bash}/bin/bash
        ${if config.deployment.imagePath == null
        then "echo ${image}"
        else ''
          if [ ! -f "${config.deployment.imagePath}" ]; then
            cp "${image}/nixos.qcow2" "${config.deployment.imagePath}"
            echo "Image has been copied to ${config.deployment.imagePath}"
          else
            echo "File ${config.deployment.imagePath} already exists ! Aborting."
            exit 1
          fi
        ''}
      '';

      deployment.internal.nixos-install = let
        nixos-install = (import <nixos/nixos/modules/installer/tools/tools.nix> {
          inherit pkgs; modulesPath = null; config = {
            nix.package.out = (import <nixpkgs> {}).nix.out;
            inherit (config) system;
            # should use correct current system values
            ids.uids.root = "root";
            ids.gids.nixbld = "nixbld";
          };
        }).config.system.build.nixos-install;
      in pkgs.writeScript "nixos-install-${name}" ''
        #!${pkgs.bash}/bin/bash
        ${nixos-install}/bin/nixos-install --closure ${config.system.build.toplevel} "$@"
      '';
    };
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
    in (import nixosPath { inherit configuration; }).config;


  nodes = import (builtins.getEnv "hostsFile");

  nodesBuilt = lib.mapAttrs (host: conf: buildNixOSSystem {
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

nodesBuilt

