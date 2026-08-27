# Модуль: 01_time_filters.sh
# Слой: logging
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

