# Модуль: 03_postgres_discovery.sh
# Слой: logging
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
#   lib/logging/07_collector.sh (см. комментарий там и в
#   lib/core/06_resource_gate.sh) — найдено при код-ревью фазы 5.

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
# COLLECTOR_ABORTED/COLLECTOR_TIMEOUT_STOP) переехала в lib/logging/07_collector.sh
# — единственное место, где эти два флага вообще выставляются (обработчики
# сигналов). Найдено при код-ревью фазы 5: раньше она была продублирована
# здесь с ДРУГИМ телом, чем стаб в lib/core/06_resource_gate.sh (там —
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

