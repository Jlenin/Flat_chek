# --- JSON report / config / push (agent) ---------------------------------------
# Общий блок для flat_check.sh и health-пути flat_check_2.sh.
# Формирует JSON v2 и пушит на один или несколько HTTP/HTTPS URL.

# Дефолты (не затираем значения из section 0 / окружения)
: "${OUTPUT_JSON:=0}"
: "${DO_PUSH:=0}"
: "${CONFIG_FILE:=}"
: "${SINGLE_PKG:=}"
: "${FILTER_PRODUCT:=}"
: "${HOST_ID:=}"
: "${HOST_IP:=}"
: "${SERVICE_NAME:=}"
: "${PUSH_URLS:=${PUSH_URL:-}}"
: "${PUSH_TOKEN:=}"
: "${PUSH_TOKENS:=}"
: "${PUSH_AUTH_HEADER:=Authorization: Bearer}"
: "${PUSH_CONNECT_TIMEOUT:=5}"
: "${PUSH_MAX_TIME:=30}"
: "${PUSH_RETRIES:=2}"
: "${PUSH_INSECURE:=0}"
: "${SHOW_REPOS_JSON:=0}"

# Значение из "KEY=..." строки конфига: снимает окружающие кавычки и то, что
# после них (инлайн-комментарий) — например,
# SERVICE_NAME="fss-backend"    # см. service_names.md
# наивный ${val%\"} снимает кавычку только если она в самом конце строки, а
# ".*" в regex вызова уже захватил весь хвост вместе с комментарием, так что
# без этой функции в SERVICE_NAME утекало 'fss-backend"    # см. ...'.
_conf_strip_value() {
    local raw="$1" val
    if [[ "$raw" =~ ^[[:space:]]*\"(.*)$ ]]; then
        val="${BASH_REMATCH[1]%%\"*}"
    elif [[ "$raw" =~ ^[[:space:]]*\'(.*)$ ]]; then
        val="${BASH_REMATCH[1]%%\'*}"
    else
        val="${raw%%#*}"
        val="${val%"${val##*[![:space:]]}"}"
        val="${val#"${val%%[![:space:]]*}"}"
    fi
    printf '%s' "$val"
}

_json_load_config() {
    # Conf заполняет только пустые переменные: CLI и env имеют приоритет.
    local f="$1" line key val
    [[ -n "$f" && -f "$f" ]] || return 0
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ -z "${line//[[:space:]]/}" ]] && continue
        if [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
            key="${BASH_REMATCH[1]}"
            val="$(_conf_strip_value "${BASH_REMATCH[2]}")"
            case "$key" in
                HOST_ID) [[ -z "${HOST_ID}" ]] && HOST_ID="$val" ;;
                HOST_IP) [[ -z "${HOST_IP}" ]] && HOST_IP="$val" ;;
                SERVICE_NAME) [[ -z "${SERVICE_NAME}" ]] && SERVICE_NAME="$val" ;;
                PUSH_URLS) [[ -z "${PUSH_URLS}" ]] && PUSH_URLS="$val" ;;
                PUSH_URL) [[ -z "${PUSH_URL:-}" ]] && PUSH_URL="$val" ;;
                PUSH_TOKEN) [[ -z "${PUSH_TOKEN}" ]] && PUSH_TOKEN="$val" ;;
                PUSH_TOKENS) [[ -z "${PUSH_TOKENS}" ]] && PUSH_TOKENS="$val" ;;
                PUSH_AUTH_HEADER) [[ -z "${PUSH_AUTH_HEADER}" ]] && PUSH_AUTH_HEADER="$val" ;;
                PACKAGES) [[ -z "${PACKAGES}" ]] && PACKAGES="$val" ;;
                PRODUCT) [[ -z "${PRODUCT:-}" ]] && PRODUCT="$val" ;;
                PUSH_CONNECT_TIMEOUT|PUSH_MAX_TIME|PUSH_RETRIES)
                    [[ "$val" =~ ^[0-9]+$ ]] && printf -v "$key" '%s' "$val"
                    ;;
                PUSH_INSECURE)
                    [[ "$val" =~ ^[01]$ ]] && PUSH_INSECURE="$val"
                    ;;
                COLLECTOR_JOBS|JOBS)
                    if [[ "$val" =~ ^[0-9]+$ && "${COLLECTOR_JOBS:-0}" -eq 0 ]]; then
                        COLLECTOR_JOBS="$val"
                    fi
                    ;;
            esac
        fi
    done < "$f"
    if [[ -z "$PUSH_URLS" && -n "${PUSH_URL:-}" ]]; then
        PUSH_URLS="$PUSH_URL"
    fi
    if [[ -n "${PRODUCT:-}" && -z "$FILTER_PRODUCT" ]]; then
        FILTER_PRODUCT="$PRODUCT"
    fi
}

_json_detect_host_ip() {
    local ip
    ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    [[ -n "$ip" ]] && { echo "$ip"; return 0; }
    ip=$(ip -4 route get 1 2>/dev/null | awk '/src/{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')
    echo "${ip:-}"
}

_json_ensure_identity() {
    [[ -n "$HOST_ID" ]] || HOST_ID="$(hostname -s 2>/dev/null || hostname 2>/dev/null || echo unknown)"
    [[ -n "$HOST_IP" ]] || HOST_IP="$(_json_detect_host_ip)"
    [[ -n "$SERVICE_NAME" ]] || SERVICE_NAME="${SINGLE_PKG:-unknown}"
}

# Экранирование строки для JSON (без внешних зависимостей).
_json_esc() {
    local s="${1:-}"
    s=${s//\\/\\\\}
    s=${s//\"/\\\"}
    s=${s//$'\n'/\\n}
    s=${s//$'\r'/\\r}
    s=${s//$'\t'/\\t}
    printf '%s' "$s"
}

_json_arr_from_csv() {
    local csv="${1:-}" first=1 item
    printf '['
    if [[ -n "$csv" ]]; then
        IFS=',' read -ra _items <<< "$csv"
        for item in "${_items[@]}"; do
            item="${item#"${item%%[![:space:]]*}"}"
            item="${item%"${item##*[![:space:]]}"}"
            [[ -z "$item" ]] && continue
            [[ $first -eq 1 ]] || printf ','
            first=0
            printf '"%s"' "$(_json_esc "$item")"
        done
    fi
    printf ']'
}

# Собрать JSON-объект одного пакета (без печати human-output).
_json_collect_pkg() {
    local pkg="$1"
    local legacy="${PKG_LEGACY[$pkg]:-}"
    local status="not_installed" ver="" unit="${pkg}.service"
    local unit_path="" active="unknown" enabled="unknown"
    local opt_path="/opt/flat/$pkg" opt_owner="" opt_status="missing"
    local log_path="/var/log/flat/$pkg" log_owner="" log_status="missing"
    local deps_meta="${PKG_DEPS[$pkg]:-}" deps_pm=""
    local pids="" ps_lines="" proc_status="not running"
    local ports_json="" api_url="" api_code=0 api_status="n/a"
    local configs_json="" port_spec port open
    local ngx_av ngx_en lr sudoers

    FOUND_PKG_VER=""
    if is_pkg_installed_tiny "$pkg" "$legacy"; then
        # тихий сбор версии без print_*
        case "$PM" in
            dpkg)
                ver=$(dpkg-query -W -f='${Version}' "$pkg" 2>/dev/null)
                [[ -z "$ver" && -n "$legacy" ]] && ver=$(dpkg-query -W -f='${Version}' $(echo "$legacy" | tr ',' ' ' | awk '{print $1}') 2>/dev/null)
                ;;
            rpm)
                ver=$(rpm -q --queryformat '%{VERSION}-%{RELEASE}' "$pkg" 2>/dev/null) || true
                ;;
            *)
                ver=$(get_pkg_version "$pkg" 2>/dev/null || true)
                ;;
        esac
        status="installed"
        INSTALLED=$((INSTALLED + 1))
    else
        if [[ $VERBOSE -eq 1 ]] || [[ -n "$SINGLE_PKG" ]]; then
            NOT_INSTALLED=$((NOT_INSTALLED + 1))
        else
            # в обычном JSON-снимке не включаем не установленные
            return 1
        fi
    fi

    # systemd
    if [[ -f "/usr/lib/systemd/system/$unit" ]]; then
        unit_path="/usr/lib/systemd/system/$unit"
    elif [[ -f "/lib/systemd/system/$unit" ]]; then
        unit_path="/lib/systemd/system/$unit"
    elif [[ -f "/etc/systemd/system/$unit" ]]; then
        unit_path="/etc/systemd/system/$unit"
    fi
    if command -v systemctl >/dev/null 2>&1; then
        active=$(systemctl is-active "$unit" 2>/dev/null || echo unknown)
        enabled=$(systemctl is-enabled "$unit" 2>/dev/null || echo unknown)
    fi

    # directories
    if [[ -d "$opt_path" ]]; then
        opt_status="ok"
        opt_owner=$(stat -c '%U:%G' "$opt_path" 2>/dev/null || echo "")
    fi
    if [[ -d "$log_path" ]]; then
        log_status="ok"
        log_owner=$(stat -c '%U:%G' "$log_path" 2>/dev/null || echo "")
    elif [[ "$status" == "installed" ]]; then
        log_status="missing"
    fi

    deps_pm=$(get_pkg_depends "$pkg" 2>/dev/null || true)

    # process
    # _sys_pkg_pids() (не голый pgrep по имени пакета) — иначе пакеты вроде
    # fss-capagent, которые запускают сторонний бинарь другим именем (heplify,
    # без "fss-capagent" где-либо в argv), всегда виделись бы как "not running",
    # хотя systemd честно показывает unit активным. _sys_pkg_pids добавляет
    # запасной путь через `systemctl show -p MainPID`, который от имени
    # процесса не зависит.
    pids=$(_sys_pkg_pids "$pkg" 2>/dev/null | paste -sd',' - 2>/dev/null)
    if [[ -n "$pids" ]]; then
        proc_status="running"
        ps_lines=$(ps -o pid=,args= -p "${pids//,/ }" 2>/dev/null | head -5 | sed 's/"/\\"/g' || true)
    fi

    # ports
    ports_json="["
    local first_port=1
    for port_spec in $(echo "${PKG_PORTS[$pkg]:-}" | tr ',' ' '); do
        [[ -z "$port_spec" ]] && continue
        open="not listening"
        if command -v ss >/dev/null 2>&1; then
            if ss -lntu 2>/dev/null | grep -qE ":${port_spec%%-*}\\b"; then
                open="listening"
            fi
        elif command -v netstat >/dev/null 2>&1; then
            if netstat -lntu 2>/dev/null | grep -qE ":${port_spec%%-*}\\b"; then
                open="listening"
            fi
        fi
        [[ $first_port -eq 1 ]] || ports_json+=","
        first_port=0
        ports_json+=$(printf '{"number":"%s","status":"%s"}' "$(_json_esc "$port_spec")" "$(_json_esc "$open")")
    done
    ports_json+="]"

    # api
    local ep="${PKG_API[$pkg]:-}"
    if [[ -n "$ep" ]]; then
        if [[ "$ep" == http://* || "$ep" == https://* ]]; then
            api_url="$ep"
        else
            api_url="http://localhost:${PKG_PORTS[$pkg]%%,*}$ep"
            # если порт диапазон/пуст — оставим как path на localhost
            [[ "${PKG_PORTS[$pkg]:-}" == *","* || "${PKG_PORTS[$pkg]:-}" == *"-"* || -z "${PKG_PORTS[$pkg]:-}" ]] && api_url="http://localhost$ep"
        fi
        if command -v curl >/dev/null 2>&1; then
            api_code=$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 2 --max-time 5 "$api_url" 2>/dev/null) || true
            [[ "$api_code" =~ ^[0-9]{3}$ ]] || api_code=0
            api_code=$((10#${api_code:-0}))
            [[ "$api_code" -eq 200 || "$api_code" -eq 204 ]] && api_status="ok" || api_status="fail"
        else
            api_code=0
            api_status="curl_not_found"
        fi
    fi

    # configs
    configs_json="["
    local first_cfg=1
    ngx_av="/etc/nginx/sites-available/$pkg"
    ngx_en="/etc/nginx/sites-enabled/$pkg"
    lr="/etc/logrotate.d/${pkg}.conf"
    [[ -f "/etc/logrotate.d/$pkg" && ! -f "$lr" ]] && lr="/etc/logrotate.d/$pkg"
    sudoers="/etc/sudoers.d/$pkg"
    for pair in "nginx:$ngx_av" "nginx:$ngx_en" "logrotate:$lr" "sudoers:$sudoers"; do
        local svc="${pair%%:*}" path="${pair#*:}" st="missing"
        [[ -e "$path" || -L "$path" ]] && st="ok"
        [[ "$path" == "$ngx_en" && ( -e "$path" || -L "$path" ) ]] && st="enabled"
        [[ $first_cfg -eq 1 ]] || configs_json+=","
        first_cfg=0
        configs_json+=$(printf '{"service_name":"%s","path":"%s","status":"%s"}' \
            "$(_json_esc "$svc")" "$(_json_esc "$path")" "$(_json_esc "$st")")
    done
    configs_json+="]"

    # ps_lines → JSON array
    local ps_json="[" pl first_ps=1
    while IFS= read -r pl; do
        [[ -z "$pl" ]] && continue
        [[ $first_ps -eq 1 ]] || ps_json+=","
        first_ps=0
        ps_json+=$(printf '"%s"' "$(_json_esc "$pl")")
    done <<< "$ps_lines"
    ps_json+="]"

    # pids → JSON array
    local pids_json="[" first_pid=1 pid
    if [[ -n "$pids" ]]; then
        IFS=',' read -ra _pids <<< "$pids"
        for pid in "${_pids[@]}"; do
            [[ "$pid" =~ ^[0-9]+$ ]] || continue
            [[ $first_pid -eq 1 ]] || pids_json+=","
            first_pid=0
            pids_json+="$pid"
        done
    fi
    pids_json+="]"

    printf '{'
    printf '"name":"%s",' "$(_json_esc "$pkg")"
    printf '"status":"%s",' "$(_json_esc "$status")"
    printf '"version":"%s",' "$(_json_esc "$ver")"
    printf '"depends_meta":%s,' "$(_json_arr_from_csv "$deps_meta")"
    printf '"depends_pm":%s,' "$(_json_arr_from_csv "$deps_pm")"
    printf '"systemd":{"unit_path":"%s","service_name":"%s","status":"%s"},' \
        "$(_json_esc "$unit_path")" "$(_json_esc "$unit")" "$(_json_esc "$active")"
    printf '"directories":['
    printf '{"type":"opt","path":"%s","owner":"%s","status":"%s"},' \
        "$(_json_esc "$opt_path")" "$(_json_esc "$opt_owner")" "$(_json_esc "$opt_status")"
    printf '{"type":"log","path":"%s","owner":"%s","status":"%s"}' \
        "$(_json_esc "$log_path")" "$(_json_esc "$log_owner")" "$(_json_esc "$log_status")"
    printf '],'
    printf '"configs":%s,' "$configs_json"
    printf '"process":{"status":"%s","pids":%s,"ps_lines":%s},' \
        "$(_json_esc "$proc_status")" "$pids_json" "$ps_json"
    printf '"ports":%s,' "$ports_json"
    printf '"api":{"url":"%s","status_code":%s,"status":"%s"}' \
        "$(_json_esc "$api_url")" "${api_code:-0}" "$(_json_esc "$api_status")"
    printf '}'
    return 0
}

_json_collect_system() {
    local cpu_pct=0 mem_total=0 mem_used=0 mem_avail=0
    local up_sec=0
    # _sys_cpu_via_procstat() сама делает init-вызов без $(...) (иначе дельта
    # /proc/stat теряется вместе с субшеллом, и результат всегда 0) — не дублируем
    # эту логику здесь, а переиспользуем уже проверенный замер.
    cpu_pct=$(_sys_cpu_via_procstat 2>/dev/null) || cpu_pct=0
    [[ "$cpu_pct" =~ ^[0-9]+$ ]] || cpu_pct=0
    if [[ "$cpu_pct" -eq 0 ]]; then
        # Один замер за 0.5s-окно может честно попасть на затишье между
        # всплесками — берём соседнее окно ещё раз, прежде чем поверить в 0%.
        cpu_pct=$(_sys_cpu_via_procstat 2>/dev/null) || cpu_pct=0
        [[ "$cpu_pct" =~ ^[0-9]+$ ]] || cpu_pct=0
    fi

    if [[ -r /proc/meminfo ]]; then
        mem_total=$(awk '/MemTotal:/{printf "%d",$2/1024}' /proc/meminfo)
        mem_avail=$(awk '/MemAvailable:/{printf "%d",$2/1024}' /proc/meminfo)
        [[ -z "$mem_avail" || "$mem_avail" == "0" ]] && mem_avail=$(awk '/MemFree:/{printf "%d",$2/1024}' /proc/meminfo)
        mem_used=$((mem_total - mem_avail))
        [[ "$mem_used" -lt 0 ]] && mem_used=0
    fi
    up_sec=$(awk '{print int($1)}' /proc/uptime 2>/dev/null || echo 0)

    # disk
    local disk_json="[" first=1 fs mount usep
    while read -r fs _ _ _ usep mount; do
        [[ "$fs" == Filesystem* || "$fs" == "tmpfs" || "$fs" == "devtmpfs" ]] && continue
        [[ "$mount" == "/proc"* || "$mount" == "/sys"* || "$mount" == "/run"* ]] && continue
        usep="${usep%%%}"
        [[ "$usep" =~ ^[0-9]+$ ]] || continue
        [[ $first -eq 1 ]] || disk_json+=","
        first=0
        disk_json+=$(printf '{"filesystem":"%s","mount":"%s","used_percent":%s}' \
            "$(_json_esc "$fs")" "$(_json_esc "$mount")" "$usep")
    done < <(df -P 2>/dev/null | awk 'NR>1{print $1,$2,$3,$4,$5,$6}')
    disk_json+="]"

    # network (упрощённо: интерфейсы без замера sleep — mbps=0.0; полный замер дорог для JSON-пути)
    local net_json="[" first=1 iface
    for iface in /sys/class/net/*; do
        iface=$(basename "$iface")
        [[ "$iface" == "lo" ]] && continue
        [[ $first -eq 1 ]] || net_json+=","
        first=0
        net_json+=$(printf '{"interface":"%s","mbps":0.0}' "$(_json_esc "$iface")")
    done
    net_json+="]"

    # database brief
    local db_name="n/a" db_status="n/a" db_repl="none" db_nodes=0
    if command -v systemctl >/dev/null 2>&1; then
        if systemctl is-active --quiet postgresql 2>/dev/null || systemctl is-active --quiet postgresql@* 2>/dev/null; then
            db_name="postgresql"; db_status="active"; db_nodes=1
        elif systemctl is-active --quiet mariadb 2>/dev/null || systemctl is-active --quiet mysqld 2>/dev/null; then
            db_name="mariadb"; db_status="active"; db_nodes=1
        fi
    fi

    # certificates (пути-кандидаты)
    local certs_json="[" first=1 cert days subject
    for cert in /etc/nginx/ssl/*.crt /etc/nginx/ssl/*.pem /opt/flat/cert/*/*.pem /etc/ssl/certs/flat*.pem; do
        [[ -f "$cert" ]] || continue
        days=$(openssl x509 -in "$cert" -noout -enddate 2>/dev/null | sed 's/notAfter=//' | xargs -I{} date -d {} +%s 2>/dev/null || echo "")
        if [[ -n "$days" ]]; then
            days=$(( (days - $(date +%s)) / 86400 ))
        else
            days=0
        fi
        subject=$(openssl x509 -in "$cert" -noout -subject 2>/dev/null | sed 's/subject=//' || echo "")
        [[ $first -eq 1 ]] || certs_json+=","
        first=0
        certs_json+=$(printf '{"path":"%s","subject":"%s","days_left":%s}' \
            "$(_json_esc "$cert")" "$(_json_esc "$subject")" "$days")
        [[ $first -eq 0 && ${#certs_json} -gt 2000 ]] && break
    done
    certs_json+="]"

    printf '{'
    printf '"cpu":{"usage_percent":%s},' "${cpu_pct:-0}"
    printf '"cpu_services":[],'
    printf '"memory":{"total_mb":%s,"used_mb":%s,"available_mb":%s},' \
        "${mem_total:-0}" "${mem_used:-0}" "${mem_avail:-0}"
    printf '"memory_services":[],'
    printf '"disk":%s,' "$disk_json"
    printf '"database":{"name":"%s","status":"%s","replication":"%s","nodes":%s},' \
        "$(_json_esc "$db_name")" "$(_json_esc "$db_status")" "$(_json_esc "$db_repl")" "${db_nodes:-0}"
    printf '"network":%s,' "$net_json"
    printf '"uptime_seconds":%s' "${up_sec:-0}"
    printf '}'
    # certificates returned via global side file
    printf '%s' "$certs_json" > "${_JSON_TMP}/certificates.json"
}

_json_collect_infra() {
    local out="[" first=1 dep status ver port req
    # важно: не ${!ALL_DEPENDS[@]+...} — hyphen keys (fps-server)
    for dep in "${!ALL_DEPENDS[@]}"; do
        status="not_installed"; ver=""; port=""; req="${ALL_DEPENDS[$dep]}"
        # Статус пакета/библиотеки — тот же источник истины, что и текстовый
        # === Depends === (is_dep_installed/is_lib_available). Раньше здесь
        # смотрели только на systemctl, поэтому все обычные пакеты и
        # библиотеки (libc6, sudo, nodejs, …) всегда получали "unknown",
        # даже будучи установленными — только реальные systemd-юниты (nginx,
        # redis, …) когда-либо получали осмысленный статус.
        if [[ "$dep" == *.so.* ]]; then
            is_lib_available "$dep" 2>/dev/null && status="installed"
        else
            is_dep_installed "$dep" 2>/dev/null && status="installed"
            ver=$(get_dep_version "$dep" 2>/dev/null || true)
        fi
        # Если это ещё и systemd-служба (nginx/mariadb/postgresql/redis/…) —
        # уточняем состояние поверх "installed": активна она или нет.
        if command -v systemctl >/dev/null 2>&1; then
            if systemctl is-active --quiet "$dep" 2>/dev/null; then
                status="active"
            elif systemctl status "$dep" &>/dev/null; then
                status=$(systemctl is-active "$dep" 2>/dev/null || echo inactive)
            fi
        fi
        [[ $first -eq 1 ]] || out+=","
        first=0
        out+=$(printf '{"service_name":"%s","status":"%s","version":"%s","port_open":"%s","required_by":"%s"}' \
            "$(_json_esc "$dep")" "$(_json_esc "$status")" "$(_json_esc "$ver")" "$(_json_esc "$port")" "$(_json_esc "$req")")
    done
    out+="]"
    printf '%s' "$out"
}

_json_collect_repos() {
    local out="[" first=1 line
    if [[ "$PM" == "dpkg" ]]; then
        while IFS= read -r line; do
            [[ -z "$line" || "$line" =~ ^# ]] && continue
            [[ $first -eq 1 ]] || out+=","
            first=0
            out+=$(printf '"[apt] %s"' "$(_json_esc "$line")")
        done < <(grep -hE '^deb ' /etc/apt/sources.list /etc/apt/sources.list.d/*.list 2>/dev/null | head -50)
    elif [[ "$PM" == "rpm" ]]; then
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            [[ $first -eq 1 ]] || out+=","
            first=0
            out+=$(printf '"[yum] %s"' "$(_json_esc "$line")")
        done < <(grep -hE '^\[|^baseurl=' /etc/yum.repos.d/*.repo 2>/dev/null | head -50)
    fi
    out+="]"
    printf '%s' "$out"
}

# Полный снимок JSON v2 → stdout
build_health_json() {
    local products_list=()
    local p pkg product_json packages_json first_prod=1 first_pkg
    local ts system_json infra_json repos_json certs_json
    local pkg_filter="${PACKAGES:-}"

    _JSON_TMP=$(mktemp -d "${TMPDIR:-/tmp}/flat_json.XXXXXX") || return 1
    _json_ensure_identity
    detect_os >/dev/null 2>&1 || detect_os

    ERRORS=0; WARNINGS=0; INSTALLED=0; NOT_INSTALLED=0
    # -g обязателен: без него `declare -A` внутри функции создаёт ЛОКАЛЬНУЮ
    # переменную, а глобальный ALL_DEPENDS (объявлен -A в разделе 0) остаётся
    # unset после return — тогда register_dep() увидит его как обычный
    # индексированный массив и попытается вычислить "$dep" арифметически
    # (bash: arr[идентификатор] без -A трактуется как арифметика), что на
    # дефисных именах вида "fss-frontend" падает под set -u: "fss: unbound variable".
    declare -gA ALL_DEPENDS=()

    ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    system_json=$(_json_collect_system)
    certs_json=$(cat "${_JSON_TMP}/certificates.json" 2>/dev/null || echo '[]')

    if [[ -n "${FLAT_PRODUCTS_ORDER+x}" && ${#FLAT_PRODUCTS_ORDER[@]} -gt 0 ]]; then
        products_list=("${FLAT_PRODUCTS_ORDER[@]}")
    else
        products_list=("AutoCallServer" "BSS" "Click to Call" "Contact Center" "Device Manager" "Gateway" "Partner Server" "SoftSwitch" "Tarifficator" "IVR" "LC" "SMS" "LDAP" "SBC" "Portal" "flat-file" "FVSC" "Infrastructure")
    fi
    if [[ -n "$FILTER_PRODUCT" ]]; then
        products_list=("$FILTER_PRODUCT")
    fi

    printf '{'
    printf '"timestamp":"%s",' "$(_json_esc "$ts")"
    printf '"host_id":"%s",' "$(_json_esc "$HOST_ID")"
    printf '"host_ip":"%s",' "$(_json_esc "$HOST_IP")"
    printf '"service_name":"%s",' "$(_json_esc "$SERVICE_NAME")"
    printf '"script_version":"%s",' "$(_json_esc "$SCRIPT_VERSION")"
    printf '"os":"%s",' "$(_json_esc "${OS_FULL_VER:-${OS_NAME:-unknown}}")"
    printf '"package_manager":"%s",' "$(_json_esc "${PM:-unknown}")"

    printf '"products":['
    first_prod=1
    for p in "${products_list[@]}"; do
        packages_json="["
        first_pkg=1
        local product_pkgs=()
        for pkg in "${!PKG_PRODUCT[@]}"; do
            [[ "${PKG_PRODUCT[$pkg]}" == "$p" ]] || continue
            if [[ -n "$SINGLE_PKG" && "$pkg" != "$SINGLE_PKG" ]]; then
                continue
            fi
            if [[ -n "$pkg_filter" ]]; then
                [[ ",${pkg_filter}," == *",$pkg,"* ]] || continue
            fi
            product_pkgs+=("$pkg")
        done
        if ((${#product_pkgs[@]} > 0)); then
            local sorted
            sorted=$(printf '%s\n' "${product_pkgs[@]}" | sort)
            product_pkgs=()
            while IFS= read -r pkg; do
                [[ -n "$pkg" ]] && product_pkgs+=("$pkg")
            done <<< "$sorted"
        fi
        for pkg in ${product_pkgs[@]+"${product_pkgs[@]}"}; do
            local pj
            # $() - subshell: INSTALLED++ внутри _json_collect_pkg не доходит сюда
            pj=$(_json_collect_pkg "$pkg") || continue
            if [[ "$pj" == *'"status":"installed"'* ]]; then
                INSTALLED=$((INSTALLED + 1))
            fi
            # Регистрация deps для infra: и meta (PKG_DEPS), и реальные PM-deps —
            # как в текстовом пути (_register_pkg_deps/check_single_pkg), иначе
            # "infrastructure" в JSON видит только явно прописанные в каталоге
            # зависимости и пропускает всё, что реально тянет пакетный менеджер
            # (libc6, libssl3, redis, sudo, …), которые есть в "=== Depends ===".
            _register_pkg_deps "$pkg" 2>/dev/null || true
            [[ $first_pkg -eq 1 ]] || packages_json+=","
            first_pkg=0
            packages_json+="$pj"
        done
        packages_json+="]"
        # пустые продукты в JSON не включаем (даже при --pkg)
        [[ "$packages_json" == "[]" ]] && continue
        [[ $first_prod -eq 1 ]] || printf ','
        first_prod=0
        printf '{"name":"%s","packages":%s}' "$(_json_esc "$p")" "$packages_json"
    done
    printf '],'

    infra_json=$(_json_collect_infra)
    repos_json='[]'
    [[ $SHOW_REPO -eq 1 || $SHOW_REPOS_JSON -eq 1 ]] && repos_json=$(_json_collect_repos)

    printf '"infrastructure":%s,' "$infra_json"
    printf '"repositories":%s,' "$repos_json"
    printf '"apt_priorities":[],'
    printf '"summary":{"installed":%s,"errors":%s,"warnings":%s},' \
        "${INSTALLED:-0}" "${ERRORS:-0}" "${WARNINGS:-0}"
    printf '"system":%s,' "$system_json"
    printf '"certificates":%s,' "$certs_json"
    printf '"uptime_services":[]'
    printf '}\n'

    rm -rf -- "$_JSON_TMP" 2>/dev/null
}

# Отправка JSON на все URL из PUSH_URLS (http/https).
# PUSH_INSECURE=1 — не проверять TLS-сертификат (curl -k), для https с self-signed.
push_health_json() {
    local body="$1"
    local urls=() tokens=() url token i rc=0 http_code
    local auth_hdr="${PUSH_AUTH_HEADER:-Authorization: Bearer}"
    local curl_insecure=()
    [[ "${PUSH_INSECURE:-0}" == "1" ]] && curl_insecure=(-k)

    _json_ensure_identity
    [[ -n "$PUSH_URLS" ]] || { warn "push: PUSH_URLS пуст — некуда отправлять"; return 1; }
    command -v curl >/dev/null 2>&1 || { warn "push: curl не найден"; return 1; }

    # split URLs
    PUSH_URLS="${PUSH_URLS//,/ }"
    read -ra urls <<< "$PUSH_URLS"
    if [[ -n "$PUSH_TOKENS" ]]; then
        PUSH_TOKENS="${PUSH_TOKENS//,/ }"
        read -ra tokens <<< "$PUSH_TOKENS"
    fi

    i=0
    for url in "${urls[@]}"; do
        [[ -z "$url" ]] && continue
        if [[ ! "$url" =~ ^https?:// ]]; then
            warn "push: пропуск URL без http/https: $url"
            rc=1
            continue
        fi
        token="${PUSH_TOKEN:-}"
        [[ -n "${tokens[$i]:-}" ]] && token="${tokens[$i]}"
        i=$((i + 1))

        local attempt=0 ok=0 curl_errfile="/tmp/flat_push_err.$$"
        while [[ $attempt -le ${PUSH_RETRIES:-2} ]]; do
            attempt=$((attempt + 1))
            # Логируем реальную вызываемую команду (токен маскируем), а не
            # реконструкцию "по мотивам" — чтобы можно было взять и повторить
            # руками (curl -v ...) без гадания, какие флаги реально ушли.
            local curl_display="curl -sS -o <body> -w '%{http_code}'"
            [[ ${#curl_insecure[@]} -gt 0 ]] && curl_display+=" ${curl_insecure[*]}"
            curl_display+=" --connect-timeout ${PUSH_CONNECT_TIMEOUT:-5} --max-time ${PUSH_MAX_TIME:-30}"
            curl_display+=" -X POST '$url' -H 'Content-Type: application/json'"
            curl_display+=" -H 'X-Flat-Host-Id: ${HOST_ID}' -H 'X-Flat-Service-Name: ${SERVICE_NAME}'"
            [[ -n "$token" ]] && curl_display+=" -H '${auth_hdr} ***'"
            curl_display+=" --data-binary <json>"
            log_debug "push: attempt $attempt → run: $curl_display"
            http_code=$(curl -sS -o /tmp/flat_push_body.$$ -w '%{http_code}' \
                "${curl_insecure[@]}" \
                --connect-timeout "${PUSH_CONNECT_TIMEOUT:-5}" \
                --max-time "${PUSH_MAX_TIME:-30}" \
                -X POST "$url" \
                -H "Content-Type: application/json" \
                -H "X-Flat-Host-Id: ${HOST_ID}" \
                -H "X-Flat-Service-Name: ${SERVICE_NAME}" \
                ${token:+-H "$auth_hdr $token"} \
                --data-binary "$body" 2>"$curl_errfile") || true
            [[ "$http_code" =~ ^[0-9]{3}$ ]] || http_code="000"
            # http=000 сам по себе не говорит, ПОЧЕМУ (DNS/refused/timeout/TLS) —
            # curl обычно пишет это в stderr, раньше просто выбрасывался в /dev/null.
            [[ -s "$curl_errfile" ]] && log_debug "push: attempt $attempt → curl said: $(tr '\n' ' ' < "$curl_errfile" 2>/dev/null)"
            rm -f "$curl_errfile" 2>/dev/null
            if [[ "$http_code" =~ ^2[0-9][0-9]$ ]]; then
                info "push: OK $http_code → $url"
                ok=1
                break
            fi
            log_debug "push: attempt $attempt → $url http=$http_code"
            sleep 1
        done
        rm -f /tmp/flat_push_body.$$ 2>/dev/null
        [[ $ok -eq 1 ]] || { warn "push: FAIL → $url (last http=$http_code)"; rc=1; }
    done
    return "$rc"
}

# Печать JSON: с отступами (jq, иначе python3 -m json.tool), если stdout —
# интерактивный терминал (глазами читать одну гигантскую строку неудобно);
# компактно в одну строку иначе (пайп/файл/cron — не ломаем автоматизацию,
# которая ждёт ровно одну строку JSON). Нет ни jq, ни python3 — как раньше.
_json_print() {
    local body="$1"
    if [[ -t 1 ]]; then
        if command -v jq >/dev/null 2>&1; then
            printf '%s' "$body" | jq . 2>/dev/null && return 0
        elif command -v python3 >/dev/null 2>&1; then
            printf '%s' "$body" | python3 -m json.tool 2>/dev/null && return 0
        fi
    fi
    printf '%s\n' "$body"
}

run_health_json() {
    local body
    [[ -n "$CONFIG_FILE" ]] && _json_load_config "$CONFIG_FILE"
    body=$(build_health_json) || { fail "не удалось собрать JSON"; return 1; }
    if [[ "$DO_PUSH" -eq 1 ]]; then
        # при --push JSON тоже можно показать через --json; иначе только push
        [[ "$OUTPUT_JSON" -eq 1 ]] && _json_print "$body"
        push_health_json "$body"
        return $?
    fi
    _json_print "$body"
}
