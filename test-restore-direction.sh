#!/bin/bash
# Test script to verify if startfcmap -restore changes copy direction
# Creates test volumes directly on storage, no VM needed

set -e

# ============================================================================
# CONFIGURATION - FILL THESE VALUES
# ============================================================================

# Test configuration
TEST_DISK_SIZE_MB=128
PATTERN_SIZE_MB=1  # Only write 1MB pattern to each disk

# Storage configuration
POOL_NAME="pool-pvc-01"
SSH_STORAGE="<STORAGE_IP>"  # e.g., 10.0.0.222
SSH_HOST="root@10.4.0.122"

# Test volume names (unique per run using PID)
SOURCE_VOL="test-restore-source-$$"
TARGET_VOL="test-restore-target-$$"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# ============================================================================
# HELPER FUNCTIONS
# ============================================================================

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

press_enter() {
    echo ""
    read -p "Press ENTER to continue..."
}

confirm_action() {
    local action="$1"
    echo ""
    log_warning "CONFIRMATION REQUIRED:"
    log_warning "$action"
    read -p "Execute this action? (yes/no): " CONFIRM
    if [ "$CONFIRM" != "yes" ]; then
        log_error "Action cancelled by user"
        exit 1
    fi
}

cleanup() {
    log_warning "Cleaning up test resources..."

    # Get hostname
    HOSTNAME=$(ssh $SSH_HOST "hostname -s")

    # Unmap volumes if mapped
    ssh $SSH_STORAGE "rmvdiskhostmap -host $HOSTNAME $SOURCE_VOL 2>/dev/null || true"
    ssh $SSH_STORAGE "rmvdiskhostmap -host $HOSTNAME $TARGET_VOL 2>/dev/null || true"

    # Remove multipath devices
    if [ -n "$SOURCE_DEVICE" ]; then
        ssh $SSH_HOST "multipath -f $SOURCE_DEVICE 2>/dev/null || true"
    fi
    if [ -n "$TARGET_DEVICE" ]; then
        ssh $SSH_HOST "multipath -f $TARGET_DEVICE 2>/dev/null || true"
    fi

    # Remove FlashCopy mapping if exists
    if [ -n "$FCMAP_ID" ]; then
        ssh $SSH_STORAGE "stopfcmap $FCMAP_ID 2>/dev/null || true"
        ssh $SSH_STORAGE "rmfcmap -force $FCMAP_ID 2>/dev/null || true"
    fi

    # Delete volumes
    ssh $SSH_STORAGE "rmvdisk -force $SOURCE_VOL 2>/dev/null || true"
    ssh $SSH_STORAGE "rmvdisk -force $TARGET_VOL 2>/dev/null || true"

    log_success "Cleanup completed"
}

trap cleanup EXIT

# ============================================================================
# SAFETY CHECKS
# ============================================================================

log_info "=========================================="
log_info "SAFETY CHECKS"
log_info "=========================================="

# Check 1: Verify pool exists
log_info "Checking if pool '$POOL_NAME' exists..."
if ! ssh $SSH_STORAGE "lsmdiskgrp $POOL_NAME >/dev/null 2>&1"; then
    log_error "Pool '$POOL_NAME' does not exist on storage!"
    log_error "Available pools:"
    ssh $SSH_STORAGE "lsmdiskgrp -delim : | cut -d':' -f1"
    exit 1
fi
log_success "Pool exists"

# Check 2: Show pool capacity
log_info "Checking pool capacity..."
POOL_INFO=$(ssh $SSH_STORAGE "lsmdiskgrp $POOL_NAME")
POOL_CAPACITY=$(echo "$POOL_INFO" | grep "^capacity " | awk '{print $2}')
POOL_FREE=$(echo "$POOL_INFO" | grep "^free_capacity " | awk '{print $2}')
log_info "Pool capacity: ${POOL_CAPACITY}GB"
log_info "Pool free: ${POOL_FREE}GB"

TOTAL_SIZE_MB=$(($TEST_DISK_SIZE_MB * 2))
TOTAL_SIZE_GB=$(echo "scale=2; $TOTAL_SIZE_MB / 1024" | bc)
log_info "Test will create: ${TOTAL_SIZE_MB}MB (${TOTAL_SIZE_GB}GB) in 2 volumes"

# Check 3: Verify test volumes don't already exist
log_info "Checking for leftover test volumes..."
if ssh $SSH_STORAGE "lsvdisk $SOURCE_VOL >/dev/null 2>&1"; then
    log_error "Volume '$SOURCE_VOL' already exists!"
    log_error "Please delete it first or wait for script cleanup from previous run"
    exit 1
fi

if ssh $SSH_STORAGE "lsvdisk $TARGET_VOL >/dev/null 2>&1"; then
    log_error "Volume '$TARGET_VOL' already exists!"
    log_error "Please delete it first or wait for script cleanup from previous run"
    exit 1
fi
log_success "No leftover test volumes found"

# Check 4: Show what will be tested
echo ""
log_warning "=============================================="
log_warning "THIS SCRIPT WILL:"
log_warning "1. Create 2 test volumes (${TEST_DISK_SIZE_MB}MB each) in pool '$POOL_NAME'"
log_warning "2. Write ${PATTERN_SIZE_MB}MB of test data to each volume"
log_warning "3. Create FlashCopy mapping and test -restore flag"
log_warning "4. Cleanup all test resources when done"
log_warning ""
log_warning "SAFE: Script only touches test volumes with unique names"
log_warning "SAFE: Will NOT modify any existing vm-*, base-*, snap-* volumes"
log_warning "=============================================="
echo ""

read -p "Continue with test? (yes/no): " CONFIRM
if [ "$CONFIRM" != "yes" ]; then
    log_error "Test cancelled by user"
    exit 0
fi

echo ""

# ============================================================================
# STEP 1: Create test volumes
# ============================================================================

log_info "=========================================="
log_info "Step 1: Creating test volumes on storage"
log_info "=========================================="

confirm_action "CREATE source volume: $SOURCE_VOL (${TEST_DISK_SIZE_MB}MB) in pool $POOL_NAME"
log_info "Creating source volume: $SOURCE_VOL (${TEST_DISK_SIZE_MB}MB)..."
ssh $SSH_STORAGE "mkvolume -name $SOURCE_VOL -pool $POOL_NAME -size $TEST_DISK_SIZE_MB -unit mb -thin"
log_success "Source volume created"

confirm_action "CREATE target volume: $TARGET_VOL (${TEST_DISK_SIZE_MB}MB) in pool $POOL_NAME"
log_info "Creating target volume: $TARGET_VOL (${TEST_DISK_SIZE_MB}MB)..."
ssh $SSH_STORAGE "mkvolume -name $TARGET_VOL -pool $POOL_NAME -size $TEST_DISK_SIZE_MB -unit mb -thin"
log_success "Target volume created"

press_enter

# ============================================================================
# STEP 2: Get volume UIDs
# ============================================================================

log_info "=========================================="
log_info "Step 2: Getting volume UIDs"
log_info "=========================================="

log_info "Getting UID for source volume..."
SOURCE_UID=$(ssh $SSH_STORAGE "lsvdisk $SOURCE_VOL | grep vdisk_UID | awk '{print \$2}'")
log_success "Source volume UID: $SOURCE_UID"

log_info "Getting UID for target volume..."
TARGET_UID=$(ssh $SSH_STORAGE "lsvdisk $TARGET_VOL | grep vdisk_UID | awk '{print \$2}'")
log_success "Target volume UID: $TARGET_UID"

# Device paths (UID in lowercase with prefix '3')
SOURCE_DEVICE="/dev/mapper/3${SOURCE_UID,,}"
TARGET_DEVICE="/dev/mapper/3${TARGET_UID,,}"

log_info "Source device path: $SOURCE_DEVICE"
log_info "Target device path: $TARGET_DEVICE"

press_enter

# ============================================================================
# STEP 3: Map volumes to host
# ============================================================================

log_info "=========================================="
log_info "Step 3: Mapping volumes to host"
log_info "=========================================="

HOSTNAME=$(ssh $SSH_HOST "hostname -s")
log_info "Host name: $HOSTNAME"

confirm_action "MAP source volume $SOURCE_VOL to host $HOSTNAME"
log_info "Mapping source volume to host..."
ssh $SSH_STORAGE "mkvdiskhostmap -host $HOSTNAME $SOURCE_VOL"

confirm_action "MAP target volume $TARGET_VOL to host $HOSTNAME"
log_info "Mapping target volume to host..."
ssh $SSH_STORAGE "mkvdiskhostmap -host $HOSTNAME $TARGET_VOL"

log_info "Waiting for devices to appear..."
sleep 3

log_info "Rescanning devices on host..."
ssh $SSH_HOST "multipath -v2 >/dev/null 2>&1"
sleep 2

log_info "Verifying devices..."
ssh $SSH_HOST "ls -la $SOURCE_DEVICE $TARGET_DEVICE"

log_success "Volumes mapped successfully"

press_enter

# ============================================================================
# STEP 4: Write patterns to volumes
# ============================================================================

log_info "=========================================="
log_info "Step 4: Writing unique patterns to volumes"
log_info "=========================================="

log_info "Writing pattern 'S' (SOURCE) to source volume..."
ssh $SSH_HOST "dd if=/dev/zero bs=1M count=$PATTERN_SIZE_MB 2>/dev/null | tr '\\0' 'S' | dd of=$SOURCE_DEVICE bs=1M count=$PATTERN_SIZE_MB 2>/dev/null && sync"

log_info "Verifying source data..."
SOURCE_DATA=$(ssh $SSH_HOST "dd if=$SOURCE_DEVICE bs=1 count=10 2>/dev/null | od -An -c | tr -d ' '")
log_success "Source contains: $SOURCE_DATA"

log_info "Writing pattern 'T' (TARGET) to target volume..."
ssh $SSH_HOST "dd if=/dev/zero bs=1M count=$PATTERN_SIZE_MB 2>/dev/null | tr '\\0' 'T' | dd of=$TARGET_DEVICE bs=1M count=$PATTERN_SIZE_MB 2>/dev/null && sync"

log_info "Verifying target data..."
TARGET_DATA=$(ssh $SSH_HOST "dd if=$TARGET_DEVICE bs=1 count=10 2>/dev/null | od -An -c | tr -d ' '")
log_success "Target contains: $TARGET_DATA"

press_enter

# ============================================================================
# STEP 5: Unmap volumes from host
# ============================================================================

log_info "=========================================="
log_info "Step 5: Unmapping volumes from host"
log_info "=========================================="

confirm_action "UNMAP volumes from host $HOSTNAME"
log_info "Unmapping volumes..."
ssh $SSH_STORAGE "rmvdiskhostmap -host $HOSTNAME $SOURCE_VOL"
ssh $SSH_STORAGE "rmvdiskhostmap -host $HOSTNAME $TARGET_VOL"

log_info "Removing multipath devices..."
ssh $SSH_HOST "multipath -f $SOURCE_DEVICE 2>/dev/null || true"
ssh $SSH_HOST "multipath -f $TARGET_DEVICE 2>/dev/null || true"

log_success "Volumes unmapped"

press_enter

# ============================================================================
# STEP 6: Create FlashCopy mapping
# ============================================================================

log_info "=========================================="
log_info "Step 6: Creating FlashCopy mapping"
log_info "=========================================="

confirm_action "CREATE FlashCopy mapping: $SOURCE_VOL → $TARGET_VOL (copyrate=150)"
log_info "Creating mapping: $SOURCE_VOL → $TARGET_VOL (copyrate=150)..."
FCMAP_OUTPUT=$(ssh $SSH_STORAGE "mkfcmap -source $SOURCE_VOL -target $TARGET_VOL -copyrate 150")
echo "$FCMAP_OUTPUT"

# Extract FlashCopy ID
FCMAP_ID=$(echo "$FCMAP_OUTPUT" | grep -oP "FlashCopy Mapping, id \[\K[0-9]+" || echo "$FCMAP_OUTPUT" | grep -oP "id \[\K[0-9]+")
log_success "FlashCopy mapping ID: $FCMAP_ID"

press_enter

# ============================================================================
# STEP 7: CRITICAL TEST - Start with -prep -restore
# ============================================================================

log_info "=========================================="
log_info "Step 7: CRITICAL TEST - Starting with -prep -restore"
log_info "=========================================="

log_warning "This is the critical test!"
log_warning "Monitoring progress..."

confirm_action "START FlashCopy mapping $FCMAP_ID with flags -prep -restore (THIS IS THE TEST!)"
log_info "Starting FlashCopy with -prep -restore flags..."
ssh $SSH_STORAGE "startfcmap -prep -restore $FCMAP_ID"

# Monitor progress
echo ""
while true; do
    FCMAP_STATUS=$(ssh $SSH_STORAGE "lsfcmap $FCMAP_ID")

    STATUS=$(echo "$FCMAP_STATUS" | grep "^status " | awk '{print $2}')
    PROGRESS=$(echo "$FCMAP_STATUS" | grep "^progress " | awk '{print $2}' || echo "0")
    RESTORE_PROGRESS=$(echo "$FCMAP_STATUS" | grep "^restore_progress " | awk '{print $2}' || echo "0")
    RESTORING=$(echo "$FCMAP_STATUS" | grep "^restoring " | awk '{print $2}' || echo "no")

    echo -ne "\rStatus: $STATUS | Progress: $PROGRESS | Restore Progress: $RESTORE_PROGRESS | Restoring: $RESTORING    "

    # Check if completed
    if [ "$PROGRESS" = "100" ] || [ "$RESTORE_PROGRESS" = "100" ]; then
        echo ""
        log_success "Copy completed!"
        break
    fi

    # Also break if status is idle_or_copied
    if [ "$STATUS" = "idle_or_copied" ]; then
        echo ""
        log_success "Copy completed (status: idle_or_copied)!"
        break
    fi

    sleep 2
done

echo ""
log_info "Final FlashCopy status:"
ssh $SSH_STORAGE "lsfcmap $FCMAP_ID | grep -E 'status|progress|restoring'"

press_enter

# ============================================================================
# STEP 8: Map volumes again and check results
# ============================================================================

log_info "=========================================="
log_info "Step 8: Checking results"
log_info "=========================================="

confirm_action "MAP volumes to host for reading results"
log_info "Mapping volumes to host for reading..."
ssh $SSH_STORAGE "mkvdiskhostmap -host $HOSTNAME $SOURCE_VOL"
ssh $SSH_STORAGE "mkvdiskhostmap -host $HOSTNAME $TARGET_VOL"

log_info "Waiting for devices..."
sleep 3
ssh $SSH_HOST "multipath -v2 >/dev/null 2>&1"
sleep 2

log_info "Reading source data after FlashCopy..."
SOURCE_DATA_AFTER=$(ssh $SSH_HOST "dd if=$SOURCE_DEVICE bs=1 count=10 2>/dev/null | od -An -c | tr -d ' '")

log_info "Reading target data after FlashCopy..."
TARGET_DATA_AFTER=$(ssh $SSH_HOST "dd if=$TARGET_DEVICE bs=1 count=10 2>/dev/null | od -An -c | tr -d ' '")

# ============================================================================
# RESULTS ANALYSIS
# ============================================================================

echo ""
echo "=============================================="
echo "RESULTS:"
echo "=============================================="
echo ""
echo "BEFORE FlashCopy:"
echo "  Source volume: $SOURCE_DATA (S = source pattern)"
echo "  Target volume: $TARGET_DATA (T = target pattern)"
echo ""
echo "AFTER FlashCopy with -prep -restore:"
echo "  Source volume: $SOURCE_DATA_AFTER"
echo "  Target volume: $TARGET_DATA_AFTER"
echo ""
echo "=============================================="

# Determine direction
if [[ "$SOURCE_DATA_AFTER" == *"S"* ]] && [[ "$TARGET_DATA_AFTER" == *"S"* ]]; then
    log_success "RESULT: -restore does NOT change direction"
    log_info "Data copied: Source → Target (normal FlashCopy)"
    log_info "Source kept 'S' pattern, Target now has 'S' pattern"
elif [[ "$SOURCE_DATA_AFTER" == *"T"* ]] && [[ "$TARGET_DATA_AFTER" == *"T"* ]]; then
    log_warning "RESULT: -restore CHANGES direction!"
    log_info "Data copied: Target → Source (reverse FlashCopy)"
    log_info "Source now has 'T' pattern, Target kept 'T' pattern"
    log_warning "This means -restore enables ROLLBACK functionality!"
else
    log_error "UNEXPECTED RESULT! Data:"
    log_error "Source: $SOURCE_DATA_AFTER"
    log_error "Target: $TARGET_DATA_AFTER"
fi

echo ""
echo "=============================================="

# Cleanup will happen automatically via trap
