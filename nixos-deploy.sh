#!/usr/bin/env bash
set -e

SCRIPT_DIR="$(dirname "$0")"

function showSyntax() {
cat <<EOF
$0 [-f hosts_file] [--fast] [--no-ssh-multiplexing] [BUILD_OPTIONS...] -h host action
EOF
}

# Parse the command line.
extraBuildFlags=()
extraInstantiateFlags=()
arguments=()
hostsFile="default.nix"
hosts=()
action=
fast=
sshMultiplexing=1

while [ "$#" -gt 0 ]; do
    i="$1"; shift 1
    case "$i" in
        --help)
            showSyntax
            exit 0
            ;;
        --hosts-file|-f)
            hostsFile="$1"
            shift 1
            ;;
        --host|--hosts|-h)
            hosts+=("$1")
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

if [ ${#arguments[@]} -ne 1 ]; then
    showSyntax
    exit 1
fi

if [ ${#hosts[@]} -eq 0 ]; then
    showSyntax
    exit 1
fi

action="${arguments[0]}"

case "$action" in
    switch|boot|test|build|dry-build|dry-activate|build-image|install)
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

if [[ "$hosts" == "all" ]]; then
   all_hosts_expr='let lib=(import <nixpkgs> {}).lib; in lib.concatStringsSep " " (builtins.attrNames (import ./default.nix))'
   hosts=($(nix-instantiate --eval -E "$all_hosts_expr" | sed -e 's/^"//' -e 's/"$//'))
   deployingAll=true
fi

function remoteBuild() {
    $SCRIPT_DIR/nix-remote-build.sh "${extraInstantiateFlags[@]}" "${extraBuildFlags[@]}" "$@"
}

function buildRemoteNix() {
    outPaths=($(buildToBuildHost --expr "$CONFIG_EXPR" -A nix.package.out "$@"))
    local remotePath=
    for p in "${outPaths[@]}"; do
        remotePath="$p/bin:$remotePath"
    done
    echo "$remotePath"
}

function buildSystem() {
    buildToTargetHost --expr "$CONFIG_EXPR" -A system.build.toplevel "$@"
}

for host in "${hosts[@]}"; do (
   echo "Deploying $host..."

   CONFIG_EXPR="(import $SCRIPT_DIR/nixos-config.nix).$host"

   export hostsFile
   source $(nix-build --expr "$CONFIG_EXPR" -A deployment.internal.script "${extraInstantiateFlags[@]}")

   if [ -z "$includeInAll" -a -n "$deployingAll" ]; then
      echo
      continue
   fi

   if [ -n "$sshMultiplexing" ]; then
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


   remotePathOption=
   if [ -z "$fast" ]; then
       echo "Building Nix..."
       remotePath="$(buildRemoteNix)"
       remotePathOption="--remote-path $remotePath"
   fi

   if [ "$action" = "build-image" ]; then
       echo "Building image..."
       buildToBuildHost $remotePathOption --expr "$CONFIG_EXPR" -A deployment.internal.build-image

   elif [ "$action" = "install" ]; then
       echo "Building system..."
       installScript="$(buildToBuildHost $remotePathOption --expr "$CONFIG_EXPR" -A deployment.internal.nixos-install.script)"
       # echo "Installing to disk..."
       echo "Run $installScript with the usual nixos-install options to install the system to a disk"

   else
       echo "Building system..."
       pathToConfig="$(buildSystem $remotePathOption)"

       echo "Activating configuration..."
       if [ "$action" = switch -o "$action" = boot ]; then
          runOnTarget nix-env -p /nix/var/nix/profiles/system --set "$pathToConfig"
       fi
       runOnTarget "$pathToConfig/bin/switch-to-configuration" "$action"
   fi

   echo
)
done

