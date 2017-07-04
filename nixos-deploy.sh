#!/bin/env bash
set -e

fast=

# parse command line

HOST="$1"
shift 1
CONFIG_EXPR="(import ./nixos-config.nix).$HOST"
NIX_REMOTE_BUILD="./nix-remote-build.sh"

function unescape() {
    sed -e 's/\\"/"/g' -e 's/^"//' -e 's/"$//' -e 's/\\n/\n/g'
}

eval "$(nix-instantiate --expr "$CONFIG_EXPR" --eval -A deployment.internal.script | unescape)"


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
remotePathOption=
if [ -z "$fast" ]; then
    remotePath="$(buildRemoteNix)"
    remotePathOption="--remote-path $remotePath"
fi

echo "Building system..."
pathToConfig="$(buildSystem $remotePathOption --cores 7)"

echo "Activating configuration..."
activateConfig "$pathToConfig/bin/switch-to-configuration" "$1"

