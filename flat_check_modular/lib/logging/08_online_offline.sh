# Модуль: 08_online_offline.sh
# Слой: logging
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
#   lib/core/02_output.sh в фазе 1, этой функции не содержит вовсе — health-only
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


