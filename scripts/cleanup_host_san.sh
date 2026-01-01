#!/bin/bash
# Comprehensive SAN/Host Cleanup Script
# Purges test-related volumes and orphaned devices from IBM FlashSystem and PVE Host

STOREID="fs-01"
TEST_PREFIXES=("vm-9999" "vm-9200" "base-9100" "vm-9101" "testsnap")

echo "Starting 'Nuclear Cleanup' for $STOREID..."

# 1. Stop and Destroy Test VMs
echo "Phase 1: Stopping and destroying test VMs..."
for vmid in 9999 9200 9100 9101; do
    if qm status "$vmid" &>/dev/null; then
        echo "Forcing stop for VM $vmid..."
        # Use overrule-shutdown as requested, with timeout
        qm stop "$vmid" --overrule-shutdown 1 --timeout 30 2>/dev/null
        
        # Verify it's actually stopped
        if ! qm wait "$vmid" 30 2>/dev/null; then
            echo "VM $vmid did not stop gracefully, killing process..."
            pkill -f "kvm -id $vmid"
        fi

        # First try standard purge
        qm destroy "$vmid" --destroy-unreferenced-disks 1 --purge 1 2>/dev/null
    fi
    # Hard cleanup of config if qm destroy failed or if it's just a file
    if [ -f "/etc/pve/qemu-server/$vmid.conf" ]; then
        echo "Hard removing stale config for VM $vmid..."
        rm -f "/etc/pve/qemu-server/$vmid.conf"
    fi
done

# 2. Purge Volumes and Mappings from Storage (Safety Net)
echo "Phase 2: Purging residual volumes from $STOREID..."
for vmid in 9999 9200 9100 9101; do
    echo "Scanning for residual volumes belonging to VM $vmid..."
    # Find all volumes for this VMID in the storage
    VOLS=$(pvesm list "$STOREID" --vmid "$vmid" | awk 'NR>1 {print $1}')
    for volid in $VOLS; do
        echo "Removing residual volume: $volid"
        pvesm free "$volid" 2>/dev/null
    done
done

# 3. Cleanup Host Devices (Multipath & SCSI)
echo "Phase 3: Cleaning up host devices..."
# Удаляем сиротливые устройства (без томов на СХД)
perl -I. -MVMHelpers -MTestEnv -e '
    $env = TestEnv->setup();
    VMHelpers::cleanup_orphan_fc_devices($env);
' 2>/dev/null

# 4. Explicit Multipath Flush for known test IDs
for prefix in "${TEST_PREFIXES[@]}"; do
    # This is a fallback to ensure mapper entries are gone
    multipath -F 2>/dev/null
done

# 5. Clear Plugin Logs
LOG_FILE="/var/log/pve-storage-ibm.log"
if [ -f "$LOG_FILE" ]; then
    echo "Clearing plugin log: $LOG_FILE..."
    true > "$LOG_FILE"
fi

echo "Cleanup complete."
