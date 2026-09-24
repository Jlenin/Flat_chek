#!/bin/bash
# flat_check_agent.sh — автономный health/metrics-агент для мониторинга.
#
# Долгоживущий процесс-демон (systemd, Type=simple), без аргументов командной
# строки: всё поведение — переменные окружения и/или flat_check_agent.conf
# рядом со скриптом (см. FLAT_AGENT_CONF ниже).
#
# Схема: три слоя обновляют кеш (каталог cache/ рядом со скриптом) каждый со
# своей периодичностью, курьер раз в METRICS_INTERVAL секунд склеивает кеш в
# полный JSON и отправляет его на PUSH_URLS. Бэку ничего не нужно собирать —
# каждый push полный.
#   full     (FULL_INTERVAL, 3600 с)  — полное обнаружение, пишет весь кеш
#   services (SERVICES_INTERVAL, 60 с) — is-active, MainPID, порты, API
#   metrics  (METRICS_INTERVAL, 5 с)   — CPU/RAM/сеть из /proc
# Подробности — agent/README.md и комментарии у раздела «Кеш» ниже.
#
# ПОТОКИ ВЫВОДА:
#   cache/last_sent.json — ровно то, что ушло последним push'ем;
#   stdout — тот же JSON, но только при ручном запуске в терминале или при
#            PRINT_JSON=1 (под systemd иначе это десятки МБ в journal в час);
#   stderr и LOG_FILE — события демона и результат push.
#
# ПРАВА ДОСТУПА: рассчитан на запуск ОБЫЧНЫМ пользователем, не root.
# Единственное известное исключение — configs[].status="sudoers" (нет "x" на
# /etc/sudoers.d) — деградирует до "missing" без ошибок. Подробности —
# agent/flat_check_agent.sudoers.example.
#
# SCRIPT_VERSION ниже — версия ЭТОГО агента, отдельная от flat_check.sh/
# flat_check_2.sh.

set -uo pipefail

SCRIPT_VERSION="1.0.0"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
[[ -z "$SCRIPT_DIR" ]] && SCRIPT_DIR="$(pwd)"

# ==========================================================================
# Глобальные переменные и дефолты
# ==========================================================================
# LOG_FILE: по тому же образцу, что flat_check.sh/flat_check_2.sh — файл
# рядом с рабочим каталогом продукта, а не встроенный в код путь. У тех
# двух это "${SCRIPT_DIR}/${SCRIPT_NAME}.log" (рядом со скриптом, т.к. это
# разовый прогон); здесь демон долгоживущий, а деплой — /opt/flat/flat-check
# (см. flat-check.service.example), поэтому файл — в соседний с /opt/flat/
# каталог /var/log/flat/flat-check/ (тот же путь, что раньше был жёстко
# прописан в flat-check.service.example как StandardOutput/StandardError).
# _log_line()/_daemon_init_logging() ниже: не удалось создать/писать файл —
# тихо деградирует до LOG_FILE="" (без файла, только stderr) — как и
# init_logging() у flat_check.sh/flat_check_2.sh, без падений.

# Цвета для info/warn/fail на экране (актуально только при ручном запуске
# в терминале — эти сообщения идут в stderr, см. шапку файла).
C_R='\033[0;31m'
C_G='\033[0;32m'
C_Y='\033[1;33m'
C_B='\033[0;34m'
C_C='\033[0;36m'
C_N='\033[0m'

LOG_FILE="${LOG_FILE:-/var/log/flat/flat-check/flat_check_agent.log}"
DEBUG_MODE="${DEBUG_MODE:-0}"

# Идентификация хоста / агента push (приоритет: env > conf-файл > пусто).
HOST_ID="${HOST_ID:-}"
HOST_IP="${HOST_IP:-}"
SERVICE_NAME="${SERVICE_NAME:-}"
PUSH_URLS="${PUSH_URLS:-${PUSH_URL:-}}"
PUSH_TOKEN="${PUSH_TOKEN:-}"
PUSH_TOKENS="${PUSH_TOKENS:-}"
PUSH_AUTH_HEADER="${PUSH_AUTH_HEADER:-Authorization: Bearer}"
# push уходит каждые METRICS_INTERVAL секунд: короткие таймауты и без
# повторов — следующая попытка и так через несколько секунд.
PUSH_CONNECT_TIMEOUT="${PUSH_CONNECT_TIMEOUT:-2}"
PUSH_MAX_TIME="${PUSH_MAX_TIME:-4}"
PUSH_RETRIES="${PUSH_RETRIES:-0}"
PUSH_INSECURE="${PUSH_INSECURE:-0}"

# Демон: интервалы слоёв (секунды). Курьер отправляет с интервалом metrics.
FULL_INTERVAL="${FULL_INTERVAL:-3600}"
SERVICES_INTERVAL="${SERVICES_INTERVAL:-60}"
METRICS_INTERVAL="${METRICS_INTERVAL:-5}"
# 1 — печатать отправляемый JSON в stdout и под systemd (по умолчанию только
# при запуске в терминале).
PRINT_JSON="${PRINT_JSON:-0}"

# Фильтры содержимого JSON (необязательные; пусто = без фильтра, все продукты).
SINGLE_PKG="${SINGLE_PKG:-}"
FILTER_PRODUCT="${FILTER_PRODUCT:-}"
PACKAGES="${PACKAGES:-}"
PRODUCT="${PRODUCT:-}"
VERBOSE="${VERBOSE:-0}"
SHOW_REPO="${SHOW_REPO:-0}"
SHOW_REPOS_JSON="${SHOW_REPOS_JSON:-0}"

# Снимок /proc/stat для расчёта дельты CPU (первый вызов инициализирует).
_CPU_PREV_IDLE=""
_CPU_PREV_TOTAL=""

# ==========================================================================
# Вывод: info/warn/fail — ТОЛЬКО в stderr (не в stdout, как в основном
# инструменте) — здесь это осознанная и единственная содержательная правка
# поведения относительно оригиналов: stdout должен остаться чистым JSON,
# даже когда push_health_json() ниже параллельно печатает диагностику
# каждой попытки. log_debug()/_log_line() — без изменений (их поведение
# и так безопасно: без LOG_FILE они по умолчанию ничего не пишут).
# ==========================================================================
info() { echo -e "${C_B}[INFO]${C_N} $1" >&2; _log_line "INFO" "$1"; }
warn() { echo -e "${C_Y}[WARN]${C_N} $1" >&2; _log_line "WARN" "$1"; }
fail() { echo -e "${C_R}[FAIL]${C_N} $1" >&2; _log_line "FAIL" "$1"; }

# ==========================================================================
# Каталог продуктов/пакетов (_pkg_set/_pkg_catalog_builtin/_load_pkg_catalog)
# ==========================================================================
# Каталог ищется РЯДОМ со скриптом (flat_check.packages.conf), иначе —
# встроенный ниже. Данные каталога те же, что у flat_check.sh/flat_check_2.sh.

# --- 1. Метаданные продуктов PKG_* (каталог) ---------------------------------
# Каталог: flat_check.packages.conf рядом со скриптом (предпочтительно).
# Нет файла → встроенный fallback (_pkg_catalog_builtin). Скрипт не падает.
# Формат строки каталога: _pkg_set NAME PRODUCT [LEGACY] [PORTS] [API] [DEPS]
# Пустые PORTS/API/DEPS не задаём. PKG_DEPS — только непустые (для «кто зависит»
# в авто-разделе Infrastructure при неудовлетворённой зависимости).


declare -A PKG_PORTS
declare -A PKG_API
declare -A PKG_LEGACY
declare -A PKG_PRODUCT
declare -A PKG_DEPS

# ALL_DEPENDS["имя_зависимости"]="pkg1,pkg2"
declare -A ALL_DEPENDS

# Порядок продуктов в human/JSON (Infrastructure — в конце)
FLAT_PRODUCTS_ORDER=(
    "AutoCallServer" "BSS" "Click to Call" "Contact Center" "Device Manager"
    "Gateway" "Partner Server" "SoftSwitch" "Tarifficator" "IVR" "LC" "SMS"
    "LDAP" "SBC" "Portal" "flat-file" "FVSC" "Infrastructure"
)

PKG_CATALOG_SOURCE="internal"
PKG_CATALOG_PATH=""

# NAME PRODUCT [LEGACY] [PORTS] [API] [DEPS] — пустой хвост можно опустить
_pkg_set() {
    local name="$1" product="$2"
    local legacy="${3:-}" ports="${4:-}" api="${5:-}" deps="${6:-}"
    [[ -n "$name" && -n "$product" ]] || return 1
    PKG_PRODUCT["$name"]="$product"
    PKG_LEGACY["$name"]="$legacy"
    [[ -n "$ports" ]] && PKG_PORTS["$name"]="$ports"
    [[ -n "$api" ]] && PKG_API["$name"]="$api"
    [[ -n "$deps" ]] && PKG_DEPS["$name"]="$deps"
    return 0
}

_pkg_catalog_builtin() {
    # shellcheck disable=SC1091
    source /dev/stdin <<'FLAT_PKG_CATALOG_EOF' || true
# ========== AutoCallServer ==========
_pkg_set "acs-frontend" "AutoCallServer" "" "" "" "nginx"
_pkg_set "acs-media" "AutoCallServer" "acs-media" "5060,10000-20000"
_pkg_set "acs-tools" "AutoCallServer" "acs-tools"
_pkg_set "acs-server" "AutoCallServer" "acs-web" "8080"
# ========== BSS ==========
_pkg_set "fcs-bssimp" "BSS" "bssimp"
_pkg_set "fcs-bssexp" "BSS" "bssexpa"
# ========== Click to Call ==========
_pkg_set "c2c-backend" "Click to Call" "" "8080" "/api/health"
_pkg_set "c2c-frontend" "Click to Call" "" "" "" "nginx"
# ========== Contact Center ==========
_pkg_set "fcs-span" "Contact Center"
_pkg_set "fcs-chat" "Contact Center" "fcs-chat-server"
_pkg_set "fcs-contact" "Contact Center" "fcs-flexconnect"
_pkg_set "fcs-contact-db" "Contact Center" "" "" "" "mariadb"
_pkg_set "fcs-contact-db-pg" "Contact Center" "" "" "" "postgresql"
_pkg_set "fcs-recognize" "Contact Center" "flat-contact-recognize"
_pkg_set "fcs-replication" "Contact Center" "fcs-record-replication,flat-record-replication"
_pkg_set "fcs-recordtask" "Contact Center" "fcs-recproc,flat-record-taskservice"
_pkg_set "fcs-screen" "Contact Center" "fcs-screen-record,flat-screen-recording"
_pkg_set "fcs-swau" "Contact Center" "fcs-swau"
_pkg_set "fcs-swau-db" "Contact Center" "" "" "" "mariadb"
_pkg_set "fcs-swau-db-pg" "Contact Center" "" "" "" "postgresql"
_pkg_set "fcs-swiam" "Contact Center" "fcs-swfo,fcs-alarm,flat-contact-alarm"
_pkg_set "fcs-swiam-db" "Contact Center" "" "" "" "mariadb"
_pkg_set "fcs-swiam-db-pg" "Contact Center" "" "" "" "postgresql"
_pkg_set "fcs-swicl" "Contact Center"
_pkg_set "fcs-swiib" "Contact Center"
_pkg_set "fcs-swikc" "Contact Center" "flat-contact-center"
_pkg_set "fcs-swikc-db" "Contact Center" "" "" "" "mariadb"
_pkg_set "fcs-swikc-db-pg" "Contact Center" "" "" "" "postgresql"
_pkg_set "fcs-swiop" "Contact Center" "flat-contact-operator-interface"
_pkg_set "fcs-swir" "Contact Center" "flat-contact-recording"
_pkg_set "fcs-swir-db" "Contact Center" "" "" "" "mariadb"
_pkg_set "fcs-swir-db-pg" "Contact Center" "" "" "" "postgresql"
_pkg_set "fcs-swui" "Contact Center" "flat-constact-system-of-analytics"
_pkg_set "fcs-swui-db" "Contact Center" "data-base-system-analytics" "" "" "mariadb"
_pkg_set "fcs-unigy" "Contact Center" "fcs-unigy-connector"
_pkg_set "frec-frontend" "Contact Center" "" "" "" "nginx"
_pkg_set "frec-backend" "Contact Center" "flat-recording-backend"
_pkg_set "fcs-record-export" "Contact Center" "flat-record-export-service"
_pkg_set "fcs-recognition" "Contact Center" "asr"
_pkg_set "asr-backend" "Contact Center"
_pkg_set "asr-analytics" "Contact Center"
# ========== Device Manager ==========
_pkg_set "fdm-server" "Device Manager" "fdm-server"
_pkg_set "fcc-frontend" "Device Manager" "" "" "" "nginx"
_pkg_set "fcc-backend" "Device Manager"
# ========== Gateway ==========
_pkg_set "fg-frontend" "Gateway" "" "" "" "nginx"
_pkg_set "fg-backend" "Gateway"
# ========== Partner Server ==========
_pkg_set "fps-backend" "Partner Server" "flatPartnerAuth"
_pkg_set "fps-profile" "Partner Server" "flatImageProcessor"
_pkg_set "fps-frontend" "Partner Server" "flatPartnerFrontend" "" "" "nginx"
_pkg_set "fps-license" "Partner Server" "flatPartnerLicense"
_pkg_set "fps-admin" "Partner Server" "flatPartnerLicenseAdmin"
_pkg_set "fps-agent" "Partner Server" "flatPartnerLicenseAgent"
_pkg_set "fps-server" "Partner Server" "flatPartnerServer"
_pkg_set "fps-push" "Partner Server" "flatPushNotificationServer"
_pkg_set "fps-control" "Partner Server" "flatPartnerFLC"
_pkg_set "fps-phonebook" "Partner Server"
# ========== SoftSwitch ==========
_pkg_set "fss-frontend" "SoftSwitch" "softswitch-frontend" "" "" "nginx"
_pkg_set "fss-backend" "SoftSwitch" "flatSoftSwitchBackend" "8082" "/api/health" "postgresql"
_pkg_set "fss-mediasrv" "SoftSwitch" "mediasrv" "5060,10000-20000"
_pkg_set "fss-srclient" "SoftSwitch" "srclient" "" "" "fss-server"
_pkg_set "fss-server" "SoftSwitch" "" "8080,8081" "/api/v1/health" "nginx,postgresql"
_pkg_set "fss-web" "SoftSwitch" "fss-web" "" "" "nginx"
_pkg_set "fss-csta" "SoftSwitch" "csta-rest-broker"
_pkg_set "fss-capagent" "SoftSwitch" "flat-capagent"
# ========== Tarifficator ==========
_pkg_set "ftr-frontend" "Tarifficator" "tarifficator-frontend" "" "" "nginx"
_pkg_set "ftr-server" "Tarifficator"
_pkg_set "ftr-backend" "Tarifficator"
_pkg_set "ftr-server-db" "Tarifficator" "" "" "" "mariadb"
_pkg_set "ftr-server-db-pg" "Tarifficator" "" "" "" "postgresql"
_pkg_set "ftr-web" "Tarifficator" "" "" "" "nginx"
# ========== IVR ==========
_pkg_set "ivr-frontend" "IVR" "" "" "" "nginx"
_pkg_set "ivr-backend" "IVR" "flatIVRBuilder"
# ========== LC ==========
_pkg_set "lc-frontend" "LC" "lc-softswitch-frontend" "" "" "nginx"
_pkg_set "lc-backend" "LC" "flatSoftSwitchLK"
# ========== SMS ==========
_pkg_set "flat-sms" "SMS"
_pkg_set "flat-smpp" "SMS"
# ========== LDAP ==========
_pkg_set "fbr-frontend" "LDAP" "fpbf-frontend" "" "" "nginx"
_pkg_set "fbr-backend" "LDAP" "flatPartnerBroker,flat-broker"
_pkg_set "flat-ldap" "LDAP" "ldapSynchronizer"
_pkg_set "flat-broker" "LDAP"
_pkg_set "flat-transfer-server" "LDAP"
# ========== SBC ==========
_pkg_set "sbc-backend" "SBC" "flat.sbc.backend"
_pkg_set "sbc-core" "SBC" "flat.sbc.core"
_pkg_set "sbc-frontend" "SBC" "" "" "" "nginx"
# ========== Portal ==========
_pkg_set "fpl-backend" "Portal"
_pkg_set "fpl-frontend" "Portal" "" "" "" "nginx"
_pkg_set "fpl2-frontend" "Portal" "" "" "" "nginx"
_pkg_set "fsft-frontend" "Portal" "" "" "" "nginx"
# ========== flat-file ==========
_pkg_set "flat-file" "flat-file" "flatFileManager,fss-file" "8083" "/api/health" "nginx"
# ========== Contact Center ==========
_pkg_set "fc-frontend" "Contact Center" "" "" "" "nginx"
_pkg_set "fc-backend" "Contact Center"
# ========== Partner Server ==========
_pkg_set "fpw-frontend" "Partner Server" "" "" "" "nginx"
# ========== FVSC ==========
_pkg_set "fvcs-backend" "FVSC"
_pkg_set "fvcs-frontend" "FVSC" "" "" "" "nginx"
_pkg_set "fvcs-live-asr" "FVSC"
_pkg_set "fvcs-live-core" "FVSC"
_pkg_set "fvcs-asr" "FVSC"
_pkg_set "fvcs-record" "FVSC"
# ========== Infrastructure ==========
_pkg_set "nginx" "Infrastructure"
_pkg_set "postgresql" "Infrastructure"
# Debian/Ubuntu/Astra не поставляют пакет с именем "mariadb" — только mariadb-server;
# без legacy is_pkg_installed_tiny() всегда возвращал "не установлен" даже при наличии сервера.
_pkg_set "mariadb" "Infrastructure" "mariadb-server,mysql-server"
FLAT_PKG_CATALOG_EOF
}

_load_pkg_catalog() {
    local conf="${SCRIPT_DIR:-.}/flat_check.packages.conf"
    unset PKG_PRODUCT PKG_LEGACY PKG_PORTS PKG_API PKG_DEPS 2>/dev/null || true
    declare -gA PKG_PRODUCT PKG_LEGACY PKG_PORTS PKG_API PKG_DEPS
    if [[ -f "$conf" && -r "$conf" ]]; then
        # shellcheck disable=SC1090
        source "$conf"
        PKG_CATALOG_SOURCE="external"
        PKG_CATALOG_PATH="$conf"
    else
        _pkg_catalog_builtin
        PKG_CATALOG_SOURCE="internal"
        PKG_CATALOG_PATH=""
    fi
}


_load_pkg_catalog

# ==========================================================================
# Низкоуровневые примитивы: вывод/лог, ОС-детект, CPU/PID, PM-запросы
# ==========================================================================
# Логика проверок — та же, что у flat_check.sh/flat_check_2.sh.

_log_line() {
    [[ -n "${LOG_FILE:-}" ]] || return 0
    # Группа скобок обязательна: если каталог LOG_FILE уже исчез (сборщик
    # только что заархивировал и удалил WORK_DIR), сам bash печатает "No such
    # file or directory" в свой stderr при настройке редиректа >> — до того,
    # как успевает сработать 2>/dev/null самой команды printf.
    local ts
    printf -v ts '%(%Y-%m-%d %H:%M:%S)T' -1
    { printf '%s [%-5s] %s\n' "$ts" "$1" "$2" >> "$LOG_FILE"; } 2>/dev/null
}

# DEBUG — только при DEBUG_MODE=1 (и в файл, и на экран).
log_debug() {
    [[ "${DEBUG_MODE:-0}" -eq 1 ]] || return 0
    _log_line "DEBUG" "$1"
    echo -e "${C_C}[DEBUG]${C_N} $1" >&2
}

detect_os() {
    OS_NAME="Unknown"
    OS_ID="unknown"
    OS_VERSION=""
    OS_FULL_VER=""

    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        OS_NAME="$NAME"
        OS_ID="$ID"
        OS_VERSION="${VERSION_ID:-}"
        OS_FULL_VER="${PRETTY_NAME:-$NAME}"
    fi

    # Специфичные для дистрибутива файлы версий для более точного определения релиза
    local ver_files=(
        "/etc/astra_version"
        "/etc/centos-release"
        "/etc/redhat-release"
        "/etc/oracle-release"
        "/etc/rocky-release"
        "/etc/almalinux-release"
        "/etc/alpine-release"
        "/etc/arch-release"
        "/etc/debian_version"
    )
    for vf in "${ver_files[@]}"; do
        [[ -f "$vf" ]] || continue
        local ver_content
        ver_content=$(head -1 "$vf" 2>/dev/null | tr -d '\n')
        [[ -z "$ver_content" ]] && continue
        # Обновить OS_NAME из файла релиза, если ещё не определено
        if [[ "$OS_NAME" == "Unknown" ]]; then
            OS_NAME=$(echo "$ver_content" | sed 's/ release.*//' | sed 's/ Linux//')
        fi
        # Извлечь номер версии
        local ver_num
        ver_num=$(echo "$ver_content" | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1)
        [[ -n "$ver_num" ]] && OS_FULL_VER="$OS_NAME $ver_num"
        # Для Debian /etc/debian_version содержит только номер
        if [[ "$vf" == "/etc/debian_version" && -z "$ver_num" ]]; then
            ver_num=$(echo "$ver_content" | grep -oE '[0-9]+(\.[0-9]+)?' | head -1)
            [[ -n "$ver_num" ]] && OS_FULL_VER="$OS_NAME $ver_num"
        fi
        break
    done

    [[ -z "$OS_FULL_VER" ]] && OS_FULL_VER="${OS_NAME} ${OS_VERSION}"

    if command -v dpkg &>/dev/null; then
        PM="dpkg"
    elif command -v rpm &>/dev/null; then
        PM="rpm"
    elif command -v pacman &>/dev/null; then
        PM="pacman"
    elif command -v apk &>/dev/null; then
        PM="apk"
    else
        PM="unknown"
    fi
}

_sys_regex_escape() {
    printf '%s' "$1" | sed 's/[][(){}.^$*+?|\\]/\\&/g'
}

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

get_pkg_depends_dpkg() {
    local pkg="$1" deps=""

    dpkg-query -W -f='${Status}\n' "$pkg" 2>/dev/null | grep -q 'install ok installed' || return
    deps=$(dpkg -s "$pkg" 2>/dev/null | grep "^Depends:" | sed 's/^Depends: //')
    if [[ -z "$deps" ]]; then
        deps=$(apt-cache depends "$pkg" 2>/dev/null | grep -E "^\s+Depends:" | sed 's/.*Depends: //' | tr '\n' ', ' | sed 's/, $//')
    fi
    echo "$deps"
}

get_pkg_depends_rpm() {
    local pkg="$1" deps=""

    rpm -q "$pkg" &>/dev/null || return
    deps=$(rpm -qR "$pkg" 2>/dev/null | grep -v "^rpmlib(" | grep -v "^/" | grep -v "^config" | grep -v "^config(" | grep -vi "^package" | grep -vi "^пакет" | sed 's/ .*$//' | sort -u | tr '\n' ', ' | sed 's/, $//')
    echo "$deps"
}

get_pkg_depends() {
    local pkg="$1"
    local deps=""

    case "$PM" in
        dpkg) deps=$(get_pkg_depends_dpkg "$pkg") ;;
        rpm)  deps=$(get_pkg_depends_rpm "$pkg") ;;
    esac

    # Очистка: убрать версионные ограничения, альтернативы, оставить только имена пакетов
    echo "$deps" | tr ',' '\n' | sed 's/|.*$//' | sed 's/([^)]*)//g' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | grep -v '^$' | grep -v '^[0-9]' | grep -v '^(' | grep -v '^)' | grep -v '^<' | grep -v '^>' | grep -v '^=' | sort -u | tr '\n' ',' | sed 's/^,//;s/,$//'
}

_pkg_version_dpkg() {
    dpkg-query -W -f='${Version}' "$1" 2>/dev/null
}

_pkg_version_rpm() {
    rpm -q --queryformat '%{VERSION}-%{RELEASE}' "$1" 2>/dev/null
}

_pkg_version_pacman() {
    pacman -Q "$1" 2>/dev/null | awk '{print $2}'
}

_pkg_version() {
    local name="$1" ver=""

    case "$PM" in
        dpkg)   ver=$(_pkg_version_dpkg "$name") ;;
        rpm)    ver=$(_pkg_version_rpm "$name") ;;
        pacman) ver=$(_pkg_version_pacman "$name") ;;
    esac

    echo "$ver"
}

get_dep_version() { _pkg_version "$1"; }

_dep_installed_dpkg() {
    dpkg-query -W -f='${Status}\n' "$1" 2>/dev/null | grep -q 'install ok installed'
}

_dep_installed_rpm() {
    rpm -q "$1" &>/dev/null
}

_dep_installed_pacman() {
    pacman -Q "$1" &>/dev/null
}

is_dep_installed() {
    local dep="$1"
    case "$PM" in
        dpkg)   _dep_installed_dpkg "$dep" ;;
        rpm)    _dep_installed_rpm "$dep" ;;
        pacman) _dep_installed_pacman "$dep" ;;
        *)      return 1 ;;
    esac
}

is_lib_available() {
    local lib="$1"
    for path in /usr/lib64 /lib64 /usr/lib /lib; do
        [[ -f "$path/$lib" ]] && return 0
    done
    return 1
}

# Каталог /opt/flat/${pkg} сюда сознательно НЕ входит: после `apt purge`
# каталог часто остаётся (dpkg предупреждает "not empty so not removed",
# если внутри лежат данные пакета — рекординги, БД и т.п.), из-за чего
# purge-нутый пакет ошибочно опознавался бы как всё ещё установленный.
# Unit-файл — обычный файл, которым владеет пакет, и он всегда удаляется
# при purge, поэтому остаётся надёжным сигналом.
has_any_trace() {
    local pkg="$1"
    local unit="${pkg}.service"
    [[ -f "/usr/lib/systemd/system/${unit}" ]] || [[ -f "/etc/systemd/system/${unit}" ]] || [[ -f "/lib/systemd/system/${unit}" ]]
}

is_pkg_installed_tiny_dpkg() {
    local pkg="$1" legacy="$2" old

    dpkg-query -W -f='${Status}\n' "$pkg" 2>/dev/null | grep -q 'install ok installed' && return 0
    for old in $(echo "$legacy" | tr ',' ' '); do
        dpkg-query -W -f='${Status}\n' "$old" 2>/dev/null | grep -q 'install ok installed' && return 0
    done
    return 1
}

is_pkg_installed_tiny_rpm() {
    local pkg="$1" legacy="$2" old

    rpm -q "$pkg" &>/dev/null && return 0
    for old in $(echo "$legacy" | tr ',' ' '); do
        rpm -q "$old" &>/dev/null && return 0
    done
    return 1
}

is_pkg_installed_tiny_pacman() {
    local pkg="$1" legacy="$2" old

    pacman -Q "$pkg" &>/dev/null && return 0
    for old in $(echo "$legacy" | tr ',' ' '); do
        pacman -Q "$old" &>/dev/null && return 0
    done
    return 1
}

is_pkg_installed_tiny_apk() {
    local pkg="$1"
    apk info -e "$pkg" &>/dev/null && return 0
    return 1
}

is_pkg_installed_tiny() {
    local pkg="$1"
    local legacy="$2"

    case "$PM" in
        dpkg)   is_pkg_installed_tiny_dpkg "$pkg" "$legacy" && return 0 ;;
        rpm)    is_pkg_installed_tiny_rpm "$pkg" "$legacy" && return 0 ;;
        pacman) is_pkg_installed_tiny_pacman "$pkg" "$legacy" && return 0 ;;
        apk)    is_pkg_installed_tiny_apk "$pkg" && return 0 ;;
    esac

    # Проверить следы (unit-файл или директория /opt/flat)
    has_any_trace "$pkg" && return 0
    return 1
}

register_dep() {
    local dep="$1"
    local pkg="$2"
    dep="${dep#"${dep%%[![:space:]]*}"}"
    dep="${dep%"${dep##*[![:space:]]}"}"
    [[ -z "$dep" ]] && return

    # Пропускаем непакетные зависимости (файлы, пути, версионные строки, сам пакет, config, RPM capabilities)
    [[ "$dep" == /* ]] && return
    [[ "$dep" == *"("* ]] && return
    [[ "$dep" == *"|"* ]] && return
    [[ "$dep" == *" "* ]] && return
    [[ "$dep" == "config" ]] && return
    [[ "$dep" == "$pkg" ]] && return
    [[ "$dep" == "rtld" ]] && return
    [[ "$dep" == "пакет" ]] && return
    [[ "$dep" == "Пакет" ]] && return
    [[ "$dep" == "package" ]] && return
    [[ "$dep" == "Package" ]] && return

    log_debug "register_dep: dep='$dep' pkg='$pkg'"
    local existing="${ALL_DEPENDS[$dep]:-}"
    if [[ -n "$existing" ]]; then
        if [[ ",${existing}," != *",$pkg,"* ]]; then
            ALL_DEPENDS[$dep]="${existing},$pkg"
        fi
    else
        ALL_DEPENDS[$dep]="$pkg"
    fi
}

_is_infrastructure_pkg() {
    [[ "${PKG_PRODUCT[$1]:-}" == "Infrastructure" ]]
}

# ==========================================================================
# Конфиг агента
# ==========================================================================

# Дефолты (не затираем значения из section 0 / окружения)

: "${SINGLE_PKG:=}"
: "${FILTER_PRODUCT:=}"
: "${HOST_ID:=}"
: "${HOST_IP:=}"
: "${SERVICE_NAME:=}"
: "${PUSH_URLS:=${PUSH_URL:-}}"
: "${PUSH_TOKEN:=}"
: "${PUSH_TOKENS:=}"
: "${PUSH_AUTH_HEADER:=Authorization: Bearer}"
: "${PUSH_CONNECT_TIMEOUT:=2}"
: "${PUSH_MAX_TIME:=4}"
: "${PUSH_RETRIES:=0}"
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
                FULL_INTERVAL|SERVICES_INTERVAL|METRICS_INTERVAL)
                    [[ "$val" =~ ^[1-9][0-9]*$ ]] && printf -v "$key" '%s' "$val"
                    ;;
                PRINT_JSON)
                    [[ "$val" =~ ^[01]$ ]] && PRINT_JSON="$val"
                    ;;
                # Без guard'а [[ -z ]], в отличие от остальных ключей выше:
                # LOG_FILE уже непустой по дефолту (см. секцию 0), поэтому
                # guard никогда бы не сработал и конфиг не мог бы ни сменить
                # путь, ни явно отключить файловый лог (LOG_FILE="" в конфиге).
                LOG_FILE) LOG_FILE="$val" ;;
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

# ==========================================================================
# JSON-кирпичики и время — без подоболочек
# ==========================================================================
# Горячие пути (metrics, курьер — каждые METRICS_INTERVAL секунд) не должны
# порождать процессы: `x=$(f)` — это fork всего bash ради одной строки
# (замер: 1000 вызовов $(_json_esc) — 643 мс и 1000 процессов, тот же код
# через printf -v — 16 мс и 0). Поэтому здесь функции пишут результат в
# переменную, имя которой передано первым аргументом (printf -v), а время
# берётся встроенным printf '%(...)T', а не внешним date.

_json_esc_to() {
    local s="${2:-}"
    s=${s//\\/\\\\}
    s=${s//\"/\\\"}
    s=${s//$'\n'/\\n}
    s=${s//$'\r'/\\r}
    s=${s//$'\t'/\\t}
    printf -v "$1" '%s' "$s"
}

_json_esc() {
    local _e
    _json_esc_to _e "${1:-}"
    printf '%s' "$_e"
}

_json_arr_from_csv() {
    local csv="${1:-}" first=1 item e
    local -a items
    printf '['
    IFS=',' read -ra items <<< "$csv"
    for item in "${items[@]}"; do
        item="${item#"${item%%[![:space:]]*}"}"
        item="${item%"${item##*[![:space:]]}"}"
        [[ -z "$item" ]] && continue
        [[ $first -eq 1 ]] || printf ','
        first=0
        _json_esc_to e "$item"
        printf '"%s"' "$e"
    done
    printf ']'
}

_epoch_to() { printf -v "$1" '%(%s)T' -1; }

_iso_utc_to() {
    # -x обязателен: bash перечитывает часовой пояс только при смене
    # ЭКСПОРТИРОВАННОГО TZ. Без него на хосте с МСК время уходило местным
    # с суффиксом Z (на 3 часа "в будущем").
    local -x TZ=UTC0
    printf -v "$1" '%(%Y-%m-%dT%H:%M:%SZ)T' "$2"
}

# Пауза без внешнего sleep: read с таймаутом на пустом канале, который
# никто никогда не пишет. Сигнал (SIGTERM) такое ожидание не прерывает —
# останов демона наступает по истечении текущей паузы (не дольше
# METRICS_INTERVAL секунд).
_WAIT_FD=""
_wait_seconds() {
    [[ -n "$_WAIT_FD" ]] || exec {_WAIT_FD}<> <(:)
    read -r -t "$1" -u "$_WAIT_FD" _ 2>/dev/null
    return 0
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

# ==========================================================================
# Кеш: каталог cache/ рядом со скриптом, у каждого файла ОДИН писатель
# ==========================================================================
#   full.cache      — пишет только слой full (раз в FULL_INTERVAL): всё,
#                     включая начальные значения services- и metrics-частей
#   services.cache  — пишет только слой services (раз в SERVICES_INTERVAL)
#   metrics.cache   — пишет только слой metrics (раз в METRICS_INTERVAL)
#   last_sent.json  — пишет только курьер: ровно то, что ушло последним
#                     push'ем (для разбора «что отправилось перед падением»)
#
# Один писатель на файл — блокировки не нужны. full/services пишут во
# временный файл и переименовывают его поверх старого (rename(2) атомарен:
# читатель видит либо целую старую версию, либо целую новую). metrics пишет
# на месте: его единственный читатель — курьер в том же процессе, строго
# после записи.
#
# Формат файлов слоёв — не JSON, а строки "ключ<TAB>значение", где значение —
# готовый JSON-фрагмент. Первая строка всегда updated_at<TAB><epoch>,
# последняя — end<TAB>1 (без неё файл считается битым/недописанным). Так
# курьер собирает итоговый JSON склейкой строк, без разбора JSON и без
# единого внешнего процесса.
#
# Кто главнее при склейке: для каждой части берётся слой, чей updated_at
# новее. updated_at у full — момент СТАРТА прогона (данные не моложе его),
# поэтому свежие services/metrics, записанные за время долгого full, не
# откатываются назад его результатом.

CACHE_DIR="$SCRIPT_DIR/cache"
_CACHE_FULL="$CACHE_DIR/full.cache"
_CACHE_SERVICES="$CACHE_DIR/services.cache"
_CACHE_METRICS="$CACHE_DIR/metrics.cache"
_CACHE_SENT="$CACHE_DIR/last_sent.json"

# Пишет глобальный массив _W в файл. $2=1 — атомарно (tmp + mv).
_cache_write() {
    local path="$1" atomic="${2:-1}" tmp="$1" k
    [[ "$atomic" == 1 ]] && tmp="${path}.tmp.${BASHPID}"
    {
        printf 'updated_at\t%s\n' "${_W[updated_at]}"
        for k in "${!_W[@]}"; do
            [[ "$k" == updated_at ]] && continue
            printf '%s\t%s\n' "$k" "${_W[$k]}"
        done
        printf 'end\t1\n'
    } > "$tmp" 2>/dev/null || return 1
    if [[ "$atomic" == 1 ]]; then
        mv -f "$tmp" "$path" 2>/dev/null || return 1
    fi
    return 0
}

# Читает файл слоя в ассоциативный массив с именем $2 (должен быть объявлен
# и пуст). 0 — файл целый: первая строка updated_at, последняя end.
_cache_read() {
    local path="$1" dst="$2" k v first=1 ok=0
    [[ -s "$path" ]] || return 1
    while IFS=$'\t' read -r k v; do
        if [[ $first -eq 1 ]]; then
            [[ "$k" == updated_at && "$v" =~ ^[0-9]+$ ]] || return 1
            first=0
        fi
        if [[ "$k" == end ]]; then
            ok=1
            continue
        fi
        [[ -n "$k" ]] && printf -v "${dst}[$k]" '%s' "$v"
    done 2>/dev/null < "$path"
    [[ $ok -eq 1 ]]
}

# ==========================================================================
# Общие проверки (используют full и services)
# ==========================================================================

# issues[] копятся в строках _ISS_<kind> (JSON-объекты через запятую) и
# счётчиках _ISS_<kind>_E/_W. kind: static — проверки слоя full (unit-файл,
# is-enabled, каталоги, nginx), dynamic — проверки, которые обновляет
# services (is-active, порты, API).
_issues_reset() {
    local k
    for k in "$@"; do
        printf -v "_ISS_$k" '%s' ''
        printf -v "_ISS_${k}_E" '%s' 0
        printf -v "_ISS_${k}_W" '%s' 0
    done
}

_issue_add() {
    local kind="$1" sev="$2" pkg="$3" code="$4" msg="$5"
    local lst="_ISS_$1" cnt e_pkg e_prod e_msg obj
    _json_esc_to e_pkg "$pkg"
    _json_esc_to e_prod "${PKG_PRODUCT[$pkg]:-}"
    _json_esc_to e_msg "$msg"
    obj="{\"severity\":\"$sev\",\"package\":\"$e_pkg\",\"product\":\"$e_prod\",\"code\":\"$code\",\"message\":\"$e_msg\"}"
    if [[ -n "${!lst}" ]]; then
        printf -v "$lst" '%s,%s' "${!lst}" "$obj"
    else
        printf -v "$lst" '%s' "$obj"
    fi
    if [[ "$sev" == error ]]; then cnt="_ISS_${kind}_E"; else cnt="_ISS_${kind}_W"; fi
    printf -v "$cnt" '%d' "$(( ${!cnt} + 1 ))"
}

# Состояние набора systemd-юнитов ОДНИМ вызовом systemctl show (вместо
# is-active/is-enabled/show MainPID на каждый юнит) → _SD_LOAD/_SD_ACT/
# _SD_EN/_SD_PID/_SD_ENTER[имя, как передано]. Блоки в выводе идут в том же
# порядке, что имена в аргументах, через пустую строку. Если число блоков не
# сошлось (systemctl отверг какое-то имя) — повторяем по одному юниту.
_SD_PROPS=(-p LoadState -p ActiveState -p UnitFileState -p MainPID -p ActiveEnterTimestamp)

_systemd_parse() {
    local out="$1" line k v i=0 have=0
    shift
    local -a names=("$@")
    while IFS= read -r line; do
        if [[ -z "$line" ]]; then
            [[ $have -eq 1 ]] && { i=$((i + 1)); have=0; }
            continue
        fi
        [[ $i -lt ${#names[@]} ]] || return 1
        k="${line%%=*}"
        v="${line#*=}"
        case "$k" in
            LoadState) _SD_LOAD["${names[i]}"]="$v" ;;
            ActiveState) _SD_ACT["${names[i]}"]="$v" ;;
            UnitFileState) _SD_EN["${names[i]}"]="$v" ;;
            MainPID) _SD_PID["${names[i]}"]="$v" ;;
            ActiveEnterTimestamp) _SD_ENTER["${names[i]}"]="$v" ;;
        esac
        have=1
    done <<< "$out"
    [[ $have -eq 1 ]] && i=$((i + 1))
    [[ $i -eq ${#names[@]} ]]
}

_systemd_batch() {
    declare -gA _SD_LOAD=() _SD_ACT=() _SD_EN=() _SD_PID=() _SD_ENTER=()
    [[ $# -gt 0 ]] || return 0
    command -v systemctl >/dev/null 2>&1 || return 1
    local out n
    out=$(systemctl show "${_SD_PROPS[@]}" -- "$@" 2>/dev/null)
    [[ -n "$out" ]] || return 1
    _systemd_parse "$out" "$@" && return 0
    declare -gA _SD_LOAD=() _SD_ACT=() _SD_EN=() _SD_PID=() _SD_ENTER=()
    for n in "$@"; do
        out=$(systemctl show "${_SD_PROPS[@]}" -- "$n" 2>/dev/null)
        [[ -n "$out" ]] && _systemd_parse "$out" "$n"
    done
    return 0
}

# Слушающие порты — ОДИН вызов ss (или netstat) на весь прогон слоя.
_ports_snapshot() {
    _LISTEN=""
    if command -v ss >/dev/null 2>&1; then
        _LISTEN=$(ss -lntu 2>/dev/null)
    elif command -v netstat >/dev/null 2>&1; then
        _LISTEN=$(netstat -lntu 2>/dev/null)
    fi
    _LISTEN+=$'\n'
}

_port_listening() {
    local p="${1%%-*}"
    [[ "$p" =~ ^[0-9]+$ ]] || return 1
    [[ "$_LISTEN" =~ :${p}[^0-9A-Za-z_] ]]
}

_unit_path_to() {
    local d
    printf -v "$1" '%s' ""
    for d in /usr/lib/systemd/system /lib/systemd/system /etc/systemd/system; do
        if [[ -f "$d/$2" ]]; then
            printf -v "$1" '%s' "$d/$2"
            return 0
        fi
    done
    return 1
}

# "PID аргументы" процесса из /proc/<pid>/cmdline — без ps.
_proc_cmdline_to() {
    local pid="$2" a s=""
    while IFS= read -r -d '' a || [[ -n "$a" ]]; do
        s+="${s:+ }$a"
    done 2>/dev/null < "/proc/$pid/cmdline"
    if [[ -z "$s" ]]; then
        read -r s 2>/dev/null < "/proc/$pid/comm"
        s="[$s]"
    fi
    printf -v "$1" '%s %s' "$pid" "$s"
}

# process пакета по списку PID'ов (через запятую): мёртвые и повторы
# отбрасываются, ps_lines — до 5 строк → _W[pkg.<p>.process], _W[pkg.<p>.pids].
_pkg_process() {
    local pkg="$1" pid list="" pl="" n=0 line e st="not running"
    local -a arr
    local -A seen=()
    IFS=',' read -ra arr <<< "$2"
    for pid in "${arr[@]}"; do
        [[ "$pid" =~ ^[1-9][0-9]*$ && -z "${seen[$pid]:-}" ]] || continue
        seen[$pid]=1
        # Нет процесса или зомби (завершился, но ещё не убран родителем) — не живой.
        read -r line 2>/dev/null < "/proc/$pid/stat" || continue
        [[ "${line##*) }" == Z* ]] && continue
        list+="${list:+,}$pid"
        if [[ $n -lt 5 ]]; then
            _proc_cmdline_to line "$pid"
            _json_esc_to e "$line"
            pl+="${pl:+,}\"$e\""
            n=$((n + 1))
        fi
    done
    [[ -n "$list" ]] && st="running"
    _W["pkg.$pkg.process"]="{\"status\":\"$st\",\"pids\":[$list],\"ps_lines\":[$pl]}"
    _W["pkg.$pkg.pids"]="$list"
}

# API-эндпоинт пакета из каталога → _API_URL/_API_CODE/_API_STATUS.
# 1 — у пакета нет API.
_api_check() {
    local pkg="$1" ep="${PKG_API[$1]:-}" ports="${PKG_PORTS[$1]:-}" code
    _API_URL=""
    _API_CODE=0
    _API_STATUS="n/a"
    [[ -n "$ep" ]] || return 1
    if [[ "$ep" == http://* || "$ep" == https://* ]]; then
        _API_URL="$ep"
    elif [[ -z "$ports" || "$ports" == *","* || "$ports" == *"-"* ]]; then
        _API_URL="http://localhost$ep"
    else
        _API_URL="http://localhost:${ports}$ep"
    fi
    if command -v curl >/dev/null 2>&1; then
        code=$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 2 --max-time 5 "$_API_URL" 2>/dev/null) || true
        [[ "$code" =~ ^[0-9]{3}$ ]] || code=0
        _API_CODE=$((10#$code))
        if [[ $_API_CODE -eq 200 || $_API_CODE -eq 204 ]]; then _API_STATUS="ok"; else _API_STATUS="fail"; fi
    else
        _API_STATUS="curl_not_found"
    fi
    return 0
}

# Живая часть пакета: systemd (is-active), порты, API + dynamic-issues →
# _W[pkg.<p>.systemd|ports|api]. Одна и та же функция у full и services.
_pkg_dynamic() {
    local pkg="$1" active="${2:-}" unit="${1}.service" unit_path spec open ports="" e1 e2 e3 is_infra=0
    local -a specs
    _is_infrastructure_pkg "$pkg" && is_infra=1
    [[ -n "$active" ]] || active="unknown"
    _unit_path_to unit_path "$unit"
    _json_esc_to e1 "$unit_path"
    _json_esc_to e2 "$unit"
    _json_esc_to e3 "$active"
    _W["pkg.$pkg.systemd"]="{\"unit_path\":\"$e1\",\"service_name\":\"$e2\",\"status\":\"$e3\"}"
    if [[ $is_infra -eq 0 && -n "$unit_path" && "$active" != "active" ]]; then
        _issue_add dynamic error "$pkg" systemd_inactive "systemd: $unit is $active"
    fi

    IFS=',' read -ra specs <<< "${PKG_PORTS[$pkg]:-}"
    for spec in "${specs[@]}"; do
        [[ -z "$spec" ]] && continue
        open="not listening"
        _port_listening "$spec" && open="listening"
        [[ "$open" == "not listening" && $is_infra -eq 0 ]] && _issue_add dynamic warning "$pkg" port_not_listening "port: $spec not listening"
        _json_esc_to e1 "$spec"
        ports+="${ports:+,}{\"number\":\"$e1\",\"status\":\"$open\"}"
    done
    _W["pkg.$pkg.ports"]="[$ports]"

    if _api_check "$pkg"; then
        [[ "$_API_STATUS" != "ok" && $is_infra -eq 0 ]] && _issue_add dynamic warning "$pkg" api_unhealthy "api: $_API_URL => $_API_STATUS"
    fi
    _json_esc_to e1 "$_API_URL"
    _W["pkg.$pkg.api"]="{\"url\":\"$e1\",\"status_code\":${_API_CODE},\"status\":\"$_API_STATUS\"}"
}

# /proc-чтение без форков (metrics и системная часть full).
_pid_stat_to() {   # $1 pid → _PJ (utime+stime, такты), _PSTART (starttime, такты)
    local line after
    local -a f
    _PJ=""
    _PSTART=0
    read -r line 2>/dev/null < "/proc/$1/stat" || return 1
    # comm (2-е поле, в скобках) может содержать пробелы/скобки — режем по
    # ПОСЛЕДНЕЙ ") ": после неё state — индекс 0, utime/stime — 11/12,
    # starttime — 19.
    after="${line##*) }"
    read -ra f <<< "$after"
    _PJ=$(( ${f[11]:-0} + ${f[12]:-0} ))
    _PSTART=${f[19]:-0}
}

_pid_rss_to() {   # $1 pid → _PRSS (КБ, VmRSS)
    local line
    _PRSS=0
    while IFS= read -r line; do
        if [[ "$line" == VmRSS:* ]]; then
            line="${line#VmRSS:}"
            _PRSS="${line//[^0-9]/}"
            _PRSS="${_PRSS:-0}"
            return 0
        fi
    done 2>/dev/null < "/proc/$1/status"
    return 1
}

_meminfo_read() {   # → _MEM_TOTAL_KB, _MEM_AVAIL_KB
    local key val free=0
    _MEM_TOTAL_KB=0
    _MEM_AVAIL_KB=0
    while IFS=':' read -r key val; do
        val="${val//[^0-9]/}"
        [[ -z "$val" ]] && continue
        case "$key" in
            MemTotal) _MEM_TOTAL_KB="$val" ;;
            MemFree) free="$val" ;;
            MemAvailable) _MEM_AVAIL_KB="$val" ;;
        esac
    done 2>/dev/null < /proc/meminfo
    [[ "$_MEM_AVAIL_KB" -gt 0 ]] || _MEM_AVAIL_KB=$free
}

_x10_fmt_to() { printf -v "$1" '%d.%d' "$(( $2 / 10 ))" "$(( $2 % 10 ))"; }

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

# ==========================================================================
# Слой full — полное обнаружение, пишет ВЕСЬ кеш (full.cache)
# ==========================================================================
# Только здесь: какие пакеты установлены, версии, зависимости, поиск
# процессов (pgrep), is-enabled, unit-файлы, каталоги, конфиги,
# infrastructure (установлена ли, версия), диски, БД, сертификаты, uptime.
# Заодно — начальные значения живых частей (is-active, порты, API, CPU/RAM),
# чтобы кеш был полным сразу; дальше их обновляют services и metrics.

# Все установленные в системе пакеты с версиями — ОДНИМ запросом к
# пакетному менеджеру (вместо dpkg-query на каждую из ~100 записей каталога).
_pm_snapshot() {
    declare -gA _PM_VER=()
    _PM_SNAP=0
    local name st ver
    case "$PM" in
        dpkg)
            while IFS=$'\t' read -r name st ver; do
                [[ "$st" == "install ok installed" ]] && _PM_VER["$name"]="$ver"
            done < <(dpkg-query -W -f='${Package}\t${Status}\t${Version}\n' 2>/dev/null)
            ;;
        rpm)
            while IFS=$'\t' read -r name ver; do
                [[ -n "$name" ]] && _PM_VER["$name"]="$ver"
            done < <(rpm -qa --qf '%{NAME}\t%{VERSION}-%{RELEASE}\n' 2>/dev/null)
            ;;
        pacman)
            while read -r name ver; do
                [[ -n "$name" ]] && _PM_VER["$name"]="$ver"
            done < <(pacman -Q 2>/dev/null)
            ;;
        *) return 1 ;;
    esac
    _PM_SNAP=1
}

# Установлен ли пакет каталога (основное имя или legacy) → _PKGVER.
# Как и раньше: нет в пакетном менеджере, но есть unit-файл — считается
# установленным (has_any_trace), версия тогда пустая.
_pkg_installed() {
    local pkg="$1" old
    local -a olds
    _PKGVER=""
    if [[ $_PM_SNAP -eq 1 ]]; then
        if [[ -n "${_PM_VER[$pkg]+x}" ]]; then
            _PKGVER="${_PM_VER[$pkg]}"
            return 0
        fi
        IFS=',' read -ra olds <<< "${PKG_LEGACY[$pkg]:-}"
        for old in "${olds[@]}"; do
            old="${old// /}"
            if [[ -n "$old" && -n "${_PM_VER[$old]+x}" ]]; then
                _PKGVER="${_PM_VER[$old]}"
                return 0
            fi
        done
        has_any_trace "$pkg"
        return
    fi
    is_pkg_installed_tiny "$pkg" "${PKG_LEGACY[$pkg]:-}" || return 1
    _PKGVER=$(_pkg_version "$pkg")
    return 0
}

_full_collect_pkg() {
    local pkg="$1" ver="$2" is_infra=0 unit="${1}.service" unit_path enabled
    local e_pkg e_ver dm dp deps_pm d pids
    local opt_path="/opt/flat/$1" log_path="/var/log/flat/$1"
    local opt_owner="" log_owner="" opt_status="missing" log_status="missing"
    local -a arr
    _is_infrastructure_pkg "$pkg" && is_infra=1

    deps_pm=$(get_pkg_depends "$pkg" 2>/dev/null)
    dm=$(_json_arr_from_csv "${PKG_DEPS[$pkg]:-}")
    dp=$(_json_arr_from_csv "$deps_pm")
    _json_esc_to e_pkg "$pkg"
    _json_esc_to e_ver "$ver"
    _W["pkg.$pkg.static"]="\"name\":\"$e_pkg\",\"status\":\"installed\",\"version\":\"$e_ver\",\"depends_meta\":$dm,\"depends_pm\":$dp"
    # Зависимости для infrastructure — те же данные, второй раз не считаем.
    IFS=',' read -ra arr <<< "${PKG_DEPS[$pkg]:-},${deps_pm}"
    for d in "${arr[@]}"; do
        register_dep "$d" "$pkg"
    done

    # systemd: unit-файл и is-enabled — здесь; is-active — в _pkg_dynamic.
    _unit_path_to unit_path "$unit"
    enabled="${_SD_EN[$unit]:-}"
    [[ -n "$enabled" ]] || enabled="unknown"
    if [[ $is_infra -eq 0 ]]; then
        if [[ -z "$unit_path" ]]; then
            _issue_add static warning "$pkg" systemd_unit_missing "systemd unit: $unit not found"
        elif [[ "$enabled" != "enabled" ]]; then
            _issue_add static error "$pkg" systemd_disabled "systemd: $unit is $enabled"
        fi
    fi

    # Поиск процессов (pgrep + MainPID) — только в full.
    pids=$(_sys_pkg_pids "$pkg" 2>/dev/null | paste -sd',' - 2>/dev/null)
    _pkg_process "$pkg" "$pids"

    # Каталоги FLAT (у Infrastructure — системные пакеты без /opt/flat).
    if [[ $is_infra -eq 1 ]]; then
        opt_status="n/a"; log_status="n/a"; opt_path=""; log_path=""
    else
        if [[ -d "$opt_path" ]]; then
            opt_status="ok"
            opt_owner=$(stat -c '%U:%G' "$opt_path" 2>/dev/null)
        else
            _issue_add static warning "$pkg" opt_dir_missing "dir: $opt_path missing"
        fi
        if [[ -d "$log_path" ]]; then
            log_status="ok"
            log_owner=$(stat -c '%U:%G' "$log_path" 2>/dev/null)
        elif [[ -n "${_W[pkg.$pkg.pids]}" ]]; then
            _issue_add static warning "$pkg" log_dir_missing "logdir: $log_path missing (process active)"
        fi
    fi
    local e_op e_oo e_lp e_lo
    _json_esc_to e_op "$opt_path"; _json_esc_to e_oo "$opt_owner"
    _json_esc_to e_lp "$log_path"; _json_esc_to e_lo "$log_owner"
    _W["pkg.$pkg.dirs"]="[{\"type\":\"opt\",\"path\":\"$e_op\",\"owner\":\"$e_oo\",\"status\":\"$opt_status\"},{\"type\":\"log\",\"path\":\"$e_lp\",\"owner\":\"$e_lo\",\"status\":\"$log_status\"}]"

    # Конфиги: WARN только когда nginx-конфиг есть в sites-available, но не
    # включён в sites-enabled (logrotate/sudoers не WARN'ят на отсутствие).
    local ngx_av="/etc/nginx/sites-available/$pkg" ngx_en="/etc/nginx/sites-enabled/$pkg"
    local lr="/etc/logrotate.d/${pkg}.conf" sudoers="/etc/sudoers.d/$pkg" cfg="" pair svc path st e
    [[ -f "/etc/logrotate.d/$pkg" && ! -f "$lr" ]] && lr="/etc/logrotate.d/$pkg"
    if [[ $is_infra -eq 0 && -f "$ngx_av" && ! -e "$ngx_en" && ! -L "$ngx_en" ]]; then
        _issue_add static warning "$pkg" nginx_not_enabled "nginx: $ngx_en not enabled"
    fi
    for pair in "nginx:$ngx_av" "nginx:$ngx_en" "logrotate:$lr" "sudoers:$sudoers"; do
        svc="${pair%%:*}"
        path="${pair#*:}"
        st="missing"
        [[ -e "$path" || -L "$path" ]] && st="ok"
        [[ "$path" == "$ngx_en" && "$st" == "ok" ]] && st="enabled"
        _json_esc_to e "$path"
        cfg+="${cfg:+,}{\"service_name\":\"$svc\",\"path\":\"$e\",\"status\":\"$st\"}"
    done
    _W["pkg.$pkg.configs"]="[$cfg]"

    _pkg_dynamic "$pkg" "${_SD_ACT[$unit]:-}"
}

# system (кроме того, что потом обновляет metrics — его начальные значения
# тоже здесь), certificates, uptime_services.
_full_collect_system() {
    local now="$1" cpu mem_total mem_used mem_avail up_sec=0 line pkg pid e
    local -a arr

    cpu=$(_sys_cpu_via_procstat 2>/dev/null) || cpu=0
    [[ "$cpu" =~ ^[0-9]+$ ]] || cpu=0
    _W[system.cpu]="{\"usage_percent\":$cpu}"

    _meminfo_read
    mem_total=$(( _MEM_TOTAL_KB / 1024 ))
    mem_avail=$(( _MEM_AVAIL_KB / 1024 ))
    mem_used=$(( mem_total - mem_avail ))
    [[ $mem_used -lt 0 ]] && mem_used=0
    _W[system.memory]="{\"total_mb\":$mem_total,\"used_mb\":$mem_used,\"available_mb\":$mem_avail}"

    read -r line _ 2>/dev/null < /proc/uptime && up_sec="${line%%.*}"
    [[ "$up_sec" =~ ^[0-9]+$ ]] || up_sec=0
    _W[system.uptime_seconds]="$up_sec"

    # CPU/RAM по сервисам: среднее с момента старта процесса (как ps pcpu) —
    # через /proc без ps. Через METRICS_INTERVAL их заменит реальная нагрузка
    # от metrics.
    local cpu_s="" mem_s="" j tot start_ticks up_ticks=$(( up_sec * ${_DAEMON_CLK_TCK:-100} )) cx mx rss v
    for pkg in "${_FULL_PKGS[@]}"; do
        IFS=',' read -ra arr <<< "${_W[pkg.$pkg.pids]:-}"
        cx=0
        rss=0
        for pid in "${arr[@]}"; do
            _pid_stat_to "$pid" || continue
            j=$_PJ
            start_ticks=$_PSTART
            tot=$(( up_ticks - start_ticks ))
            [[ $tot -gt 0 ]] && cx=$(( cx + j * 1000 / tot ))
            _pid_rss_to "$pid" && rss=$(( rss + _PRSS ))
        done
        if [[ $cx -gt 0 ]]; then
            _x10_fmt_to v "$cx"
            cpu_s+="${cpu_s:+,}{\"service_name\":\"$pkg\",\"usage_percent\":$v}"
        fi
        mx=0
        [[ $rss -gt 0 && $_MEM_TOTAL_KB -gt 0 ]] && mx=$(( rss * 1000 / _MEM_TOTAL_KB ))
        if [[ $mx -gt 0 ]]; then
            _x10_fmt_to v "$mx"
            mem_s+="${mem_s:+,}{\"service_name\":\"$pkg\",\"usage_percent\":$v}"
        fi
    done
    _W[system.cpu_services]="[$cpu_s]"
    _W[system.memory_services]="[$mem_s]"

    local disk="" fs mount usep
    while read -r fs _ _ _ usep mount; do
        [[ "$fs" == Filesystem* || "$fs" == "tmpfs" || "$fs" == "devtmpfs" ]] && continue
        [[ "$mount" == "/proc"* || "$mount" == "/sys"* || "$mount" == "/run"* ]] && continue
        usep="${usep%%%}"
        [[ "$usep" =~ ^[0-9]+$ ]] || continue
        local e_fs e_mt
        _json_esc_to e_fs "$fs"
        _json_esc_to e_mt "$mount"
        disk+="${disk:+,}{\"filesystem\":\"$e_fs\",\"mount\":\"$e_mt\",\"used_percent\":$usep}"
    done < <(df -P 2>/dev/null | awk 'NR>1{print $1,$2,$3,$4,$5,$6}')
    _W[system.disk]="[$disk]"

    # Сеть: здесь только список интерфейсов — скорость считает metrics
    # (разницей между своими тиками).
    local net="" iface
    for iface in /sys/class/net/*; do
        iface="${iface##*/}"
        [[ "$iface" == "lo" || "$iface" == "*" ]] && continue
        _json_esc_to e "$iface"
        net+="${net:+,}{\"interface\":\"$e\",\"mbps\":0.0}"
    done
    _W[system.network]="[$net]"

    local db_name="n/a" db_status="n/a" db_nodes=0
    if command -v systemctl >/dev/null 2>&1; then
        if systemctl is-active --quiet postgresql 2>/dev/null || systemctl is-active --quiet 'postgresql@*' 2>/dev/null; then
            db_name="postgresql"; db_status="active"; db_nodes=1
        elif systemctl is-active --quiet mariadb 2>/dev/null || systemctl is-active --quiet mysqld 2>/dev/null; then
            db_name="mariadb"; db_status="active"; db_nodes=1
        fi
    fi
    _W[system.database]="{\"name\":\"$db_name\",\"status\":\"$db_status\",\"replication\":\"none\",\"nodes\":$db_nodes}"

    local certs="" cert days subject e_c e_s
    for cert in /etc/nginx/ssl/*.crt /etc/nginx/ssl/*.pem /opt/flat/cert/*/*.pem /etc/ssl/certs/flat*.pem; do
        [[ -f "$cert" ]] || continue
        days=$(openssl x509 -in "$cert" -noout -enddate 2>/dev/null | sed 's/notAfter=//' | xargs -I{} date -d {} +%s 2>/dev/null)
        if [[ "$days" =~ ^[0-9]+$ ]]; then days=$(( (days - now) / 86400 )); else days=0; fi
        subject=$(openssl x509 -in "$cert" -noout -subject 2>/dev/null | sed 's/subject=//')
        _json_esc_to e_c "$cert"
        _json_esc_to e_s "$subject"
        certs+="${certs:+,}{\"path\":\"$e_c\",\"subject\":\"$e_s\",\"days_left\":$days}"
        [[ ${#certs} -gt 2000 ]] && break
    done
    _W[certificates]="[$certs]"
}

# uptime_services — по уже полученному общему systemctl show (главное имя
# пакета и legacy-имена: берётся первый активный юнит).
_full_collect_uptime() {
    local now="$1" pkg name enter ts out=""
    local -a names
    for pkg in "${_FULL_PKGS[@]}"; do
        mapfile -t names < <(_sys_pkg_names "$pkg")
        for name in "${names[@]}"; do
            [[ "${_SD_ACT[${name}.service]:-}" == "active" ]] || continue
            enter="${_SD_ENTER[${name}.service]:-}"
            [[ -n "$enter" && "$enter" != "n/a" && "$enter" != "0" ]] || continue
            ts=$(date -d "$enter" +%s 2>/dev/null)
            if [[ "$ts" =~ ^[0-9]+$ && $now -ge $ts ]]; then
                out+="${out:+,}{\"service_name\":\"$pkg\",\"uptime\":$((now - ts))}"
            fi
            break
        done
    done
    _W[uptime_services]="[$out]"
}

_full_collect_infra() {
    local d status ver unit e_n e_v e_r list=""
    local -a deps units=()
    mapfile -t deps < <(printf '%s\n' "${!ALL_DEPENDS[@]}" | sort)
    for d in "${deps[@]}"; do
        [[ -z "$d" || "$d" == *.so.* ]] && continue
        [[ "$d" =~ ^[A-Za-z0-9@._+-]+$ ]] && units+=("$d")
    done
    _systemd_batch "${units[@]}"
    for d in "${deps[@]}"; do
        [[ -z "$d" ]] && continue
        status="not_installed"
        ver=""
        unit=0
        if [[ "$d" == *.so.* ]]; then
            is_lib_available "$d" 2>/dev/null && status="installed"
        else
            if [[ $_PM_SNAP -eq 1 ]]; then
                [[ -n "${_PM_VER[$d]+x}" ]] && { status="installed"; ver="${_PM_VER[$d]}"; }
            else
                is_dep_installed "$d" 2>/dev/null && status="installed"
                ver=$(get_dep_version "$d" 2>/dev/null)
            fi
        fi
        # Если это ещё и systemd-служба (nginx/postgresql/redis/…) — вместо
        # installed её состояние (active/inactive/failed), а services
        # дальше обновляет только его.
        if [[ "${_SD_LOAD[$d]:-}" == "loaded" && -n "${_SD_ACT[$d]:-}" ]]; then
            status="${_SD_ACT[$d]}"
            unit=1
        fi
        _json_esc_to e_n "$d"
        _json_esc_to e_v "$ver"
        _json_esc_to e_r "${ALL_DEPENDS[$d]}"
        _W["infra.$d.name"]="\"$e_n\""
        _W["infra.$d.status"]="$status"
        _W["infra.$d.rest"]="\"version\":\"$e_v\",\"port_open\":\"\",\"required_by\":\"$e_r\""
        _W["infra.$d.unit"]="$unit"
        list+="${list:+ }$d"
    done
    _W[infra.list]="$list"
}

_full_run() {
    local t0 t1 p pkg i=0 e plist
    local -a sorted products_list units
    local -A seen=()
    _epoch_to t0
    info "cache: full — старт"
    detect_os
    declare -gA _W=() ALL_DEPENDS=()
    _issues_reset static dynamic
    _pm_snapshot

    # Установленные пакеты: продукты в фиксированном порядке, внутри — по
    # алфавиту; фильтры PACKAGES/PRODUCT действуют здесь, и services с
    # metrics берут этот же список (раньше services их игнорировал).
    mapfile -t sorted < <(printf '%s\n' "${!PKG_PRODUCT[@]}" | sort)
    products_list=("${FLAT_PRODUCTS_ORDER[@]}")
    [[ -n "$FILTER_PRODUCT" ]] && products_list=("$FILTER_PRODUCT")
    _FULL_PKGS=()
    declare -A pkg_ver=() prod_pkgs=()
    for p in "${products_list[@]}"; do
        for pkg in "${sorted[@]}"; do
            [[ "${PKG_PRODUCT[$pkg]}" == "$p" ]] || continue
            [[ -n "$SINGLE_PKG" && "$pkg" != "$SINGLE_PKG" ]] && continue
            [[ -n "$PACKAGES" && ",${PACKAGES}," != *",$pkg,"* ]] && continue
            _pkg_installed "$pkg" || continue
            pkg_ver[$pkg]="$_PKGVER"
            prod_pkgs[$p]+="${prod_pkgs[$p]:+ }$pkg"
            _FULL_PKGS+=("$pkg")
        done
    done

    # Один systemctl show на все юниты пакетов (включая legacy-имена — для
    # uptime_services) вместо 2–4 вызовов systemctl на каждый пакет.
    units=()
    for pkg in "${_FULL_PKGS[@]}"; do
        while IFS= read -r e; do
            [[ -n "$e" && -z "${seen[$e]:-}" ]] || continue
            seen[$e]=1
            units+=("${e}.service")
        done < <(_sys_pkg_names "$pkg")
    done
    _systemd_batch "${units[@]}"
    _ports_snapshot

    for p in "${products_list[@]}"; do
        plist="${prod_pkgs[$p]:-}"
        [[ -n "$plist" ]] || continue
        for pkg in $plist; do
            _full_collect_pkg "$pkg" "${pkg_ver[$pkg]}"
        done
        _json_esc_to e "$p"
        _W["product.$i.name"]="\"$e\""
        _W["product.$i.pkgs"]="$plist"
        i=$((i + 1))
    done
    _W[products.count]="$i"
    _W[pkgs]="${_FULL_PKGS[*]}"

    _full_collect_system "$t0"
    _full_collect_uptime "$t0"
    _full_collect_infra

    _json_esc_to e "$SCRIPT_VERSION"; _W[script_version]="\"$e\""
    _json_esc_to e "${OS_FULL_VER:-${OS_NAME:-unknown}}"; _W[os]="\"$e\""
    _json_esc_to e "${PM:-unknown}"; _W[package_manager]="\"$e\""
    if [[ $SHOW_REPO -eq 1 || $SHOW_REPOS_JSON -eq 1 ]]; then
        _W[repositories]=$(_json_collect_repos)
    else
        _W[repositories]="[]"
    fi
    _W[issues.static]="$_ISS_static"
    _W[issues.static.count]="$_ISS_static_E $_ISS_static_W"
    _W[issues.dynamic]="$_ISS_dynamic"
    _W[issues.dynamic.count]="$_ISS_dynamic_E $_ISS_dynamic_W"
    _W[updated_at]="$t0"

    if _cache_write "$_CACHE_FULL" 1; then
        _epoch_to t1
        info "cache: full — готово: пакетов ${#_FULL_PKGS[@]}, за $((t1 - t0)) с"
    else
        fail "cache: full — не удалось записать $_CACHE_FULL"
        return 1
    fi
}

# ==========================================================================
# Слой services — живые статусы по списку пакетов из full.cache
# ==========================================================================
# Каталог НЕ сканирует. На весь прогон: один systemctl show (is-active и
# MainPID всех юнитов пакетов и служб-зависимостей), один ss; плюс curl на
# каждый пакет с API. PID'ы: найденные full'ом (если ещё живы) + свежий
# MainPID — так metrics переживает перезапуск сервиса без ожидания full.
_services_run() {
    local t0 pkg d pids mp
    local -a pkgs deps units=()
    _epoch_to t0
    declare -gA _F=() _W=()
    _cache_read "$_CACHE_FULL" _F || return 1
    _issues_reset dynamic
    read -ra pkgs <<< "${_F[pkgs]:-}"
    read -ra deps <<< "${_F[infra.list]:-}"
    for pkg in "${pkgs[@]}"; do
        units+=("${pkg}.service")
    done
    for d in "${deps[@]}"; do
        [[ "${_F[infra.$d.unit]:-0}" == 1 ]] && units+=("$d")
    done
    _systemd_batch "${units[@]}"
    _ports_snapshot

    for pkg in "${pkgs[@]}"; do
        pids="${_F[pkg.$pkg.pids]:-}"
        mp="${_SD_PID[${pkg}.service]:-0}"
        [[ "$mp" =~ ^[1-9][0-9]*$ ]] && pids+="${pids:+,}$mp"
        _pkg_process "$pkg" "$pids"
        _pkg_dynamic "$pkg" "${_SD_ACT[${pkg}.service]:-}"
    done
    for d in "${deps[@]}"; do
        [[ "${_F[infra.$d.unit]:-0}" == 1 && "${_SD_LOAD[$d]:-}" == "loaded" && -n "${_SD_ACT[$d]:-}" ]] || continue
        _W["infra.$d.status"]="${_SD_ACT[$d]}"
    done
    _W[issues.dynamic]="$_ISS_dynamic"
    _W[issues.dynamic.count]="$_ISS_dynamic_E $_ISS_dynamic_W"
    _W[updated_at]="$t0"
    _cache_write "$_CACHE_SERVICES" 1 || { fail "cache: services — не удалось записать $_CACHE_SERVICES"; return 1; }
}

# ==========================================================================
# Слой metrics — CPU/RAM/сеть из /proc, без единого внешнего процесса
# ==========================================================================
# Работает в основном процессе демона (не в фоне): разницы между тиками
# (_MET_*) живут в памяти этого процесса. PID'ы — из склеенного кеша (full
# или services, кто свежее).

_metrics_init() {
    _DAEMON_CLK_TCK=$(getconf CLK_TCK 2>/dev/null)
    [[ "$_DAEMON_CLK_TCK" =~ ^[0-9]+$ && "$_DAEMON_CLK_TCK" -gt 0 ]] || _DAEMON_CLK_TCK=100
    declare -gA _MET_PID_J=() _MET_NET_PREV=()
    _MET_CPU_PREV_TOTAL=0
    _MET_CPU_PREV_IDLE=0
    # Первый замер — только база для разниц, его результат не используется.
    _met_cpu_total
    _met_network 1
    _epoch_to _MET_PREV_EPOCH
}

_met_cpu_total() {   # → _MET_CPU (%), разница /proc/stat с прошлого вызова
    local line total=0 i idle dt di
    local -a f
    _MET_CPU=0
    read -r line 2>/dev/null < /proc/stat || return 0
    read -ra f <<< "$line"
    for ((i = 1; i < ${#f[@]}; i++)); do
        total=$(( total + ${f[i]:-0} ))
    done
    idle=$(( ${f[4]:-0} + ${f[5]:-0} ))
    dt=$(( total - _MET_CPU_PREV_TOTAL ))
    di=$(( idle - _MET_CPU_PREV_IDLE ))
    _MET_CPU_PREV_TOTAL=$total
    _MET_CPU_PREV_IDLE=$idle
    [[ $dt -gt 0 ]] && _MET_CPU=$(( (dt - di) * 100 / dt ))
}

_met_network() {   # $1 elapsed → _MET_NET: [{"interface","mbps"}] по каждому интерфейсу кроме lo
    local elapsed="${1:-1}" line iface total prev x10 v e out=""
    local -a f
    [[ $elapsed -gt 0 ]] || elapsed=1
    while IFS= read -r line; do
        [[ "$line" == *:* ]] || continue
        iface="${line%%:*}"
        iface="${iface// /}"
        [[ -z "$iface" || "$iface" == "lo" ]] && continue
        read -ra f <<< "${line#*:}"
        total=$(( ${f[0]:-0} + ${f[8]:-0} ))
        prev="${_MET_NET_PREV[$iface]:-}"
        _MET_NET_PREV[$iface]=$total
        x10=0
        [[ -n "$prev" && $total -ge $prev ]] && x10=$(( (total - prev) * 80 / (1000000 * elapsed) ))
        _x10_fmt_to v "$x10"
        _json_esc_to e "$iface"
        out+="${out:+,}{\"interface\":\"$e\",\"mbps\":$v}"
    done 2>/dev/null < /proc/net/dev
    _MET_NET="[$out]"
}

_metrics_run() {
    local now elapsed pkg pid prev cx rss mx v cpu_s="" mem_s="" pids have
    local -a pkgs arr
    local -A newj=()
    _epoch_to now
    elapsed=$(( now - _MET_PREV_EPOCH ))
    [[ $elapsed -gt 0 ]] || elapsed=1
    _MET_PREV_EPOCH=$now

    _met_cpu_total
    _meminfo_read
    _met_network "$elapsed"

    read -ra pkgs <<< "${_F[pkgs]:-}"
    for pkg in "${pkgs[@]}"; do
        _cget_to pids "pkg.$pkg.pids"
        IFS=',' read -ra arr <<< "$pids"
        cx=0
        rss=0
        have=0
        for pid in "${arr[@]}"; do
            [[ "$pid" =~ ^[0-9]+$ ]] || continue
            _pid_stat_to "$pid" || continue
            newj[$pid]=$_PJ
            prev="${_MET_PID_J[$pid]:-}"
            if [[ -n "$prev" && $_PJ -ge $prev ]]; then
                cx=$(( cx + (_PJ - prev) * 1000 / (_DAEMON_CLK_TCK * elapsed) ))
                have=1
            fi
            _pid_rss_to "$pid" && rss=$(( rss + _PRSS ))
        done
        if [[ $have -eq 1 && $cx -gt 0 ]]; then
            _x10_fmt_to v "$cx"
            cpu_s+="${cpu_s:+,}{\"service_name\":\"$pkg\",\"usage_percent\":$v}"
        fi
        mx=0
        [[ $rss -gt 0 && $_MEM_TOTAL_KB -gt 0 ]] && mx=$(( rss * 1000 / _MEM_TOTAL_KB ))
        if [[ $mx -gt 0 ]]; then
            _x10_fmt_to v "$mx"
            mem_s+="${mem_s:+,}{\"service_name\":\"$pkg\",\"usage_percent\":$v}"
        fi
    done
    # Только текущие PID'ы — иначе таблица разниц росла бы бесконечно.
    _MET_PID_J=()
    for pid in "${!newj[@]}"; do
        _MET_PID_J[$pid]=${newj[$pid]}
    done

    declare -gA _W=()
    _W[updated_at]="$now"
    _W[system.cpu]="{\"usage_percent\":$_MET_CPU}"
    _W[system.memory]="{\"total_mb\":$(( _MEM_TOTAL_KB / 1024 )),\"used_mb\":$(( (_MEM_TOTAL_KB - _MEM_AVAIL_KB) / 1024 )),\"available_mb\":$(( _MEM_AVAIL_KB / 1024 ))}"
    _W[system.cpu_services]="[$cpu_s]"
    _W[system.memory_services]="[$mem_s]"
    _W[system.network]="$_MET_NET"
    _cache_write "$_CACHE_METRICS" 0 || warn "cache: metrics — не удалось записать $_CACHE_METRICS"
    declare -gA _M=()
    for v in "${!_W[@]}"; do
        _M[$v]="${_W[$v]}"
    done
    _M_TS=$now
}

# ==========================================================================
# Склейка кеша (для metrics и курьера)
# ==========================================================================
# full.cache и services.cache перечитываются, только когда сменился их
# updated_at (первая строка файла) — в обычный тик это одно чтение строки.
_F_TS=""
_S_TS=""
_M_TS=""

_cache_refresh() {
    local k ts=""
    IFS=$'\t' read -r k ts 2>/dev/null < "$_CACHE_FULL" || ts=""
    if [[ -z "$ts" || "$ts" != "$_F_TS" ]]; then
        declare -gA _F=()
        _F_TS=""
        if _cache_read "$_CACHE_FULL" _F; then
            _F_TS="${_F[updated_at]}"
        else
            declare -gA _F=()
        fi
    fi
    [[ -n "$_F_TS" ]] || return 1

    ts=""
    IFS=$'\t' read -r k ts 2>/dev/null < "$_CACHE_SERVICES" || ts=""
    if [[ -n "$ts" && "$ts" != "$_S_TS" ]]; then
        declare -gA _S=()
        _S_TS=""
        if _cache_read "$_CACHE_SERVICES" _S; then
            _S_TS="${_S[updated_at]}"
        else
            declare -gA _S=()
        fi
    fi
    _USE_S=0
    [[ -n "$_S_TS" && $_S_TS -ge $_F_TS ]] && _USE_S=1
    _USE_M=0
    [[ -n "$_M_TS" && $_M_TS -ge $_F_TS ]] && _USE_M=1
    return 0
}

# Значение ключа из самого свежего слоя, где он есть ($3 — по умолчанию).
_cget_to() {
    local k="$2"
    if [[ $_USE_M -eq 1 && -n "${_M[$k]+x}" ]]; then
        printf -v "$1" '%s' "${_M[$k]}"
    elif [[ $_USE_S -eq 1 && -n "${_S[$k]+x}" ]]; then
        printf -v "$1" '%s' "${_S[$k]}"
    elif [[ -n "${_F[$k]+x}" ]]; then
        printf -v "$1" '%s' "${_F[$k]}"
    else
        printf -v "$1" '%s' "${3:-}"
    fi
}

_layer_json_to() {   # $1 var, $2 epoch данных, $3 источник, $4 интервал, $5 now, $6 sections
    local iso
    _iso_utc_to iso "$2"
    printf -v "$1" '{"updated_at":"%s","age_seconds":%d,"interval_seconds":%d,"source":"%s","sections":[%s]}' \
        "$iso" "$(( $5 - $2 ))" "$4" "$3" "$6"
}

# ==========================================================================
# Курьер — склеивает кеш в полный JSON и отправляет (раз в METRICS_INTERVAL)
# ==========================================================================
_courier_send() {
    local now ts j v i n p pkg d st sd dirs cfg pr po api name list e_cnt w_cnt ie iw
    local l_full l_svc l_met s_ts s_src m_ts m_src iss_s iss_d obj0='{}'
    local -a pkgs deps
    _epoch_to now
    _iso_utc_to ts "$now"

    s_ts=$_F_TS; s_src="full"
    [[ $_USE_S -eq 1 ]] && { s_ts=$_S_TS; s_src="services"; }
    m_ts=$_F_TS; m_src="full"
    [[ $_USE_M -eq 1 ]] && { m_ts=$_M_TS; m_src="metrics"; }
    _layer_json_to l_full "$_F_TS" full "$FULL_INTERVAL" "$now" \
        '"script_version","os","package_manager","repositories","products[].packages[].version/depends/directories/configs","infrastructure[].version","system.disk","system.database","system.uptime_seconds","certificates","uptime_services","issues(static)"'
    _layer_json_to l_svc "$s_ts" "$s_src" "$SERVICES_INTERVAL" "$now" \
        '"products[].packages[].systemd/process/ports/api","infrastructure[].status","issues(dynamic)"'
    _layer_json_to l_met "$m_ts" "$m_src" "$METRICS_INTERVAL" "$now" \
        '"system.cpu","system.cpu_services","system.memory","system.memory_services","system.network"'

    j="{\"hosts\":[{\"timestamp\":\"$ts\",\"host_id\":\"$_ID_HOST\",\"host_ip\":\"$_ID_IP\",\"service_name\":\"$_ID_SVC\","
    j+="\"script_version\":${_F[script_version]:-\"\"},\"os\":${_F[os]:-\"\"},\"package_manager\":${_F[package_manager]:-\"\"},"
    j+="\"layers\":{\"full\":$l_full,\"services\":$l_svc,\"metrics\":$l_met},"

    j+="\"products\":["
    n="${_F[products.count]:-0}"
    for ((i = 0; i < n; i++)); do
        [[ $i -gt 0 ]] && j+=","
        j+="{\"name\":${_F[product.$i.name]:-\"\"},\"packages\":["
        read -ra pkgs <<< "${_F[product.$i.pkgs]:-}"
        list=""
        for pkg in "${pkgs[@]}"; do
            _cget_to sd "pkg.$pkg.systemd" '{}'
            _cget_to pr "pkg.$pkg.process" '{}'
            _cget_to po "pkg.$pkg.ports" '[]'
            _cget_to api "pkg.$pkg.api" '{}'
            list+="${list:+,}{${_F[pkg.$pkg.static]:-\"name\":\"$pkg\"},\"systemd\":$sd,\"directories\":${_F[pkg.$pkg.dirs]:-[]},\"configs\":${_F[pkg.$pkg.configs]:-[]},\"process\":$pr,\"ports\":$po,\"api\":$api}"
        done
        j+="$list]}"
    done
    j+="],"

    j+="\"infrastructure\":["
    read -ra deps <<< "${_F[infra.list]:-}"
    list=""
    for d in "${deps[@]}"; do
        _cget_to st "infra.$d.status" "unknown"
        list+="${list:+,}{\"service_name\":${_F[infra.$d.name]:-\"$d\"},\"status\":\"$st\",${_F[infra.$d.rest]:-\"version\":\"\",\"port_open\":\"\",\"required_by\":\"\"}}"
    done
    j+="$list],"
    j+="\"repositories\":${_F[repositories]:-[]},\"apt_priorities\":[],"

    read -r ie iw <<< "${_F[issues.static.count]:-0 0}"
    _cget_to v issues.dynamic.count "0 0"
    read -r e_cnt w_cnt <<< "$v"
    read -ra pkgs <<< "${_F[pkgs]:-}"
    j+="\"summary\":{\"installed\":${#pkgs[@]},\"errors\":$(( ie + e_cnt )),\"warnings\":$(( iw + w_cnt ))},"

    j+="\"system\":{"
    _cget_to v system.cpu '{"usage_percent":0}'; j+="\"cpu\":$v,"
    _cget_to v system.cpu_services '[]'; j+="\"cpu_services\":$v,"
    _cget_to v system.memory '{}'; j+="\"memory\":$v,"
    _cget_to v system.memory_services '[]'; j+="\"memory_services\":$v,"
    j+="\"disk\":${_F[system.disk]:-[]},\"database\":${_F[system.database]:-$obj0},"
    _cget_to v system.network '[]'; j+="\"network\":$v,"
    j+="\"uptime_seconds\":${_F[system.uptime_seconds]:-0}},"
    j+="\"certificates\":${_F[certificates]:-[]},\"uptime_services\":${_F[uptime_services]:-[]},"

    iss_s="${_F[issues.static]:-}"
    _cget_to iss_d issues.dynamic ''
    j+="\"issues\":[${iss_s}${iss_s:+${iss_d:+,}}${iss_d}]"
    j+="}]}"

    # Сначала на диск (last_sent.json — что именно ушло, для разбора после
    # падения), потом push из этого же файла.
    if printf '%s\n' "$j" > "${_CACHE_SENT}.tmp" 2>/dev/null && mv -f "${_CACHE_SENT}.tmp" "$_CACHE_SENT" 2>/dev/null; then
        [[ -n "$PUSH_URLS" ]] && push_health_json "$_CACHE_SENT"
    else
        warn "courier: не удалось записать $_CACHE_SENT — отправка пропущена"
    fi
    if [[ "$PRINT_JSON" == 1 || -t 1 ]]; then
        printf '%s\n' "$j"
    fi
    return 0
}

# ==========================================================================
# Отправка JSON на PUSH_URLS
# ==========================================================================
# Тело — из файла (curl --data-binary @file). Шлёт каждые METRICS_INTERVAL
# секунд, поэтому по умолчанию без повторов и с коротким --max-time: зависший
# приёмник не должен задерживать следующий тик, а следующая попытка и так
# через несколько секунд. В лог — только смена состояния URL (OK → FAIL и
# обратно), иначе это тысячи строк в час; каждая попытка — в DEBUG.
declare -A _PUSH_STATE=() _PUSH_FAILS=()

push_health_json() {
    local file="$1" url token i=0 rc=0 http_code attempt ok errf="$CACHE_DIR/.push_err" err
    local -a urls tokens curl_insecure=()
    local auth_hdr="${PUSH_AUTH_HEADER:-Authorization: Bearer}"
    [[ "${PUSH_INSECURE:-0}" == "1" ]] && curl_insecure=(-k)
    command -v curl >/dev/null 2>&1 || { warn "push: curl не найден"; return 1; }

    read -ra urls <<< "${PUSH_URLS//,/ }"
    read -ra tokens <<< "${PUSH_TOKENS//,/ }"

    for url in "${urls[@]}"; do
        [[ -z "$url" ]] && continue
        if [[ ! "$url" =~ ^https?:// ]]; then
            [[ "${_PUSH_STATE[$url]:-}" == "bad" ]] || warn "push: пропуск URL без http/https: $url"
            _PUSH_STATE[$url]="bad"
            rc=1
            continue
        fi
        token="${PUSH_TOKEN:-}"
        [[ -n "${tokens[$i]:-}" ]] && token="${tokens[$i]}"
        i=$((i + 1))

        attempt=0
        ok=0
        while [[ $attempt -le ${PUSH_RETRIES:-0} ]]; do
            attempt=$((attempt + 1))
            http_code=$(curl -sS -o /dev/null -w '%{http_code}' \
                "${curl_insecure[@]}" \
                --connect-timeout "${PUSH_CONNECT_TIMEOUT:-2}" \
                --max-time "${PUSH_MAX_TIME:-4}" \
                -X POST "$url" \
                -H "Content-Type: application/json" \
                -H "X-Flat-Host-Id: ${HOST_ID}" \
                -H "X-Flat-Service-Name: ${SERVICE_NAME}" \
                ${token:+-H "$auth_hdr $token"} \
                --data-binary "@$file" 2>"$errf") || true
            [[ "$http_code" =~ ^[0-9]{3}$ ]] || http_code="000"
            if [[ "$http_code" =~ ^2[0-9][0-9]$ ]]; then
                ok=1
                break
            fi
            if [[ "${DEBUG_MODE:-0}" -eq 1 ]]; then
                err=""
                IFS= read -r -d '' err 2>/dev/null < "$errf"
                log_debug "push: attempt $attempt → $url http=$http_code ${err//$'\n'/ }"
            fi
            [[ $attempt -le ${PUSH_RETRIES:-0} ]] && _wait_seconds 1
        done
        if [[ $ok -eq 1 ]]; then
            if [[ "${_PUSH_STATE[$url]:-}" != "ok" ]]; then
                if [[ "${_PUSH_STATE[$url]:-}" == "fail" ]]; then
                    info "push: снова OK $http_code → $url (после ${_PUSH_FAILS[$url]:-0} неудачных)"
                else
                    info "push: OK $http_code → $url"
                fi
            fi
            _PUSH_STATE[$url]="ok"
            _PUSH_FAILS[$url]=0
        else
            if [[ "${_PUSH_STATE[$url]:-}" != "fail" ]]; then
                warn "push: FAIL → $url (http=$http_code) — дальше в лог только восстановление; каждая попытка — при DEBUG_MODE=1"
            fi
            _PUSH_STATE[$url]="fail"
            _PUSH_FAILS[$url]=$(( ${_PUSH_FAILS[$url]:-0} + 1 ))
            rc=1
        fi
    done
    return "$rc"
}

# ==========================================================================
# Планировщик: full/services — в фоне, metrics и курьер — в основном цикле
# ==========================================================================

# Тот же приём, что init_logging() у flat_check.sh/flat_check_2.sh: каталог
# лога (соседний с /opt/flat/<продукт>), файл усекается один раз за запуск
# демона. Нет прав — LOG_FILE="" и только stderr, без падения.
_daemon_init_logging() {
    [[ -n "$LOG_FILE" ]] || return 0
    mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null
    if ! { : > "$LOG_FILE"; } 2>/dev/null; then
        warn "не удалось писать лог-файл $LOG_FILE — файловое логирование выключено, дальше только stderr (переопределить путь: LOG_FILE в конфиге/env)"
        LOG_FILE=""
        return 1
    fi
    _log_line "INFO" "=== flat_check_agent (демон) — сессия начата ==="
    return 0
}

# Запуск слоя в фоне, если предыдущий его запуск уже закончился. Главный
# цикл — единственный, кто их запускает, поэтому лок-файлы не нужны:
# достаточно помнить PID своего фонового процесса.
_BG_full=""
_BG_services=""
_layer_launch() {
    local layer="$1" quiet="${2:-0}" var="_BG_$1"
    if [[ -n "${!var}" ]] && kill -0 "${!var}" 2>/dev/null; then
        [[ $quiet -eq 1 ]] || info "cache: $layer — предыдущий запуск ещё не завершился, пропуск"
        return 1
    fi
    ( "_${layer}_run" ) &
    printf -v "$var" '%s' "$!"
}

_daemon_init() {
    local iso
    _STOP=0
    _WAITING=0
    trap '_STOP=1' TERM INT
    detect_os
    _json_ensure_identity
    _json_esc_to _ID_HOST "$HOST_ID"
    _json_esc_to _ID_IP "$HOST_IP"
    _json_esc_to _ID_SVC "$SERVICE_NAME"
    mkdir -p "$CACHE_DIR" 2>/dev/null || { fail "cache: не удалось создать каталог $CACHE_DIR"; exit 1; }
    _metrics_init
    declare -gA _F=() _S=() _M=()
    _USE_S=0
    _USE_M=0
    # После перезапуска: уже лежащий кеш отправляется сразу (общий timestamp
    # — текущий, updated_at частей — старые, по ним видно возраст данных).
    if _cache_read "$_CACHE_METRICS" _M; then
        _M_TS="${_M[updated_at]}"
    else
        declare -gA _M=()
    fi
    _NEXT_FULL=0
    _NEXT_SERVICES=0
    _NEXT_METRICS=0
    _FULL_RETRY_AT=0
    if _cache_refresh; then
        _iso_utc_to iso "$_F_TS"
        _NEXT_FULL=$(( _F_TS + FULL_INTERVAL ))
        info "cache: найден кеш (full от $iso) — отправка сразу, следующий full через $(( _NEXT_FULL > _MET_PREV_EPOCH ? _NEXT_FULL - _MET_PREV_EPOCH : 0 )) с"
    fi
}

daemon_main() {
    local now pause
    _daemon_init
    info "daemon: старт (full=${FULL_INTERVAL}s services=${SERVICES_INTERVAL}s metrics/отправка=${METRICS_INTERVAL}s, кеш=$CACHE_DIR)"
    while [[ "$_STOP" -eq 0 ]]; do
        _epoch_to now
        if ! _cache_refresh; then
            # Кеша нет/битый: services, metrics и курьер ждут, full — в фоне.
            if [[ $_WAITING -eq 0 ]]; then
                warn "cache: кеш не создан или повреждён ($_CACHE_FULL) — запускаю full; services, metrics и отправка ждут его создания"
                _WAITING=1
            fi
            # Упавший full не перезапускаем чаще раза в 30 с.
            if [[ $now -ge $_FULL_RETRY_AT ]] && _layer_launch full 1; then
                _FULL_RETRY_AT=$(( now + 30 ))
            fi
            _NEXT_FULL=$(( now + FULL_INTERVAL ))
            _wait_seconds 1
            continue
        fi
        if [[ $_WAITING -eq 1 ]]; then
            info "cache: кеш создан — services, metrics и отправка продолжают работу"
            _WAITING=0
        fi
        if [[ $now -ge $_NEXT_FULL ]]; then
            _NEXT_FULL=$(( now + FULL_INTERVAL ))
            _layer_launch full
        fi
        if [[ $now -ge $_NEXT_SERVICES ]]; then
            _NEXT_SERVICES=$(( now + SERVICES_INTERVAL ))
            _layer_launch services
        fi
        if [[ $now -ge $_NEXT_METRICS ]]; then
            _NEXT_METRICS=$(( now + METRICS_INTERVAL ))
            _metrics_run
            _cache_refresh
            _courier_send
        fi
        _epoch_to now
        pause=$(( _NEXT_METRICS - now ))
        [[ $(( _NEXT_SERVICES - now )) -lt $pause ]] && pause=$(( _NEXT_SERVICES - now ))
        [[ $(( _NEXT_FULL - now )) -lt $pause ]] && pause=$(( _NEXT_FULL - now ))
        [[ $pause -ge 1 ]] || pause=1
        _wait_seconds "$pause"
    done
    info "daemon: остановлен (сигнал)"
    wait 2>/dev/null
}


# ==========================================================================
# Точка входа: без argv — всё поведение определяется env/конфигом выше.
# ==========================================================================
# Конфиг-файл: рядом со скриптом по умолчанию, переопределяется переменной
# окружения FLAT_AGENT_CONF. Отсутствие файла — не ошибка, но если из-за
# этого нечего пушить, об этом стоит явно предупредить (молчание неотличимо
# от "push и не должен был случиться").
FLAT_AGENT_CONF="${FLAT_AGENT_CONF:-$SCRIPT_DIR/flat_check_agent.conf}"
_json_load_config "$FLAT_AGENT_CONF"
_daemon_init_logging

if [[ -z "$PUSH_URLS" ]]; then
    if [[ ! -f "$FLAT_AGENT_CONF" ]]; then
        warn "конфиг не найден: $FLAT_AGENT_CONF — PUSH_URLS пуст, push пропущен (JSON всё равно собирается в cache/last_sent.json; переопределить путь можно через FLAT_AGENT_CONF)"
    else
        info "PUSH_URLS не задан — push пропущен, JSON собирается в cache/last_sent.json"
    fi
fi

daemon_main
