# CLAUDE.md

Отвечай только по-русски.

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

- Remote server: `root@10.4.0.122` use key `~/.ssh/id_ed25519`. Any chekcs (syntax etc) do on this host.
- Deploy: Build a deb package and install on remote server
- Restart: `systemctl restart pvedaemon`
- Register: `pvesm add <storage-id> --type <plugin-name> --portal <ip> ...`
- Storage API: `10.0.0.222` endpoints `/rest/<cmd>`, user: pvcu, password: qenwu2-Wiwseb-nosgim. Всегда используй токен который хранится на удаленном хосте.
- Docker: Use local Docker for build package
- SCSI Scan: запрещено использовать rescan-scsi-bus.sh. Ищи FC порты и опрашивай только их.

#### Unit Tests

**Location on remote server:** `/root/pve-ibm-flash-system-5x-fc/`

**Run all unit tests:**
```bash
ssh root@10.4.0.122 "cd /root/pve-ibm-flash-system-5x-fc && prove t/unit/volume/*.t t/unit/snapshot/*.t t/unit/*.t"
```

**Run specific test file:**
```bash
ssh root@10.4.0.122 "cd /root/pve-ibm-flash-system-5x-fc && prove t/unit/volume/status.t"
```

**Run with verbose output:**
```bash
ssh root@10.4.0.122 "cd /root/pve-ibm-flash-system-5x-fc && prove -v t/unit/volume/status.t"
```

**Deploy updated modules to Proxmox:**
```bash
# Copy modules to system directory
scp PVE/Storage/Custom/IBMFlashSystem/*.pm root@10.4.0.122:/usr/share/perl5/PVE/Storage/Custom/IBMFlashSystem/

# Copy tests to remote
scp t/unit/volume/*.t root@10.4.0.122:/root/pve-ibm-flash-system-5x-fc/t/unit/volume/
```

**Test structure:**
- `t/unit/volume/*.t` - Volume operations tests (11 files, 47 tests)
- `t/unit/snapshot/*.t` - Snapshot operations tests (4 files, 17 tests)
- `t/unit/*.t` - Integration tests (4 files, 11 tests)
- Total: **75 tests** (as of refactoring commit 152703a)

**Important:** Modules are installed to `/usr/share/perl5/PVE/Storage/Custom/IBMFlashSystem/` on remote server for Proxmox to load them. Tests run from `/root/pve-ibm-flash-system-5x-fc/` working directory.

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

# Спецификация Proxmox Storage API v13 (IBM FlashSystem REST)

## 1. Метаданные и Конфигурация

### `api()`
*   **Действие**: Возвращает версию API.
*   **Требование**: Возвращать строго `13`.

### `plugindata()`
*   **Действие**: Описывает статические возможности плагина.
*   **Требование**: 
    *   `content` => `{ images => 1, rootdir => 1 }`
    *   `format` => `{ raw => 1 }`
    *   `migration` => `{ shared => 1 }` (обязательно для Live Migration).

### `options()` и `properties()`
*   **Действие**: Определение параметров в `storage.cfg` и их типов.
*   **Обязательные поля**: `portal`, `pool`, `hostcluster`, `username`, `password`.

---

## 2. Мониторинг и Состояние

### `activate_storage($class, $storeid, $scfg, $cache)`
*   **Действие**: Проверка связи с API СХД.
*   **Критическое поведение**: Должен выполнять проверочный запрос (например, `GET /lssystem`). Если токен истек (HTTP 403 / InvalidToken), метод обязан выполнить ревалидацию. Если СХД недоступна — вызвать `die`.

### `status($class, $storeid, $scfg, $cache)`
*   **Действие**: Возврат объема пула.
*   **Критическое поведение**: Запрашивать данные через `POST /rest/lsmdiskgrp`. Возвращать массив `($total, $free, $used, 1)` строго в **байтах**.

---

## 3. Жизненный цикл томов (CRUD)

### `alloc_image($class, $storeid, $scfg, $vmid, $fmt, $name, $size)`
*   **Действие**: Создание нового тома.
*   **Критическое поведение**: Использовать **`POST /rest/mkvolume`**. Конвертировать `$size` (в КБ) в **байты** (`unit: b`). Всегда передавать **`"thin": true`**. Возвращать имя тома.

### `free_image($class, $storeid, $scfg, $volname, $isBase)`
*   **Действие**: Удаление тома.
*   **Критическое поведение (State-Based Cleanup)**: Чтобы избежать ошибок блокировки (`CMMVC8698E`):
    1. Вызвать `POST /rest/lsvdiskhostmap` для этого тома. Снять маппинги со **всех** хостов кластера (использовать цикл по результатам).
    2. Найти и удалить все связанные FlashCopy маппинги (`lsfcmap` -> `stop` -> `rmfcmap`).
    3. Только после этого вызывать `rmvdisk`.

### `volume_size_info($class, $scfg, $storeid, $volname, $timeout)`
*   **Действие**: Получение актуального размера.
*   **Критическое поведение**: Запрашивать `capacity` и `used_capacity` через API. Возвращать данные в байтах.

### `volume_resize($class, $scfg, $storeid, $volname, $size, $running)`
*   **Действие**: Расширение тома.
*   **Критическое поведение**: Расширять основной том И все его зависимые снапшоты (`Targets`) на одну и ту же дельту в байтах. Если маппинг активен и СХД блокирует расширение: `stopfcmap` -> `expand` -> `startfcmap`.

---

## 4. Доступ к данным и транспорт (Activation)

### `path($class, $scfg, $volname, $storeid, $snapname)`
*   **Действие**: Возвращает путь к блочному устройству.
*   **Критическое поведение**:
    1. Метод **обязан** каждый раз запрашивать `vdisk_UID` (WWN) тома через API СХД.
    2. Построить строку пути: `/dev/mapper/3<vdisk_UID}` (UID в нижнем регистре).
    3. **Важно**: Метод не должен проверять наличие файла в ОС, он только возвращает строку «где диск должен быть».

### `activate_volume($class, $storeid, $scfg, $volname, $snapname, $cache)`
*   **Действие**: Подключение LUN к хосту.
*   **Критическое поведение (Discovery Loop)**:
    1. Выполнить `mkvdiskhostmap`.
    3. **Цикл ожидания**: Проверять наличие файла `/dev/mapper/3<UID>` до 30 секунд.
    4. Если устройство не появилось за 5 секунд, принудительно вызвать `multipath -v2`.
    5. **Синхронизация**: Не возвращать успех, пока устройство не станет доступно для открытия (использовать `sysopen` на чтение/запись). Это критично для предотвращения ошибок `qemu-img` при "Full Clone".

### `deactivate_volume($class, $storeid, $scfg, $volname, $snapname, $cache)`
*   **Действие**: Отключение LUN.
*   **Критическое поведение**: Сначала `multipath -f`, затем удаление путей в `/sys/block/sdX/device/delete`, и только в конце — API вызов `rmvdiskhostmap`.

### `qemu_blockdev_options($class, $scfg, $storeid, $volname, $machine_version, $options)`
*   **Действие**: Опции для QEMU.
*   **Требование**: Всегда возвращать `{ driver => 'host_device', filename => $path }`.

---

## 5. Снапшоты и Клонирование

### `volume_has_feature($class, $scfg, $feature, $storeid, $volname, $snapname, $running)`
*   **Требование**: Для фич `clone`, `copy`, `snapshot` возвращать хэш возможностей: `{ base => 1, current => 1, snap => 1 }`. Это заставит Proxmox вызывать нативные методы плагина.

### `clone_image($class, $scfg, $storeid, $volname, $vmid, $snapname)`
*   **Действие**: Аппаратное клонирование.
*   **Критическое поведение**: Реализовать как **Hardware Full Copy**.
    1. Создать новый том через `mkvolume`.
    2. Создать маппинг с **`copyrate: 150`** и **`autodelete: true`**.
    3. Это гарантирует, что диск станет независимым автоматически, а Proxmox получит управление мгновенно.

### `volume_snapshot($class, $scfg, $storeid, $volname, $snapname)`
*   **Действие**: Создание снапшота.
*   **Критическое поведение**: Использовать `mkvolume` (thin) и `mkfcmap` с **`copyrate: 0`**. Дождаться статуса `active/copying` перед возвратом.

### `volume_snapshot_rollback($class, $scfg, $storeid, $volname, $snapname)`
*   **Действие**: Откат к снапшоту.
*   **Критическое поведение (Manual Reverse-Sync)**:
    1. Сохранить текущую структуру «Звезды» (все Target-тома) в файл `/run/pve-ibm-rollback-$volname.json`.
    2. Удалить все текущие `fcmap` от этого источника (`force: true`).
    3. Создать временный реверсивный маппинг `Snapshot -> VM_Disk` с **`copyrate: 150`** и **`cleanrate: 150`**.
    4. Дождаться перехода в статус `active`. С этого момента данные считаются восстановленными.
    5. Удалить реверсивный маппинг.
    6. По данным из JSON-журнала восстановить оригинальную «Звезду» (`VM_Disk` снова становится `Source` для всех томов снапшотов) с **`copyrate: 0`**.

### `create_base($class, $storeid, $scfg, $volname)`
*   **Действие**: Создание шаблона.
*   **Критическое поведение**: Выполнить переименование тома через `POST /rest/chvdisk` (замена `vm-` на `base-`). Метод `path()` должен немедленно начать возвращать путь, основываясь на новом имени.

---

### Особые указания по обработке ошибок:
*   При получении ошибки **`CMMVC5701E`** (Object Busy) плагин должен делать до 5 попыток с паузой в 1 секунду.
*   Все операции с FlashCopy должны подтверждаться опросом статуса (`lsfcmap`), использование фиксированных задержек `sleep()` запрещено.

---

## IBM FlashSystem REST API Documentation

### Overview

IBM FlashSystem 5.x предоставляет REST API для управления. Все endpoint'ы используют метод **POST** (специфика IBM).

**Base URL:** `https://<portal>:<port>/rest/<endpoint>`

**Аутентификация:** Token-based через заголовок `X-Auth-Token`

### Справочник Endpoints

#### Аутентификация

| Endpoint | Описание |
|----------|----------|
| `POST /rest/auth` | Получить токен (заголовки: `X-Auth-Username`, `X-Auth-Password`) |

#### Управление томами

| Endpoint | Описание | Параметры |
|----------|----------|-----------|
| `POST /rest/mkvolume` | Создать том | `name`, `pool`, `size`, `unit: "b"`, `thin: true` |
| `POST /rest/lsvdisk` | Список томов | `bytes: true` |
| `POST /rest/lsvdisk/<name>` | Информация о томе | `bytes: true` |
| `POST /rest/expandvdisksize/<id>` | Расширить том | `size` (дельта), `unit: "b"` |
| `POST /rest/rmvdisk/<id>` | Удалить том | `{}` |
| `POST /rest/lsmdiskgrp/<pool>` | Информация о пуле | `bytes: true` |

#### Управление хостами

| Endpoint | Описание | Параметры |
|----------|----------|-----------|
| `POST /rest/lshost` | Список хостов | `{}` |
| `POST /rest/mkhost` | Создать хост | `name`, `hostcluster`, `type: "generic"` |
| `POST /rest/mkport/<host>` | Добавить FC порт | `fcport_name: "XX:XX:XX:XX:XX:XX:XX:XX"` |
| `POST /rest/lshostcluster/<cluster>` | Информация о кластере | `{}` |

#### Подключение томов к хостам (LUN Mapping)

| Endpoint | Описание | Параметры |
|----------|----------|-----------|
| `POST /rest/lsvdiskhostmap` | Список маппингов | `{}` |
| `POST /rest/mkvdiskhostmap/<id>` | Подключить том к хосту | `host`, `scsi` (LUN 1-255) |
| `POST /rest/rmvdiskhostmap/<id>` | Отключить том от хоста | `host` |

#### FlashCopy (Снапшоты и клоны)

| Endpoint | Описание | Параметры |
|----------|----------|-----------|
| `POST /rest/lsfcmap` | Список FlashCopy | `{}` |
| `POST /rest/lsfcmap/<id>` | Информация о FlashCopy | `{}` |
| `POST /rest/mkfcmap` | Создать FlashCopy | `source`, `target`, `copyrate` |
| `POST /rest/prestartfcmap/<id>` | Подготовить FlashCopy | `{}` |
| `POST /rest/startfcmap/<id>` | Запустить FlashCopy | `{}` |
| `POST /rest/stopfcmap/<id>` | Остановить FlashCopy | `{}` |
| `POST /rest/rmfcmap/<id>` | Удалить FlashCopy | `force: true` |

### Коды ошибок IBM FlashSystem

| Код | Описание | Обработка |
|-----|----------|-----------|
| `CMMVC5701E` | Объект занят | Retry 5 раз, пауза 1с |
| `CMMVC5750E` | Не найден | Игнорировать (idempotent) |
| `CMMVC5840E` | Том подключён/в FlashCopy | Сначала отключить |
| `CMMVC5842E` | Объект не существует | Игнорировать (idempotent) |
| `CMMVC5897E` | FlashCopy не удалён | Игнорировать |
| `CMMVC5902E` | Уже подготовлен | Получить существующий ID |
| `CMMVC5906E` | В состоянии preparing | Retry 5 раз, пауза 1с |
| `CMMVC5916E` | Не активен | Игнорировать |
| `CMMVC5951E` | Уже остановлен | Игнорировать |
| `CMMVC6035E` | Уже существует | Игнорировать (idempotent) |
| `CMMVC6374E` | Идентичный маппинг | Получить существующий ID |
| `CMMVC6432E` | Хост не существует | Создать хост |
| `CMMVC6470E` | Целевой том занят | Retry 5 раз, пауза 1с |
| `CMMVC9055E` | Есть зависимые маппинги | Удалить зависимости |
| `ClusterCrendentialsInvalid` | Неверные учетные данные | Проверить логин/пароль |

### Параметр copyrate для FlashCopy

| Значение | Описание | Использование |
|----------|----------|---------------|
| `0` | Copy-on-write (без немедленного копирования) | Снапшоты |
| `1-100` | Фоновое копирование | Клоны |
| `100-150` | Быстрое копирование | Быстрые клоны/восстановление |

### Workflow'и

#### Создание тома
1. `POST /rest/mkvolume` → создать том
2. `POST /rest/mkvdiskhostmap/<id>` → подключить к хосту
3. Сканирование SCSI: `echo "- - -" > /sys/class/scsi_host/hostX/scan`
4. Устройство появляется как `/dev/mapper/3<vdisk_UID>` (нижний регистр)

#### Удаление тома
1. `POST /rest/stopfcmap/<id>` → остановить FlashCopy
2. `POST /rest/rmfcmap/<id>` → удалить FlashCopy
3. `POST /rest/rmvdiskhostmap/<id>` → отключить от хоста
4. `multipath -f <device>` → удалить multipath
5. `POST /rest/rmvdisk/<id>` → удалить том

#### Создание снапшота
1. `POST /rest/mkvolume` → создать целевой том
2. `POST /rest/mkfcmap` → создать FlashCopy (copyrate: 0)
3. `POST /rest/prestartfcmap/<id>` → подготовить
4. `POST /rest/startfcmap/<id>` → запустить

#### Клонирование
1. `POST /rest/mkvolume` → создать целевой том
2. `POST /rest/mkfcmap` → создать FlashCopy (copyrate: 100-150)
3. `POST /rest/prestartfcmap/<id>` → подготовить
4. `POST /rest/startfcmap/<id>` → запустить
5. Дождаться `idle_or_copied`
6. `POST /rest/rmfcmap/<id>` → удалить (тома независимы)

### Рекомендации

1. Всегда использовать `thin: true` для томов со снапшотами
2. Использовать `bytes: true` для получения размеров в байтах
3. Обрабатывать пустые ответы: API может вернуть `{}` при отсутствии результатов
4. Проверять тип ответа: `ref()` для определения array/hash/string
5. Retry при "busy" ошибках: `CMMVC5701E`, `CMMVC5906E`, `CMMVC6470E`
6. Игнорировать "not found" для idempotent операций
8. Использовать `force: true` для операций очистки
9. Ждать появления устройства до 30 секунд после маппинга
10. Кешировать токены до HTTP 401/403

