# Integration Tests

Complete integration test suite for IBM FlashSystem storage plugin.

## Prerequisites

1. **Storage configured on remote server:**
   - Storage ID: `ibmfs`
   - Portal: `10.0.0.222`
   - Pool: `Pool1`
   - Hostcluster: `ProxmoxCluster`

2. **SSH access to test server:**
   - Host: `root@10.4.0.122`
   - Key-based auth configured

3. **Perl modules on remote server:**
   ```bash
   apt-get install libtest-simple-perl libjson-perl
   ```

## Running Tests

### Quick check (pre-flight)
```bash
cd t/integration
make check
```

### Run all tests
```bash
make test
```

### Cleanup test volumes
```bash
make clean
```

### SSH to test server
```bash
make ssh
```

## Test Coverage

| Test | Description |
|------|-------------|
| Cleanup previous | Remove any leftover test volumes |
| Activate Storage | Verify connection and configuration |
| Create Volume | Allocate a new 10GB volume |
| Get Volume Size | Query volume size information |
| List Volumes | List all volumes in pool |
| Activate Volume | Map volume to host (FC) |
| Get Volume Path | Verify multipath device path |
| Resize Volume | Expand volume from 10GB to 15GB |
| Create Base Template | Create template volume |
| Clone Volume | Create linked clone via FlashCopy |
| Deactivate Volume | Unmap from host |
| Delete Volume | Remove volume from storage |
| Final Cleanup | Remove all test artifacts |

## Test Naming

Test volumes use prefix `vm-99999` to avoid conflicts:
- `vm-99999-disk-0` - Primary test volume
- `vm-99999-disk-1` - Secondary test volume
- `vm-99999-base-0` - Base template
- `vm-99999-clone-0` - Cloned volume

## Manual Testing

### Create VM via pvesm
```bash
# On remote server
pvesm add ibmfs --type ibmflash --portal 10.0.0.222 --pool Pool1 --hostcluster ProxmoxCluster --username pvcu
pvesm set ibmfs --password yourpassword
```

### Test volume operations
```bash
# Create VM with disk
qm create 9999 --name test-vm --scsi0 ibmfs:10

# Check mappings
curl -s -k -H "X-Auth-Token: $(cat /run/pve-storage-ibm-ibmfs.token)" \
  https://10.0.0.222/rest/lsvdiskhostmap | jq .

# Start VM (triggers activate)
qm start 9999

# Stop VM (triggers deactivate)
qm stop 9999

# Delete VM
qm destroy 9999 --destroy-unreferenced-disks 1 --purge 1
```

## Troubleshooting

### Tests fail to connect
```bash
# Check SSH
ssh root@10.4.0.122 "hostname"

# Check token
ssh root@10.4.0.122 "cat /run/pve-storage-ibm-ibmfs.token"
```

### Volume stuck with mappings
```bash
# Check mappings
ssh root@10.4.0.122 'curl -s -k -H "X-Auth-Token: $(cat /run/pve-storage-ibm-ibmfs.token)" \
  https://10.0.0.222/rest/lsvdiskhostmap' | jq .

# Force remove
make clean
```

### Multipath issues
```bash
ssh root@10.4.0.122 "multipath -ll"
ssh root@10.4.0.122 "systemctl restart multipathd"
```
