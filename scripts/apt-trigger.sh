#!/bin/bash
#
# IBM FlashSystem 5.x FC Plugin - APT Trigger
# Checks if relevant PVE packages are being updated and applies patches if needed
#
# This script is called by APT's Pre-Install-Pkgs hook with package list on stdin
#

PATCH_MANAGER="/usr/share/pve-ibm-fs5x-fc-plugin/scripts/patch-manager.sh"

# Packages that require re-patching when updated
WATCHED_PACKAGES="qemu-server pve-manager pve-qemu-kvm"

log() {
    logger -t "ibm-fs-plugin" "$*"
}

# Read package list from stdin (APT Pre-Install-Pkgs format)
# Format varies by APT version, but package names are always present
needs_patching=0

while IFS= read -r line; do
    for pkg in $WATCHED_PACKAGES; do
        if echo "$line" | grep -qw "$pkg"; then
            log "Detected update of watched package: $pkg"
            needs_patching=1
            break 2
        fi
    done
done

if [ "$needs_patching" -eq 1 ]; then
    log "Scheduling patch re-application after dpkg completes"
    # We cannot apply patches here (files are locked during Pre-Install)
    # Create a flag file that Post-Invoke will check
    touch /tmp/.ibm-fs-plugin-needs-patching
fi

exit 0
