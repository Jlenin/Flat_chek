#!/bin/bash
# flat_check_agent.sh — автономный health-check агент для мониторинга.
#
# Не интерактивный, без --help, без сессионного лога: считает состояние
# хоста (те же продукты/пакеты/инфраструктура/сертификаты, что и полный
# flat_check --json) и печатает JSON v2 в stdout; если задан PUSH_URLS —
# ещё и отправляет его на все указанные http/https-адреса.
#
# ПОЛНОСТЬЮ САМОСТОЯТЕЛЬНЫЙ ФАЙЛ: не подключает (source) ничего из
# flat_check_modular/ или корневых flat_check.sh/flat_check_2.sh — нужный
# код скопирован сюда напрямую (см. "Источник:" в заголовке каждого блока
# ниже), чтобы на хосте мониторинга было ровно ОДИН файл без внешних
# зависимостей. Если меняете логику проверки в оригиналах — не забудьте
# перенести правку и сюда (и наоборот).
#
# БЕЗ АРГУМЕНТОВ КОМАНДНОЙ СТРОКИ. Конфигурация — только переменные
# окружения и/или конфиг-файл рядом со скриптом (см. FLAT_AGENT_CONF ниже).
# Это даёт «одну строку» для cron/systemd timer:
#
#   */5 * * * * PUSH_URLS=https://partner.example/api/v1/health/ingest \
#               PUSH_TOKEN=*** HOST_ID=ss-n1 SERVICE_NAME=fss-backend \
#               /opt/flat/flat_check_agent.sh >/dev/null
#
# Либо через конфиг-файл (см. flat_check_agent.conf.example) — тогда
# командная строка ещё короче:
#
#   */5 * * * * /opt/flat/flat_check_agent.sh >/dev/null
#
# ПОТОКИ ВЫВОДА (важно для интеграции с мониторингом):
#   stdout — ТОЛЬКО JSON, одной строкой, ничего больше. Безопасно парсить
#            весь stdout как JSON, даже если настроен push.
#   stderr — диагностика push (curl-ошибки, "push: OK/FAIL"), если такая
#            была. При ручном запуске в терминале видно оба потока сразу —
#            то есть видно и результат (JSON), и что именно запушилось.
#
# КОД ВОЗВРАТА: 0 — JSON успешно собран (и, если был push, все URL приняли
# успешно); ненулевой — либо не удалось собрать JSON (редкость), либо хотя
# бы один push не прошёл. Само по себе содержимое JSON (какие пакеты не
# установлены и т.п.) на код возврата не влияет — это данные для дашборда,
# а не признак "скрипт сломался".
#
# ПРАВА ДОСТУПА: рассчитан на запуск ОБЫЧНЫМ пользователем, не root.
# Почти все проверки (dpkg/rpm/pacman/apk-запросы, systemctl status,
# слушающие порты, curl к локальным API, чтение публичных сертификатов)
# для этого прав не требуют. Единственное известное исключение — поле
# configs[].status="sudoers": обычный пользователь не может даже
# проверить существование файла внутри /etc/sudoers.d (там нет "x" для
# остальных) — деградирует до "missing" без ошибок. Подробности и
# необязательный ACL-пример — agent/flat_check_agent.sudoers.example.
#
# Версии: значение SCRIPT_VERSION ниже — версия ЭТОГО standalone-агента,
# отдельная от flat_check.sh/flat_check_2.sh/flat_check_modular (общая
# логика копируется, но версионируется независимо).

set -uo pipefail

SCRIPT_VERSION="1.0.0"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
[[ -z "$SCRIPT_DIR" ]] && SCRIPT_DIR="$(pwd)"

# ==========================================================================
# Глобальные переменные и дефолты
# ==========================================================================
# Источник: подмножество lib/core.sh (раздел 00_globals) + lib/agent.sh
# (раздел 01_config) из flat_check_modular — взяты только переменные,
# реально читаемые кодом ниже (проверено построчным grep по каждой).
# LOG_FILE сознательно НЕ инициализируется (никогда не вызываем
# init_logging) — сессионный лог этому агенту не нужен; _log_line() при
# пустом LOG_FILE и так тихо ничего не делает (см. её тело ниже).

# Цвета для info/warn/fail на экране (актуально только при ручном запуске
# в терминале — эти сообщения идут в stderr, см. шапку файла).
C_R='\033[0;31m'
C_G='\033[0;32m'
C_Y='\033[1;33m'
C_B='\033[0;34m'
C_C='\033[0;36m'
C_N='\033[0m'

LOG_FILE=""
DEBUG_MODE="${DEBUG_MODE:-0}"

# Идентификация хоста / агента push (приоритет: env > conf-файл > пусто).
HOST_ID="${HOST_ID:-}"
HOST_IP="${HOST_IP:-}"
SERVICE_NAME="${SERVICE_NAME:-}"
PUSH_URLS="${PUSH_URLS:-${PUSH_URL:-}}"
PUSH_TOKEN="${PUSH_TOKEN:-}"
PUSH_TOKENS="${PUSH_TOKENS:-}"
PUSH_AUTH_HEADER="${PUSH_AUTH_HEADER:-Authorization: Bearer}"
PUSH_CONNECT_TIMEOUT="${PUSH_CONNECT_TIMEOUT:-5}"
PUSH_MAX_TIME="${PUSH_MAX_TIME:-30}"
PUSH_RETRIES="${PUSH_RETRIES:-2}"
PUSH_INSECURE="${PUSH_INSECURE:-0}"

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
# Источник: перенесено без изменений логики из flat_check_modular/lib/core.sh
# (раздел 01_catalog). Единственная правка: каталог ищется РЯДОМ со скриптом
# (flat_check.packages.conf), а не в подпапке conf/ — "всё в одном месте".
# Данные каталога (кто от чего зависит) НЕ менялись.

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
    # В модульной раскладке каталог лежит в conf/, а не рядом со скриптом
    # (как в оригинальных flat_check.sh/flat_check_2.sh) — см. ARCHITECTURE.md.
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
# Источник: перенесено без изменений логики из flat_check_modular/lib/core.sh
# (разделы 02_output/04_os_detect/05_system_metrics/06_resource_gate/
# 07_pkg_checks/08_infra_checks) — только функции, реально нужные
# build_health_json()/push_health_json() ниже (проверено построчным
# грепом call-graph, не на глаз).

_log_line() {
    [[ -n "${LOG_FILE:-}" ]] || return 0
    # Группа скобок обязательна: если каталог LOG_FILE уже исчез (сборщик
    # только что заархивировал и удалил WORK_DIR), сам bash печатает "No such
    # file or directory" в свой stderr при настройке редиректа >> — до того,
    # как успевает сработать 2>/dev/null самой команды printf.
    { printf '%s [%-5s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" "$2" >> "$LOG_FILE"; } 2>/dev/null
}

log_debug() {
    _log_line "DEBUG" "$1"
    [[ "${DEBUG_MODE:-0}" -eq 1 ]] && echo -e "${C_C}[DEBUG]${C_N} $1" >&2
}

print_info() {
    # В stderr (не stdout): stdout зарезервирован строго под JSON-ответ.
    echo -e "${C_B}[INFO]${C_N}  $1" >&2
    _log_line "INFO" "$1"
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

    print_info "OS: $OS_FULL_VER"
    print_info "Package manager: $PM"
    echo ""
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

get_pkg_version() { _pkg_version "$1"; }

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
    dep=$(echo "$dep" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
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

_register_pkg_deps() {
    local pkg="$1"
    local deps_meta="${PKG_DEPS[$pkg]:-}"
    local deps_real dep

    if [[ -n "$deps_meta" ]]; then
        for dep in $(echo "$deps_meta" | tr ',' ' '); do
            register_dep "$dep" "$pkg"
        done
    fi
    deps_real=$(get_pkg_depends "$pkg" 2>/dev/null)
    if [[ -n "$deps_real" ]]; then
        for dep in $(echo "$deps_real" | tr ',' ' '); do
            register_dep "$dep" "$pkg"
        done
    fi
}

_is_infrastructure_pkg() {
    [[ "${PKG_PRODUCT[$1]:-}" == "Infrastructure" ]]
}

# ==========================================================================
# Конфиг агента + сборка health JSON v2
# ==========================================================================
# Источник: перенесено без изменений логики из
# flat_check_modular/lib/agent.sh (разделы 01_config/02_json_build).
# _json_print() НЕ перенесена — она выбирает pretty/compact по TTY, а этому
# агенту всегда нужен компактный однострочный JSON (как при пайпе/cron).

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

# ==========================================================================
# РАЗДЕЛ: 02_json_build
# ==========================================================================
# Назначение: Сборка полного health JSON v2 (build_health_json) и его частей —
#   идентификация хоста, экранирование строк, снимок одного пакета, снимок
#   системных метрик, infrastructure/depends, список репозиториев.
# Публичные функции: build_health_json(), _json_ensure_identity(),
#   _json_detect_host_ip(), _json_esc(s), _json_arr_from_csv(csv),
#   _json_collect_pkg(pkg), _json_collect_system(), _json_collect_infra(),
#   _json_collect_repos(), _json_print(body)
# Зависит от: 01_config.sh (переменные-дефолты), lib/core (_sys_cpu_via_procstat,
#   _sys_pkg_pids, get_dep_version, get_pkg_depends, is_dep_installed,
#   is_lib_available, is_pkg_installed_tiny, get_pkg_version, register_dep через
#   _register_pkg_deps, detect_os, PKG_PRODUCT/PKG_LEGACY/PKG_PORTS/PKG_API/PKG_DEPS,
#   ALL_DEPENDS, FLAT_PRODUCTS_ORDER)
# Не зависит от: lib/logging — ничего из сборщика логов здесь не используется
# Side effects: запускает systemctl/dpkg/rpm/ss/curl/openssl/df; пишет во временный
#   каталог $_JSON_TMP (сертификаты передаются через файл, не через subshell —
#   иначе терялись бы вместе с состоянием CPU-дельты, см. комментарий ниже)
#
# Источник: перенесено без изменений логики из agent/json_report.inc.sh
#   (строки 87-465 и 468-574 — build_health_json; _json_print — строки 656-666,
#   вынесен сюда, а не в 03_push.sh, т.к. используется и при простом --json
#   без --push).
#
# ОБНАРУЖЕННОЕ РАСХОЖДЕНИЕ (найдено при сверке --json со старым flat_check.sh,
# не исправлено в оригиналах в рамках этой задачи — см. CONTEXT.md/README для
# отдельного тикета): agent/json_report.inc.sh отстал от копий, вшитых в
# flat_check.sh/flat_check_2.sh, в блоке directories внутри _json_collect_pkg —
# он не пропускал через _is_infrastructure_pkg() и показывал бы для
# nginx/postgresql/mariadb выдуманные пути /opt/flat/<pkg> со статусом
# "missing" вместо честного "n/a" (эти пакеты не живут под /opt/flat). Взята
# исправленная версия из flat_check.sh/flat_check_2.sh (идентична в обоих).


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

    # directories (FLAT layout; Infrastructure — системные пакеты без /opt/flat)
    if _is_infrastructure_pkg "$pkg"; then
        opt_status="n/a"
        log_status="n/a"
        opt_path=""
        log_path=""
    else
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

# ==========================================================================
# Отправка JSON на PUSH_URLS
# ==========================================================================
# Источник: перенесено без изменений логики из
# flat_check_modular/lib/agent.sh (раздел 03_push, push_health_json()) —
# run_health_json() НЕ перенесена, у этого агента свой диспетчер (см. ниже).

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


# ==========================================================================
# Точка входа: без argv — всё поведение определяется env/конфигом выше.
# ==========================================================================
# Конфиг-файл: рядом со скриптом по умолчанию ("всё в одном месте"),
# переопределяется переменной окружения FLAT_AGENT_CONF. Отсутствие файла —
# не ошибка (_json_load_config() тихо возвращается, если файла нет) —
# тогда работают только значения из окружения/дефолтов выше.
FLAT_AGENT_CONF="${FLAT_AGENT_CONF:-$SCRIPT_DIR/flat_check_agent.conf}"
_json_load_config "$FLAT_AGENT_CONF"

# _json_ensure_identity() вызывается внутри build_health_json() ниже —
# отдельно здесь не нужна.
body=""
if ! body=$(build_health_json); then
    fail "flat_check_agent: не удалось собрать JSON"
    exit 1
fi

# stdout — ТОЛЬКО это. Ничего больше сюда не печатать.
printf '%s\n' "$body"

if [[ -n "$PUSH_URLS" ]]; then
    push_health_json "$body"
    exit $?
fi

exit 0
