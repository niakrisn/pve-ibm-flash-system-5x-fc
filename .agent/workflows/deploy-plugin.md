---
description: Deploy IBM FlashSystem Plugin to Proxmox Server
---

# Deploy IBM FlashSystem Plugin to Proxmox Server

## ⚠️ CRITICAL SAFETY RULES

### 🔴 NEVER DO THIS:
```bash
# ❌ DANGEROUS - --delete flag on system directories will DELETE ALL system PVE modules!
rsync -avz --delete PVE/ root@10.4.0.122:/usr/share/perl5/PVE/
```

**Why dangerous:** The `--delete` flag removes files on the destination that don't exist in the source. Since we only have the plugin in `PVE/Storage/Custom/`, rsync will delete ALL other system modules (API2, CLI, QemuServer, etc.).

### ✅ ALWAYS DO THIS:
```bash
# ✅ SAFE - Copies only Custom storage plugins WITHOUT --delete
rsync -avz PVE/Storage/Custom/ root@10.4.0.122:/usr/share/perl5/PVE/Storage/Custom/
```

**Key points:**
- ✅ NO `--delete` flag
- ✅ Trailing slashes on both paths
- ✅ Syncs ONLY the Custom directory (not entire PVE tree)

## Deployment Steps

### 1. Deploy Plugin Modules

Copy **ONLY** the Custom storage plugins directory to the system:

```bash
# ✅ SAFE - Copies entire Custom directory recursively WITHOUT --delete
rsync -avz PVE/Storage/Custom/ root@10.4.0.122:/usr/share/perl5/PVE/Storage/Custom/
```

**Important:** Note the trailing slashes in both paths - this ensures we copy the **contents** of the Custom directory, not the directory itself.

**Files deployed:**
- `IBMFlashSystem.pm` - Main plugin file
- `IBMFlashSystem/Client.pm` - REST API client
- `IBMFlashSystem/Common.pm` - Common utilities
- `IBMFlashSystem/Volume.pm` - Volume operations
- `IBMFlashSystem/Snapshot.pm` - Snapshot operations
- `IBMFlashSystem/DeviceManager.pm` - Device management
- `IBMFlashSystem/FCMap.pm` - FlashCopy operations
- `IBMFlashSystem/Logger.pm` - Logging

### 2. Restart Proxmox Services

```bash
ssh root@10.4.0.122 "systemctl restart pvedaemon pveproxy pvestatd"
```

### 3. Verify Deployment

Check that services started successfully:

```bash
ssh root@10.4.0.122 "systemctl status pvedaemon pveproxy pvestatd --no-pager"
```

## Testing Deployment

### Deploy Tests to Remote Server

Use the `sync_tests.sh` script (safe, no --delete on system directories):

```bash
./scripts/sync_tests.sh
```

Or manually:

```bash
# Copy integration tests
rsync -avz t/integration/ root@10.4.0.122:/root/pve-ibm-flash-system-5x-fc/t/integration/

# Copy unit tests
rsync -avz t/unit/ root@10.4.0.122:/root/pve-ibm-flash-system-5x-fc/t/unit/
```

### Run Tests

```bash
# Run all scenario tests
ssh root@10.4.0.122 "cd /root/pve-ibm-flash-system-5x-fc && export PERL5LIB=\$(pwd):\$(pwd)/PVE/Storage/Custom && prove -v t/integration/scenarios/*.t"

# Run specific test
ssh root@10.4.0.122 "cd /root/pve-ibm-flash-system-5x-fc && export PERL5LIB=\$(pwd):\$(pwd)/PVE/Storage/Custom && prove -v t/integration/scenarios/01_basic_lifecycle.t"
```

## Rollback

If deployment fails, restore from backup:

```bash
# Restore plugin from backup (if exists)
ssh root@10.4.0.122 "cp -r /usr/share/perl5/PVE/Storage/Custom/IBMFlashSystem.backup/* /usr/share/perl5/PVE/Storage/Custom/IBMFlashSystem/"

# Restart services
ssh root@10.4.0.122 "systemctl restart pvedaemon pveproxy pvestatd"
```

## Environment

- **Remote server:** `root@10.4.0.122`
- **SSH key:** `~/.ssh/id_ed25519`
- **Plugin path:** `/usr/share/perl5/PVE/Storage/Custom/IBMFlashSystem/`
- **Test path:** `/root/pve-ibm-flash-system-5x-fc/`
- **Storage API:** `10.0.0.222` (user: `pvcu`, password: `qenwu2-Wiwseb-nosgim`)

## Troubleshooting

### Services won't start after deployment

Check logs:
```bash
ssh root@10.4.0.122 "journalctl -u pvedaemon -n 50 --no-pager"
```

Check for syntax errors:
```bash
ssh root@10.4.0.122 "perl -c /usr/share/perl5/PVE/Storage/Custom/IBMFlashSystem.pm"
```

### Plugin not loading

Verify file permissions:
```bash
ssh root@10.4.0.122 "ls -la /usr/share/perl5/PVE/Storage/Custom/IBMFlashSystem/"
```

Files should be owned by `root:root` with mode `644`.
