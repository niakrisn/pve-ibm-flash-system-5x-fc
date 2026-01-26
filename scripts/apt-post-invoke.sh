#!/bin/bash
#
# IBM FlashSystem 5.x FC Plugin - APT Post-Invoke Handler
# Applies patches if flag file exists (set by apt-trigger.sh)
#

PATCH_MANAGER="/usr/share/pve-ibm-fs5x-fc-plugin/scripts/patch-manager.sh"
FLAG_FILE="/tmp/.ibm-fs-plugin-needs-patching"

if [ -f "$FLAG_FILE" ]; then
    rm -f "$FLAG_FILE"
    logger -t "ibm-fs-plugin" "Applying patches after package update"
    if [ -x "$PATCH_MANAGER" ]; then
        "$PATCH_MANAGER" apply
    fi
fi

exit 0
