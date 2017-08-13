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

      deployment.image = lib.mkOption {
        type = lib.types.attrsOf lib.types.unspecified;
        default = {
          name = "nixos-${name}-disk-image";
          format = "qcow2";
          diskSize = "15000";
        };
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
        in pkgs.writeScript "nixos-deploy-${name}" ''
          export NIX_SSHOPTS="${config.deployment.ssh_options}"

          function buildToBuildHost() {
            remoteBuild ${build_host_opt bh} ${target_host_opt bh} "$@"
          }

          function buildToTargetHost() {
            remoteBuild ${build_host_opt bh} ${target_host_opt th} "$@"
          }

          function runOnTarget() {
            ${if th == null then "sudo" else "ssh \"${th}\""} "$@"
          }
        '';

        deployment.internal.build-image = import <nixos/nixos/lib/make-disk-image.nix> ({
          inherit pkgs lib config;
        } // config.deployment.image);

    };
  };


  buildNixOSSystem = configuration:
    (import <nixos/nixos> { inherit configuration; }).config;


  nodes = import (builtins.getEnv "hostsFile");

  nodesBuilt = lib.mapAttrs (host: conf: buildNixOSSystem {
    imports = [
      deploymentConf
      conf
    ];
    _module.args = {
      nodes = nodesBuilt;
      name = host;
    };
  }) nodes;

in

nodesBuilt

