---
description: Deploy IBM FlashSystem Plugin to Proxmox Server
---

## ⚠️ CRITICAL SAFETY RULES

### 🔴 NEVER DO THIS:
```bash
# ❌ DANGEROUS - --delete flag on system directories will DELETE ALL system PVE modules!
rsync -avz --delete PVE/ root@10.4.0.122:/usr/share/perl5/PVE/
```

**Why dangerous:** The `--delete` flag removes files on the destination that don't exist in the source.

**Key points:**
- ✅ Используй ТОЛЬКО пакетную установку
- ✅ Никогда не копируй файлы напрямую через rsync/scp

## Deployment Steps

### 1. Build Packages
// turbo
```bash
make package-docker
```

### 2. Deploy Plugin Package
```bash
ssh -i ~/.ssh/id_ed25519 root@10.4.0.122 "rm -f /tmp/pve-ibm-fs5x-fc-plugin*.deb"
scp -i ~/.ssh/id_ed25519 output/pve-ibm-fs5x-fc-plugin_*.deb root@10.4.0.122:/tmp/
ssh -i ~/.ssh/id_ed25519 root@10.4.0.122 "dpkg -i /tmp/pve-ibm-fs5x-fc-plugin_*.deb && systemctl restart pvedaemon pveproxy pvestatd"
```

### 3. Deploy Tests Package (Optional)
```bash
ssh -i ~/.ssh/id_ed25519 root@10.4.0.122 "rm -f /tmp/pve-ibm-fs5x-fc-plugin-tests*.deb"
scp -i ~/.ssh/id_ed25519 output/pve-ibm-fs5x-fc-plugin-tests_*.deb root@10.4.0.122:/tmp/
ssh -i ~/.ssh/id_ed25519 root@10.4.0.122 "dpkg -i /tmp/pve-ibm-fs5x-fc-plugin-tests_*.deb"
```

### 4. Configure Tests (if not done before)
```bash
ssh -i ~/.ssh/id_ed25519 root@10.4.0.122 'echo "{\"flashsystem_storage\": \"fs-01\", \"local_storage\": \"local-lvm\"}" > /etc/pve/ibm-fs5x-tests.conf'
```

### 5. Run Integration Tests
// turbo
```bash
ssh -i ~/.ssh/id_ed25519 root@10.4.0.122 "pve-ibm-fs5x-test-runner"
```

## Verify Deployment

Check that services started successfully:
```bash
ssh root@10.4.0.122 "systemctl status pvedaemon pveproxy pvestatd --no-pager"
```

## Environment

- **Remote server:** `root@10.4.0.122`
- **SSH key:** `~/.ssh/id_ed25519`
- **Plugin package:** `pve-ibm-fs5x-fc-plugin`
- **Tests package:** `pve-ibm-fs5x-fc-plugin-tests`
- **Test config:** `/etc/pve/ibm-fs5x-tests.conf`

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