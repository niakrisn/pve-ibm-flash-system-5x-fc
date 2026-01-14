#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

IMAGE="pve-ibm-fs5x-fc-plugin-tools"
PLATFORM="linux/amd64"
SUITE="trixie"
REPO_URL="http://download.proxmox.com/debian/pve"
COMPONENT="pve-no-subscription"
KEY_FILE="proxmox-release-trixie.gpg"
VERSIONS_FILE="pkg-versions.txt"
CACHE_DIR=".cache/docker-apt"
USE_CACHE=1
OUTPUT_DIR="output/patchtest"

usage() {
    cat <<'EOF'
Usage:
  patch-apply-docker-check.sh [options]

Options:
  --image <docker-image>   Docker image to use (default: debian:bookworm)
  --platform <platform>    Docker platform (default: linux/amd64)
  --suite <suite>          Proxmox suite (default: trixie)
  --repo <url>             Proxmox repo URL
  --component <name>       Proxmox repo component
  --key-file <path>        Local Proxmox GPG key file (relative to repo root)
  --versions <path>        Package versions file (default: pkg-versions.txt)
  --output <path>          Output directory (default: output/patchtest)
  --no-cache               Disable Docker APT cache volumes
EOF
}

die() {
    echo "ERROR: $*" >&2
    exit 1
}

while [ $# -gt 0 ]; do
    case "$1" in
        --image)
            IMAGE="${2:-}"
            shift 2
            ;;
        --platform)
            PLATFORM="${2:-}"
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
        --key-file)
            KEY_FILE="${2:-}"
            shift 2
            ;;
        --versions)
            VERSIONS_FILE="${2:-}"
            shift 2
            ;;
        --output)
            OUTPUT_DIR="${2:-}"
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

[ -f "$ROOT_DIR/$KEY_FILE" ] || die "key file not found: $KEY_FILE"
[ -f "$ROOT_DIR/$VERSIONS_FILE" ] || die "versions file not found: $VERSIONS_FILE"

if [ "$USE_CACHE" -eq 1 ]; then
    mkdir -p "$ROOT_DIR/$CACHE_DIR/lists" "$ROOT_DIR/$CACHE_DIR/archives"
fi

DOCKER_ARGS=(
    --rm
    -i
    --platform="$PLATFORM"
    -v "$ROOT_DIR:/work"
    -w /work
    -e KEY_FILE="$KEY_FILE"
    -e VERSIONS_FILE="$VERSIONS_FILE"
    -e OUTPUT_DIR="$OUTPUT_DIR"
    -e REPO_URL="$REPO_URL"
    -e SUITE="$SUITE"
    -e COMPONENT="$COMPONENT"
)

if [ "$USE_CACHE" -eq 1 ]; then
    DOCKER_ARGS+=(
        -v "$ROOT_DIR/$CACHE_DIR/lists:/var/lib/apt/lists"
        -v "$ROOT_DIR/$CACHE_DIR/archives:/var/cache/apt/archives"
    )
fi

docker run "${DOCKER_ARGS[@]}" "$IMAGE" bash -s <<'EOF'
set -euxo pipefail

apt-get update
apt-get install -y --no-install-recommends \
  ca-certificates \
  gnupg \
  apt-transport-https \
  patch \
  sed

mkdir -p /etc/apt/keyrings
cp "/work/$KEY_FILE" /etc/apt/keyrings/proxmox.gpg

echo "deb [signed-by=/etc/apt/keyrings/proxmox.gpg] $REPO_URL $SUITE $COMPONENT" \
  > /etc/apt/sources.list.d/proxmox.list

apt-get update

mkdir -p /tmp/pve-upstream
cd /tmp/pve-upstream

qemu_ver=$(awk '$1=="qemu-server"{print $2}' "/work/$VERSIONS_FILE")
stor_ver=$(awk '$1=="libpve-storage-perl"{print $2}' "/work/$VERSIONS_FILE")
mgr_ver=$(awk '$1=="pve-manager"{print $2}' "/work/$VERSIONS_FILE")

[ -n "$qemu_ver" ] || { echo "missing qemu-server version" >&2; exit 1; }
[ -n "$stor_ver" ] || { echo "missing libpve-storage-perl version" >&2; exit 1; }
[ -n "$mgr_ver" ] || { echo "missing pve-manager version" >&2; exit 1; }

apt download qemu-server="$qemu_ver" libpve-storage-perl="$stor_ver" pve-manager="$mgr_ver"
for deb in *.deb; do
  pkg="${deb%%_*}"
  dpkg-deb -x "$deb" "/tmp/pve-upstream/$pkg"
done

rm -rf /work/_patchtest
rm -rf "/work/$OUTPUT_DIR"
mkdir -p "/work/$OUTPUT_DIR/usr/share/perl5/PVE"
cp -a /tmp/pve-upstream/qemu-server/usr/share/perl5/PVE/QemuServer.pm "/work/$OUTPUT_DIR/usr/share/perl5/PVE/"
cp -a /tmp/pve-upstream/qemu-server/usr/share/perl5/PVE/QemuServer "/work/$OUTPUT_DIR/usr/share/perl5/PVE/"
mkdir -p "/work/$OUTPUT_DIR/usr/share/perl5/PVE/API2"
cp -a /tmp/pve-upstream/qemu-server/usr/share/perl5/PVE/API2/Qemu.pm "/work/$OUTPUT_DIR/usr/share/perl5/PVE/API2/"
mkdir -p "/work/$OUTPUT_DIR/usr/share/perl5/PVE/Storage"
cp -a /tmp/pve-upstream/libpve-storage-perl/usr/share/perl5/PVE/Storage/Plugin.pm "/work/$OUTPUT_DIR/usr/share/perl5/PVE/Storage/"

cd "/work/$OUTPUT_DIR/usr/share/perl5"
while IFS= read -r line || [ -n "$line" ]; do
  line="${line%%#*}"
  line="$(echo "$line" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
  [ -z "$line" ] && continue
  patch -p0 < "/work/debian/patches/$line"
done < /work/debian/patches/series

mkdir -p "/work/$OUTPUT_DIR/usr/share/pve-manager"
cp -a /tmp/pve-upstream/pve-manager/usr/share/pve-manager/index.html.tpl "/work/$OUTPUT_DIR/usr/share/pve-manager/"

sed -e 's|^--- /|--- |' -e 's|^+++ /|+++ |' /work/debian/patches/pve-manager-index-html-gui.patch > "/work/$OUTPUT_DIR/patchtest_gui.patch"
patch --batch -p0 -d "/work/$OUTPUT_DIR" < "/work/$OUTPUT_DIR/patchtest_gui.patch"

echo "OK: patches applied" > "/work/$OUTPUT_DIR/patchtest.log"
EOF
