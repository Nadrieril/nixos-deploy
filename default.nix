{ pkgs ? import <nixpkgs> {} }:

with pkgs; stdenv.mkDerivation {
  name = "nixos-deploy";
  src = ./.;

  buildPhase = ''
    # The script expects the Nix file defining the options to be
    # stored in the same directory, which is not the case in the
    # derivation output:
    sed -i "s:^SCRIPT_DIR.*$:SCRIPT_DIR=$out/share:g" nixos-deploy

    # Some external commands aren't correctly recognised by Nix' shell
    # script patcher:
    sed -i "s:python:${python}/bin/python:g" nixos-deploy
    sed -i "s:nix-build:${nix}/bin/nix-build:g" nixos-deploy
    sed -i "s:jq:${jq}/bin/jq:g" nixos-deploy
 '';

  installPhase = ''
    mkdir -p $out/share/zsh/vendor-completions $out/bin
    cp nixos-config.nix $out/share/
    cp nixos-deploy $out/bin/
    cp zsh-completion.zsh $out/share/zsh/vendor-completions/_nixos-deploy
  '';
}
