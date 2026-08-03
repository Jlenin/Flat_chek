# flat_check / flat_check_2 — проверка FLAT/FCS и сбор логов

Два bash-скрипта для серверов с продуктами линейки FLAT / FCS. **Health (текст и JSON) у них одинаковый.** Отличие — сборщик логов только в `_2`.

| Файл | Назначение | Версия |
|------|------------|--------|
| `flat_check.sh` | health check + **JSON-агент** (без log collector) | **3.7.0** |
| `flat_check_2.sh` | то же health/JSON **1к1** + сбор логов | **3.7.0** |
| `agent/` | конфиг, установщик, cron, контракт push → Partner | |

Скрипты только читают состояние (и копируют логи в `_2`). Конфиги служб не меняют. Для полного сбора логов обычно нужен **root** или sudo.

---

## Какой скрипт брать

```bash
# мониторинг / cron / Flat Partner (страница «Система» + JSON push)
./flat_check.sh
./flat_check.sh --json
./flat_check.sh --config /etc/flat/flat_check.conf --json --push

# то же + сбор логов
./flat_check_2.sh
./flat_check_2.sh -log -off -t 4d
```

> **CLI:** в `flat_check.sh` флаг `-i` = `--info`.  
> В `flat_check_2.sh` флаг `-i` = интерактивный мастер.  
> Для health/JSON фильтр продукта: `--product`. В `-log` по-прежнему `-p` выбирает продукт для сбора.

Установка агента на ноду: **[`agent/README.md`](agent/README.md)**.

---

## Быстрый старт

```bash
chmod +x flat_check.sh flat_check_2.sh agent/install_flat_check.sh

./flat_check.sh -h
./flat_check_2.sh -h

# текст: System → продукты → Infrastructure → Summary
./flat_check.sh

# JSON v2 (host_id / host_ip / service_name + products/system/…)
./flat_check.sh --json --host-id ss-n1 --service-name fss-backend | jq .summary
```

Версия:

```bash
./flat_check.sh -v
# → flat_check 3.7.0
```

---

## JSON-агент → Partner

На каждой ноде продукта агент сам собирает снимок и пушит на HTTP/HTTPS (как Zabbix active).

```bash
# установка
sudo ./agent/install_flat_check.sh \
  --push-url 'https://partner.example.local/api/v1/health/ingest' \
  --push-token 'SECRET' \
  --host-id ss-n1 \
  --service-name fss-backend

# вручную
flat_check --config /etc/flat/flat_check.conf --json --push
```

| Возможность | Как |
|-------------|-----|
| Несколько URL | `PUSH_URLS=url1,url2` |
| HTTP и HTTPS | любой `http://` / `https://` |
| Токен | `PUSH_TOKEN` + заголовок `Authorization: Bearer` (настраивается) |
| Идентичность | `HOST_ID`, `HOST_IP`, `SERVICE_NAME` (`fss-backend`, `fps-backend`, …) |

Подробно: conf, cron, токен backend, service names — в [`agent/`](agent/).

---

## Режимы

### `flat_check.sh` (health + JSON)

| Запуск | Что делает |
|--------|------------|
| без аргументов | health: System + установленные пакеты |
| `-i` / `--info` | подробно по **всем** пакетам |
| `-r` / `--repo` | + репозитории |
| `--pkg NAME` | один пакет (текст) |
| `--product NAME` | фильтр продукта |
| `--json` | снимок JSON v2 → stdout |
| `--push` | POST JSON на все `PUSH_URLS` |
| `--config FILE` | конфиг агента |
| `--host-id` / `--host-ip` / `--service-name` | идентичность |
| `--selftest simple` | быстрый самотест (в т.ч. JSON) |
| `--dev` | полный VERBOSE health |

### `flat_check_2.sh` (health + JSON + логи)

| Запуск | Что делает |
|--------|------------|
| без аргументов / `--json` / `--push` | как `flat_check.sh` |
| `-i` | интерактивный мастер |
| `-log -on` / `-log -off` | сбор логов |
| `--selftest` / `--dev` | самотест (health + log-path) |

---

## Health check (общий для обоих)

```bash
./flat_check.sh
./flat_check.sh -r
./flat_check_2.sh                 # тот же health-путь
```

### Порядок вывода (текст)

```text
[INFO]  OS: ...
=== System ===
=== SoftSwitch ===
=fss-server=
=== Infrastructure ===
=== Summary ===
```

Блок `=== System ===` нужен для дашборда Flat Partner (страница «Система»).

| Ключ | Содержание |
|------|------------|
| `cpu` / `cpu top` | общая загрузка и % по службам FLAT |
| `memory` / `memory top` | RAM и % по службам |
| `disk` | разделы |
| `database` / `cluster_db` | PostgreSQL/MariaDB, репликация |
| `network` | rx/tx МБ/с |
| `cert` | срок сертификатов; `<30` → `[WARN]` |
| `uptime` | система + службы |

Метаданные `PKG_*`, `detect_os`, `check_system`, `run_product_checks`, `check_infrastructure`, resource-gate и **JSON-блок** в обоих скриптах совпадают.

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
| `-p` / `--product` | продукт для **логов** (при `-log`) |
| `-s` / `--service` | пакет/служба |
| `--mgcpclient` / `--no-mgcpclient` | SoftSwitch: `mgcpclient*` |
| `-j N` | offline / health: макс. воркеров |
| `--chunk-mode size\|lines` | нарезка крупных логов |
| `--chunk-size` / `--chunk-lines` | лимиты частей |

**Host-wide 80% (Zabbix):** лишние воркеры не добавляются при CPU/RAM ≥ 80%; минимум 1 воркер всегда разрешён.

### Offline примеры

```bash
./flat_check_2.sh -log -off -t 15m
./flat_check_2.sh -log -off -f -2h -e -1h
./flat_check_2.sh -log -off -f '14.07.2026 10:00' -e '14.07.2026 14:00'
./flat_check_2.sh -log -off -t 1d --chunk-mode size --chunk-size 50M
```

Архив: `YYYY.MM.DD_HH-MM_<hostname>.tar.gz`

---

## Зависимости

Обязательно: `bash`, coreutils, `awk` (gawk), `grep`.

Для health/JSON: `systemctl`, `dpkg`/`rpm`, `ss`/`netstat`, **`curl`** (API + push), `openssl`, `psql` (по ситуации).

Для сбора логов (`_2`): ещё `tail`, `gzip`/`pigz`, опционально `tcpdump`, `zcat`.

---

## Cron

```bash
# текстовый health
0 6 * * * /usr/local/bin/flat_check >> /var/log/flat/health_check.log 2>&1

# JSON → Partner (ставит install_flat_check.sh)
*/5 * * * * root /usr/local/bin/flat_check --config /etc/flat/flat_check.conf --json --push >>/var/log/flat/flat_check_push.log 2>&1
```

---

## Добавить пакет в health check

Правьте **оба** файла одинаково:

```bash
PKG_PRODUCT["my-pkg"]="Product Name"
PKG_LEGACY["my-pkg"]="old-name"          # или ""
PKG_PORTS["my-pkg"]="8080"
PKG_API["my-pkg"]="/api/health"
PKG_DEPS["my-pkg"]="nginx,postgresql"
```

JSON/push-блок: `agent/json_report.inc.sh` → оба скрипта.

---

## Устройство

| Блок | `flat_check.sh` | `flat_check_2.sh` |
|------|-----------------|-------------------|
| 0–5 | флаги, `PKG_*`, System, пакеты, infra | то же (1к1) |
| JSON agent | `--json` / `--push` / conf | то же (1к1) |
| 6–10 | — | discovery и сбор логов |
| 9 resource-gate | параллельный опрос пакетов | то же + воркеры сбора |
| 11 | help / argv / main / selftest | wizard + log CLI + main |

---

## Связанные файлы

| Файл | Заметка |
|------|---------|
| `flat_check.sh` | health + JSON agent (**3.7.0**) |
| `flat_check_2.sh` | health/JSON + log collector (**3.7.0**) |
| `agent/` | установщик, conf, cron, README |
| `examples/` | старые черновики → см. `agent/` |
| `README.md` | этот файл |
