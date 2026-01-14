---
description: Strict Integration Test Execution (Fail-Fast & Evidence Collection)
---

# Strict Integration Test Execution Workflow

This workflow enforces the **Fail-Fast** principle. You must follow this EXACTLY when running integration tests.

## 1. Preparation
1.  **Sync/Install Tests**: Рекомендуется использовать пакетную установку:
    ```bash
    make package-docker
    # ... деплой пакета тестов из output/ ...
    scp -i ~/.ssh/id_ed25519 output/pve-ibm-fs5x-fc-plugin-tests_*.deb root@10.4.0.122:/tmp/
    ssh -i ~/.ssh/id_ed25519 root@10.4.0.122 "dpkg -i /tmp/pve-ibm-fs5x-fc-plugin-tests_*.deb"
    # ... деплой основного пакета плагина из output/ ...
    scp -i ~/.ssh/id_ed25519 output/pve-ibm-fs5x-fc-plugin_*.deb root@10.4.0.122:/tmp/
    ssh -i ~/.ssh/id_ed25519 root@10.4.0.122 "dpkg -i /tmp/pve-ibm-fs5x-fc-plugin_*.deb"
    ```

## 2. Execution (FAIL-FAST)
Используй системный раннер. Он сам сделает очистку и проверит окружение.
Запрещено запускать `prove` напрямую (в том числе локально или на сервере) — это нарушает Fail-Fast и может запустить тесты параллельно.
При любой ошибке раннер автоматически запускает сбор доказательств.

```bash
ssh -i ~/.ssh/id_ed25519 root@10.4.0.122 "pve-ibm-fs5x-test-runner"
# Для запуска конкретного теста по номеру (первые два символа файла):
ssh -i ~/.ssh/id_ed25519 root@10.4.0.122 "pve-ibm-fs5x-test-runner 03"
# Допускается передать полный файл, будет взят его префикс:
ssh -i ~/.ssh/id_ed25519 root@10.4.0.122 "pve-ibm-fs5x-test-runner 03_snapshot_lifecycle.t"
# Можно указать несколько тестов:
ssh -i ~/.ssh/id_ed25519 root@10.4.0.122 "pve-ibm-fs5x-test-runner 01 03 07"
```

## 3. Protocol: ON FAILURE
If the test runner exits with a non-zero code, or if you see a "FAIL" in the output:

### [FATAL] STOP IMMEDIATELY
*   **DO NOT** automatically re-run the test.
*   **DO NOT** attempt to "fix" the code immediately.
*   **DO NOT** run cleanup scripts that might destroy evidence.

### [ACTION] COLLECT EVIDENCE
Используй ТОЛЬКО доказательства, собранные раннером через `collect_evidence.sh`.
Не запускай сбор вручную — чтобы не перезаписать/исказить артефакты.

Каталог evidence включает имя сценария в пути (например, `...-07_backup_restore.t-YYYYMMDD-HHMMSS`).
Если нужны данные, сначала найди последний каталог:
```bash
ls -dt /var/log/pve-ibm-fs5x-evidence-* | head -n 1
```

После сбора агент обязан проанализировать доказательства и подготовить отчет.
Желательно сохранить отчет как артефакт в каталоге evidence (например, `analysis.txt`).

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
