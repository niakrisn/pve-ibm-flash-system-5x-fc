# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Proxmox VE storage plugin for IBM FlashSystem 5.x series storage arrays via Fibre Channel. This is a **Perl-based custom storage plugin** implementing Proxmox Storage API v13.

### Key Architecture

```
Proxmox VE (API v13)
         ↓
PVE::Storage::Custom::IBMFlashSystemPlugin.pm
         ↓
IBM FlashSystem REST API
         ↓
Fibre Channel SAN → Host Clusters → Volumes
```

### Token Management (Lazy Invalidation)

- Token cached in `/run/pve-storage-ibm.token` (mode 0600)
- On `401`, `403`, or JSON response containing `InvalidToken`:
  1. Delete cached token file
  2. Re-authenticate via `POST /rest/auth`
  3. Retry original request (max `max_retries` times)

### Testing Environment

- Remote server: `root@10.4.0.122` use key `~/.ssh/id_ed25519`
- Deploy: Copy `.pm` file to `/usr/share/perl5/PVE/Storage/Custom/`
- Restart: `systemctl restart pvedaemon`
- Register: `pvesm add <storage-id> --type <plugin-name> --portal <ip> ...`
- Storage API: `10.0.0.222` endpoints `/rest/<cmd>`
- Docker: Use local Docker for build and checks

---

## Implementation Plan

### Stage 1: REST Client with Token Management

**Implementation Tasks:**
1. **HTTP Client (`LWP::UserAgent`):**
   - Config: `timeout` from config, `ssl_opts` for SSL verification (optional)
2. **`_api_request` method:**
   - Check token cache in `/run/pve-storage-ibm.token`, call `_authenticate` if missing
   - Execute request with `X-Auth-Token` header
   - On `401`, `403`, or `InvalidToken` in JSON response: delete cache, re-auth, retry
3. **`_authenticate` method:**
   - `POST /rest/auth` with `X-Auth-Username` and `X-Auth-Password` headers
   - Save token to `/run/pve-storage-ibm.token` with mode `0600`

### Stage 2: Proxmox API v13 Integration

**Plugin Declaration Methods:**
- `api()`: Return `13`
- `options()`: Configuration options - `portal`, `username`, `password`, `pool`, `host_cluster`, `timeout`, `verify_ssl`, `max_retries`, `retry_delay`
- `plugindata()`: Capabilities - `content => { images => 1, rootdir => 1 }`, `format => { raw => 1 }`, `migration => { shared => 1 }`
- `volume_has_feature()`: Return support for snapshot, clone, template, copy, sparseinit

### Stage 3: Pool Management

**Volume Operations (bound to configured pool):**
- `status()`: `POST /rest/lsmdiskgrp` filtered by pool name
- `alloc_image()`: `POST /rest/mkvdisk` with `mdiskgrp`, `size`, `unit => 'b'`, `name`
- `volume_size_info()`: `POST /rest/lsvdisk` for size and vdisk_UID

### Stage 4: Host Cluster Logic

**Dynamic Host Creation for SAN Connectivity:**
- `activate_volume()`:
  - Get local initiator (WWPN for FC)
  - `POST /rest/lshost` to check if host exists
  - If not found: `POST /rest/mkhost` with `hostcluster => $scfg->{host_cluster}` (critical!)
  - `POST /rest/mkvdiskhostmap/{vol_id}` to map volume
- `path()`: Return `/dev/disk/by-id/scsi-3<vdisk_UID>`

### Stage 5: FlashCopy Snapshots

**Snapshot Operations:**
- `volume_snapshot()`: `/rest/mkvdisk` → `/rest/mkfcmap` → `/rest/prestartfcmap/{id}` → `/rest/startfcmap/{id}`
- `volume_snapshot_rollback()`: `/restorefcmap`
- `volume_snapshot_delete()`: `/rest/stopfcmap` → `/rest/rmfcmap` → `/rest/rmvdisk`

### Stage 6: Validation Testing

**Manual Tests:**
1. **Expired Token Test:**
   - Run `pvesm list`
   - Delete `/run/pve-storage-ibm.token` via SSH
   - Run `pvesm list` again - should transparently re-authenticate
2. **Migration Test:**
   - Migrate VM with IBM FS disk to another node
   - Verify host is created in cluster on target node

---

## Code Reference

### Token Retry Pattern

```perl
sub api_request {
    my ($self, $scfg, $method, $endpoint, $data) = @_;

    my $token = $self->get_cached_token();
    my $attempts = 0;
    my $max_retries = $scfg->{max_retries} // 3;

    while ($attempts <= $max_retries) {
        my $res = $self->ua->request($method, $url, {
            headers => { 'X-Auth-Token' => $token },
            json => $data
        });

        if ($res->{status} == 403 || $res->{content} =~ /InvalidToken/i) {
            $token = $self->_authenticate($scfg);  # Updates cache
            $attempts++;
            next;
        }

        return decode_json($res->{content});
    }
    die "API request failed after $max_retries retries";
}
```

### Starting Point

Begin by creating the directory structure locally and implementing `_authenticate` method. Verify with a simple system info query (`POST /rest/lssystem`).

