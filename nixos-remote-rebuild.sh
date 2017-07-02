HOST="$1"
shift 1
export NIX_SSHOPTS="-A"

tmpDir=$(mktemp -t -d nixos-rebuild.XXXXXX)
export NIXOS_CONFIG="$tmpDir/nixos-config.nix"
echo "{ imports = [ (import $PWD/test.nix).$HOST ]; networking.hostName = \"$HOST\"; }" > $NIXOS_CONFIG
CONFIG_EXPR="import <nixos/nixos> { configuration = (import $NIXOS_CONFIG); }"

set -e

IP=$(nix-instantiate --expr "$CONFIG_EXPR" --eval -A config.custom.ip | tr -d '"')
echo $IP

nixos_rebuild=$(nix-build --no-out-link --expr "$CONFIG_EXPR" -A config.system.build.nixos-rebuild)
$nixos_rebuild/bin/nixos-rebuild --build-host root@build_host --target-host "root@$IP" "$@"

rm -rf "$tmpDir"

