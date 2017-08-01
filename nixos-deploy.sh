#!/bin/env bash
set -e

SCRIPT_DIR="$(dirname "$0")"

function showSyntax() {
cat <<EOF
$0 [-f hosts_file] [--fast] [--no-ssh-multiplexing] [BUILD_OPTIONS...] host action
EOF
}

# Parse the command line.
extraBuildFlags=()
extraInstantiateFlags=()
arguments=()
hostsFile="default.nix"
host=
action=
fast=
sshMultiplexing=1

while [ "$#" -gt 0 ]; do
    i="$1"; shift 1
    case "$i" in
        --help|-h)
            showSyntax
            exit 0
            ;;
        --hosts-file|-f)
            hostsFile="$1"
            shift 1
            ;;
        --fast)
            fast=1
            ;;
        --no-ssh-multiplexing)
            sshMultiplexing=
            ;;
        --max-jobs|-j|--cores|-I|--remote-path)
            j="$1"; shift 1
            extraBuildFlags+=("$i" "$j")
            ;;
        --keep-failed|-K|--keep-going|-k|--verbose|-v|-vv|-vvv|-vvvv|-vvvvv|--fallback|--repair|-Q|-j*)
            extraBuildFlags+=("$i")
            ;;
        --show-trace)
            extraInstantiateFlags+=("$i")
            extraBuildFlags+=("$i")
            ;;
        --option)
            j="$1"; shift 1
            k="$1"; shift 1
            extraBuildFlags+=("$i" "$j" "$k")
            ;;
        --*)
            echo "$0: unknown option '$i'"
            exit 1
            ;;
        *)
            arguments+=("$i")
            ;;
    esac
done

if [ ${#arguments[@]} -ne 2 ]; then
    showSyntax
    exit 1
fi

host="${arguments[0]}"
action="${arguments[1]}"

case "$action" in
    switch|boot|test|build|dry-build|dry-activate)
        ;;
    *)
        echo "$0: unknown action '$action'"
        exit 1
        ;;
esac

if [[ "$hostsFile" != /* ]]; then
   hostsFile="$PWD/$hostsFile"
fi

if [ ! -f "$hostsFile" ]; then
    echo "$0: file '$hostsFile' does not exist"
    exit 1
fi


function remoteBuild() {
    $SCRIPT_DIR/nix-remote-build.sh "${extraBuildFlags[@]}" "$@"
}

CONFIG_EXPR="(import $SCRIPT_DIR/nixos-config.nix).$host"
export hostsFile

function unescape() {
    sed -e 's/\\"/"/g' -e 's/^"//' -e 's/"$//' -e 's/\\n/\n/g'
}

defs="$(nix-instantiate --expr "$CONFIG_EXPR" --eval -A deployment.internal.script "${extraInstantiateFlags[@]}")"
eval "$(echo $defs | unescape)"


if [ -n sshMultiplexing ]; then
    tmpDir=$(mktemp -t -d nixos-deploy.XXXXXX)
    # TODO: split SSHOPTS into build/target ssh opts
    NIX_SSHOPTS="$NIX_SSHOPTS -o ControlMaster=auto -o ControlPath=$tmpDir/ssh-%n -o ControlPersist=60"

    cleanup() {
        for ctrl in "$tmpDir"/ssh-*; do
            ssh -o ControlPath="$ctrl" -O exit dummyhost 2>/dev/null || true
        done
        rm -rf "$tmpDir"
    }
    trap cleanup EXIT
fi


echo "Building Nix..."
remotePathOption=
if [ -z "$fast" ]; then
    remotePath="$(buildRemoteNix)"
    remotePathOption="--remote-path $remotePath"
fi

echo "Building system..."
pathToConfig="$(buildSystem $remotePathOption)"

echo "Activating configuration..."
if [ "$action" = switch -o "$action" = boot ]; then
   runOnTarget nix-env -p /nix/var/nix/profiles/system --set "$pathToConfig"
fi
runOnTarget "$pathToConfig/bin/switch-to-configuration" "$action"

