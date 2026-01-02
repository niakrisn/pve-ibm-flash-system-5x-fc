---
trigger: always_on
---

## 1. Plugin Architecture
- НЕ вызывать activate/deactivate изнутри plugin methods.
- Cleanup — ответственность PVE core, не плагина.
- Операции должны быть атомарными.
- Отвечай на русском