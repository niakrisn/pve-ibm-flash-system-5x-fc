#!/bin/bash
# Comprehensive SAN/Host Cleanup Script
# Purges test-related volumes and orphaned devices from IBM FlashSystem and PVE Host

STOREID="fs-01"
CONFIG_FILE="/etc/pve/ibm-fs5x-tests.conf"

# Read test pool from config (default: pve-storage-test-pool)
if [ -f "$CONFIG_FILE" ]; then
    TEST_POOL=$(jq -r '.test_pool // "pve-storage-test-pool"' "$CONFIG_FILE" 2>/dev/null)
else
    TEST_POOL="pve-storage-test-pool"
fi

echo "Starting 'Nuclear Cleanup' for $STOREID (pool: $TEST_POOL)..."

# 1. Stop and Destroy Test VMs from Pool
echo "Phase 1: Stopping and destroying test VMs from pool '$TEST_POOL'..."

# Get all VMs in the test pool
TEST_VMS=$(pvesh get /pools/$TEST_POOL --output-format json 2>/dev/null | jq -r '.members[]? | select(.type == "qemu") | .vmid' 2>/dev/null || true)

# FALLBACK: Explicitly check for known test VMIDs if they are not in the pool
# This handles orphans from previous runs or bugs in pool assignment
FALLBACK_VMIDS="9999 9998 9001 9002"
for fvmid in $FALLBACK_VMIDS; do
    if qm status "$fvmid" &>/dev/null; then
        echo "Found orphaned test VM $fvmid (not in pool), adding to cleanup list..."
        TEST_VMS="$TEST_VMS $fvmid"
    fi
done

# Deduplicate VMIDs
TEST_VMS=$(echo "$TEST_VMS" | tr ' ' '\n' | sort -u | tr '\n' ' ')

if [ -n "$TEST_VMS" ]; then
    for vmid in $TEST_VMS; do
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
            echo "Destroying VM $vmid..."
            qm destroy "$vmid" --destroy-unreferenced-disks 1 --purge 1 2>/dev/null
        fi
        # Hard cleanup of config if qm destroy failed or if it's just a file (e.g. template)
        if [ -f "/etc/pve/qemu-server/$vmid.conf" ]; then
            echo "Hard removing stale config or template for VM $vmid..."
            rm -f "/etc/pve/qemu-server/$vmid.conf"
        fi
    done
else
    echo "No test VMs found (pool or fallback)"
fi

# 2. Purge Volumes and Mappings from Storage (Safety Net)
echo "Phase 2: Purging residual volumes from $STOREID..."

# Get all VMIDs from pool (including those that might have failed to destroy)
ALL_VMIDS=$(pvesh get /pools/$TEST_POOL --output-format json 2>/dev/null | jq -r '.members[]? | select(.type == "qemu") | .vmid' 2>/dev/null || true)

# Also scan for any volumes matching test patterns (vm-9*, base-9*, snap-vm-9*)
# This catches orphaned volumes from VMs that were removed from pool but left volumes
echo "Scanning for test-pattern volumes on $STOREID..."
TEST_VOLS=$(pvesm list "$STOREID" 2>/dev/null | awk '$1 ~ /:(vm-9|base-9|snap-vm-9)/ {print $1}' || true)

# Combine VMID-based and pattern-based volume lists
for vmid in $ALL_VMIDS; do
    echo "Scanning for residual volumes belonging to VM $vmid..."
    VOLS=$(pvesm list "$STOREID" --vmid "$vmid" 2>/dev/null | awk 'NR>1 {print $1}' || true)
    
    # Cleanup FlashCopy mappings using the plugin's own library
    echo "Scanning for orphaned FlashCopy mappings for VM $vmid..."
    perl -I. -I/usr/share/pve-ibm-fs5x-fc-plugin-tests/lib -MPVE::Storage::Custom::IBMFlashSystem::FCMap -MTestEnv -e '
        my $vmid = "'"$vmid"'";
        my $env = TestEnv->setup();
        PVE::Storage::Custom::IBMFlashSystem::FCMap::remove_fcmaps_for_vm_volumes("PVE::Storage::Custom::IBMFlashSystem", $env->{scfg}, $env->{storeid}, $vmid);
    ' 2>/dev/null

    for volid in $VOLS; do
        echo "Removing residual volume: $volid"
        pvesm free "$volid" 2>/dev/null || true
    done
done

# Clean up pattern-matched volumes
if [ -n "$TEST_VOLS" ]; then
    echo "Removing pattern-matched test volumes..."
    for volid in $TEST_VOLS; do
        echo "Removing test volume: $volid"
        pvesm free "$volid" 2>/dev/null || true
    done
fi

# 3. Cleanup Host Devices (Multipath & SCSI)
echo "Phase 3: Cleaning up host devices..."
# Удаляем сиротливые устройства (без томов на СХД)
perl -I. -I/usr/share/pve-ibm-fs5x-fc-plugin-tests/lib -MVMHelpers -MTestEnv -e '
    $env = TestEnv->setup();
    VMHelpers::cleanup_orphan_fc_devices($env);
' 2>/dev/null

# Explicit Multipath Flush
multipath -F 2>/dev/null || true

# 4. Clear Plugin Logs
LOG_FILE="/var/log/pve-storage-ibm.log"
if [ -f "$LOG_FILE" ]; then
    echo "Clearing plugin log: $LOG_FILE..."
    true > "$LOG_FILE"
fi

echo "Cleanup complete."
