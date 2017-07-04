CONFIG_EXPR="import ./nixos-config.nix"
HOST="$1"
shift 1

set -e

buildHost="$(nix-instantiate --expr "$CONFIG_EXPR" --eval -A "$HOST".deployment.buildHost | tr -d '"')"
targetHost="$(nix-instantiate --expr "$CONFIG_EXPR" --eval -A "$HOST".deployment.targetHost | tr -d '"')"
export NIX_SSHOPTS="$(nix-instantiate --expr "$CONFIG_EXPR" --eval -A "$HOST".deployment.ssh_options | tr -d '"')"
echo "Building for $targetHost on $buildHost"

tmpDir=$(mktemp -t -d nixos-deploy.XXXXXX)
NIX_SSHOPTS="$NIX_SSHOPTS -o ControlMaster=auto -o ControlPath=$tmpDir/ssh-%n -o ControlPersist=60"

cleanup() {
    for ctrl in "$tmpDir"/ssh-*; do
        ssh -o ControlPath="$ctrl" -O exit dummyhost 2>/dev/null || true
    done
    rm -rf "$tmpDir"
}
trap cleanup EXIT


echo "Building Nix..."
remotePath=
for p in $(./nix-remote-build.sh --target-host "$buildHost" --expr "$CONFIG_EXPR" -A "$HOST".nix.package.out); do
    remotePath="$remotePath${remotePath:+:}$p/bin"
done

echo "Building system..."
pathToConfig="$(./nix-remote-build.sh --build-host "$buildHost" --target-host "$targetHost" --remote-path "$remotePath" --expr "$CONFIG_EXPR" -A "$HOST".system.build.toplevel --cores 7)"

echo "Activating configuration..."
ssh "$targetHost" $pathToConfig/bin/switch-to-configuration "$1"

