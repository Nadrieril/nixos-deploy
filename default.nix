{ pkgs ? import <nixpkgs> {} }:

with pkgs; stdenv.mkDerivation {
  name = "nixos-deploy";
  src = ./.;

  buildPhase = ''
    # The script expects the Nix file defining the options to be
    # stored in the same directory, which is not the case in the
    # derivation output:
    sed -i "s:^SCRIPT_DIR.*$:SCRIPT_DIR=$out/share:g" nixos-deploy.sh

    # Some external commands aren't correctly recognised by Nix' shell
    # script patcher:
    sed -i "s:python:${python}/bin/python:g" nixos-deploy.sh
    sed -i "s:nix-build:${nix}/bin/nix-build:g" nixos-deploy.sh
 '';

  installPhase = ''
    mkdir -p $out/share/zsh/vendor-completions $out/bin
    cp nixos-config.nix $out/share/
    cp nixos-deploy.sh $out/bin/nixos-deploy
    cp zsh-completion.zsh $out/share/zsh/vendor-completions/_nixos-deploy
  '';
}
