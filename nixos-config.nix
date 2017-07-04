let
  pkgs = import <nixos> {};
  lib = pkgs.lib;

  deploymentConf = { name, config, pkgs, lib, ... }: {
    options = {
      deployment.buildHost = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = ''
          This option specifies the hostname or IP address ofthe host to build on.
          If null, uses targetHost; if localhost, uses local machine;
          if neither, needs to be able to ssh into targetHost.
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
        '';
      };
    };

    config = {
      deployment.targetHost = lib.mkDefault name;
      networking.hostName = lib.mkDefault name;
    };
  };

  buildNixOSSystem = configuration:
    (import <nixos/nixos> { inherit configuration; }).config;


  nodes = import ./test.nix;

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

