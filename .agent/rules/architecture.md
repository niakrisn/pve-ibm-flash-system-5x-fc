---
trigger: always_on
---

## 1. Plugin Architecture
- [!CAUTION] НЕ вызывать activate/deactivate изнутри plugin methods.
- [!CAUTION] Cleanup — ответственность PVE core, не плагина.
- Операции должны быть атомарными.
- Отвечай на русском