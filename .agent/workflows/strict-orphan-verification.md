---
description: Strict Zero-Orphan Verification and Fail-Fast Troubleshooting
---
# Strict Zero-Orphan Verification Workflow

This workflow mandates a "stop-and-dump" approach to prevent block device leaks on the Proxmox host.

## 1. Clean Baseline (Pre-Test)
Before starting ANY test session, the host MUST be clean:
- `multipath -ll` returns NO devices associated with the SAN storage.
- `lsblk -S` shows no stale SCSI disks (`sdX`) with I/O errors.
- `/dev/disk/by-id/` contains no `scsi-3...` links for deleted volumes.
- FlashSystem: All test volumes/hostmaps are purged.

## 2. Fail-Fast Execution
Run tests in small, granular steps (e.g., one `.t` file at a time or even specific actions).
- **CRITICAL:** If a command fails (exit code != 0, or timeout), **STOP IMMEDIATELY**.
- Do NOT attempt to "recover" or "clean up" blindly.

## 3. Fact-Gathering (The "Dump")
Upon failure or discovery of an orphan, execute this status dump:

### A. Host OS State
- `multipath -ll` (Check for active/failed mappings)
- `lsblk -S` (Check for SCSI devices and their HCTL/Serial)
- `ls -l /dev/disk/by-id/scsi-*` (Check for persistent symlinks)
- `dmesg | tail -n 50` (Check for SCSI/Multipath transport errors)

### B. Proxmox State
- `qm config <VMID>` (Current VM configuration)
- `cat /etc/pve/storage.cfg` (Storage backend config)
- `journalctl -u pve-cluster -u pve-ha-lrm -n 100`

### C. Plugin & Storage State
- `cat /var/log/pve-storage-ibm.log | tail -n 100` (Plugin internal logs)
- **API Call:** List all volumes on the pool.
- **API Call:** List all host mappings for the node.
- **Compare:** Does a mapping exist on the SAN for a device NOT seen on the host? Or vice versa?

## 4. Analysis
- **Orphan with Mapping:** `deactivate_volume` was likely never called or failed via API.
- **Orphan without Mapping (DEAD):** `rmvdiskhostmap` succeeded, but the plugin failed to remove the local OS devices (`_remove_scsi_devices` skipped or failed).
- **Mapping without Orphan:** `activate_volume` (map) succeeded, but the host never scanned or discovered the device.
