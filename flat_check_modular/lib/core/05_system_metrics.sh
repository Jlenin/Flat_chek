# Модуль: 05_system_metrics.sh
# Слой: core
# Назначение: Обзор ресурсов хоста для дашборда/health JSON: CPU (по ОС-семействам), память, диск, PostgreSQL/MariaDB роль и репликация, сеть, сертификаты, uptime.
# Публичные функции: check_system(), _sys_cpu()/_sys_memory()/_sys_disk()/_sys_database()/_sys_network()/_sys_certificates()/_sys_uptime(), _sys_cpu_via_procstat(), _sys_pkg_pids()
# Зависит от: 00_globals.sh, 02_output.sh, 04_os_detect.sh
# Не зависит от: от каталога пакетов и проверок отдельных пакетов — сам только описывает хост в целом
# Side effects: запускает top/free/df/ss/psql/openssl/systemctl; печатает раздел === System ===
#
# Источник: перенесено без изменений логики из flat_check.sh (строки 480-1005).

# --- 3b. Системные метрики (обзор хоста для дашборда / health JSON) ------------
# Всегда печатает блок === System ===; отсутствующие данные → n/a (секция никогда не пропускается).

_sys_installed_pkgs() {
    local pkg
    for pkg in $(printf '%s\n' "${!PKG_PRODUCT[@]}" | sort); do
        if is_pkg_installed_tiny "$pkg" "${PKG_LEGACY[$pkg]:-}"; then
            echo "$pkg"
        fi
    done
}

# Суммирует %cpu или %mem по PID (поле ps: pcpu|pmem). Печатает число или пусто.
_sys_pids_pct_sum() {
    local field="$1"
    shift
    local pids=("$@") pid list="" tot
    [[ ${#pids[@]} -eq 0 ]] && { echo ""; return; }
    for pid in "${pids[@]}"; do
        [[ "$pid" =~ ^[0-9]+$ ]] || continue
        list="${list}${list:+,}${pid}"
    done
    [[ -z "$list" ]] && { echo ""; return; }
    tot=$(ps -p "$list" -o "$field"= 2>/dev/null | awk '{s+=$1} END{if(NR) printf "%.1f", s; else print ""}')
    echo "$tot"
}

# Экранирует строку для использования в базовом расширенном regex (pgrep -f)
_sys_regex_escape() {
    printf '%s' "$1" | sed 's/[][(){}.^$*+?|\\]/\\&/g'
}

# Кандидаты имён процесса/юнита для пакета (каноническое имя + legacy-алиасы)
_sys_pkg_names() {
    local pkg="$1" legacy name
    echo "$pkg"
    legacy="${PKG_LEGACY[$pkg]:-}"
    [[ -z "$legacy" ]] && return 0
    local IFS=','
    # shellcheck disable=SC2086
    for name in $legacy; do
        name="${name// /}"
        [[ -n "$name" && "$name" != "$pkg" ]] && echo "$name"
    done
}

# PID для имени пакета (точный pgrep + pgrep по похожему пути, systemd MainPID; также legacy-юниты)
_sys_pkg_pids() {
    local pkg="$1"
    local pids=() pid name esc
    while IFS= read -r name; do
        [[ -z "$name" ]] && continue
        esc=$(_sys_regex_escape "$name")
        while IFS= read -r pid; do
            [[ -n "$pid" ]] && pids+=("$pid")
        done < <(
            pgrep -x "$name" 2>/dev/null
            pgrep -f "(^|/)(${esc})([ /:]|$)" 2>/dev/null
        )
        if command -v systemctl &>/dev/null; then
            pid=$(systemctl show "${name}.service" -p MainPID --value 2>/dev/null || true)
            if [[ "$pid" =~ ^[0-9]+$ && "$pid" -gt 0 ]]; then
                pids+=("$pid")
            fi
        fi
    done < <(_sys_pkg_names "$pkg")
    if [[ ${#pids[@]} -gt 0 ]]; then
        printf '%s\n' "${pids[@]}" | sort -nu
    fi
}

# --- 3b-1. Пробы загрузки CPU по ОС -------------------------------------------
# Каждая проба печатает целочисленный/десятичный процент загрузки на stdout и
# возвращает 0, либо возвращает 1 без вывода, если снять показание не удалось.
# _sys_cpu() ниже вызывает их только через диспетчеризацию get_os_release().

# /proc/stat — это интерфейс ядра, одинаковый на любом поддерживаемом нами
# дистрибутиве Linux — это единственный не-OS-специфичный строительный блок,
# который всем пробам ниже разрешено использовать совместно, точно как они
_sys_cpu_via_procstat() {
    declare -F _get_cpu_usage_percent >/dev/null 2>&1 || return 1
    _get_cpu_usage_percent >/dev/null   # инициализируем окно дельты
    # 0.5s было мало для рваной VoIP-нагрузки (SIP-сигнализация всплесками) —
    # окно легко попадало ровно в затишье между всплесками и честно отдавало
    # низкий %, хотя средняя загрузка за секунду-две заметно выше (примерно
    # так же долго — единицы секунд — по умолчанию усредняет top). 1.5s не
    # устраняет саму возможность попасть в затишье, но делает это заметно реже.
    sleep 1.5
    local pct
    pct=$(_get_cpu_usage_percent)
    [[ "$pct" =~ ^[0-9]+$ ]] || return 1
    echo "$pct"
}

# Debian-семья (Debian/Ubuntu/Astra поставляют procps-ng >= 3.3.10):
# `top -bn1` печатает "%Cpu(s):  3.2 us,  1.1 sy, ..., 95.3 id, ...".
get_sys_cpu_debian() {
    _sys_cpu_via_procstat && return 0

    command -v top &>/dev/null || return 1
    local line idle
    line=$(top -bn1 2>/dev/null | grep -m1 '^%Cpu(s):')
    [[ -n "$line" ]] || return 1
    idle=$(grep -oE '[0-9]+([.,][0-9]+)?[[:space:]]*id' <<<"$line" | grep -oE '^[0-9]+([.,][0-9]+)?' | tr ',' '.')
    [[ -n "$idle" ]] || return 1
    awk -v i="$idle" 'BEGIN{printf "%.1f", 100-i}'
}

get_sys_cpu_ubuntu() { get_sys_cpu_debian; }   # та же семья procps-ng, что и у Debian
get_sys_cpu_astra()  { get_sys_cpu_debian; }   # Astra Linux основана на Debian

# RHEL-семья (RHEL/CentOS/Oracle/Rocky/AlmaLinux — один и тот же userland):
# старый procps печатает "Cpu(s):  10.0%us,  2.0%sy, ..., 87.0%id, ..." — без
# ведущего '%' в строке и без пробела перед '%' каждого поля.
get_sys_cpu_rhel() {
    _sys_cpu_via_procstat && return 0

    command -v top &>/dev/null || return 1
    local line idle us
    line=$(top -bn1 2>/dev/null | grep -m1 -E '^Cpu\(s\):')
    [[ -n "$line" ]] || return 1
    idle=$(grep -oE '[0-9]+([.,][0-9]+)?%id' <<<"$line" | grep -oE '^[0-9]+([.,][0-9]+)?' | tr ',' '.')
    if [[ -n "$idle" ]]; then
        awk -v i="$idle" 'BEGIN{printf "%.1f", 100-i}'
        return 0
    fi
    us=$(grep -oE '[0-9]+([.,][0-9]+)?%us' <<<"$line" | grep -oE '^[0-9]+([.,][0-9]+)?' | tr ',' '.')
    [[ -n "$us" ]] || return 1
    echo "$us"
}

get_sys_cpu_centos()    { get_sys_cpu_rhel; }   # CentOS — пересборка RHEL
get_sys_cpu_oracle()    { get_sys_cpu_rhel; }   # Oracle Linux — пересборка RHEL
get_sys_cpu_rocky()     { get_sys_cpu_rhel; }   # Rocky Linux — пересборка RHEL
get_sys_cpu_almalinux() { get_sys_cpu_rhel; }   # AlmaLinux — пересборка RHEL

# Arch всегда следует последней procps-ng — та же форма вывода, что и у Debian-семьи.
get_sys_cpu_arch() { get_sys_cpu_debian; }

# Alpine — это musl/busybox: вывод `top -bn1` недостаточно стабилен для парсинга
# между версиями busybox, а sysstat/mpstat не входят в базовый образ.
# /proc/stat всё равно остаётся интерфейсом ядра, так что он один и составляет всю пробу —
# запасного варианта с угадыванием формата здесь намеренно нет.
get_sys_cpu_alpine() {
    _sys_cpu_via_procstat
}

# Неизвестный/неподдерживаемый дистрибутив: пробуем всё, что знаем, в порядке надёжности.
get_sys_cpu_generic() {
    _sys_cpu_via_procstat && return 0
    get_sys_cpu_debian && return 0
    get_sys_cpu_rhel
}

# --- 3b-2. Секция CPU (обзор хоста) ------------------------------------------
_sys_cpu() {
    local os usage pkg pct
    local -a top_parts=() pids=()

    os=$(get_os_release)
    case "$os" in
        debian)    usage=$(get_sys_cpu_debian) ;;
        ubuntu)    usage=$(get_sys_cpu_ubuntu) ;;
        astra)     usage=$(get_sys_cpu_astra) ;;
        centos)    usage=$(get_sys_cpu_centos) ;;
        rhel)      usage=$(get_sys_cpu_rhel) ;;
        oracle)    usage=$(get_sys_cpu_oracle) ;;
        rocky)     usage=$(get_sys_cpu_rocky) ;;
        almalinux) usage=$(get_sys_cpu_almalinux) ;;
        arch)      usage=$(get_sys_cpu_arch) ;;
        alpine)    usage=$(get_sys_cpu_alpine) ;;
        *)         usage=$(get_sys_cpu_generic) ;;
    esac

    if [[ "$usage" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
        print_info "cpu: usage=${usage}%"
    else
        print_info "cpu: usage=n/a"
    fi

    while IFS= read -r pkg; do
        [[ -z "$pkg" ]] && continue
        mapfile -t pids < <(_sys_pkg_pids "$pkg")
        pct=$(_sys_pids_pct_sum pcpu "${pids[@]+"${pids[@]}"}")
        [[ -n "$pct" && "$pct" != "0.0" ]] && top_parts+=("${pkg}=${pct}%")
    done < <(_sys_installed_pkgs)

    if [[ ${#top_parts[@]} -gt 0 ]]; then
        print_info "cpu top: $(printf '%s\n' "${top_parts[@]}" | sed 's/%$//' | sort -t= -k2,2nr | sed 's/$/%/' | paste -sd' ' -)"
    else
        print_info "cpu top: n/a"
    fi
}

_sys_memory() {
    local total used avail pct top_parts=() pkg mem
    local -a pids=()
    # Предпочитать /proc/meminfo (стабильные колонки); free -m как запасной вариант
    read -r total used avail < <(awk '
        /MemTotal:/ {t=$2}
        /MemAvailable:/ {a=$2}
        /MemFree:/ {f=$2}
        END {
            if (t+0 > 0) {
                if (a+0 <= 0) a=f
                printf "%d %d %d", int(t/1024), int((t-a)/1024), int(a/1024)
            }
        }' /proc/meminfo 2>/dev/null)
    if [[ -z "$total" || "$total" -eq 0 ]]; then
        read -r total used avail < <(free -m 2>/dev/null | awk '/^Mem:/{print $2, $3, $7}')
    fi
    if [[ -n "$total" && "$total" -gt 0 ]]; then
        pct=$(( used * 100 / total ))
        print_info "memory: total=${total}MB used=${used}MB available=${avail:-n/a}MB (${pct}%)"
    else
        print_info "memory: total=n/a used=n/a available=n/a"
    fi

    while IFS= read -r pkg; do
        [[ -z "$pkg" ]] && continue
        mapfile -t pids < <(_sys_pkg_pids "$pkg")
        mem=$(_sys_pids_pct_sum pmem "${pids[@]+"${pids[@]}"}")
        [[ -n "$mem" && "$mem" != "0.0" ]] && top_parts+=("${pkg}=${mem}%")
    done < <(_sys_installed_pkgs)

    if [[ ${#top_parts[@]} -gt 0 ]]; then
        print_info "memory top: $(printf '%s\n' "${top_parts[@]}" | sed 's/%$//' | sort -t= -k2,2nr | sed 's/$/%/' | paste -sd' ' -)"
    else
        print_info "memory top: n/a"
    fi
}

_sys_disk() {
    local line fs size used avail usep mount count=0 hline hsize hused havail
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        # df -P: столбцы Filesystem 1024-blocks Used Available Capacity Mounted
        fs=$(echo "$line" | awk '{print $1}')
        size=$(echo "$line" | awk '{print $2}')
        used=$(echo "$line" | awk '{print $3}')
        avail=$(echo "$line" | awk '{print $4}')
        usep=$(echo "$line" | awk '{print $5}')
        mount=$(echo "$line" | awk '{print $6}')
        # человекочитаемый вид через df -h для отображения
        hline=$(df -hP "$mount" 2>/dev/null | awk 'NR==2{print}')
        if [[ -n "$hline" ]]; then
            hsize=$(echo "$hline" | awk '{print $2}')
            hused=$(echo "$hline" | awk '{print $3}')
            havail=$(echo "$hline" | awk '{print $4}')
            usep=$(echo "$hline" | awk '{print $5}')
            print_info "disk: $fs $mount $hsize $hused $havail $usep"
        else
            print_info "disk: $fs $mount used=$usep"
        fi
        count=$((count + 1))
    done < <(df -P 2>/dev/null | awk 'NR>1 && $1 ~ /^\/dev\// {print}')

    [[ "$count" -eq 0 ]] && print_info "disk: n/a"
}

_sys_psql() {
    local sql="$1" out="" euid
    euid="${EUID:-$(id -u)}"
    if [[ "$euid" -eq 0 ]]; then
        out=$(sudo -n -u postgres psql -tAc "$sql" 2>/dev/null) || true
    fi
    [[ -z "$out" ]] && out=$(psql -tAc "$sql" 2>/dev/null) || true
    echo "$out" | tr -d '[:space:]'
}

# --- Хелперы кластера PostgreSQL (используются _sys_database ниже) ---------
# Каждая фаза старого монолитного определения получила своё имя: активен ли
# движок, в какой роли он находится и как выглядит его состояние репликации.
# _sys_database() ниже просто связывает результаты вместе.

# Истина, если юнит postgresql активен (обычный, .service, или @-инстанс).
_sys_pg_is_active() {
    command -v systemctl &>/dev/null || return 1
    systemctl is-active --quiet postgresql 2>/dev/null \
        || systemctl is-active --quiet postgresql.service 2>/dev/null \
        || systemctl list-units --type=service --state=running 2>/dev/null | grep -qE 'postgresql(@|-)'
}

# Истина, если активным движком БД является mariadb или mysql (проверяется только
# после того, как postgresql исключён — тот же порядок, что и в оригинале).
_sys_mariadb_is_active() {
    command -v systemctl &>/dev/null || return 1
    systemctl is-active --quiet mariadb 2>/dev/null || systemctl is-active --quiet mysql 2>/dev/null
}

# Печатает "primary" или "standby" через pg_is_in_recovery(); ничего (rc=1), если
# доступ к psql недоступен либо запрос не вернул одно из этих двух значений.
_sys_pg_role() {
    local euid role
    euid="${EUID:-$(id -u)}"
    command -v psql &>/dev/null && [[ "$euid" -eq 0 || -n "${PGUSER:-}" || -n "${PGDATABASE:-}" ]] || return 1
    role=$(_sys_psql "SELECT CASE WHEN pg_is_in_recovery() THEN 'standby' ELSE 'primary' END")
    [[ "$role" == "primary" || "$role" == "standby" ]] || return 1
    echo "$role"
}

# Сводка по репликации для узла primary.
_sys_pg_primary_cluster_info() {
    local n lag
    n=$(_sys_psql "SELECT count(*) FROM pg_stat_replication")
    if [[ ! "$n" =~ ^[0-9]+$ || "$n" -eq 0 ]]; then
        echo "replication=none replicas=0"
        return
    fi
    lag=$(_sys_psql "SELECT COALESCE((EXTRACT(EPOCH FROM MAX(COALESCE(replay_lag, write_lag, flush_lag))))::int, 0) FROM pg_stat_replication")
    if [[ -z "$lag" || ! "$lag" =~ ^[0-9]+$ ]]; then
        lag=$(_sys_psql "SELECT COALESCE(EXTRACT(EPOCH FROM (now()-min(reply_time)))::int,0) FROM pg_stat_replication")
    fi
    [[ -z "$lag" || ! "$lag" =~ ^[0-9]+$ ]] && lag="0"
    echo "replication=ok lag=${lag}s replicas=$n"
}

# Сводка по lag для узла standby, относительно последней воспроизведённой транзакции primary.
_sys_pg_standby_cluster_info() {
    local lag
    lag=$(_sys_psql "SELECT COALESCE(EXTRACT(EPOCH FROM (now()-pg_last_xact_replay_timestamp()))::int, 0)")
    [[ -z "$lag" || ! "$lag" =~ ^[0-9]+$ ]] && lag="n/a"
    if [[ "$lag" == "n/a" ]]; then
        echo "replication=standby lag=n/a"
    else
        echo "replication=standby lag=${lag}s"
    fi
}

_sys_database() {
    local db="n/a" cluster="n/a" role=""

    if _sys_pg_is_active; then
        db="postgresql active"
        role=$(_sys_pg_role)
        if [[ -n "$role" ]]; then
            db="postgresql active ($role)"
            if [[ "$role" == "primary" ]]; then
                cluster=$(_sys_pg_primary_cluster_info)
            else
                cluster=$(_sys_pg_standby_cluster_info)
            fi
        fi
    elif _sys_mariadb_is_active; then
        db="mariadb/mysql active"
    fi

    # Запасной вариант: пакет присутствует, но systemd не определён
    if [[ "$db" == "n/a" ]]; then
        if command -v psql &>/dev/null || [[ -d /var/lib/postgresql ]]; then
            db="postgresql present (service status n/a)"
        elif command -v mysql &>/dev/null || [[ -d /var/lib/mysql ]]; then
            db="mariadb/mysql present (service status n/a)"
        fi
    fi

    print_info "database: $db"
    print_info "cluster_db: $cluster"
}

_sys_network() {
    local interval=1
    local -A rx1=() tx1=()
    local iface line rx tx count=0 rx_mb tx_mb
    local tmp1 tmp2

    tmp1=$(mktemp 2>/dev/null) || tmp1="/tmp/flat_net1.$$"
    tmp2=$(mktemp 2>/dev/null) || tmp2="/tmp/flat_net2.$$"
    grep -E '^\s*[a-zA-Z0-9]+:' /proc/net/dev 2>/dev/null | grep -v 'lo:' > "$tmp1" || true
    sleep "$interval"
    grep -E '^\s*[a-zA-Z0-9]+:' /proc/net/dev 2>/dev/null | grep -v 'lo:' > "$tmp2" || true

    while IFS= read -r line; do
        iface=$(echo "$line" | awk -F: '{gsub(/ /,"",$1); print $1}')
        rx=$(echo "$line" | awk -F: '{print $2}' | awk '{print $1}')
        tx=$(echo "$line" | awk -F: '{print $2}' | awk '{print $9}')
        [[ -n "$iface" ]] || continue
        rx1["$iface"]=$rx
        tx1["$iface"]=$tx
    done < "$tmp1"

    while IFS= read -r line; do
        iface=$(echo "$line" | awk -F: '{gsub(/ /,"",$1); print $1}')
        rx=$(echo "$line" | awk -F: '{print $2}' | awk '{print $1}')
        tx=$(echo "$line" | awk -F: '{print $2}' | awk '{print $9}')
        [[ -n "$iface" && -n "${rx1[$iface]:-}" ]] || continue
        rx_mb=$(awk -v a="${rx1[$iface]}" -v b="$rx" -v t="$interval" 'BEGIN{printf "%.2f", (b-a)/t/1024/1024}')
        tx_mb=$(awk -v a="${tx1[$iface]}" -v b="$tx" -v t="$interval" 'BEGIN{printf "%.2f", (b-a)/t/1024/1024}')
        print_info "network: $iface rx=${rx_mb} MB/s tx=${tx_mb} MB/s"
        count=$((count + 1))
    done < "$tmp2"

    rm -f "$tmp1" "$tmp2" 2>/dev/null
    [[ "$count" -eq 0 ]] && print_info "network: n/a"
}

_sys_certificates() {
    local cert expiry expiry_epoch now_epoch days subject count=0
    local -a roots=(/etc/ssl/certs /etc/nginx/ssl /etc/nginx/certs /opt/flat)
    now_epoch=$(date +%s 2>/dev/null)

    if ! command -v openssl &>/dev/null || [[ -z "$now_epoch" ]]; then
        print_info "cert: n/a"
        return
    fi

    while IFS= read -r -d '' cert; do
        # Пропускаем дампы CA bundle и мусор хешированных директорий: только похожие на конечные имена
        case "$(basename "$cert")" in
            ca-certificates.crt|*.0) continue ;;
        esac
        expiry=$(openssl x509 -enddate -noout -in "$cert" 2>/dev/null | cut -d= -f2-)
        [[ -n "$expiry" ]] || continue
        expiry_epoch=$(date -d "$expiry" +%s 2>/dev/null) || continue
        days=$(( (expiry_epoch - now_epoch) / 86400 ))
        subject=$(openssl x509 -subject -noout -in "$cert" 2>/dev/null | sed 's/^subject=//')
        subject="${subject:-n/a}"
        if [[ "$days" -lt 30 ]]; then
            print_warn "cert: $cert days_left=$days subject=$subject"
        else
            print_info "cert: $cert days_left=$days subject=$subject"
        fi
        count=$((count + 1))
        [[ "$count" -ge 20 ]] && break
    done < <(
        for root in "${roots[@]}"; do
            [[ -d "$root" ]] || continue
            if [[ "$root" == /etc/ssl/certs ]]; then
                # только явно именованные сертификаты, не хеш-симлинки
                find "$root" -maxdepth 1 -type f \( -name '*.crt' -o -name '*.pem' \) ! -name 'ca-certificates.crt' -print0 2>/dev/null
            elif [[ "$root" == /opt/flat ]]; then
                find "$root" -maxdepth 5 \( -path '*/ssl/*' -o -path '*/certs/*' -o -path '*/tls/*' \) \
                    -type f \( -name '*.crt' -o -name '*.pem' \) -print0 2>/dev/null
            else
                find "$root" -maxdepth 3 -type f \( -name '*.crt' -o -name '*.pem' \) -print0 2>/dev/null
            fi
        done
    )

    [[ "$count" -eq 0 ]] && print_info "cert: n/a"
}

_sys_fmt_duration() {
    local sec="$1" d h m
    [[ "$sec" =~ ^[0-9]+$ ]] || { echo "n/a"; return; }
    d=$((sec / 86400))
    h=$(( (sec % 86400) / 3600 ))
    m=$(( (sec % 3600) / 60 ))
    if [[ "$d" -gt 0 ]]; then
        echo "${d}d ${h}h ${m}m (${sec}s)"
    else
        echo "${h}h ${m}m (${sec}s)"
    fi
}

_sys_uptime() {
    local up_sec load_str enter now_epoch pkg ts sec fmt count=0 unit name
    up_sec=$(awk '{print int($1)}' /proc/uptime 2>/dev/null)
    load_str=$(awk -F'load average: ' '{print $2}' < <(uptime 2>/dev/null) | tr -d ' ')
    if [[ -n "$up_sec" ]]; then
        fmt=$(_sys_fmt_duration "$up_sec")
        if [[ -n "$load_str" ]]; then
            print_info "uptime: system=$fmt load=$load_str"
        else
            print_info "uptime: system=$fmt"
        fi
    else
        print_info "uptime: system=n/a"
    fi

    now_epoch=$(date +%s 2>/dev/null)
    if command -v systemctl &>/dev/null && [[ -n "$now_epoch" ]]; then
        while IFS= read -r pkg; do
            [[ -z "$pkg" ]] && continue
            enter=""
            while IFS= read -r name; do
                [[ -z "$name" ]] && continue
                unit="${name}.service"
                systemctl is-active --quiet "$unit" 2>/dev/null || continue
                enter=$(systemctl show "$unit" -p ActiveEnterTimestamp --value 2>/dev/null)
                [[ -n "$enter" && "$enter" != "n/a" && "$enter" != "0" ]] && break
            done < <(_sys_pkg_names "$pkg")
            [[ -z "$enter" || "$enter" == "n/a" || "$enter" == "0" ]] && continue
            ts=$(date -d "$enter" +%s 2>/dev/null) || continue
            sec=$((now_epoch - ts))
            [[ "$sec" -lt 0 ]] && continue
            fmt=$(_sys_fmt_duration "$sec")
            print_info "uptime: ${pkg}=$fmt"
            count=$((count + 1))
        done < <(_sys_installed_pkgs)
    fi
    [[ "$count" -eq 0 ]] && print_info "uptime services: n/a"
}

check_system() {
    local tmpdir pid_disk pid_db pid_net pid_certs f w
    echo "=== System ==="
    tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/flat_sys.XXXXXX" 2>/dev/null) || tmpdir="/tmp/flat_sys.$$"
    mkdir -p "$tmpdir" 2>/dev/null || true
    # Параллельные пробы хоста, пока cpu/memory снимают свои замеры (sleep)
    (_sys_disk > "$tmpdir/disk") &
    pid_disk=$!
    (_sys_database > "$tmpdir/database") &
    pid_db=$!
    (_sys_network > "$tmpdir/network") &
    pid_net=$!
    (_sys_certificates > "$tmpdir/certs") &
    pid_certs=$!
    _sys_cpu
    _sys_memory
    wait "$pid_disk" 2>/dev/null || true
    wait "$pid_db" 2>/dev/null || true
    wait "$pid_net" 2>/dev/null || true
    wait "$pid_certs" 2>/dev/null || true
    # Стабильный порядок для дашборда; восстанавливаем счётчики WARN, потерянные в subshell'ах
    for f in disk database network certs; do
        if [[ -f "$tmpdir/$f" ]]; then
            cat "$tmpdir/$f"
            w=$(grep -c '\[WARN\]' "$tmpdir/$f" 2>/dev/null || true)
            [[ "$w" =~ ^[0-9]+$ ]] && WARNINGS=$((WARNINGS + w))
        fi
    done
    _sys_uptime
    rm -rf -- "$tmpdir" 2>/dev/null
}

