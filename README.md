# flat_check / flat_check_2 — проверка FLAT/FCS и сбор логов

Два bash-скрипта для серверов с продуктами линейки FLAT / FCS. **Опрос ресурсов и служб (health) у них одинаковый** — общий код из модернизированного `flat_check_2.sh`. Отличие только в сборщике логов.

| Файл | Назначение | Версия |
|------|------------|--------|
| `flat_check.sh` | **только health check** (без log collector) | **3.6.2** |
| `flat_check_2.sh` | health check **+** сбор логов (online/offline) | **3.6.2** |

Скрипты только читают состояние (и копируют логи в `_2`). Конфиги служб не меняют. Для полного сбора логов (PostgreSQL, tcpdump) обычно нужен **root** или sudo.

---

## Какой скрипт брать

```bash
# только мониторинг / cron / Zabbix / Flat Partner (страница «Система»)
./flat_check.sh
./flat_check.sh -i          # подробно по всем пакетам (включая не установленные)
./flat_check.sh -r          # + репозитории

# то же + сбор логов
./flat_check_2.sh
./flat_check_2.sh -i        # интерактивный мастер (язык → health / логи / selftest)
./flat_check_2.sh -log -off -t 4d
```

> **CLI:** в `flat_check.sh` флаг `-i` = `--info` (как в старом health-скрипте).  
> В `flat_check_2.sh` флаг `-i` = интерактивный мастер.

---

## Быстрый старт

```bash
chmod +x flat_check.sh flat_check_2.sh

./flat_check.sh -h
./flat_check_2.sh -h

# проверка: System → продукты → Infrastructure → Summary
./flat_check.sh
./flat_check_2.sh
```

Версия:

```bash
./flat_check.sh -v
./flat_check_2.sh -v
# → flat_check 3.6.2 / flat_check_2 3.6.2
```

При сборе логов (`_2`):

```text
[INFO] Режим логов: offline / scope=brief (flat_check_2 v3.6.2)
```

---

## Режимы

### `flat_check.sh` (health only)

| Запуск | Что делает |
|--------|------------|
| без аргументов | health: System + установленные пакеты |
| `-i` / `--info` | подробно по **всем** пакетам |
| `-r` / `--repo` | + репозитории APT/YUM |
| `-v` / `--version` | версия |
| `-j N` | макс. параллельных воркеров проверки пакетов |
| `--selftest simple` | быстрый самотест |
| `--dev` / `--selftest extended` | полный VERBOSE health |

### `flat_check_2.sh` (health + логи)

| Запуск | Что делает |
|--------|------------|
| без аргументов | тот же health, что у `flat_check.sh` |
| `-v` / `--version` | версия |
| `-r` / `--repo` | + репозитории |
| `-i` | интерактивный мастер |
| `--selftest` / `--dev` | самотест (в т.ч. log-path в extended) |
| `-log -on` / `-log -off` | сбор логов |

---

## Health check (общий для обоих)

```bash
./flat_check.sh
./flat_check.sh -r
./flat_check_2.sh                 # тот же health-путь
./flat_check.sh > /var/log/flat/health_$(date +%Y%m%d_%H%M).log 2>&1
```

### Порядок вывода

```text
[INFO]  OS: ...
[INFO]  Package manager: ...

=== System ===
[INFO] cpu: usage=...
[INFO] cpu top: ...
[INFO] memory: ...
[INFO] memory top: ...
[INFO] disk: ...
[INFO] database: ...
[INFO] cluster_db: ...
[INFO] network: ...
[INFO]/[WARN] cert: ...
[INFO] uptime: system=...
[INFO] uptime: <service>=...

=== SoftSwitch ===
=fss-server=
[OK]   pkg: fss-server installed
...

=== Infrastructure ===
...

=== Summary ===
[INFO] Installed: N | Errors: X | Warnings: Y
```

Блок `=== System ===` выводится **всегда** (даже если данных нет → `n/a`). Нужен для дашборда Flat Partner (этап 2 мониторинга): страница «Система».

| Ключ | Содержание |
|------|------------|
| `cpu` / `cpu top` | общая загрузка и % по установленным службам FLAT |
| `memory` / `memory top` | RAM и % по службам |
| `disk` | разделы `/dev/*` (size/used/avail/%) |
| `database` / `cluster_db` | PostgreSQL/MariaDB, роль primary/standby, репликация |
| `network` | rx/tx МБ/с по интерфейсам (кроме `lo`, замер ~1 с) |
| `cert` | срок действия сертификатов (дни); `<30` → `[WARN]` |
| `uptime` | система + ActiveEnterTimestamp systemd-служб |

### Метки

| Метка | Смысл |
|-------|--------|
| `[OK]` | норма |
| `[WARN]` | стоит глянуть |
| `[FAIL]` | явная проблема |
| `[INFO]` | справка |

Метаданные `PKG_*`, `detect_os`, `check_system`, `run_product_checks`, `check_infrastructure` и resource-gate (`_collector_*`) в обоих скриптах **совпадают** (источник истины — код `flat_check_2.sh`).

---

## Сбор логов (только `flat_check_2.sh`)

### Online / offline

| | Online `-log -on` | Offline `-log -off` |
|--|-------------------|---------------------|
| Когда | проблема «сейчас» | разбор за прошлый интервал |
| Что | только новые строки после старта | строки по timestamp в файле |
| tcpdump | по умолчанию (только `--scope extended`) | нет |

### Выбор цели и объём

```bash
./flat_check_2.sh -log --list-targets
./flat_check_2.sh -log -off -t 2h --scope brief -p SoftSwitch --no-mgcpclient
./flat_check_2.sh -log -off -f -1d --scope extended -s fcs-swui
./flat_check_2.sh -log -on -t 30m --scope brief -p "Contact Center"
```

| Флаг | Смысл |
|------|--------|
| `--scope brief` | только логи выбранных служб (по умолчанию) |
| `--scope extended` | + system/nginx/postgresql/configs (+ tcpdump online) |
| `-p` / `--product` | продукт (повторяемый) |
| `-s` / `--service` | пакет/служба (повторяемый) |
| `--mgcpclient` / `--no-mgcpclient` | SoftSwitch: включать ли `mgcpclient*` |
| `-j N` | offline / health: макс. параллельных воркеров (по умолч. nproc×80%, ≤32) |
| `--chunk-mode size\|lines` | offline: как резать крупные логи на part_\*.log (по умолч. `size`) |
| `--chunk-size РАЗМЕР` | offline: макс. размер одной части при `--chunk-mode size` (например `50M`, `200M`; по умолч. `100M`) |
| `--chunk-lines N` | offline: макс. строк в одной части при `--chunk-mode lines` (по умолч. `500000`) |

Без `-p`/`-s` — все пакеты, **присутствующие на хосте**. Каталоги вне allowlist (`logforflat` и т.п.) пропускаются: `[INFO] skip unknown`.

При отказе от mgcpclient исключаются и файлы `mgcpclient*` **внутри** каталогов служб (например `fss-server`).

**Host-wide 80% (Zabbix):** лишние воркеры не добавляются, если CPU или RAM **всей системы** уже ≥ 80%. Чтобы не зависать на загруженном хосте, **всегда разрешён минимум 1 воркер**. `pigz` — меньше потоков (limit−20%).

**Offline вырезка по времени (оперативно на больших логах):**

| Размер plain-файла | Стратегия |
|--------------------|-----------|
| &lt; 1MB | один поток `awk` |
| ≥ 1MB, упорядочен | бинарный поиск границ `from`/`to`, затем **параллельный chunk-scan** окна |
| ≥ 1GB (монолиты SoftSwitch) | то же, чанки крупнее (~64MB) |
| ≥ 1MB, не упорядочен | параллельный chunk-scan всего файла |
| `.gz` | линейный `zcat \| awk` (seek невозможен) |

Проверка пути вырезки: `./flat_check_2.sh --dev` и мастер → «Самотест» → «Расширенный».

### Offline примеры

```bash
./flat_check_2.sh -log -off -t 15m
./flat_check_2.sh -log -off -f -2h -e -1h
./flat_check_2.sh -log -off -f '14.07.2026 10:00' -e '14.07.2026 14:00'
./flat_check_2.sh -log -off -o /root
./flat_check_2.sh -log -off -t 1d --chunk-mode lines --chunk-lines 200000
./flat_check_2.sh -log -off -t 1d --chunk-mode size --chunk-size 50M
```

Мастер (`-i` → «Сбор логов» → «Offline») задаёт разбивку отдельным шагом после выбора диапазона.

### Online

```bash
./flat_check_2.sh -log -on
./flat_check_2.sh -log -on -t 5m
./flat_check_2.sh -log -on -t 30m --scope extended -n   # -n без tcpdump
```

Архив: `YYYY.MM.DD_HH-MM_<hostname>.tar.gz`

### Лог сессии

| Скрипт | Файл | Куда |
|--------|------|------|
| `flat_check.sh` | `flat_check.log` | рядом со скриптом, перезаписывается |
| `flat_check_2.sh` | `flat_check_2.log` | рядом со скриптом; при `-log` — внутрь архива |

На экран лог не влияет: `[OK]`/`[WARN]`/`[FAIL]`/`[INFO]` дублируются с таймстампом; подробности поиска логов и снимки ресурсов — только в файл (`DEBUG`).

---

## Сигналы и безопасность под root

Касается **сборщика** в `flat_check_2.sh`. Удаление рабочих каталогов только по шаблону `YYYY.MM.DD_HH-MM_*` внутри каталога вывода.

| Действие | Поведение |
|----------|-----------|
| Enter (online) | останов → архив |
| `-t` / мало места (TERM) | graceful → архив |
| Ctrl+C (INT) | abort, без архива |

---

## Зависимости

Обязательно: `bash`, coreutils, `awk` (gawk), `grep`.

Для health: `systemctl`, `dpkg`/`rpm`, `ss`/`netstat`, `curl`, `openssl`, `psql` (по ситуации), `top`/`free`/`df`.

Для сбора логов (`_2`): ещё `tail`, `gzip`/`pigz`, опционально `tcpdump`, `zcat`.

---

## Cron / CI

```bash
# health (предпочтительно flat_check.sh)
0 6 * * * /opt/flat/scripts/flat_check.sh >> /var/log/flat/health_check.log 2>&1

# эквивалентный health через _2 (без -log)
0 6 * * * /opt/flat/scripts/flat_check_2.sh >> /var/log/flat/health_check.log 2>&1
```

Вывод health рассчитан на парсинг бэкендом Flat Partner (`GET /health` → JSON), в т.ч. блок System.

---

## Добавить пакет в health check

Правьте **оба** файла одинаково (или сначала `_2`, затем перенесите блок `PKG_*` в `flat_check.sh`):

```bash
PKG_PRODUCT["my-pkg"]="Product Name"
PKG_LEGACY["my-pkg"]="old-name"          # или ""
PKG_PORTS["my-pkg"]="8080"
PKG_API["my-pkg"]="/api/health"
PKG_DEPS["my-pkg"]="nginx,postgresql"
```

---

## Устройство

| Блок | `flat_check.sh` | `flat_check_2.sh` |
|------|-----------------|-------------------|
| 0–5 | флаги, `PKG_*`, вывод, ОС, System, пакеты, infra | то же (1к1) |
| 6–10 | — | discovery и сбор логов |
| 9 resource-gate | параллельный опрос пакетов | то же + воркеры сбора |
| 11 | help / argv / main / selftest | wizard + log CLI + main |

---

## Связанные файлы

| Файл | Заметка |
|------|---------|
| `flat_check.sh` | health only (**3.6.2**), без log collector |
| `flat_check_2.sh` | health + log collector (**3.6.2**) |
| `README.md` | этот файл |
