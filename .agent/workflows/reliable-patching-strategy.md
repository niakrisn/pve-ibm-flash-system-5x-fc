---
description: Reliable Patching Strategy for Proxmox and Whitespace-Sensitive Files
---
# Reliable Patching Strategy (The Gold Standard)

This workflow ensures that patches for Proxmox VE core files (or any whitespace-sensitive environment) are generated reliably without trial-and-error.

## 1. Obtain the Base (Original) File
Never assume local files or manual copies have correct whitespace/line endings. 
- **Action:** Download the original file directly from the target server or reinstall the package to get a "clean" copy.
- **Command:** `scp root@10.4.0.122:/usr/share/perl5/PVE/API2/Qemu.pm ./Qemu.pm.orig`
- **If "Dirty":** `ssh root@10.4.0.122 "apt install --reinstall qemu-server"` first.

## 2. Create the Modified Version
- **Action:** Copy the original to a mod file: `cp file.pm.orig file.pm.mod`.
- **Action:** Edit `file.pm.mod` using standard tools. This preserves the original line endings (LF vs CRLF) and indentation style.

## 3. Generate the Unified Diff
- **Action:** Use the `diff` tool to generate a standard unified patch.
- **Command:** `diff -u file.pm.orig file.pm.mod > patch_name.diff || true`
- **Constraint:** NEVER manually edit the `@@ -L,C +L,C @@` context or indentation in the resulting `.diff` file.

## 4. Finalize for Debian Package
- **Action:** Update the file paths in the diff header to match the expected structure in `debian/patches/` (usually relative to the source root).
- **Command Shorthand:** `sed -i 's|--- Qemu.pm.orig|--- PVE/API2/Qemu.pm|; s|+++ Qemu.pm.mod|+++ PVE/API2/Qemu.pm|' patch_name.diff`

## 5. Benefits
- **Zero Fuzz:** Patch applies cleanly because it was built on the exact same context.
- **Speed:** Reduces 2 hours of manual cleanup to 2 minutes of automated commands.
- **Modular:** Easy to combine multiple files into one monolithic patch by appending outputs.
