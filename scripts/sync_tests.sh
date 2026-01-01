#!/bin/bash
# Reliable test synchronization script
# This script ensures ONLY the correct test files are synced to the remote host

set -euo pipefail

REMOTE_HOST="${REMOTE_HOST:-root@10.4.0.122}"
REMOTE_DIR="/root/pve-ibm-flash-system-5x-fc"
LOCAL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "=== Syncing test files to ${REMOTE_HOST}:${REMOTE_DIR} ==="

# Step 1: Clean up any orphaned files in the remote root directory
echo "Step 1: Removing orphaned test helper files from remote root..."
ssh "${REMOTE_HOST}" "cd ${REMOTE_DIR} && rm -vf StorageHelpers.pm VMHelpers.pm StateVerifier.pm FCHelpers.pm TestEnv.pm 2>/dev/null || true"

# Step 2: Sync ONLY the t/integration directory structure
echo "Step 2: Syncing t/integration directory..."
rsync -avz --checksum \
  --delete \
  --exclude='*.swp' \
  --exclude='.DS_Store' \
  "${LOCAL_DIR}/t/integration/" \
  "${REMOTE_HOST}:${REMOTE_DIR}/t/integration/"

# Step 3: Verify no duplicate files exist in wrong locations
echo "Step 3: Verifying no duplicate test helper files..."
DUPLICATES=$(ssh "${REMOTE_HOST}" "find ${REMOTE_DIR} -maxdepth 2 -name 'StorageHelpers.pm' -o -name 'VMHelpers.pm' -o -name 'StateVerifier.pm' | grep -v 't/integration/lib' || true")

if [ -n "$DUPLICATES" ]; then
    echo "❌ ERROR: Found duplicate test helper files in wrong locations:"
    echo "$DUPLICATES"
    echo ""
    echo "These files will interfere with Perl's module loading."
    echo "Please remove them manually or run:"
    echo "  ssh ${REMOTE_HOST} 'cd ${REMOTE_DIR} && rm -f StorageHelpers.pm VMHelpers.pm StateVerifier.pm FCHelpers.pm TestEnv.pm t/integration/StorageHelpers.pm t/integration/VMHelpers.pm'"
    exit 1
fi

echo "✅ Sync complete. All test files are in correct locations."
echo ""
echo "To run tests:"
echo "  ssh ${REMOTE_HOST} 'cd ${REMOTE_DIR} && export PERL5LIB=\$(pwd):\$(pwd)/PVE/Storage/Custom && prove -v t/integration/lifecycle/20_vm_start.t'"
