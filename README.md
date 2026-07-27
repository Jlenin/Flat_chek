# flat_check_2 — проверка FLAT/FCS и сбор логов

Один bash-скрипт для серверов с продуктами линейки FLAT / FCS:

1. **Health check** — система (CPU/RAM/диск/сеть/БД/сертификаты/uptime), установленные пакеты, порты, API, зависимости.
2. **Сбор логов** — online (`tail -F`) или offline (копия / вырезка по метке времени в файле), с выбором продукта/службы.

Скрипт только читает состояние и копирует файлы. Конфиги служб не меняет. Для полного сбора (в т.ч. PostgreSQL, tcpdump) обычно нужен **root** или sudo.

Актуальный файл: `flat_check_2.sh` (версия в шапке: `SCRIPT_VERSION`, сейчас **3.6.0**).

---

## Быстрый старт

```bash
chmod +x flat_check_2.sh

# справка (RU + EN)
./flat_check_2.sh -h

# проверка: System → продукты → Infrastructure → Summary
./flat_check_2.sh

# мастер: язык → режим → параметры
./flat_check_2.sh -i
```

Версия при сборе логов:

```text
[INFO] Режим логов: offline / scope=brief (flat_check_2 v3.6.2)
```

Если версии нет или формат старый — на сервере лежит неактуальный файл. Переложите скрипт с репозитория.

---

## Режимы

| Запуск | Что делает |
|--------|------------|
| без аргументов | health check: System + установленные пакеты |
| `-v` / `--version` | версия скрипта |
| `-r` / `--repo` | добавить раздел репозиториев APT/YUM |
| `-i` | интерактивный мастер |
| `--selftest simple` | быстрый самотест (факт запуска функций) |
| `--dev` / `--selftest extended` | расширенный самотест (варианты + health VERBOSE + seek/chunk) |
| `-log -on` / `-log -off` | сбор логов (online / offline) |

---

## Health check

```bash
./flat_check_2.sh
./flat_check_2.sh -r
./flat_check_2.sh -v                    # версия
./flat_check_2.sh --selftest simple
./flat_check_2.sh > /var/log/flat/health_$(date +%Y%m%d_%H%M).log 2>&1
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

---

## Сбор логов

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

Идея как у [timegrep](https://github.com/linux-wizard/timegrep) / tgrep / archeolog (бисекция по timestamp), плюс параллельный проход окна — чтобы вытаскивать большие куски с 20–30GB логов без однопоточного скана всего файла. Порезка логов по суткам у разработчиков — отдельно, позже.

Проверка пути вырезки: входит в `./flat_check_2.sh --dev` (расширенный самотест) и в мастер → «Самотест» → «Расширенный».

Health: продукты/пакеты проверяются параллельно, вывод буферизуется в стабильном порядке.

### Offline примеры

```bash
./flat_check_2.sh -log -off -t 15m
./flat_check_2.sh -log -off -f -2h -e -1h
./flat_check_2.sh -log -off -f '14.07.2026 10:00' -e '14.07.2026 14:00'
./flat_check_2.sh -log -off -o /root
./flat_check_2.sh -log -off -t 1d --chunk-mode lines --chunk-lines 200000
./flat_check_2.sh -log -off -t 1d --chunk-mode size --chunk-size 50M
```

Мастер (`-i` → «Сбор логов» → «Offline») задаёт те же вопросы про разбивку отдельным шагом после выбора диапазона.

### Online

```bash
./flat_check_2.sh -log -on
./flat_check_2.sh -log -on -t 5m
./flat_check_2.sh -log -on -t 30m --scope extended -n   # -n без tcpdump
```

Архив: `YYYY.MM.DD_HH-MM_<hostname>.tar.gz`

### Лог сессии (`flat_check_2.log`)

Каждый запуск пишет полный лог своей работы в `flat_check_2.log`:
аргументы запуска (или выбор в мастере `-i`), какие каталоги/файлы логов
найдены и какие отклонены и почему (архивная копия при наличии живой
обычной, файл вне запрошенного диапазона времени и т.п.), снимки
загрузки CPU/MEM хоста в начале/конце и раз в 30с во время сбора,
итоговый результат каждого шага.

* При `-log` (online/offline) — лог кладётся **внутрь рабочей директории
  сбора** и упаковывается в тот же `.tar.gz`, что и сами логи.
* Иначе (health check, `-i`, `--dev`/`--selftest`) — лог пишется рядом со
  скриптом (или в `-o`/`--output`, если указан) и **перезаписывается** на
  каждом запуске — без ротации, чтобы файл не разрастался при частых
  запусках из cron/Zabbix.

На экран лог не влияет: строки `[OK]/[WARN]/[FAIL]/[INFO]`, которые видно
в терминале, дублируются туда же с таймстампом; более подробные записи
"что найдено/отклонено" и снимки ресурсов пишутся только в файл (уровень
`DEBUG`), чтобы не перегружать интерактивный вывод.

---

## Сигналы и безопасность под root

Удаление рабочих каталогов только по шаблону `YYYY.MM.DD_HH-MM_*` внутри каталога вывода.

| Действие | Поведение |
|----------|-----------|
| Enter (online) | останов → архив |
| `-t` / мало места (TERM) | graceful → архив |
| Ctrl+C (INT) | abort, без архива |

---

## Зависимости

Обязательно: `bash`, coreutils, `awk` (gawk), `tail`, `grep`, `gzip`/`pigz`.

По ситуации: `tcpdump`, `curl`, `ss`/`netstat`, `systemctl`, `dpkg`/`rpm`, `zcat`, `openssl` (сертификаты), `psql` (кластер PostgreSQL), `top`/`free`/`df`.

---

## Cron / CI

```bash
0 6 * * * /opt/flat/scripts/flat_check_2.sh >> /var/log/flat/health_check.log 2>&1
```

Вывод health check рассчитан на парсинг бэкендом Flat Partner (`GET /health` → JSON), в т.ч. блок System для страницы «Система».

---

## Добавить пакет в health check

```bash
PKG_PRODUCT["my-pkg"]="Product Name"
PKG_LEGACY["my-pkg"]="old-name"          # или ""
PKG_PORTS["my-pkg"]="8080"
PKG_API["my-pkg"]="/api/health"
PKG_DEPS["my-pkg"]="nginx,postgresql"
```

---

## Устройство скрипта

| Блок | Содержание |
|------|------------|
| 0 | флаги, константы |
| 1 | метаданные `PKG_*` |
| 2 | вывод, локализация |
| 3 | ОС / PM |
| 3b | System metrics |
| 4 | health check пакетов |
| 5 | Infrastructure / репозитории |
| 6–10 | discovery и сбор логов |
| 11 | wizard, help, argv, main |

---

## Связанные файлы

| Файл | Заметка |
|------|---------|
| `flat_check_2.sh` | актуальный (**3.6.0**), единственный рабочий файл в этом репозитории |
| `README.md` | этот файл |
