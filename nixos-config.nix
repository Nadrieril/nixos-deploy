let
  pkgs = import <nixos> {};
  lib = pkgs.lib;

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

      deployment.internal = lib.mkOption {
        type = lib.types.attrsOf lib.types.unspecified;
        internal = true;
        default = {};
      };
    };

    config = {
      deployment.buildHost = lib.mkDefault config.deployment.targetHost;

      deployment.internal.script =
        let
          default = d: x: if x == null then d else x;
          option = f: x: if x == null then "" else f x;
          target_host_opt = x: "--target-host \"${default "localhost" x}\"";
          build_host_opt = x: "--build-host \"${default "localhost" x}\"";
          bh = config.deployment.buildHost;
          th = config.deployment.targetHost;
        in ''
          export NIX_SSHOPTS="${config.deployment.ssh_options}"

          function buildRemoteNix() {
            outPaths=($(remoteBuild ${build_host_opt bh} ${target_host_opt bh} --expr "$CONFIG_EXPR" -A nix.package.out "$@"))
            rc=$?; if [[ $rc != 0 ]]; then exit $rc; fi
            local remotePath=
            for p in "${"$"}{outPaths[@]}"; do
                remotePath="$p/bin:$remotePath"
            done
            echo "$remotePath"
          }

          function buildSystem() {
            remoteBuild ${build_host_opt bh} ${target_host_opt th} --expr "$CONFIG_EXPR" -A system.build.toplevel "$@"
            rc=$?; if [[ $rc != 0 ]]; then exit $rc; fi
          }

          function runOnTarget() {
            ${if th == null then "sudo" else "ssh \"${th}\""} "$@"
            rc=$?; if [[ $rc != 0 ]]; then exit $rc; fi
          }
        '';

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

