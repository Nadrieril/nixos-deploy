{ pkgs ? import <nixpkgs> { } }:

with pkgs; stdenv.mkDerivation {
  name = "nixos-deploy";
  src = ./.;

  buildPhase = ''
    # The script expects the Nix file defining the options to be
    # stored in the same directory, which is not the case in the
    # derivation output:
    sed -i "s:^SCRIPT_DIR=.*$:SCRIPT_DIR=$out/share:g" nixos-deploy

    # Some external commands aren't correctly recognised by Nix' shell
    # script patcher:
    sed -i "s:^__PYTHON__=.*$:__PYTHON__=${python3}/bin/python3:g" nixos-deploy
    sed -i "s:^__NIX_BUILD__=.*$:__NIX_BUILD__=${nix}/bin/nix-build:g" nixos-deploy
    sed -i "s:^__JQ__=.*$:__JQ__=${jq}/bin/jq:g" nixos-deploy
  '';

  installPhase = ''
    mkdir -p $out/share/zsh/vendor-completions $out/bin
    cp nixos-config.nix $out/share/
    cp nixos-deploy $out/bin/
    cp zsh-completion.zsh $out/share/zsh/vendor-completions/_nixos-deploy
  '';
}
