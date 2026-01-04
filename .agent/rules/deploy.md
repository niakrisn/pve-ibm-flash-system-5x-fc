---
trigger: always_on
---

## 1. Deployment Safety
- Для деплоя используй ТОЛЬКО установку через пакет. Пакет плагина — `pve-ibm-fs5x-fc-plugin`.
- Для интеграционных тестов используй отдельный пакет — `pve-ibm-fs5x-fc-plugin-tests`.
- С каждым изменением пакеты необходимо версионировать.
- [!CAUTION] НИКОГДА не использовать `rsync --delete` на системных директориях PVE.

## 2. Integration Testing (Package-based)
- После установки `pve-ibm-fs5x-fc-plugin-tests`, создай файл конфигурации:
  ```bash
  cat <<EOF > /etc/pve/ibm-fs5x-tests.conf
  {
    "flashsystem_storage": "fs-01",
    "local_storage": "local-lvm"
  }
  EOF
  ```
- Для запуска всех тестов используй: `pve-ibm-fs5x-test-runner`