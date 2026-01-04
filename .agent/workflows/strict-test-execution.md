---
description: Strict Integration Test Execution (Fail-Fast & Evidence Collection)
---
# Strict Integration Test Execution Workflow

This workflow enforces the **Fail-Fast** principle. You must follow this EXACTLY when running integration tests.

## 1. Preparation
1.  **Sync Tests**: Ensure local test files are synced to the remote host.
    ```bash
    scp -r t/integration/* root@10.4.0.122:/usr/share/pve-ibm-fs5x-fc-plugin-tests/
    ```
2.  **Verify Environment**: Check that the host is clean before starting.
    ```bash
    ssh -i ~/.ssh/id_ed25519 root@10.4.0.122 "qm list; multipath -ll; lsblk"
    ```
    *If any leftover VMs or devices exist, STOP and notify the user.*

## 2. Execution (FAIL-FAST)
Run the test runner. The runner is configured to `set -e`, but YOU must also respect the outcome.

```bash
ssh -i ~/.ssh/id_ed25519 root@10.4.0.122 "chmod +x /usr/share/pve-ibm-fs5x-fc-plugin-tests/scenarios/*.t; pve-ibm-fs5x-test-runner"
```

## 3. Protocol: ON FAILURE
If the test runner exits with a non-zero code, or if you see a "FAIL" in the output:

### [FATAL] STOP IMMEDIATELY
*   **DO NOT** automatically re-run the test.
*   **DO NOT** attempt to "fix" the code immediately.
*   **DO NOT** run cleanup scripts that might destroy evidence.

### [ACTION] COLLECT EVIDENCE
Run the following commands to capture the state "as-is":

1.  **Process List**:
    ```bash
    ssh -i ~/.ssh/id_ed25519 root@10.4.0.122 "ps aux | grep qm"
    ```
2.  **Storage/Device State**:
    ```bash
    ssh -i ~/.ssh/id_ed25519 root@10.4.0.122 "multipath -ll; lsblk -o NAME,SERIAL,HCTL,SIZE,TYPE,FSTYPE,MOUNTPOINT; ls -l /dev/disk/by-id/scsi-*"
    ```
3.  **VM Config**:
    ```bash
    ssh -i ~/.ssh/id_ed25519 root@10.4.0.122 "qm config <FAILED_VMID>"
    ```
4.  **Logs**:
    ```bash
    ssh -i ~/.ssh/id_ed25519 root@10.4.0.122 "tail -n 100 /var/log/pve-storage-ibm.log; journalctl -n 50"
    ```

### [ACTION] WAIT FOR USER
*   Present the gathered evidence to the user.
*   Ask for permission to proceed (cleanup, retry, or fix).
*   **Only proceed after explicit user approval.**

## 4. Protocol: ON SUCCESS
If and only if ALL tests pass:
1.  Verify the task logs in Proxmox are clean (no "red" errors).
2.  Update the `task.md` or artifacts.
3.  Notify the user of success.
