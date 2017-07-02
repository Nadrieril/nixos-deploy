let
  pkgs = import <nixos> {};
  lib = pkgs.lib;

  deployment = { config, pkgs, lib, ... }: {
    options = {
      deployment = lib.mkOption {
        default = {};
        type = lib.types.attrsOf lib.types.unspecified;
      };
    };
  };

  buildNixOSSystem = configuration:
    import <nixos/nixos> { inherit configuration; };


  nodes = import ./test.nix;

  nodesBuilt = lib.mapAttrs (host: conf: buildNixOSSystem {
    imports = [
      deployment
      conf
    ];
    _module.args = { nodes = nodesBuilt; };
    networking.hostName = lib.mkDefault host;
  }) nodes;

in

nodesBuilt."${builtins.getEnv "HOST"}".config

