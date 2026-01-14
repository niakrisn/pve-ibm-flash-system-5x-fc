#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

LIST_FILE=""
PKG_MAP_FILE=""
VERSIONS_FILE=""
KEY_FILE=""
UPDATE_SERIES=0
IMAGE="pve-ibm-fs5x-fc-plugin-tools"
SUITE="trixie"
REPO_URL="http://download.proxmox.com/debian/pve"
COMPONENT="pve-no-subscription"
KEY_URL=""
CACHE_DIR=".cache/docker-apt"
USE_CACHE=1

usage() {
    cat <<'EOF'
Usage:
  prepare-patches-docker.sh --list <patch-list.txt> --pkgmap <pkg-map.txt> [options]

Options:
  --versions <pkg-versions.txt>  Use explicit package versions
  --key-file <path>      Use a local Proxmox GPG key file (relative to repo)
  --update-series        Update debian/patches/series while creating patches
  --image <docker-image> Docker image to use (default: debian:bookworm)
  --suite <suite>        Proxmox suite (default: bookworm)
  --repo <url>           Proxmox repo URL (default: http://download.proxmox.com/debian/pve)
  --component <name>     Proxmox repo component (default: pve-no-subscription)
  --key-url <url>        GPG key URL (default: repo/proxmox-release-<suite>.gpg)
  --no-cache             Disable Docker APT cache volumes

Patch list format (one per line):
  <patch-name> <target-path> <mod-path>

Package map format (one per line):
  <target-path> <package-name>

Package versions format (one per line):
  <package-name> <version>
EOF
}

die() {
    echo "ERROR: $*" >&2
    exit 1
}

while [ $# -gt 0 ]; do
    case "$1" in
        --list)
            LIST_FILE="${2:-}"
            shift 2
            ;;
        --pkgmap)
            PKG_MAP_FILE="${2:-}"
            shift 2
            ;;
        --versions)
            VERSIONS_FILE="${2:-}"
            shift 2
            ;;
        --key-file)
            KEY_FILE="${2:-}"
            shift 2
            ;;
        --update-series)
            UPDATE_SERIES=1
            shift
            ;;
        --image)
            IMAGE="${2:-}"
            shift 2
            ;;
        --suite)
            SUITE="${2:-}"
            shift 2
            ;;
        --repo)
            REPO_URL="${2:-}"
            shift 2
            ;;
        --component)
            COMPONENT="${2:-}"
            shift 2
            ;;
        --key-url)
            KEY_URL="${2:-}"
            shift 2
            ;;
        --no-cache)
            USE_CACHE=0
            shift
            ;;
        *)
            usage
            die "unknown argument: $1"
            ;;
    esac
done

[ -n "$LIST_FILE" ] || die "missing --list"
[ -n "$PKG_MAP_FILE" ] || die "missing --pkgmap"
[ -f "$ROOT_DIR/$LIST_FILE" ] || die "list file not found: $LIST_FILE"
[ -f "$ROOT_DIR/$PKG_MAP_FILE" ] || die "pkg map file not found: $PKG_MAP_FILE"
[ -z "$VERSIONS_FILE" ] || [ -f "$ROOT_DIR/$VERSIONS_FILE" ] || die "versions file not found: $VERSIONS_FILE"
[ -z "$KEY_FILE" ] || [ -f "$ROOT_DIR/$KEY_FILE" ] || die "key file not found: $KEY_FILE"

if [ -z "$KEY_URL" ]; then
    KEY_URL="${REPO_URL%/}/proxmox-release-${SUITE}.gpg"
fi

if [ "$USE_CACHE" -eq 1 ]; then
    mkdir -p "$ROOT_DIR/$CACHE_DIR/lists" "$ROOT_DIR/$CACHE_DIR/archives"
fi

DOCKER_ARGS=(
    --rm
    -v "$ROOT_DIR:/work"
    -w /work
    -e LIST_FILE="$LIST_FILE"
    -e PKG_MAP_FILE="$PKG_MAP_FILE"
    -e VERSIONS_FILE="$VERSIONS_FILE"
    -e UPDATE_SERIES="$UPDATE_SERIES"
    -e SUITE="$SUITE"
    -e REPO_URL="$REPO_URL"
    -e COMPONENT="$COMPONENT"
    -e KEY_URL="$KEY_URL"
    -e KEY_FILE="$KEY_FILE"
)

if [ "$USE_CACHE" -eq 1 ]; then
    DOCKER_ARGS+=(
        -v "$ROOT_DIR/$CACHE_DIR/lists:/var/lib/apt/lists"
        -v "$ROOT_DIR/$CACHE_DIR/archives:/var/cache/apt/archives"
    )
fi

docker run \
    "${DOCKER_ARGS[@]}" \
    "$IMAGE" bash -s <<'EOF'
set -euo pipefail

die() {
    echo "ERROR: $*" >&2
    exit 1
}

apt-get update
apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    gnupg \
    apt-transport-https \
    diffutils

mkdir -p /etc/apt/keyrings
if [ -n "${KEY_FILE:-}" ]; then
    cp "/work/$KEY_FILE" /etc/apt/keyrings/proxmox.gpg
else
    curl -fsSL "$KEY_URL" | gpg --dearmor -o /etc/apt/keyrings/proxmox.gpg
fi
echo "deb [signed-by=/etc/apt/keyrings/proxmox.gpg] $REPO_URL $SUITE $COMPONENT" \
    > /etc/apt/sources.list.d/proxmox.list

apt-get update

list_file="/work/$LIST_FILE"
pkg_map_file="/work/$PKG_MAP_FILE"
versions_file=""
if [ -n "${VERSIONS_FILE:-}" ]; then
    versions_file="/work/$VERSIONS_FILE"
fi

declare -A pkg_for_target
while IFS= read -r line || [ -n "$line" ]; do
    line="${line%%#*}"
    line="$(echo "$line" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    [ -z "$line" ] && continue
    set -- $line
    [ $# -ge 2 ] || die "invalid pkg map entry: $line"
    pkg_for_target["$1"]="$2"
done < "$pkg_map_file"

declare -A version_for_pkg
if [ -n "$versions_file" ]; then
    [ -f "$versions_file" ] || die "versions file not found in container: $versions_file"
    while IFS= read -r line || [ -n "$line" ]; do
        line="${line%%#*}"
        line="$(echo "$line" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
        [ -z "$line" ] && continue
        set -- $line
        [ $# -ge 2 ] || die "invalid versions entry: $line"
        version_for_pkg["$1"]="$2"
    done < "$versions_file"
fi

declare -A needed_pkgs
while IFS= read -r line || [ -n "$line" ]; do
    line="${line%%#*}"
    line="$(echo "$line" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    [ -z "$line" ] && continue
    set -- $line
    [ $# -ge 3 ] || die "invalid patch list entry: $line"
    target="$2"
    pkg="${pkg_for_target[$target]:-}"
    [ -n "$pkg" ] || die "no package mapping for target: $target"
    needed_pkgs["$pkg"]=1
done < "$list_file"

mkdir -p /tmp/pve-upstream
cd /tmp/pve-upstream

for pkg in "${!needed_pkgs[@]}"; do
    if [ -n "${version_for_pkg[$pkg]:-}" ]; then
        apt download "${pkg}=${version_for_pkg[$pkg]}"
    else
        apt download "$pkg"
    fi
    deb="$(ls -t ${pkg}_*.deb | head -n 1)"
    [ -n "$deb" ] || die "failed to download package: $pkg"
    dpkg-deb -x "$deb" "/tmp/pve-upstream/$pkg"
done

while IFS= read -r line || [ -n "$line" ]; do
    line="${line%%#*}"
    line="$(echo "$line" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    [ -z "$line" ] && continue
    set -- $line
    [ $# -ge 3 ] || die "invalid patch list entry: $line"
    patch="$1"
    target="$2"
    mod="/work/$3"

    pkg="${pkg_for_target[$target]:-}"
    [ -n "$pkg" ] || die "no package mapping for target: $target"
    base="/tmp/pve-upstream/$pkg"

    if [[ "$target" = /* ]]; then
        orig="$base$target"
    else
        orig="$base/usr/share/perl5/$target"
    fi

    [ -f "$orig" ] || die "orig not found: $orig"
    [ -f "$mod" ] || die "mod not found: $mod"

    if [ "$UPDATE_SERIES" -eq 1 ]; then
        /work/scripts/patch-series-helper.sh create \
            --patch "$patch" \
            --target "$target" \
            --orig "$orig" \
            --mod "$mod" \
            --update-series
    else
        /work/scripts/patch-series-helper.sh create \
            --patch "$patch" \
            --target "$target" \
            --orig "$orig" \
            --mod "$mod"
    fi
done < "$list_file"
EOF
