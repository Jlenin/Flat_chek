# Модуль: 10_wizard.sh
# Слой: core
# Назначение: Интерактивный мастер (-i/--interactive) — язык, выбор режима
#   (health/сбор логов/самотест), для сбора логов: online/offline, scope,
#   диапазон времени, chunk-настройки, выбор продуктов/служб/типов логов.
# Публичные функции: run_interactive_wizard()
# Зависит от: lib/core (00_globals, 02_output, 03_i18n — _l(), 01_catalog —
#   PKG_PRODUCT/PKG_LEGACY); ветка сбора логов (_wizard_configure_log_mode →
#   _wizard_select_log_targets) дополнительно ожидает lib/logging уже
#   подключённым (список целей/типов логов строится через lib/logging/02_log_discovery.sh).
# Не зависит от: lib/agent — ветка --selftest/health не использует JSON/push напрямую
# Side effects: интерактивный ввод с терминала (read), печатает вопросы/списки,
#   устанавливает MODE_LOG/LOG_SUBMODE/SELFTEST_MODE/... как обычный parse_args()
#
# Источник: перенесено без изменений логики из flat_check_2.sh (строки 7434-7898).
#   Живёт в lib/core (а не в lib/logging), т.к. должен быть доступен ДО того,
#   как известно, какой режим выберет пользователь внутри мастера — сам мастер
#   решает, понадобится ли lib/logging, а не наоборот (см. flat_check: -i
#   безусловно подключает lib/logging, т.к. мастер может привести в режим сбора
#   логов уже после старта, когда подключать модули по флагам CLI уже поздно).

# --- 11. Мастер / справка / argv / main ------------------------------------------

# Единый разбор y/n в мастере (раскладки, регистр, yes/да/no/нет).
# Пустой ввод — НЕ yes (для вопросов с Enter=n это безопасный отказ).
# «н» = русская клавиша на месте латинской Y при RU-раскладке → не yes.
# «т» = русская клавиша на месте латинской N при RU-раскладке → no.
_wizard_is_yes() {
    local a="${1:-}"
    a="${a#"${a%%[![:space:]]*}"}"
    a="${a%"${a##*[![:space:]]}"}"
    [[ -z "$a" ]] && return 1
    case "$a" in
        y|Y|yes|YES|Yes|YeS|д|Д|да|ДА|Да) return 0 ;;
    esac
    local al
    al=$(printf '%s' "$a" | tr '[:upper:]' '[:lower:]')
    [[ "$al" == "y" || "$al" == "yes" ]] && return 0
    return 1
}

_wizard_is_no() {
    local a="${1:-}"
    a="${a#"${a%%[![:space:]]*}"}"
    a="${a%"${a##*[![:space:]]}"}"
    [[ -z "$a" ]] && return 1
    case "$a" in
        n|N|no|NO|No|н|Н|нет|НЕТ|Нет|т|Т) return 0 ;;
    esac
    local al
    al=$(printf '%s' "$a" | tr '[:upper:]' '[:lower:]')
    [[ "$al" == "n" || "$al" == "no" ]] && return 0
    return 1
}

# Интерактивный выбор продукта/службы; устанавливает SELECTED_PRODUCTS / SELECTED_SERVICES
# Печатает нумерованный список заранее, затем читает+разбирает выбор пользователя в
# отбор из этого же списка: "a"/"A"/"а"/"А"/"all"/"все" (или пустой ввод) выбирает
# всё; индексы через запятую и/или пробел выбирают конкретные элементы (невалидные
# токены выдают warn и пропускаются); если ничего валидного не выбрано, откатывается
# на "всё" — так же, как явное "all". Это шаг чтения+разбора,
# который раньше был скопипащен для списка продуктов и списка служб
# ниже; сама *печать* нумерованного списка отличается между ними (разная
# аннотация на элемент) и остаётся в каждом вызывающем коде.
# Аргументы: label (для предупреждения "Invalid <label> choice"), имя
# исходного массива, имя массива назначения.
_wizard_pick_from_list() {
    local label="$1"
    local -n _wpfl_src=$2
    local -n _wpfl_dst=$3
    local choice="" part normalized
    local -a _parts=()

    read -r choice 2>/dev/null || true
    choice="${choice:-a}"
    # trim
    choice="${choice#"${choice%%[![:space:]]*}"}"
    choice="${choice%"${choice##*[![:space:]]}"}"
    [[ -z "$choice" ]] && choice="a"

    _wpfl_dst=()
    case "$choice" in
        a|A|а|А|all|ALL|All|все|ВСЕ|Все)
            _wpfl_dst=("${_wpfl_src[@]}")
            ;;
        n|N|нет|НЕТ|Нет|none|NONE|None)
            # Явная отмена сбора логов (не fallback на «все»)
            _wpfl_dst=()
            WIZARD_SKIP_LOG=1
            ;;
        *)
            # Запятые и пробелы — равноправные разделители ("1,3" и "1 3")
            normalized="${choice//,/ }"
            # shellcheck disable=SC2206
            _parts=($normalized)
            for part in "${_parts[@]}"; do
                [[ -z "$part" ]] && continue
                if [[ "$part" =~ ^[0-9]+$ ]] && [[ "$part" -ge 1 && "$part" -le ${#_wpfl_src[@]} ]]; then
                    _wpfl_dst+=("${_wpfl_src[$((part - 1))]}")
                else
                    warn "Invalid $label choice: $part"
                fi
            done
            [[ ${#_wpfl_dst[@]} -eq 0 ]] && _wpfl_dst=("${_wpfl_src[@]}")
            ;;
    esac
    log_debug "wizard: $label choice='$choice' -> selected: ${_wpfl_dst[*]+"${_wpfl_dst[*]}"} skip=${WIZARD_SKIP_LOG:-0}"
}

_wizard_select_log_targets() {
    local -a prods=()
    local -A prod_pkgs=()
    local pkg prod i refine=""
    local -a svc_list=()

    SELECTED_PRODUCTS=()
    SELECTED_SERVICES=()

    for pkg in $(printf '%s\n' "${!PKG_PRODUCT[@]}" | sort); do
        _pkg_present_on_host "$pkg" || continue
        prod="${PKG_PRODUCT[$pkg]}"
        if [[ -z "${prod_pkgs[$prod]:-}" ]]; then
            prods+=("$prod")
            prod_pkgs["$prod"]="$pkg"
        else
            prod_pkgs["$prod"]="${prod_pkgs[$prod]} $pkg"
        fi
    done

    if [[ ${#prods[@]} -eq 0 ]]; then
        warn "$(_l wiz_no_targets)"
        return 0
    fi
    log_debug "wizard: available products on host: ${prods[*]}"

    echo ""
    echo "$(_l wiz_title_products)"
    i=1
    for prod in "${prods[@]}"; do
        echo "  $i — $prod (${prod_pkgs[$prod]})"
        i=$((i + 1))
    done
    echo "$(_l wiz_products_all)"
    echo -n "$(_l wiz_products_prompt)"
    _wizard_pick_from_list product prods SELECTED_PRODUCTS
    if [[ "${WIZARD_SKIP_LOG:-0}" -eq 1 ]]; then
        warn "Log collection cancelled (n)."
        return 0
    fi

    # Опциональное уточнение по службам: предлагаем всегда, если выбран хоть один продукт
    echo ""
    echo -n "$(_l wiz_refine_services)"
    read -r refine 2>/dev/null || true
    if _wizard_is_yes "$refine"; then
        svc_list=()
        for prod in "${SELECTED_PRODUCTS[@]}"; do
            for pkg in ${prod_pkgs[$prod]}; do
                svc_list+=("$pkg")
            done
        done
        echo "$(_l wiz_title_services)"
        i=1
        for pkg in "${svc_list[@]}"; do
            echo "  $i — $pkg [${PKG_PRODUCT[$pkg]}]"
            i=$((i + 1))
        done
        echo "$(_l wiz_services_all)"
        echo -n "$(_l wiz_services_prompt)"
        _wizard_pick_from_list service svc_list SELECTED_SERVICES
        if [[ "${WIZARD_SKIP_LOG:-0}" -eq 1 ]]; then
            warn "Log collection cancelled (n)."
            return 0
        fi
        SELECTED_PRODUCTS=()
    fi

    resolve_selected_packages

    # Шаг 9: опциональный выбор конкретных типов логов по каждой службе
    LOG_TYPE_FILTER=0
    SELECTED_LOG_TYPES=()
    local refine_types="" stem_list=() picked_types=() stem i_lt prod_label
    echo ""
    echo -n "$(_l wiz_refine_log_types)"
    read -r refine_types 2>/dev/null || true
    if _wizard_is_yes "$refine_types"; then
        LOG_TYPE_FILTER=1
        # Список служб — на fd 3: иначе _wizard_pick_from_list (read stdin)
        # съедает имена пакетов / EOF и всегда выбирает «все типы».
        while IFS= read -r pkg <&3; do
            [[ -n "$pkg" ]] || continue
            stem_list=()
            while IFS= read -r stem; do
                [[ -n "$stem" ]] && stem_list+=("$stem")
            done < <(_discover_log_type_stems_for_pkg "$pkg")
            prod_label="${PKG_PRODUCT[$pkg]:-?} ($pkg)"
            echo ""
            echo "$(_l wiz_title_log_types)"
            echo "$(_l wiz_log_types_for): $prod_label"
            if [[ ${#stem_list[@]} -eq 0 ]]; then
                info "$(_l wiz_log_types_none)"
                SELECTED_LOG_TYPES["$pkg"]="*"
                continue
            fi
            i_lt=1
            for stem in "${stem_list[@]}"; do
                echo "  $i_lt — $stem"
                i_lt=$((i_lt + 1))
            done
            echo "$(_l wiz_log_types_all)"
            echo -n "$(_l wiz_log_types_prompt)"
            picked_types=()
            _wizard_pick_from_list "log-type($pkg)" stem_list picked_types
            if [[ "${WIZARD_SKIP_LOG:-0}" -eq 1 ]]; then
                warn "Log collection cancelled (n)."
                return 0
            fi
            if [[ ${#picked_types[@]} -eq 0 || ${#picked_types[@]} -eq ${#stem_list[@]} ]]; then
                SELECTED_LOG_TYPES["$pkg"]="*"
            else
                SELECTED_LOG_TYPES["$pkg"]="${picked_types[*]}"
            fi
            log_debug "wizard: log types for $pkg -> ${SELECTED_LOG_TYPES[$pkg]}"
        done 3< <(
            for pkg in "${SELECTED_PKGS[@]+"${SELECTED_PKGS[@]}"}"; do
                printf '%s\t%s\n' "${PKG_PRODUCT[$pkg]:-ZZZ}" "$pkg"
            done | LC_ALL=C sort -t $'\t' -k1,1 -k2,2 | cut -f2
        )
        # При y инженер уже выбрал типы (включая/исключая mgcpclient) — вопрос не задаём
        _apply_mgcpclient_from_log_types
    else
        _resolve_mgcpclient_option
    fi

    echo ""
    info "$(_l wiz_preview_pkgs): ${#SELECTED_PKGS[@]}"
    for pkg in "${SELECTED_PKGS[@]+"${SELECTED_PKGS[@]}"}"; do
        if [[ "${LOG_TYPE_FILTER:-0}" -eq 1 ]]; then
            info "  → $pkg [${SELECTED_LOG_TYPES[$pkg]:-*}]"
        else
            info "  → $pkg"
        fi
    done
    if [[ "${LOG_TYPE_FILTER:-0}" -eq 1 ]]; then
        info "$(_l wiz_preview_log_types): filter=on"
    fi
    # Тоже в текущем shell — сохраняем LOG_DIR_OWNER для последующего сбора.
    local dirs=()
    discover_log_dirs_for_selected >/dev/null
    dirs=("${DISCOVERED_LOG_DIRS[@]+"${DISCOVERED_LOG_DIRS[@]}"}")
    info "$(_l wiz_preview_dirs): ${#dirs[@]}"
    for d in "${dirs[@]+"${dirs[@]}"}"; do
        info "  → $d"
    done
}

# --- Шаги диалога мастера (каждый читает ровно один запрос) --------------------
# Локальные переменные предварительно инициализируются в "" перед каждым read: при
# `set -u` `read`, наткнувшийся на EOF (неинтерактивный stdin), может оставить целевую
# переменную неустановленной, а не пустой, и любой последующий `[[ "$var" == ... ]]`
# на никогда не назначенной локальной переменной прервёт выполнение скрипта.

_wizard_step_language() {
    local lang_choice=""
    echo ""
    echo "=== Language / Язык ==="
    echo "  1 — Русский"
    echo "  2 — English"
    echo -n "$(_l ask_lang_prompt)"
    read -r lang_choice 2>/dev/null || true
    if [[ "$lang_choice" == "1" ]]; then CURRENT_LANG="ru"; else CURRENT_LANG="en"; fi
    log_debug "wizard: lang_choice='$lang_choice' -> CURRENT_LANG=$CURRENT_LANG"
}

# Устанавливает глобальную WIZARD_MODE_CHOICE для диспетчеризации у вызывающего кода — НЕ печатает:
# эта функция уже печатает текст запроса в тот же stdout, так что
# возврат выбора через $(...) захватил бы и этот текст тоже.
_wizard_step_mode() {
    WIZARD_MODE_CHOICE=""
    echo ""
    echo "$(_l wiz_title_mode)"
    echo "$(_l wiz_mode_1)"
    echo "$(_l wiz_mode_2)"
    echo "$(_l wiz_mode_3)"
    echo -n "$(_l wiz_mode_prompt)"
    read -r WIZARD_MODE_CHOICE 2>/dev/null || true
    log_debug "wizard: mode_choice='$WIZARD_MODE_CHOICE'"
}

_wizard_step_online_offline() {
    local submode_choice=""
    echo ""
    echo "$(_l wiz_title_type)"
    echo "$(_l wiz_type_1)"
    echo "$(_l wiz_type_2)"
    echo -n "$(_l wiz_type_prompt)"
    read -r submode_choice 2>/dev/null || true
    [[ "$submode_choice" == "2" ]] && LOG_SUBMODE="offline" || LOG_SUBMODE="online"
    log_debug "wizard: submode_choice='$submode_choice' -> LOG_SUBMODE=$LOG_SUBMODE"
}

_wizard_step_scope() {
    local scope_choice=""
    echo ""
    echo "$(_l wiz_title_scope)"
    echo "$(_l wiz_scope_1)"
    echo "$(_l wiz_scope_2)"
    echo -n "$(_l wiz_scope_prompt)"
    read -r scope_choice 2>/dev/null || true
    [[ "$scope_choice" == "2" ]] && LOG_SCOPE="extended" || LOG_SCOPE="brief"
    log_debug "wizard: scope_choice='$scope_choice' -> LOG_SCOPE=$LOG_SCOPE"
}

# Online: timeout, плюс (только для extended scope) отказ от tcpdump.
_wizard_step_online_time_settings() {
    local tcpdump_choice=""
    echo ""
    echo -n "$(_l wiz_timeout)"
    read -r TIMEOUT_RAW 2>/dev/null || true
    TIMEOUT_RAW="${TIMEOUT_RAW:-}"
    if [[ "$LOG_SCOPE" == "extended" ]]; then
        echo -n "$(_l wiz_tcpdump)"
        read -r tcpdump_choice 2>/dev/null || true
        _wizard_is_no "$tcpdump_choice" && START_TCPDUMP=0
    else
        START_TCPDUMP=0
    fi
    log_debug "wizard: online timeout='$TIMEOUT_RAW' tcpdump_choice='$tcpdump_choice' -> START_TCPDUMP=$START_TCPDUMP"
}

# Offline: выбрать режим диапазона (отступ по длительности / явные from+to / from+offset).
_wizard_step_offline_time_settings() {
    local range_choice=""
    echo ""
    echo "$(_l wiz_title_range)"
    echo "$(_l wiz_range_1)"
    echo "$(_l wiz_range_2)"
    echo "$(_l wiz_range_3)"
    echo "$(_l wiz_range_all)"
    echo -n "$(_l wiz_range_prompt)"
    read -r range_choice 2>/dev/null || true
    case "$range_choice" in
        1)
            echo -n "$(_l wiz_for_how_long)"
            read -r TIMEOUT_RAW 2>/dev/null || true
            TIMEOUT_RAW="${TIMEOUT_RAW:-}"
            ;;
        2)
            echo -n "$(_l wiz_from_dt)"
            read -r FROM_TIME 2>/dev/null || true
            FROM_TIME="${FROM_TIME:-}"
            echo -n "$(_l wiz_to_dt)"
            read -r TO_TIME 2>/dev/null || true
            TO_TIME="${TO_TIME:-}"
            ;;
        3)
            echo -n "$(_l wiz_from_dt2)"
            read -r FROM_TIME 2>/dev/null || true
            FROM_TIME="${FROM_TIME:-}"
            echo -n "$(_l wiz_for_offset)"
            read -r TO_TIME 2>/dev/null || true
            TO_TIME="${TO_TIME:-}"
            ;;
    esac
    log_debug "wizard: range_choice='$range_choice' -> TIMEOUT_RAW='${TIMEOUT_RAW:-}' FROM_TIME='${FROM_TIME:-}' TO_TIME='${TO_TIME:-}'"
}

# Только offline: как резать итоговые part_*.log в архиве — по размеру
# (LOG_CHUNK_SIZE_BYTES) или по числу строк (LOG_CHUNK_LINES). См.
# LOG_CHUNK_MODE / _psl_split_final_output().
_wizard_step_chunk_settings() {
    local chunk_choice="" value="" bytes
    echo ""
    echo "$(_l wiz_title_chunk)"
    echo "$(_l wiz_chunk_1)"
    echo "$(_l wiz_chunk_2)"
    echo -n "$(_l wiz_chunk_prompt)"
    read -r chunk_choice 2>/dev/null || true
    if [[ "$chunk_choice" == "2" ]]; then
        LOG_CHUNK_MODE="lines"
        echo -n "$(_l wiz_chunk_lines_prompt)"
        read -r value 2>/dev/null || true
        [[ "$value" =~ ^[1-9][0-9]*$ ]] && LOG_CHUNK_LINES="$value"
    else
        LOG_CHUNK_MODE="size"
        echo -n "$(_l wiz_chunk_size_prompt)"
        read -r value 2>/dev/null || true
        if [[ -n "$value" ]]; then
            if bytes=$(_parse_size_to_bytes "$value") && [[ "$bytes" -gt 0 ]]; then
                LOG_CHUNK_SIZE_BYTES="$bytes"
            else
                warn "$(_l wiz_chunk_size_invalid) '$value'"
            fi
        fi
    fi
    log_debug "wizard: chunk_choice='$chunk_choice' value='$value' -> LOG_CHUNK_MODE=$LOG_CHUNK_MODE LOG_CHUNK_SIZE_BYTES=$LOG_CHUNK_SIZE_BYTES LOG_CHUNK_LINES=$LOG_CHUNK_LINES"
}

_wizard_step_output_dir() {
    local out_dir=""
    echo -n "$(_l wiz_output_dir)"
    read -r out_dir 2>/dev/null || true
    [[ -n "$out_dir" ]] && OUTPUT_DIR="$out_dir"
}

# Режим 2: настроить сбор логов от начала до конца — online/offline, область,
# настройки времени, выбор продукта/службы, директория вывода.
_wizard_configure_log_mode() {
    MODE_LOG=1
    MODE_DEV=0
    SELFTEST_MODE=""
    WIZARD_SKIP_LOG=0

    _wizard_step_online_offline
    _wizard_step_scope

    if [[ "$LOG_SUBMODE" == "online" ]]; then
        _wizard_step_online_time_settings
    else
        _wizard_step_offline_time_settings
        # Разбивка на part_*.log касается только offline — online просто
        # tail -F в один файл на источник, без нарезки.
        _wizard_step_chunk_settings
    fi

    # Выбор продукта / службы
    detect_os
    _wizard_select_log_targets
    if [[ "${WIZARD_SKIP_LOG:-0}" -eq 1 ]]; then
        MODE_LOG=0
        _log_line "INFO" "wizard: сбор логов отменён (n)"
        return 0
    fi
    log_debug "wizard: SELECTED_PRODUCTS=(${SELECTED_PRODUCTS[*]+"${SELECTED_PRODUCTS[*]}"}) SELECTED_SERVICES=(${SELECTED_SERVICES[*]+"${SELECTED_SERVICES[*]}"})"

    _wizard_step_output_dir
    _log_line "INFO" "wizard: режим=сбор логов $LOG_SUBMODE, scope=$LOG_SCOPE, output_dir='${OUTPUT_DIR:-(по умолчанию)}'"
}

# Режим 3: настроить режим самотеста (simple/extended).
_wizard_configure_selftest() {
    local selftest_choice=""
    MODE_LOG=0
    MODE_DEV=0
    echo ""
    echo "$(_l wiz_title_selftest)"
    echo "$(_l wiz_selftest_1)"
    echo "$(_l wiz_selftest_2)"
    echo -n "$(_l wiz_selftest_prompt)"
    read -r selftest_choice 2>/dev/null || true
    case "$selftest_choice" in
        2) SELFTEST_MODE="extended"; MODE_DEV=1 ;;
        *) SELFTEST_MODE="simple" ;;
    esac
    _log_line "INFO" "wizard: режим=самотест ($SELFTEST_MODE)"
}

# Режим по умолчанию: проверка состояния, с опциональной секцией репозиториев.
_wizard_configure_healthcheck() {
    local repo_choice=""
    MODE_LOG=0
    MODE_DEV=0
    SELFTEST_MODE=""
    echo -n "$(_l wiz_show_repo)"
    read -r repo_choice 2>/dev/null || true
    _wizard_is_yes "$repo_choice" && SHOW_REPO=1
    _log_line "INFO" "wizard: режим=проверка служб (health check), show_repo=$SHOW_REPO"
}

run_interactive_wizard() {
    # Сбрасываем режимы, чтобы предыдущий -log/--dev из argv не протёк в выбор проверки состояния
    MODE_LOG=0
    MODE_DEV=0
    SELFTEST_MODE=""

    _wizard_step_language

    _wizard_step_mode

    case "$WIZARD_MODE_CHOICE" in
        2) _wizard_configure_log_mode ;;
        3) _wizard_configure_selftest ;;
        *) _wizard_configure_healthcheck ;;
    esac
}
