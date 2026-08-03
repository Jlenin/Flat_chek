# CONTEXT — handoff для другого ИИ / агента

Документ-контекст по репозиторию **Flat_chek** (`github.com/Jlenin/Flat_chek`).  
Обновлять при существенных изменениях (версия, контракт JSON, установщик, паритет скриптов).

**Последнее обновление:** 2026-08-03  
**Текущая версия скриптов:** `3.7.0`  
**Ветка финалки агента:** `cursor/flat-check-agent-json-f35c` (PR #13 → `main`)

---

## 1. Что это за проект

Два bash-скрипта для серверов FLAT/FCS:

| Файл | Роль |
|------|------|
| `flat_check.sh` | **только health** + JSON-агент (без сборщика логов) |
| `flat_check_2.sh` | тот же health/JSON **1к1** + **сбор логов** (online/offline) |
| `agent/` | конфиг, cron, установщик, контракт push → Flat Partner |
| `examples/` | старые черновики; источник истины теперь `agent/` |
| `README.md` | пользовательская документация |
| `CONTEXT.md` | этот файл (для ИИ) |

Скрипты **не меняют** конфиги служб — только читают состояние (и копируют логи в `_2`).

Цель мониторинга: дашборд Flat Partner (сводка / пакеты / система / infra), модель доставки **как Zabbix active** — агент на каждой ноде сам пушит JSON, а не центральный SSH-координатор.

---

## 2. Что уже сделано (хронология смысла)

Не полный git-лог, а смысловые этапы:

1. **Offline log fixes** (в `flat_check_2`): cutoff в полночь, unsorted logs, строки без даты, daily merge, chunk modes (`size`/`lines`) — серии PR до ~#8/#9, версия `_2` доходила до 3.6.x.
2. **Health-only `flat_check.sh`** вырезан из `_2` без log collector (PR #10). Health-путь совпадает с `_2`.
3. **Архитектура агента** (обсуждение + docs):
   - предпочтение: агент на ноде + JSON push на Partner ingest;
   - не основной путь: SSH coordinator / `PKG_HOST` / remote-map;
   - опора на выдержки: `выдержка из документации.docx`, `CI_CD статус-v96-*.docx` (могут лежать в workspace, в git обычно не обязательны).
4. **Черновики `examples/`** (PR #11/#12): payload, conf, cron, скелет install — «целевой вид».
5. **Финалка 3.7.0 (PR #13):**
   - реальные `--json` / `--push` / `--config` / `--pkg` / identity в `flat_check.sh`;
   - то же 1к1 в `flat_check_2.sh`;
   - папка `agent/` с рабочим установщиком и подробным README;
   - корневой README обновлён.

---

## 3. Правила паритета (критично)

### Health / JSON — всегда 1к1

Между `flat_check.sh` и `flat_check_2.sh` должны совпадать:

- `PKG_*` метаданные
- `detect_os`, `check_system`, `run_product_checks`, `check_infrastructure`
- resource-gate (`_collector_*`, лимиты ~80% CPU/RAM)
- **весь блок JSON/push** (сейчас канон: `agent/json_report.inc.sh`, вшит в оба файла)

### Только в `flat_check_2.sh`

- `-log` online/offline, wizard `-i`, chunk/seek, `parce_service_log*`, tcpdump и т.д.

### CLI-ловушки

| Флаг | `flat_check.sh` | `flat_check_2.sh` |
|------|-----------------|-------------------|
| `-i` | `--info` (подробный health) | интерактивный мастер |
| `-p` / `--product` | фильтр продукта (health/JSON) | при `-log` — выбор продукта для логов; иначе фильтр health/JSON |
| `-j` | `--jobs` (воркеры пакетов) | `--jobs` (в т.ч. offline copy workers) |
| `--json` / `--push` | агент | то же; обрабатывается **до** `-log` и завершает процесс |

При правках health/JSON: менять **оба** скрипта (или править `agent/json_report.inc.sh` и пересинхронизировать вставку).

---

## 4. JSON-агент (контракт)

### CLI

```bash
./flat_check.sh --config /etc/flat/flat_check.conf --json
./flat_check.sh --config /etc/flat/flat_check.conf --json --push
./flat_check.sh --pkg fss-server --json
./flat_check.sh --json --host-id ss-n1 --host-ip 10.0.1.5 --service-name fss-backend
```

- `--json` — печать тела в stdout  
- `--push` — POST на все `PUSH_URLS` (без обязательной печати; с `--json --push` — и печать, и push)  
- conf + env: `PUSH_URLS`, `PUSH_TOKEN`, `HOST_ID`, `HOST_IP`, `SERVICE_NAME`, …

### Обязательные поля идентичности в JSON

- `host_id`
- `host_ip`
- `service_name` — **CI/CD-имя** (`fss-backend`, `fps-backend`, …), не hostname  
  Справочник: `agent/service_names.md`

### Прочее в снимке

`timestamp`, `script_version`, `os`, `package_manager`, `products[]` (с `packages[]`), `infrastructure[]`, `repositories`, `summary`, `system` (cpu/mem/disk/db/network/uptime), `certificates`, …

Пример: `agent/health-payload.example.json`.  
UI Partner читает агрегат через `GET /health` (поля описаны в docx-выдержке); агент **пушит** сырой снимок на ingest.

### Push

- Несколько URL: `PUSH_URLS=url1,url2` (http и https)
- Заголовки: `Content-Type: application/json`, `Authorization: Bearer <token>` (или кастомный `PUSH_AUTH_HEADER`), `X-Flat-Host-Id`, `X-Flat-Service-Name`
- Ретраи/таймауты: `PUSH_RETRIES`, `PUSH_CONNECT_TIMEOUT`, `PUSH_MAX_TIME`
- Нужен `curl`

### Важный баг, который уже чинили

В блоке JSON **нельзя** делать `PUSH_URLS=""` и т.п. — это затирало env.  
Сейчас дефолты через `: "${PUSH_URLS:=${PUSH_URL:-}}"` и аналоги.

Также: `status_code` в API — число без leading zeros (`$((10#…))`); пустые `products[]` не включаются; `ALL_DEPENDS` сбрасывается через `unset` + `declare -A`.

---

## 5. Папка `agent/` (финальный комплект)

| Файл | Зачем |
|------|--------|
| `README.md` | подробная инструкция установщика и эксплуатации |
| `install_flat_check.sh` | production-ish install: bin → conf → cron → smoke |
| `flat_check.conf.example` | шаблон `/etc/flat/flat_check.conf` |
| `cron.example` | `/etc/cron.d/flat-check` |
| `service_names.md` | SERVICE_NAME из CI/CD |
| `backend-token.example.yaml` | как принять токен на backend |
| `health-payload.example.json` | пример тела |
| `ingest-request.example.http` | пример HTTP |
| `cli.examples.sh` | примеры команд |
| `json_report.inc.sh` | канон блока JSON/push |

Типовая установка:

```bash
sudo ./agent/install_flat_check.sh \
  --push-url 'https://partner.example.local/api/v1/health/ingest' \
  --push-token 'SECRET' \
  --host-id ss-n1 \
  --service-name fss-backend
```

Флаги: `--dry-run`, `--with-logs` (ещё `flat_check_2`), `--skip-cron`, `--force-conf`, `--cron-spec`, …

---

## 6. Сбор логов (`flat_check_2` only) — кратко

- Online: `-log -on` — `tail -F`, опционально tcpdump при `--scope extended`
- Offline: `-log -off` — фильтр **строк по timestamp внутри файла**, не только mtime
- Крупные plain ≥1MB: bisect границ + parallel chunk-scan; ≥1GB — крупнее чанки; unsorted — full-file chunk-scan; `.gz` — линейно
- Host-wide gate ~80% CPU/RAM; всегда ≥1 воркер
- Chunk output: `--chunk-mode size|lines`, `--chunk-size`, `--chunk-lines`
- Архив: `YYYY.MM.DD_HH-MM_<hostname>.tar.gz`
- Сессионный лог: `flat_check_2.log` (при `-log` — внутрь архива)

Не смешивать с `--json/--push` в одном запуске: JSON-путь выходит раньше.

---

## 7. Версии и ветки (ориентир)

| Версия | Смысл |
|--------|--------|
| 3.6.2 | health-only `flat_check` + стабильный log path в `_2` (до агента) |
| **3.7.0** | JSON agent + `agent/` kit |

Полезные ветки/PR (могут быть уже в `main`):

- health-only flat_check
- examples drafts (#11/#12)
- **agent JSON final (#13)** — `cursor/flat-check-agent-json-f35c`
- ранее: offline seek, chunk split, daily merge, parce_service_log, sys cpu refactor и т.д.

Base для новых PR по умолчанию: `main`.  
Имена веток cloud-агента: `cursor/<name>-f35c`.

---

## 8. Как проверять после правок

```bash
bash -n flat_check.sh flat_check_2.sh agent/install_flat_check.sh

./flat_check.sh -v          # 3.7.0+
./flat_check.sh --selftest simple
./flat_check_2.sh --selftest simple

./flat_check.sh --json --host-id t --service-name fss-backend | jq .summary
PUSH_URLS=http://127.0.0.1:PORT/ingest PUSH_TOKEN=x ./flat_check.sh --push

# паритет блока:
# agent/json_report.inc.sh должен совпадать с блоком в обоих .sh

./agent/install_flat_check.sh --dry-run --host-id t --service-name fss-backend \
  --push-url https://example/ingest
```

Текстовый health без флагов должен остаться читаемым как раньше.

---

## 9. Чего пользователь хочет по стилю

- **Читабельность, понятность, результативность** — меньше магии, явные флаги, понятные README.
- Не раздувать scope: не тащить SSH-координатор как основной путь, если не просят.
- Frontend-design rules из user_rules к этому репо **не относятся** (это bash/ops).
- Документацию markdown — по запросу; этот `CONTEXT.md` пользователь **явно попросил** вести.

---

## 10. Типичные следующие задачи (если попросят)

- Дожать поля JSON под точный UI/API mapping из docx (если Partner начнёт ругаться на схему)
- Deb/rpm пакет вместо raw install
- Systemd timer вместо cron
- Метрики/алерты на fail push
- Remote-map по SSH — только как опциональный bastion-путь (черновики были в `examples/`)
- Не дать разъехаться JSON-блоку между двумя скриптами (генерация из `json_report.inc.sh` в CI)

---

## 11. Карта «куда смотреть»

```text
flat_check.sh          ← health + agent CLI/main
flat_check_2.sh        ← health/agent 1к1 + logs
agent/README.md        ← как ставить и пользоваться
agent/json_report.inc.sh ← канон JSON/push
agent/install_flat_check.sh
README.md              ← пользовательский обзор
CONTEXT.md             ← этот handoff
```

При сомнении по продуктовым именам сервисов — `agent/service_names.md` и CI/CD docx.  
При сомнении по полям UI health — выдержка из документации Partner (`GET /health`).
