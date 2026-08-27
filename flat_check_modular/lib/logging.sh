# Слой: logging
# Подключается при -log/-i/--dev/любом --selftest/--list-targets.
# Сборщик логов: TUNABLES, парсеры времени, поиск логов (FLAT/PostgreSQL),
# извлечение по диапазону (seek/bisect), online/offline режимы.
#
# Разделы этого файла (в порядке подключения; искать по "РАЗДЕЛ: <имя>"):
#   00_tunables              Настраиваемые константы сборщика логов — лимиты ресурсов хоста, пороги seek/bisect для больших plain-логов, пороги zgrep/archive-фильтров, состояние прогресса offline-extract, пути к конфигам служб. Это тот самый "блок TUNABLES", который README называет местом для правки перед запуском — в модульной версии он вынесен в отдельный файл вместо начала монолита.
#   01_time_filters          Парсеры длительности/момента времени (parse_duration, parse_time_point) и фильтры строк лог-файлов по временной метке — общая база offline/online диапазонов.
#   02_log_discovery         Поиск каталогов логов известных пакетов (PKG_PRODUCT/PKG_LEGACY под /var/log/flat и /opt/flat), список целей для -log --list-targets, отбор по -p/-s и mgcpclient.
#   03_postgres_discovery    (1) Поиск логов PostgreSQL (путь, формат имени, ротация) отдельно от каталога пакетов FLAT — своя эвристика путей/прав доступа. (2) Общий seek/bisect-движок извлечения диапазона из большого файла по временной метке (time_to_epoch, filter_log_file_by_range, бисекция смещений, параллельный chunk-scan) — используется НЕ ТОЛЬКО для PostgreSQL, а вообще всеми extract-модулями (04/05/06) и синтетическим self-test'ом seek+chunk. Оба назначения физически лежат в одном файле только потому, что так исторически сложилось в оригинале (см. "Источник" ниже) — при дальнейшем рефакторинге это кандидат на разделение на два файла.
#   04_extract_single        Автономное извлечение диапазона строк из ОДНОГО файла лога службы (parce_service_log) — базовый строительный блок для offline-сбора.
#   05_extract_multi         Извлечение диапазона из ВСЕХ файлов ротации лога службы (parce_service_logs) — соответствие служба → известные директории логов, применение parce_service_log к каждому файлу.
#   06_extract_apply         Применение parce_service_log(s) к уже найденным директориям: потоковое сравнение/дедупликация файлов по диапазону, zgrep/архивные эвристики, прогресс offline-extract между параллельными job'ами по файлам, пул воркеров.
#   07_collector             Процессы сборщика логов: online tail -F, обработка сигналов (INT/TERM/Enter), безопасное удаление рабочих каталогов только по шаблону архива, resource-gate воркеров сбора.
#   08_online_offline        Верхнеуровневые режимы -log -on/-off: online = tail -F + опциональный tcpdump до Enter/TERM; offline = параллельное копирование/извлечение по диапазону, упаковка в .tar.gz.
#
# До объединения (см. git-историю фазы 5) это было 9 отдельных
# файлов lib/logging/NN_name.sh — слиты в один по итогам код-ревью: три с половиной
# десятка файлов на весь проект оказались избыточной дробностью для инструмента,
# который должен быть понятен человеку без глубокого знания bash. Внутренние
# границы (заголовки "РАЗДЕЛ:") и порядок — те же самые.
# ==========================================================================
# РАЗДЕЛ: 00_tunables
# ==========================================================================
# Назначение: Настраиваемые константы сборщика логов — лимиты ресурсов хоста,
#   пороги seek/bisect для больших plain-логов, пороги zgrep/archive-фильтров,
#   состояние прогресса offline-extract, пути к конфигам служб. Это тот самый
#   "блок TUNABLES", который README называет местом для правки перед запуском —
#   в модульной версии он вынесен в отдельный файл вместо начала монолита.
# Публичные функции: (нет функций — только константы/состояние)
# Зависит от: ничего (грузится в числе первых файлов lib/logging)
# Не зависит от: LOG_CHUNK_MODE/LOG_CHUNK_SIZE_BYTES/LOG_CHUNK_LINES и
#   _CPU_PREV_IDLE/_CPU_PREV_TOTAL сюда НЕ включены — они уже объявлены в
#   lib/core.sh (раздел 00_globals) и к моменту подключения lib/logging могут быть уже
#   изменены parse_args() (--chunk-mode/--chunk-size/--chunk-lines); повторное
#   объявление здесь затёрло бы выбор пользователя обратно на дефолт.
# Side effects: нет
#
# Источник: перенесено без изменений логики из flat_check_2.sh (строки 147-194,
#   204-225 — секция 0, за вычетом LOG_CHUNK_*/_CPU_PREV_* по причине выше).

# --- ресурсы хоста (не доля скрипта) -----------------------------------------
# Offline параллельное копирование: 0 = авто (nproc * RESOURCE_CPU_LIMIT/100)

COLLECTOR_JOBS=0
# Общесистемный лимит CPU/MEM: придерживать лишние воркеры, когда ВСЯ
# система достигла этих лимитов (/proc). Минимум 1 воркер всегда разрешён.
RESOURCE_CPU_LIMIT=80
RESOURCE_MEM_LIMIT=80
# Макс. секунд ожидания запаса ресурсов перед ещё одним воркером (≥1 уже работает)
RESOURCE_WAIT_MAX=120
# Как часто фоновый монитор ресурсов пишет снимок CPU/MEM в лог сессии
RESOURCE_LOG_INTERVAL_SEC=30

# --- seek / параллельное извлечение plain ------------------------------------
# Минимальный размер для бисекции + параллельного извлечения чанков
SEEK_MIN_BYTES=$((1 * 1024 * 1024))
# Монолиты масштаба SoftSwitch: увеличенное окно параллелизма
SEEK_HUGE_BYTES=$((1024 * 1024 * 1024))
# Размер чанка параллельного сканирования внутри байтового диапазона [from,to]
SEEK_CHUNK_BYTES=$((64 * 1024 * 1024))
# Проба-чанк для выборки timestamp по смещению
SEEK_PROBE_BYTES=131072
# Отступ перед начальным смещением (строгий sorted)
SEEK_BACKOFF_BYTES=$((1024 * 1024))
# Отступ для soft-sorted (середина «плавает», но first≤last) — шире, без early-stop
SEEK_SOFT_SORT_BACKOFF_BYTES=$((32 * 1024 * 1024))
# Внутренняя гранулярность параллельного извлечения ОДНОГО файла в
# parce_service_log() (не итоговый part_*.log — см. LOG_CHUNK_*).
MAX_LOG_CHUNK_SIZE=$((100 * 1024 * 1024))

# --- offline archive filter / stream extract ---------------------------------
# Грубый day-отсев: ±1 календарный день (NYE / TZ)
LOG_RANGE_DAY_MARGIN_SEC=$((24 * 3600))
# Макс. число дней для zgrep-паттернов по календарным датам
LOG_ZGREP_MAX_DAYS=32
# Макс. число часов для hour-level zgrep-паттернов
LOG_ZGREP_MAX_HOURS=48
# При длине диапазона ≤ этого — hour-level zgrep (−m 1); miss → skip файла
LOG_ZGREP_HOUR_MAX_SEC=$((24 * 3600))
# Короткое окно: не читать stem.N.gz, если живой stem покрывает [from,to]
LOG_PLAIN_COVERS_ROTATED_MAX_SEC=$((24 * 3600))
# После zgrep-miss не гонять 12-point full-decompress (dated → skip;
# undated без инструмента → один extract). 0 = старое поведение (12-point).
LOG_ARCHIVE_SKIP_PROBE_ON_ZGREP_MISS=1
# Stream-extract архива: early-stop после to (+ grace), как у sorted plain.
# Soft-стемы (sipdump/…) всегда без early-stop — см. _log_archive_stream_sorted().
LOG_ARCHIVE_STREAM_SORTED=1
# Допуск (сек) после to перед early-stop — мелкий reorder потоков SoftSwitch
LOG_ARCHIVE_EARLY_STOP_GRACE_SEC=300

# Прогресс offline-extract (файлы состояния между parallel dir-jobs)
_COLLECT_PROGRESS_DIR=""
_COLLECT_PROGRESS_TOTAL=0

# Epoch полуночи дня файла, который сейчас разбирает line_epoch() (awk, см.
# _AWK_LINE_EPOCH) — нужен только логам без даты в самой строке (только
# HH:MM:SS, дата — в имени файла). Выставляется _infer_file_midnight_epoch()
# в начале обработки каждого файла (parce_service_log(),
# filter_log_file_by_range()); "" — не относится к текущему файлу /
# определить не удалось.
_LOG_REF_MIDNIGHT_EPOCH=""

# Пути к конфигам для извлечения логов
CONFIG_PATHS=(
    "/opt/flat/switchserver/settings.ini"
    "/opt/flat/fss-server/settings.ini"
    "/etc/flat/srclient/settings.ini"
    "/opt/flat/fss-srclient/settings.ini"
    "/etc/mediasrv/config.xml"
    "/opt/flat/fss-mediasrv/config.xml"
    "/opt/flat/flat-file/config.yml"
)

# ==========================================================================
# РАЗДЕЛ: 01_time_filters
# ==========================================================================
# Назначение: Парсеры длительности/момента времени (parse_duration, parse_time_point) и фильтры строк лог-файлов по временной метке — общая база offline/online диапазонов.
# Публичные функции: parse_duration(), parse_time_point(), time_to_epoch(), line_epoch()-хелперы и фильтры по диапазону
# Зависит от: lib/core (die/warn), 00_tunables.sh
# Не зависит от: log_discovery/postgres_discovery/extract_*/collector — используется ими, а не наоборот
# Side effects: нет — чистые парсеры/фильтры
#
# Источник: перенесено без изменений логики из flat_check_2.sh (строки 6204-6363).

# --- 8. Парсеры длительности / момента времени + фильтры строк по timestamp -----
# Offline: filter_log_file_by_range* — выше в файле, рядом с collect_postgresql.
# Общие хелперы длительности:

parse_duration() {
    local raw="$1"
    PARSE_RESULT_NUM=0
    PARSE_RESULT_UNIT=""
    if [[ "$raw" =~ ^[0-9]+$ ]]; then
        PARSE_RESULT_NUM="$raw"
        PARSE_RESULT_UNIT="s"
        return 0
    fi
    if [[ "$raw" =~ ^([0-9]+)([smhd])$ ]]; then
        PARSE_RESULT_NUM="${BASH_REMATCH[1]}"
        PARSE_RESULT_UNIT="${BASH_REMATCH[2]}"
        return 0
    fi
    return 1
}

duration_to_seconds() {
    local num="$1" unit="$2"
    case "$unit" in s) echo "$num" ;; m) echo "$(( num * 60 ))" ;; h) echo "$(( num * 3600 ))" ;; d) echo "$(( num * 86400 ))" ;; *) echo "$num" ;; esac
}

# Разбор человеко-читаемого размера (--chunk-size) в байты: "500000000",
# "100M"/"100MB", "2G"/"2GB", "512K"/"512KB" (регистр не важен, суффикс "B"
# необязателен). Печатает байты, возвращает 1 при нераспознанном формате.
_parse_size_to_bytes() {
    local raw="${1^^}" num unit
    if [[ "$raw" =~ ^([0-9]+)$ ]]; then
        echo "${BASH_REMATCH[1]}"
        return 0
    fi
    if [[ "$raw" =~ ^([0-9]+)(K|M|G)B?$ ]]; then
        num="${BASH_REMATCH[1]}"
        unit="${BASH_REMATCH[2]}"
        case "$unit" in
            K) echo "$((num * 1024))" ;;
            M) echo "$((num * 1024 * 1024))" ;;
            G) echo "$((num * 1024 * 1024 * 1024))" ;;
        esac
        return 0
    fi
    return 1
}

# ============================================================
# Разбор точки во времени: абсолютная дата или относительное смещение
#   "-2h"        → 2 часа назад
#   "2025-06-25 10:00" → абсолютная дата
#   "25.06.2025 10:00" → абсолютная дата (DD.MM.YYYY)
# ============================================================
parse_time_point() {
    local raw="$1"
    local result=""
    # Относительное смещение: начинается с + или -
    if [[ "$raw" =~ ^[+-] ]]; then
        local sign="${raw:0:1}"
        local dur="${raw:1}"
        if ! parse_duration "$dur"; then
            return 1
        fi
        local unit_str=""
        case "$PARSE_RESULT_UNIT" in
            s) unit_str="seconds" ;;
            m) unit_str="minutes" ;;
            h) unit_str="hours" ;;
            d) unit_str="days" ;;
        esac
        result=$(date -d "${sign}${PARSE_RESULT_NUM} ${unit_str}" "+%Y-%m-%d %H:%M:%S" 2>/dev/null)
    else
        # Абсолютная дата: пробуем несколько форматов
        result=$(date -d "$raw" "+%Y-%m-%d %H:%M:%S" 2>/dev/null)
        # Запасной вариант: DD.MM.YYYY HH:MM[:SS] → YYYY-MM-DD HH:MM:SS
        if [[ -z "$result" && "$raw" =~ ^([0-9]{2})\.([0-9]{2})\.([0-9]{4})[[:space:]]([0-9]{2}):([0-9]{2})(:([0-9]{2}))? ]]; then
            local d="${BASH_REMATCH[1]}" m="${BASH_REMATCH[2]}" y="${BASH_REMATCH[3]}"
            local hh="${BASH_REMATCH[4]}" mm="${BASH_REMATCH[5]}"
            local ss="${BASH_REMATCH[7]:-00}"
            result=$(date -d "${y}-${m}-${d} ${hh}:${mm}:${ss}" "+%Y-%m-%d %H:%M:%S" 2>/dev/null)
        fi
        # Запасной вариант: DD.MM HH:MM[:SS] (текущий год)
        if [[ -z "$result" && "$raw" =~ ^([0-9]{2})\.([0-9]{2})[[:space:]]([0-9]{2}):([0-9]{2})(:([0-9]{2}))? ]]; then
            local d="${BASH_REMATCH[1]}" m="${BASH_REMATCH[2]}"
            local hh="${BASH_REMATCH[3]}" mm="${BASH_REMATCH[4]}"
            local ss="${BASH_REMATCH[6]:-00}"
            local y; y=$(date +%Y)
            result=$(date -d "${y}-${m}-${d} ${hh}:${mm}:${ss}" "+%Y-%m-%d %H:%M:%S" 2>/dev/null)
        fi
    fi
    [[ -n "$result" ]] && echo "$result" && return 0
    return 1
}

# Разбирает FROM_TIME / TO_TIME / timeout_raw (режим «за последние Nd»)
# в пару абсолютных строк "%Y-%m-%d %H:%M:%S". Печатает две строки:
#   1) from_time  2) to_time
# (обе пустые = собрать все логи без фильтра по времени).
#
# TO как смещение от FROM: принимаем и "+3h", и голый "3h"/"30m"/"1d"
# (wizard просит "+3h", но без плюса GNU date -d "3h" даёт мусорную
# абсолютную дату — часто раньше from — и диапазон оказывается пустым/перевёрнутым).
_offline_resolve_time_bounds() {
    local from_raw="${1:-}" to_raw="${2:-}" timeout_raw="${3:-}"
    local from_time="" to_time="" offset_cand from_epoch add_sec

    if [[ -n "$from_raw" ]]; then
        from_time=$(parse_time_point "$from_raw") || return 1
    fi
    if [[ -n "$to_raw" ]]; then
        offset_cand="$to_raw"
        [[ "$offset_cand" =~ ^\+ ]] && offset_cand="${offset_cand:1}"
        if [[ -n "$from_time" ]] && parse_duration "$offset_cand"; then
            from_epoch=$(date -d "$from_time" "+%s" 2>/dev/null)
            [[ -n "$from_epoch" ]] || return 1
            add_sec=$(duration_to_seconds "$PARSE_RESULT_NUM" "$PARSE_RESULT_UNIT")
            to_time=$(date -d "@$(( from_epoch + add_sec ))" "+%Y-%m-%d %H:%M:%S" 2>/dev/null)
            [[ -n "$to_time" ]] || return 1
        else
            to_time=$(parse_time_point "$to_raw") || return 1
        fi
    fi
    if [[ -z "$from_time" && -n "$timeout_raw" ]]; then
        from_time=$(parse_time_point "-${timeout_raw}") || true
    fi
    # Только from («за последние Nd») → верхняя граница = сейчас.
    # Иначе пустой to раньше доходил до date -d "" → полночь сегодня.
    if [[ -n "$from_time" && -z "$to_time" ]]; then
        to_time=$(date "+%Y-%m-%d %H:%M:%S")
    fi
    # from > to — явная ошибка (раньше тихо давало пустую выборку)
    if [[ -n "$from_time" && -n "$to_time" ]]; then
        local fe te
        fe=$(date -d "$from_time" "+%s" 2>/dev/null) || return 1
        te=$(date -d "$to_time" "+%s" 2>/dev/null) || return 1
        if [[ "$fe" -gt "$te" ]]; then
            return 2
        fi
    fi
    printf '%s\n%s\n' "$from_time" "$to_time"
}

# Проверка комбинации CLI -t/-f/-e после parse_args (до сбора).
_validate_time_cli_combo() {
    local rc=0
    if [[ "${CLI_TIMEOUT_BEFORE_FROM:-0}" -eq 1 && "${CLI_FROM_SET:-0}" -eq 1 ]]; then
        die "Invalid flag order: -t before -f. Use -f … -t … (range end) or -t alone (last N / timeout)."
    fi
    if [[ "${CLI_TIMEOUT_SET:-0}" -eq 1 && "${CLI_FROM_SET:-0}" -eq 1 && "${CLI_T_AS_TO:-0}" -eq 0 ]]; then
        die "Cannot combine -t (last N) with -f/--from. Use -f … -t … or -f … -e … for a range."
    fi
    # from>to ловим до discover пакетов (понятная ошибка сразу)
    if [[ -n "${FROM_TIME:-}" && -n "${TO_TIME:-}" ]]; then
        _offline_resolve_time_bounds "$FROM_TIME" "$TO_TIME" "" >/dev/null 2>&1 || rc=$?
        if [[ "$rc" -eq 2 ]]; then
            die "Invalid time range: from is after to (from='${FROM_TIME}' to='${TO_TIME}'). Swap -f/--from and -e/--to (or -t as end)."
        fi
    fi
}


# ==========================================================================
# РАЗДЕЛ: 02_log_discovery
# ==========================================================================
# Назначение: Поиск каталогов логов известных пакетов (PKG_PRODUCT/PKG_LEGACY под /var/log/flat и /opt/flat), список целей для -log --list-targets, отбор по -p/-s и mgcpclient.
# Публичные функции: list_log_targets(), поиск/фильтрация директорий логов по пакету/продукту
# Зависит от: lib/core (PKG_PRODUCT/PKG_LEGACY/detect_os), 00_tunables.sh
# Не зависит от: 01_time_filters.sh, postgres/extract-модули — сам вызывается ими раньше по конвейеру
# Side effects: запускает find по /var/log/flat и /opt/flat; печатает [INFO] skip unknown
#
# Источник: перенесено без изменений логики из flat_check_2.sh (строки 2605-3148).

# --- 6. Поиск директорий логов --------------------------------------------------
# Только пути из белого списка: PKG_PRODUCT (+ PKG_LEGACY) через find_log_dirs_for_pkg.
# Неизвестные директории внутри /var/log/flat (например, logforflat) пропускаются.


_log_dir_add_unique() {
    local candidate="$1"
    [[ -z "$candidate" || ! -d "$candidate" ]] && return 1
    candidate=$(readlink -f "$candidate" 2>/dev/null || echo "$candidate")
    local existing
    for existing in "${DISCOVERED_LOG_DIRS[@]+"${DISCOVERED_LOG_DIRS[@]}"}"; do
        [[ "$existing" == "$candidate" ]] && return 1
    done
    DISCOVERED_LOG_DIRS+=("$candidate")
    return 0
}

_log_path_to_dir() {
    local path="$1"
    [[ -z "$path" ]] && return 1
    # Разворачиваем только ведущий ~ (избегаем eval на путях из конфига)
    [[ "$path" == "~" ]] && path="$HOME"
    [[ "$path" == "~/"* ]] && path="$HOME/${path:2}"
    if [[ -d "$path" ]]; then
        echo "$path"
    elif [[ -f "$path" ]]; then
        dirname "$path"
    fi
}

# Нормализовать имя продукта/службы для нечёткого сравнения: в нижний регистр, убрать пробелы/_/-
_norm_target_name() {
    echo "$1" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]_-'
}

_pkg_names_for_lookup() {
    local pkg="$1"
    local legacy="${PKG_LEGACY[$pkg]:-}"
    local names=("$pkg") old
    local -a _leg_arr=()
    if [[ -n "$legacy" ]]; then
        IFS=',' read -ra _leg_arr <<< "$legacy"
        for old in "${_leg_arr[@]}"; do
            old="${old#"${old%%[![:space:]]*}"}"
            old="${old%"${old##*[![:space:]]}"}"
            [[ -n "$old" ]] && names+=("$old")
        done
    fi
    printf '%s\n' "${names[@]}"
}

_is_known_log_basename() {
    local name="$1" pkg alias
    [[ -z "$name" ]] && return 1
    for pkg in "${!PKG_PRODUCT[@]}"; do
        while IFS= read -r alias; do
            [[ "$name" == "$alias" ]] && return 0
        done < <(_pkg_names_for_lookup "$pkg")
    done
    return 1
}

_pkg_present_on_host() {
    local pkg="$1" alias
    is_pkg_installed_tiny "$pkg" "${PKG_LEGACY[$pkg]:-}" && return 0
    while IFS= read -r alias; do
        [[ -d "/opt/flat/${alias}" ]] && return 0
        [[ -d "/var/log/flat/${alias}" ]] && return 0
    done < <(_pkg_names_for_lookup "$pkg")
    return 1
}

_pkg_add_unique_to() {
    # $1 = имя массива в стиле nameref через eval; проще: использовать глобальный SELECTED_PKGS
    local pkg="$1" e
    for e in "${SELECTED_PKGS[@]+"${SELECTED_PKGS[@]}"}"; do
        [[ "$e" == "$pkg" ]] && return 1
    done
    SELECTED_PKGS+=("$pkg")
    return 0
}

# Истина, если каноническое имя продукта совпадает с вводом пользователя (точно или нормализованно)
_product_name_matches() {
    local want="$1" have="$2"
    [[ -z "$want" || -z "$have" ]] && return 1
    [[ "$want" == "$have" ]] && return 0
    [[ "$(_norm_target_name "$want")" == "$(_norm_target_name "$have")" ]] && return 0
    return 1
}

# Разрешить строку продукта от пользователя в каноническое значение PKG_PRODUCT (или пусто)
_resolve_product_canonical() {
    local want="$1" prod
    local -A seen=()
    for prod in "${PKG_PRODUCT[@]}"; do
        [[ -n "${seen[$prod]:-}" ]] && continue
        seen["$prod"]=1
        if _product_name_matches "$want" "$prod"; then
            echo "$prod"
            return 0
        fi
    done
    return 1
}

# Разрешить строку службы/пакета в ключ PKG_PRODUCT
_resolve_service_canonical() {
    local want="$1" pkg alias
    for pkg in "${!PKG_PRODUCT[@]}"; do
        while IFS= read -r alias; do
            if [[ "$want" == "$alias" ]] || [[ "$(_norm_target_name "$want")" == "$(_norm_target_name "$alias")" ]]; then
                echo "$pkg"
                return 0
            fi
        done < <(_pkg_names_for_lookup "$pkg")
    done
    return 1
}

# Заполнить SELECTED_PKGS из SELECTED_PRODUCTS / SELECTED_SERVICES (либо все присутствующие пакеты)
resolve_selected_packages() {
    SELECTED_PKGS=()
    local prod pkg canon want
    local has_filter=0

    if [[ ${#SELECTED_PRODUCTS[@]} -gt 0 || ${#SELECTED_SERVICES[@]} -gt 0 ]]; then
        has_filter=1
    fi

    if [[ "$has_filter" -eq 0 ]]; then
        for pkg in "${!PKG_PRODUCT[@]}"; do
            _pkg_present_on_host "$pkg" && _pkg_add_unique_to "$pkg"
        done
        return 0
    fi

    for want in "${SELECTED_PRODUCTS[@]+"${SELECTED_PRODUCTS[@]}"}"; do
        canon=$(_resolve_product_canonical "$want") || die "Unknown product: '$want' (try --list-targets)"
        for pkg in "${!PKG_PRODUCT[@]}"; do
            if _product_name_matches "$canon" "${PKG_PRODUCT[$pkg]}"; then
                _pkg_present_on_host "$pkg" && _pkg_add_unique_to "$pkg"
            fi
        done
    done

    for want in "${SELECTED_SERVICES[@]+"${SELECTED_SERVICES[@]}"}"; do
        canon=$(_resolve_service_canonical "$want") || die "Unknown service: '$want' (try --list-targets)"
        if _pkg_present_on_host "$canon"; then
            _pkg_add_unique_to "$canon"
        else
            warn "Service not present on host (skipped): $canon"
        fi
    done

    if [[ "$has_filter" -eq 1 && ${#SELECTED_PKGS[@]} -eq 0 ]]; then
        die "No matching packages present on host for the given -p/-s (try --list-targets)"
    fi
}

# Истина, если в итоговом выборе есть служба fss-server (единственная, в списке
# или через продукт SoftSwitch / «все»). Логи mgcpclient бывают только у неё —
# для fss-frontend/fss-backend/… вопрос и EXTRA-каталоги не нужны.
_selection_includes_fss_server() {
    local pkg
    for pkg in "${SELECTED_PKGS[@]+"${SELECTED_PKGS[@]}"}"; do
        [[ "$pkg" == "fss-server" ]] && return 0
    done
    return 1
}

# Найти директории логов mgcpclient (не входят в белый список PKG_PRODUCT)
_find_mgcpclient_log_dirs() {
    local d target
    local -A seen=()
    for d in \
        "/var/log/flat/mgcpclient" \
        "/opt/flat/mgcpclient/log" \
        "/opt/flat/mgcpclient/logs" \
        "/var/log/mgcpclient"
    do
        [[ -d "$d" ]] || continue
        target=$(readlink -f "$d" 2>/dev/null || echo "$d")
        [[ -z "${seen[$target]:-}" ]] || continue
        seen["$target"]=1
        echo "$target"
    done
}

# Спросить / применить включение fss-server → mgcpclient; заполняет EXTRA_LOG_DIRS при согласии
# quiet=1: только перезаполнить EXTRA_LOG_DIRS, без запроса/спама (INCLUDE уже решён)
_resolve_mgcpclient_option() {
    local quiet="${1:-0}"
    EXTRA_LOG_DIRS=()
    _selection_includes_fss_server || return 0

    if [[ -z "${INCLUDE_MGCPCLIENT}" ]]; then
        if [[ "$quiet" -eq 1 ]]; then
            # Второй проход без предварительного решения — тихо пропускаем
            INCLUDE_MGCPCLIENT=0
        elif [[ -t 0 ]]; then
            echo ""
            echo -n "$(_l ask_mgcpclient)"
            local ans=""
            read -r ans 2>/dev/null || true
            if _wizard_is_yes "$ans"; then
                INCLUDE_MGCPCLIENT=1
            else
                INCLUDE_MGCPCLIENT=0
            fi
        else
            info "$(_l mgcpclient_default_no)"
            INCLUDE_MGCPCLIENT=0
        fi
    fi

    if [[ "${INCLUDE_MGCPCLIENT}" -eq 1 ]]; then
        local d
        while IFS= read -r d; do
            [[ -n "$d" ]] && EXTRA_LOG_DIRS+=("$d")
        done < <(_find_mgcpclient_log_dirs)
        if [[ "$quiet" -eq 0 ]]; then
            if [[ ${#EXTRA_LOG_DIRS[@]} -eq 0 ]]; then
                info "$(_l mgcpclient_not_found)"
            else
                info "$(_l mgcpclient_include): ${#EXTRA_LOG_DIRS[@]}"
                for d in "${EXTRA_LOG_DIRS[@]}"; do
                    info "  → $d"
                done
            fi
        fi
    else
        [[ "$quiet" -eq 0 ]] && info "$(_l mgcpclient_skip)"
    fi
    MGCPCLIENT_RESOLVED=1
}

# Вывести продукты/службы, доступные на этом хосте
list_log_targets() {
    local pkg prod
    local -A prod_pkgs=()
    local -A prod_seen=()

    echo "=== Log targets (present on host) ==="
    echo ""
    echo "Products (--product / -p):"
    for pkg in $(printf '%s\n' "${!PKG_PRODUCT[@]}" | sort); do
        _pkg_present_on_host "$pkg" || continue
        prod="${PKG_PRODUCT[$pkg]}"
        if [[ -z "${prod_pkgs[$prod]:-}" ]]; then
            prod_pkgs["$prod"]="$pkg"
        else
            prod_pkgs["$prod"]="${prod_pkgs[$prod]},$pkg"
        fi
    done
    for prod in $(printf '%s\n' "${!prod_pkgs[@]}" | sort); do
        echo "  - $prod"
        echo "      services: ${prod_pkgs[$prod]}"
    done
    echo ""
    echo "Services (--service / -s):"
    for pkg in $(printf '%s\n' "${!PKG_PRODUCT[@]}" | sort); do
        _pkg_present_on_host "$pkg" || continue
        echo "  - $pkg  [${PKG_PRODUCT[$pkg]}]"
    done
}

# Сообщить о неизвестных директориях внутри /var/log/flat (мусор вроде logforflat) — один раз за запуск
_report_skipped_unknown_flat_dirs() {
    local d base
    [[ "${SKIP_UNKNOWN_FLAT_REPORTED:-0}" -eq 1 ]] && return 0
    SKIP_UNKNOWN_FLAT_REPORTED=1
    [[ -d "/var/log/flat" ]] || return 0
    for d in /var/log/flat/*/; do
        [[ -d "$d" ]] || continue
        base=$(basename "$d")
        # mgcpclient — опциональное дополнение SoftSwitch, а не «неизвестный мусор»
        [[ "$base" == "mgcpclient" ]] && continue
        if ! _is_known_log_basename "$base"; then
            # На stderr: discover_log_dirs_for_selected() читается через
            # command substitution (mapfile), stdout здесь — только пути
            info "skip unknown: $base" >&2
        fi
    done
}

find_log_dirs_for_pkg() {
    local pkg="$1"
    local found_dirs=() alias target cfg_path sub
    local -A seen=()

    while IFS= read -r alias; do
        if [[ -d "/var/log/flat/${alias}" ]]; then
            target=$(readlink -f "/var/log/flat/${alias}" 2>/dev/null || echo "/var/log/flat/${alias}")
            [[ -z "${seen[$target]:-}" ]] && { seen["$target"]=1; found_dirs+=("$target"); }
        fi
        if [[ -L "/var/log/flat/${alias}" ]]; then
            target=$(readlink -f "/var/log/flat/${alias}" 2>/dev/null)
            if [[ -n "$target" && -d "$target" && -z "${seen[$target]:-}" ]]; then
                seen["$target"]=1
                found_dirs+=("$target")
            fi
        fi
        for sub in log logs; do
            if [[ -d "/opt/flat/${alias}/${sub}" ]]; then
                target=$(readlink -f "/opt/flat/${alias}/${sub}" 2>/dev/null || echo "/opt/flat/${alias}/${sub}")
                [[ -z "${seen[$target]:-}" ]] && { seen["$target"]=1; found_dirs+=("$target"); }
            fi
        done
    done < <(_pkg_names_for_lookup "$pkg")

    cfg_path=$(get_log_path_from_config "$pkg")
    if [[ -n "$cfg_path" ]]; then
        cfg_path=$(_log_path_to_dir "$cfg_path")
        if [[ -n "$cfg_path" && -d "$cfg_path" ]]; then
            target=$(readlink -f "$cfg_path" 2>/dev/null || echo "$cfg_path")
            [[ -z "${seen[$target]:-}" ]] && found_dirs+=("$target")
        fi
    fi
    printf '%s\n' "${found_dirs[@]}"
}

# Построить DISCOVERED_LOG_DIRS из SELECTED_PKGS (только белый список) + EXTRA_LOG_DIRS
discover_log_dirs_for_selected() {
    DISCOVERED_LOG_DIRS=()
    LOG_DIR_OWNER=()
    local pkg d abs
    local result=()

    _report_skipped_unknown_flat_dirs

    for pkg in "${SELECTED_PKGS[@]+"${SELECTED_PKGS[@]}"}"; do
        while IFS= read -r d; do
            [[ -n "$d" ]] || continue
            abs=$(readlink -f "$d" 2>/dev/null || echo "$d")
            if _log_dir_add_unique "$d"; then
                LOG_DIR_OWNER["$abs"]="$pkg"
                log_debug "found dir for package '$pkg': $abs"
            elif [[ -z "${LOG_DIR_OWNER[$abs]:-}" ]]; then
                LOG_DIR_OWNER["$abs"]="$pkg"
            fi
        done < <(find_log_dirs_for_pkg "$pkg")
    done

    for d in "${EXTRA_LOG_DIRS[@]+"${EXTRA_LOG_DIRS[@]}"}"; do
        if [[ -n "$d" && -d "$d" ]]; then
            _log_dir_add_unique "$d"
            log_debug "found extra dir: $d"
        fi
    done

    for d in "${DISCOVERED_LOG_DIRS[@]+"${DISCOVERED_LOG_DIRS[@]}"}"; do
        # Включаем директории, где есть похожие на логи файлы (включая .gz). Online пропускает .gz при tail.
        if _dir_has_any_log_files "$d"; then
            result+=("$d")
        else
            log_debug "discarded (no log-like files inside): $d"
        fi
    done
    DISCOVERED_LOG_DIRS=("${result[@]+"${result[@]}"}")
    printf '%s\n' "${DISCOVERED_LOG_DIRS[@]+"${DISCOVERED_LOG_DIRS[@]}"}"
}

# Истина, если базовое имя похоже на дамп SoftSwitch mgcpclient (mgcpclient_2.txt, …)
_is_mgcpclient_log_file() {
    local base
    base=$(basename "$1")
    [[ "$base" == mgcpclient || "$base" == mgcpclient.* || "$base" == mgcpclient_* ]]
}

# Стем «типа лога» для выбора инженером: ротации/архивы схлопываются
# (sipdump.txt.2.gz → sipdump, mgcpclient_3.txt → mgcpclient).
_log_type_stem() {
    local key
    key=$(_psl_log_group_key "$1")
    key=$(printf '%s' "$key" | sed -E 's/\.(log|txt|csv)$//')
    case "$key" in
        mgcpclient|mgcpclient.*|mgcpclient_*) key="mgcpclient" ;;
    esac
    printf '%s' "$key"
}

# Истина, если файл проходит фильтр выбранных типов для каталога (или фильтр выключен).
# Каталоги без владельца (EXTRA_LOG_DIRS / mgcpclient) не режем по типам.
_log_file_matches_type_filter() {
    local file="$1" src_dir="$2"
    local owner sel stem s
    [[ "${LOG_TYPE_FILTER:-0}" -eq 1 ]] || return 0
    owner="${LOG_DIR_OWNER[$src_dir]:-}"
    [[ -n "$owner" ]] || return 0
    sel="${SELECTED_LOG_TYPES[$owner]:-*}"
    [[ "$sel" == "*" ]] && return 0
    stem=$(_log_type_stem "$file")
    for s in $sel; do
        [[ "$s" == "$stem" ]] && return 0
    done
    return 1
}

# Уникальные стемы типов логов для пакета (включая mgcpclient* при листинге).
_discover_log_type_stems_for_pkg() {
    local pkg="$1" d f stem
    local -A seen=()
    local saved_inc="${INCLUDE_MGCPCLIENT}"
    local saved_filter="${LOG_TYPE_FILTER}"
    INCLUDE_MGCPCLIENT=1
    LOG_TYPE_FILTER=0
    while IFS= read -r d; do
        [[ -n "$d" && -d "$d" ]] || continue
        while IFS= read -r -d '' f; do
            stem=$(_log_type_stem "$f")
            [[ -n "$stem" ]] || continue
            seen["$stem"]=1
        done < <(find_log_files_in_dir "$d")
    done < <(find_log_dirs_for_pkg "$pkg")
    INCLUDE_MGCPCLIENT="$saved_inc"
    LOG_TYPE_FILTER="$saved_filter"
    if [[ ${#seen[@]} -gt 0 ]]; then
        printf '%s\n' "${!seen[@]}" | LC_ALL=C sort -u
    fi
}

# По типам логов fss-server решить INCLUDE_MGCPCLIENT без интерактивного вопроса.
_apply_mgcpclient_from_log_types() {
    local sel stem
    INCLUDE_MGCPCLIENT=0
    if _selection_includes_fss_server; then
        sel="${SELECTED_LOG_TYPES[fss-server]:-*}"
        if [[ "$sel" == "*" ]]; then
            INCLUDE_MGCPCLIENT=1
        else
            for stem in $sel; do
                if [[ "$stem" == "mgcpclient" ]]; then
                    INCLUDE_MGCPCLIENT=1
                    break
                fi
            done
        fi
    fi
    _resolve_mgcpclient_option 1
}

# Кандидаты логов в каталоге (NUL): широкий набор схем logrotate (Debian/РЕД ОС/…).
# Маска на диске ≈ name.(log|txt|csv)[.-_]* плюс архив .gz/.bz2/.xz.
# Полная матрица имён → stem/group: _logrotate_name_matrix() + selftest.
# Без *.txt-*/*.log-* РЕД ОС sipdump.txt-20260802.gz find не видел (оставался live).
_find_app_log_paths() {
    local src_dir="$1"
    [[ -d "$src_dir" ]] || return 0
    find -L "$src_dir" -maxdepth 2 -type f \( \
        -name '*.log' -o -name '*.txt' -o -name '*.csv' \
        -o -name '*.log.*' -o -name '*.txt.*' -o -name '*.csv.*' \
        -o -name '*.log.gz' -o -name '*.txt.gz' -o -name '*.csv.gz' \
        -o -name '*.log.bz2' -o -name '*.txt.bz2' -o -name '*.csv.bz2' \
        -o -name '*.log.xz' -o -name '*.txt.xz' -o -name '*.csv.xz' \
        -o -name '*.log-*' -o -name '*.txt-*' -o -name '*.csv-*' \
        -o -name '*.log_*' -o -name '*.txt_*' -o -name '*.csv_*' \
    \) -print0 2>/dev/null
}

# Матрица ротаций: filename<TAB>expected_stem<TAB>expected_group
# Держать широкой — чтобы смена logrotate на любой ОС/службе ловилась selftest'ом.
_logrotate_name_matrix() {
    cat <<'EOF'
sipdump.txt	sipdump	sipdump.txt
sipdump.txt.1	sipdump	sipdump.txt
sipdump.txt.2.gz	sipdump	sipdump.txt
sipdump.txt.1.bz2	sipdump	sipdump.txt
sipdump.txt.1.xz	sipdump	sipdump.txt
sipdump.txt.-20260731	sipdump	sipdump.txt
sipdump.txt.-20260731.gz	sipdump	sipdump.txt
sipdump.txt.-2026-07-31	sipdump	sipdump.txt
sipdump.txt.-2026-07-31.gz	sipdump	sipdump.txt
sipdump.txt-20260802	sipdump	sipdump.txt
sipdump.txt-20260802.gz	sipdump	sipdump.txt
sipdump.txt-20260623	sipdump	sipdump.txt
sipdump.txt_20260802	sipdump	sipdump.txt
sipdump.txt_20260802.gz	sipdump	sipdump.txt
sipdump.txt.20260802	sipdump	sipdump.txt
sipdump.txt.20260802.gz	sipdump	sipdump.txt
sipdump.txt.2026-08-02	sipdump	sipdump.txt
sipdump.txt.2026-08-02.gz	sipdump	sipdump.txt
sipdump.txt.2026_08_02.gz	sipdump	sipdump.txt
error.log	error	error.log
error.log.3	error	error.log
error.log.3.gz	error	error.log
error.log-20260802.gz	error	error.log
error.log_20260802	error	error.log
sipsigthr_log.txt-20260804.gz	sipsigthr_log	sipsigthr_log.txt
sippbx.txt.1.gz	sippbx	sippbx.txt
tarificationlog.txt.7.gz	tarificationlog	tarificationlog.txt
abonentsclass.txt.1.gz	abonentsclass	abonentsclass.txt
mgcpclient_10.txt	mgcpclient	mgcpclient_10.txt
mgcpclient_10.txt-20260803.gz	mgcpclient	mgcpclient_10.txt
mgcpclient_3.txt	mgcpclient	mgcpclient_3.txt
access.2026-07-22.log	access	access.log
access.log.1	access	access.log
access.log.2.gz	access	access.log
2026_07_24_swau_log.log	swau_log	swau_log.log
2026-07-25_swau_log.log	swau_log	swau_log.log
app.csv	app	app.csv
app.csv.1	app	app.csv
app.csv-20260801.gz	app	app.csv
app.csv_20260801	app	app.csv
EOF
}

# find_log_files_in_dir учитывает INCLUDE_MGCPCLIENT: если не 1, пропускает файлы mgcpclient*
# и LOG_TYPE_FILTER / SELECTED_LOG_TYPES (стемы на пакет).
# Online: также пропускаем *.gz (tail -F не может следить за содержимым gzip)
find_log_files_in_dir() {
    local src_dir="$1" f
    [[ -d "$src_dir" ]] || return 0
    src_dir=$(readlink -f "$src_dir" 2>/dev/null || echo "$src_dir")
    while IFS= read -r -d '' f; do
        if [[ "${INCLUDE_MGCPCLIENT:-0}" != "1" ]] && _is_mgcpclient_log_file "$f"; then
            continue
        fi
        if ! _log_file_matches_type_filter "$f" "$src_dir"; then
            continue
        fi
        if [[ "${LOG_SUBMODE:-}" == "online" && "$f" == *.gz ]]; then
            continue
        fi
        printf '%s\0' "$f"
    done < <(_find_app_log_paths "$src_dir")
}

# Истина, если в директории есть хоть один собираемый похожий-на-лог файл (включая .gz) — для поиска
_dir_has_any_log_files() {
    local d="$1" f
    [[ -d "$d" ]] || return 1
    d=$(readlink -f "$d" 2>/dev/null || echo "$d")
    while IFS= read -r -d '' f; do
        if [[ "${INCLUDE_MGCPCLIENT:-0}" != "1" ]] && _is_mgcpclient_log_file "$f"; then
            continue
        fi
        if ! _log_file_matches_type_filter "$f" "$d"; then
            continue
        fi
        return 0
    done < <(_find_app_log_paths "$d")
    return 1
}


# ==========================================================================
# РАЗДЕЛ: 03_postgres_discovery
# ==========================================================================
# Назначение: (1) Поиск логов PostgreSQL (путь, формат имени, ротация) отдельно
#   от каталога пакетов FLAT — своя эвристика путей/прав доступа. (2) Общий
#   seek/bisect-движок извлечения диапазона из большого файла по временной
#   метке (time_to_epoch, filter_log_file_by_range, бисекция смещений,
#   параллельный chunk-scan) — используется НЕ ТОЛЬКО для PostgreSQL, а
#   вообще всеми extract-модулями (04/05/06) и синтетическим self-test'ом
#   seek+chunk. Оба назначения физически лежат в одном файле только потому,
#   что так исторически сложилось в оригинале (см. "Источник" ниже) — при
#   дальнейшем рефакторинге это кандидат на разделение на два файла.
# Публичные функции: discover_postgresql_log_sources()/is_postgresql_present()/
#   collect_postgresql_logs() (postgres-специфика); time_to_epoch(),
#   filter_log_file_by_range(), filter_log_file_by_range_grep() и внутренние
#   _binsearch_*/_seek_*/_extract_chunk_worker (общий движок, используется извне)
# Зависит от: lib/core (detect_os), 00_tunables.sh, 01_time_filters.sh
# Не зависит от: log_discovery (FLAT-пакеты) — независимая ветка для системной БД
# Side effects: читает файловую систему (find/ls), не пишет; seek-движок
#   запускает параллельные фоновые job'ы (&) для chunk-scan
#
# Источник: перенесено без изменений логики из flat_check_2.sh (строки 3149-3897).
#   Единственное исключение — _collector_should_stop(): в оригинале была
#   определена прямо здесь; в модульной сборке перенесена в
#   lib/logging.sh (раздел 07_collector) (см. комментарий там и в
#   lib/core.sh (раздел 06_resource_gate)) — найдено при код-ревью фазы 5.

# --- 7. Поиск логов PostgreSQL ---------------------------------------------------

find_pg_log_files_in_dir() {
    local src_dir="$1" f
    [[ -d "$src_dir" ]] || return 0
    while IFS= read -r -d '' f; do
        if [[ "${LOG_SUBMODE:-}" == "online" && "$f" == *.gz ]]; then
            continue
        fi
        printf '%s\0' "$f"
    done < <(find -L "$src_dir" -maxdepth 2 -type f \( \
        -name '*.log' -o -name '*.csv' -o -name '*.txt' \
        -o -name '*.log.*' -o -name '*.log.gz' -o -name '*.csv.gz' \
        -o -name 'postgresql-*' \
    \) -print0 2>/dev/null)
}

has_pg_log_files() {
    local d="$1"
    [[ -d "$d" ]] || return 1
    [[ -n "$(find_pg_log_files_in_dir "$d" | head -c 1)" ]]
}

_pg_conf_get_value() {
    local key="$1" conf="$2" line val
    line=$(grep -E "^[[:space:]]*${key}[[:space:]]*=" "$conf" 2>/dev/null | grep -v '^[[:space:]]*#' | head -1)
    [[ -z "$line" ]] && return 1
    val=$(echo "$line" | sed -E "s/^[[:space:]]*${key}[[:space:]]*=[[:space:]]*'([^']*)'.*/\1/")
    if [[ "$val" == "$line" ]]; then
        val=$(echo "$line" | sed -E 's/^[^=]+=[[:space:]]*"?([^"#]*)"?.*$/\1/')
    fi
    val=$(echo "$val" | sed 's/[[:space:]]*$//')
    [[ -n "$val" ]] && echo "$val"
}

_pg_resolve_log_dir_from_conf() {
    local conf="$1"
    local data_dir log_dir
    [[ -f "$conf" ]] || return 1
    data_dir=$(_pg_conf_get_value "data_directory" "$conf")
    [[ -z "$data_dir" ]] && return 1
    log_dir=$(_pg_conf_get_value "log_directory" "$conf")
    [[ -z "$log_dir" ]] && log_dir="log"
    if [[ "$log_dir" != /* ]]; then
        echo "${data_dir%/}/${log_dir}"
    else
        echo "$log_dir"
    fi
}

_pg_log_source_add() {
    local path="$1" label="$2" conf="${3:-}"
    local entry existing_path normalized
    [[ -z "$path" ]] && return 1
    normalized=$(readlink -f "$path" 2>/dev/null || echo "$path")
    for entry in "${PG_LOG_SOURCES[@]}"; do
        existing_path="${entry%%|*}"
        [[ "$existing_path" == "$normalized" ]] && return 1
    done
    PG_LOG_SOURCES+=("${normalized}|${label}|${conf}")
}

_discover_pg_from_systemd_service() {
    local svc="$1"
    local exec_start data_dir conf log_dir sub
    [[ -z "$svc" ]] && return 1
    exec_start=$(systemctl show "$svc" -p ExecStart --value 2>/dev/null)
    [[ -z "$exec_start" ]] && return 1

    data_dir=$(echo "$exec_start" | sed -n 's/.*-D[[:space:]]\+\([^[:space:]]\+\).*/\1/p')
    conf=$(echo "$exec_start" | sed -n 's/.*config_file=\([^[:space:]]\+\).*/\1/p')

    if [[ -n "$conf" && -f "$conf" ]]; then
        log_dir=$(_pg_resolve_log_dir_from_conf "$conf")
        if [[ -n "$log_dir" ]]; then
            _pg_log_source_add "$log_dir" "$svc" "$conf"
            return 0
        fi
    fi

    if [[ -n "$data_dir" ]]; then
        for sub in log pg_log; do
            _pg_log_source_add "${data_dir%/}/${sub}" "$svc" "${conf:-}"
        done
    fi
}

discover_postgresql_log_sources() {
    local conf svc log_dir pg_dir
    PG_LOG_SOURCES=()

    for conf in /etc/postgresql/*/main/postgresql.conf /var/lib/pgsql/*/data/postgresql.conf; do
        [[ -f "$conf" ]] || continue
        log_dir=$(_pg_resolve_log_dir_from_conf "$conf")
        [[ -n "$log_dir" ]] && _pg_log_source_add "$log_dir" "${conf%/postgresql.conf}" "$conf"
    done

    if command -v systemctl &>/dev/null; then
        while read -r svc; do
            [[ -z "$svc" ]] && continue
            _discover_pg_from_systemd_service "$svc"
        done < <(systemctl list-unit-files --type=service --no-pager 2>/dev/null | awk '{print $1}' | grep -E '^postgresql' || true)
    fi

    for pg_dir in /var/lib/postgresql/*/main/pg_log /var/lib/postgresql/*/main/log; do
        [[ -d "$pg_dir" ]] && _pg_log_source_add "$pg_dir" "discovered:$(dirname "$pg_dir")" ""
    done
    [[ -d /var/log/postgresql ]] && _pg_log_source_add "/var/log/postgresql" "discovered:/var/log/postgresql" ""
}

is_postgresql_present() {
    command -v psql &>/dev/null && return 0
    command -v systemctl &>/dev/null && systemctl list-unit-files --type=service --no-pager 2>/dev/null | grep -qE '^postgresql'
}

check_postgresql_log_access() {
    local dir="$1"
    [[ -e "$dir" ]] || return 1
    [[ -d "$dir" ]] || return 2
    ls "$dir" &>/dev/null || return 3
    return 0
}

_logs_time_context() {
    local mode="${1:-offline}"
    local from_time="${2:-}"
    local to_time="${3:-}"
    if [[ "$mode" == "online" ]]; then
        echo "collection"
    elif [[ -n "$from_time" || -n "$to_time" ]]; then
        echo "period"
    else
        echo "plain"
    fi
}

_log_absent_reason() {
    local ctx="$1"
    case "$ctx" in
        period)     _l logs_absent_for_period ;;
        collection) _l logs_absent_for_collection ;;
        *)          _l logs_absent ;;
    esac
}

_join_comma_list() {
    local result="" item
    for item in "$@"; do
        [[ -n "$result" ]] && result+=", "
        result+="$item"
    done
    echo "$result"
}

_format_absent_files_hint() {
    local max_show=4
    local -A seen=()
    local -a unique=() f shown=0 extra summary=""
    for f in "$@"; do
        [[ -n "${seen[$f]+x}" ]] && continue
        seen[$f]=1
        unique+=("$f")
    done
    local total=${#unique[@]}
    [[ "$total" -eq 0 ]] && return 0
    if [[ "$total" -le 5 ]]; then
        _join_comma_list "${unique[@]}"
        return 0
    fi
    for f in "${unique[@]}"; do
        [[ $shown -ge $max_show ]] && break
        [[ -n "$summary" ]] && summary+=", "
        summary+="$f"
        ((shown++)) || true
    done
    extra=$(( total - shown ))
    echo "${total} $(_l absent_files_unit): ${summary} (+${extra} $(_l more_files))"
}

_log_absent_info() {
    local label="$1" ctx="$2"
    shift 2
    local hint
    hint=$(_format_absent_files_hint "$@")
    if [[ -n "$hint" ]]; then
        info "${label}: $(_log_absent_reason "$ctx") (${hint})"
    else
        info "${label}: $(_log_absent_reason "$ctx")"
    fi
}

# _collector_should_stop() НЕ определена здесь: настоящая версия (проверяет
# COLLECTOR_ABORTED/COLLECTOR_TIMEOUT_STOP) переехала в lib/logging.sh (раздел 07_collector)
# — единственное место, где эти два флага вообще выставляются (обработчики
# сигналов). Найдено при код-ревью фазы 5: раньше она была продублирована
# здесь с ДРУГИМ телом, чем стаб в lib/core.sh (раздел 06_resource_gate) (там —
# заглушка "никогда не останавливаться" для health-check без lib/logging), и
# из двух определений реально выигрывало то, что грузилось последним по
# порядку каталогов (logging после core) — работало по факту, но не по
# документированному замыслу. Теперь переопределение явное и с комментарием.

# Ждём, пока пользователь не остановит online-сбор (Enter) или не придёт TERM (timeout / диск-guard).
# Вызывающий код должен обеспечить, что non-TTY online имеет timeout_sec > 0 перед запуском tail'ов.
_online_wait_for_stop() {
    if [[ -t 0 ]]; then
        while [[ "${COLLECTOR_TIMEOUT_STOP:-0}" -eq 0 && "${COLLECTOR_ABORTED:-0}" -eq 0 ]]; do
            if read -r -t 1 _ 2>/dev/null; then
                break
            fi
        done
    else
        while [[ "${COLLECTOR_TIMEOUT_STOP:-0}" -eq 0 && "${COLLECTOR_ABORTED:-0}" -eq 0 ]]; do
            sleep 1
        done
    fi
}

collect_postgresql_logs() {
    local work_dir="$1" mode="$2"
    local from_time="${3:-}" to_time="${4:-}"
    local entry path label conf status dest safe_label

    discover_postgresql_log_sources

    if [[ ${#PG_LOG_SOURCES[@]} -eq 0 ]]; then
        is_postgresql_present && info "postgresql: $(_l pg_logs_not_found)"
        return 0
    fi

    for entry in "${PG_LOG_SOURCES[@]}"; do
        IFS='|' read -r path label conf <<< "$entry"
        status=0
        check_postgresql_log_access "$path" || status=$?

        case "$status" in
            1) info "postgresql ($label): $(_l pg_logs_dir_missing) $path"; continue ;;
            2) warn "postgresql ($label): $(_l pg_logs_not_dir) $path"; continue ;;
            3)
                if [[ "${EUID:-$(id -u 2>/dev/null)}" -ne 0 ]]; then
                    warn "postgresql ($label): $(_l pg_logs_no_access) $path — $(_l pg_logs_try_sudo)"
                else
                    warn "postgresql ($label): $(_l pg_logs_no_access) $path"
                fi
                continue
                ;;
        esac

        if ! has_pg_log_files "$path"; then
            local ctx pg_label
            ctx=$(_logs_time_context "$mode" "$from_time" "$to_time")
            pg_label="postgresql ($(basename "$path"))"
            info "${pg_label}: $(_log_absent_reason "$ctx")"
            continue
        fi

        safe_label=$(echo "$label" | sed 's|^/||; s|/|_|g; s|@|_|g')
        [[ -z "$safe_label" ]] && safe_label=$(basename "$path")
        dest="$work_dir/postgresql/${safe_label}"
        local pg_display="postgresql ($(basename "$path"))"

        if [[ "$mode" == "online" ]]; then
            start_tail_for_dir "$path" "$dest" "pg" "$pg_display"
        else
            copy_existing_logs "$path" "$dest" "$from_time" "$to_time" "pg" "$pg_display"
        fi
    done
}

time_to_epoch() {
    date -d "$1" "+%s" 2>/dev/null
}

# Общее тело awk: парсинг timestamp → epoch (YYYY-MM-DD / DD.MM.YYYY, плюс
# запасной вариант для строк вообще без даты — только HH:MM:SS, см. ниже).
# Ожидает опциональную awk-переменную ref_midnight (epoch полуночи дня,
# к которому относится файл — задаётся через -v вызывающим кодом на основе
# _LOG_REF_MIDNIGHT_EPOCH, см. _infer_file_midnight_epoch()).
# Важно: метка только с НАЧАЛА строки. Иначе в sipdump тело SIP (Date/SDP/…)
# даёт ложный epoch → early-stop обрезает файл до реальных строк диапазона.
_AWK_LINE_EPOCH='
function line_epoch(line, ts, n, p) {
    if (match(line, /^[0-9]{4}-[0-9]{2}-[0-9]{2}[ T][0-9]{2}:[0-9]{2}:[0-9]{2}/)) {
        ts = substr(line, RSTART, RLENGTH)
        gsub(/[-T:]/, " ", ts)
        n = split(ts, p, " ")
        if (n >= 6) return mktime(p[1] " " p[2] " " p[3] " " p[4] " " p[5] " " p[6])
    }
    if (match(line, /^[0-9]{2}\.[0-9]{2}\.[0-9]{4}[ T][0-9]{2}:[0-9]{2}:[0-9]{2}/)) {
        ts = substr(line, RSTART, RLENGTH)
        gsub(/[T]/, " ", ts)
        n = split(ts, p, /[. :]/)
        if (n >= 6) return mktime(p[3] " " p[2] " " p[1] " " p[4] " " p[5] " " p[6])
    }
    if (match(line, /^[0-9]{2}\.[0-9]{2}\.[0-9]{4}[ T][0-9]{2}:[0-9]{2}/)) {
        ts = substr(line, RSTART, RLENGTH)
        gsub(/[T]/, " ", ts)
        n = split(ts, p, /[. :]/)
        if (n >= 5) return mktime(p[3] " " p[2] " " p[1] " " p[4] " " p[5] " 0")
    }
    if (match(line, /^[0-9]{4}-[0-9]{2}-[0-9]{2}[ T][0-9]{2}:[0-9]{2}/)) {
        ts = substr(line, RSTART, RLENGTH)
        gsub(/[-T:]/, " ", ts)
        n = split(ts, p, " ")
        if (n >= 5) return mktime(p[1] " " p[2] " " p[3] " " p[4] " " p[5] " 0")
    }
    # Некоторые логгеры FLAT (например fcs-swau) пишут в каждой строке только
    # время (HH:MM:SS[:мс]) без даты — дата целиком в имени файла
    # (YYYY_MM_DD_*.log). ref_midnight (epoch 00:00:00 дня файла) передаётся
    # вызывающим кодом через -v; без него строки такого формата неотличимы
    # от "нет метки времени вообще", как и раньше.
    if (ref_midnight > 0 && match(line, /^[0-9]{2}:[0-9]{2}:[0-9]{2}/)) {
        ts = substr(line, RSTART, RLENGTH)
        n = split(ts, p, ":")
        if (n >= 3) return ref_midnight + p[1] * 3600 + p[2] * 60 + p[3]
    }
    return -1
}
'

_file_size_bytes() {
    local s
    s=$(stat -c '%s' "$1" 2>/dev/null) && { echo "$s"; return 0; }
    s=$(wc -c < "$1" 2>/dev/null | tr -d '[:space:]')
    echo "${s:-0}"
}

# Печатает epoch полуночи (00:00:00) календарного дня, к которому относится
# файл — для логов, где каждая строка содержит только время (HH:MM:SS), без
# даты, а дата зашита только в имени файла (обычная схема для ежедневно
# ротируемых логов вида YYYY_MM_DD_*.log, например fcs-swau/*.log). Сначала
# пробует распознать дату в имени файла (YYYY_MM_DD, YYYY-MM-DD,
# DD.MM.YYYY, DD_MM_YYYY); если в имени файла даты нет — использует дату
# mtime файла как разумное приближение. Пусто, если и это не удалось.
_infer_file_midnight_epoch() {
    local file="$1" base date_str="" epoch mtime
    base=$(basename -- "$file")

    if [[ "$base" =~ ([0-9]{4})[_-]([0-9]{2})[_-]([0-9]{2}) ]]; then
        date_str="${BASH_REMATCH[1]}-${BASH_REMATCH[2]}-${BASH_REMATCH[3]}"
    elif [[ "$base" =~ ([0-9]{2})[._]([0-9]{2})[._]([0-9]{4}) ]]; then
        date_str="${BASH_REMATCH[3]}-${BASH_REMATCH[2]}-${BASH_REMATCH[1]}"
    fi

    if [[ -n "$date_str" ]]; then
        epoch=$(date -d "$date_str 00:00:00" "+%s" 2>/dev/null)
        [[ "$epoch" =~ ^[0-9]+$ ]] && { echo "$epoch"; return 0; }
    fi

    mtime=$(stat -c '%Y' "$file" 2>/dev/null) || return 1
    date_str=$(date -d "@$mtime" '+%Y-%m-%d' 2>/dev/null)
    [[ -n "$date_str" ]] || return 1
    epoch=$(date -d "$date_str 00:00:00" "+%s" 2>/dev/null)
    [[ "$epoch" =~ ^[0-9]+$ ]] && echo "$epoch"
}

# Epoch одной строки лога (-1, если нет)
_epoch_of_line() {
    local line="$1" ep
    [[ -z "$line" ]] && { echo -1; return; }
    # Логи SoftSwitch могут содержать NUL / не-UTF8; убираем перед bash/awk
    line="${line//$'\0'/}"
    # Избегаем SIGPIPE+pipefail, когда awk завершается после одной строки
    ep=$(set +o pipefail
        printf '%s\n' "$line" | LC_ALL=C awk -v ref_midnight="${_LOG_REF_MIDNIGHT_EPOCH:-0}" \
            "$_AWK_LINE_EPOCH"' { print line_epoch($0); exit }')
    echo "${ep:--1}"
}

# Прочитать одну полную строку в/после байтового смещения (не сканирует остаток файла)
_probe_line_at_offset() {
    local file="$1" off="$2" line
    local probe="${SEEK_PROBE_BYTES:-131072}"
    if [[ "$off" -le 0 ]]; then
        # tr убирает NUL, чтобы command substitution не выдавал предупреждение
        head -n 1 "$file" 2>/dev/null | tr -d '\0'
        return 0
    fi
    # Поток dd→tr→awk: никогда не храним сырую пробу (с NUL) в bash-переменной
    # LC_ALL=C: избегаем "Invalid multibyte data" на почти-бинарных срезах лога
    line=$(set +o pipefail
        dd if="$file" bs=65536 iflag=skip_bytes,count_bytes skip="$off" count="$probe" 2>/dev/null \
            | tr -d '\0' \
            | LC_ALL=C awk '
                NR == 1 { partial = $0; next }
                { print; exit }
                END { if (NR <= 1 && length(partial)) print partial }
            ')
    [[ -n "$line" ]] || return 1
    printf '%s\n' "$line"
    return 0
}

# Три пробы epoch (начало / середина / почти-конец). Печатает "e1 e2 e3" или "".
_logs_probe_epochs() {
    local file="$1" size="$2"
    local e1 e2 e3 near_end line1 line2 line3
    line1=$(_probe_line_at_offset "$file" 0)
    e1=$(_epoch_of_line "$line1")
    line2=$(_probe_line_at_offset "$file" $((size / 2)))
    e2=$(_epoch_of_line "$line2")
    if [[ "$size" -gt "${SEEK_PROBE_BYTES:-131072}" ]]; then
        near_end=$((size - SEEK_PROBE_BYTES))
        line3=$(_probe_line_at_offset "$file" "$near_end")
    else
        # Маленький файл: "почти-конец" ≠ offset 0 — берём последнюю строку.
        line3=$(tail -n 1 -- "$file" 2>/dev/null | tr -d '\0')
    fi
    e3=$(_epoch_of_line "$line3")
    [[ "$e1" =~ ^[0-9]+$ && "$e2" =~ ^[0-9]+$ && "$e3" =~ ^[0-9]+$ ]] || return 1
    [[ "$e1" -gt 0 && "$e2" -gt 0 && "$e3" -gt 0 ]] || return 1
    echo "$e1 $e2 $e3"
}

# Режим хронологии plain-файла: sorted | soft | unsorted.
# soft = first≤last, но середина «плавает» (типичный sipdump/clustermonitor
# SoftSwitch с несколькими писателями) — seek с широким backoff, без early-stop.
_logs_sort_mode() {
    local file="$1" size="$2"
    local e1 e2 e3
    read -r e1 e2 e3 < <(_logs_probe_epochs "$file" "$size") || { echo unsorted; return; }
    if [[ "$e1" -le "$e2" && "$e2" -le "$e3" ]]; then
        echo sorted
    elif [[ "$e1" -le "$e3" ]]; then
        echo soft
    else
        echo unsorted
    fi
}

# Истина только для строгого sorted (совместимость со старыми вызовами).
_logs_appear_sorted() {
    [[ "$(_logs_sort_mode "$1" "$2")" == "sorted" ]]
}

# Бинарный поиск: приблизительное байтовое смещение первой строки с epoch >= target
# Для файла в 30GB это ~35 проб × ~128KB ≈ несколько МБ I/O (в стиле timegrep/archeolog).
_binsearch_offset_ge() {
    local file="$1" target="$2" size="$3"
    local lo=0 hi="$size" mid line ep
    # Останавливаемся, когда окно мало; должно быть много меньше типичных логов среднего размера (selftest ~1–2MB)
    local window="${SEEK_PROBE_BYTES:-131072}"

    while [[ $((hi - lo)) -gt "$window" ]]; do
        mid=$(( (lo + hi) / 2 ))
        line=$(_probe_line_at_offset "$file" "$mid") || { lo=$((mid + 1)); continue; }
        ep=$(_epoch_of_line "$line")
        if [[ ! "$ep" =~ ^[0-9]+$ ]] || [[ "$ep" -lt 0 ]]; then
            lo=$((mid + 4096))
            [[ "$lo" -ge "$hi" ]] && break
            continue
        fi
        if [[ "$ep" -lt "$target" ]]; then
            lo=$mid
        else
            hi=$mid
        fi
    done
    echo "$lo"
}

# Потоковый фильтр: строки в [from,to].
# sorted=1 → early-stop когда ep > to+grace (grace смягчает мелкий reorder).
_awk_filter_range_prog() {
    local sorted="${1:-0}"
    local grace="${2:-0}"
    [[ "$grace" =~ ^[0-9]+$ ]] || grace=0
    printf '%s\n' "$_AWK_LINE_EPOCH"
    cat <<EOF
BEGIN { in_range = 0; sorted = $sorted; grace = $grace }
{
    ep = line_epoch(\$0)
    if (ep >= 0) {
        if (sorted && ep > to + grace) exit
        if (ep >= from && ep <= to) { print; in_range = 1 }
        else { in_range = 0 }
    } else if (in_range) {
        print
    }
}
EOF
}

# Выровнять байтовое смещение на начало строки (после предыдущего \n). Не даёт разрывать строки между чанками.
_align_to_line_start() {
    local file="$1" off="$2" size="${3:-0}"
    local prev nskip
    [[ "$off" -le 0 ]] && { echo 0; return; }
    [[ "$size" -gt 0 && "$off" -ge "$size" ]] && { echo "$size"; return; }
    prev=$(dd if="$file" bs=1 iflag=skip_bytes,count_bytes skip=$((off - 1)) count=1 2>/dev/null) || true
    if [[ "$prev" == $'\n' ]]; then
        echo "$off"
        return
    fi
    nskip=$(set +o pipefail
        dd if="$file" bs=64K iflag=skip_bytes,count_bytes skip="$off" count=65536 2>/dev/null \
            | tr -d '\0' \
            | LC_ALL=C awk 'BEGIN{RS="\n"; ORS=""} NR==1 { print length($0)+1; exit }')
    [[ "$nskip" =~ ^[0-9]+$ ]] || nskip=0
    echo $((off + nskip))
}

# Извлечь одно выровненное по \n байтовое окно → part-файл
_extract_chunk_worker() {
    local file="$1" off="$2" len="$3" from_epoch="$4" to_epoch="$5" sorted="$6" part="$7"
    [[ "$len" -le 0 ]] && { : > "$part"; return 0; }
    dd if="$file" bs=4M iflag=skip_bytes,count_bytes skip="$off" count="$len" 2>/dev/null \
        | tr -d '\0' \
        | LC_ALL=C awk -v from="$from_epoch" -v to="$to_epoch" -v ref_midnight="${_LOG_REF_MIDNIGHT_EPOCH:-0}" \
            "$(_awk_filter_range_prog "$sorted")" \
        > "$part" 2>/dev/null || true
}

# Выделенный пул задач seek — НЕЛЬЗЯ переиспользовать COLLECTOR_JOB_PIDS (вложенность под copy-воркерами → зависание).
_SEEK_JOB_PIDS=()

_seek_kill_jobs() {
    local pid
    for pid in "${_SEEK_JOB_PIDS[@]+"${_SEEK_JOB_PIDS[@]}"}"; do
        kill -TERM "$pid" 2>/dev/null || true
    done
    sleep 0.2
    for pid in "${_SEEK_JOB_PIDS[@]+"${_SEEK_JOB_PIDS[@]}"}"; do
        kill -KILL "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
    done
    _SEEK_JOB_PIDS=()
}

_seek_wait_slot() {
    local max_jobs="$1" pid alive
    local waited=0
    local max_wait="${RESOURCE_WAIT_MAX:-120}"
    local gate_warned=0
    _get_cpu_usage_percent >/dev/null
    while true; do
        alive=()
        for pid in "${_SEEK_JOB_PIDS[@]+"${_SEEK_JOB_PIDS[@]}"}"; do
            if kill -0 "$pid" 2>/dev/null; then
                alive+=("$pid")
            else
                wait "$pid" 2>/dev/null || true
            fi
        done
        _SEEK_JOB_PIDS=("${alive[@]+"${alive[@]}"}")

        if [[ ${#_SEEK_JOB_PIDS[@]} -lt "$max_jobs" ]]; then
            if _collector_resources_ok; then
                return 0
            fi
            if [[ ${#_SEEK_JOB_PIDS[@]} -eq 0 ]]; then
                return 0
            fi
            if [[ "$waited" -ge "$max_wait" ]]; then
                return 0
            fi
        fi

        _collector_should_stop && return 1

        if [[ ${#_SEEK_JOB_PIDS[@]} -gt 0 ]]; then
            if ! wait -n 2>/dev/null; then
                sleep 0.3
                waited=$((waited + 1))
            fi
        else
            sleep 0.3
            waited=$((waited + 1))
        fi
    done
}

_seek_wait_all_jobs() {
    local pid
    for pid in "${_SEEK_JOB_PIDS[@]+"${_SEEK_JOB_PIDS[@]}"}"; do
        wait "$pid" 2>/dev/null || true
    done
    _SEEK_JOB_PIDS=()
}

# Параллельное сканирование по чанкам [start_off, end_off). Безопасно от зависания (≥1 воркер); чанки выровнены по строкам.
_filter_byte_range_parallel() {
    local file="$1" dest="$2" from_epoch="$3" to_epoch="$4"
    local start_off="$5" end_off="$6" sorted="${7:-1}"
    local range chunk_sz max_jobs n i off next len part_dir rf size
    local -a parts=() bounds=()

    [[ "$end_off" -gt "$start_off" ]] || return 1
    range=$((end_off - start_off))
    size=$(_file_size_bytes "$file")
    max_jobs=$(_collector_inner_max_jobs)
    [[ "$max_jobs" -lt 1 ]] && max_jobs=1
    chunk_sz="${SEEK_CHUNK_BYTES:-67108864}"

    # Окна среднего размера: чанков достаточно, чтобы задействовать несколько воркеров
    if [[ "$range" -lt $((chunk_sz * max_jobs)) ]]; then
        chunk_sz=$(( range / max_jobs + 1 ))
        [[ "$chunk_sz" -lt $((1024 * 1024)) ]] && chunk_sz=$((1024 * 1024))
    fi
    # Окна ≥1GB: оставляем крупные чанки (монолиты SoftSwitch)
    if [[ "$range" -ge "${SEEK_HUGE_BYTES:-1073741824}" ]]; then
        chunk_sz="${SEEK_CHUNK_BYTES:-67108864}"
        [[ "$chunk_sz" -lt $((32 * 1024 * 1024)) ]] && chunk_sz=$((32 * 1024 * 1024))
    fi

    n=$(( (range + chunk_sz - 1) / chunk_sz ))
    [[ "$n" -lt 1 ]] && n=1
    [[ "$n" -gt 256 ]] && { chunk_sz=$(( (range + 255) / 256 )); n=$(( (range + chunk_sz - 1) / chunk_sz )); }

    # Выравниваем границы чанков по строкам, чтобы ни одна строка лога не была разорвана/потеряна
    bounds=("$start_off")
    for (( i=1; i<n; i++ )); do
        off=$(_align_to_line_start "$file" $((start_off + i * chunk_sz)) "$size")
        [[ "$off" -lt "$end_off" ]] || break
        [[ "$off" -gt "${bounds[$((${#bounds[@]} - 1))]}" ]] || continue
        bounds+=("$off")
    done
    bounds+=("$end_off")
    n=$(( ${#bounds[@]} - 1 ))

    part_dir=$(mktemp -d "${TMPDIR:-/tmp}/flat_seek.XXXXXX") || return 1
    _SEEK_JOB_PIDS=()

    for (( i=0; i<n; i++ )); do
        _collector_should_stop && { _seek_kill_jobs; rm -rf -- "$part_dir"; return 1; }
        if ! _seek_wait_slot "$max_jobs"; then
            _seek_kill_jobs
            rm -rf -- "$part_dir"
            return 1
        fi
        off="${bounds[$i]}"
        next="${bounds[$((i + 1))]}"
        len=$((next - off))
        [[ "$len" -le 0 ]] && continue
        rf="$part_dir/$(printf '%05d' "$i")"
        parts+=("$rf")
        (
            renice -n 10 $$ >/dev/null 2>&1 || true
            ionice -c 2 -n 7 -p $$ >/dev/null 2>&1 || true
            _extract_chunk_worker "$file" "$off" "$len" "$from_epoch" "$to_epoch" "$sorted" "$rf"
        ) &
        _SEEK_JOB_PIDS+=($!)
    done
    _seek_wait_all_jobs

    : > "$dest" 2>/dev/null || { rm -rf -- "$part_dir"; return 1; }
    for rf in "${parts[@]}"; do
        [[ -f "$rf" && -s "$rf" ]] && cat "$rf" >> "$dest"
    done
    rm -rf -- "$part_dir" 2>/dev/null
    [[ -s "$dest" ]]
}

# Фильтровать строки лога по timestamp внутри содержимого файла (YYYY-MM-DD / DD.MM.YYYY)
# Стратегия (рабочая скорость на монолитах масштаба SoftSwitch):
#   1) Если обычный файл + похож на отсортированный + size>=SEEK_MIN: бисекция смещений from/to, затем параллельное сканирование по чанкам
#   2) Иначе если обычный файл + size>=SEEK_MIN: параллельное сканирование по чанкам всего файла (безопасно для неотсортированных)
#   3) Иначе: однопоточный awk (маленькие файлы / .gz через zcat)
filter_log_file_by_range() {
    local src_file="$1" dest_file="$2"
    local from_epoch="$3" to_epoch="$4"
    local reader="cat" size=0 sorted=0 start_off=0 end_off=0
    local min_sz="${SEEK_MIN_BYTES:-1048576}"
    local sort_mode backoff

    [[ "$src_file" == *.gz ]] && reader="zcat"
    _collector_should_stop && return 1
    mkdir -p "$(dirname "$dest_file")" 2>/dev/null
    _LOG_REF_MIDNIGHT_EPOCH=$(_infer_file_midnight_epoch "$src_file")

    if [[ "$reader" == "cat" && -f "$src_file" ]]; then
        size=$(_file_size_bytes "$src_file")
        if [[ "$size" -ge "$min_sz" ]]; then
            sort_mode=$(_logs_sort_mode "$src_file" "$size")
            if [[ "$sort_mode" == "sorted" || "$sort_mode" == "soft" ]]; then
                [[ "$sort_mode" == "sorted" ]] && sorted=1 || sorted=0
                [[ "$sort_mode" == "sorted" ]] \
                    && backoff="${SEEK_BACKOFF_BYTES:-1048576}" \
                    || backoff="${SEEK_SOFT_SORT_BACKOFF_BYTES:-33554432}"
                start_off=$(_binsearch_offset_ge "$src_file" "$from_epoch" "$size")
                end_off=$(_binsearch_offset_ge "$src_file" "$((to_epoch + 1))" "$size")
                if [[ "$start_off" -gt "$backoff" ]]; then
                    start_off=$((start_off - backoff))
                else
                    start_off=0
                fi
                end_off=$((end_off + backoff))
                [[ "$end_off" -gt "$size" ]] && end_off=$size
                [[ "$end_off" -le "$start_off" ]] && end_off=$size
                _filter_byte_range_parallel "$src_file" "$dest_file" "$from_epoch" "$to_epoch" \
                    "$start_off" "$end_off" "$sorted"
                return $?
            fi
            # Неотсортированный, но большой: параллельное сканирование всего файла
            _filter_byte_range_parallel "$src_file" "$dest_file" "$from_epoch" "$to_epoch" \
                0 "$size" 0
            return $?
        fi
    fi

    # Маленькие файлы / gzip: единый поток
    $reader "$src_file" 2>/dev/null \
        | tr -d '\0' \
        | LC_ALL=C awk -v from="$from_epoch" -v to="$to_epoch" -v ref_midnight="${_LOG_REF_MIDNIGHT_EPOCH:-0}" \
            "$(_awk_filter_range_prog 0)" \
        > "$dest_file" 2>/dev/null \
        || { rm -f "$dest_file" 2>/dev/null; return 1; }

    [[ -s "$dest_file" ]]
}

# Запасной вариант на основе grep для логов в стиле syslog (почасовые паттерны).
# НИКОГДА не пересканировать многогигабайтные файлы почасово — это означало бы перечитывание сотен ГБ.
filter_log_file_by_range_grep() {
    local src_file="$1" dest_file="$2"
    local from_time="$3" to_time="$4"
    local from_epoch to_epoch size=0
    from_epoch=$(time_to_epoch "$from_time")
    to_epoch=$(time_to_epoch "$to_time")
    [[ -z "$from_epoch" || -z "$to_epoch" ]] && return 1
    _collector_should_stop && return 1

    if [[ "$src_file" != *.gz && -f "$src_file" ]]; then
        size=$(_file_size_bytes "$src_file")
        # Крупные файлы: только путь awk/bisect — почасовой цикл катастрофичен
        if [[ "$size" -ge "${SEEK_MIN_BYTES:-1048576}" ]]; then
            return 1
        fi
    fi

    local patterns=() d y m dd hh
    local cur_epoch="$from_epoch"
    local span_h=$(( (to_epoch - from_epoch) / 3600 + 1 ))
    [[ "$span_h" -gt 168 ]] && return 1

    while [[ "$cur_epoch" -le "$to_epoch" ]]; do
        y=$(date -d "@$cur_epoch" "+%Y" 2>/dev/null)
        m=$(date -d "@$cur_epoch" "+%m" 2>/dev/null)
        dd=$(date -d "@$cur_epoch" "+%d" 2>/dev/null)
        hh=$(date -d "@$cur_epoch" "+%H" 2>/dev/null)
        patterns+=("${y}-${m}-${dd} ${hh}:")
        patterns+=("${dd}.${m}.${y} ${hh}:")
        patterns+=("${y}/${m}/${dd} ${hh}:")
        cur_epoch=$(( cur_epoch + 3600 ))
    done

    local pat reader="cat" combined=""
    [[ "$src_file" == *.gz ]] && reader="zcat"
    mkdir -p "$(dirname "$dest_file")" 2>/dev/null
    : > "$dest_file" 2>/dev/null || return 1

    combined=$(printf '%s|' "${patterns[@]}")
    combined="${combined%|}"
    $reader "$src_file" 2>/dev/null | grep -a -E "$combined" > "$dest_file" 2>/dev/null || true
    [[ -s "$dest_file" ]]
}


# ==========================================================================
# РАЗДЕЛ: 04_extract_single
# ==========================================================================
# Назначение: Автономное извлечение диапазона строк из ОДНОГО файла лога службы (parce_service_log) — базовый строительный блок для offline-сбора.
# Публичные функции: parce_service_log()
# Зависит от: 01_time_filters.sh, 00_tunables.sh, lib/core (die/warn/log_debug)
# Не зависит от: 05_extract_multi.sh/06_extract_apply.sh — они вызывают эту функцию, а не наоборот
# Side effects: читает/пишет файлы во временный/выходной каталог сборки архива
#
# Источник: перенесено без изменений логики из flat_check_2.sh (строки 3898-4252).

# --- 8b. Автономное извлечение диапазона из лога службы (parce_service_log) ----
# Получив файл лога службы (или символьную ссылку на него) и диапазон времени
# [from, to], находит байтовые смещения, ограничивающие этот диапазон, через
# интерполяционный поиск — каждая проба нацеливается пропорционально тому,
# где "from"/"to" должны находиться между двумя уже известными epoch в текущих
# границах поиска (так же, как человек предположил бы «прошлое воскресенье
# примерно на 87% файла», прочитав дату только первой строки, а затем
# скорректировал бы прицел по величине промаха), а не всегда делит оставшееся
# окно пополам, как обычная бисекция. Предполагает, что лог хронологически
# отсортирован (append-only) — на этом же предположении опирается весь подход,
# включая существующую bisect-based filter_log_file_by_range() в другом месте этого файла.

# Разрешает путь к логу (следуя одному переходу по символьной ссылке) в
# реальный, читаемый, несжатый файл. Печатает разрешённый путь.
# ПРИМЕЧАНИЕ: stdout этой функции — её возвращаемое значение (вызывающий код
# всегда использует её как real_path=$(_psl_resolve_log_path ...)) — каждый
# вызов warn() ниже явно перенаправлен в stderr, иначе сам текст диагностики
# был бы захвачен в $(...) вместо показа пользователю (та же ошибка смешения
# print/возвращаемого значения, что и в других местах; поймана здесь по той же
# причине, что и на шаге выбора режима в мастере).

_psl_resolve_log_path() {
    local path="$1" real="$1"

    [[ -n "$path" ]] || { warn "parce_service_log: no log path given" >&2; return 1; }
    if [[ -L "$path" ]]; then
        real=$(readlink -f "$path" 2>/dev/null)
        [[ -n "$real" ]] || { warn "parce_service_log: broken symlink: $path" >&2; return 1; }
    fi
    [[ -f "$real" ]] || { warn "parce_service_log: not a regular file: $path" >&2; return 1; }
    [[ -r "$real" ]] || { warn "parce_service_log: not readable: $real" >&2; return 1; }
    case "$real" in
        *.gz|*.bz2|*.xz|*.zip)
            warn "parce_service_log: compressed logs are not byte-seekable: $real" >&2
            return 1
            ;;
    esac
    echo "$real"
}

# Принимает либо уже числовой epoch, либо всё, что понимает `date -d`.
# Та же оговорка про stdout-как-возвращаемое-значение, что и у _psl_resolve_log_path() выше.
# Пустая строка — ошибка: GNU `date -d ""` молча даёт 00:00:00 сегодняшнего дня,
# из‑за чего верхняя граница «за последние Nd» обрывала лог ровно на полуночи.
_psl_parse_timestamp() {
    local raw="$1" ep
    if [[ -z "${raw//[[:space:]]/}" ]]; then
        warn "parce_service_log: cannot parse timestamp '$raw'" >&2
        return 1
    fi
    if [[ "$raw" =~ ^[0-9]+$ ]]; then
        echo "$raw"
        return 0
    fi
    ep=$(time_to_epoch "$raw")
    [[ "$ep" =~ ^[0-9]+$ ]] || { warn "parce_service_log: cannot parse timestamp '$raw'" >&2; return 1; }
    echo "$ep"
}

# Интерполяционный поиск наименьшего байтового смещения, чья строка имеет
# epoch >= target ($size, если такой строки нет). Автоматически переходит на
# обычную бисекцию, когда две известные граничные epoch равны (нечего
# интерполировать). Те же примитивы пробы/парсинга, что и у обычной бисекции
# _binsearch_offset_ge() выше, отличается только выбор "mid".
#
#
# Чистый интерполяционный поиск подвержен известному патологическому
# случаю: логи редко пишутся с равномерной скоростью (всплески сменяются
# затишьями), и когда *глобальная* плотность на [lo,hi] сильно отличается от
# *локальной* плотности возле target, прямое пропорциональное предположение
# почти не сужает окно на каждом шаге — поиск может деградировать почти до
# линейного сканирования. _MIN_PROGRESS_FRAC ниже ограничивает каждое
# предположение так, чтобы оно сдвигалось хотя бы на эту долю текущего окна,
# что ограничивает число итераций логарифмом (та же форма, что у обычной
# бисекции, просто с большим основанием) независимо от того, насколько
# перекошены timestamp'ы, при этом всё ещё используя интерполированное
# предположение — и его обычно намного более быструю сходимость — там, где
# данные ведут себя достаточно хорошо, чтобы предположение само попало в этот диапазон.
_PSL_MIN_PROGRESS_FRAC=10   # гарантируем >=1/10 окна за одну итерацию

_psl_find_offset_for_epoch() {
    local file="$1" size="$2" target="$3"
    local window="${SEEK_PROBE_BYTES:-131072}"
    local lo=0 hi="$size" lo_ep hi_ep mid mid_ep line span min_gap

    line=$(_probe_line_at_offset "$file" "$lo") || line=""
    lo_ep=$(_epoch_of_line "$line")
    [[ "$lo_ep" =~ ^[0-9]+$ ]] || lo_ep=0
    if [[ "$lo_ep" -ge "$target" ]]; then
        echo 0
        return 0
    fi

    line=$(_probe_line_at_offset "$file" "$((size > window ? size - window : 0))") || line=""
    hi_ep=$(_epoch_of_line "$line")
    [[ "$hi_ep" =~ ^[0-9]+$ ]] || hi_ep="$lo_ep"
    if [[ "$hi_ep" -lt "$target" ]]; then
        echo "$size"
        return 0
    fi

    while [[ $((hi - lo)) -gt "$window" ]]; do
        if [[ "$hi_ep" -le "$lo_ep" ]]; then
            # Вырожденное окно (одинаковые epoch) — интерполировать нельзя.
            mid=$(( (lo + hi) / 2 ))
        else
            # Сделано в awk (double precision), а не в целых числах bash: на файле в
            # несколько сотен ГБ (target-lo_ep)*(hi-lo) может переполнить 64-битное целое
            # bash до того, как деление вернёт его в норму.
            mid=$(awk -v lo="$lo" -v hi="$hi" -v lo_ep="$lo_ep" -v hi_ep="$hi_ep" -v target="$target" \
                'BEGIN { frac = (target - lo_ep) / (hi_ep - lo_ep); m = lo + frac * (hi - lo); printf "%d", m }')
            [[ "$mid" =~ ^[0-9]+$ ]] || mid=$(( (lo + hi) / 2 ))

            # Ограничиваем в полосу гарантированного прогресса около середины —
            # именно это не даёт перекошенной плотности застопорить поиск.
            span=$((hi - lo))
            min_gap=$((span / _PSL_MIN_PROGRESS_FRAC))
            [[ "$min_gap" -lt 1 ]] && min_gap=1
            [[ $((mid - lo)) -lt "$min_gap" ]] && mid=$((lo + min_gap))
            [[ $((hi - mid)) -lt "$min_gap" ]] && mid=$((hi - min_gap))
        fi

        line=$(_probe_line_at_offset "$file" "$mid") || { lo=$((mid + 1)); continue; }
        mid_ep=$(_epoch_of_line "$line")
        if [[ ! "$mid_ep" =~ ^[0-9]+$ ]] || [[ "$mid_ep" -lt 0 ]]; then
            lo=$((mid + 4096))
            [[ "$lo" -ge "$hi" ]] && break
            continue
        fi

        if [[ "$mid_ep" -lt "$target" ]]; then
            lo="$mid"; lo_ep="$mid_ep"
        else
            hi="$mid"; hi_ep="$mid_ep"
        fi
    done
    echo "$lo"
}

# Разрешает [from_epoch, to_epoch] в выровненный по строкам байтовый диапазон
# [start_off, end_off). Печатает "start_off end_off"; возвращает 1, если ничего не подошло.
#
# _psl_find_offset_for_epoch() лишь сужает до одного проб-"окна"
# (SEEK_PROBE_BYTES) от истинной границы — так же, как и обычная бисекция
# _binsearch_offset_ge() — ни одна из них никогда не подтверждает точную
# строку. Поэтому, как и filter_log_file_by_range() делает вокруг своих
# вызовов _binsearch_offset_ge(), отступаем на SEEK_BACKOFF_BYTES с обеих
# сторон перед выравниванием: более широкое байтовое окно гарантированно
# полностью содержит истинную границу, а содержательный фильтр по epoch,
# применяемый на шаге копирования (не в этой функции), отбрасывает все
# лишние строки, которые этот запас захватывает с любой стороны.
# $5 = опциональный backoff в байтах (default SEEK_BACKOFF_BYTES; soft → SEEK_SOFT_SORT_*).
_psl_locate_range() {
    local file="$1" size="$2" from_epoch="$3" to_epoch="$4"
    local backoff="${5:-${SEEK_BACKOFF_BYTES:-1048576}}"
    local start_off end_off

    start_off=$(_psl_find_offset_for_epoch "$file" "$size" "$from_epoch")
    [[ "$start_off" -gt "$backoff" ]] && start_off=$((start_off - backoff)) || start_off=0
    start_off=$(_align_to_line_start "$file" "$start_off" "$size")

    end_off=$(_psl_find_offset_for_epoch "$file" "$size" "$((to_epoch + 1))")
    end_off=$((end_off + backoff))
    [[ "$end_off" -gt "$size" ]] && end_off="$size"
    end_off=$(_align_to_line_start "$file" "$end_off" "$size")

    if [[ "$end_off" -le "$start_off" ]]; then
        warn "parce_service_log: no lines fall inside the requested time range" >&2
        return 1
    fi
    echo "$start_off $end_off"
}

# Создаёт свежую, прозрачно названную директорию в /tmp для чанк-файлов
# этого извлечения: /tmp/parce_<basename>_<from>-<to>.<random>/
_psl_make_output_dir() {
    local file="$1" from_epoch="$2" to_epoch="$3"
    local base prefix

    base=$(basename -- "$file")
    base="${base//[^A-Za-z0-9._-]/_}"
    prefix="/tmp/parce_${base}_${from_epoch}-${to_epoch}"
    mktemp -d "${prefix}.XXXXXX" 2>/dev/null
}

# Разбивает [start_off, end_off) на выровненные по строкам куски размером
# MAX_LOG_CHUNK_SIZE. Печатает по одному смещению на строку: N+1 границ образуют N чанков.
_psl_plan_chunk_bounds() {
    local file="$1" start_off="$2" end_off="$3" size="$4"
    local chunk_sz="${MAX_LOG_CHUNK_SIZE:-104857600}" range i off prev

    range=$((end_off - start_off))
    [[ "$chunk_sz" -gt 0 ]] || chunk_sz="$range"
    echo "$start_off"
    prev="$start_off"
    i=1
    while [[ $((start_off + i * chunk_sz)) -lt "$end_off" ]]; do
        off=$(_align_to_line_start "$file" $((start_off + i * chunk_sz)) "$size")
        if [[ "$off" -gt "$prev" && "$off" -lt "$end_off" ]]; then
            echo "$off"
            prev="$off"
        fi
        i=$((i + 1))
    done
    echo "$end_off"
}

# Копирует каждый кусок [off, next) из _psl_plan_chunk_bounds (аргументы
# 6..N) в свой raw_NNNNN.log внутри raw_dir, оставляя только строки внутри
# [from_epoch, to_epoch] — защита от того, что интерполяционный поиск
# приземлился на несколько строк раньше/позже точной границы. Это ВНУТРЕННЯЯ
# параллельная нарезка на воркеры (гранулярность — MAX_LOG_CHUNK_SIZE), а не
# итоговые part_*.log в архиве — вызывающий код (parce_service_log())
# склеивает эти raw_*.log обратно в один файл и режет его заново на
# итоговые части через _psl_split_final_output() (LOG_CHUNK_MODE и т.п.).
# $5=sorted: 1 разрешает ранний выход из awk по каждому куску, как только
# встретилась строка позже to_epoch (безопасно только если файл
# действительно хронологически отсортирован); 0 — сканировать кусок целиком
# (когда _logs_appear_sorted() уже сказал "нет", а границы [off,next) —
# это просто весь файл, а не результат интерполяционного поиска).
# Отбрасывает куски, оказавшиеся пустыми. Печатает число непустых кусков.
_psl_copy_chunks() {
    local file="$1" raw_dir="$2" from_epoch="$3" to_epoch="$4" sorted="$5"
    local -a bounds=("${@:6}")
    local n=$((${#bounds[@]} - 1))
    local max_jobs i off next len part idx=0 count=0

    max_jobs=$(_collector_inner_max_jobs)
    [[ "$max_jobs" -lt 1 ]] && max_jobs=1
    _SEEK_JOB_PIDS=()

    for (( i=0; i<n; i++ )); do
        off="${bounds[$i]}"
        next="${bounds[$((i + 1))]}"
        len=$((next - off))
        [[ "$len" -le 0 ]] && continue
        idx=$((idx + 1))
        part=$(printf '%s/raw_%05d.log' "$raw_dir" "$idx")
        if ! _seek_wait_slot "$max_jobs"; then
            _seek_kill_jobs
            break
        fi
        (
            renice -n 10 $$ >/dev/null 2>&1 || true
            ionice -c 2 -n 7 -p $$ >/dev/null 2>&1 || true
            _extract_chunk_worker "$file" "$off" "$len" "$from_epoch" "$to_epoch" "$sorted" "$part"
        ) &
        _SEEK_JOB_PIDS+=($!)
    done
    _seek_wait_all_jobs

    for part in "$raw_dir"/raw_*.log; do
        [[ -e "$part" ]] || continue
        if [[ -s "$part" ]]; then
            count=$((count + 1))
        else
            rm -f -- "$part" 2>/dev/null
        fi
    done
    echo "$count"
}

# Извлекает часть лог-файла службы, чьи строки попадают в
# [ts_from, ts_to], в один или несколько чанк-файлов под /tmp.
#   $1 = путь к лог-файлу (или символьной ссылке на него)
#   $2 = начало диапазона — секунды epoch, либо всё, что понимает `date -d`
#   $3 = конец диапазона   — секунды epoch, либо всё, что понимает `date -d`
# При успехе: устанавливает PSL_OUTPUT_PATH (директория в /tmp с
# part_00001.log, part_00002.log, ...) и PSL_OUTPUT_CHUNKS (их количество),
# печатает "<PSL_OUTPUT_PATH> <PSL_OUTPUT_CHUNKS>", возвращает 0.
# При неудаче: выводит warn с причиной, возвращает 1, оставляет обе глобальные переменные неустановленными.
parce_service_log() {
    local log_path="$1" ts_from_raw="$2" ts_to_raw="$3"
    local real_path from_epoch to_epoch size range_str start_off end_off sorted=1
    local sort_mode backoff out_dir raw_dir combined raw_count chunk_count
    local -a bounds=()

    unset PSL_OUTPUT_PATH PSL_OUTPUT_CHUNKS

    real_path=$(_psl_resolve_log_path "$log_path") || return 1
    from_epoch=$(_psl_parse_timestamp "$ts_from_raw") || return 1
    to_epoch=$(_psl_parse_timestamp "$ts_to_raw") || return 1
    if [[ "$from_epoch" -gt "$to_epoch" ]]; then
        warn "parce_service_log: start timestamp is after end timestamp"
        return 1
    fi

    size=$(_file_size_bytes "$real_path")
    if [[ "$size" -le 0 ]]; then
        warn "parce_service_log: $real_path is empty or unreadable"
        return 1
    fi
    # Некоторые логгеры (например fcs-swau) пишут в строке только время без
    # даты — дата только в имени файла; без этого такие строки были бы
    # неотличимы от "нет метки времени вообще" везде ниже по конвейеру
    # (line_epoch() в awk читает эту переменную через -v ref_midnight=...).
    _LOG_REF_MIDNIGHT_EPOCH=$(_infer_file_midnight_epoch "$real_path")

    sort_mode=$(_logs_sort_mode "$real_path" "$size")
    case "$sort_mode" in
        sorted)
            range_str=$(_psl_locate_range "$real_path" "$size" "$from_epoch" "$to_epoch") || return 1
            read -r start_off end_off <<< "$range_str"
            ;;
        soft)
            # first≤last, середина плавает — seek с широким окном, без early-stop.
            sorted=0
            backoff="${SEEK_SOFT_SORT_BACKOFF_BYTES:-33554432}"
            log_debug "parce_service_log: soft-sorted seek ($real_path), backoff=${backoff}"
            range_str=$(_psl_locate_range "$real_path" "$size" "$from_epoch" "$to_epoch" "$backoff") || return 1
            read -r start_off end_off <<< "$range_str"
            ;;
        *)
            sorted=0
            warn "parce_service_log: $real_path does not look chronologically sorted — scanning the whole file instead of seeking"
            start_off=0
            end_off="$size"
            ;;
    esac

    out_dir=$(_psl_make_output_dir "$real_path" "$from_epoch" "$to_epoch")
    [[ -n "$out_dir" && -d "$out_dir" ]] || { warn "parce_service_log: cannot create output dir under /tmp"; return 1; }
    raw_dir="$out_dir/.raw"
    mkdir -p "$raw_dir" 2>/dev/null || { warn "parce_service_log: cannot create scratch dir under /tmp"; rm -rf -- "$out_dir" 2>/dev/null; return 1; }

    mapfile -t bounds < <(_psl_plan_chunk_bounds "$real_path" "$start_off" "$end_off" "$size")
    raw_count=$(_psl_copy_chunks "$real_path" "$raw_dir" "$from_epoch" "$to_epoch" "$sorted" "${bounds[@]}")

    if [[ ! "$raw_count" =~ ^[0-9]+$ ]] || [[ "$raw_count" -eq 0 ]]; then
        warn "parce_service_log: no lines matched inside the requested range"
        rm -rf -- "$out_dir" 2>/dev/null
        return 1
    fi

    # Склеиваем внутренние параллельные куски обратно в один файл (порядок
    # сохраняется благодаря нулям в raw_%05d) и режем его заново на итоговые
    # part_*.log согласно LOG_CHUNK_MODE — так же, как это делает
    # _psl_finalize_groups() для директорий/служб целиком.
    combined="$out_dir/.combined.log"
    cat "$raw_dir"/raw_*.log > "$combined" 2>/dev/null
    rm -rf -- "$raw_dir" 2>/dev/null

    chunk_count=$(_psl_split_final_output "$combined" "$out_dir" "part_")
    rm -f -- "$combined" 2>/dev/null

    if [[ ! "$chunk_count" =~ ^[0-9]+$ ]] || [[ "$chunk_count" -eq 0 ]]; then
        warn "parce_service_log: no lines matched inside the requested range"
        rm -rf -- "$out_dir" 2>/dev/null
        return 1
    fi

    PSL_OUTPUT_PATH="$out_dir"
    PSL_OUTPUT_CHUNKS="$chunk_count"
    echo "$PSL_OUTPUT_PATH $PSL_OUTPUT_CHUNKS"
}


# ==========================================================================
# РАЗДЕЛ: 05_extract_multi
# ==========================================================================
# Назначение: Извлечение диапазона из ВСЕХ файлов ротации лога службы (parce_service_logs) — соответствие служба → известные директории логов, применение parce_service_log к каждому файлу.
# Публичные функции: parce_service_logs()
# Зависит от: 04_extract_single.sh, 02_log_discovery.sh, 00_tunables.sh
# Не зависит от: 06_extract_apply.sh — вызывается им для применения к найденным директориям
# Side effects: читает/пишет файлы во временный/выходной каталог сборки архива
#
# Источник: перенесено без изменений логики из flat_check_2.sh (строки 4253-4655).

# --- 8c. Извлечение диапазона из логов службы целиком (parce_service_logs) ----
# Оборачивает parce_service_log() всем необходимым, чтобы дойти от просто
# *имени службы* до готового набора чанк-файлов: находит, где служба
# хранит свои логи, находит, какие из её файлов могут содержать данные в [from,to],
# пропускает архивную копию, если существует живая обычная копия того же файла,
# запускает parce_service_log() на каждом из уцелевших файлов (сначала распаковывая
# файлы, существующие только в архиве, во временную копию), затем объединяет и
# перенарезает по *типу* лога (access.log/access.log.1/access.2026-07-22.log.gz
# объединяются вместе; error.log — никогда), так что итоговый вывод — небольшое
# число опрятных файлов размером MAX_LOG_CHUNK_SIZE, а не один крошечный файл на
# каждый оригинал ротации. Все промежуточные файлы/директории удаляются перед
# возвратом — возвращённая директория содержит только финальный результат.

# --- Этап 1: явное соответствие служба -> известная(ые) директория(и) логов ---
# Нужно только для служб, у которых имя директории логов не совпадает с
# именем службы (логи mysqld лежат в /var/log/mysql, а не в /var/log/
# mysqld) — всё, где имя директории == имени службы, уже покрывается
# этапами 2/3 ниже и не требует записи здесь.

declare -A _PSL_SVC_LOG_DIRS=(
    [mysqld]="/var/log/mysql /var/lib/mysql"
    [mysql]="/var/log/mysql /var/lib/mysql"
    [mariadb]="/var/log/mysql /var/lib/mysql"
    [httpd]="/var/log/httpd"
    [redis-server]="/var/log/redis"
    [rabbitmq-server]="/var/log/rabbitmq"
)
# Этап 2: дополнительные родительские директории для поиска одноимённой подпапки
# (помимо стандартного /var/log, который проверяется отдельно на этапе 3). Включает
# /var/log/flat, поэтому внутренние продукты FLAT (любое имя из PKG_PRODUCT)
# находятся здесь автоматически по той же конвенции, которую уже использует
# find_log_dirs_for_pkg(), без необходимости добавлять запись на каждый продукт выше.
_PSL_SVC_SEARCH_ROOTS=(/var/log/flat /opt /opt/flat /var/opt /usr/local/var/log)

# Находит директорию(и) логов для имени службы. Печатает каждую
# отдельную директорию на своей строке (без дублей); возвращает 1 без
# вывода, если ничего не найдено. Например, ssh/sshd на большинстве систем
# закономерно не имеют выделенной директории (они пишут в syslog/auth.log) и
# корректно попадут именно в этот случай.
_psl_find_service_log_dirs() {
    local service="$1"
    local -a found=()
    local d root cfg_dir

    # Этап 1: явное соответствие, плюс пути из конфигов, которые некоторые
    # продукты FLAT уже регистрируют через get_log_path_from_config().
    for d in ${_PSL_SVC_LOG_DIRS[$service]:-}; do
        [[ -d "$d" ]] && found+=("$d")
    done
    cfg_dir=$(get_log_path_from_config "$service" 2>/dev/null)
    if [[ -n "$cfg_dir" ]]; then
        cfg_dir=$(eval echo "$cfg_dir" 2>/dev/null)
        [[ -d "$cfg_dir" ]] && found+=("$cfg_dir")
    fi

    # Этап 2: одноимённая подпапка внутри списка родительских корней.
    for root in "${_PSL_SVC_SEARCH_ROOTS[@]}"; do
        d="$root/$service"
        [[ -d "$d" ]] && found+=("$d")
    done

    # Этап 3: стандартная конвенция, проверяется явно, чтобы никогда не
    # пропускаться, даже если список корней этапа 2 выше в будущем сократят.
    d="/var/log/$service"
    [[ -d "$d" ]] && found+=("$d")

    [[ ${#found[@]} -eq 0 ]] && return 1
    printf '%s\n' "${found[@]}" | sort -u
}

# Печатает "start_epoch end_epoch" для файла: время создания (или время
# изменения inode, если файловая система/ядро не предоставляют настоящее
# время создания) как начало, mtime как конец — самая широкая разумная оценка
# промежутка, в течение которого файл мог получать строки лога.
_psl_file_time_span() {
    local file="$1" birth mtime ctime start

    birth=$(stat -c '%W' "$file" 2>/dev/null)
    ctime=$(stat -c '%Z' "$file" 2>/dev/null)
    mtime=$(stat -c '%Y' "$file" 2>/dev/null)

    if [[ "$birth" =~ ^[0-9]+$ ]] && [[ "$birth" -gt 0 ]]; then
        start="$birth"
    elif [[ "$ctime" =~ ^[0-9]+$ ]]; then
        start="$ctime"
    else
        start="$mtime"
    fi
    [[ "$mtime" =~ ^[0-9]+$ ]] || mtime="$start"
    # ctime (время изменения метаданных) может оказаться *позже* mtime для
    # ротированного файла — например, logrotate переименовывает его заметно
    # позже последней записанной строки, что двигает ctime, но не mtime —
    # ограничиваем, чтобы промежуток никогда не был перевёрнутым (иначе проверка
    # пересечения в _psl_scan_candidate_files() была бы ненадёжной).
    [[ "$start" -gt "$mtime" ]] && start="$mtime"
    echo "$start $mtime"
}

# Сканирует список директорий (не рекурсивно: это уже собственные
# директории логов службы, а не дерево для обхода) на обычные файлы, чей
# промежуток [birth/ctime, mtime] пересекается с [from_epoch, to_epoch]. Печатает
# по одному подходящему пути на строку.
_psl_scan_candidate_files() {
    local from_epoch="$1" to_epoch="$2"
    shift 2
    local -a dirs=("$@")
    local dir f fstart fend

    for dir in "${dirs[@]}"; do
        [[ -d "$dir" ]] || continue
        while IFS= read -r -d '' f; do
            [[ -f "$f" ]] || continue
            read -r fstart fend < <(_psl_file_time_span "$f")
            [[ "$fstart" =~ ^[0-9]+$ && "$fend" =~ ^[0-9]+$ ]] || continue
            [[ "$fstart" -le "$to_epoch" && "$fend" -ge "$from_epoch" ]] && echo "$f"
        done < <(find -L "$dir" -maxdepth 1 -type f -print0 2>/dev/null)
    done
}

# Печатает имя без архивного расширения (убирает .gz/.bz2/.xz/.zip/.Z),
# либо имя без изменений, если оно не архивировано.
_psl_strip_archive_ext() {
    local name="$1" ext
    for ext in .gz .bz2 .xz .zip .Z; do
        if [[ "$name" == *"$ext" ]]; then
            echo "${name%"$ext"}"
            return 0
        fi
    done
    echo "$name"
}

# Снимает суффикс logrotate после .log/.txt/.csv.
# Маска на практике: name.(log|txt|csv).<что угодно> —
#   sipdump.txt.1 | sipdump.txt.-20260731 | sipdump.txt.2026-07-31 | error.log.3
# Редко без точки: name.txt-20260731 / name.log_2026-07-31.
# Без этого sipdump.txt.-20260731 схлопывался в «sipdump.txt.» и отваливался
# от фильтра типов / группы live sipdump.txt (баг на РЕД ОС и др.).
_psl_strip_logrotate_suffix() {
    local name="$1"
    if [[ "$name" =~ ^(.+)\.(log|txt|csv)\..+ ]]; then
        printf '%s.%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
        return 0
    fi
    if [[ "$name" =~ ^(.+)\.(log|txt|csv)[-_][0-9]{4} ]]; then
        printf '%s.%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
        return 0
    fi
    printf '%s\n' "$name"
}

# Читает список кандидатов (по одному пути на строку) из stdin, отбрасывает
# любой архивный файл, у которого есть живой обычный «близнец» с идентичным
# именем (та же директория, то же имя после удаления архивного расширения) —
# один и тот же экземпляр ротации существует дважды, читать нужно только
# обычный — и печатает уцелевшие пути.
_psl_dedupe_archive_copies() {
    local -A has_plain=()
    local -a files=()
    local f dir base identity key

    mapfile -t files

    for f in "${files[@]}"; do
        dir=$(dirname -- "$f")
        base=$(basename -- "$f")
        identity=$(_psl_strip_archive_ext "$base")
        [[ "$base" == "$identity" ]] && has_plain["$dir/$identity"]=1
    done

    for f in "${files[@]}"; do
        dir=$(dirname -- "$f")
        base=$(basename -- "$f")
        identity=$(_psl_strip_archive_ext "$base")
        if [[ "$base" != "$identity" ]]; then
            key="$dir/$identity"
            [[ -n "${has_plain[$key]:-}" ]] && continue
        fi
        echo "$f"
    done
}

# Вычисляет «тип лога», к которому относится ротированный/архивный файл, так что
# access.log / access.log.1 / access.log.2.gz / access.2026-07-22.log /
# sipdump.txt.-20260731 все группируются вместе, а error.log остаётся отдельно.
# Убирает (по порядку): архивное расширение, суффикс logrotate после .log|.txt|.csv,
# ведущую дату в имени (FCS daily), прочие числовые/датированные хвосты.
_psl_log_group_key() {
    local key
    key=$(_psl_strip_archive_ext "$(basename -- "$1")")
    # SoftSwitch / logrotate: name.txt.<что угодно> → name.txt (до ведущей даты FCS)
    key=$(_psl_strip_logrotate_suffix "$key")
    # Ведущая дата в самом начале имени файла — ежедневная ротация вида
    # YYYY_MM_DD_service_log.log / YYYY-MM-DD-service.log (например у
    # fcs-swau/fcs-contact и других продуктов линейки FCS): без этого
    # каждый день считался бы своим собственным "типом" лога и никогда не
    # объединялся бы с остальными днями той же службы.
    key=$(printf '%s' "$key" | sed -E \
        -e 's/^[0-9]{4}[_-][0-9]{2}[_-][0-9]{2}[_-]//' \
        -e 's/^[0-9]{2}[_.][0-9]{2}[_.][0-9]{4}[_-]//')
    key=$(printf '%s' "$key" | sed -E \
        -e 's/\.[0-9]+$//' \
        -e 's/[-.][0-9]{4}-?[0-9]{2}-?[0-9]{2}$//')
    key=$(printf '%s' "$key" | sed -E \
        -e 's/[-.][0-9]{4}-[0-9]{2}-[0-9]{2}(\.log)$/\1/' \
        -e 's/\.[0-9]+(\.log)$/\1/')
    # хвост вроде «sipdump.txt.» после неудачного peel даты
    key="${key%.}"
    printf '%s' "$key"
}

# Если $1 обычный — печатает без изменений. Если он архивирован — распаковывает
# его в $2/scratch/ и вместо этого печатает путь к этой временной копии (вызывающий
# код сам отвечает за её удаление по завершении — сама parce_service_log()
# полностью отбрасывает сжатый ввод, искать внутри сжатого потока
# невозможно). .zip распознаётся выше для целей группировки/дедупликации,
# но здесь не распаковывается (неоднозначное имя внутреннего элемента) — логируется
# и пропускается.
_psl_materialize_plain() {
    local file="$1" work_dir="$2" scratch out

    case "$file" in
        *.gz)  : ;;
        *.bz2) : ;;
        *.xz)  : ;;
        *.zip|*.Z)
            warn "parce_service_logs: skipping unsupported archive format: $file" >&2
            return 1
            ;;
        *) echo "$file"; return 0 ;;
    esac

    scratch="$work_dir/scratch"
    mkdir -p "$scratch" 2>/dev/null || return 1
    out="$scratch/$(basename -- "$file").$$.${RANDOM}.plain"
    case "$file" in
        *.gz)  gunzip -c -- "$file" ;;
        *.bz2) bunzip2 -c -- "$file" ;;
        *.xz)  unxz -c -- "$file" ;;
    esac > "$out" 2>/dev/null

    if [[ -s "$out" ]]; then
        echo "$out"
    else
        rm -f -- "$out" 2>/dev/null
        return 1
    fi
}

# Запускает parce_service_log() на одном файле-кандидате и при успехе добавляет
# его извлечённый чанк(и) в аккумулятор группы этого файла под
# $work_dir/groups/. Немедленно чистит собственную tmp-директорию вывода
# parce_service_log() и любую распакованную во временную копию, независимо от исхода.
# Возвращает 0, если этот файл дал хоть какие-то строки, иначе 1 (нормально для
# ротированного файла, в котором просто нет ничего в диапазоне — это не ошибка).
_psl_process_one_candidate() {
    local file="$1" from_epoch="$2" to_epoch="$3" work_dir="$4"
    local plain is_scratch=0 group group_file rc=1

    plain=$(_psl_materialize_plain "$file" "$work_dir") || return 1
    [[ "$plain" != "$file" ]] && is_scratch=1

    if parce_service_log "$plain" "$from_epoch" "$to_epoch" >/dev/null 2>&1; then
        group=$(_psl_log_group_key "$file")
        group_file="$work_dir/groups/${group}.log"
        mkdir -p "$work_dir/groups" 2>/dev/null
        cat "$PSL_OUTPUT_PATH"/part_*.log >> "$group_file" 2>/dev/null
        rc=0
    fi
    rm -rf -- "${PSL_OUTPUT_PATH:-}" 2>/dev/null
    [[ "$is_scratch" -eq 1 ]] && rm -f -- "$plain" 2>/dev/null
    return "$rc"
}

# Свежая, прозрачно названная директория в /tmp для финального результата
# по службе: /tmp/parces_<service>_<from>-<to>.<random>/
_psl_make_service_output_dir() {
    local service="$1" from_epoch="$2" to_epoch="$3" base prefix
    base="${service//[^A-Za-z0-9._-]/_}"
    prefix="/tmp/parces_${base}_${from_epoch}-${to_epoch}"
    mktemp -d "${prefix}.XXXXXX" 2>/dev/null
}

# Разбивает один уже готовый (отфильтрованный/объединённый) файл на
# part_*.log в out_dir — целиком по строкам, никогда их не разрывая.
# Режим — LOG_CHUNK_MODE: "size" (умолчание) — split -C LOG_CHUNK_SIZE_BYTES;
# "lines" — split -l LOG_CHUNK_LINES. Это единственное место, где
# по-настоящему определяется размер/число строк итоговых файлов в архиве —
# и parce_service_log(), и _psl_finalize_groups() вызывают именно её.
# Печатает число получившихся частей (0, если src_file пуст/отсутствует).
_psl_split_final_output() {
    local src_file="$1" out_dir="$2" prefix="${3:-part_}"
    local count

    [[ -s "$src_file" ]] || { echo 0; return 0; }
    mkdir -p "$out_dir" 2>/dev/null || { echo 0; return 1; }

    if [[ "${LOG_CHUNK_MODE:-size}" == "lines" ]]; then
        split -l "${LOG_CHUNK_LINES:-500000}" -d --numeric-suffixes=1 -a 5 \
            --additional-suffix=.log -- "$src_file" "$out_dir/${prefix}" 2>/dev/null
    else
        split -C "${LOG_CHUNK_SIZE_BYTES:-104857600}" -d --numeric-suffixes=1 -a 5 \
            --additional-suffix=.log -- "$src_file" "$out_dir/${prefix}" 2>/dev/null
    fi

    count=$(find "$out_dir" -maxdepth 1 -type f -name "${prefix}*.log" 2>/dev/null | wc -l)
    echo "${count:-0}"
}

# Перенарезает каждый файл-аккумулятор группы в $work_dir/groups/ на
# part_*.log в $final_dir (через _psl_split_final_output(), см. LOG_CHUNK_*),
# с именами "<group>.part_NN.log". Печатает общее число записанных чанк-файлов.
_psl_finalize_groups() {
    local work_dir="$1" final_dir="$2"
    local gfile gkey count total=0

    for gfile in "$work_dir"/groups/*.log; do
        [[ -s "$gfile" ]] || continue
        gkey=$(basename -- "$gfile"); gkey="${gkey%.log}"
        count=$(_psl_split_final_output "$gfile" "$final_dir" "${gkey}.part_")
        [[ "$count" =~ ^[0-9]+$ ]] && total=$((total + count))
    done

    echo "$total"
}

# Извлекает каждый лог-файл заданной службы, который попадает (хотя бы частично)
# в [ts_from, ts_to], в небольшой набор объединённых, ограниченных по размеру
# чанк-файлов под /tmp.
#   $1 = имя службы (nginx, mysqld, apache2, ssh, имя пакета внутреннего
#        продукта FLAT, ...)
#   $2 = начало диапазона — секунды epoch, либо всё, что понимает `date -d`
#   $3 = конец диапазона   — секунды epoch, либо всё, что понимает `date -d`
# При успехе: устанавливает PSLS_OUTPUT_PATH (директория в /tmp с
# <type>.part_NN.log на каждый тип лога — access/error/и т.д. никогда не смешиваются) и
# PSLS_OUTPUT_CHUNKS, печатает "<PSLS_OUTPUT_PATH> <PSLS_OUTPUT_CHUNKS>",
# возвращает 0. При неудаче: выводит warn с причиной, возвращает 1.
parce_service_logs() {
    local service="$1" ts_from_raw="$2" ts_to_raw="$3"
    local from_epoch to_epoch work_dir final_dir chunk_count processed=0
    local f
    local -a dirs=() candidates=() kept=()

    unset PSLS_OUTPUT_PATH PSLS_OUTPUT_CHUNKS

    [[ -n "$service" ]] || { warn "parce_service_logs: no service name given"; return 1; }
    from_epoch=$(_psl_parse_timestamp "$ts_from_raw") || return 1
    to_epoch=$(_psl_parse_timestamp "$ts_to_raw") || return 1
    if [[ "$from_epoch" -gt "$to_epoch" ]]; then
        warn "parce_service_logs: start timestamp is after end timestamp"
        return 1
    fi

    mapfile -t dirs < <(_psl_find_service_log_dirs "$service")
    if [[ ${#dirs[@]} -eq 0 ]]; then
        warn "parce_service_logs: no log directory found for service '$service'"
        return 1
    fi
    info "parce_service_logs: $service log dirs: ${dirs[*]}"

    mapfile -t candidates < <(_psl_scan_candidate_files "$from_epoch" "$to_epoch" "${dirs[@]}")
    if [[ ${#candidates[@]} -eq 0 ]]; then
        warn "parce_service_logs: no files for '$service' overlap the requested range"
        return 1
    fi
    mapfile -t kept < <(printf '%s\n' "${candidates[@]}" | _psl_dedupe_archive_copies)

    work_dir=$(mktemp -d "/tmp/parces_work_${service}.XXXXXX" 2>/dev/null) || {
        warn "parce_service_logs: cannot create scratch dir under /tmp"
        return 1
    }

    for f in "${kept[@]}"; do
        _psl_process_one_candidate "$f" "$from_epoch" "$to_epoch" "$work_dir" \
            && processed=$((processed + 1))
    done

    if [[ "$processed" -eq 0 ]]; then
        warn "parce_service_logs: no lines matched inside the requested range for '$service'"
        rm -rf -- "$work_dir" 2>/dev/null
        return 1
    fi

    final_dir=$(_psl_make_service_output_dir "$service" "$from_epoch" "$to_epoch")
    if [[ -z "$final_dir" || ! -d "$final_dir" ]]; then
        warn "parce_service_logs: cannot create output dir under /tmp"
        rm -rf -- "$work_dir" 2>/dev/null
        return 1
    fi

    chunk_count=$(_psl_finalize_groups "$work_dir" "$final_dir")
    rm -rf -- "$work_dir" 2>/dev/null

    if [[ ! "$chunk_count" =~ ^[0-9]+$ ]] || [[ "$chunk_count" -eq 0 ]]; then
        warn "parce_service_logs: nothing to output for '$service'"
        rm -rf -- "$final_dir" 2>/dev/null
        return 1
    fi

    PSLS_OUTPUT_PATH="$final_dir"
    PSLS_OUTPUT_CHUNKS="$chunk_count"
    echo "$PSLS_OUTPUT_PATH $PSLS_OUTPUT_CHUNKS"
}


# ==========================================================================
# РАЗДЕЛ: 06_extract_apply
# ==========================================================================
# Назначение: Применение parce_service_log(s) к уже найденным директориям: потоковое сравнение/дедупликация файлов по диапазону, zgrep/архивные эвристики, прогресс offline-extract между параллельными job'ами по файлам, пул воркеров.
# Публичные функции: _log_extract_all_dirs_by_range(), _log_extract_dir_by_range(), _collect_progress_*(), _log_file_pool_worker(), _selftest_seek_extract() (used by extended self-test, см. lib/core.sh (раздел 11_selftest))
# Зависит от: 04_extract_single.sh, 05_extract_multi.sh, 01_time_filters.sh, 00_tunables.sh, lib/core (resource-gate: _collector_wait_slot/_collector_resources_ok)
# Не зависит от: 07_collector.sh/08_online_offline.sh — они вызывают функции отсюда, а не наоборот
# Side effects: запускает параллельные фоновые job'ы (&), пишет/читает файлы прогресса, распаковывает .gz на лету
#
# Источник: перенесено без изменений логики из flat_check_2.sh (строки 4656-5494).

# --- 8d. Applying parce_service_log(s) to already-discovered directories -----
# run_log_collection() already knows exactly which directories to look at
# for the selected packages — discover_log_dirs_for_selected() is built on
# FLAT's own PKG_PRODUCT/PKG_LEGACY/config knowledge, which is more precise
# than guessing a directory from a bare service name the way
# _psl_find_service_log_dirs() has to. What online and offline collection
# *do* with a directory's files once found, though, is exactly what
# parce_service_log(s) already solved: skip an archived file when a live
# plain twin exists, and (offline only) extract by time range, merged by
# log type into size-bounded chunks instead of one tiny file per rotated
# original. The functions below reuse those already-tested building blocks
# against a caller-supplied directory instead of re-discovering it by name
# — this is the "search" logic online and offline collection share.

# NUL-delimited passthrough filter: drops an archived file (paths arrive
# NUL-separated on stdin, e.g. from find_log_files_in_dir()) whenever a
# live plain file with the identical name (modulo the archive extension)
# is also present. Thin adapter so callers already working with NUL-safe
# file streams — as the rest of the collector does — can reuse the
# newline-based _psl_dedupe_archive_copies() from the parce_service_log(s)
# module without giving up NUL-safety at the edges.

_log_dedupe_files_stream() {
    local f
    local -a files=() kept=()
    while IFS= read -r -d '' f; do files+=("$f"); done
    [[ ${#files[@]} -eq 0 ]] && return 0
    # Хронологический порядок (старые сначала) по mtime — иначе порядок
    # определялся бы обходом каталога (не гарантированно по датам), и
    # объединённый файл группы (для нескольких ежедневно ротируемых файлов
    # одной службы) читался бы вперемешку, а не по дням подряд.
    mapfile -t files < <(
        for f in "${files[@]}"; do
            printf '%s\t%s\n' "$(stat -c '%Y' "$f" 2>/dev/null || echo 0)" "$f"
        done | sort -t $'\t' -k1,1n | cut -f2-
    )
    mapfile -t kept < <(printf '%s\n' "${files[@]}" | _psl_dedupe_archive_copies)
    if [[ "${#kept[@]}" -ne "${#files[@]}" ]]; then
        local -A kept_set=()
        local skipped=0
        for f in "${kept[@]}"; do kept_set["$f"]=1; done
        for f in "${files[@]}"; do
            if [[ -z "${kept_set[$f]:-}" ]]; then
                skipped=$((skipped + 1))
                # Консоль — кратко; session-лог — подробно (plain приоритетнее архива)
                warn "duplicate skipped: $(basename -- "$f") (plain preferred)"
                _log_line "WARN" "duplicate archive skipped (plain preferred): $f"
            fi
        done
        [[ "$skipped" -gt 0 ]] && info "Duplicates: skipped $skipped archive twin(s), kept plain"
    fi
    printf '%s\0' "${kept[@]+"${kept[@]}"}"
}

# The exact candidate file list both start_tail_for_dir() (online) and
# _log_extract_dir_by_range() (offline) iterate over: find_log_files_in_dir()'s
# existing name/mgcpclient/online-.gz rules, plus the archive-vs-plain
# dedup above.
_log_candidate_files_for_dir() {
    _log_dedupe_files_stream < <(find_log_files_in_dir "$1")
}

# True if a file's [birth/ctime, mtime] span could contain data inside
# [from_epoch, to_epoch] — the same estimate parce_service_logs() uses to
# decide whether one of a service's files is worth opening at all. An
# unknown span is never skipped here (better to let the content-level
# filter inside parce_service_log() decide than to guess wrong up front).
_log_file_in_range() {
    local file="$1" from_epoch="$2" to_epoch="$3" fstart fend
    read -r fstart fend < <(_psl_file_time_span "$file")
    [[ "$fstart" =~ ^[0-9]+$ && "$fend" =~ ^[0-9]+$ ]] || return 0
    [[ "$fstart" -le "$to_epoch" && "$fend" -ge "$from_epoch" ]]
}

# Midnight epoch YYYY-MM-DD / YYYY_MM_DD / YYYYMMDD / DD.MM.YYYY из имени файла, или "".
_log_filename_day_epoch() {
    local base day
    base=$(basename -- "$1")
    if [[ "$base" =~ (^|[^0-9])([0-9]{4})[_-]([0-9]{2})[_-]([0-9]{2})([^0-9]|$) ]]; then
        day="${BASH_REMATCH[2]}-${BASH_REMATCH[3]}-${BASH_REMATCH[4]}"
    elif [[ "$base" =~ (^|[^0-9])([0-9]{4})([0-9]{2})([0-9]{2})([^0-9]|$) ]]; then
        day="${BASH_REMATCH[2]}-${BASH_REMATCH[3]}-${BASH_REMATCH[4]}"
    elif [[ "$base" =~ (^|[^0-9])([0-9]{2})\.([0-9]{2})\.([0-9]{4})([^0-9]|$) ]]; then
        day="${BASH_REMATCH[4]}-${BASH_REMATCH[3]}-${BASH_REMATCH[2]}"
    else
        return 1
    fi
    date -d "$day 00:00:00" "+%s" 2>/dev/null
}

# Грубый отсев: файл 100% вне [from,to] с запасом ±1 календарный день (NYE/TZ).
# return 0 = точно вне (можно не открывать); 1 = возможно пересекается.
_log_coarse_definitely_outside() {
    local file="$1" from_epoch="$2" to_epoch="$3"
    local margin="${LOG_RANGE_DAY_MARGIN_SEC:-86400}"
    local coarse_from=$((from_epoch - margin)) coarse_to=$((to_epoch + margin))
    local fstart fend day_ep from_mid to_mid from_day to_day

    if day_ep=$(_log_filename_day_epoch "$file"); then
        # Сравниваем календарные дни, не wall-clock с margin от 00:30 —
        # иначе 31.12 00:00 ошибочно < (01.01 00:30 − 1d).
        from_mid=$(date -d "$(date -d "@$from_epoch" "+%Y-%m-%d") 00:00:00" "+%s" 2>/dev/null) || from_mid=$from_epoch
        to_mid=$(date -d "$(date -d "@$to_epoch" "+%Y-%m-%d") 00:00:00" "+%s" 2>/dev/null) || to_mid=$to_epoch
        from_day=$((from_mid - margin))
        to_day=$((to_mid + margin))
        if [[ "$day_ep" -lt "$from_day" || "$day_ep" -gt "$to_day" ]]; then
            return 0
        fi
        return 1
    fi

    read -r fstart fend < <(_psl_file_time_span "$file")
    [[ "$fstart" =~ ^[0-9]+$ && "$fend" =~ ^[0-9]+$ ]] || return 1
    if [[ "$fend" -lt "$coarse_from" || "$fstart" -gt "$coarse_to" ]]; then
        return 0
    fi
    return 1
}

# Длина диапазона в секундах (для выбора hour vs day zgrep и skip .N.gz).
_log_range_span_sec() {
    local from_epoch="$1" to_epoch="$2"
    local span=$((to_epoch - from_epoch))
    [[ "$span" -lt 0 ]] && span=0
    echo "$span"
}

# Экранирование литерала для ERE (zgrep -E): точки в DD.MM.YYYY и т.п.
_log_ere_quote() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//./\\.}"
    s="${s//[/\\[}"
    s="${s//]/\\)}"
    s="${s//+/\\+}"
    s="${s//\*/\\*}"
    s="${s//\?/\\?}"
    s="${s//|/\\|}"
    s="${s//\{/\\{}"
    printf '%s' "$s"
}

# Паттерн дат ^DD.MM.YYYY|^YYYY-MM-DD на каждый день [from-margin .. to+margin], ≤ LOG_ZGREP_MAX_DAYS.
# Якорь ^ — чтобы sipdump не ловил дату внутри тела SIP.
_log_day_grep_pattern() {
    local from_epoch="$1" to_epoch="$2"
    local margin="${LOG_RANGE_DAY_MARGIN_SEC:-86400}"
    local maxd="${LOG_ZGREP_MAX_DAYS:-32}"
    local cur end pat d1 d2 day n=0
    day=$(date -d "@$((from_epoch - margin))" "+%Y-%m-%d" 2>/dev/null) || return 1
    cur=$(date -d "$day 00:00:00" "+%s" 2>/dev/null) || return 1
    day=$(date -d "@$((to_epoch + margin))" "+%Y-%m-%d" 2>/dev/null) || return 1
    end=$(date -d "$day 23:59:59" "+%s" 2>/dev/null) || return 1
    pat=""
    while [[ "$cur" -le "$end" && "$n" -lt "$maxd" ]]; do
        d1=$(date -d "@$cur" "+%d.%m.%Y" 2>/dev/null) || break
        d2=$(date -d "@$cur" "+%Y-%m-%d" 2>/dev/null) || break
        d1=$(_log_ere_quote "$d1")
        d2=$(_log_ere_quote "$d2")
        [[ -n "$pat" ]] && pat="${pat}|"
        pat="${pat}^${d1}|^${d2}"
        n=$((n + 1))
        cur=$((cur + 86400))
    done
    [[ -n "$pat" ]] || return 1
    printf '%s' "$pat"
}

# Паттерн часов SoftSwitch: «^DD.MM.YYYY HH:» | «^YYYY-MM-DD HH:» (±1h), ≤ LOG_ZGREP_MAX_HOURS.
_log_hour_grep_pattern() {
    local from_epoch="$1" to_epoch="$2"
    local maxh="${LOG_ZGREP_MAX_HOURS:-48}"
    local cur end pat d1 d2 n=0
    cur=$(( (from_epoch / 3600) * 3600 - 3600 ))
    end=$(( (to_epoch / 3600) * 3600 + 3600 ))
    [[ "$cur" -lt 0 ]] && cur=0
    pat=""
    while [[ "$cur" -le "$end" && "$n" -lt "$maxh" ]]; do
        d1=$(date -d "@$cur" "+%d.%m.%Y %H:" 2>/dev/null) || break
        d2=$(date -d "@$cur" "+%Y-%m-%d %H:" 2>/dev/null) || break
        d1=$(_log_ere_quote "$d1")
        d2=$(_log_ere_quote "$d2")
        [[ -n "$pat" ]] && pat="${pat}|"
        pat="${pat}^${d1}|^${d2}"
        n=$((n + 1))
        cur=$((cur + 3600))
    done
    [[ -n "$pat" ]] || return 1
    printf '%s' "$pat"
}

# Выбрать zgrep-паттерн: короткий диапазон → часы, иначе дни.
_log_archive_grep_pattern() {
    local from_epoch="$1" to_epoch="$2"
    local span hour_max
    span=$(_log_range_span_sec "$from_epoch" "$to_epoch")
    hour_max="${LOG_ZGREP_HOUR_MAX_SEC:-86400}"
    if [[ "$span" -le "$hour_max" ]]; then
        _log_hour_grep_pattern "$from_epoch" "$to_epoch" && return 0
    fi
    _log_day_grep_pattern "$from_epoch" "$to_epoch"
}

_log_is_compressed_log() {
    case "$1" in
        *.gz|*.bz2|*.xz|*.tgz|*.tar.gz) return 0 ;;
        *) return 1 ;;
    esac
}

# Поток распаковки архива в stdout. return 1 если формат/утилита недоступны.
_log_stream_decompress() {
    local file="$1"
    case "$file" in
        *.tar.gz|*.tgz)
            command -v tar >/dev/null 2>&1 || return 1
            tar -xOzf "$file" 2>/dev/null
            ;;
        *.gz)
            if command -v gzip >/dev/null 2>&1; then gzip -dc -- "$file" 2>/dev/null
            elif command -v zcat >/dev/null 2>&1; then zcat -- "$file" 2>/dev/null
            else return 1
            fi
            ;;
        *.bz2)
            if command -v bunzip2 >/dev/null 2>&1; then bunzip2 -c -- "$file" 2>/dev/null
            elif command -v bzcat >/dev/null 2>&1; then bzcat -- "$file" 2>/dev/null
            else return 1
            fi
            ;;
        *.xz)
            if command -v unxz >/dev/null 2>&1; then unxz -c -- "$file" 2>/dev/null
            elif command -v xzcat >/dev/null 2>&1; then xzcat -- "$file" 2>/dev/null
            else return 1
            fi
            ;;
        *) return 1 ;;
    esac
}

# zgrep/аналог по выбранному паттерну (−m 1).
# 0 = hit; 1 = miss; 2 = инструмент/паттерн недоступен (не считать miss).
_log_archive_zgrep_hit() {
    local file="$1" from_epoch="$2" to_epoch="$3"
    local pat
    pat=$(_log_archive_grep_pattern "$from_epoch" "$to_epoch") || return 2
    case "$file" in
        *.gz)
            if command -v zgrep >/dev/null 2>&1; then
                zgrep -m 1 -E -- "$pat" "$file" >/dev/null 2>&1 && return 0
                return 1
            fi
            ;;
        *.bz2)
            if command -v bzgrep >/dev/null 2>&1; then
                bzgrep -m 1 -E -- "$pat" "$file" >/dev/null 2>&1 && return 0
                return 1
            fi
            ;;
        *.xz)
            if command -v xzgrep >/dev/null 2>&1; then
                xzgrep -m 1 -E -- "$pat" "$file" >/dev/null 2>&1 && return 0
                return 1
            fi
            ;;
    esac
    if _log_stream_decompress "$file" | grep -m 1 -E -- "$pat" >/dev/null 2>&1; then
        return 0
    fi
    _log_stream_decompress "$file" >/dev/null 2>&1 || return 2
    return 1
}

# Совместимость: старое имя = day/hour zgrep hit.
_log_archive_zgrep_day_hit() {
    _log_archive_zgrep_hit "$@"
}

# Живой plain для архивной ротации → dir/stem
# (sipdump.txt.1.gz / sipdump.txt.-20260731.gz → sipdump.txt).
_log_live_plain_for_rotated_archive() {
    local file="$1" dir base identity live
    dir=$(dirname -- "$file")
    base=$(basename -- "$file")
    identity=$(_psl_strip_archive_ext "$base")
    [[ "$identity" == "$base" ]] && return 1
    live=$(_psl_strip_logrotate_suffix "$identity")
    [[ "$live" != "$identity" ]] || return 1
    [[ -f "$dir/$live" ]] && { echo "$dir/$live"; return 0; }
    return 1
}

# Короткое окно + есть live plain, покрывающий [from,to] → .N.gz не читаем.
# return 0 = skip archive; 1 = не skip.
_log_skip_rotated_archive_if_plain_covers() {
    local file="$1" from_epoch="$2" to_epoch="$3"
    local span max_span live
    span=$(_log_range_span_sec "$from_epoch" "$to_epoch")
    max_span="${LOG_PLAIN_COVERS_ROTATED_MAX_SEC:-86400}"
    [[ "$span" -le "$max_span" ]] || return 1
    live=$(_log_live_plain_for_rotated_archive "$file") || return 1
    if _log_file_in_range "$live" "$from_epoch" "$to_epoch"; then
        log_debug "discarded (live plain covers short range): $file (plain=$live)"
        return 0
    fi
    return 1
}

# 12-точечная проба epoch по потоку (начало, конец, 10 пропорциональных).
# return 0 = пересечение с [from,to] вероятно/точно; 1 = нет.
# Дорого (full decompress) — вызывается только если zgrep недоступен / undated fallback.
_log_archive_probe_overlap() {
    local file="$1" from_epoch="$2" to_epoch="$3"
    local usize=0
    case "$file" in
        *.gz) usize=$(gzip -l -- "$file" 2>/dev/null | awk 'NR==2 {print $2; exit}') ;;
    esac
    [[ "$usize" =~ ^[0-9]+$ ]] || usize=0
    _log_stream_decompress "$file" 2>/dev/null | tr -d '\0' | LC_ALL=C awk \
        -v from="$from_epoch" -v to="$to_epoch" -v usize="$usize" \
        -v ref_midnight=0 \
        "${_AWK_LINE_EPOCH}
        BEGIN {
            nprobe = 12
            for (i = 0; i < nprobe; i++) probe_at[i] = -1
            bytes = 0; have = 0; hit = 0
            first = 0; last = 0
            next_i = 0
            if (usize > 0) step = usize / (nprobe - 1)
            else step = 0
        }
        {
            bytes += length(\$0) + 1
            ep = line_epoch(\$0)
            if (ep >= 0) {
                if (!have) { first = ep; have = 1 }
                last = ep
                if (ep >= from && ep <= to) { hit = 1; exit }
            }
            if (step > 0) {
                while (next_i < nprobe && bytes >= next_i * step) {
                    if (ep >= 0) probe_at[next_i] = ep
                    else if (have) probe_at[next_i] = last
                    next_i++
                }
            }
        }
        END {
            if (hit) exit 0
            if (have && first <= to && last >= from) exit 0
            for (i = 0; i < nprobe; i++) {
                if (probe_at[i] >= from && probe_at[i] <= to) exit 0
            }
            if (!have) exit 0
            exit 1
        }"
}

# Решение по архиву после coarse: zgrep → (опц.) probe. 0=process, 1=skip.
_log_archive_should_process() {
    local file="$1" from_epoch="$2" to_epoch="$3"
    local zg=0

    if _log_skip_rotated_archive_if_plain_covers "$file" "$from_epoch" "$to_epoch"; then
        return 1
    fi

    _log_archive_zgrep_hit "$file" "$from_epoch" "$to_epoch"
    zg=$?
    if [[ "$zg" -eq 0 ]]; then
        return 0
    fi
    if [[ "$zg" -eq 1 ]]; then
        # miss: dated SoftSwitch / короткий hour-zgrep — не жжём второй full-decompress
        if [[ "${LOG_ARCHIVE_SKIP_PROBE_ON_ZGREP_MISS:-1}" -eq 1 ]]; then
            log_debug "discarded (archive zgrep miss, skip probe): $file"
            return 1
        fi
        if _log_archive_probe_overlap "$file" "$from_epoch" "$to_epoch"; then
            return 0
        fi
        log_debug "discarded (archive probe/zgrep: no overlap): $file"
        return 1
    fi
    # zg=2: нет *grep/паттерна — undated/HH:MM:SS: один extract лучше, чем слепой skip
    if _log_filename_day_epoch "$file" >/dev/null 2>&1; then
        # имя с датой, но zgrep недоступен: дешёвый coarse уже прошёл → пробуем extract
        return 0
    fi
    if [[ "${LOG_ARCHIVE_SKIP_PROBE_ON_ZGREP_MISS:-1}" -eq 1 ]]; then
        return 0
    fi
    if _log_archive_probe_overlap "$file" "$from_epoch" "$to_epoch"; then
        return 0
    fi
    log_debug "discarded (archive probe: no overlap): $file"
    return 1
}

# SoftSwitch multi-writer стемы: mid «плавает» — early-stop на архиве опасен.
_log_stem_is_soft_sorted() {
    local stem
    stem=$(_log_type_stem "$1")
    case "$stem" in
        sipdump|clustermonitorlog|clustermonitor|sipsigthr_log|sippbx|sipsigthr)
            return 0
            ;;
    esac
    return 1
}

# 1/0 — включать ли early-stop при stream-extract архива.
_log_archive_stream_sorted() {
    local file="$1"
    if _log_stem_is_soft_sorted "$file"; then
        echo 0
        return
    fi
    echo "${LOG_ARCHIVE_STREAM_SORTED:-1}"
}

# Стоит ли открывать файл для offline-диапазона (дешёвые проверки → zgrep → …).
_log_should_process_for_range() {
    local file="$1" from_epoch="$2" to_epoch="$3"
    [[ -n "$from_epoch" || -n "$to_epoch" ]] || return 0
    from_epoch="${from_epoch:-0}"
    to_epoch="${to_epoch:-9999999999}"

    if _log_coarse_definitely_outside "$file" "$from_epoch" "$to_epoch"; then
        log_debug "discarded (coarse day/mtime outside range±1d): $file"
        return 1
    fi

    if _log_is_compressed_log "$file"; then
        _log_archive_should_process "$file" "$from_epoch" "$to_epoch"
        return $?
    fi

    # plain: прежняя mtime/ctime эвристика
    if _log_file_in_range "$file" "$from_epoch" "$to_epoch"; then
        return 0
    fi
    log_debug "discarded (plain birth/mtime span outside range): $file"
    return 1
}

# Extracts (or, with no time range, plain-copies) one file into its log-
# type group accumulator under $work_dir/groups/ — the very accumulator
# parce_service_logs() itself writes to, so _psl_finalize_groups() can
# re-chunk it later without caring whether the source was a service name
# or an already-known directory. Mirrors _psl_process_one_candidate(),
# with one difference: empty from_epoch/to_epoch means "collect
# everything" (offline with no --from/--to at all), which skips the
# epoch filter entirely instead of forcing every line through it for
# nothing.
# Если задан только from (режим «за последние Nd»), to по умолчанию —
# сейчас: иначе пустой to раньше доходил до date -d "" → полночь сегодня
# и обрезал хвост текущего дня.
# Один decompress|awk в group_file. sorted/grace — из TUNABLES;
# soft-стемы (sipdump) — без early-stop.
# return 0 если хоть что-то дописалось.
_log_stream_extract_to_group() {
    local file="$1" from_epoch="$2" to_epoch="$3" group_file="$4"
    local before_sz=0 after_sz=0 sorted=0 grace=0

    [[ -f "$group_file" ]] && before_sz=$(_file_size_bytes "$group_file")
    _LOG_REF_MIDNIGHT_EPOCH=$(_infer_file_midnight_epoch "$file")
    sorted=$(_log_archive_stream_sorted "$file")
    grace="${LOG_ARCHIVE_EARLY_STOP_GRACE_SEC:-300}"
    _log_stream_decompress "$file" 2>/dev/null \
        | tr -d '\0' \
        | LC_ALL=C awk -v from="$from_epoch" -v to="$to_epoch" \
            -v ref_midnight="${_LOG_REF_MIDNIGHT_EPOCH:-0}" \
            "$(_awk_filter_range_prog "$sorted" "$grace")" \
        >> "$group_file" 2>/dev/null || true
    [[ -f "$group_file" ]] && after_sz=$(_file_size_bytes "$group_file")
    [[ "$after_sz" -gt "$before_sz" ]]
}

_log_extract_one_file() {
    local file="$1" from_epoch="$2" to_epoch="$3" work_dir="$4"
    local plain is_scratch=0 group group_file rc=1

    group=$(_psl_log_group_key "$file")
    group_file="$work_dir/groups/${group}.log"
    mkdir -p "$work_dir/groups" 2>/dev/null

    # Сжатые + диапазон: один поток decompress|awk (без temp plain, с early-stop)
    if [[ -n "$from_epoch" || -n "$to_epoch" ]] && _log_is_compressed_log "$file"; then
        [[ -n "$from_epoch" && -z "$to_epoch" ]] && to_epoch=$(date +%s)
        [[ -z "$from_epoch" && -n "$to_epoch" ]] && from_epoch=0
        _log_stream_extract_to_group "$file" "$from_epoch" "$to_epoch" "$group_file"
        return $?
    fi

    plain=$(_psl_materialize_plain "$file" "$work_dir") || return 1
    [[ "$plain" != "$file" ]] && is_scratch=1

    if [[ -z "$from_epoch" && -z "$to_epoch" ]]; then
        cat "$plain" >> "$group_file" 2>/dev/null && rc=0
    else
        [[ -n "$from_epoch" && -z "$to_epoch" ]] && to_epoch=$(date +%s)
        [[ -z "$from_epoch" && -n "$to_epoch" ]] && from_epoch=0
        if parce_service_log "$plain" "$from_epoch" "$to_epoch" >/dev/null 2>&1; then
            cat "$PSL_OUTPUT_PATH"/part_*.log >> "$group_file" 2>/dev/null
            rc=0
        fi
    fi
    rm -rf -- "${PSL_OUTPUT_PATH:-}" 2>/dev/null
    [[ "$is_scratch" -eq 1 ]] && rm -f -- "$plain" 2>/dev/null
    return "$rc"
}

# --- прогресс offline-extract (общий счётчик между parallel file-jobs) ----------
# Sticky-строка: всегда \r + CSI K (стереть до конца), иначе хвост прошлого
# имени «наезжает» (ping.log + agent.log → ping.loggent.log).
_collect_progress_init() {
    local total="$1"
    _COLLECT_PROGRESS_TOTAL="$total"
    _COLLECT_PROGRESS_DIR=$(mktemp -d "${TMPDIR:-/tmp}/flat_prog.XXXXXX") || {
        _COLLECT_PROGRESS_DIR=""
        return 1
    }
    printf '0\n' > "$_COLLECT_PROGRESS_DIR/done"
    : > "$_COLLECT_PROGRESS_DIR/label"
    if [[ -t 1 ]]; then
        printf '[INFO] extract: 0%% (0/%s)\n' "$total"
    else
        info "extract: 0% (0/$total)"
    fi
}

_collect_progress_fmt_label() {
    # убрать CR/CSI из имени; обрезать, чтобы строка не разъезжалась
    local s="$1"
    s="${s//$'\r'/}"
    s="${s//$'\033'/}"
    s="${s:0:48}"
    printf '%s' "$s"
}

_collect_progress_tick() {
    local label="${1:-}"
    local done total pct last_pct lock shown
    [[ -n "${_COLLECT_PROGRESS_DIR:-}" && -d "$_COLLECT_PROGRESS_DIR" ]] || return 0
    total="${_COLLECT_PROGRESS_TOTAL:-0}"
    [[ "$total" -gt 0 ]] || return 0
    label=$(_collect_progress_fmt_label "$label")
    lock="$_COLLECT_PROGRESS_DIR/lock"
    (
        if command -v flock >/dev/null 2>&1; then
            flock 9
        fi
        done=$(cat "$_COLLECT_PROGRESS_DIR/done" 2>/dev/null || echo 0)
        done=$((done + 1))
        printf '%s\n' "$done" > "$_COLLECT_PROGRESS_DIR/done"
        [[ -n "$label" ]] && printf '%s\n' "$label" > "$_COLLECT_PROGRESS_DIR/label"
        pct=$((done * 100 / total))
        last_pct=$(cat "$_COLLECT_PROGRESS_DIR/last_pct" 2>/dev/null || echo -1)
        shown="extract: ${pct}% (${done}/${total}) ${label}"
        # консоль: sticky \r + clear-to-EOL; в лог — каждый ≥5% или последний
        if [[ -t 1 ]]; then
            printf '\r\033[K[INFO] %s' "$shown"
            [[ "$done" -ge "$total" ]] && printf '\n'
        fi
        if [[ "$pct" -ge $((last_pct + 5)) || "$done" -ge "$total" ]]; then
            printf '%s\n' "$pct" > "$_COLLECT_PROGRESS_DIR/last_pct"
            _log_line "INFO" "$shown"
            if [[ ! -t 1 ]]; then
                info "$shown"
            fi
        fi
    ) 9>"$lock" 2>/dev/null || true
}

_collect_progress_finish() {
    local done total
    [[ -n "${_COLLECT_PROGRESS_DIR:-}" && -d "$_COLLECT_PROGRESS_DIR" ]] || return 0
    done=$(cat "$_COLLECT_PROGRESS_DIR/done" 2>/dev/null || echo 0)
    total="${_COLLECT_PROGRESS_TOTAL:-0}"
    if [[ -t 1 ]]; then
        printf '\r\033[K[INFO] extract: 100%% (%s/%s) done\n' "$done" "$total"
    fi
    log_debug "extract progress finished: ${done}/${total}"
    rm -rf -- "$_COLLECT_PROGRESS_DIR" 2>/dev/null
    _COLLECT_PROGRESS_DIR=""
    _COLLECT_PROGRESS_TOTAL=0
}

# Runs _log_extract_one_file() over every candidate in one already-
# discovered source directory, then re-chunks the result into $dest_dir.
# Empty from_epoch/to_epoch means no time filter at all (offline with no
# --from/--to given). Returns 1 if nothing ended up in $dest_dir — normal
# when a directory's files simply have nothing in range, not an error.
_log_extract_dir_by_range() {
    local src_dir="$1" dest_dir="$2" from_epoch="$3" to_epoch="$4"
    local work_dir f processed=0 seen=0 chunk_count base

    work_dir=$(mktemp -d "${TMPDIR:-/tmp}/flat_logdir.XXXXXX") || return 1

    while IFS= read -r -d '' f; do
        _collector_should_stop && { rm -rf -- "$work_dir"; return 130; }
        seen=$((seen + 1))
        base=$(basename -- "$f")
        # tick сразу — инженер видит активность даже на долгом skip/extract
        if [[ -n "$from_epoch" || -n "$to_epoch" ]]; then
            if ! _log_should_process_for_range "$f" "${from_epoch:-0}" "${to_epoch:-9999999999}"; then
                _collect_progress_tick "skip:$base"
                continue
            fi
        fi
        _collect_progress_tick "$base"
        if _log_extract_one_file "$f" "$from_epoch" "$to_epoch" "$work_dir"; then
            processed=$((processed + 1))
            log_debug "kept: $f"
        else
            log_debug "discarded (no lines in requested range or read error): $f"
        fi
    done < <(_log_candidate_files_for_dir "$src_dir")

    if [[ "$processed" -eq 0 ]]; then
        log_debug "$src_dir: candidates=$seen kept=0 -> nothing to write to $dest_dir"
        rm -rf -- "$work_dir" 2>/dev/null
        return 1
    fi

    mkdir -p "$dest_dir" || { rm -rf -- "$work_dir"; return 1; }
    chunk_count=$(_psl_finalize_groups "$work_dir" "$dest_dir")
    rm -rf -- "$work_dir" 2>/dev/null
    log_debug "$src_dir: candidates=$seen kept=$processed -> $dest_dir (chunks=$chunk_count)"
    [[ "$chunk_count" -gt 0 ]]
}

# Считает кандидатов по всем ALL_LOG_DIRS (для % прогресса).
_log_count_all_candidates() {
    local logdir n=0 f
    for logdir in "${ALL_LOG_DIRS[@]}"; do
        while IFS= read -r -d '' f; do
            n=$((n + 1))
        done < <(_log_candidate_files_for_dir "$logdir")
    done
    echo "$n"
}

# Один файл → изолированный inbox/$idx.log (+ .group), без гонок по groups/*.
# Порядок склейки потом — по idx (как обход кандидатов).
_log_extract_one_file_to_inbox() {
    local file="$1" from_epoch="$2" to_epoch="$3" work_dir="$4" idx="$5"
    local group tmp_work out
    group=$(_psl_log_group_key "$file")
    mkdir -p "$work_dir/inbox" 2>/dev/null || return 1
    printf '%s\n' "$group" > "$work_dir/inbox/${idx}.group"
    tmp_work="$work_dir/inbox/${idx}.work"
    mkdir -p "$tmp_work/groups" 2>/dev/null || return 1
    if _log_extract_one_file "$file" "$from_epoch" "$to_epoch" "$tmp_work"; then
        out="$tmp_work/groups/${group}.log"
        if [[ -s "$out" ]]; then
            mv -- "$out" "$work_dir/inbox/${idx}.log" 2>/dev/null \
                || cp -- "$out" "$work_dir/inbox/${idx}.log" 2>/dev/null
            rm -rf -- "$tmp_work" 2>/dev/null
            return 0
        fi
    fi
    rm -rf -- "$tmp_work" 2>/dev/null
    return 1
}

# Склеить inbox/*.log в groups/<group>.log в порядке idx (числовом).
_log_merge_inbox_to_groups() {
    local work_dir="$1"
    local idx group f
    local -a idxs=()

    mkdir -p "$work_dir/groups" 2>/dev/null || return 1
    mapfile -t idxs < <(
        for f in "$work_dir"/inbox/*.group; do
            [[ -f "$f" ]] || continue
            basename -- "$f" .group
        done | sort -n
    )
    for idx in "${idxs[@]+"${idxs[@]}"}"; do
        [[ -s "$work_dir/inbox/${idx}.log" ]] || continue
        group=$(cat "$work_dir/inbox/${idx}.group" 2>/dev/null) || continue
        [[ -n "$group" ]] || continue
        cat "$work_dir/inbox/${idx}.log" >> "$work_dir/groups/${group}.log" 2>/dev/null || true
    done
}

# Воркер пула файлов: аргументы раскрываются родителем до & (без гонки $idx).
_log_file_pool_worker() {
    local file="$1" from_epoch="$2" to_epoch="$3" work_dir="$4" idx="$5" base="$6" inner_jobs="$7"
    export FLAT_FILE_POOL_WORKER=1
    export FLAT_INNER_MAX_JOBS="$inner_jobs"
    renice -n 10 $$ >/dev/null 2>&1 || true
    ionice -c 2 -n 7 -p $$ >/dev/null 2>&1 || true
    if [[ -n "$from_epoch" || -n "$to_epoch" ]]; then
        if ! _log_should_process_for_range "$file" "${from_epoch:-0}" "${to_epoch:-9999999999}"; then
            _collect_progress_tick "skip:$base"
            return 0
        fi
    fi
    _collect_progress_tick "$base"
    if _log_extract_one_file_to_inbox "$file" "$from_epoch" "$to_epoch" "$work_dir" "$idx"; then
        log_debug "kept: $file"
    else
        log_debug "discarded (no lines in requested range or read error): $file"
    fi
}

# Offline по ВСЕМ ALL_LOG_DIRS: пул воркеров по ФАЙЛАМ (не по каталогам),
# под host-wide gate CPU/MEM ≤ RESOURCE_*%. Вложенный chunk-seek при
# max_jobs≥2 приглушён (FLAT_INNER_MAX_JOBS=1), чтобы не было N×M > 80%.
# Каталоги без строк в диапазоне — "absent", как раньше.
_log_extract_all_dirs_by_range() {
    local work_root="$1" from_epoch="$2" to_epoch="$3"
    local logdir dest_name max_jobs idx=0 ctx="plain" total=0
    local work_dir f base inner_jobs chunk_count
    local -A dest_work=()
    local -a dest_order=()

    [[ -n "$from_epoch" || -n "$to_epoch" ]] && ctx="period"
    max_jobs=$(_collector_max_jobs)
    COLLECTOR_JOB_PIDS=()

    # Per-dir scratch + подсчёт кандидатов
    for logdir in "${ALL_LOG_DIRS[@]}"; do
        dest_name=$(_archive_subdir_name "$logdir")
        dest_order+=("$dest_name")
        work_dir=$(mktemp -d "${TMPDIR:-/tmp}/flat_logdir.XXXXXX") || continue
        mkdir -p "$work_dir/inbox" "$work_dir/groups" 2>/dev/null
        dest_work["$dest_name"]="$work_dir"
        while IFS= read -r -d '' f; do
            total=$((total + 1))
        done < <(_log_candidate_files_for_dir "$logdir")
    done

    _collect_progress_init "$total" || true

    # При нескольких file-воркерах — без fan-out chunk-seek внутри каждого
    if [[ "$max_jobs" -ge 2 ]]; then
        inner_jobs=1
    else
        inner_jobs=$(_collector_max_jobs)
    fi
    info "Parallel file workers: $max_jobs (host-wide CPU/MEM gate ${RESOURCE_CPU_LIMIT}%/${RESOURCE_MEM_LIMIT}%; inner chunks≤${inner_jobs})"

    for logdir in "${ALL_LOG_DIRS[@]}"; do
        dest_name=$(_archive_subdir_name "$logdir")
        work_dir="${dest_work[$dest_name]:-}"
        [[ -n "$work_dir" && -d "$work_dir" ]] || continue

        while IFS= read -r -d '' f; do
            _collector_should_stop && {
                _collector_kill_jobs
                _collect_progress_finish
                for dest_name in "${dest_order[@]+"${dest_order[@]}"}"; do
                    rm -rf -- "${dest_work[$dest_name]:-}" 2>/dev/null
                done
                return 130
            }
            if ! _collector_wait_slot "$max_jobs"; then
                _collector_kill_jobs
                _collect_progress_finish
                for dest_name in "${dest_order[@]+"${dest_order[@]}"}"; do
                    rm -rf -- "${dest_work[$dest_name]:-}" 2>/dev/null
                done
                return 130
            fi
            idx=$((idx + 1))
            base=$(basename -- "$f")
            _log_file_pool_worker "$f" "$from_epoch" "$to_epoch" "$work_dir" "$idx" "$base" "$inner_jobs" &
            COLLECTOR_JOB_PIDS+=($!)
        done < <(_log_candidate_files_for_dir "$logdir")
    done

    _collector_wait_all_jobs
    _collect_progress_finish

    for dest_name in "${dest_order[@]+"${dest_order[@]}"}"; do
        work_dir="${dest_work[$dest_name]:-}"
        if [[ -z "$work_dir" || ! -d "$work_dir" ]]; then
            info "${dest_name}: $(_log_absent_reason "$ctx")"
            continue
        fi
        _log_merge_inbox_to_groups "$work_dir"
        if compgen -G "$work_dir/groups/*.log" >/dev/null 2>&1; then
            mkdir -p "$work_root/$dest_name" 2>/dev/null || true
            chunk_count=$(_psl_finalize_groups "$work_dir" "$work_root/$dest_name")
            log_debug "$dest_name: merged inbox -> $work_root/$dest_name (chunks=${chunk_count:-0})"
            if [[ ! "$chunk_count" =~ ^[0-9]+$ ]] || [[ "$chunk_count" -eq 0 ]]; then
                info "${dest_name}: $(_log_absent_reason "$ctx")"
            fi
        else
            info "${dest_name}: $(_log_absent_reason "$ctx")"
        fi
        rm -rf -- "$work_dir" 2>/dev/null
    done
}

# Встроенный юнит-тест seek (используется расширенным selftest / --dev)
_selftest_seek_extract() {
    local dir log dest from_epoch to_epoch base n lines got sz
    dir=$(mktemp -d "${TMPDIR:-/tmp}/flat_selfseek.XXXXXX") || return 1
    log="$dir/big.log"
    dest="$dir/out.log"
    # Принудительно использовать путь seek+chunk
    SEEK_MIN_BYTES=$((100 * 1024))
    SEEK_CHUNK_BYTES=$((256 * 1024))
    SEEK_BACKOFF_BYTES=$((64 * 1024))
    base=$(date -d '2026-01-15 10:00:00' +%s 2>/dev/null) || base=1768467600
    n=40000
    # gawk strftime: быстрый синтетический отсортированный лог (~1–2MB)
    awk -v base="$base" -v n="$n" 'BEGIN {
        for (i = 0; i < n; i++)
            printf "%s line-%d\n", strftime("%Y-%m-%d %H:%M:%S", base + i), i
    }' > "$log" 2>/dev/null || {
        for (( i=0; i<n; i++ )); do
            printf '%s line-%d\n' "$(date -d "@$((base + i))" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "2026-01-15 10:00:00")" "$i"
        done > "$log"
    }
    sz=$(wc -c < "$log" | tr -d ' ')
    from_epoch=$((base + 10000))
    to_epoch=$((base + 15000))
    if ! filter_log_file_by_range "$log" "$dest" "$from_epoch" "$to_epoch"; then
        echo "SELFTEST-SEEK: FAIL filter returned false (size=$sz)" >&2
        rm -rf -- "$dir"
        return 1
    fi
    lines=$(wc -l < "$dest" | tr -d ' ')
    if [[ "$lines" -lt 4000 || "$lines" -gt 6000 ]]; then
        echo "SELFTEST-SEEK: FAIL line count=$lines (want ~5001) size=$sz" >&2
        rm -rf -- "$dir"
        return 1
    fi
    got=$(head -1 "$dest" | grep -oE 'line-[0-9]+' | head -1)
    echo "SELFTEST-SEEK: OK lines=$lines first=$got size=$sz"
    rm -rf -- "$dir"
    return 0
}


# ==========================================================================
# РАЗДЕЛ: 07_collector
# ==========================================================================
# Назначение: Процессы сборщика логов: online tail -F, обработка сигналов (INT/TERM/Enter), безопасное удаление рабочих каталогов только по шаблону архива, resource-gate воркеров сбора.
# Публичные функции: run_log_collection()-хелперы, обработчики сигналов,
#   безопасная очистка рабочего каталога, _collector_should_stop() (сознательно
#   переопределяет одноимённый стаб lib/core.sh (раздел 06_resource_gate))
# Зависит от: 06_extract_apply.sh, lib/core (resource-gate), 00_tunables.sh
# Не зависит от: 08_online_offline.sh — верхнеуровневый режим использует эти хелперы
# Side effects: запускает tail -F/tcpdump в фоне, ловит сигналы, удаляет каталоги (только по шаблону YYYY.MM.DD_HH-MM_*)
#
# Источник: перенесено без изменений логики из flat_check_2.sh (строки 6364-7141),
#   ЗА ИСКЛЮЧЕНИЕМ _collector_max_jobs/_get_mem_usage_percent/_get_cpu_usage_percent/
#   _collector_resources_ok/_collector_wait_slot/_collector_wait_all_jobs — в
#   оригинале они физически лежали внутри той же секции 9 (значит, при первом
#   переносе секции целиком удвоились бы с lib/core.sh (раздел 06_resource_gate), где эти
#   же функции уже есть байт-в-байт под тем же именем). Найдено и убрано при
#   код-ревью фазы 5 — используется версия из core (грузится раньше logging).

# --- 9. Процессы сборщика / сигналы / безопасное удаление -----------------------
# Root: удалять только рабочие директории, совпадающие с шаблоном имени ARCHIVE внутри COLLECTOR_DIR.

# Истина, если путь похож на рабочую директорию нашей сессии: <collector>/YYYY.MM.DD_HH-MM_*

_is_safe_work_dir() {
    local path="$1" base parent
    [[ -n "$path" && -d "$path" ]] || return 1
    path=$(readlink -f "$path" 2>/dev/null || echo "$path")
    base=$(basename "$path")
    parent=$(dirname "$path")
    [[ "$base" =~ ^[0-9]{4}\.[0-9]{2}\.[0-9]{2}_[0-9]{2}-[0-9]{2}_ ]] || return 1
    if [[ -n "${COLLECTOR_DIR:-}" ]]; then
        local coll
        coll=$(readlink -f "$COLLECTOR_DIR" 2>/dev/null || echo "$COLLECTOR_DIR")
        [[ "$parent" == "$coll" ]] || return 1
    fi
    # отказываем на явно опасных корневых путях
    case "$path" in
        /|/bin|/boot|/dev|/etc|/home|/lib|/lib64|/opt|/proc|/root|/run|/sbin|/srv|/sys|/tmp|/usr|/var) return 1 ;;
    esac
    return 0
}

# Удалить директорию текущей сессии только после проверок безопасности (Ctrl+C / ранний abort)
safe_rm_work_dir() {
    local path="${1:-${WORK_DIR:-}}"
    if _is_safe_work_dir "$path"; then
        rm -rf -- "$path" 2>/dev/null
    elif [[ -n "$path" ]]; then
        warn "Refusing to remove path (safety check failed): $path"
    fi
}

# TERM + короткая отсрочка + KILL для списка PID (общее для сборщика и полной очистки)
_kill_pids_gracefully() {
    local pid
    for pid in "$@"; do
        [[ -n "$pid" ]] && kill -TERM "$pid" 2>/dev/null
    done
    sleep 1
    for pid in "$@"; do
        [[ -n "$pid" ]] || continue
        if kill -0 "$pid" 2>/dev/null; then
            kill -KILL "$pid" 2>/dev/null
        fi
        wait "$pid" 2>/dev/null || true
    done
}

cleanup_background_jobs() {
    local pid
    # TERM, короткая отсрочка, затем KILL, чтобы wait не мог зависнуть на застрявшем tail/NFS
    for pid in "${TAIL_PIDS[@]+"${TAIL_PIDS[@]}"}"; do [[ -n "$pid" ]] && kill -TERM "$pid" 2>/dev/null; done
    if [[ ${#COLLECTOR_JOB_PIDS[@]} -gt 0 ]]; then
        _kill_pids_gracefully "${COLLECTOR_JOB_PIDS[@]}"
    fi
    [[ -n "${TCPDUMP_PID:-}" ]] && kill -TERM "$TCPDUMP_PID" 2>/dev/null
    [[ -n "${TIMEOUT_KILL_PID:-}" ]] && kill "$TIMEOUT_KILL_PID" 2>/dev/null
    [[ -n "${DISK_WATCH_PID:-}" ]] && kill "$DISK_WATCH_PID" 2>/dev/null
    [[ -n "${RESOURCE_WATCH_PID:-}" ]] && kill "$RESOURCE_WATCH_PID" 2>/dev/null
    sleep 1
    for pid in "${TAIL_PIDS[@]+"${TAIL_PIDS[@]}"}" \
               ${TCPDUMP_PID:+"$TCPDUMP_PID"} \
               ${TIMEOUT_KILL_PID:+"$TIMEOUT_KILL_PID"} \
               ${DISK_WATCH_PID:+"$DISK_WATCH_PID"} \
               ${RESOURCE_WATCH_PID:+"$RESOURCE_WATCH_PID"}; do
        [[ -n "$pid" ]] || continue
        if kill -0 "$pid" 2>/dev/null; then
            kill -KILL "$pid" 2>/dev/null
        fi
        wait "$pid" 2>/dev/null || true
    done
    TAIL_PIDS=()
    COLLECTOR_JOB_PIDS=()
    TCPDUMP_PID=""
    TIMEOUT_KILL_PID=""
    DISK_WATCH_PID=""
    RESOURCE_WATCH_PID=""
}

cleanup_on_abort() {
    cleanup_background_jobs
    safe_rm_work_dir
}

# TERM: аккуратная остановка (online timeout, диск-guard) — прервать чтение, затем архивировать
_on_collect_graceful_stop() {
    COLLECTOR_TIMEOUT_STOP=1
}

# INT (Ctrl+C): abort — удалить рабочую директорию, без архивации
_on_collect_abort() {
    COLLECTOR_ABORTED=1
    cleanup_on_abort
    exit 130
}

# Переопределяет стаб lib/core.sh (раздел 06_resource_gate) (там — «никогда не
# останавливаться», для health-check без lib/logging). Здесь — настоящая
# проверка: обработчики сигналов выше — единственное место, где
# COLLECTOR_ABORTED/COLLECTOR_TIMEOUT_STOP вообще выставляются, поэтому и
# реальная реализация живёт рядом с ними. lib/core грузится раньше
# lib/logging, так что эта версия замещает стаб везде, где lib/logging
# подключён (сборщик логов, мастер, самотест) — см. комментарий в
# lib/core.sh (раздел 06_resource_gate).
_collector_should_stop() {
    [[ "${COLLECTOR_ABORTED:-0}" -eq 1 || "${COLLECTOR_TIMEOUT_STOP:-0}" -eq 1 ]]
}

cleanup() {
    cleanup_background_jobs
}

trap _on_collect_abort INT
trap _on_collect_graceful_stop TERM
trap cleanup EXIT

# Процент свободного места на диске (100 - используемый%). Пусто при ошибке.
get_disk_free_percent() {
    local dir="${1:-.}"
    df -P "$dir" 2>/dev/null | awk 'NR==2 { gsub(/%/,"",$5); if ($5+0>=0) print 100-$5 }'
}

cleanup_old_work_dirs() {
    local dir="$1" keep_name="${2:-}"
    local d base
    [[ -d "$dir" ]] || return 0
    # Только внутри выходной директории сборщика; только наш шаблон имён; никогда текущий keep_name
    while IFS= read -r -d '' d; do
        base=$(basename "$d")
        [[ -n "$keep_name" && "$base" == "$keep_name" ]] && continue
        _is_safe_work_dir "$d" || continue
        rm -rf -- "$d" 2>/dev/null
    done < <(find "$dir" -maxdepth 1 -type d \
        -name '[0-9][0-9][0-9][0-9].[0-9][0-9].[0-9][0-9]_[0-9][0-9]-[0-9][0-9]_*' -print0 2>/dev/null)
}

# Уникальное имя поддиректории архива для исходной директории логов (online + offline должны совпадать)
_archive_subdir_name() {
    local path="$1" name
    path=$(readlink -f "$path" 2>/dev/null || echo "$path")
    path="${path%/}"
    if [[ "$path" == /var/log/flat ]]; then
        echo "flat"
        return 0
    fi
    if [[ "$path" == /var/log/flat/* ]]; then
        name="${path#/var/log/flat/}"
        echo "${name////_}"
        return 0
    fi
    if [[ "$path" =~ ^/opt/flat/([^/]+)/(log|logs)$ ]]; then
        echo "${BASH_REMATCH[1]}"
        return 0
    fi
    echo "${path#/}" | tr '/' '_'
}

# Фоновый монитор диска: TERM → аккуратная остановка, если свободного места < 2%
start_disk_watch() {
    local watch_dir="$1"
    (
        while true; do
            local free
            free=$(get_disk_free_percent "$watch_dir")
            if [[ -n "$free" && "$free" -lt 2 ]]; then
                kill -TERM $$ 2>/dev/null
                break
            fi
            sleep 10
        done
    ) &
    DISK_WATCH_PID=$!
}

# Фоновый монитор ресурсов хоста: раз в RESOURCE_LOG_INTERVAL_SEC пишет снимок
# CPU/MEM только в файл лога сессии (log_debug — не на экран), чтобы после
# долгого online/offline сбора можно было посмотреть, была ли машина
# нагружена. Останавливается вместе с остальными фоновыми задачами в
# cleanup_background_jobs().
start_resource_monitor() {
    (
        # Первый вызов _get_cpu_usage_percent только инициализирует дельту (вернёт 0)
        _get_cpu_usage_percent >/dev/null
        while true; do
            sleep "${RESOURCE_LOG_INTERVAL_SEC:-30}"
            log_debug "resources: CPU=$(_get_cpu_usage_percent)% MEM=$(_get_mem_usage_percent)%"
        done
    ) &
    RESOURCE_WATCH_PID=$!
}

# Уникальный путь назначения: разворачиваем относительный путь в одну строку, чтобы параллельные файлы с одинаковым basename не конфликтовали
_unique_dest_path() {
    local src_file="$1" dest_dir="$2" src_dir="${3:-}"
    local rel base dest_path n=0
    if [[ -n "$src_dir" ]]; then
        rel="${src_file#"$src_dir"/}"
        rel="${rel#/}"
        [[ -z "$rel" || "$rel" == "$src_file" ]] && rel=$(basename "$src_file")
    else
        rel=$(basename "$src_file")
    fi
    base="${rel////_}"
    dest_path="$dest_dir/$base"
    while [[ -e "$dest_path" ]]; do
        n=$((n + 1))
        dest_path="$dest_dir/${base}.$$.$RANDOM.$n"
        [[ "$n" -gt 50 ]] && break
    done
    echo "$dest_path"
}

_start_tail_one_file() {
    local src_file="$1" dest_dir="$2" display_label="$3" src_dir="${4:-}"
    local dest_path pid
    dest_path=$(_unique_dest_path "$src_file" "$dest_dir" "$src_dir")
    mkdir -p "$dest_dir" || return 1
    # Понижаем приоритет; держим nice/ionice в той же &-строке, чтобы $! указывал на цепочку tail
    if command -v nice >/dev/null 2>&1 && command -v ionice >/dev/null 2>&1; then
        nice -n 10 ionice -c3 tail -F -n 0 "$src_file" > "$dest_path" 2>/dev/null &
    elif command -v nice >/dev/null 2>&1; then
        nice -n 10 tail -F -n 0 "$src_file" > "$dest_path" 2>/dev/null &
    else
        tail -F -n 0 "$src_file" > "$dest_path" 2>/dev/null &
    fi
    pid=$!
    if kill -0 "$pid" 2>/dev/null; then
        TAIL_PIDS+=("$pid")
        ok "Monitoring ${display_label}: $(basename "$src_file") PID=$pid"
        return 0
    fi
    warn "Failed to start tail for ${display_label}: $(basename "$src_file")"
    return 1
}

start_tail_for_file() {
    local src_file="$1" dest_dir="$2"
    local display_label="${3:-$(basename "$src_file")}"
    _start_tail_one_file "$src_file" "$dest_dir" "$display_label"
}

prune_empty_collected_files() {
    local root="$1"
    [[ -d "$root" ]] || return 0
    find "$root" -type f -empty ! -path '*/configs/*' ! -name '*.pcap' -delete 2>/dev/null
    find "$root" -type d -empty -delete 2>/dev/null
}

_count_collected_log_stats() {
    local root="$1" count=0 bytes=0 f sz
    while IFS= read -r -d '' f; do
        sz=$(stat -c '%s' "$f" 2>/dev/null || echo 0)
        count=$((count + 1))
        bytes=$(( bytes + sz ))
    done < <(find "$root" -type f ! -path '*/configs/*' ! -name '*.pcap' -size +0c -print0 2>/dev/null)
    echo "$count $bytes"
}

report_collected_log_stats() {
    local root="$1" mode="$2" count=0 bytes=0 kb=0
    read -r count bytes < <(_count_collected_log_stats "$root")
    kb=$(( (bytes + 1023) / 1024 ))
    if [[ "$count" -gt 0 ]]; then
        info "$(_l log_archive_stats) $count ($kb KB)"
    elif [[ "$mode" == "online" ]]; then
        info "$(_l log_online_no_new)"
    fi
}

start_tail_for_dir() {
    local src_dir="$1" dest_dir="$2"
    local find_fn="_log_candidate_files_for_dir"
    local display_label="${4:-$(basename "$src_dir")}"
    [[ "${3:-}" == "pg" ]] && find_fn="find_pg_log_files_in_dir"
    local files=() f started=0
    while IFS= read -r -d '' f; do files+=("$f"); done < <($find_fn "$src_dir")
    if [[ ${#files[@]} -eq 0 ]]; then
        local ctx
        ctx=$(_logs_time_context "${LOG_SUBMODE:-online}")
        info "${display_label}: $(_log_absent_reason "$ctx")"
        return 0
    fi
    mkdir -p "$dest_dir" || return 1
    for f in "${files[@]}"; do
        if _start_tail_one_file "$f" "$dest_dir" "$display_label" "$src_dir"; then
            started=$((started + 1))
            log_debug "tailing: $f"
        else
            log_debug "discarded (failed to start tail): $f"
        fi
    done
    log_debug "$src_dir: candidates=${#files[@]} tailing=$started"
    [[ "$started" -eq 0 ]] && warn "Failed to start tail for ${display_label} ($src_dir)"
}

# _collector_max_jobs() и остальной resource-gate (_get_mem_usage_percent,
# _get_cpu_usage_percent, _collector_resources_ok, _collector_wait_slot,
# _collector_wait_all_jobs) НЕ дублируются здесь — это lib/core.sh (раздел 06_resource_gate),
# которая грузится раньше lib/logging и используется как есть (найдено и
# убрано дублирование при код-ревью фазы 5: в исходном flat_check_2.sh эти
# функции физически лежали внутри той же секции "9. Процессы сборщика", что
# и остальной этот файл, и при переносе секции целиком попали сюда повторно).

# Вложенный пул (chunk-seek внутри file-worker): не размножать сверх host-gate.
# FLAT_INNER_MAX_JOBS задаёт родитель (file-pool); иначе — половина outer max.
_collector_inner_max_jobs() {
    local n
    if [[ "${FLAT_INNER_MAX_JOBS:-}" =~ ^[1-9][0-9]*$ ]]; then
        echo "$FLAT_INNER_MAX_JOBS"
        return 0
    fi
    n=$(_collector_max_jobs)
    [[ "$n" -gt 4 ]] && n=$(( (n + 1) / 2 ))
    [[ "$n" -lt 1 ]] && n=1
    echo "$n"
}

_collector_kill_jobs() {
    [[ ${#COLLECTOR_JOB_PIDS[@]} -eq 0 ]] && return 0
    _kill_pids_gracefully "${COLLECTOR_JOB_PIDS[@]}"
    COLLECTOR_JOB_PIDS=()
}

# Обработать результаты задач копирования; массивы job_labels[job_idx]=source_label
_process_copy_job_results() {
    local result_dir="$1" use_content_filter="$2"
    local -n pjob_labels=$3
    local -A lbl_copied=() lbl_skipped=() lbl_warns=()
    local -a lbl_order=()
    local rf job_idx kind a b c source_label copied=0
    local skipped_no_range_files=() skipped_warn_entries=()
    local reason_entry dest_dir

    for rf in "$result_dir"/*; do
        [[ -f "$rf" ]] || continue
        job_idx=$(basename "$rf")
        source_label="${pjob_labels[$job_idx]:-}"
        if [[ -n "$source_label" ]]; then
            if [[ ",${lbl_order[*]}," != *",$source_label,"* ]]; then
                lbl_order+=("$source_label")
            fi
        fi
        IFS='|' read -r kind a b c < "$rf" || continue
        case "$kind" in
            OK)
                copied=$((copied + 1))
                lbl_copied["$source_label"]=$((${lbl_copied[$source_label]:-0} + 1))
                ok "$(_l collected) $a lines from $b ($source_label)"
                ;;
            OK_GREP)
                copied=$((copied + 1))
                lbl_copied["$source_label"]=$((${lbl_copied[$source_label]:-0} + 1))
                ok "$(_l collected) $a lines (grep) from $b ($source_label)"
                ;;
            OK_CP)
                copied=$((copied + 1))
                lbl_copied["$source_label"]=$((${lbl_copied[$source_label]:-0} + 1))
                ;;
            SKIP)
                skipped_no_range_files+=("$source_label|$a")
                ;;
            WARN)
                skipped_warn_entries+=("$source_label|$a: $b")
                ;;
        esac
    done

    local lbl entry base files_for_lbl=() seen=""
    for lbl in "${lbl_order[@]}"; do
        [[ -z "$lbl" ]] && continue
        files_for_lbl=()
        for entry in "${skipped_no_range_files[@]}"; do
            [[ "$entry" == "$lbl|"* ]] || continue
            base="${entry#"$lbl"|}"
            files_for_lbl+=("$base")
        done
        if [[ ${#files_for_lbl[@]} -gt 0 ]]; then
            _log_absent_info "$lbl" "period" "${files_for_lbl[@]}"
        fi
        local warn_for_lbl=()
        for entry in "${skipped_warn_entries[@]}"; do
            [[ "$entry" == "$lbl|"* ]] && warn_for_lbl+=("${entry#"$lbl"|}")
        done
        if [[ ${#warn_for_lbl[@]} -gt 0 ]]; then
            warn "$(_l skipped) ${#warn_for_lbl[@]} $(_l log_files_from) $lbl"
            for reason_entry in "${warn_for_lbl[@]}"; do
                warn "  → $reason_entry"
            done
        fi
        if [[ ${lbl_copied[$lbl]:-0} -gt 0 && "$use_content_filter" -eq 0 ]]; then
            ok "$(_l collected) ${lbl_copied[$lbl]} $(_l log_files_from) $lbl"
        fi
    done
    echo "$copied"
}

# Общий пул задач над заранее собранным списком файлов (один пул — без вложенных воркеров).
# Nameref'ы ДОЛЖНЫ использовать уникальные локальные имена: вызывающий код часто передаёт массивы с именами вроде cp_files и т.п.
_copy_log_files_parallel() {
    local from_time="${1:-}" to_time="${2:-}"
    local -n _ref_files=$3
    local -n _ref_src=$4
    local -n _ref_dest=$5
    local -n _ref_label=$6
    local -a _empty_labels=("${@:7}")

    local n=${#_ref_files[@]} max_jobs result_dir job_idx=0 rf f i
    local from_epoch="" to_epoch="" use_content_filter=0 copied

    if [[ "$n" -eq 0 ]]; then
        local lbl ctx
        for lbl in "${_empty_labels[@]}"; do
            [[ -z "$lbl" ]] && continue
            ctx=$(_logs_time_context "offline" "$from_time" "$to_time")
            info "${lbl}: $(_log_absent_reason "$ctx")"
        done
        return 0
    fi

    if [[ -n "$from_time" || -n "$to_time" ]]; then
        use_content_filter=1
        [[ -z "$to_time" ]] && to_time=$(date "+%Y-%m-%d %H:%M:%S")
        [[ -z "$from_time" ]] && from_time="1970-01-01 00:00:00"
        from_epoch=$(time_to_epoch "$from_time")
        to_epoch=$(time_to_epoch "$to_time")
        [[ -z "$from_epoch" || -z "$to_epoch" ]] && use_content_filter=0
    fi

    max_jobs=$(_collector_max_jobs)
    [[ "$max_jobs" -gt "$n" ]] && max_jobs="$n"
    result_dir=$(mktemp -d "${TMPDIR:-/tmp}/flat_copy.XXXXXX") || return 1
    declare -A _copy_job_labels=()

    for (( i=0; i<n; i++ )); do
        f="${_ref_files[$i]}"
        mkdir -p "${_ref_dest[$i]}" || continue
        if _collector_should_stop; then
            _collector_kill_jobs
            rm -rf -- "$result_dir" 2>/dev/null
            return 130
        fi
        if ! _collector_wait_slot "$max_jobs"; then
            _collector_kill_jobs
            rm -rf -- "$result_dir" 2>/dev/null
            return 130
        fi
        job_idx=$((job_idx + 1))
        _copy_job_labels["$job_idx"]="${_ref_label[$i]}"
        rf="$result_dir/$job_idx"
        (
            renice -n 10 $$ >/dev/null 2>&1 || true
            ionice -c 2 -n 7 -p $$ >/dev/null 2>&1 || true
            _copy_one_existing_log "$f" "${_ref_src[$i]}" "${_ref_dest[$i]}" \
                "$use_content_filter" "$from_epoch" "$to_epoch" \
                "$from_time" "$to_time" "$rf"
        ) &
        COLLECTOR_JOB_PIDS+=($!)
    done

    _collector_wait_all_jobs

    if _collector_should_stop; then
        rm -rf -- "$result_dir" 2>/dev/null
        return 130
    fi

    copied=$(_process_copy_job_results "$result_dir" "$use_content_filter" _copy_job_labels)
    rm -rf -- "$result_dir" 2>/dev/null
    return 0
}

# Скопировать/отфильтровать один лог-файл; записать строку статуса в result_file
# Статус: OK|<lines>|<base> | OK_GREP|<lines>|<base> | OK_CP|<base> | SKIP|<base> | WARN|<base>|<reason>
_copy_one_existing_log() {
    local f="$1" src_dir="$2" dest_dir="$3"
    local use_content_filter="$4" from_epoch="$5" to_epoch="$6"
    local from_time="$7" to_time="$8" result_file="$9"

    local base dest_path lines rel err_msg reason

    dest_path=$(_unique_dest_path "$f" "$dest_dir" "$src_dir")
    rel="${f#"$src_dir"/}"
    rel="${rel#/}"
    [[ -z "$rel" || "$rel" == "$f" ]] && rel=$(basename "$f")
    base="${rel////_}"

    if [[ "$use_content_filter" -eq 1 ]]; then
        if filter_log_file_by_range "$f" "$dest_path" "$from_epoch" "$to_epoch"; then
            lines=$(wc -l < "$dest_path" 2>/dev/null || echo 0)
            printf 'OK|%s|%s\n' "$lines" "$base" > "$result_file"
        elif filter_log_file_by_range_grep "$f" "$dest_path" "$from_time" "$to_time"; then
            lines=$(wc -l < "$dest_path" 2>/dev/null || echo 0)
            printf 'OK_GREP|%s|%s\n' "$lines" "$base" > "$result_file"
        else
            rm -f "$dest_path" 2>/dev/null
            printf 'SKIP|%s\n' "$base" > "$result_file"
        fi
    else
        err_msg=$(cp -p "$f" "$dest_path" 2>&1)
        if [[ $? -eq 0 ]]; then
            printf 'OK_CP|%s\n' "$base" > "$result_file"
        else
            if [[ "$err_msg" == *"Permission denied"* ]]; then
                reason="Permission denied (try sudo)"
            elif [[ "$err_msg" == *"No space left"* ]]; then
                reason="No space left on device"
            else
                reason="${err_msg:-unknown error}"
            fi
            printf 'WARN|%s|%s\n' "$base" "$reason" > "$result_file"
        fi
    fi
}

copy_existing_logs() {
    local src_dir="$1" dest_dir="$2"
    local from_time="${3:-}"
    local to_time="${4:-}"
    local log_kind="${5:-}"
    local source_label="${6:-$(basename "$src_dir")}"
    local find_fn="find_log_files_in_dir"
    [[ "$log_kind" == "pg" ]] && find_fn="find_pg_log_files_in_dir"
    local -a cp_files=() cp_src=() cp_dest=() cp_label=()
    local f rc

    while IFS= read -r -d '' f; do
        cp_files+=("$f")
        cp_src+=("$src_dir")
        cp_dest+=("$dest_dir")
        cp_label+=("$source_label")
    done < <($find_fn "$src_dir")

    if [[ ${#cp_files[@]} -eq 0 ]]; then
        _copy_log_files_parallel "$from_time" "$to_time" cp_files cp_src cp_dest cp_label "$source_label"
        return 0
    fi

    mkdir -p "$dest_dir" || return 1
    _copy_log_files_parallel "$from_time" "$to_time" cp_files cp_src cp_dest cp_label
    rc=$?
    [[ $rc -eq 130 ]] && return 130
    if [[ -d "$dest_dir" ]] && [[ -z "$(find "$dest_dir" -mindepth 1 -print -quit 2>/dev/null)" ]]; then
        rmdir "$dest_dir" 2>/dev/null
    fi
}

copy_system_log_by_range() {
    local sysfile="$1" sysdest="$2"
    local from_time="${3:-}" to_time="${4:-}"
    local source_label="${5:-}"
    local base dest_path from_epoch to_epoch

    [[ -f "$sysfile" ]] || return 0
    base=$(basename "$sysfile")
    mkdir -p "$sysdest" || return 1
    dest_path="$sysdest/$base"
    [[ -z "$source_label" ]] && source_label="system"

    if [[ -n "$from_time" || -n "$to_time" ]]; then
        [[ -z "$to_time" ]] && to_time=$(date "+%Y-%m-%d %H:%M:%S")
        [[ -z "$from_time" ]] && from_time="1970-01-01 00:00:00"
        from_epoch=$(time_to_epoch "$from_time")
        to_epoch=$(time_to_epoch "$to_time")
        if filter_log_file_by_range "$sysfile" "$dest_path" "$from_epoch" "$to_epoch"; then
            ok "${source_label}: $(_l sys_copied) $base ($(wc -l < "$dest_path" 2>/dev/null || echo 0) lines)"
        elif filter_log_file_by_range_grep "$sysfile" "$dest_path" "$from_time" "$to_time"; then
            ok "${source_label}: $(_l sys_copied) $base (grep, $(wc -l < "$dest_path" 2>/dev/null || echo 0) lines)"
        else
            rm -f "$dest_path" 2>/dev/null
            info "${source_label}: $base — $(_log_absent_reason period)"
        fi
    else
        cp -p "$sysfile" "$dest_path" 2>/dev/null && ok "${source_label}: $(_l sys_copied) $base"
    fi
}

_copy_one_config() {
    local src="$1" dest="$2" result_file="$3"
    mkdir -p "$(dirname "$dest")" 2>/dev/null || true
    if cp -p "$src" "$dest" 2>/dev/null; then
        printf 'OK\n' > "$result_file"
    else
        printf 'FAIL\n' > "$result_file"
    fi
}

collect_configs() {
    local dest="$1"
    local -a cfg_src=() cfg_dest=()
    local conf f rel subdir collected=() dup existing
    local max_jobs result_dir job_idx=0 rf count=0

    for conf in "${CONFIG_PATHS[@]}"; do
        if [[ -f "$conf" ]]; then
            subdir=$(dirname "$conf" | sed 's|^/||;s|/|_|g')
            cfg_src+=("$conf")
            cfg_dest+=("$dest/configs/$subdir/$(basename "$conf")")
        fi
    done
    if [[ -d "/opt/flat" ]]; then
        collected=()
        while IFS= read -r -d '' f; do
            collected+=("$f")
        done < <(find "/opt/flat" -maxdepth 5 \( -name node_modules -o -name .git -o -name vendor -o -name dist -o -name build -o -name .pnpm -o -name .cache \) -prune -o \
            -type f -path '*/config/*' \
            \( -name '*.ini' -o -name '*.xml' -o -name '*.yml' -o -name '*.yaml' -o -name '*.conf' -o -name '*.json' -o -name '*.properties' -o -name '*.cfg' \) \
            -print0 2>/dev/null)
        while IFS= read -r -d '' f; do
            dup=0
            for existing in "${collected[@]}"; do [[ "$existing" == "$f" ]] && dup=1 && break; done
            [[ "$dup" -eq 0 ]] && collected+=("$f")
        done < <(find "/opt/flat" -maxdepth 5 \( -name node_modules -o -name .git -o -name vendor -o -name dist -o -name build -o -name .pnpm -o -name .cache \) -prune -o \
            -type f \( -iname '*config*' -o -iname '*version*' -o -iname '*settings*' \) \
            \( -name '*.ini' -o -name '*.xml' -o -name '*.yml' -o -name '*.yaml' -o -name '*.conf' -o -name '*.json' -o -name '*.properties' -o -name '*.cfg' \) \
            -print0 2>/dev/null)
        for f in "${collected[@]}"; do
            rel=$(echo "$f" | sed 's|^/opt/flat/||;s|/|_|g')
            cfg_src+=("$f")
            cfg_dest+=("$dest/configs/${rel}")
        done
    fi

    [[ ${#cfg_src[@]} -eq 0 ]] && return 0

    max_jobs=$(_collector_max_jobs)
    [[ "$max_jobs" -gt ${#cfg_src[@]} ]] && max_jobs=${#cfg_src[@]}
    result_dir=$(mktemp -d "${TMPDIR:-/tmp}/flat_cfg.XXXXXX" 2>/dev/null) || return 0
    _get_cpu_usage_percent >/dev/null

    for (( i=0; i<${#cfg_src[@]}; i++ )); do
        if ! _collector_wait_slot "$max_jobs"; then
            break
        fi
        job_idx=$((job_idx + 1))
        rf="$result_dir/$job_idx"
        (
            renice -n 10 $$ >/dev/null 2>&1 || true
            _copy_one_config "${cfg_src[$i]}" "${cfg_dest[$i]}" "$rf"
        ) &
        COLLECTOR_JOB_PIDS+=($!)
    done
    _collector_wait_all_jobs

    for rf in "$result_dir"/*; do
        [[ -f "$rf" ]] || continue
        [[ "$(cat "$rf" 2>/dev/null)" == OK ]] && count=$((count + 1))
    done
    rm -rf -- "$result_dir" 2>/dev/null
    [[ "$count" -gt 0 ]] && info "$(_l config_collected): $count"
}


# ==========================================================================
# РАЗДЕЛ: 08_online_offline
# ==========================================================================
# Назначение: Верхнеуровневые режимы -log -on/-off: online = tail -F + опциональный tcpdump до Enter/TERM; offline = параллельное копирование/извлечение по диапазону, упаковка в .tar.gz.
# Публичные функции: run_log_collection(submode, timeout_raw), relocate_log_to_workdir()
# Зависит от: все остальные lib/logging/*.sh, lib/core (resource-gate, _log_line)
# Не зависит от: lib/agent — сборщик логов не знает про JSON/push
# Side effects: создаёт архив YYYY.MM.DD_HH-MM_<hostname>.tar.gz, пишет во временный рабочий каталог
#
# Источник: run_log_collection() — перенесено без изменений логики из
#   flat_check_2.sh (строки 7142-7433). relocate_log_to_workdir() — найдена
#   отдельно при сверке offline-сбора модульной сборки с оригиналом (строка
#   467, физически лежала в section 2 "Хелперы вывода", т.к. это единственное
#   место в flat_check_2.sh, где output-хелперы обзавелись логикой,
#   специфичной для сборщика логов; flat_check.sh, взятый за основу
#   lib/core.sh (раздел 02_output) в фазе 1, этой функции не содержит вовсе — health-only
#   скрипт не имеет рабочего каталога архива). Единственный вызов —
#   run_log_collection() ниже, поэтому функция перенесена сюда, а не в core.

# relocate_log_to_workdir(): после того как WORK_DIR создан, переносит уже
# открытый сессионный лог (LOG_FILE) внутрь него — чтобы session-лог тоже
# попал в итоговый .tar.gz архива, а не остался рядом со скриптом.

relocate_log_to_workdir() {
    local old_log="${LOG_FILE:-}"
    local new_log="${WORK_DIR%/}/${SCRIPT_NAME}.log"
    if [[ -n "$old_log" && -f "$old_log" && "$old_log" != "$new_log" ]]; then
        if ! mv -- "$old_log" "$new_log" 2>/dev/null; then
            cp -- "$old_log" "$new_log" 2>/dev/null && rm -f -- "$old_log" 2>/dev/null
        fi
    fi
    LOG_FILE="$new_log"
    { : >> "$LOG_FILE"; } 2>/dev/null || LOG_FILE=""
}

# --- 10. Online / offline сбор --------------------------------------------------
# Разрешить OUTPUT_DIR в COLLECTOR_DIR/WORK_DIR/ARCHIVE_NAME. Они осознанно
# остаются простыми глобальными переменными — start_disk_watch/cleanup/обработчики
# сигналов читают $WORK_DIR напрямую, как и до этого разделения. Сначала удаляет
# устаревшие рабочие директории (никогда не трогает ту, которую мы собираемся создать).
_prepare_collection_workdir() {
    local mode="$1"

    COLLECTOR_DIR="${OUTPUT_DIR:-$SCRIPT_DIR}"
    if [[ ! -d "$COLLECTOR_DIR" ]]; then
        mkdir -p "$COLLECTOR_DIR" 2>/dev/null || die "$(_l err_perm): $COLLECTOR_DIR"
    fi
    [[ -w "$COLLECTOR_DIR" ]] || die "$(_l err_perm): $COLLECTOR_DIR"

    ARCHIVE_NAME="$(date '+%Y.%m.%d_%H-%M_')$(hostname)"
    # Удаляем устаревшие директории ДО создания текущей рабочей директории (никогда не удаляем ARCHIVE_NAME)
    cleanup_old_work_dirs "$COLLECTOR_DIR" "$ARCHIVE_NAME"
    WORK_DIR="$COLLECTOR_DIR/$ARCHIVE_NAME"
    mkdir -p "$WORK_DIR" || die "Cannot create work dir: $WORK_DIR"
    # Переносим сюда всё, что уже успело залогироваться (argv, выбор мастера) —
    # ${SCRIPT_NAME}.log должен целиком оказаться в архиве вместе с логами
    relocate_log_to_workdir

    info "$(_l mode_log): $mode / scope=$LOG_SCOPE (flat_check_2 v${SCRIPT_VERSION})"
    info "$(_l workdir): $WORK_DIR"
}

# Разрешить SELECTED_PKGS и глобальный массив ALL_LOG_DIRS. Возвращает 1 (предварительно
# удалив только что созданный WORK_DIR), если собирать нечего.
_resolve_collection_targets() {
    local mode="$1" logdir

    detect_os
    command -v tail &>/dev/null || die "$(_l err_cmd_notfound): tail"
    command -v awk &>/dev/null || die "$(_l err_cmd_notfound): awk"
    command -v date &>/dev/null || die "$(_l err_cmd_notfound): date"

    resolve_selected_packages
    if [[ "${MGCPCLIENT_RESOLVED:-0}" -eq 1 ]]; then
        _resolve_mgcpclient_option 1
    else
        _resolve_mgcpclient_option
    fi
    info "$(_l found_svcs): ${#SELECTED_PKGS[@]} (selected)"
    if [[ ${#SELECTED_PKGS[@]} -gt 0 ]]; then
        local _sp
        for _sp in "${SELECTED_PKGS[@]}"; do
            info "  → ${_sp} [${PKG_PRODUCT[$_sp]:-?}]"
        done
    fi
    if [[ "$mode" == "offline" ]]; then
        info "$(_l resource_limits): host CPU<${RESOURCE_CPU_LIMIT}% MEM<${RESOURCE_MEM_LIMIT}% (workers≤$(_collector_max_jobs); throttle extras when busy, never hang)"
    fi

    # Вызывать в текущем shell (не через $(...)/process substitution): иначе
    # LOG_DIR_OWNER, заполняемый для фильтра типов логов, потеряется в subshell.
    discover_log_dirs_for_selected >/dev/null
    ALL_LOG_DIRS=("${DISCOVERED_LOG_DIRS[@]+"${DISCOVERED_LOG_DIRS[@]}"}")
    if [[ ${#ALL_LOG_DIRS[@]} -eq 0 ]]; then
        warn "$(_l err_no_logdirs)"
        safe_rm_work_dir "$WORK_DIR"
        return 1
    fi
    info "$(_l found_logdirs): ${#ALL_LOG_DIRS[@]}"
    for logdir in "${ALL_LOG_DIRS[@]}"; do
        info "  → $logdir"
    done
}

# Online: запустить tail -F на каждой директории из глобального ALL_LOG_DIRS (+ инфра-
# логи при collect_infra=1), опционально tcpdump, затем блокироваться до
# остановки/timeout. Возвращает 1 (предварительно удалив WORK_DIR), если tail
# так ни на чём и не запустился.
_run_online_collection() {
    local timeout_raw="$1" timeout_sec="$2" collect_infra="$3"
    local logdir dest_name sysfile

    # Неинтерактивный online без -t завершился бы сразу после запуска tail'ов
    if [[ ! -t 0 && "$timeout_sec" -le 0 ]]; then
        safe_rm_work_dir "$WORK_DIR"
        die "$(_l err_online_need_t)"
    fi

    # Диск-guard перед запуском tail'ов (проверка сразу внутри start_disk_watch)
    start_disk_watch "$WORK_DIR"
    start_resource_monitor
    _get_cpu_usage_percent >/dev/null   # первый вызов лишь инициализирует дельту /proc/stat
    log_debug "resources at start: CPU=$(_get_cpu_usage_percent)% MEM=$(_get_mem_usage_percent)%"
    info "Online: host-wide CPU/MEM gate ${RESOURCE_CPU_LIMIT}%/${RESOURCE_MEM_LIMIT}% (tails I/O-bound; archive/post uses same worker pool)"

    for logdir in "${ALL_LOG_DIRS[@]}"; do
        dest_name=$(_archive_subdir_name "$logdir")
        start_tail_for_dir "$logdir" "$WORK_DIR/$dest_name" "" "$dest_name"
    done
    if [[ "$collect_infra" -eq 1 ]]; then
        for sysfile in /var/log/messages /var/log/syslog; do
            [[ -f "$sysfile" ]] && start_tail_for_file "$sysfile" "$WORK_DIR/system" "system"
        done

        # Логи Nginx для FLAT — собираем, если nginx присутствует (online только обычные логи)
        if command -v nginx &>/dev/null || [[ -d "/etc/nginx" ]] || [[ -d "/var/log/nginx" ]]; then
            local ngx_dir="/var/log/nginx"
            if [[ -d "$ngx_dir" ]]; then
                while IFS= read -r -d '' ngx_file; do
                    start_tail_for_file "$ngx_file" "$WORK_DIR/nginx" "nginx"
                done < <(find -L "$ngx_dir" -maxdepth 1 -type f \( -name '*flat*.log' -o -name '*access*.log' -o -name '*error*.log' \) ! -name '*.gz' -print0 2>/dev/null)
            fi
        fi

        collect_postgresql_logs "$WORK_DIR" "online"
    fi

    if [[ ${#TAIL_PIDS[@]} -eq 0 ]]; then
        warn "$(_l err_no_logfiles)"
        safe_rm_work_dir "$WORK_DIR"
        return 1
    fi
    ok "$(_l tail_running): ${#TAIL_PIDS[@]}"

    if [[ "$collect_infra" -eq 1 && "$START_TCPDUMP" -eq 1 ]]; then
        if command -v tcpdump &>/dev/null; then
            nohup tcpdump -i any -s 0 -w "$WORK_DIR/tcpdump_$(hostname).pcap" >/dev/null 2>&1 &
            TCPDUMP_PID=$!; sleep 1
            if kill -0 "$TCPDUMP_PID" 2>/dev/null; then ok "$(_l tcpdump_started) $TCPDUMP_PID)"
            else warn "$(_l tcpdump_fail)"; TCPDUMP_PID=""; fi
        else warn "$(_l tcpdump_notfound)"; fi
    fi

    echo ""
    info "$(_l log_running)"
    info "$(_l log_running_online_note)"
    [[ "$timeout_sec" -gt 0 ]] && info "$(_l log_autostop) ${timeout_raw} (${timeout_sec}s)"
    if [[ "$timeout_sec" -gt 0 ]]; then
        ( sleep "$timeout_sec"; kill -TERM $$ 2>/dev/null ) &
        TIMEOUT_KILL_PID=$!
    fi
    _online_wait_for_stop
    [[ -n "${TIMEOUT_KILL_PID:-}" ]] && kill "$TIMEOUT_KILL_PID" 2>/dev/null && wait "$TIMEOUT_KILL_PID" 2>/dev/null
    TIMEOUT_KILL_PID=""
    echo ""
    if [[ "${COLLECTOR_TIMEOUT_STOP:-0}" -eq 1 ]]; then
        info "$(_l log_autostop) ${timeout_raw} (${timeout_sec}s)"
        COLLECTOR_TIMEOUT_STOP=0
    fi
    log_debug "resources at stop: CPU=$(_get_cpu_usage_percent)% MEM=$(_get_mem_usage_percent)%"
    info "$(_l log_stopping)"
    cleanup
}

# Offline: по каждой директории из глобального ALL_LOG_DIRS через parce_service_log(s)
# извлечь в опциональном диапазоне времени from/to (+ инфра-логи при collect_infra=1).
_run_offline_collection() {
    local timeout_raw="$1" collect_infra="$2"
    local from_time="" to_time="" sysfile

    # Offline: диск-guard (аккуратная остановка + архивация, как и в online)
    start_disk_watch "$WORK_DIR"
    start_resource_monitor
    _get_cpu_usage_percent >/dev/null   # первый вызов лишь инициализирует дельту /proc/stat
    log_debug "resources at start: CPU=$(_get_cpu_usage_percent)% MEM=$(_get_mem_usage_percent)%"

    # Разбор from/to для offline-сбора по диапазону (см. _offline_resolve_time_bounds)
    local bounds_out bounds_rc=0
    bounds_out=$(_offline_resolve_time_bounds "$FROM_TIME" "$TO_TIME" "$timeout_raw") || bounds_rc=$?
    if [[ "$bounds_rc" -eq 2 ]]; then
        die "Invalid time range: from is after to (from='${FROM_TIME:-}' to='${TO_TIME:-}'). Swap -f/--from and -e/--to (or -t as end)."
    elif [[ "$bounds_rc" -ne 0 ]]; then
        die "Invalid --from/--to: from='${FROM_TIME:-}' to='${TO_TIME:-}'"
    fi
    from_time=$(printf '%s\n' "$bounds_out" | sed -n '1p')
    to_time=$(printf '%s\n' "$bounds_out" | sed -n '2p')

    if [[ -n "$from_time" && -n "$to_time" ]]; then
        info "Extracting log lines from $from_time to $to_time (by content timestamp)"
    else
        info "$(_l log_all)"
    fi
    local range_from_epoch="" range_to_epoch=""
    [[ -n "$from_time" ]] && range_from_epoch=$(time_to_epoch "$from_time")
    [[ -n "$to_time" ]] && range_to_epoch=$(time_to_epoch "$to_time")
    # Пул по файлам + host-gate — см. _log_extract_all_dirs_by_range
    _log_extract_all_dirs_by_range "$WORK_DIR" "$range_from_epoch" "$range_to_epoch"
    if [[ "$collect_infra" -eq 1 ]]; then
        for sysfile in /var/log/messages /var/log/syslog; do
            _collector_should_stop && break
            copy_system_log_by_range "$sysfile" "$WORK_DIR/system" "$from_time" "$to_time" "system"
        done

        # Логи Nginx для FLAT — собираем, если nginx присутствует
        if command -v nginx &>/dev/null || [[ -d "/etc/nginx" ]] || [[ -d "/var/log/nginx" ]]; then
            local ngx_dir="/var/log/nginx"
            if [[ -d "$ngx_dir" ]]; then
                local ngx_dest="$WORK_DIR/nginx"
                while IFS= read -r -d '' ngx_file; do
                    _collector_should_stop && break
                    if [[ -n "$from_time" || -n "$to_time" ]]; then
                        copy_system_log_by_range "$ngx_file" "$ngx_dest" "$from_time" "$to_time" "nginx"
                    else
                        mkdir -p "$ngx_dest"
                        cp -p "$ngx_file" "$ngx_dest/$(basename "$ngx_file")" 2>/dev/null && ok "nginx: $(_l sys_copied) $(basename "$ngx_file")"
                    fi
                done < <(find -L "$ngx_dir" -maxdepth 1 -type f \( -name '*flat*.log' -o -name '*access*.log' -o -name '*error*.log' \) -print0 2>/dev/null)
                rmdir "$ngx_dest" 2>/dev/null
            fi
        fi

        if ! _collector_should_stop; then
            collect_postgresql_logs "$WORK_DIR" "offline" "$from_time" "$to_time"
        fi
    fi

    if [[ "${COLLECTOR_TIMEOUT_STOP:-0}" -eq 1 ]]; then
        info "$(_l log_autostop) disk/timeout"
        COLLECTOR_TIMEOUT_STOP=0
    fi
    log_debug "resources at stop: CPU=$(_get_cpu_usage_percent)% MEM=$(_get_mem_usage_percent)%"
    [[ -n "${RESOURCE_WATCH_PID:-}" ]] && kill "$RESOURCE_WATCH_PID" 2>/dev/null
    RESOURCE_WATCH_PID=""
    ok "$(_l log_copydone)"
}

# Сжать глобальный WORK_DIR в ARCHIVE_NAME.tar.gz внутри
# COLLECTOR_DIR, используя pigz с учитывающим хост числом потоков/паузой,
# когда доступно.
_archive_collection_workdir() {
    local cores _pigz_wait=0

    cd "$COLLECTOR_DIR" || die "Cannot enter $COLLECTOR_DIR"
    if command -v pigz &>/dev/null; then
        cores="$(nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || echo 2)"
        # Общесистемный запас: используем (лимит-20)% ядер, чтобы один pigz не превышал Zabbix-подобную нагрузку
        cores=$(( cores * (${RESOURCE_CPU_LIMIT:-80} - 20) / 100 ))
        [[ "$cores" -lt 1 ]] && cores=1
        _get_cpu_usage_percent >/dev/null
        # Только ограниченное ожидание — никогда не блокировать архивацию навечно на загруженном хосте
        while ! _collector_resources_ok && [[ "$_pigz_wait" -lt 30 ]]; do
            sleep 1
            _pigz_wait=$((_pigz_wait + 1))
        done
        [[ "$_pigz_wait" -ge 30 ]] && info "pigz: host still busy — compressing anyway (reduced threads)"
        tar -cf - "$ARCHIVE_NAME" --remove-files | pigz -p "$cores" > "$ARCHIVE_NAME.tar.gz"
        ok "$(_l archive_pigz)"
    else
        tar -zcf "$ARCHIVE_NAME.tar.gz" "$ARCHIVE_NAME" --remove-files
        ok "$(_l archive_gzip)"
    fi
    # ${SCRIPT_NAME}.log уже упакован в архив и удалён вместе с WORK_DIR
    # (--remove-files) — дальше писать в него уже нельзя
    LOG_FILE=""
    echo ""
    ok "$(_l archive_at): $COLLECTOR_DIR/$ARCHIVE_NAME.tar.gz"
}

run_log_collection() {
    local mode="$1"
    local timeout_raw="${2:-}"
    local timeout_sec=0

    if [[ -n "$timeout_raw" ]]; then
        if ! parse_duration "$timeout_raw"; then
            die "Invalid timeout: '$timeout_raw'. Use: 5h, 30m, 1d, 300s or 300"
        fi
        if [[ "$mode" == "online" ]]; then
            timeout_sec=$(duration_to_seconds "$PARSE_RESULT_NUM" "$PARSE_RESULT_UNIT")
        fi
    fi

    _prepare_collection_workdir "$mode"
    log_debug "Аргументы run_log_collection: mode=$mode timeout_raw='$timeout_raw' LOG_SCOPE=$LOG_SCOPE FROM_TIME='$FROM_TIME' TO_TIME='$TO_TIME' OUTPUT_DIR='$OUTPUT_DIR' INCLUDE_MGCPCLIENT='$INCLUDE_MGCPCLIENT' SELECTED_PRODUCTS=(${SELECTED_PRODUCTS[*]+"${SELECTED_PRODUCTS[*]}"}) SELECTED_SERVICES=(${SELECTED_SERVICES[*]+"${SELECTED_SERVICES[*]}"})"
    _resolve_collection_targets "$mode" || return 1

    local collect_infra=0
    [[ "$LOG_SCOPE" == "extended" ]] && collect_infra=1

    if [[ "$mode" == "online" ]]; then
        _run_online_collection "$timeout_raw" "$timeout_sec" "$collect_infra" || return 1
    else
        _run_offline_collection "$timeout_raw" "$collect_infra"
    fi

    if [[ "$collect_infra" -eq 1 ]]; then
        collect_configs "$WORK_DIR"
    fi
    prune_empty_collected_files "$WORK_DIR"
    report_collected_log_stats "$WORK_DIR" "$mode"

    _archive_collection_workdir
    info "$(_l done_msg)"
    return 0
}


