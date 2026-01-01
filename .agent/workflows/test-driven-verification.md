---
description: IBM FlashSystem Test-Driven Verification Lifecycle
---
// turbo-all
# Test-Driven Verification Workflow

This workflow ensures that every integration test validates the EXACT state of the VM, SAN volumes, and host devices.

## 0. Test Synchronization (CRITICAL)
Before ANY test execution, ensure test files are correctly synced to the remote host:

**Use the dedicated sync script:**
```bash
./scripts/sync_tests.sh
```

**What it does:**
1. Removes orphaned test helper files from remote root directory (e.g., `StorageHelpers.pm`, `VMHelpers.pm`).
2. Syncs ONLY the `t/integration/` directory structure using `rsync --checksum --delete`.
3. Verifies no duplicate files exist in wrong locations (e.g., `/root/pve-ibm-flash-system-5x-fc/StorageHelpers.pm`).

**Why this matters:**
- Perl's `@INC` includes `/root/pve-ibm-flash-system-5x-fc` BEFORE `t/integration/lib`.
- If a duplicate `StorageHelpers.pm` exists in the root, Perl will load the WRONG version.
- This caused 4 consecutive test failures due to stale API code.

**Manual verification (if needed):**
```bash
ssh root@10.4.0.122 "find /root/pve-ibm-flash-system-5x-fc -maxdepth 2 -name 'StorageHelpers.pm' -o -name 'VMHelpers.pm'"
# Expected output: ONLY /root/pve-ibm-flash-system-5x-fc/t/integration/lib/StorageHelpers.pm
```

## 1. Zero-Orphan Baseline
Before ANY test execution:
- Run a deep cleanup of the host.
- Terminate all lingering `qm` processes.
- Clear ALL host-SAN mappings if no active VMs are using them.
- Purge all test volumes (`vm-9999-*`, etc.) from the SAN.

## 2. Granular State Verification
Every test MUST verify the specific state transition:
- **CREATE**: `qm create` success -> Volumes exist on SAN -> **NO mappings** -> **NO host devices** -> VM status: `stopped`.
- **START**: `qm start` success -> Task status `OK` -> Mappings exist -> Multipath devices online and writable -> VM status: `running`.
- **STOP**: `qm stop` success -> Task status `OK` -> Mappings removed -> Host devices removed -> VM status: `stopped`.
- **DESTROY**: `qm destroy` success -> Task status `OK` -> Volumes purged from SAN -> VM config gone.
- **SNAPSHOT**: `qm snapshot` success -> FlashCopy mappings exist on SAN -> Snapshot volumes exist -> VM status: `running` (or same as before).
- **CLONE**: `qm clone` success -> New volumes created on SAN -> Correct parent/child relationships -> VM status: `stopped`.
- **TEMPLATE**: `qm template` success -> Volumes marked as read-only/base -> VM status: `template`.

## 3. Log & Task Analysis
Mandatory checks for every operation:
- **Proxmox Tasks**: Verify UPID success (journal/API).
- **Plugin Logs**: Verify `/var/log/pve-storage-ibm.log` contains expected API calls (e.g., `mkvolume`, `mkvdiskhostmap`) without errors.
- **VM State**: Verify `qm status` matches expected lifecycle stage.

## 4. Fail-Fast & Report
If ANY check fails:
1. **STOP IMMEDIATELY**: Do not continue with subsequent test steps.
2. **Collect Evidence**:
   - Host: `multipath -ll`, `lsblk -S`, `dmesg | tail -n 50`.
   - SAN: List mappings for the specific volume and the node.
   - Proxmox: `qm config <vmid>`, `journalctl -n 100`.
3. **Draft Report**: Present a comprehensive summary of the "As-Is" vs "To-Be" state.
4. **Wait for Approval**: Do not attempt auto-remediation without explicit user instruction.

## 4. Modularity
All verification logic must reside in `t/integration/lib/StateVerifier.pm` to ensure consistency across the entire test suite.
