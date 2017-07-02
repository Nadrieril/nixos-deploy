export NIX_SSHOPTS="-A"
export NIXOS_CONFIG="$PWD/nixos-config.nix"
CONFIG_EXPR="import <nixos/nixos> { configuration = (import $NIXOS_CONFIG); }"

export HOST="$1"
shift 1

set -e

IP=$(nix-instantiate --expr "$CONFIG_EXPR" --eval -A config.deployment.ip | tr -d '"')
echo $IP

nixos_rebuild=$(nix-build --no-out-link --expr "$CONFIG_EXPR" -A config.system.build.nixos-rebuild)
$nixos_rebuild/bin/nixos-rebuild --build-host root@build_host --target-host "root@$IP" "$@"

