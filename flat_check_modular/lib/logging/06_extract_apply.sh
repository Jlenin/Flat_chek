# Модуль: 06_extract_apply.sh
# Слой: logging
# Назначение: Применение parce_service_log(s) к уже найденным директориям: потоковое сравнение/дедупликация файлов по диапазону, zgrep/архивные эвристики, прогресс offline-extract между параллельными job'ами по файлам, пул воркеров.
# Публичные функции: _log_extract_all_dirs_by_range(), _log_extract_dir_by_range(), _collect_progress_*(), _log_file_pool_worker(), _selftest_seek_extract() (used by extended self-test, см. lib/core/11_selftest.sh)
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

