#!/bin/env bash

set -e

showSyntax() {
    # TODO
    exit 1
}


# Parse the command line.
origArgs=("$@")
instArgs=()
buildArgs=()
buildHost=
targetHost=
remotePATH=

while [ "$#" -gt 0 ]; do
    i="$1"; shift 1
    case "$i" in
      --help)
        showSyntax
        ;;
      --build-host|h)
        buildHost="$1"
        shift 1
        ;;
      --target-host|t)
        targetHost="$1"
        shift 1
        ;;
      --remote-path)
        remotePATH="$1"; shift 1
        ;;
      -o)
        out="$1"; shift 1
        buildArgs+=("--add-root" "$out" "--indirect")
        ;;
      -A|--expr)
        j="$1"; shift 1
        instArgs+=("$i" "$j")
        ;;
      # -I) # We don't want this in buildArgs
      #   shift 1
      #   ;;
      "<"*) # nix paths
        instArgs+=("$i")
        ;;
      *)
        buildArgs+=("$i")
        ;;
    esac
done


if [ -z "$buildHost" -a -n "$targetHost" ]; then
    buildHost="$targetHost"
fi
if [ "$targetHost" = localhost ]; then
    targetHost=
fi
if [ "$buildHost" = localhost ]; then
    buildHost=
fi

buildHostCmd() {
    if [ -z "$buildHost" ]; then
        "$@"
    elif [ -n "$remotePATH" ]; then
        ssh $NIX_SSHOPTS "$buildHost" PATH="$remotePATH" "$@"
    else
        ssh $NIX_SSHOPTS "$buildHost" "$@"
    fi
}

copyToTarget() {
    if ! [ "$targetHost" = "$buildHost" ]; then
        if [ -z "$targetHost" ]; then
            NIX_SSHOPTS=$NIX_SSHOPTS nix-copy-closure --from "$buildHost" "$@"
        elif [ -z "$buildHost" ]; then
            NIX_SSHOPTS=$NIX_SSHOPTS nix-copy-closure --to "$targetHost" "$@"
        else
            buildHostCmd nix-copy-closure --to "$targetHost" "$@"
        fi
    fi
}

nixBuild() {
    local drv="$(nix-instantiate "${instArgs[@]}")"
    if [ -a "$drv" ]; then
        if [ -n "$buildHost" ]; then
            NIX_SSHOPTS=$NIX_SSHOPTS nix-copy-closure --to "$buildHost" "$drv"
        fi
        buildHostCmd nix-store -r "$drv" "${buildArgs[@]}"
    else
        echo "nix-instantiate failed" >&2
        exit 1
    fi
}

outPaths=($(nixBuild))
copyToTarget "${outPaths[@]}"
for p in "${outPaths[@]}"; do
    echo "$p"
done

