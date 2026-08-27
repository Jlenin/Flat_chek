# Модуль: 07_collector.sh
# Слой: logging
# Назначение: Процессы сборщика логов: online tail -F, обработка сигналов (INT/TERM/Enter), безопасное удаление рабочих каталогов только по шаблону архива, resource-gate воркеров сбора.
# Публичные функции: run_log_collection()-хелперы, обработчики сигналов, безопасная очистка рабочего каталога
# Зависит от: 06_extract_apply.sh, lib/core (resource-gate), 00_tunables.sh
# Не зависит от: 08_online_offline.sh — верхнеуровневый режим использует эти хелперы
# Side effects: запускает tail -F/tcpdump в фоне, ловит сигналы, удаляет каталоги (только по шаблону YYYY.MM.DD_HH-MM_*)
#
# Источник: перенесено без изменений логики из flat_check_2.sh (строки 6364-7141).

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

_collector_max_jobs() {
    local n cores
    if [[ "${COLLECTOR_JOBS:-0}" -gt 0 ]]; then
        echo "$COLLECTOR_JOBS"
        return 0
    fi
    cores=$(nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)
    [[ -z "$cores" || "$cores" -lt 1 ]] && cores=4
    # Лимит воркеров по умолчанию от числа ядер; запуск всё равно ограничен общесистемными лимитами RESOURCE_*
    n=$(( cores * ${RESOURCE_CPU_LIMIT:-80} / 100 ))
    [[ "$n" -lt 1 ]] && n=1
    [[ "$n" -gt 32 ]] && n=32
    echo "$n"
}

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

# Процент использованной памяти по всему хосту (100 - MemAvailable/MemTotal*100)
_get_mem_usage_percent() {
    local pct
    # Предпочитать MemAvailable; запасной вариант MemFree (в Git Bash / нестандартных ядрах может не быть Available)
    pct=$(awk '/MemTotal:/ {t=$2} /MemAvailable:/ {a=$2} /MemFree:/ {f=$2} END {
        if (t+0 <= 0) { print 0; exit }
        if (a+0 <= 0) a = f
        printf "%d", int((t - a) * 100 / t);
    }' /proc/meminfo 2>/dev/null)
    echo "${pct:-0}"
}

# Процент занятости CPU системы через дельту /proc/stat (первый вызов инициализирует, возвращает 0)
_get_cpu_usage_percent() {
    local user nice system idle iowait irq softirq steal guest guest_nice
    local idle_all non_idle total diff_idle diff_total pct
    # shellcheck disable=SC2034
    read -r _cpu user nice system idle iowait irq softirq steal guest guest_nice < /proc/stat 2>/dev/null || {
        echo 0
        return 0
    }
    idle_all=$((idle + iowait))
    non_idle=$((user + nice + system + irq + softirq + steal))
    total=$((idle_all + non_idle))
    if [[ -z "${_CPU_PREV_TOTAL:-}" || "${_CPU_PREV_TOTAL}" -eq 0 ]]; then
        _CPU_PREV_IDLE=$idle_all
        _CPU_PREV_TOTAL=$total
        echo 0
        return 0
    fi
    diff_idle=$((idle_all - _CPU_PREV_IDLE))
    diff_total=$((total - _CPU_PREV_TOTAL))
    _CPU_PREV_IDLE=$idle_all
    _CPU_PREV_TOTAL=$total
    if [[ "$diff_total" -le 0 ]]; then
        echo 0
        return 0
    fi
    pct=$(( (100 * (diff_total - diff_idle)) / diff_total ))
    [[ "$pct" -lt 0 ]] && pct=0
    [[ "$pct" -gt 100 ]] && pct=100
    echo "$pct"
}

# Истина, если CPU и память всего хоста в пределах настроенных лимитов
_collector_resources_ok() {
    local cpu mem cpu_lim mem_lim
    cpu_lim=${RESOURCE_CPU_LIMIT:-80}
    mem_lim=${RESOURCE_MEM_LIMIT:-80}
    mem=$(_get_mem_usage_percent)
    [[ "$mem" =~ ^[0-9]+$ ]] || mem=0
    if [[ "$mem" -ge "$mem_lim" ]]; then
        return 1
    fi
    cpu=$(_get_cpu_usage_percent)
    [[ "$cpu" =~ ^[0-9]+$ ]] || cpu=0
    # Первая проба /proc/stat всегда возвращает 0 — всегда берём вторую пробу
    if [[ "$cpu" -eq 0 ]]; then
        sleep 0.2
        cpu=$(_get_cpu_usage_percent)
        [[ "$cpu" =~ ^[0-9]+$ ]] || cpu=0
    fi
    [[ "$cpu" -lt "$cpu_lim" ]]
}

# Ждать свободный слот для задачи. Общесистемный лимит придерживает *дополнительные*
# воркеры, когда CPU/MEM ≥ лимита, но никогда не блокирует навечно:
#   - 0 запущенных воркеров → всегда разрешить 1 (гарантия прогресса; избегаем зависания на загруженных хостах)
#   - ≥1 запущено → ждать запаса ресурсов или завершения задачи, до RESOURCE_WAIT_MAX
_collector_wait_slot() {
    local max_jobs="$1" pid alive
    local waited=0
    local max_wait="${RESOURCE_WAIT_MAX:-120}"
    local gate_warned=0
    # Инициализируем счётчик CPU
    _get_cpu_usage_percent >/dev/null
    while true; do
        alive=()
        for pid in "${COLLECTOR_JOB_PIDS[@]+"${COLLECTOR_JOB_PIDS[@]}"}"; do
            if kill -0 "$pid" 2>/dev/null; then
                alive+=("$pid")
            else
                wait "$pid" 2>/dev/null || true
            fi
        done
        COLLECTOR_JOB_PIDS=("${alive[@]+"${alive[@]}"}")

        if [[ ${#COLLECTOR_JOB_PIDS[@]} -lt "$max_jobs" ]]; then
            if _collector_resources_ok; then
                return 0
            fi
            # Воркеров пока нет → нужно запустить хотя бы один, иначе deadlock на загруженных хостах (MEM часто ≥80%)
            if [[ ${#COLLECTOR_JOB_PIDS[@]} -eq 0 ]]; then
                if [[ "$gate_warned" -eq 0 ]]; then
                    info "host CPU/MEM at/above ${RESOURCE_CPU_LIMIT}%/${RESOURCE_MEM_LIMIT}% — starting 1 worker (avoid hang)"
                    gate_warned=1
                fi
                return 0
            fi
            # Воркеры уже есть: ждём снижения нагрузки или завершения задачи
            if [[ "$waited" -ge "$max_wait" ]]; then
                if [[ "$gate_warned" -eq 0 ]]; then
                    info "host load gate wait ${max_wait}s — allowing another worker"
                    gate_warned=1
                fi
                return 0
            fi
        fi

        _collector_should_stop && return 1

        if [[ ${#COLLECTOR_JOB_PIDS[@]} -gt 0 ]]; then
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

_collector_wait_all_jobs() {
    local pid
    for pid in "${COLLECTOR_JOB_PIDS[@]+"${COLLECTOR_JOB_PIDS[@]}"}"; do
        wait "$pid" 2>/dev/null || true
    done
    COLLECTOR_JOB_PIDS=()
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

