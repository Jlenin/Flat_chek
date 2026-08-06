# flat_check / flat_check_2

Проверка состояния продуктов FLAT/FCS на Linux-хосте (dpkg/rpm + systemd).

| Скрипт | Назначение | Версия |
|--------|------------|--------|
| `flat_check.sh` | health check | 3.7.1 |
| `flat_check_2.sh` | тот же health check + сбор логов | 3.10.2 |

Оба скрипта только читают состояние системы и пакетов. Конфиги служб не меняют.  
Для полного сбора логов в `_2` обычно нужен root или sudo.

Периодическая отправка health JSON в Flat Partner (conf, cron, установщик) — в каталоге [`agent/`](agent/).

---

## Какой скрипт использовать

```bash
# только мониторинг состояния
./flat_check.sh
./flat_check.sh -r          # + репозитории
./flat_check.sh --dev       # самотест + VERBOSE health по всем пакетам

# мониторинг + сбор логов
./flat_check_2.sh
./flat_check_2.sh -i        # интерактивный мастер
./flat_check_2.sh -log -off -t 4d
```

Health-путь у обоих совпадает (`PKG_*`, System, пакеты, infrastructure, resource-gate, JSON/push).  
`-i` есть только в `flat_check_2.sh` (мастер). В `flat_check.sh` не используется.

---

## Быстрый старт

```bash
chmod +x flat_check.sh flat_check_2.sh

./flat_check.sh -h
./flat_check_2.sh -h

./flat_check.sh
./flat_check.sh -v    # flat_check 3.7.1
```

---

## Health check

```bash
./flat_check.sh
./flat_check.sh -r
./flat_check_2.sh     # тот же путь проверки
```

Порядок вывода:

```text
[INFO]  OS: ...
[INFO]  Package manager: ...

=== System ===
=== SoftSwitch ===
=fss-server=
...
=== Infrastructure ===
=== Summary ===
```

| Блок System | Содержание |
|-------------|------------|
| `cpu` / `cpu top` | общая загрузка и % по службам FLAT |
| `memory` / `memory top` | RAM и % по службам |
| `disk` | разделы |
| `database` / `cluster_db` | PostgreSQL/MariaDB, роль, репликация |
| `network` | rx/tx МБ/с по интерфейсам |
| `cert` | срок сертификатов; &lt;30 дней → `[WARN]` |
| `uptime` | система и systemd-службы |

Метки: `[OK]` норма, `[WARN]` обратить внимание, `[FAIL]` проблема, `[INFO]` справка.

### Общие флаги health (оба скрипта)

| Флаг | Описание |
|------|----------|
| `-r` / `--repo` | показать репозитории |
| `-j` / `--jobs N` | лимит параллельных воркеров |
| `--pkg NAME` | один пакет |
| `-p` / `--product NAME` | один продукт |
| `--selftest simple\|extended` | самотест |
| `--dev` | = `--selftest extended` (VERBOSE health по всем пакетам) |
| `-v` / `--version` | версия |

Дополнительно оба понимают `--json` / `--push` / `--config` (см. [`agent/`](agent/)).

Только в `flat_check_2.sh`: `-i` (мастер), `-log` и связанные флаги сбора логов.

---

## Сбор логов (`flat_check_2.sh`)

| Режим | Когда | Что снимает |
|-------|-------|-------------|
| `-log -on` | проблема «сейчас» | новые строки после старта (`tail -F`), tcpdump при `--scope extended` |
| `-log -off` | разбор за прошлый интервал | строки по timestamp внутри файла |

```bash
./flat_check_2.sh -log --list-targets
./flat_check_2.sh -log -off -t 2h --scope brief -p SoftSwitch --no-mgcpclient
./flat_check_2.sh -log -off -f -1d --scope extended -s fcs-swui
./flat_check_2.sh -log -on -t 30m --scope brief -p "Contact Center"
```

| Флаг | Смысл |
|------|--------|
| `--scope brief` | только логи выбранных служб (по умолчанию) |
| `--scope extended` | + system / nginx / postgresql / configs (+ tcpdump online) |
| `-p` / `--product` | продукт (в режиме `-log`) |
| `-s` / `--service` | пакет/служба |
| `--mgcpclient` / `--no-mgcpclient` | SoftSwitch/`fss-server`: включать ли `mgcpclient*` (вопрос только если выбран `fss-server`) |
| `-j N` | число offline-воркеров |
| `--chunk-mode size\|lines` | нарезка крупных логов |
| `--chunk-size` / `--chunk-lines` | лимит части |
| `-o` / `--output DIR` | каталог архива |

Без `-p`/`-s` собираются пакеты, присутствующие на хосте. Каталоги вне allowlist пропускаются (`[INFO] skip unknown`).

В мастере (`-i`) после выбора продуктов/служб можно уточнить **типы логов** внутри каталога каждой службы (ротации вроде `sipdump.txt.2.gz` схлопываются в `sipdump`). По умолчанию — все типы. Вопрос про `mgcpclient` — только если выбран `fss-server` и конкретные типы не уточняли.

Нагрузка хоста: новые воркеры не стартуют, если CPU или RAM системы уже ≥ 80%; минимум один воркер всегда разрешён.

### Offline: фильтр по времени

Диапазон режет **строки** по метке времени в файле, не по mtime.

```bash
./flat_check_2.sh -log -off -t 15m
./flat_check_2.sh -log -off -f -2h -e -1h
./flat_check_2.sh -log -off -f '14.07.2026 10:00' -e '14.07.2026 14:00'
./flat_check_2.sh -log -off -f '14.07.2026 10:00' -t '14.07.2026 14:00'  # -t после -f = to
# -t 2h без -f = за последние 2ч; порядок -t … -f — ошибка; from>to — ошибка
./flat_check_2.sh -log -off -t 1d --chunk-mode size --chunk-size 50M
```

| Размер plain-файла | Стратегия |
|--------------------|-----------|
| &lt; 1MB | один поток `awk` |
| ≥ 1MB, sorted | bisect + параллельный scan окна (early-stop) |
| ≥ 1MB, soft-sorted | bisect с широким backoff, scan окна без early-stop |
| ≥ 1MB, unsorted | параллельный scan всего файла |
| `.gz` / архивы | coarse day → hour/day `zgrep -m1` → один stream-extract (early-stop); `.N.gz` пропускается, если live plain покрывает короткое окно |

В начале `flat_check_2.sh` блок **TUNABLES** (лимиты CPU/MEM хоста, seek/backoff, zgrep, early-stop) — можно править перед запуском. Host-wide CPU/MEM **80%** оставлен намеренно (Zabbix): скрипт берёт доступное до потолка (offline — пул по **файлам**; check — пакеты параллельно; online — tails + тот же gate на пост-работу). Offline прогресс: одна sticky-строка `extract: N% (i/total) file`.

Архив: `YYYY.MM.DD_HH-MM_<hostname>.tar.gz`.

### Сигналы (сбор логов)

| Действие | Поведение |
|----------|-----------|
| Enter (online) | останов → архив |
| `-t` / TERM | graceful → архив |
| Ctrl+C (INT) | abort, без архива |

Рабочие каталоги удаляются только по шаблону `YYYY.MM.DD_HH-MM_*` внутри каталога вывода.

---

## Лог сессии

| Скрипт | Файл | Куда |
|--------|------|------|
| `flat_check.sh` | `flat_check.log` | рядом со скриптом, перезаписывается |
| `flat_check_2.sh` | `flat_check_2.log` | рядом со скриптом; при `-log` — в архив |

---

## Зависимости

Обязательно: `bash`, coreutils, `awk` (gawk), `grep`.

Health: `systemctl`, `dpkg`/`rpm`, `ss`/`netstat`, `curl`, `openssl`, при необходимости `psql` / `top` / `free` / `df`.

Сбор логов (`_2`): `tail`, `gzip` или `pigz`; опционально `tcpdump`, `zcat`.

---

## Cron (текстовый health)

```bash
0 6 * * * /opt/flat/scripts/flat_check.sh >> /var/log/flat/health_check.log 2>&1
```

Для JSON-отправки в Partner см. [`agent/`](agent/).

---

## Добавить пакет

Правки вносятся в **оба** скрипта одинаково:

```bash
PKG_PRODUCT["my-pkg"]="Product Name"
PKG_LEGACY["my-pkg"]="old-name"          # или ""
PKG_PORTS["my-pkg"]="8080"
PKG_API["my-pkg"]="/api/health"
PKG_DEPS["my-pkg"]="nginx,postgresql"
```

---

## Структура кода

| Блок | `flat_check.sh` | `flat_check_2.sh` |
|------|-----------------|-------------------|
| 0–5 | флаги, `PKG_*`, System, пакеты, infra | то же |
| 6–10 | — | поиск и сбор логов |
| 9 | resource-gate опроса пакетов | то же + воркеры сбора |
| 11 | help / argv / main / selftest | мастер + log CLI + main |
