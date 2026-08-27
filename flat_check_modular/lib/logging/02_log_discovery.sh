# Модуль: 02_log_discovery.sh
# Слой: logging
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

