# flat_check / flat_check_2

Проверка состояния продуктов FLAT/FCS на Linux-хосте (dpkg/rpm + systemd).

| Скрипт | Назначение | Версия |
|--------|------------|--------|
| `flat_check.sh` | health check | 3.8.11 |
| `flat_check_2.sh` | тот же health check + сбор логов | 3.11.11 |
| `flat_check.packages.conf` | каталог пакетов (рядом со скриптом) | — |

Оба скрипта только читают состояние системы и пакетов. Конфиги служб не меняют.  
Для полного сбора логов в `_2` обычно нужен root или sudo.

Периодическая отправка health JSON в Flat Partner (conf, cron, установщик `install_flat_check.sh`) — см. «Push в Flat Partner» ниже, скрипты установки лежат в [`agent/`](agent/).

Отдельно от этого — `agent/flat_check_agent.sh`: самостоятельный скрипт-агент
для прямой интеграции в мониторинг (Zabbix external check, systemd timer).
Функционально похож на `flat_check.sh` (тот же набор проверок), но живёт
полностью независимо — без установщика (копируется одним файлом), без argv,
без сессионного лога. `install_flat_check.sh` его не ставит и не трогает.
Документация — [`agent/README.md`](agent/README.md).

Модульная версия того же функционала (health + JSON-агент + сборщик логов +
мастер, но код разложен по слоям вместо двух монолитов) — в каталоге
[`flat_check_modular/`](flat_check_modular/). Оба варианта независимы и
поддерживаются параллельно; `flat_check.sh`/`flat_check_2.sh` никуда не
делись и продолжают работать как раньше.

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
./flat_check.sh -v    # flat_check 3.8.11
```

---

## Каталог пакетов

`flat_check.packages.conf` лежит **рядом** со скриптом. При старте:

- файл есть → `package catalog: external (/path/…/flat_check.packages.conf)`
- файла нет → встроенный fallback, скрипт не падает: `package catalog: internal (builtin)`

Формат строк:

```bash
_pkg_set "my-pkg" "Product Name" "legacy-name" "8080" "/api/health" "nginx,postgresql"
# PORTS / API / DEPS можно опустить, если пустые
_pkg_set "other-pkg" "Product Name" "old-name"
```

Продукт **Infrastructure** (в конце списка продуктов): `nginx`, `postgresql`, `mariadb` — в каталоге как обычные PKG (проверка без `/opt/flat`).  
Раздел **`=== Depends ===`** — зависимости установленных пакетов (libs, nginx как dep, postgresql, …) в прежнем формате `[OK]/[FAIL]`.

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
| `--debug` | дублировать DEBUG-строки сессионного лога на экран (диагностика) |
| `-v` / `--version` | версия |

Дополнительно оба понимают `--json` / `--push` / `--config` (см. «Push в Flat Partner» ниже).

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
| `.gz` / архивы | coarse day → hour/day `zgrep -m1` (`^` якорь) → stream-extract; soft-стемы (`sipdump`…) без early-stop; `.N.gz` пропускается, если live plain покрывает короткое окно |

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

`--json` в интерактивном терминале печатается с отступами через `jq` (если есть) или `python3 -m json.tool`; при пайпе/редиректе (cron, `| jq`, `> file`) — как раньше, компактно одной строкой. Ни `jq`, ни `python3` не обязательны — без них просто компактный вывод везде.

Сбор логов (`_2`): `tail`, `gzip` или `pigz`; опционально `tcpdump`, `zcat`.

---

## Cron (текстовый health)

```bash
0 6 * * * /opt/flat/scripts/flat_check.sh >> /var/log/flat/health_check.log 2>&1
```

Для JSON-отправки в Partner (installer, конфиг, push) — см. следующий раздел.

---

## Push в Flat Partner

Периодическая отправка health JSON с ноды продукта на ingest Flat Partner.

```text
нода ── cron ──► flat_check --config … --push
                      │
                      ▼  POST JSON (token)
                 Partner ingest (1…N URL)
                      │
                      ▼
                 GET /health → UI
```

Установщик и вспомогательные скрипты — в каталоге [`agent/`](agent/)
(`install_flat_check.sh`, `reinstall_flat_check.sh`, `uninstall_flat_check.sh`).

### Установка

Из корня репозитория (**нужен sudo** для установки в `/usr/local` и `/etc`):

```bash
chmod +x agent/install_flat_check.sh

sudo ./agent/install_flat_check.sh \
  --push-url 'https://partner.example.local/api/v1/health/ingest' \
  --push-token 'SECRET' \
  --host-id ss-n1 \
  --service-name fss-backend
```

`chmod +x` нужен вручную только один раз, на самом `install_flat_check.sh`
(если скачали архивом с GitHub — «Download ZIP» не всегда сохраняет
исполняемый бит). Дальше он сам чинит бит `+x` себе, `reinstall_flat_check.sh`,
`uninstall_flat_check.sh` и `flat_check.sh`/`flat_check_2.sh` — их отдельно
делать исполняемыми не нужно. Не хочется даже этого одного `chmod` —
запустите через `bash agent/install_flat_check.sh ...`, результат тот же.

Без root — только в свой префикс:

```bash
./agent/install_flat_check.sh \
  --bin "$HOME/flat/bin/flat_check" \
  --conf-dir "$HOME/flat/etc" \
  --skip-cron \
  --push-url 'https://…/ingest' --push-token 'SECRET' \
  --host-id ss-n1 --service-name fss-backend
```

Шаги установщика:

1. `flat_check.sh` → `/usr/local/bin/flat_check`
2. каталоги `/etc/flat`, `/var/log/flat`
3. конфиг `/etc/flat/flat_check.conf` (если файла ещё нет)
4. cron `/etc/cron.d/flat-check` — каждые 5 минут `--push`
5. пробный `--json`; `--push` только если URL не из `example.*`

### Несколько URL

```bash
sudo ./agent/install_flat_check.sh \
  --push-url 'https://a.example/ingest,https://b.example/ingest' \
  --push-token 'SECRET' \
  --host-id ss-n1 \
  --service-name fss-backend
```

### Вместе со сборщиком логов

```bash
sudo ./agent/install_flat_check.sh ... --with-logs
# дополнительно: /usr/local/bin/flat_check_2
```

### Прочие флаги установщика

| Флаг | Описание |
|------|----------|
| `--dry-run` | показать действия без изменений |
| `--bin PATH` | путь бинаря |
| `--conf-dir DIR` | каталог конфига (по умолчанию `/etc/flat`) |
| `--conf FILE` | явный путь conf |
| `--cron-spec '*/10 * * * *'` | расписание |
| `--skip-cron` | не ставить cron |
| `--force-conf` | перезаписать существующий conf |
| `--no-test` | без пробного прогона |
| `--host-ip IP` | зафиксировать IP в conf |

Если conf уже есть, параметры `--push-*` / `--host-*` / `--service-name` **не меняют** его — нужен `--force-conf` либо правка файла вручную.

### Переустановка / удаление

```bash
# переустановка: бинарь/cron/каталог пакетов обновляются всегда;
# конфиг — по умолчанию (без -y/-n) СОХРАНЯЕТСЯ как есть
sudo ./agent/reinstall_flat_check.sh
sudo ./agent/reinstall_flat_check.sh -y                    # сбросить конфиг на шаблон
sudo ./agent/reinstall_flat_check.sh -n --push-token NEW    # сохранить конфиг, обновить токен

# удаление: конфиг — по умолчанию (без -y/-n) УДАЛЯЕТСЯ вместе с остальным
sudo ./agent/uninstall_flat_check.sh
sudo ./agent/uninstall_flat_check.sh -n                     # оставить /etc/flat как есть
sudo ./agent/uninstall_flat_check.sh -y                     # удалить конфиг без вопроса
```

`reinstall_flat_check.sh` — тонкая обёртка над `install_flat_check.sh` (принимает те же `--bin`/`--conf-dir`/`--push-*`/…, см. его `-h`); `-y` эквивалентен `--force-conf`. `uninstall_flat_check.sh` не трогает `LOG_DIR` (логи push). Без tty и без `-y`/`-n` оба применяют своё умолчание молча, не дожидаясь ввода.

Отдельный `chmod +x` для `reinstall_flat_check.sh`/`uninstall_flat_check.sh`
не нужен — оба, как и `install_flat_check.sh`, чинят бит `+x` себе и соседям
при каждом запуске, так что достаточно один раз сделать исполняемым любой
из трёх (см. «Установка» выше).

### Конфиг push

Минимальный рабочий набор:

```bash
PUSH_URLS="https://partner.example.local/api/v1/health/ingest"
PUSH_TOKEN="SECRET"
HOST_ID="ss-n1"
SERVICE_NAME="fss-backend"
```

| Ключ | Нужен | Описание |
|------|-------|----------|
| `PUSH_URLS` | для push | URL через запятую/пробел (`http`/`https`) |
| `PUSH_TOKEN` | обычно да | токен стенда |
| `HOST_ID` | да | id хоста в UI |
| `SERVICE_NAME` | да | имя сервиса CI/CD, см. `agent/service_names.md` |
| `HOST_IP` | нет | иначе определяется автоматически |
| `PACKAGES` / `PRODUCT` | нет | сузить набор проверок |
| `PUSH_CONNECT_TIMEOUT` / `PUSH_MAX_TIME` / `PUSH_RETRIES` | нет | таймауты curl |
| `PUSH_INSECURE` | нет | `1` = не проверять TLS-сертификат приёмника (`curl -k`); нужно при self-signed на https, иначе push падает с `FAIL (last http=000)` |

Приоритет значений: **CLI → переменные окружения → conf → автоопределение**.

Полный шаблон: `agent/flat_check.conf.example`.

### Запуск push

```bash
# снимок в stdout
flat_check --config /etc/flat/flat_check.conf --json

# отправка на все PUSH_URLS (без печати JSON)
flat_check --config /etc/flat/flat_check.conf --push

# снимок + отправка
flat_check --config /etc/flat/flat_check.conf --json --push

# один пакет / явная идентичность
flat_check --pkg fss-server --json
flat_check --json --host-id ss-n1 --host-ip 10.0.1.5 --service-name fss-backend
```

Те же флаги есть в `flat_check_2.sh`. Режим `-log` с `--json`/`--push` в одном запуске не комбинируется: JSON-путь завершает процесс раньше.

Cron по умолчанию вызывает `--push` без `--json`, чтобы лог не раздувался телом снимка.

При установке `install_flat_check.sh` копирует `flat_check.packages.conf` рядом с бинарём
(`dirname(INSTALL_BIN)/flat_check.packages.conf`). Если файла нет — скрипт использует
встроенный каталог.

### Формат JSON и push-заголовки

Обязательные поля идентичности: `host_id`, `host_ip`, `service_name`.
Далее: `timestamp`, `script_version`, `os`, `package_manager`, `products`,
`infrastructure`, `summary`, `system`, `certificates`, …

Примеры: `agent/health-payload.example.json`, `agent/ingest-request.example.http`.

Заголовки при push:

```http
Content-Type: application/json
Authorization: Bearer <PUSH_TOKEN>
X-Flat-Host-Id: <HOST_ID>
X-Flat-Service-Name: <SERVICE_NAME>
```

Настройка приёма токена на стороне backend: `agent/backend-token.example.yaml`.

### Проверка push

```bash
flat_check -v
flat_check --selftest simple
flat_check --config /etc/flat/flat_check.conf --json | jq '.host_id, .service_name, .summary'
flat_check --config /etc/flat/flat_check.conf --push
tail -f /var/log/flat/flat_check_push.log
```

| Симптом | Что проверить |
|---------|----------------|
| `PUSH_URLS пуст` | conf / env |
| `curl не найден` | пакет `curl` |
| `http=401/403` | токен, `PUSH_AUTH_HEADER` |
| `http=000` | DNS, firewall, TLS; если приёмник на self-signed https — `PUSH_INSECURE=1`. Точную причину curl (connection refused / timed out / …) смотрите в `flat_check_push.log` или `--push --debug` — строка `push: curl → URL: ...` |
| `service_name: unknown` | `SERVICE_NAME` в conf или `--service-name` |

### Установка вручную

```bash
install -m 0755 flat_check.sh /usr/local/bin/flat_check
install -d -m 0755 /etc/flat /var/log/flat
cp agent/flat_check.conf.example /etc/flat/flat_check.conf
# заполнить PUSH_URLS, PUSH_TOKEN, HOST_ID, SERVICE_NAME
chmod 0640 /etc/flat/flat_check.conf
cp agent/cron.example /etc/cron.d/flat-check
chmod 0644 /etc/cron.d/flat-check
```

---

## Добавить пакет

Предпочтительно в `flat_check.packages.conf` (и в builtin-fallback обоих скриптов, если меняете каталог):

```bash
_pkg_set "my-pkg" "Product Name" "old-name" "8080" "/api/health" "nginx,postgresql"
```

Infra-пакет в каталоге продуктов: `_pkg_set "nginx" "Infrastructure"`.  
Зависимости (`=== Depends ===`) собираются из `PKG_DEPS` + Depends пакетного менеджера.

---

## Структура кода

| Блок | `flat_check.sh` | `flat_check_2.sh` |
|------|-----------------|-------------------|
| 0–5 | флаги, каталог/`PKG_*`, System, пакеты, infra | то же |
| 6–10 | — | поиск и сбор логов |
| 9 | resource-gate опроса пакетов | то же + воркеры сбора |
| 11 | help / argv / main / selftest | мастер + log CLI + main |
