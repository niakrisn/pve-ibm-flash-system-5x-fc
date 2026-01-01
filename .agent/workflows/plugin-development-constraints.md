---
description: IBM FlashSystem Plugin Development Constraints
---
# Plugin Development Constraints & Best Practices

To maintain architectural integrity and prevent resource leaks, the following rules MUST be followed during development:

## 1. No Internal Activation/Deactivation
- **RULE:** NEVER call `activate_volume` or `deactivate_volume` (or their internal equivalents) from within other plugin methods (like `alloc_image`, `free_image`, or `clone_image`).
- **RATIONALE:** Volume lifecycle management is the sole responsibility of Proxmox VE core. The plugin only implements the mechanics. Internal calls create "hidden" states that PVE cannot track, lead to race conditions, and cause orphaned block devices if one layer fails while the other assumes success.
- **EXCEPTION:** Only `_path` and `_wait_for_multipath_device` should deal with host-level device state, and only when explicitly triggered by a PVE-level activation.

## 2. PVE Core Responsibility
- If a cleanup is missing (e.g., during a failed clone or VM destruction), the fix MUST be applied to the **Proxmox VE core** (via patches to `PVE::API2::Qemu`, `PVE::QemuServer`, etc.), NOT hardcoded into the plugin's `free_image` or similar methods.

## 3. Atomic Operations
- Plugin methods should be as atomic as possible. If an operation requires multiple API calls to the FlashSystem, ensure proper error handling and logging, but do not attempt "magic" host-level cleanups that PVE isn't aware of.

## 4. State Verification
- Always assume the host environment might be "dirty". Prefer searching for existing state (WWIDs, multipath maps) over assuming a clean slate, but do not take destructive actions on devices not explicitly managed in the current task.
