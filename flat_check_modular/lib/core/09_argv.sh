# Модуль: 09_argv.sh
# Слой: core
# Назначение: Разбор аргументов командной строки (usage()/parse_args()) и
#   финальный диспетчер режимов (dispatch_main()) — какой путь выполнить
#   после того, как флаги разобраны и точка входа подключила lib/agent
#   и/или lib/logging (если они понадобились по флагам).
# Публичные функции: usage(), parse_args("$@"), dispatch_main("$@")
# Зависит от: 00_globals.sh, 02_output.sh (die/info/_log_line), 04_os_detect.sh,
#   05_system_metrics.sh, 07_pkg_checks.sh, 08_infra_checks.sh — всегда;
#   отдельные ветки dispatch_main() дополнительно ожидают lib/agent (--json/--push,
#   --config) и/или lib/logging (-i/-log) уже подключёнными точкой входа.
# Не зависит от: ничего внутри lib/agent или lib/logging напрямую — только
#   вызывает их функции по имени, когда до этого дошло исполнение
# Side effects: печатает справку и выходит (usage()/-h/-v), пишет INFO о запуске
#   в сессионный лог, завершает процесс (exit) в конце большинства веток
#
# Источник: usage()+parse_args() перенесены без изменений логики из
#   flat_check_2.sh (строки 8584-9006, полный CLI — health + JSON agent +
#   мастер + сборщик логов, тот же набор флагов что и раньше, ничего не
#   переименовано). dispatch_main() — тело main() оттуда же (строки 9010-9071),
#   вынесенное в отдельную функцию: раньше parse_args() и диспетчеризация были
#   одной функцией main(); в модульной версии их разнесли, чтобы точка входа
#   могла подключить lib/agent/lib/logging МЕЖДУ разбором флагов и запуском —
#   логика внутри не менялась ни на строчку, только физическое разделение.

usage() {
    cat <<'EOF'
flat_check — FLAT/FCS health check + log collector

Usage: flat_check [MODE] [OPTIONS]

Modes:
  (no args)               Health check (installed services only)
  -i, --interactive       Interactive wizard (language, mode, log options)
  --dev                   Extended self-test (VERBOSE health all packages + seek/chunk)
  --selftest simple|extended
                          Self-test: simple = functions launch; extended = same as --dev
  --debug                 Mirror DEBUG-level session log lines to the screen (stderr)
  -log                    Log collector mode
    -on, --online         Real-time capture (tail -F + optional tcpdump)
    -off, --offline       Copy/extract existing logs
    -t, --timeout DUR     Alone: last N / online timeout (e.g. 5h, 30m).
                          After -f: range end (alias of -e/--to). Order -t … -f is an error.
    -f, --from TIME       Range start (e.g. -2h, 25.06.2026 10:00)
    -e, --to TIME         Range end (e.g. -1h, 25.06.2026 12:00)
    --until TIME          Same as -e/--to
                          Range: -t 2h | -f -2h -e -1h | -f '…' -t '…' | -f '…' -e '…'
    -n, --no-tcpdump      Skip network capture (online only)
    -j, --jobs N          Offline: parallel file copy workers (default: nproc*80%, max 32)
    --chunk-mode size|lines  Offline: how to split large output logs (default: size)
    --chunk-size SIZE     Offline: max size per part when --chunk-mode size (e.g. 50M, 200M; default: 100M)
    --chunk-lines N       Offline: max lines per part when --chunk-mode lines (default: 500000)
    --scope brief|extended  Brief = selected services only (default);
                          extended = + system/nginx/postgresql/configs (+ tcpdump online)
    -p, --product NAME    Product to collect (repeatable; see --list-targets)
    -s, --service PKG     Service/package to collect (repeatable)
    --list-targets        List products/services present on host and exit
    --mgcpclient          SoftSwitch/fss-server: include mgcpclient logs (no prompt)
    --no-mgcpclient       SoftSwitch/fss-server: skip mgcpclient logs (no prompt)
  -v, --version           Print script version and exit
  -r, --repo              Show repositories (APT/YUM sources)
  -o, --output DIR        Write archive to DIR (log mode only)
  -h, --help              Show this help and exit

Duration suffixes: s=sec, m=min, h=hour, d=day. Bare number = seconds

Offline log range (IMPORTANT):
  Unlike flat_check_old, time range filters log LINES by timestamp inside files,
  not only by file modification time. Supports formats:
    2026-06-25 14:01:49
    25.06.2026 14:01:49
    08.06.2026 14:17:29.791
  Large plain logs (>=1MB): binary-search start/end offsets, then parallel chunk-scan
  of that window (multi-worker; hang-safe host load gate). Files >=1GB use larger chunks.
  .gz and tiny files: linear awk. Unsorted large plain: parallel full-file chunk-scan.
  Same idea as timegrep/tgrep/archeolog (bisect), plus parallel window scan for throughput.

Log discovery:
  Only known package dirs (PKG_PRODUCT + PKG_LEGACY under /var/log/flat and /opt/flat).
  Unknown folders (e.g. logforflat) are skipped with [INFO] skip unknown.
  Default without -p/-s: all packages present on the host.
  If selection includes fss-server: prompts for mgcpclient (or --mgcpclient / --no-mgcpclient).
  Other SoftSwitch services (fss-frontend/backend/…) do not prompt.
  When skipped: excludes mgcpclient* files inside fss-server dirs as well.
  PostgreSQL / system / nginx / configs: only with --scope extended
  Offline workers respect host-wide ~80% CPU and ~80% memory (/proc/stat, /proc/meminfo):
  workers are not spawned when the whole system is already at or above the limit (Zabbix-friendly).

Log collection messages ([INFO]):
  If logs are missing, the script reports why — this is not an error:
    offline with -t/-f/-e  → [INFO] no logs for the specified time period
    online (-log -on)      → [INFO] no logs during collection
    offline without range  → [INFO] no logs
  PostgreSQL: also reports missing directory, no access (run as root/sudo)
  Absent-log hints show source label (nginx, system, postgresql) and up to 4 file names (+N more)

Log collection:
  Offline: parallel copy of log files (up to nproc workers, -j to override)
  Online: one tail -F process per source log file (same layout as offline archive)
  Empty files created during collection with no new lines are removed before archiving

Session log (<script-name>.log):
  Every run writes a full log of its own work: invocation args or wizard
  choices, which log dirs/files were found and which were discarded (and
  why), host CPU/MEM snapshots at start/stop and every 30s during collection.
  -log: the log file is written inside the collection work dir and packed
        into the same .tar.gz as the collected logs.
  otherwise: written next to the script (or -o/--output) and overwritten on
        each run (no rotation, safe for frequent cron/Zabbix invocations).
  Terminal [OK]/[WARN]/[FAIL]/[INFO] lines are mirrored there with a
  timestamp; fine-grained "found/discarded"/resource entries are DEBUG-level
  and file-only, so the screen output is unaffected.

Required dependencies:
  bash, coreutils (date, find, cp, tar, mkdir, wc, sort)
  awk (gawk) — offline log line filtering by timestamp
  tail — online log collection
  grep — fallback pattern search in logs
  gzip OR pigz — archive compression (pigz preferred if available)

Optional dependencies:
  tcpdump — network capture in online mode (needs root)
  zcat/gzip — reading .gz log files
  curl — API health checks in check mode
  ss or netstat — port checks
  dpkg or rpm — package manager detection
  systemctl — service status checks
  nginx -t — nginx config validation

JSON agent:
  --config FILE         agent config (/etc/flat/flat_check.conf)
  --pkg NAME            single package (health/JSON)
  --product NAME        product filter for health/JSON
                        (in -log mode -p still selects log products)
  --json                emit full health JSON v2 to stdout
  --push                POST JSON to all PUSH_URLS (http/https)
  --host-id|--host-ip|--service-name   host identity overrides

Examples:
  ./flat_check                    # Health check only
  ./flat_check -i                 # Interactive wizard
  ./flat_check --json
  ./flat_check --config /etc/flat/flat_check.conf --json --push
  ./flat_check --pkg fss-server --json
  ./flat_check -log --list-targets
  ./flat_check -log -off -t 2h --scope brief -p SoftSwitch --no-mgcpclient
  ./flat_check -log -off -f -1d --scope extended -s fcs-swui
  ./flat_check -log -on -t 30m --scope brief -p "Contact Center" -s acs-server
  ./flat_check -v                 # Print version
  ./flat_check --selftest simple  # Quick self-test
  ./flat_check --dev              # Extended self-test

Installer / conf: see agent/README.md

---

flat_check — проверка FLAT/FCS + сборщик логов

Использование: flat_check [РЕЖИМ] [ОПЦИИ]

Режимы:
  (без аргументов)        Проверка установленных служб
  -i, --interactive       Интерактивный мастер (язык, режим, параметры логов)
  --dev                   Расширенный самотест (VERBOSE health по всем пакетам + seek/chunk)
  --selftest simple|extended
                          Самотест: simple = запуск функций; extended = как --dev
  --debug                 Дублировать DEBUG-строки сессионного лога на экран (stderr)
  -log                    Режим сборщика логов
    -on, --online         Сбор в реальном времени (tail -F + опц. tcpdump)
    -off, --offline       Копирование/извлечение готовых логов
    -t, --timeout ДЛИТ    Одно: last N / online timeout (например 5h, 30m).
                          После -f: конец диапазона (как -e/--to). Порядок -t … -f — ошибка.
    -f, --from TIME       Начало диапазона (например -2h, 25.06.2026 10:00)
    -e, --to TIME         Конец диапазона (например -1h, 25.06.2026 12:00)
    --until TIME          То же, что -e/--to
                          Диапазон: -t 2h | -f -2h -e -1h | -f '…' -t '…' | -f '…' -e '…'
    -n, --no-tcpdump      Не записывать сетевой трафик (только online)
    -j, --jobs N          Offline: число параллельных копий файлов (по умолч. nproc*80%, макс. 32)
    --chunk-mode size|lines  Offline: как резать крупные логи (по умолч. size)
    --chunk-size РАЗМЕР   Offline: макс. размер одной части при --chunk-mode size (например 50M, 200M; по умолч. 100M)
    --chunk-lines N       Offline: макс. строк в одной части при --chunk-mode lines (по умолч. 500000)
    --scope brief|extended  Краткий = только выбранные службы (по умолч.);
                          расширенный = + system/nginx/postgresql/configs (+ tcpdump online)
    -p, --product NAME    Продукт (повторяемый; см. --list-targets)
    -s, --service PKG     Служба/пакет (повторяемый)
    --list-targets        Показать продукты/службы на хосте и выйти
    --mgcpclient          SoftSwitch/fss-server: включить логи mgcpclient (без вопроса)
    --no-mgcpclient       SoftSwitch/fss-server: не собирать mgcpclient (без вопроса)
  -v, --version           Показать версию скрипта и выйти
  -r, --repo              Показать репозитории (APT/YUM sources)
  -o, --output ДИР        Записать архив в директорию (только -log)
  -h, --help              Показать справку и выйти

Offline диапазон (ВАЖНО):
  В отличие от flat_check_old, диапазон фильтрует СТРОКИ логов по метке времени
  внутри файла, а не только по дате изменения файла. Форматы:
    2026-06-25 14:01:49
    25.06.2026 14:01:49
    08.06.2026 14:17:29.791
  Крупные plain-логи (>=1MB): binary-search границ from/to, затем параллельный
  chunk-scan окна (несколько воркеров; hang-safe лимит нагрузки хоста). При >=1GB —
  крупные чанки. .gz и мелкие файлы: линейный awk. Неупорядоченные крупные: parallel
  full-file scan. Как timegrep/tgrep/archeolog (бисекция) + параллельный проход окна.

Поиск логов:
  Только известные каталоги пакетов (PKG_PRODUCT + PKG_LEGACY в /var/log/flat и /opt/flat).
  Неизвестные папки (например logforflat) пропускаются: [INFO] skip unknown.
  Без -p/-s: все пакеты, присутствующие на хосте.
  Если в выборе есть fss-server: спрашивает про mgcpclient (или --mgcpclient / --no-mgcpclient).
  Остальные службы SoftSwitch (fss-frontend/backend/…) — без вопроса.
  При отказе: исключает и файлы mgcpclient* внутри каталогов fss-server.
  PostgreSQL / system / nginx / configs: только с --scope extended
  Offline-воркеры учитывают нагрузку всей системы ~до 80% CPU и 80% RAM (/proc/stat, /proc/meminfo):
  при CPU или RAM системы ≥80% новые воркеры не стартуют (удобно для Zabbix).

Сообщения при сборе логов ([INFO]):
  Если логов нет — скрипт сообщает об этом, это не ошибка:
    offline с -t/-f/-e  → [INFO] за указанное время логи отсутствуют
    online (-log -on)   → [INFO] за время сбора логи отсутствуют
    offline без диапазона → [INFO] логи отсутствуют
  PostgreSQL: также сообщает об отсутствии каталога, нет доступа (нужен root/sudo)
  Подсказки по отсутствующим логам: метка источника (nginx, system, postgresql) и до 4 имён файлов (+N ещё)

Сбор логов:
  Offline: параллельное копирование файлов (до nproc*80% воркеров, -j для переопределения)
  Online: отдельный tail -F на каждый исходный лог-файл (структура архива как в offline)
  Пустые файлы без новых строк удаляются перед упаковкой архива

Обязательные зависимости:
  bash, coreutils (date, find, cp, tar, mkdir, wc, sort)
  awk (gawk) — фильтрация строк логов offline по метке времени
  tail — online сбор логов
  grep — резервный поиск по шаблонам в логах
  gzip ИЛИ pigz — сжатие архива (предпочтительно pigz)

Опциональные зависимости:
  tcpdump — захват сети в online режиме (нужен root)
  zcat/gzip — чтение .gz логов
  curl — проверка API health в режиме проверки
  ss или netstat — проверка портов
  dpkg или rpm — определение пакетного менеджера
  systemctl — статус служб
  nginx -t — проверка конфигурации nginx

JSON-агент:
  --config FILE         конфиг агента (/etc/flat/flat_check.conf)
  --pkg NAME            один пакет (health/JSON)
  --product NAME        фильтр продукта (health/JSON); в -log — выбор лога
  --json                полный health JSON v2 в stdout
  --push                POST JSON на все PUSH_URLS (http/https)
  --host-id|--host-ip|--service-name   идентификация хоста

Примеры:
  ./flat_check                    # Только проверка
  ./flat_check -i                 # Интерактивный мастер
  ./flat_check --json
  ./flat_check --config /etc/flat/flat_check.conf --json --push
  ./flat_check --pkg fss-server --json
  ./flat_check -log --list-targets
  ./flat_check -log -off -t 2h --scope brief -p SoftSwitch --no-mgcpclient
  ./flat_check -log -off -f -1d --scope extended -s fcs-swui
  ./flat_check -log -on -t 30m --scope brief -p "Contact Center"
  ./flat_check -v                 # Версия
  ./flat_check --selftest simple  # Быстрый самотест
  ./flat_check --dev              # Расширенный самотест

Установка: см. agent/README.md
EOF
    exit 0
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -i|--interactive)
                MODE_INTERACTIVE=1
                shift
                ;;
            -v|--version)
                echo "flat_check ${SCRIPT_VERSION}"
                exit 0
                ;;
            --dev)
                SELFTEST_MODE="extended"
                MODE_DEV=1
                shift
                ;;
            --debug)
                DEBUG_MODE=1
                shift
                ;;
            --selftest)
                if [[ -z "${2:-}" || "$2" == -* ]]; then die "Missing value for --selftest (simple|extended)"; fi
                case "$2" in
                    simple|extended) SELFTEST_MODE="$2" ;;
                    *) die "Invalid --selftest: '$2' (use simple|extended)" ;;
                esac
                [[ "$SELFTEST_MODE" == "extended" ]] && MODE_DEV=1
                shift 2
                ;;
            -log)
                MODE_LOG=1
                shift
                ;;
            -on|--online)
                LOG_SUBMODE="online"
                shift
                ;;
            -off|--offline)
                LOG_SUBMODE="offline"
                shift
                ;;
            -t|--timeout)
                if [[ -z "${2:-}" || "$2" == -* ]]; then die "Missing value for $1"; fi
                # Контекст: если -f уже был — это конец диапазона (alias --to).
                # Иначе — last-N / online timeout.
                if [[ "${CLI_FROM_SET:-0}" -eq 1 ]]; then
                    if [[ "${CLI_TO_SET:-0}" -eq 1 ]]; then
                        die "Conflicting end time: both -e/--to and -t used as range end"
                    fi
                    TO_TIME="$2"
                    CLI_TO_SET=1
                    CLI_T_AS_TO=1
                else
                    TIMEOUT_RAW="$2"
                    CLI_TIMEOUT_SET=1
                fi
                shift 2
                ;;
            --until)
                if [[ -z "${2:-}" ]]; then die "Missing value for $1"; fi
                if [[ "${CLI_TO_SET:-0}" -eq 1 ]]; then
                    die "Conflicting end time: --until with existing -e/-t end"
                fi
                TO_TIME="$2"
                CLI_TO_SET=1
                shift 2
                ;;
            -f|--from)
                if [[ -z "${2:-}" ]]; then die "Missing value for $1"; fi
                if [[ "${CLI_TIMEOUT_SET:-0}" -eq 1 && "${CLI_T_AS_TO:-0}" -eq 0 ]]; then
                    CLI_TIMEOUT_BEFORE_FROM=1
                fi
                FROM_TIME="$2"
                CLI_FROM_SET=1
                shift 2
                ;;
            -e|--to)
                if [[ -z "${2:-}" ]]; then die "Missing value for $1"; fi
                if [[ "${CLI_TO_SET:-0}" -eq 1 ]]; then
                    die "Conflicting end time: -e/--to with existing -t/--until end"
                fi
                TO_TIME="$2"
                CLI_TO_SET=1
                shift 2
                ;;
            -n|--no-tcpdump)
                START_TCPDUMP=0; shift
                ;;
            -j|--jobs)
                if [[ -z "${2:-}" || "$2" == -* ]]; then die "Missing value for $1"; fi
                if ! [[ "$2" =~ ^[1-9][0-9]*$ ]]; then die "Invalid -j/--jobs value: '$2' (positive integer)"; fi
                COLLECTOR_JOBS="$2"; shift 2
                ;;
            --chunk-mode)
                if [[ -z "${2:-}" || "$2" == -* ]]; then die "Missing value for $1"; fi
                case "$2" in
                    size|lines) LOG_CHUNK_MODE="$2" ;;
                    *) die "Invalid --chunk-mode: '$2' (use size|lines)" ;;
                esac
                shift 2
                ;;
            --chunk-size)
                if [[ -z "${2:-}" || "$2" == -* ]]; then die "Missing value for $1"; fi
                if ! LOG_CHUNK_SIZE_BYTES=$(_parse_size_to_bytes "$2") || [[ "$LOG_CHUNK_SIZE_BYTES" -le 0 ]]; then
                    die "Invalid --chunk-size: '$2' (e.g. 50M, 200000000)"
                fi
                LOG_CHUNK_MODE="size"; shift 2
                ;;
            --chunk-lines)
                if [[ -z "${2:-}" || "$2" == -* ]]; then die "Missing value for $1"; fi
                if ! [[ "$2" =~ ^[1-9][0-9]*$ ]]; then die "Invalid --chunk-lines: '$2' (positive integer)"; fi
                LOG_CHUNK_LINES="$2"; LOG_CHUNK_MODE="lines"; shift 2
                ;;
            --scope)
                if [[ -z "${2:-}" || "$2" == -* ]]; then die "Missing value for $1"; fi
                case "$2" in
                    brief|extended) LOG_SCOPE="$2" ;;
                    *) die "Invalid --scope: '$2' (use brief|extended)" ;;
                esac
                shift 2
                ;;
            -p|--product)
                # -log: список продуктов для сбора; иначе — фильтр health/JSON
                if [[ -z "${2:-}" || "$2" == -* ]]; then die "Missing value for $1"; fi
                if [[ $MODE_LOG -eq 1 ]]; then
                    SELECTED_PRODUCTS+=("$2")
                else
                    FILTER_PRODUCT="$2"
                fi
                shift 2
                ;;
            -s|--service)
                if [[ -z "${2:-}" || "$2" == -* ]]; then die "Missing value for $1"; fi
                SELECTED_SERVICES+=("$2"); shift 2
                ;;
            --list-targets)
                LIST_TARGETS=1; shift
                ;;
            --mgcpclient)
                INCLUDE_MGCPCLIENT=1; shift
                ;;
            --no-mgcpclient)
                INCLUDE_MGCPCLIENT=0; shift
                ;;
            -r|--repo)
                SHOW_REPO=1; SHOW_REPOS_JSON=1; shift
                ;;
            -o|--output)
                if [[ -z "${2:-}" || "$2" == -* ]]; then die "Missing value for $1"; fi
                OUTPUT_DIR="$2"; shift 2
                ;;
            --config)
                [[ -z "${2:-}" || "$2" == -* ]] && die "Missing value for $1"
                CONFIG_FILE="$2"; shift 2 ;;
            --pkg)
                [[ -z "${2:-}" || "$2" == -* ]] && die "Missing value for $1"
                SINGLE_PKG="$2"; shift 2 ;;
            --json) OUTPUT_JSON=1; shift ;;
            --push) DO_PUSH=1; shift ;;
            --host-id)
                [[ -z "${2:-}" || "$2" == -* ]] && die "Missing value for $1"
                HOST_ID="$2"; shift 2 ;;
            --host-ip)
                [[ -z "${2:-}" || "$2" == -* ]] && die "Missing value for $1"
                HOST_IP="$2"; shift 2 ;;
            --service-name)
                [[ -z "${2:-}" || "$2" == -* ]] && die "Missing value for $1"
                SERVICE_NAME="$2"; shift 2 ;;
            -h|--help)
                usage
                ;;
            *)
                die "Unknown option: $1 (try -h)"
                ;;
        esac
    done
}

# dispatch_main(): тело main() из flat_check_2.sh (строки 9010-9071) без
# изменений логики, только без повторного вызова parse_args() (это уже
# сделала точка входа flat_check ДО подключения lib/agent/lib/logging).
dispatch_main() {
    init_logging "${OUTPUT_DIR:-$SCRIPT_DIR}"
    _log_line "INFO" "Запуск: $0 $* (аргументов: $#)"

    # -i: интерактивный мастер
    if [[ $MODE_INTERACTIVE -eq 1 ]]; then
        run_interactive_wizard
    fi

    if [[ $LIST_TARGETS -eq 1 ]]; then
        detect_os
        list_log_targets
        exit 0
    fi

    # Самотест: --dev / --selftest / режим 3 мастера
    if [[ -n "${SELFTEST_MODE:-}" ]]; then
        run_selftest "$SELFTEST_MODE"
        exit $?
    fi
    if [[ $MODE_DEV -eq 1 ]]; then
        run_selftest extended
        exit $?
    fi

    [[ -n "$CONFIG_FILE" ]] && _json_load_config "$CONFIG_FILE"

    # JSON / push (1к1 с flat_check.sh) — до -log
    if [[ "$OUTPUT_JSON" -eq 1 || "$DO_PUSH" -eq 1 ]]; then
        run_health_json
        exit $?
    fi

    # -log: только сбор логов
    if [[ $MODE_LOG -eq 1 ]]; then
        _validate_time_cli_combo
        run_log_collection "$LOG_SUBMODE" "$TIMEOUT_RAW"
        [[ $SHOW_REPO -eq 1 ]] && { detect_os; check_repositories; }
        exit 0
    fi

    # Один пакет — текстовый health
    if [[ -n "$SINGLE_PKG" ]]; then
        detect_os
        [[ -n "${PKG_PRODUCT[$SINGLE_PKG]:-}" ]] || die "Unknown package: $SINGLE_PKG"
        check_single_pkg "$SINGLE_PKG"
        exit $?
    fi

    # ПО УМОЛЧАНИЮ: только проверка состояния (исходное поведение flat_check)
    detect_os
    check_system
    local products=("${FLAT_PRODUCTS_ORDER[@]}")
    local p
    if [[ -n "$FILTER_PRODUCT" ]]; then
        products=("$FILTER_PRODUCT")
    fi
    for p in "${products[@]}"; do run_product_checks "$p"; done
    check_infrastructure
    [[ $SHOW_REPO -eq 1 ]] && check_repositories
    print_summary
}
