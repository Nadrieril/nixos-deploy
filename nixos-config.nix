let
  host = builtins.getEnv "HOST";

  deployment = { config, pkgs, lib, ... }: {
    options = {
      deployment = lib.mkOption {
        default = {};
        type = lib.types.attrsOf lib.types.unspecified;
      };
    };

    config = {
      networking.hostName = lib.mkDefault host;
    };
  };

in
{
  imports = [
    deployment
    (import ./test.nix)."${host}"
  ];
}
