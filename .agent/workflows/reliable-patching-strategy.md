---
description: Reliable Patching Strategy for Proxmox and Whitespace-Sensitive Files
---
# Reliable Patching Strategy (Series-Based)

This workflow generates clean, ordered patch series for Proxmox VE core files without trial-and-error.

## 0. Rules of the Road
- One logical change = one patch file.
- Use a numbered prefix to enforce order: `00-`, `10-`, `20-`, ...
- Keep patch paths relative to `/usr/share/perl5` because patch-manager applies with `-p0` from that base.
- Never hand-edit `@@ -L,C +L,C @@` or whitespace in a diff.
- If fuzz is required, treat it as a version mismatch and rebuild against the correct base.

## 1. Obtain the Clean Base (Per Target File)
Never trust `/usr/share/perl5/...` on a test host because files may already be patched.
- **Preferred action:** Extract pristine files from the exact package version you target.
- **Example (run on the test server, then copy to local):**
  - `ssh root@10.4.0.122 "mkdir -p /tmp/qemu-server && cd /tmp/qemu-server && apt download qemu-server && dpkg-deb -x qemu-server_*.deb /tmp/qemu-server"`
  - `scp root@10.4.0.122:/tmp/qemu-server/usr/share/perl5/PVE/QemuServer.pm ./QemuServer.pm.orig`
  - `scp root@10.4.0.122:/tmp/qemu-server/usr/share/perl5/PVE/QemuServer/OVMF.pm ./OVMF.pm.orig`
- **If you must use the test server:** extract from the downloaded `.deb` there, not from `/usr/share`.

## 2. Create the Modified Version
- **Action:** Copy `*.orig` to `*.mod` and edit the `*.mod` file only.
- **Command:** `cp QemuServer.pm.orig QemuServer.pm.mod`

## 3. Generate a Patch with Correct Headers
Use `diff --label` so the patch header is correct and no `sed` rewrite is needed.
- **Command (manual):**
  - `diff -u --label PVE/QemuServer.pm --label PVE/QemuServer.pm QemuServer.pm.orig QemuServer.pm.mod > debian/patches/30-qemuserver-foo.patch || true`
  - `diff -u --label PVE/QemuServer/OVMF.pm --label PVE/QemuServer/OVMF.pm OVMF.pm.orig OVMF.pm.mod > debian/patches/10-ovmf-bar.patch || true`
- **Command (helper script):**
  - `scripts/patch-series-helper.sh create --patch 30-qemuserver-foo.patch --target PVE/QemuServer.pm --orig QemuServer.pm.orig --mod QemuServer.pm.mod --update-series`
- **Command (batch list):**
  - `scripts/patch-series-helper.sh batch-create --list patch-list.txt --update-series`
- **List format (one per line):**
  - `30-qemuserver-foo.patch PVE/QemuServer.pm QemuServer.pm.orig QemuServer.pm.mod`
- **Constraint:** Do not modify the generated diff manually.

## 3a. Docker-Based Preparation (Recommended)
If you want fully reproducible bases, generate patches inside Docker and extract pristine files from Proxmox packages there.
- **Before Docker:** get package versions from the test server.
  - `ssh root@10.4.0.122 "dpkg-query -W -f='${Package} ${Version}\n' qemu-server libpve-storage-perl pve-manager" > pkg-versions.txt`
- **Repo note:** test server uses the `trixie` Proxmox repo; use the same suite in Docker.
- **Build the tools image (required once):**
  - `make tools-image`
- **Inputs:**
  - `patch-list.txt` entries: `<patch-name> <target-path> <mod-path>`
  - `pkg-map.txt` entries: `<target-path> <package-name>`
  - `pkg-versions.txt` entries: `<package-name> <version>`
- **Command:**
  - `scripts/prepare-patches-docker.sh --list patch-list.txt --pkgmap pkg-map.txt --versions pkg-versions.txt --key-file proxmox-release-trixie.gpg --update-series`
- **Cache:** Docker APT cache is stored under `.cache/docker-apt` by default.
- **Patch application check:**
  - `scripts/patch-apply-docker-check.sh`

## 4. Order the Series
Update `debian/patches/series` so patches apply in dependency order.
- **Rule:** A patch that introduces a helper must appear before patches that use it.
- **Example:**
  - `00-storage-plugin-san-flag.patch`
  - `10-ovmf-deactivate-san-vars.patch`
  - `20-cloudinit-deactivate-san.patch`
- **Helper:** `scripts/patch-series-helper.sh sort-series` (sorts within comment-separated blocks)

## 5. Validate Locally (No Fuzz)
- **Command (quick check):** `patch --dry-run -p0 < debian/patches/30-qemuserver-foo.patch`
- **Command (full series on host):** `scripts/patch-manager.sh apply`
- If a patch needs fuzz, rebuild it from a clean base.

## 6. Special Case: GUI Patch
The GUI patch targets `/usr/share/pve-manager/index.html.tpl` and is applied separately.
- Keep it as a standalone patch file (not part of the Perl series).
- Use absolute paths in the diff header to match the target location.

## 7. Benefits
- **Deterministic:** Patch series applies in a defined order with no surprises.
- **Stable:** Zero-fuzz patches mean higher confidence across upgrades.
- **Maintainable:** Each patch maps to a single change, making rollbacks and reviews easy.
