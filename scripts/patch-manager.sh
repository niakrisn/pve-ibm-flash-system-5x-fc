#!/bin/bash
#
# IBM FlashSystem 5.x FC Plugin - Patch Manager
# Manages application and removal of PVE patches and GUI integration
#

set -e

PACKAGE_NAME="pve-ibm-fs5x-fc-plugin"
PATCH_DIR="/usr/share/${PACKAGE_NAME}/patches"
QEMU_TARGET="/usr/share/perl5/PVE/API2/Qemu.pm"
GUI_PATCH_SOURCE="/usr/share/${PACKAGE_NAME}/patches/pve-manager-index-html-gui.patch"
GUI_JS_SOURCE="/usr/share/${PACKAGE_NAME}/ibmflash-gui.js"
GUI_JS_TARGET="/usr/share/pve-manager/js/pve-storage-ibmflash.js"
GUI_TEMPLATE="/usr/share/pve-manager/index.html.tpl"
MARKER_PREFIX="# IBM FlashSystem Patch"
GUI_MARKER="pve-storage-ibmflash.js"

log() {
    echo "[IBM FlashSystem Plugin] $*"
}

# Check if Perl patches are applied
is_patched() {
    grep -q "$MARKER_PREFIX" "$QEMU_TARGET" 2>/dev/null
}

# Check if GUI is fully applied (both script tag AND JS file)
is_gui_patched() {
    grep -q "$GUI_MARKER" "$GUI_TEMPLATE" 2>/dev/null && [ -f "$GUI_JS_TARGET" ]
}

# Check if a specific patch is already applied
patch_applied() {
    _patch_file="$1"
    _target_file="$2"
    # Use dry-run reverse to check if patch can be reversed (meaning it's applied)
    patch -R -p0 -s -f --dry-run "$_target_file" < "$_patch_file" >/dev/null 2>&1
}

# Ensure GUI is fully applied (both files)
ensure_gui() {
    # Check if script tag exists in template
    if ! grep -q "$GUI_MARKER" "$GUI_TEMPLATE" 2>/dev/null; then
        # Apply index.html.tpl patch
        if [ -f "$GUI_PATCH_SOURCE" ]; then
            log "Applying index.html.tpl patch..."
            if patch -p0 -N "$GUI_TEMPLATE" < "$GUI_PATCH_SOURCE" 2>/dev/null; then
                log "  ✓ Script tag added"
            else
                log "  ⚠ Patch failed, trying with fuzz..."
                patch -p0 -N --fuzz=3 "$GUI_TEMPLATE" < "$GUI_PATCH_SOURCE" 2>/dev/null
            fi
        fi
    fi

    # Ensure JS file exists
    if [ ! -f "$GUI_JS_TARGET" ]; then
        mkdir -p "$(dirname "$GUI_JS_TARGET")"
        cp "$GUI_JS_SOURCE" "$GUI_JS_TARGET"
        chmod 644 "$GUI_JS_TARGET"
        log "  ✓ JS file copied"
    fi
}

case "$1" in
    apply)
        # Apply Perl patches
        if ! is_patched; then
            _applied_count=0
            _failed_patches=""

            # Apply each patch
            for _patch in "$PATCH_DIR"/*.patch; do
                if [ -f "$_patch" ]; then
                    _patch_name=$(basename "$_patch")

                    # Skip GUI patch for now (will handle separately)
                    if [ "$_patch_name" = "pve-manager-index-html-gui.patch" ]; then
                        continue
                    fi

                    # Skip if already applied (check by marker)
                    if grep -q "$MARKER_PREFIX" "$QEMU_TARGET" 2>/dev/null; then
                        log "Patch already applied: $_patch_name"
                        continue
                    fi

                    log "Applying: $_patch_name"

                    # Try to apply with -N (assume not applied)
                    if patch -p0 -N "$QEMU_TARGET" < "$_patch" 2>/dev/null; then
                        log "  ✓ Applied: $_patch_name"
                        _applied_count=$((_applied_count + 1))
                    else
                        # Try with --fuzz=3 for minor whitespace differences
                        if patch -p0 -N --fuzz=3 "$QEMU_TARGET" < "$_patch" 2>/dev/null; then
                            log "  ✓ Applied (with fuzz): $_patch_name"
                            _applied_count=$((_applied_count + 1))
                        else
                            log "  ⚠ Failed: $_patch_name (file may have been modified)"
                            _failed_patches="$_failed_patches $_patch_name"
                        fi
                    fi
                fi
            done

            # Add marker if at least one patch was applied
            if [ $_applied_count -gt 0 ]; then
                _package_version=$(dpkg-query -W -f='${Version}' "$PACKAGE_NAME" 2>/dev/null || echo "unknown")
                echo "" >> "$QEMU_TARGET"
                echo "${MARKER_PREFIX} ${_package_version}" >> "$QEMU_TARGET"
                log "Applied $_applied_count patch(es)"
            fi

            # Warn about failed patches but don't fail (APT hook safety)
            if [ -n "$_failed_patches" ]; then
                log "WARNING: Some patches failed to apply:$_failed_patches"
                log "The target file may have been modified by another update."
            fi
        else
            log "Perl patches already applied, skipping"
        fi

        # Apply GUI integration
        ensure_gui

        # Restart services
        systemctl try-reload-or-restart pvedaemon pveproxy pvestatd 2>/dev/null || true
        ;;

    remove)
        # Remove Perl patches
        if is_patched; then
            _removed_count=0

            # Reverse each patch
            for _patch in "$PATCH_DIR"/*.patch; do
                if [ -f "$_patch" ]; then
                    _patch_name=$(basename "$_patch")

                    # Skip GUI patch for now
                    if [ "$_patch_name" = "pve-manager-index-html-gui.patch" ]; then
                        continue
                    fi

                    # For Qemu.pm patches, just count them
                    _removed_count=$((_removed_count + 1))
                fi
            done

            # Remove marker if we removed any patches
            if [ $_removed_count -gt 0 ]; then
                # Remove our marker line and the empty line before it
                sed -i ":a;/${MARKER_PREFIX}/{x;1x;1d;x;d};/^\n*$/{$d;N;ba" "$QEMU_TARGET" 2>/dev/null || \
                sed -i "/${MARKER_PREFIX}/d" "$QEMU_TARGET"
                log "Removed $_removed_count patch(es)"
            fi
        fi

        # Remove GUI integration
        if is_gui_patched; then
            log "Removing GUI integration..."

            # Reverse index.html.tpl patch
            if patch -R -p0 "$GUI_TEMPLATE" < "$GUI_PATCH_SOURCE" 2>/dev/null; then
                log "  ✓ GUI patch reversed"
            elif patch -R -p0 -f "$GUI_TEMPLATE" < "$GUI_PATCH_SOURCE" 2>/dev/null; then
                log "  ✓ GUI patch reversed (forced)"
            fi

            # Remove the JS file
            rm -f "$GUI_JS_TARGET"

            # Update timestamp
            touch "$GUI_TEMPLATE" 2>/dev/null || true

            log "  ✓ GUI removed"
        fi

        # Restart services
        systemctl try-reload-or-restart pvedaemon pveproxy pvestatd 2>/dev/null || true
        ;;

    *)
        echo "Usage: $0 {apply|remove}"
        exit 1
        ;;
esac

exit 0
