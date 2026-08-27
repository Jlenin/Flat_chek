# Слой: core
# Всегда подключается. Health-check, каталог пакетов, вывод, i18n,
# ОС-детект, системные метрики, resource-gate, проверки пакетов/инфраструктуры,
# argv/usage/диспетчер, интерактивный мастер, selftest.
#
# Разделы этого файла (в порядке подключения; искать по "РАЗДЕЛ: <имя>"):
#   00_globals               Глобальные флаги, счётчики (ERRORS/WARNINGS/...), цвета вывода, переменные окружения PUSH_*/HOST_*, читаемые из env до parse_args, и CLI-флаги режимов -i/-log (нужны parse_args() ещё до того, как известно, подключён ли lib/logging в этом запуске).
#   01_catalog               Каталог продуктов/пакетов: _pkg_set() регистрирует запись (имя пакета, продукт, legacy-имена, порты, API-путь, deps), builtin-fallback и загрузка внешнего flat_check.packages.conf.
#   02_output                Печать статусов (ok/warn/fail/info), запись сессионного лога (_log_line/log_debug/init_logging), die().
#   03_i18n                  Локализация текстов интерфейса (_l key) — переключается через переменную CURRENT_LANG (по умолчанию en, мастер переключает на ru). Используется в основном мастером и сборщиком логов (lib/logging), но живёт в core, т.к. это универсальная утилита без зависимостей от остальных слоёв.
#   04_os_detect             Определение дистрибутива и пакетного менеджера (dpkg/rpm/pacman/apk) — detect_os().
#   05_system_metrics        Обзор ресурсов хоста для дашборда/health JSON: CPU (по ОС-семействам), память, диск, PostgreSQL/MariaDB роль и репликация, сеть, сертификаты, uptime.
#   06_resource_gate         Общий host-wide resource-gate (CPU/MEM ≥ 80% → не стартовать новый воркер, минимум один воркер всегда разрешён) — переиспользуется и параллельным опросом пакетов, и offline-сборщиком логов в lib/logging.
#   07_pkg_checks            Низкоуровневые примитивы по пакетному менеджеру (зависимости, версия, наличие) и проверки состояния конкретного продукта/пакета (служба, порт, API, логи, конфиги).
#   08_infra_checks          Инфраструктурные пакеты (nginx/postgresql/mariadb — без require /opt/flat), список репозиториев по PM, финальный === Summary ===.
#   09_argv                  Разбор аргументов командной строки (usage()/parse_args()) и финальный диспетчер режимов (dispatch_main()) — какой путь выполнить после того, как флаги разобраны и точка входа подключила lib/agent и/или lib/logging (если они понадобились по флагам).
#   10_wizard                Интерактивный мастер (-i/--interactive) — язык, выбор режима (health/сбор логов/самотест), для сбора логов: online/offline, scope, диапазон времени, chunk-настройки, выбор продуктов/служб/типов логов.
#   11_selftest              --selftest simple|extended — самопроверка ключевых функций/каталога без реального воздействия на систему (кроме чтения состояния). simple — быстрый smoke-test хелперов core+agent; extended — то же плюс проверки lib/logging (парсеры времени, resource-gate, seek+chunk extract) и VERBOSE health-прогон по всем продуктам (то же самое, что --dev).
#
# До объединения (см. git-историю фазы 5) это было 12 отдельных
# файлов lib/core/NN_name.sh — слиты в один по итогам код-ревью: три с половиной
# десятка файлов на весь проект оказались избыточной дробностью для инструмента,
# который должен быть понятен человеку без глубокого знания bash. Внутренние
# границы (заголовки "РАЗДЕЛ:") и порядок — те же самые.
# ==========================================================================
# РАЗДЕЛ: 00_globals
# ==========================================================================
# Назначение: Глобальные флаги, счётчики (ERRORS/WARNINGS/...), цвета вывода,
#   переменные окружения PUSH_*/HOST_*, читаемые из env до parse_args, и CLI-флаги
#   режимов -i/-log (нужны parse_args() ещё до того, как известно, подключён ли
#   lib/logging в этом запуске).
# Публичные функции: (нет функций — только объявления переменных)
# Зависит от: ничего
# Не зависит от: от всех остальных модулей — грузится первым
# Side effects: не пишет и не запускает ничего, только присваивает переменные
#
# Источник: перенесено без изменений логики из flat_check.sh (строки 37-96)
#   + CLI-флаги -i/-log из flat_check_2.sh (section 0, строки 90-199).

# --- 0. Глобальные переменные ---------------------------------------------------

# Путь и имя скрипта — для сессионного лога; вычисляем один раз.
# ВАЖНО: в модульной версии этот файл сам подключается через `source` из
# lib/core/*.sh, поэтому ${BASH_SOURCE[0]} здесь указывал бы на путь ЭТОГО
# файла (lib/core.sh (раздел 00_globals)), а не на точку входа `flat_check`. Точка
# входа обязана выставить SCRIPT_DIR/SCRIPT_NAME ДО подключения core — здесь
# только страховка на случай, если модуль когда-нибудь подключат отдельно.

: "${SCRIPT_DIR:=$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)}"
[[ -z "$SCRIPT_DIR" ]] && SCRIPT_DIR="$(pwd)"
: "${SCRIPT_NAME:=$(basename "${BASH_SOURCE[0]}")}"
SCRIPT_NAME="${SCRIPT_NAME%.sh}"

# Путь текущего сессионного лог-файла (<SCRIPT_NAME>.log); "" = логирование в
# файл отключено (нет прав на запись).
LOG_FILE=""

# Цвета
C_R='\033[0;31m'
C_G='\033[0;32m'
C_Y='\033[1;33m'
C_B='\033[0;34m'
C_C='\033[0;36m'
C_N='\033[0m'

ERRORS=0
WARNINGS=0
INSTALLED=0
NOT_INSTALLED=0
VERBOSE=0
SHOW_REPO=0
MODE_DEV=0
# --debug: дублировать log_debug() на экран (обычно только в LOG_FILE) —
# для диагностики без доступа к файлу сессионного лога
DEBUG_MODE=0
# Самотест: "" | simple | extended
SELFTEST_MODE=""

# Агент JSON/push (см. agent/ и блок JSON report)
OUTPUT_JSON=0
DO_PUSH=0
CONFIG_FILE=""
SINGLE_PKG=""
FILTER_PRODUCT=""
HOST_ID="${HOST_ID:-}"
HOST_IP="${HOST_IP:-}"
SERVICE_NAME="${SERVICE_NAME:-}"
PUSH_URLS="${PUSH_URLS:-}"
PUSH_TOKEN="${PUSH_TOKEN:-}"
PUSH_TOKENS="${PUSH_TOKENS:-}"
PACKAGES="${PACKAGES:-}"
PRODUCT="${PRODUCT:-}"
SHOW_REPOS_JSON=0

# Параллельный опрос пакетов (тот же resource-gate, что в flat_check_2.sh)
COLLECTOR_JOB_PIDS=()
# 0 = авто (nproc * RESOURCE_CPU_LIMIT%), либо COLLECTOR_JOBS / -j
COLLECTOR_JOBS=0
RESOURCE_CPU_LIMIT=80
RESOURCE_MEM_LIMIT=80
RESOURCE_WAIT_MAX=120
# Снимок /proc/stat для расчёта дельты CPU
_CPU_PREV_IDLE=""
_CPU_PREV_TOTAL=""

# Режимы/флаги CLI, специфичные для -i (мастер) и -log (сборщик логов,
# lib/logging) — объявлены здесь, а не в lib/logging, потому что parse_args()
# (lib/core.sh (раздел 09_argv)) разбирает их независимо от того, подключён ли
# lib/logging в этом запуске (см. flat_check_2.sh, section 0, строки 90-199).
MODE_LOG=0
MODE_INTERACTIVE=0
LOG_SUBMODE="online"
START_TCPDUMP=1
TIMEOUT_RAW=""
FROM_TIME=""
TO_TIME=""
CLI_TIMEOUT_SET=0
CLI_FROM_SET=0
CLI_TO_SET=0
CLI_T_AS_TO=0
CLI_TIMEOUT_BEFORE_FROM=0
OUTPUT_DIR=""
LOG_SCOPE="brief"
SELECTED_PRODUCTS=()   # имена продуктов из -p / мастера (в режиме -log)
SELECTED_SERVICES=()   # имена пакетов из -s / мастера
LIST_TARGETS=0
INCLUDE_MGCPCLIENT=""
LOG_CHUNK_MODE="size"
LOG_CHUNK_SIZE_BYTES=$((100 * 1024 * 1024))
LOG_CHUNK_LINES=500000


# ==========================================================================
# РАЗДЕЛ: 01_catalog
# ==========================================================================
# Назначение: Каталог продуктов/пакетов: _pkg_set() регистрирует запись (имя пакета, продукт, legacy-имена, порты, API-путь, deps), builtin-fallback и загрузка внешнего flat_check.packages.conf.
# Публичные функции: _pkg_set(), _pkg_catalog_builtin(), _load_pkg_catalog()
# Зависит от: 00_globals.sh
# Не зависит от: от вывода, ОС-детекта, проверок пакетов — сам только наполняет PKG_* массивы
# Side effects: читает conf/flat_check.packages.conf с диска, если он есть рядом со скриптом
#
# Источник: перенесено без изменений логики из flat_check.sh (строки 97-282).

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
    local conf="${SCRIPT_DIR:-.}/conf/flat_check.packages.conf"
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
# РАЗДЕЛ: 02_output
# ==========================================================================
# Назначение: Печать статусов (ok/warn/fail/info), запись сессионного лога (_log_line/log_debug/init_logging), die().
# Публичные функции: print_ok/warn/fail/info/not_installed(), ok/warn/fail/info(), _log_line(), log_debug(), init_logging(), die()
# Зависит от: 00_globals.sh (ERRORS/WARNINGS/LOG_FILE/DEBUG_MODE/цвета)
# Не зависит от: от каталога, ОС-детекта, проверок — используется ими, а не наоборот
# Side effects: пишет в LOG_FILE (session-лог), печатает в stdout/stderr
#
# Источник: перенесено без изменений логики из flat_check.sh (строки 283-372).
# Единственная сознательная правка: баннер в init_logging() печатал
# "${SCRIPT_NAME}.sh v..." — там ".sh" дописывался руками, т.к. SCRIPT_NAME
# всегда был "flat_check"/"flat_check_2" без расширения. Точка входа новой
# сборки называется просто `flat_check` (без .sh), поэтому дописывание ".sh"
# убрано — иначе баннер лгал бы ("flat_check.sh" при реальном имени файла
# "flat_check"). Сам факт и текст остальных сообщений не менялся.
#
# Вторая правка (фаза 3, при добавлении lib/logging): die() здесь портирован
# из flat_check.sh как `die() { fail "$1"; exit 1; }` — health-only скрипт не
# знает о рабочих каталогах сборщика логов. flat_check_2.sh (строка 512)
# определяет die() как `fail "$1"; cleanup 2>/dev/null; exit 1;`, чтобы
# фатальная ошибка в режиме -log не оставляла недоделанный рабочий каталог.
# В unified-инструменте die() общий на все режимы, поэтому взята версия
# flat_check_2.sh: `cleanup` определена только в lib/logging.sh (раздел 07_collector),
# но 2>/dev/null безопасно проглатывает "command not found", если lib/logging
# не подключён (health-only запуск) — ровно так же безопасно, как и в
# оригинале, где cleanup() тоже мог быть вызван до того, как до неё дошли
# другие ветки кода.

# --- 2. Хелперы вывода + логирование в файл --------------------------------------
# (print_ok / print_warn / print_fail / print_info — используются при проверке состояния)

# Пишет строку сессионного лога (без ANSI-кодов, с таймстампом и уровнем).
# Тихо ничего не делает, если LOG_FILE не задан/недоступен для записи —
# логирование в файл никогда не должно ронять сам скрипт или его вывод.

_log_line() {
    [[ -n "${LOG_FILE:-}" ]] || return 0
    # Группа скобок обязательна: если каталог LOG_FILE уже исчез (сборщик
    # только что заархивировал и удалил WORK_DIR), сам bash печатает "No such
    # file or directory" в свой stderr при настройке редиректа >> — до того,
    # как успевает сработать 2>/dev/null самой команды printf.
    { printf '%s [%-5s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" "$2" >> "$LOG_FILE"; } 2>/dev/null
}

# Технические подробности обычно только в файл лога (снимки CPU/MEM и т.п.) —
# не выводятся на экран, чтобы не перегружать вывод. С --debug — дублируются
# и на экран (stderr), чтобы разбирать проблему прямо в терминале.
log_debug() {
    _log_line "DEBUG" "$1"
    [[ "${DEBUG_MODE:-0}" -eq 1 ]] && echo -e "${C_C}[DEBUG]${C_N} $1" >&2
}

# Инициализирует LOG_FILE в $dir/${SCRIPT_NAME}.log (перезаписывается на
# каждом запуске — без ротации, чтобы файл не разрастался при частых
# вызовах из cron/Zabbix). При отсутствии прав на запись — тихо отключает
# логирование в файл (на экран это не влияет).
init_logging() {
    local dir="${1:-$SCRIPT_DIR}"
    LOG_FILE="${dir%/}/${SCRIPT_NAME}.log"
    if ! { : > "$LOG_FILE"; } 2>/dev/null; then
        LOG_FILE=""
        return 1
    fi
    _log_line "INFO" "=== ${SCRIPT_NAME} v${SCRIPT_VERSION} — сессия начата ==="
    # Версия на экран в human-режиме (при --json/--push только в session-log)
    if [[ "${OUTPUT_JSON:-0}" -ne 1 && "${DO_PUSH:-0}" -ne 1 ]]; then
        info "${SCRIPT_NAME} v${SCRIPT_VERSION}"
    fi
    if [[ "${PKG_CATALOG_SOURCE:-internal}" == "external" ]]; then
        _log_line "INFO" "package catalog: external (${PKG_CATALOG_PATH})"
        if [[ "${OUTPUT_JSON:-0}" -ne 1 && "${DO_PUSH:-0}" -ne 1 ]]; then
            info "package catalog: external (${PKG_CATALOG_PATH})"
        fi
    else
        _log_line "INFO" "package catalog: internal (builtin)"
        if [[ "${OUTPUT_JSON:-0}" -ne 1 && "${DO_PUSH:-0}" -ne 1 ]]; then
            info "package catalog: internal (builtin)"
        fi
    fi
    return 0
}


print_ok() {
    echo -e "${C_G}[OK]${C_N}    $1"
    _log_line "OK" "$1"
}

print_warn() {
    echo -e "${C_Y}[WARN]${C_N}  $1"
    _log_line "WARN" "$1"
    ((WARNINGS++))
}

print_fail() {
    echo -e "${C_R}[FAIL]${C_N}  $1"
    _log_line "FAIL" "$1"
    ((ERRORS++))
}

print_info() {
    echo -e "${C_B}[INFO]${C_N}  $1"
    _log_line "INFO" "$1"
}

print_not_installed() {
    echo -e "${C_B}[INFO]${C_N}  $1 — not installed"
    _log_line "INFO" "$1 — not installed"
}

# Короткие псевдонимы (selftest / внутренние хелперы)
ok()  { echo -e "${C_G}[OK]${C_N}  $1"; _log_line "OK" "$1"; }
warn() { echo -e "${C_Y}[WARN]${C_N} $1"; _log_line "WARN" "$1"; }
fail() { echo -e "${C_R}[FAIL]${C_N} $1"; _log_line "FAIL" "$1"; }
info() { echo -e "${C_B}[INFO]${C_N} $1"; _log_line "INFO" "$1"; }

die() { fail "$1"; cleanup 2>/dev/null; exit 1; }



# ==========================================================================
# РАЗДЕЛ: 03_i18n
# ==========================================================================
# Назначение: Локализация текстов интерфейса (_l key) — переключается через
#   переменную CURRENT_LANG (по умолчанию en, мастер переключает на ru).
#   Используется в основном мастером и сборщиком логов (lib/logging), но
#   живёт в core, т.к. это универсальная утилита без зависимостей от
#   остальных слоёв.
# Публичные функции: _l(key) — печатает локализованную строку по ключу
# Зависит от: 00_globals.sh (объявляет свой собственный CURRENT_LANG ниже,
#   чтобы не требовать правки 00_globals.sh, у которого в flat_check.sh
#   такой переменной не было — i18n нужен только logging/wizard)
# Не зависит от: каталога, вывода, ОС-детекта, проверок пакетов
# Side effects: нет — чистая функция, только echo
#
# Источник: перенесено без изменений логики из flat_check_2.sh (строки 514-736,
#   плюс объявление CURRENT_LANG из строки 128 той же секции 0).


CURRENT_LANG="${CURRENT_LANG:-en}"

# --- 2b. Локализация (_l) --------------------------------------------------------
_l() {
    local key="$1"
    case "$CURRENT_LANG" in
        ru)
            case "$key" in
                err_online_need_t) echo "Online без TTY требует -t/--timeout" ;;
                ask_lang_prompt)   echo "Ваш выбор / Your choice [1-2]: " ;;
                mode_log)          echo "Режим логов" ;;
                workdir)           echo "Рабочая директория" ;;
                found_svcs)        echo "Найдено служб" ;;
                found_logdirs)     echo "Найдено лог-директорий" ;;
                tail_running)      echo "Процессов tail" ;;
                tcpdump_started)   echo "tcpdump запущен (PID" ;;
                tcpdump_fail)      echo "tcpdump не запустился (нужен root?)" ;;
                tcpdump_notfound)  echo "tcpdump не найден" ;;
                log_running)       echo "Сбор логов запущен. Нажмите [Enter] для остановки." ;;
                log_running_online_note) echo "Online: в архив попадают только НОВЫЕ строки, появившиеся после старта сбора." ;;
                log_archive_stats) echo "Лог-файлов с данными в архиве:" ;;
                log_online_no_new) echo "За время сбора новых записей в логах не было (online пишет только новые строки)" ;;
                log_autostop)      echo "Автоостановка через" ;;
                log_stopping)      echo "Остановка сбора..." ;;
                log_files_from)    echo "файлов из" ;;
                log_copydone)      echo "Копирование завершено" ;;
                log_all)           echo "Копирование всех логов" ;;
                archive_pigz)      echo "Архив создан (pigz)" ;;
                archive_gzip)      echo "Архив создан (gzip)" ;;
                archive_at)        echo "Архив" ;;
                done_msg)          echo "Готово" ;;
                err_no_logdirs)    echo "Не найдено лог-директорий" ;;
                err_no_logfiles)   echo "Нет лог-файлов для мониторинга" ;;
                err_perm)          echo "Нет прав на запись" ;;
                err_cmd_notfound)  echo "Не найдена команда" ;;
                config_collected)  echo "Собрано конфигов" ;;
                sys_copied)        echo "Скопирован" ;;
                wiz_title_mode)    echo "=== Режим ===" ;;
                wiz_mode_1)        echo "  1 — Проверка служб (health check)" ;;
                wiz_mode_2)        echo "  2 — Сбор логов" ;;
                wiz_mode_3)        echo "  3 — Самотест скрипта" ;;
                wiz_mode_prompt)   echo "Ваш выбор [1-3]: " ;;
                wiz_title_selftest) echo "=== Самотест ===" ;;
                wiz_selftest_1)    echo "  1 — Простой (факт запуска функций)" ;;
                wiz_selftest_2)    echo "  2 — Расширенный (варианты + health + seek/chunk)" ;;
                wiz_selftest_prompt) echo "Ваш выбор [1-2]: " ;;
                wiz_title_type)    echo "=== Тип сбора ===" ;;
                wiz_type_1)        echo "  1 — Online (tail -F, в реальном времени)" ;;
                wiz_type_2)        echo "  2 — Offline (копирование готовых логов)" ;;
                wiz_type_prompt)   echo "Ваш выбор [1-2]: " ;;
                wiz_timeout)       echo -n "Таймаут сбора (например 5h, 30m, Enter = бесконечно): " ;;
                wiz_tcpdump)       echo -n "tcpdump? (y/n): " ;;
                wiz_title_range)   echo "=== Диапазон ===" ;;
                wiz_range_1)       echo "  1 — За последние N (например 5h)" ;;
                wiz_range_2)       echo "  2 — От даты-времени до даты-времени" ;;
                wiz_range_3)       echo "  3 — От даты-времени + N часов/минут" ;;
                wiz_range_all)     echo "  Enter — Все логи" ;;
                wiz_range_prompt)  echo "Ваш выбор [1-3]: " ;;
                wiz_for_how_long)  echo -n "За сколько? (например 5h, 30m): " ;;
                wiz_from_dt)       echo -n "От (например 25.06.2026 10:00): " ;;
                wiz_to_dt)         echo -n "До (например 25.06.2026 12:00): " ;;
                wiz_from_dt2)      echo -n "От (например 25.06.2026 10:00): " ;;
                wiz_for_offset)    echo -n "На сколько? (например +3h, 3h, +30m): " ;;
                wiz_title_chunk)   echo "=== Разбивка больших логов ===" ;;
                wiz_chunk_1)       echo "  1 — По размеру (например 100MB) [по умолчанию]" ;;
                wiz_chunk_2)       echo "  2 — По количеству строк (например 500000)" ;;
                wiz_chunk_prompt)  echo "Ваш выбор [1-2, Enter=1]: " ;;
                wiz_chunk_size_prompt)  echo -n "Максимальный размер одной части (например 50M, 200M; Enter = 100M): " ;;
                wiz_chunk_lines_prompt) echo -n "Максимум строк в одной части (Enter = 500000): " ;;
                wiz_chunk_size_invalid) echo "Не удалось разобрать размер, используется значение по умолчанию:" ;;
                wiz_output_dir)    echo -n "Директория для архива (Enter = рядом со скриптом): " ;;
                wiz_show_repo)     echo -n "Показать репозитории? (y/n): " ;;
                wiz_title_scope)   echo "=== Объём сбора ===" ;;
                wiz_scope_1)       echo "  1 — Краткий (только логи выбранных продуктов/служб)" ;;
                wiz_scope_2)       echo "  2 — Расширенный (+ system, nginx, PostgreSQL, configs; online: tcpdump)" ;;
                wiz_scope_prompt)  echo "Ваш выбор [1-2]: " ;;
                wiz_title_products) echo "=== Продукты ===" ;;
                wiz_products_all)  echo "  a — Все установленные" ;;
                wiz_products_prompt) echo -n "Номера через запятую/пробел, a=все, n=отмена: " ;;
                wiz_refine_services) echo -n "Уточнить службы? (y/n, Enter=n): " ;;
                wiz_title_services) echo "=== Службы ===" ;;
                wiz_services_all)  echo "  a — Все службы выбранных продуктов" ;;
                wiz_services_prompt) echo -n "Номера через запятую/пробел, a=все, n=отмена: " ;;
                wiz_refine_log_types) echo -n "Выбрать конкретные логи служб? (y/n, Enter=n): " ;;
                wiz_title_log_types) echo "=== Типы логов службы ===" ;;
                wiz_log_types_for) echo "Логи службы" ;;
                wiz_log_types_all) echo "  a — все найденные типы" ;;
                wiz_log_types_prompt) echo -n "Номера через запятую/пробел, a=все, n=отмена: " ;;
                wiz_log_types_none) echo "типы логов не найдены — будут собраны все доступные файлы" ;;
                wiz_preview_log_types) echo "типы логов" ;;
                wiz_no_targets)    echo "На хосте не найдено известных продуктов/служб" ;;
                wiz_preview_pkgs)  echo "Выбрано служб" ;;
                wiz_preview_dirs)  echo "Лог-директорий к сбору" ;;
                ask_mgcpclient)    echo -n "SoftSwitch (fss-server): собирать логи mgcpclient? (y/n, Enter=n): " ;;
                mgcpclient_default_no) echo "SoftSwitch (fss-server): mgcpclient пропущен (нет TTY; укажите --mgcpclient или --no-mgcpclient)" ;;
                mgcpclient_not_found) echo "mgcpclient: каталог логов не найден" ;;
                mgcpclient_include) echo "mgcpclient: добавлено каталогов" ;;
                mgcpclient_skip)   echo "mgcpclient: пропущен (файлы mgcpclient* и отдельные каталоги)" ;;
                resource_limits)   echo "Лимиты нагрузки системы (host-wide)" ;;
                collected)         echo "Скопирован" ;;
                skipped)           echo "Пропущено" ;;
                logs_absent_for_period) echo "за указанное время логи отсутствуют" ;;
                logs_absent_for_collection) echo "за время сбора логи отсутствуют" ;;
                logs_absent)       echo "логи отсутствуют" ;;
                absent_files_unit) echo "файлов" ;;
                more_files)        echo "ещё" ;;
                pg_logs_not_found) echo "каталог логов не найден (логирование в файл не настроено?)" ;;
                pg_logs_dir_missing) echo "каталог логов не существует:" ;;
                pg_logs_not_dir)   echo "путь логов не является каталогом:" ;;
                pg_logs_no_access) echo "нет доступа к каталогу логов:" ;;
                pg_logs_try_sudo)  echo "запустите от root или через sudo" ;;
                *)                 echo "$key" ;;
            esac
            ;;
        *)
            case "$key" in
                err_online_need_t) echo "Online without TTY requires -t/--timeout" ;;
                ask_lang_prompt)   echo "Your choice / Ваш выбор [1-2]: " ;;
                mode_log)          echo "Log mode" ;;
                workdir)           echo "Work directory" ;;
                found_svcs)        echo "Found services" ;;
                found_logdirs)     echo "Found log directories" ;;
                tail_running)      echo "Tail processes" ;;
                tcpdump_started)   echo "tcpdump started (PID" ;;
                tcpdump_fail)      echo "tcpdump failed to start (needs root?)" ;;
                tcpdump_notfound)  echo "tcpdump not found" ;;
                log_running)       echo "Log collection running. Press [Enter] to stop." ;;
                log_running_online_note) echo "Online: archive includes only NEW lines written after collection started." ;;
                log_archive_stats) echo "Log files with data in archive:" ;;
                log_online_no_new) echo "No new log lines during collection (online captures only new lines)" ;;
                log_autostop)      echo "Auto-stop in" ;;
                log_stopping)      echo "Stopping collection..." ;;
                log_files_from)    echo "files from" ;;
                log_copydone)      echo "Copy done" ;;
                log_all)           echo "Copying all logs" ;;
                archive_pigz)      echo "Archive created (pigz)" ;;
                archive_gzip)      echo "Archive created (gzip)" ;;
                archive_at)        echo "Archive" ;;
                done_msg)          echo "Done" ;;
                err_no_logdirs)    echo "No log directories found" ;;
                err_no_logfiles)   echo "No log files to monitor" ;;
                err_perm)          echo "Permission denied" ;;
                err_cmd_notfound)  echo "Command not found" ;;
                config_collected)  echo "Configs collected" ;;
                sys_copied)        echo "Copied" ;;
                wiz_title_mode)    echo "=== Mode ===" ;;
                wiz_mode_1)        echo "  1 — Health check" ;;
                wiz_mode_2)        echo "  2 — Log collection" ;;
                wiz_mode_3)        echo "  3 — Script self-test" ;;
                wiz_mode_prompt)   echo "Your choice [1-3]: " ;;
                wiz_title_selftest) echo "=== Self-test ===" ;;
                wiz_selftest_1)    echo "  1 — Simple (functions launch)" ;;
                wiz_selftest_2)    echo "  2 — Extended (variants + health + seek/chunk)" ;;
                wiz_selftest_prompt) echo "Your choice [1-2]: " ;;
                wiz_title_type)    echo "=== Collection type ===" ;;
                wiz_type_1)        echo "  1 — Online (tail -F, real-time)" ;;
                wiz_type_2)        echo "  2 — Offline (copy existing logs)" ;;
                wiz_type_prompt)   echo "Your choice [1-2]: " ;;
                wiz_timeout)       echo -n "Collection timeout (e.g. 5h, 30m, Enter = forever): " ;;
                wiz_tcpdump)       echo -n "tcpdump? (y/n): " ;;
                wiz_title_range)   echo "=== Range ===" ;;
                wiz_range_1)       echo "  1 — Last N (e.g. 5h)" ;;
                wiz_range_2)       echo "  2 — From date-time to date-time" ;;
                wiz_range_3)       echo "  3 — From date-time + N hours/minutes" ;;
                wiz_range_all)     echo "  Enter — All logs" ;;
                wiz_range_prompt)  echo "Your choice [1-3]: " ;;
                wiz_for_how_long)  echo -n "For how long? (e.g. 5h, 30m): " ;;
                wiz_from_dt)       echo -n "From (e.g. 25.06.2026 10:00): " ;;
                wiz_to_dt)         echo -n "To (e.g. 25.06.2026 12:00): " ;;
                wiz_from_dt2)      echo -n "From (e.g. 25.06.2026 10:00): " ;;
                wiz_for_offset)    echo -n "For how long? (e.g. +3h, 3h, +30m): " ;;
                wiz_title_chunk)   echo "=== Splitting large logs ===" ;;
                wiz_chunk_1)       echo "  1 — By size (e.g. 100MB) [default]" ;;
                wiz_chunk_2)       echo "  2 — By line count (e.g. 500000)" ;;
                wiz_chunk_prompt)  echo "Your choice [1-2, Enter=1]: " ;;
                wiz_chunk_size_prompt)  echo -n "Max size per part (e.g. 50M, 200M; Enter = 100M): " ;;
                wiz_chunk_lines_prompt) echo -n "Max lines per part (Enter = 500000): " ;;
                wiz_chunk_size_invalid) echo "Could not parse size, using default:" ;;
                wiz_output_dir)    echo -n "Output dir (Enter = script dir): " ;;
                wiz_show_repo)     echo -n "Show repositories? (y/n): " ;;
                wiz_title_scope)   echo "=== Collection scope ===" ;;
                wiz_scope_1)       echo "  1 — Brief (selected product/service logs only)" ;;
                wiz_scope_2)       echo "  2 — Extended (+ system, nginx, PostgreSQL, configs; online: tcpdump)" ;;
                wiz_scope_prompt)  echo "Your choice [1-2]: " ;;
                wiz_title_products) echo "=== Products ===" ;;
                wiz_products_all)  echo "  a — All present on host" ;;
                wiz_products_prompt) echo -n "Numbers (comma/space), a=all, n=cancel: " ;;
                wiz_refine_services) echo -n "Refine services? (y/n, Enter=n): " ;;
                wiz_title_services) echo "=== Services ===" ;;
                wiz_services_all)  echo "  a — All services of selected products" ;;
                wiz_services_prompt) echo -n "Numbers (comma/space), a=all, n=cancel: " ;;
                wiz_refine_log_types) echo -n "Select specific service logs? (y/n, Enter=n): " ;;
                wiz_title_log_types) echo "=== Service log types ===" ;;
                wiz_log_types_for) echo "Logs for" ;;
                wiz_log_types_all) echo "  a — all discovered types" ;;
                wiz_log_types_prompt) echo -n "Numbers (comma/space), a=all, n=cancel: " ;;
                wiz_log_types_none) echo "no log types found — all available files will be collected" ;;
                wiz_preview_log_types) echo "log types" ;;
                wiz_no_targets)    echo "No known products/services found on this host" ;;
                wiz_preview_pkgs)  echo "Selected services" ;;
                wiz_preview_dirs)  echo "Log directories to collect" ;;
                ask_mgcpclient)    echo -n "SoftSwitch (fss-server): collect mgcpclient logs? (y/n, Enter=n): " ;;
                mgcpclient_default_no) echo "SoftSwitch (fss-server): skipping mgcpclient (no TTY; pass --mgcpclient or --no-mgcpclient)" ;;
                mgcpclient_not_found) echo "mgcpclient: log directory not found" ;;
                mgcpclient_include) echo "mgcpclient: directories added" ;;
                mgcpclient_skip)   echo "mgcpclient: skipped (mgcpclient* files and extra dirs)" ;;
                resource_limits)   echo "Host system load limits" ;;
                collected)         echo "Copied" ;;
                skipped)           echo "Skipped" ;;
                logs_absent_for_period) echo "no logs for the specified time period" ;;
                logs_absent_for_collection) echo "no logs during collection" ;;
                logs_absent)       echo "no logs" ;;
                absent_files_unit) echo "files" ;;
                more_files)        echo "more" ;;
                pg_logs_not_found) echo "log directory not found (file logging not configured?)" ;;
                pg_logs_dir_missing) echo "log directory does not exist:" ;;
                pg_logs_not_dir)   echo "log path is not a directory:" ;;
                pg_logs_no_access) echo "no access to log directory:" ;;
                pg_logs_try_sudo)  echo "run as root or via sudo" ;;
                *)                 echo "$key" ;;
            esac
            ;;
    esac
}


# ==========================================================================
# РАЗДЕЛ: 04_os_detect
# ==========================================================================
# Назначение: Определение дистрибутива и пакетного менеджера (dpkg/rpm/pacman/apk) — detect_os().
# Публичные функции: detect_os(), get_os_release()
# Зависит от: 02_output.sh (log_debug)
# Не зависит от: от каталога пакетов и проверок — они читают уже установленную переменную PKG_MANAGER
# Side effects: читает /etc/os-release, запускает dpkg/rpm/pacman/apk для проверки наличия
#
# Источник: перенесено без изменений логики из flat_check.sh (строки 373-479).

# --- 3. ОС / пакетный менеджер ---------------------------------------------------
# Определить ОС и пакетный менеджер

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

# Канонический id дистрибутива для OS-специфичной диспетчеризации (get_sys_cpu_<id> и т.п.).
# Тот же порядок определения, что и в detect_os(): сначала /etc/os-release, затем legacy
# файлы релиза для систем без os-release. Чистая функция — без глобальных переменных,
# без вывода, просто печатает одно из:
#   debian ubuntu astra centos rhel oracle rocky almalinux arch alpine unknown
get_os_release() {
    local id=""

    if [[ -f /etc/os-release ]]; then
        id=$(. /etc/os-release 2>/dev/null; echo "${ID:-}")
        id="${id,,}"
    fi

    if [[ -z "$id" ]]; then
        if   [[ -f /etc/astra_version ]];     then id="astra"
        elif [[ -f /etc/centos-release ]];    then id="centos"
        elif [[ -f /etc/rocky-release ]];      then id="rocky"
        elif [[ -f /etc/almalinux-release ]];  then id="almalinux"
        elif [[ -f /etc/oracle-release ]];     then id="oracle"
        elif [[ -f /etc/redhat-release ]];     then id="rhel"
        elif [[ -f /etc/alpine-release ]];     then id="alpine"
        elif [[ -f /etc/arch-release ]];       then id="arch"
        elif [[ -f /etc/debian_version ]];     then id="debian"
        fi
    fi

    # Нормализуем пару алиасов, которые os-release использует, но которые не совпадают с
    # именами файлов релиза выше (у Oracle Linux ID "ol"; у RHEL — "redhat"
    # в очень старых релизах). Всё остальное передаётся как есть и
    # попадает в общую ветку диспетчеризации у вызывающего кода.
    case "$id" in
        ol)     id="oracle" ;;
        redhat) id="rhel" ;;
        "")     id="unknown" ;;
    esac

    echo "$id"
}


# ==========================================================================
# РАЗДЕЛ: 05_system_metrics
# ==========================================================================
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


# ==========================================================================
# РАЗДЕЛ: 06_resource_gate
# ==========================================================================
# Назначение: Общий host-wide resource-gate (CPU/MEM ≥ 80% → не стартовать новый воркер, минимум один воркер всегда разрешён) — переиспользуется и параллельным опросом пакетов, и offline-сборщиком логов в lib/logging.
# Публичные функции: _collector_max_jobs(), _collector_resources_ok(), _collector_wait_slot(), _collector_wait_all_jobs(), _get_cpu_usage_percent(), _get_mem_usage_percent()
# Зависит от: 00_globals.sh, 05_system_metrics.sh (_sys_cpu_via_procstat)
# Не зависит от: от каталога пакетов, вывода-текста, инфраструктуры — чистая утилита планирования воркеров
# Side effects: запускает фоновые job'ы (&) и ждёт их (wait); не пишет напрямую в лог
#
# Источник: перенесено без изменений логики из flat_check.sh (строки 2242-2397).

# --- 9. Параллельный опрос пакетов (resource-gate) ------------------------------
# Те же хелперы, что использует run_product_checks() в flat_check_2.sh.
# Имена _collector_* сохранены намеренно — поведение 1к1 с flat_check_2.

# Для health-check (без lib/logging) всегда «не останавливаться» — флагов
# сборщика логов (COLLECTOR_ABORTED/COLLECTOR_TIMEOUT_STOP) в этом режиме не
# существует. ВАЖНО: если lib/logging подключён, lib/logging.sh (раздел 07_collector)
# определяет _collector_should_stop() ПОВТОРНО (сознательно, тем же именем) —
# та версия реально проверяет сигналы Ctrl+C/timeout сборщика и, поскольку
# core грузится раньше logging, замещает этот стаб. Здесь — единственное
# намеренное переопределение функции между слоями во всём проекте; см. её
# заголовок в lib/logging.sh (раздел 07_collector), если меняете сигнатуру/поведение.

_collector_should_stop() {
    return 1
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



# ==========================================================================
# РАЗДЕЛ: 07_pkg_checks
# ==========================================================================
# Назначение: Низкоуровневые примитивы по пакетному менеджеру (зависимости, версия, наличие) и проверки состояния конкретного продукта/пакета (служба, порт, API, логи, конфиги).
# Публичные функции: get_pkg_depends(), get_dep_version(), is_dep_installed(), register_dep(), is_pkg_installed_tiny(), check_process(), check_ports(), check_api_health(), check_single_pkg(), run_product_checks(), is_lib_available()
# Зависит от: 00_globals.sh, 01_catalog.sh, 02_output.sh, 04_os_detect.sh, 05_system_metrics.sh (_sys_pkg_pids)
# Не зависит от: от инфраструктуры/repo-проверок и от agent/logging — это их общая база, а не наоборот
# Side effects: запускает dpkg/rpm/pacman/apk/systemctl/ss/curl; печатает разделы по продуктам; заполняет ALL_DEPENDS
#
# Источник: перенесено без изменений логики из flat_check.sh (строки 1006-1880).

# --- Список сырых зависимостей по PM -----------------------------------------
# По одной самодостаточной функции на каждый пакетный менеджер: печатает сырую,
# нефильтрованную строку зависимостей для установленного пакета, используя только
# инструмент(ы) этого PM; печатает ничего, если пакет не установлен.
# get_pkg_depends() ниже диспетчеризует по $PM, затем выполняет общую для обоих
# PM-агностичную очистку (убрать версионные ограничения/альтернативы, дедуп).

# Debian-семья: строка Depends: из dpkg -s, запасной вариант — apt-cache depends.

get_pkg_depends_dpkg() {
    local pkg="$1" deps=""

    dpkg-query -W -f='${Status}\n' "$pkg" 2>/dev/null | grep -q 'install ok installed' || return
    deps=$(dpkg -s "$pkg" 2>/dev/null | grep "^Depends:" | sed 's/^Depends: //')
    if [[ -z "$deps" ]]; then
        deps=$(apt-cache depends "$pkg" 2>/dev/null | grep -E "^\s+Depends:" | sed 's/.*Depends: //' | tr '\n' ', ' | sed 's/, $//')
    fi
    echo "$deps"
}

# RHEL-семья: сырой список requires из rpm -qR, отфильтрованный до реальных имён пакетов.
get_pkg_depends_rpm() {
    local pkg="$1" deps=""

    rpm -q "$pkg" &>/dev/null || return
    deps=$(rpm -qR "$pkg" 2>/dev/null | grep -v "^rpmlib(" | grep -v "^/" | grep -v "^config" | grep -v "^config(" | grep -vi "^package" | grep -vi "^пакет" | sed 's/ .*$//' | sort -u | tr '\n' ', ' | sed 's/, $//')
    echo "$deps"
}

# Получить реальные зависимости пакета из PM (только dpkg/rpm — у пакетов FLAT
# для pacman/apk реальные зависимости здесь и раньше не декларировались, до этого разделения тоже)
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

# --- Запрос версии по PM -------------------------------------------------------
# По одной самодостаточной функции на каждый пакетный менеджер: печатает установленную
# строку версии для имени (пакет или зависимость — поиск один и тот же
# в обоих случаях), либо ничего, если не найдено/не применимо.
# get_pkg_version()/get_dep_version() — это два имени для одной и той же диспетчеризации;
# раньше это были две копии друг друга, по одной на каждого вызывающего.

# Debian-семья: dpkg-query печатает поле Version напрямую.
_pkg_version_dpkg() {
    dpkg-query -W -f='${Version}' "$1" 2>/dev/null
}

# RHEL-семья: у rpm нет однопольного запроса версии, поэтому объединяем VERSION+RELEASE.
_pkg_version_rpm() {
    rpm -q --queryformat '%{VERSION}-%{RELEASE}' "$1" 2>/dev/null
}

# Arch: pacman -Q печатает "имя версия" в одной строке; версия — второе поле.
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

# Получить версию пакета из PM
get_pkg_version() { _pkg_version "$1"; }

# Получить версию зависимости из PM (тот же поиск, что и у get_pkg_version)
get_dep_version() { _pkg_version "$1"; }

# --- Проверка наличия зависимости по PM --------------------------------------
# Debian-семья: достаточно одного поля Status из dpkg-query.
_dep_installed_dpkg() {
    dpkg-query -W -f='${Status}\n' "$1" 2>/dev/null | grep -q 'install ok installed'
}

# RHEL-семья: достаточно одного кода возврата rpm -q.
_dep_installed_rpm() {
    rpm -q "$1" &>/dev/null
}

# Arch: достаточно одного кода возврата pacman -Q.
_dep_installed_pacman() {
    pacman -Q "$1" &>/dev/null
}

# Проверить, установлена ли зависимость (только dpkg/rpm/pacman, как и раньше)
is_dep_installed() {
    local dep="$1"
    case "$PM" in
        dpkg)   _dep_installed_dpkg "$dep" ;;
        rpm)    _dep_installed_rpm "$dep" ;;
        pacman) _dep_installed_pacman "$dep" ;;
        *)      return 1 ;;
    esac
}

# Проверить статус службы для зависимости (возвращает строку-описание)
check_dep_service() {
    local dep="$1"
    local svc=""
    local result=""

    # Соответствие распространённых имён пакетов именам служб
    case "$dep" in
        nginx) svc="nginx" ;;
        redis|redis-server) svc="redis-server" ;;
        mariadb|mysql-server|mariadb-server) svc="mariadb" ;;
        postgresql|postgresql-*) svc="postgresql" ;;
        rabbitmq-server|rabbitmq) svc="rabbitmq-server" ;;
        sudo) return 0 ;;  # у sudo нет службы
        *) return 0 ;;
    esac

    if command -v systemctl &>/dev/null; then
        local active
        active=$(systemctl is-active "${svc}.service" 2>/dev/null || echo "unknown")
        if [[ "$active" == "active" ]]; then
            result="service active"
        else
            result="service $active"
        fi
    fi
    echo "$result"
}

# Собрать зависимость в глобальный массив ALL_DEPENDS (dep -> "pkg1,pkg2")
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

# --- Пробы наличия пакета по PM -----------------------------------------------
# По одной самодостаточной функции на каждый пакетный менеджер: основное имя, затем
# каждое legacy-имя через запятую, используя только инструмент запроса этого PM — никаких
# команд других PM внутри. Каждая устанавливает FOUND_PKG_VER/FOUND_PKG_STATUS,
# печатает соответствующую строку ok/warn/fail и возвращает:
#   0 = установлен  1 = установлен, но не полностью настроен (только dpkg)
#   2 = вместо него найдено legacy-имя  3 = не найден совсем
# check_pkg_installed() ниже вызывает их только через диспетчеризацию по $PM.

# Debian-семья: dpkg-query даёт версию + полный статус установки за один вызов.
check_pkg_installed_dpkg() {
    local pkg="$1" legacy="$2" old found ver status

    found=$(dpkg-query -W -f='${Package}\t${Version}\t${Status}\n' "$pkg" 2>/dev/null)
    if [[ -n "$found" ]]; then
        ver=$(echo "$found" | awk '{print $2}')
        status=$(echo "$found" | awk '{$1=""; $2=""; print $0}' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        FOUND_PKG_VER="$ver"
        FOUND_PKG_STATUS="$status"
        if [[ "$status" == "install ok installed" ]]; then
            print_ok "pkg: $pkg installed"
            return 0
        else
            print_warn "pkg: $pkg installed but status='$status'"
            return 1
        fi
    fi

    for old in $(echo "$legacy" | tr ',' ' '); do
        found=$(dpkg-query -W -f='${Package}\t${Version}\t${Status}\n' "$old" 2>/dev/null)
        [[ -n "$found" ]] || continue
        ver=$(echo "$found" | awk '{print $2}')
        status=$(echo "$found" | awk '{$1=""; $2=""; print $0}' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        FOUND_PKG_VER="$ver"
        FOUND_PKG_STATUS="$status"
        print_warn "pkg: $pkg not found, but legacy '$old' exists ($ver)"
        return 2
    done

    print_fail "pkg: $pkg not installed"
    return 3
}

# RHEL-семья: rpm -q только подтверждает наличие, версия — из второго запроса.
check_pkg_installed_rpm() {
    local pkg="$1" legacy="$2" old ver

    if rpm -q "$pkg" &>/dev/null; then
        ver=$(rpm -q --queryformat '%{VERSION}-%{RELEASE}' "$pkg" 2>/dev/null)
        FOUND_PKG_VER="$ver"
        print_ok "pkg: $pkg installed"
        return 0
    fi

    for old in $(echo "$legacy" | tr ',' ' '); do
        rpm -q "$old" &>/dev/null || continue
        ver=$(rpm -q --queryformat '%{VERSION}-%{RELEASE}' "$old" 2>/dev/null)
        FOUND_PKG_VER="$ver"
        print_warn "pkg: $pkg not found, but legacy '$old' exists ($ver)"
        return 2
    done

    print_fail "pkg: $pkg not installed"
    return 3
}

# Arch: pacman -Q печатает "имя версия" в одной строке для установленного пакета.
check_pkg_installed_pacman() {
    local pkg="$1" legacy="$2" old ver

    if pacman -Q "$pkg" &>/dev/null; then
        ver=$(pacman -Q "$pkg" 2>/dev/null | awk '{print $2}')
        FOUND_PKG_VER="$ver"
        print_ok "pkg: $pkg installed"
        return 0
    fi

    for old in $(echo "$legacy" | tr ',' ' '); do
        pacman -Q "$old" &>/dev/null || continue
        ver=$(pacman -Q "$old" 2>/dev/null | awk '{print $2}')
        FOUND_PKG_VER="$ver"
        print_warn "pkg: $pkg not found, but legacy '$old' exists ($ver)"
        return 2
    done

    print_fail "pkg: $pkg not installed"
    return 3
}

# Alpine: apk info -e только подтверждает наличие, отдельный запрос версии здесь не используется.
check_pkg_installed_apk() {
    local pkg="$1" legacy="$2" old

    if apk info -e "$pkg" &>/dev/null; then
        print_ok "pkg: $pkg installed"
        return 0
    fi

    for old in $(echo "$legacy" | tr ',' ' '); do
        apk info -e "$old" &>/dev/null || continue
        print_warn "pkg: $pkg not found, but legacy '$old' exists"
        return 2
    done

    print_fail "pkg: $pkg not installed"
    return 3
}

# Проверить, установлен ли пакет через PM (подробно, печатает статус)
check_pkg_installed() {
    local pkg="$1"
    local legacy="$2"

    FOUND_PKG_VER=""
    FOUND_PKG_STATUS=""

    case "$PM" in
        dpkg)   check_pkg_installed_dpkg "$pkg" "$legacy" ;;
        rpm)    check_pkg_installed_rpm "$pkg" "$legacy" ;;
        pacman) check_pkg_installed_pacman "$pkg" "$legacy" ;;
        apk)    check_pkg_installed_apk "$pkg" "$legacy" ;;
        *)      print_fail "pkg: $pkg not installed"; return 3 ;;
    esac
}

has_any_trace() {
    local pkg="$1"
    local unit="${pkg}.service"
    [[ -f "/usr/lib/systemd/system/${unit}" ]] || [[ -f "/etc/systemd/system/${unit}" ]] || [[ -f "/lib/systemd/system/${unit}" ]] || [[ -d "/opt/flat/${pkg}" ]]
}

# --- Тихие проверки наличия по PM --------------------------------------------
# По одной самодостаточной функции на каждый пакетный менеджер для тихого (без вывода)
# быстрого пути: основное имя, затем каждое legacy-имя через запятую, используя только
# инструмент запроса этого PM. Возвращает 0, если найдено, иначе 1.
# is_pkg_installed_tiny() ниже пробует подходящую через $PM, затем всегда
# откатывается на has_any_trace() независимо от PM/результата.

# Debian-семья: достаточно одного поля Status из dpkg-query, версия не нужна.
is_pkg_installed_tiny_dpkg() {
    local pkg="$1" legacy="$2" old

    dpkg-query -W -f='${Status}\n' "$pkg" 2>/dev/null | grep -q 'install ok installed' && return 0
    for old in $(echo "$legacy" | tr ',' ' '); do
        dpkg-query -W -f='${Status}\n' "$old" 2>/dev/null | grep -q 'install ok installed' && return 0
    done
    return 1
}

# RHEL-семья: для проверки наличия достаточно одного кода возврата rpm -q.
is_pkg_installed_tiny_rpm() {
    local pkg="$1" legacy="$2" old

    rpm -q "$pkg" &>/dev/null && return 0
    for old in $(echo "$legacy" | tr ',' ' '); do
        rpm -q "$old" &>/dev/null && return 0
    done
    return 1
}

# Arch: для проверки наличия достаточно одного кода возврата pacman -Q.
is_pkg_installed_tiny_pacman() {
    local pkg="$1" legacy="$2" old

    pacman -Q "$pkg" &>/dev/null && return 0
    for old in $(echo "$legacy" | tr ',' ' '); do
        pacman -Q "$old" &>/dev/null && return 0
    done
    return 1
}

# Alpine: достаточно одного кода возврата apk info -e; legacy-цикла здесь
# не было и в исходном монолите — у пакетов FLAT для apk-семьи их просто нет.
is_pkg_installed_tiny_apk() {
    local pkg="$1"
    apk info -e "$pkg" &>/dev/null && return 0
    return 1
}

# Тихая быстрая проверка установки пакета (возвращает 0/1, без вывода)
is_pkg_installed() {
    is_pkg_installed_tiny "$@"
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

# Проверить systemd unit
check_systemd_unit() {
    local pkg="$1"
    local unit="${pkg}.service"
    local unit_file=""

    if [[ -f "/usr/lib/systemd/system/${unit}" ]]; then
        unit_file="/usr/lib/systemd/system/${unit}"
    elif [[ -f "/etc/systemd/system/${unit}" ]]; then
        unit_file="/etc/systemd/system/${unit}"
    elif [[ -f "/lib/systemd/system/${unit}" ]]; then
        unit_file="/lib/systemd/system/${unit}"
    fi

    if [[ -n "$unit_file" ]]; then
        print_ok "systemd unit: $unit_file exists"

        if command -v systemctl &>/dev/null; then
            local active
            active=$(systemctl is-active "$unit" 2>/dev/null)
            if [[ "$active" == "active" ]]; then
                print_ok "systemd: $unit is active"
            else
                print_warn "systemd: $unit is $active"
            fi

            local enabled
            enabled=$(systemctl is-enabled "$unit" 2>/dev/null)
            if [[ "$enabled" == "enabled" ]]; then
                print_ok "systemd: $unit is enabled"
            else
                print_warn "systemd: $unit is $enabled"
            fi
        fi
    else
        print_warn "systemd unit: $unit not found"
    fi
}

# Попытаться найти путь к логу из известных конфиг-файлов пакета
get_log_path_from_config() {
    local pkg="$1"
    local path=""
    local conf=""

    case "$pkg" in
        fss-server)
            for conf in "/opt/flat/fss-server/settings.ini" "/opt/flat/switchserver/settings.ini"; do
                [[ -f "$conf" ]] || continue
                path=$(grep -s '^LogPath=' "$conf" | head -1 | cut -d '=' -f 2-)
                [[ -n "$path" ]] && break
            done
            ;;
        fss-srclient)
            for conf in "/opt/flat/fss-srclient/settings.ini" "/etc/flat/srclient/settings.ini" "/opt/flat/srclient/settings.ini"; do
                [[ -f "$conf" ]] || continue
                path=$(grep -s '^logger_fileName' "$conf" | head -1 | sed -E 's/.*=\s*"([^"]*)".*/\1/')
                [[ -n "$path" ]] && break
            done
            ;;
        fss-mediasrv)
            for conf in "/opt/flat/fss-mediasrv/config.xml" "/etc/mediasrv/config.xml" "/opt/flat/mediasrv/config.xml"; do
                [[ -f "$conf" ]] || continue
                path=$(grep -s '<LogParams>' "$conf" | head -1 | sed -E 's/.*>([^<]*)<.*/\1/')
                [[ -n "$path" ]] && break
            done
            ;;
        flat-file)
            for conf in "/opt/flat/flat-file/config.yml" "/opt/flat/${pkg}/config.yml"; do
                [[ -f "$conf" ]] || continue
                path=$(grep -s '^\s*dir\s*:' "$conf" | head -1 | cut -d ':' -f 2- | xargs)
                [[ -n "$path" ]] && break
            done
            ;;
    esac

    echo "$path"
}

# Проверить директорию логов со свежестью и запасным вариантом из конфига
check_log_directory() {
    local pkg="$1"
    local log_dir="/var/log/flat/${pkg}"
    local found_log_dir=""
    local log_status=""

    # Проверить, является ли символьной ссылкой
    if [[ -L "$log_dir" ]]; then
        local target
        target=$(readlink -f "$log_dir" 2>/dev/null || readlink "$log_dir" 2>/dev/null)
        print_info "logdir: $log_dir is symlink -> $target"
        # Использовать целевой путь для дальнейших проверок
        log_dir="$target"
    fi

    # Проверить путь по умолчанию
    if [[ -d "$log_dir" ]]; then
        if find -L "$log_dir" -maxdepth 1 -type f -mmin -300 2>/dev/null | head -1 | grep -q .; then
            print_ok "logdir: $log_dir exists (fresh logs)"
            log_status="ok"
        elif [[ -n "$(find -L "$log_dir" -maxdepth 1 -type f 2>/dev/null | head -1)" ]]; then
            log_status="stale"
        else
            log_status="empty"
        fi
    else
        log_status="missing"
    fi

    if [[ "$log_status" == "ok" ]]; then
        local owner
        owner=$(stat -c '%U:%G' "$log_dir" 2>/dev/null || stat -f '%Su:%Sg' "$log_dir" 2>/dev/null)
        print_info "logdir: $log_dir owner=$owner"
        return 0
    fi

    # Проблема с путём по умолчанию — проверить, активен ли процесс.
    # _sys_pkg_pids() — не голый pgrep по имени пакета, иначе пакеты вроде
    # fss-capagent (сторонний бинарь heplify, без "fss-capagent" в argv)
    # всегда считались бы неактивными, хотя systemd видит unit активным.
    local is_active=0
    [[ -n "$(_sys_pkg_pids "$pkg" 2>/dev/null)" ]] && is_active=1

    if [[ "$log_status" == "stale" ]]; then
        if [[ $is_active -eq 0 ]]; then
            print_info "logdir: $log_dir has old logs but process is inactive"
            local owner
            owner=$(stat -c '%U:%G' "$log_dir" 2>/dev/null || stat -f '%Su:%Sg' "$log_dir" 2>/dev/null)
            print_info "logdir: $log_dir owner=$owner"
            return 0
        else
            print_warn "logdir: $log_dir is standard but logs are older than 5 hours, check actuality (process is active)"
        fi
    elif [[ "$log_status" == "empty" ]]; then
        if [[ $is_active -eq 0 ]]; then
            print_info "logdir: $log_dir is empty but process is inactive"
            return 0
        else
            print_warn "logdir: $log_dir is empty but process is active"
        fi
    elif [[ "$log_status" == "missing" ]]; then
        if [[ $is_active -eq 0 ]]; then
            print_info "logdir: $log_dir missing but process is inactive"
            return 0
        else
            print_warn "logdir: $log_dir missing but process is active"
        fi
    fi

    # Процесс активен и есть проблема — попытаться найти путь к логу из конфига
    # Нужно только для empty/missing; для stale путь по умолчанию существует, но устарел.
    # Для stale: запасной вариант только если известен конфиг для этого пакета (иначе пропуск).
    if [[ "$log_status" == "stale" ]]; then
        return 0
    fi

    found_log_dir=$(get_log_path_from_config "$pkg")
    if [[ -n "$found_log_dir" ]]; then
        found_log_dir=$(eval echo "$found_log_dir")
        if [[ -d "$found_log_dir" ]]; then
            if find -L "$found_log_dir" -maxdepth 1 -type f -mmin -300 2>/dev/null | head -1 | grep -q .; then
                print_ok "logdir: $found_log_dir exists (fresh logs from config)"
            elif [[ -n "$(find -L "$found_log_dir" -maxdepth 1 -type f 2>/dev/null | head -1)" ]]; then
                print_warn "logdir: $found_log_dir exists but logs are old (from config)"
            else
                print_warn "logdir: $found_log_dir exists but empty (from config)"
            fi
            local owner
            owner=$(stat -c '%U:%G' "$found_log_dir" 2>/dev/null || stat -f '%Su:%Sg' "$found_log_dir" 2>/dev/null)
            print_info "logdir: $found_log_dir owner=$owner"
        else
            print_warn "logdir: $found_log_dir from config does not exist"
        fi
    else
        print_warn "logdir: no log path found in config for $pkg"
    fi
}

# Проверить директорию opt и права доступа
check_opt_directory() {
    local pkg="$1"
    local opt_dir="/opt/flat/${pkg}"

    if [[ -d "$opt_dir" ]]; then
        print_ok "dir: $opt_dir exists"
        local owner
        owner=$(stat -c '%U:%G' "$opt_dir" 2>/dev/null || stat -f '%Su:%Sg' "$opt_dir" 2>/dev/null)
        print_info "dir: $opt_dir owner=$owner"
    else
        print_warn "dir: $opt_dir missing"
    fi
}

# Проверить конфигурационные файлы
check_configs() {
    local pkg="$1"
    local nginx_avail="/etc/nginx/sites-available/${pkg}"
    local nginx_en="/etc/nginx/sites-enabled/${pkg}"
    local logrotate="/etc/logrotate.d/${pkg}.conf"
    local sudoers="/etc/sudoers.d/${pkg}"

    if [[ -f "$nginx_avail" ]]; then
        print_ok "nginx: $nginx_avail exists"
        if [[ -L "$nginx_en" ]] || [[ -f "$nginx_en" ]]; then
            print_ok "nginx: $nginx_en enabled"
        else
            print_warn "nginx: $nginx_en not enabled"
        fi
    fi

    if [[ -f "$logrotate" ]]; then
        print_ok "logrotate: $logrotate exists"
    fi

    if [[ -f "$sudoers" ]]; then
        print_ok "sudoers: $sudoers exists"
    fi
}

# Проверить процесс по имени или паттерну
check_process() {
    local pkg="$1"
    local pids
    # _sys_pkg_pids() — не голый pgrep по имени пакета, иначе пакеты вроде
    # fss-capagent (запускают сторонний бинарь heplify, без "fss-capagent"
    # где-либо в argv) никогда не находились бы, хотя systemd видит unit
    # активным; у _sys_pkg_pids есть запасной путь через MainPID юнита.
    pids=$(_sys_pkg_pids "$pkg" 2>/dev/null | paste -sd',' - 2>/dev/null)

    if [[ -n "$pids" ]]; then
        print_ok "process: running (PIDs: $pids)"
        for p in $(echo "$pids" | tr ',' ' '); do
            local psline
            psline=$(ps -p "$p" -o pid,comm,args --no-headers 2>/dev/null || true)
            if [[ -n "$psline" ]]; then
                echo "        $psline"
            fi
        done
    fi
}

# Проверить сетевые порты
check_ports() {
    local pkg="$1"
    local ports_spec="${PKG_PORTS[$pkg]:-}"

    [[ -z "$ports_spec" ]] && return 0

    if ! command -v ss &>/dev/null && ! command -v netstat &>/dev/null; then
        print_warn "ports: ss/netstat not found"
        return 1
    fi

    local port
    for port in $(echo "$ports_spec" | tr ',' ' '); do
        local found=""
        if [[ "$port" == *"-"* ]]; then
            local start end
            start=$(echo "$port" | cut -d'-' -f1)
            end=$(echo "$port" | cut -d'-' -f2)
            if command -v ss &>/dev/null; then
                found=$(ss -tan 2>/dev/null | awk -v s="$start" -v e="$end" 'match($4, /:([0-9]+)$/, arr) { if (arr[1]+0 >= s+0 && arr[1]+0 <= e+0) print }' | head -1)
            fi
        else
            local pnum="$port"
            if [[ "$port" == *"/"* ]]; then
                pnum="${port%%/*}"
            fi
            if command -v ss &>/dev/null; then
                found=$(ss -tlnp 2>/dev/null | grep -E ":${pnum} " | head -1 || true)
            elif command -v netstat &>/dev/null; then
                found=$(netstat -tlnp 2>/dev/null | grep -E ":${pnum} " | head -1 || true)
            fi
        fi

        if [[ -n "$found" ]]; then
            print_ok "port: ${port} is open"
        else
            print_warn "port: ${port} not listening"
        fi
    done
}

# Проверить состояние API
check_api_health() {
    local pkg="$1"
    local endpoint="${PKG_API[$pkg]:-}"
    local ports_spec="${PKG_PORTS[$pkg]:-}"

    [[ -z "$endpoint" ]] || [[ -z "$ports_spec" ]] && return 0

    if ! command -v curl &>/dev/null; then
        print_warn "api: curl not found"
        return 1
    fi

    local first_port
    first_port=$(echo "$ports_spec" | tr ',' '\n' | grep -E '^[0-9]+$' | head -1)
    [[ -z "$first_port" ]] && return 0

    local url="http://localhost:${first_port}${endpoint}"
    local code
    code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "$url" 2>/dev/null || true)
    if [[ "$code" == "200" ]] || [[ "$code" == "204" ]]; then
        print_ok "api: $url => $code"
    elif [[ -n "$code" ]]; then
        print_warn "api: $url => $code"
    else
        print_warn "api: $url unreachable"
    fi
}

# --- 4. Проверки состояния по пакетам -------------------------------------------
# Зарегистрировать PKG_DEPS + зависимости PM в ALL_DEPENDS (первый проход перед параллельными проверками)
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

# Проверка одного пакета (учитывает VERBOSE)
check_single_pkg() {
    local pkg="$1"
    local legacy="${PKG_LEGACY[$pkg]:-}"

    # Быстрая тихая проверка для не установленных пакетов
    if ! is_pkg_installed_tiny "$pkg" "$legacy"; then
        if [[ $VERBOSE -eq 1 ]]; then
            echo "=$pkg="
            print_not_installed "$pkg"
            ((NOT_INSTALLED++))
            check_systemd_unit "$pkg"
            check_opt_directory "$pkg"
            check_log_directory "$pkg"
            check_configs "$pkg"
            check_process "$pkg"
            check_ports "$pkg"
            check_api_health "$pkg"
        fi
        return 1
    fi

    echo "=$pkg="

    # Пакет установлен (или есть следы) — печатаем полные детали
    check_pkg_installed "$pkg" "$legacy"
    local rc=$?

    if [[ $rc -eq 3 && -z "$FOUND_PKG_VER" ]]; then
        if has_any_trace "$pkg"; then
            print_warn "pkg: $pkg not found in PM, but traces exist on disk"
        fi
        return 1
    fi

    # Печатаем версию отдельно
    if [[ -n "$FOUND_PKG_VER" ]]; then
        print_info "version: ${FOUND_PKG_VER}"
    fi

    # Печатаем и собираем зависимости (регистрация обычно уже сделана на первом проходе)
    local deps_meta="${PKG_DEPS[$pkg]:-}"
    local deps_real=""
    if [[ -n "$deps_meta" ]]; then
        print_info "depends: ${deps_meta}"
        for dep in $(echo "$deps_meta" | tr ',' ' '); do
            register_dep "$dep" "$pkg"
        done
    fi

    # Пытаемся получить реальные зависимости из пакетного менеджера
    deps_real=$(get_pkg_depends "$pkg" 2>/dev/null)
    if [[ -n "$deps_real" ]]; then
        # Показываем реальные depends только если отличаются от meta
        if [[ "$deps_real" != "$deps_meta" ]]; then
            print_info "depends (PM): ${deps_real}"
        fi
        for dep in $(echo "$deps_real" | tr ',' ' '); do
            register_dep "$dep" "$pkg"
        done
    fi

    ((INSTALLED++))
    if _is_infrastructure_pkg "$pkg"; then
        check_infrastructure_pkg "$pkg"
        return 0
    fi
    check_systemd_unit "$pkg"
    check_opt_directory "$pkg"
    check_log_directory "$pkg"
    check_configs "$pkg"
    check_process "$pkg"
    check_ports "$pkg"
    check_api_health "$pkg"
    return 0
}

# Запуск проверок для одного продукта (параллельные пакеты, буферизованный упорядоченный вывод)
run_product_checks() {
    local product="$1"
    local installed_count=0
    local total_count=0
    local product_pkgs=()
    local pkg legacy max_jobs tmpdir job_idx=0 dw de di dn

    for pkg in "${!PKG_PRODUCT[@]}"; do
        if [[ "${PKG_PRODUCT[$pkg]:-}" == "$product" ]]; then
            product_pkgs+=("$pkg")
            ((total_count++))
            legacy="${PKG_LEGACY[$pkg]:-}"
            if is_pkg_installed_tiny "$pkg" "$legacy"; then
                ((installed_count++))
                _register_pkg_deps "$pkg"
            fi
        fi
    done

    [[ $total_count -eq 0 ]] && return

    if [[ $installed_count -eq 0 ]]; then
        if [[ $VERBOSE -eq 1 ]]; then
            echo ""
            echo "=== $product ==="
            for pkg in "${product_pkgs[@]}"; do
                check_single_pkg "$pkg"
            done
        fi
        return
    fi

    echo ""
    echo "=== $product ==="

    # Сортируем имена пакетов для устойчивого соответствия job_idx ↔ вывод
    IFS=$'\n' product_pkgs=($(printf '%s\n' "${product_pkgs[@]}" | sort)); unset IFS

    max_jobs=$(_collector_max_jobs)
    [[ "$max_jobs" -gt ${#product_pkgs[@]} ]] && max_jobs=${#product_pkgs[@]}
    tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/flat_pkg.XXXXXX" 2>/dev/null) || tmpdir="/tmp/flat_pkg.$$"
    mkdir -p "$tmpdir" 2>/dev/null || true
    _get_cpu_usage_percent >/dev/null

    for pkg in "${product_pkgs[@]}"; do
        if ! _collector_wait_slot "$max_jobs"; then
            break
        fi
        job_idx=$((job_idx + 1))
        (
            renice -n 5 $$ >/dev/null 2>&1 || true
            # Снимаем снэпшот счётчиков до проверки — НЕ "local" (это простой
            # subshell, а не тело функции); дельта записывается ниже в
            # файл, отдельный от человекочитаемого вывода самого check_single_pkg,
            # чтобы родительский процесс мог восстановить именно то, что было
            # увеличено здесь, без необходимости заново вычислять это через grep по
            # напечатанному тексту [WARN]/[FAIL] (хрупко: зависит от того, что текст сообщения никогда не изменится).
            _pj_w0=$WARNINGS; _pj_e0=$ERRORS; _pj_i0=$INSTALLED; _pj_n0=$NOT_INSTALLED
            check_single_pkg "$pkg"
            printf '%d %d %d %d\n' \
                "$((WARNINGS - _pj_w0))" "$((ERRORS - _pj_e0))" \
                "$((INSTALLED - _pj_i0))" "$((NOT_INSTALLED - _pj_n0))" \
                > "$tmpdir/$job_idx.stat" 2>/dev/null
        ) > "$tmpdir/$job_idx" 2>&1 &
        COLLECTOR_JOB_PIDS+=($!)
    done
    _collector_wait_all_jobs

    # Печатаем в порядке пакетов; восстанавливаем счётчики, потерянные в subshell'ах (Summary /
    # Zabbix), из собственного дельта-файла каждой задачи, а не разбором напечатанного текста.
    job_idx=0
    for pkg in "${product_pkgs[@]}"; do
        job_idx=$((job_idx + 1))
        [[ -f "$tmpdir/$job_idx" ]] || continue
        cat "$tmpdir/$job_idx"
        if [[ -f "$tmpdir/$job_idx.stat" ]]; then
            read -r dw de di dn < "$tmpdir/$job_idx.stat"
            [[ "$dw" =~ ^-?[0-9]+$ ]] && WARNINGS=$((WARNINGS + dw))
            [[ "$de" =~ ^-?[0-9]+$ ]] && ERRORS=$((ERRORS + de))
            [[ "$di" =~ ^-?[0-9]+$ ]] && INSTALLED=$((INSTALLED + di))
            [[ "$dn" =~ ^-?[0-9]+$ ]] && NOT_INSTALLED=$((NOT_INSTALLED + dn))
        fi
    done
    rm -rf -- "$tmpdir" 2>/dev/null
}

# Проверить, существует ли файл разделяемой библиотеки в стандартных lib-путях
is_lib_available() {
    local lib="$1"
    for path in /usr/lib64 /lib64 /usr/lib /lib; do
        [[ -f "$path/$lib" ]] && return 0
    done
    return 1
}


# ==========================================================================
# РАЗДЕЛ: 08_infra_checks
# ==========================================================================
# Назначение: Инфраструктурные пакеты (nginx/postgresql/mariadb — без require /opt/flat), список репозиториев по PM, финальный === Summary ===.
# Публичные функции: check_infrastructure(), check_repositories(), print_summary()
# Зависит от: 00_globals.sh, 02_output.sh, 04_os_detect.sh, 07_pkg_checks.sh
# Не зависит от: ничего в core/logging не зависит от этого модуля
# Side effects: печатает разделы === Infrastructure === / === Summary ===, читает списки репозиториев PM
#
# Источник: перенесено без изменений логики из flat_check.sh (строки 1881-2241).

# --- 5. Инфраструктура + репозитории --------------------------------------------
# Проверить все собранные зависимости (Infrastructure)
# Найти первую службу-кандидата systemd, чей unit-*файл* существует, и
# сообщить, активна ли она. Это ровно тот паттерн, который раньше был
# скопипащен для mariadb/postgresql/redis ниже: пробуем кандидатов в заданном
# порядке, останавливаемся на первом совпадении unit-файла (независимо от активности) —
# никогда не сообщаем о кандидате, чей unit вообще не был установлен.
# Возвращает 0, если найден подходящий unit-файл, иначе 1 (вызывающий код решает,
# что значит "нет ни одного подходящего unit" для этой зависимости).

_infra_report_first_unit() {
    local label="$1"; shift
    local svc active
    for svc in "$@"; do
        if systemctl list-unit-files --type=service 2>/dev/null | grep -q "^${svc}.service"; then
            active=$(systemctl is-active "${svc}.service" 2>/dev/null)
            if [[ "$active" == "active" ]]; then
                print_ok "$label: $svc active"
            else
                print_warn "$label: $svc $active"
            fi
            return 0
        fi
    done
    return 1
}

# Пакет из продукта Infrastructure (nginx/postgresql/…): не /opt/flat, а системный.
_is_infrastructure_pkg() {
    [[ "${PKG_PRODUCT[$1]:-}" == "Infrastructure" ]]
}

# Зависимость удовлетворена? (для дедупа авто-раздела Infrastructure)
_infra_dep_satisfied() {
    local dep="$1"
    if [[ "$dep" == *.so.* ]]; then
        is_lib_available "$dep" 2>/dev/null
        return $?
    fi
    case "$dep" in
        nginx)
            command -v nginx &>/dev/null && return 0
            is_dep_installed "$dep" 2>/dev/null && return 0
            return 1
            ;;
        mariadb|mysql|mysql-server|mariadb-server)
            command -v mysql &>/dev/null && return 0
            is_dep_installed "mariadb" 2>/dev/null && return 0
            is_dep_installed "mysql" 2>/dev/null && return 0
            is_dep_installed "mariadb-server" 2>/dev/null && return 0
            is_dep_installed "mysql-server" 2>/dev/null && return 0
            return 1
            ;;
        postgresql|postgresql-*)
            command -v psql &>/dev/null && return 0
            is_dep_installed "$dep" 2>/dev/null && return 0
            return 1
            ;;
        redis|redis-server)
            is_dep_installed "redis" 2>/dev/null || is_dep_installed "redis-server" 2>/dev/null
            return $?
            ;;
        *)
            is_dep_installed "$dep" 2>/dev/null
            return $?
            ;;
    esac
}

# Подробная проверка одного infra-пакета в секции продукта Infrastructure.
check_infrastructure_pkg() {
    local pkg="$1"
    local ver="" active=""

    if _infra_dep_satisfied "$pkg"; then
        ver=$(get_dep_version "$pkg" 2>/dev/null || true)
        case "$pkg" in
            nginx)
                if command -v nginx &>/dev/null; then
                    print_ok "nginx: $(nginx -v 2>&1 | head -1)"
                    if nginx -t &>/dev/null; then
                        print_ok "nginx: config valid"
                    else
                        print_fail "nginx: config invalid"
                    fi
                else
                    print_ok "nginx: installed${ver:+ ($ver)}"
                fi
                ;;
            postgresql|mariadb)
                print_ok "$pkg: ${ver:-installed}"
                ;;
            *)
                print_ok "$pkg: ${ver:-installed}"
                ;;
        esac
        if command -v systemctl &>/dev/null; then
            active=$(systemctl is-active "$pkg" 2>/dev/null || systemctl is-active "${pkg}.service" 2>/dev/null || echo "")
            if [[ "$active" == "active" ]]; then
                print_ok "$pkg: service active"
            elif [[ -n "$active" && "$active" != "unknown" ]]; then
                print_info "$pkg: service $active"
            fi
        fi
    else
        print_fail "$pkg: not installed"
    fi
    check_ports "$pkg"
    check_api_health "$pkg"
}

check_infrastructure() {
    echo ""
    echo "=== Depends ==="

    local has_any=0
    local dep_list=()

    # Сортируем уникальные зависимости
    for dep in "${!ALL_DEPENDS[@]}"; do
        dep_list+=("$dep")
        ((has_any++))
    done

    if [[ $has_any -eq 0 ]]; then
        print_info "No dependencies registered by installed packages"
        return
    fi

    IFS=$'\n' dep_list=($(sort <<<"${dep_list[*]}")); unset IFS

    for dep in "${dep_list[@]}"; do
        local req_by="${ALL_DEPENDS[$dep]:-}"
        local dep_ver=""
        local svc_status=""
        local dep_found=0

        # Разделяемые библиотеки: проверяем наличие файла в lib-путях (RHEL/ReOS 7.3 использует /usr/lib64/)
        if [[ "$dep" == *.so.* ]]; then
            if is_lib_available "$dep"; then
                print_ok "$dep: library found"
            else
                print_fail "$dep: library not found (required by: $req_by)"
            fi
            continue
        fi

        if is_dep_installed "$dep"; then
            dep_found=1
            dep_ver=$(get_dep_version "$dep")
            svc_status=$(check_dep_service "$dep")
        fi

        case "$dep" in
            nginx)
                if command -v nginx &>/dev/null; then
                    local ver
                    ver=$(nginx -v 2>&1 | head -1)
                    print_ok "nginx: $ver"
                    if command -v systemctl &>/dev/null; then
                        local active
                        active=$(systemctl is-active nginx.service 2>/dev/null || systemctl is-active nginx 2>/dev/null || echo "unknown")
                        if [[ "$active" == "active" ]]; then
                            print_ok "nginx: service active"
                        else
                            print_warn "nginx: service $active"
                        fi
                    fi
                    if nginx -t &>/dev/null; then
                        print_ok "nginx: config valid"
                    else
                        print_fail "nginx: config invalid"
                    fi
                elif [[ $dep_found -eq 0 ]]; then
                    print_fail "nginx: not installed (required by: $req_by)"
                else
                    print_warn "nginx: installed but binary not found"
                fi
                ;;
            mariadb|mysql|mysql-server|mariadb-server)
                if command -v mysql &>/dev/null; then
                    local ver
                    ver=$(mysql --version 2>/dev/null | head -1 | cut -d' ' -f1-4)
                    print_ok "mariadb/mysql: $ver"
                    if command -v systemctl &>/dev/null; then
                        _infra_report_first_unit mariadb mariadb mysql
                    fi
                    if command -v ss &>/dev/null && ss -tlnp 2>/dev/null | grep -q ':3306 '; then
                        print_ok "mariadb: port 3306 open"
                    fi
                elif [[ $dep_found -eq 0 ]]; then
                    print_fail "mariadb/mysql: not installed (required by: $req_by)"
                else
                    print_warn "mariadb/mysql: installed but client not found"
                fi
                ;;
            postgresql|postgresql-*)
                if command -v psql &>/dev/null; then
                    local ver
                    ver=$(psql --version 2>/dev/null | head -1)
                    print_ok "postgresql: $ver"
                    if command -v systemctl &>/dev/null; then
                        _infra_report_first_unit postgresql postgresql postgresql-12 postgresql-13 postgresql-14 postgresql-15 postgresql-16
                    fi
                    if command -v ss &>/dev/null && ss -tlnp 2>/dev/null | grep -q ':5432 '; then
                        print_ok "postgresql: port 5432 open"
                    fi
                elif is_dep_installed "mariadb" || is_dep_installed "mysql-server" || is_dep_installed "mariadb-server" || is_dep_installed "mysql"; then
                    print_info "postgresql: not installed, but mariadb/mysql is available (required by: $req_by)"
                elif [[ $dep_found -eq 0 ]]; then
                    print_fail "postgresql: not installed (required by: $req_by)"
                else
                    print_warn "postgresql: installed but client not found"
                fi
                ;;
            redis|redis-server)
                if [[ $dep_found -eq 1 ]]; then
                    print_ok "redis: $dep_ver installed"
                    if command -v systemctl &>/dev/null; then
                        _infra_report_first_unit redis redis-server redis
                    fi
                else
                    print_fail "redis: not installed (required by: $req_by)"
                fi
                ;;
            rabbitmq-server|rabbitmq)
                if [[ $dep_found -eq 1 ]]; then
                    print_ok "rabbitmq: $dep_ver installed"
                    if command -v systemctl &>/dev/null; then
                        local active
                        active=$(systemctl is-active rabbitmq-server.service 2>/dev/null || echo "unknown")
                        if [[ "$active" == "active" ]]; then
                            print_ok "rabbitmq: service active"
                        else
                            print_warn "rabbitmq: service $active"
                        fi
                    fi
                else
                    print_fail "rabbitmq: not installed (required by: $req_by)"
                fi
                ;;
            sudo)
                if [[ $dep_found -eq 1 ]]; then
                    print_ok "sudo: $dep_ver installed"
                else
                    print_fail "sudo: not installed (required by: $req_by)"
                fi
                ;;
            nodejs|nodejs-*)
                if command -v node &>/dev/null; then
                    local ver
                    ver=$(node --version 2>/dev/null | head -1)
                    print_ok "nodejs: $ver"
                elif is_dep_installed "nsolid" || command -v nsolid &>/dev/null; then
                    print_info "nodejs: not installed, but nsolid is available (required by: $req_by)"
                elif [[ $dep_found -eq 0 ]]; then
                    print_fail "nodejs: not installed (required by: $req_by)"
                else
                    print_warn "nodejs: installed but client not found"
                fi
                ;;
            *)
                if [[ $dep_found -eq 1 ]]; then
                    print_ok "$dep: $dep_ver installed"
                    if [[ -n "$svc_status" ]]; then
                        if [[ "$svc_status" == "service active" ]]; then
                            print_ok "$dep: $svc_status"
                        else
                            print_warn "$dep: $svc_status"
                        fi
                    fi
                else
                    print_fail "$dep: not installed (required by: $req_by)"
                fi
                ;;
        esac
    done
}

# Проверить репозитории

# --- Список репозиториев по PM ------------------------------------------------
# По одной самодостаточной функции на каждый пакетный менеджер — каждая читает только
# свои конфиг-файлы/инструменты репозиториев этого PM. check_repositories() ниже просто
# печатает заголовок секции и диспетчеризует по $PM.

# Debian-семья: записи sources.list(.d), затем приоритеты apt-cache policy.
check_repositories_dpkg() {
    local f line policy

    if [[ -f /etc/apt/sources.list ]]; then
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            [[ "$line" == \#* ]] && continue
            print_info "[apt] $line"
        done < /etc/apt/sources.list
    fi

    for f in /etc/apt/sources.list.d/*.list; do
        [[ -f "$f" ]] || continue
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            [[ "$line" == \#* ]] && continue
            print_info "[apt] $line"
        done < "$f"
    done

    if command -v apt-cache &>/dev/null; then
        policy=$(apt-cache policy 2>/dev/null | grep -E '^\s+[0-9]+' | head -20)
        if [[ -n "$policy" ]]; then
            echo ""
            print_info "APT priorities:"
            echo "$policy" | while IFS= read -r line; do
                print_info "  $line"
            done
        fi
    fi
}

# RHEL-семья: вывод `yum repolist`, затем сырые файлы *.repo внутри yum.repos.d.
check_repositories_rpm() {
    local f line repolist

    if command -v yum &>/dev/null; then
        repolist=$(yum repolist 2>/dev/null | tail -n +2 | grep -v "^repolist" | head -30)
        if [[ -n "$repolist" ]]; then
            echo "$repolist" | while IFS= read -r line; do
                print_info "[yum] $line"
            done
        fi
    fi

    for f in /etc/yum.repos.d/*.repo; do
        [[ -f "$f" ]] || continue
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            [[ "$line" == \#* ]] && continue
            print_info "[yum] $line"
        done < "$f"
    done
}

# Печатает настроенные репозитории пакетов для определённого PM (только dpkg/rpm —
# для pacman/apk список репозиториев никогда не был реализован, как и до этого разделения).
check_repositories() {
    echo ""
    echo "=== Repositories ==="

    case "$PM" in
        dpkg) check_repositories_dpkg ;;
        rpm)  check_repositories_rpm ;;
    esac
}

# Итоги
print_summary() {
    echo ""
    echo "=== Summary ==="
    print_info "Installed: $INSTALLED | Errors: $ERRORS | Warnings: $WARNINGS"
}



# ==========================================================================
# РАЗДЕЛ: 09_argv
# ==========================================================================
# Назначение: Разбор аргументов командной строки (usage()/parse_args()) и
#   финальный диспетчер режимов (dispatch_main()) — какой путь выполнить
#   после того, как флаги разобраны и точка входа подключила lib/agent
#   и/или lib/logging (если они понадобились по флагам).
# Публичные функции: usage(), parse_args("$@"), dispatch_main("$@")
# Зависит от: 00_globals.sh, 02_output.sh (die/info/_log_line), 04_os_detect.sh,
#   05_system_metrics.sh, 07_pkg_checks.sh, 08_infra_checks.sh — всегда;
#   отдельные ветки dispatch_main() дополнительно ожидают lib/agent (--json/--push,
#   --config) и/или lib/logging (-i/-log) уже подключёнными точкой входа.
# Не зависит от: ничего внутри lib/agent или lib/logging напрямую — только
#   вызывает их функции по имени, когда до этого дошло исполнение
# Side effects: печатает справку и выходит (usage()/-h/-v), пишет INFO о запуске
#   в сессионный лог, завершает процесс (exit) в конце большинства веток
#
# Источник: usage()+parse_args() перенесены без изменений логики из
#   flat_check_2.sh (строки 8584-9006, полный CLI — health + JSON agent +
#   мастер + сборщик логов, тот же набор флагов что и раньше, ничего не
#   переименовано). dispatch_main() — тело main() оттуда же (строки 9010-9071),
#   вынесенное в отдельную функцию: раньше parse_args() и диспетчеризация были
#   одной функцией main(); в модульной версии их разнесли, чтобы точка входа
#   могла подключить lib/agent/lib/logging МЕЖДУ разбором флагов и запуском —
#   логика внутри не менялась ни на строчку, только физическое разделение.


usage() {
    cat <<'EOF'
flat_check — FLAT/FCS health check + log collector

Usage: flat_check [MODE] [OPTIONS]

Modes:
  (no args)               Health check (installed services only)
  -i, --interactive       Interactive wizard (language, mode, log options)
  --dev                   Extended self-test (VERBOSE health all packages + seek/chunk)
  --selftest simple|extended
                          Self-test: simple = functions launch; extended = same as --dev
  --debug                 Mirror DEBUG-level session log lines to the screen (stderr)
  -log                    Log collector mode
    -on, --online         Real-time capture (tail -F + optional tcpdump)
    -off, --offline       Copy/extract existing logs
    -t, --timeout DUR     Alone: last N / online timeout (e.g. 5h, 30m).
                          After -f: range end (alias of -e/--to). Order -t … -f is an error.
    -f, --from TIME       Range start (e.g. -2h, 25.06.2026 10:00)
    -e, --to TIME         Range end (e.g. -1h, 25.06.2026 12:00)
    --until TIME          Same as -e/--to
                          Range: -t 2h | -f -2h -e -1h | -f '…' -t '…' | -f '…' -e '…'
    -n, --no-tcpdump      Skip network capture (online only)
    -j, --jobs N          Offline: parallel file copy workers (default: nproc*80%, max 32)
    --chunk-mode size|lines  Offline: how to split large output logs (default: size)
    --chunk-size SIZE     Offline: max size per part when --chunk-mode size (e.g. 50M, 200M; default: 100M)
    --chunk-lines N       Offline: max lines per part when --chunk-mode lines (default: 500000)
    --scope brief|extended  Brief = selected services only (default);
                          extended = + system/nginx/postgresql/configs (+ tcpdump online)
    -p, --product NAME    Product to collect (repeatable; see --list-targets)
    -s, --service PKG     Service/package to collect (repeatable)
    --list-targets        List products/services present on host and exit
    --mgcpclient          SoftSwitch/fss-server: include mgcpclient logs (no prompt)
    --no-mgcpclient       SoftSwitch/fss-server: skip mgcpclient logs (no prompt)
  -v, --version           Print script version and exit
  -r, --repo              Show repositories (APT/YUM sources)
  -o, --output DIR        Write archive to DIR (log mode only)
  -h, --help              Show this help and exit

Duration suffixes: s=sec, m=min, h=hour, d=day. Bare number = seconds

Offline log range (IMPORTANT):
  Unlike flat_check_old, time range filters log LINES by timestamp inside files,
  not only by file modification time. Supports formats:
    2026-06-25 14:01:49
    25.06.2026 14:01:49
    08.06.2026 14:17:29.791
  Large plain logs (>=1MB): binary-search start/end offsets, then parallel chunk-scan
  of that window (multi-worker; hang-safe host load gate). Files >=1GB use larger chunks.
  .gz and tiny files: linear awk. Unsorted large plain: parallel full-file chunk-scan.
  Same idea as timegrep/tgrep/archeolog (bisect), plus parallel window scan for throughput.

Log discovery:
  Only known package dirs (PKG_PRODUCT + PKG_LEGACY under /var/log/flat and /opt/flat).
  Unknown folders (e.g. logforflat) are skipped with [INFO] skip unknown.
  Default without -p/-s: all packages present on the host.
  If selection includes fss-server: prompts for mgcpclient (or --mgcpclient / --no-mgcpclient).
  Other SoftSwitch services (fss-frontend/backend/…) do not prompt.
  When skipped: excludes mgcpclient* files inside fss-server dirs as well.
  PostgreSQL / system / nginx / configs: only with --scope extended
  Offline workers respect host-wide ~80% CPU and ~80% memory (/proc/stat, /proc/meminfo):
  workers are not spawned when the whole system is already at or above the limit (Zabbix-friendly).

Log collection messages ([INFO]):
  If logs are missing, the script reports why — this is not an error:
    offline with -t/-f/-e  → [INFO] no logs for the specified time period
    online (-log -on)      → [INFO] no logs during collection
    offline without range  → [INFO] no logs
  PostgreSQL: also reports missing directory, no access (run as root/sudo)
  Absent-log hints show source label (nginx, system, postgresql) and up to 4 file names (+N more)

Log collection:
  Offline: parallel copy of log files (up to nproc workers, -j to override)
  Online: one tail -F process per source log file (same layout as offline archive)
  Empty files created during collection with no new lines are removed before archiving

Session log (<script-name>.log):
  Every run writes a full log of its own work: invocation args or wizard
  choices, which log dirs/files were found and which were discarded (and
  why), host CPU/MEM snapshots at start/stop and every 30s during collection.
  -log: the log file is written inside the collection work dir and packed
        into the same .tar.gz as the collected logs.
  otherwise: written next to the script (or -o/--output) and overwritten on
        each run (no rotation, safe for frequent cron/Zabbix invocations).
  Terminal [OK]/[WARN]/[FAIL]/[INFO] lines are mirrored there with a
  timestamp; fine-grained "found/discarded"/resource entries are DEBUG-level
  and file-only, so the screen output is unaffected.

Required dependencies:
  bash, coreutils (date, find, cp, tar, mkdir, wc, sort)
  awk (gawk) — offline log line filtering by timestamp
  tail — online log collection
  grep — fallback pattern search in logs
  gzip OR pigz — archive compression (pigz preferred if available)

Optional dependencies:
  tcpdump — network capture in online mode (needs root)
  zcat/gzip — reading .gz log files
  curl — API health checks in check mode
  ss or netstat — port checks
  dpkg or rpm — package manager detection
  systemctl — service status checks
  nginx -t — nginx config validation

JSON agent:
  --config FILE         agent config (/etc/flat/flat_check.conf)
  --pkg NAME            single package (health/JSON)
  --product NAME        product filter for health/JSON
                        (in -log mode -p still selects log products)
  --json                emit full health JSON v2 to stdout
  --push                POST JSON to all PUSH_URLS (http/https)
  --host-id|--host-ip|--service-name   host identity overrides

Examples:
  ./flat_check                    # Health check only
  ./flat_check -i                 # Interactive wizard
  ./flat_check --json
  ./flat_check --config /etc/flat/flat_check.conf --json --push
  ./flat_check --pkg fss-server --json
  ./flat_check -log --list-targets
  ./flat_check -log -off -t 2h --scope brief -p SoftSwitch --no-mgcpclient
  ./flat_check -log -off -f -1d --scope extended -s fcs-swui
  ./flat_check -log -on -t 30m --scope brief -p "Contact Center" -s acs-server
  ./flat_check -v                 # Print version
  ./flat_check --selftest simple  # Quick self-test
  ./flat_check --dev              # Extended self-test

Installer / conf: see agent/README.md

---

flat_check — проверка FLAT/FCS + сборщик логов

Использование: flat_check [РЕЖИМ] [ОПЦИИ]

Режимы:
  (без аргументов)        Проверка установленных служб
  -i, --interactive       Интерактивный мастер (язык, режим, параметры логов)
  --dev                   Расширенный самотест (VERBOSE health по всем пакетам + seek/chunk)
  --selftest simple|extended
                          Самотест: simple = запуск функций; extended = как --dev
  --debug                 Дублировать DEBUG-строки сессионного лога на экран (stderr)
  -log                    Режим сборщика логов
    -on, --online         Сбор в реальном времени (tail -F + опц. tcpdump)
    -off, --offline       Копирование/извлечение готовых логов
    -t, --timeout ДЛИТ    Одно: last N / online timeout (например 5h, 30m).
                          После -f: конец диапазона (как -e/--to). Порядок -t … -f — ошибка.
    -f, --from TIME       Начало диапазона (например -2h, 25.06.2026 10:00)
    -e, --to TIME         Конец диапазона (например -1h, 25.06.2026 12:00)
    --until TIME          То же, что -e/--to
                          Диапазон: -t 2h | -f -2h -e -1h | -f '…' -t '…' | -f '…' -e '…'
    -n, --no-tcpdump      Не записывать сетевой трафик (только online)
    -j, --jobs N          Offline: число параллельных копий файлов (по умолч. nproc*80%, макс. 32)
    --chunk-mode size|lines  Offline: как резать крупные логи (по умолч. size)
    --chunk-size РАЗМЕР   Offline: макс. размер одной части при --chunk-mode size (например 50M, 200M; по умолч. 100M)
    --chunk-lines N       Offline: макс. строк в одной части при --chunk-mode lines (по умолч. 500000)
    --scope brief|extended  Краткий = только выбранные службы (по умолч.);
                          расширенный = + system/nginx/postgresql/configs (+ tcpdump online)
    -p, --product NAME    Продукт (повторяемый; см. --list-targets)
    -s, --service PKG     Служба/пакет (повторяемый)
    --list-targets        Показать продукты/службы на хосте и выйти
    --mgcpclient          SoftSwitch/fss-server: включить логи mgcpclient (без вопроса)
    --no-mgcpclient       SoftSwitch/fss-server: не собирать mgcpclient (без вопроса)
  -v, --version           Показать версию скрипта и выйти
  -r, --repo              Показать репозитории (APT/YUM sources)
  -o, --output ДИР        Записать архив в директорию (только -log)
  -h, --help              Показать справку и выйти

Offline диапазон (ВАЖНО):
  В отличие от flat_check_old, диапазон фильтрует СТРОКИ логов по метке времени
  внутри файла, а не только по дате изменения файла. Форматы:
    2026-06-25 14:01:49
    25.06.2026 14:01:49
    08.06.2026 14:17:29.791
  Крупные plain-логи (>=1MB): binary-search границ from/to, затем параллельный
  chunk-scan окна (несколько воркеров; hang-safe лимит нагрузки хоста). При >=1GB —
  крупные чанки. .gz и мелкие файлы: линейный awk. Неупорядоченные крупные: parallel
  full-file scan. Как timegrep/tgrep/archeolog (бисекция) + параллельный проход окна.

Поиск логов:
  Только известные каталоги пакетов (PKG_PRODUCT + PKG_LEGACY в /var/log/flat и /opt/flat).
  Неизвестные папки (например logforflat) пропускаются: [INFO] skip unknown.
  Без -p/-s: все пакеты, присутствующие на хосте.
  Если в выборе есть fss-server: спрашивает про mgcpclient (или --mgcpclient / --no-mgcpclient).
  Остальные службы SoftSwitch (fss-frontend/backend/…) — без вопроса.
  При отказе: исключает и файлы mgcpclient* внутри каталогов fss-server.
  PostgreSQL / system / nginx / configs: только с --scope extended
  Offline-воркеры учитывают нагрузку всей системы ~до 80% CPU и 80% RAM (/proc/stat, /proc/meminfo):
  при CPU или RAM системы ≥80% новые воркеры не стартуют (удобно для Zabbix).

Сообщения при сборе логов ([INFO]):
  Если логов нет — скрипт сообщает об этом, это не ошибка:
    offline с -t/-f/-e  → [INFO] за указанное время логи отсутствуют
    online (-log -on)   → [INFO] за время сбора логи отсутствуют
    offline без диапазона → [INFO] логи отсутствуют
  PostgreSQL: также сообщает об отсутствии каталога, нет доступа (нужен root/sudo)
  Подсказки по отсутствующим логам: метка источника (nginx, system, postgresql) и до 4 имён файлов (+N ещё)

Сбор логов:
  Offline: параллельное копирование файлов (до nproc*80% воркеров, -j для переопределения)
  Online: отдельный tail -F на каждый исходный лог-файл (структура архива как в offline)
  Пустые файлы без новых строк удаляются перед упаковкой архива

Обязательные зависимости:
  bash, coreutils (date, find, cp, tar, mkdir, wc, sort)
  awk (gawk) — фильтрация строк логов offline по метке времени
  tail — online сбор логов
  grep — резервный поиск по шаблонам в логах
  gzip ИЛИ pigz — сжатие архива (предпочтительно pigz)

Опциональные зависимости:
  tcpdump — захват сети в online режиме (нужен root)
  zcat/gzip — чтение .gz логов
  curl — проверка API health в режиме проверки
  ss или netstat — проверка портов
  dpkg или rpm — определение пакетного менеджера
  systemctl — статус служб
  nginx -t — проверка конфигурации nginx

JSON-агент:
  --config FILE         конфиг агента (/etc/flat/flat_check.conf)
  --pkg NAME            один пакет (health/JSON)
  --product NAME        фильтр продукта (health/JSON); в -log — выбор лога
  --json                полный health JSON v2 в stdout
  --push                POST JSON на все PUSH_URLS (http/https)
  --host-id|--host-ip|--service-name   идентификация хоста

Примеры:
  ./flat_check                    # Только проверка
  ./flat_check -i                 # Интерактивный мастер
  ./flat_check --json
  ./flat_check --config /etc/flat/flat_check.conf --json --push
  ./flat_check --pkg fss-server --json
  ./flat_check -log --list-targets
  ./flat_check -log -off -t 2h --scope brief -p SoftSwitch --no-mgcpclient
  ./flat_check -log -off -f -1d --scope extended -s fcs-swui
  ./flat_check -log -on -t 30m --scope brief -p "Contact Center"
  ./flat_check -v                 # Версия
  ./flat_check --selftest simple  # Быстрый самотест
  ./flat_check --dev              # Расширенный самотест

Установка: см. agent/README.md
EOF
    exit 0
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -i|--interactive)
                MODE_INTERACTIVE=1
                shift
                ;;
            -v|--version)
                echo "flat_check ${SCRIPT_VERSION}"
                exit 0
                ;;
            --dev)
                SELFTEST_MODE="extended"
                MODE_DEV=1
                shift
                ;;
            --debug)
                DEBUG_MODE=1
                shift
                ;;
            --selftest)
                if [[ -z "${2:-}" || "$2" == -* ]]; then die "Missing value for --selftest (simple|extended)"; fi
                case "$2" in
                    simple|extended) SELFTEST_MODE="$2" ;;
                    *) die "Invalid --selftest: '$2' (use simple|extended)" ;;
                esac
                [[ "$SELFTEST_MODE" == "extended" ]] && MODE_DEV=1
                shift 2
                ;;
            -log)
                MODE_LOG=1
                shift
                ;;
            -on|--online)
                LOG_SUBMODE="online"
                shift
                ;;
            -off|--offline)
                LOG_SUBMODE="offline"
                shift
                ;;
            -t|--timeout)
                if [[ -z "${2:-}" || "$2" == -* ]]; then die "Missing value for $1"; fi
                # Контекст: если -f уже был — это конец диапазона (alias --to).
                # Иначе — last-N / online timeout.
                if [[ "${CLI_FROM_SET:-0}" -eq 1 ]]; then
                    if [[ "${CLI_TO_SET:-0}" -eq 1 ]]; then
                        die "Conflicting end time: both -e/--to and -t used as range end"
                    fi
                    TO_TIME="$2"
                    CLI_TO_SET=1
                    CLI_T_AS_TO=1
                else
                    TIMEOUT_RAW="$2"
                    CLI_TIMEOUT_SET=1
                fi
                shift 2
                ;;
            --until)
                if [[ -z "${2:-}" ]]; then die "Missing value for $1"; fi
                if [[ "${CLI_TO_SET:-0}" -eq 1 ]]; then
                    die "Conflicting end time: --until with existing -e/-t end"
                fi
                TO_TIME="$2"
                CLI_TO_SET=1
                shift 2
                ;;
            -f|--from)
                if [[ -z "${2:-}" ]]; then die "Missing value for $1"; fi
                if [[ "${CLI_TIMEOUT_SET:-0}" -eq 1 && "${CLI_T_AS_TO:-0}" -eq 0 ]]; then
                    CLI_TIMEOUT_BEFORE_FROM=1
                fi
                FROM_TIME="$2"
                CLI_FROM_SET=1
                shift 2
                ;;
            -e|--to)
                if [[ -z "${2:-}" ]]; then die "Missing value for $1"; fi
                if [[ "${CLI_TO_SET:-0}" -eq 1 ]]; then
                    die "Conflicting end time: -e/--to with existing -t/--until end"
                fi
                TO_TIME="$2"
                CLI_TO_SET=1
                shift 2
                ;;
            -n|--no-tcpdump)
                START_TCPDUMP=0; shift
                ;;
            -j|--jobs)
                if [[ -z "${2:-}" || "$2" == -* ]]; then die "Missing value for $1"; fi
                if ! [[ "$2" =~ ^[1-9][0-9]*$ ]]; then die "Invalid -j/--jobs value: '$2' (positive integer)"; fi
                COLLECTOR_JOBS="$2"; shift 2
                ;;
            --chunk-mode)
                if [[ -z "${2:-}" || "$2" == -* ]]; then die "Missing value for $1"; fi
                case "$2" in
                    size|lines) LOG_CHUNK_MODE="$2" ;;
                    *) die "Invalid --chunk-mode: '$2' (use size|lines)" ;;
                esac
                shift 2
                ;;
            --chunk-size)
                if [[ -z "${2:-}" || "$2" == -* ]]; then die "Missing value for $1"; fi
                if ! LOG_CHUNK_SIZE_BYTES=$(_parse_size_to_bytes "$2") || [[ "$LOG_CHUNK_SIZE_BYTES" -le 0 ]]; then
                    die "Invalid --chunk-size: '$2' (e.g. 50M, 200000000)"
                fi
                LOG_CHUNK_MODE="size"; shift 2
                ;;
            --chunk-lines)
                if [[ -z "${2:-}" || "$2" == -* ]]; then die "Missing value for $1"; fi
                if ! [[ "$2" =~ ^[1-9][0-9]*$ ]]; then die "Invalid --chunk-lines: '$2' (positive integer)"; fi
                LOG_CHUNK_LINES="$2"; LOG_CHUNK_MODE="lines"; shift 2
                ;;
            --scope)
                if [[ -z "${2:-}" || "$2" == -* ]]; then die "Missing value for $1"; fi
                case "$2" in
                    brief|extended) LOG_SCOPE="$2" ;;
                    *) die "Invalid --scope: '$2' (use brief|extended)" ;;
                esac
                shift 2
                ;;
            -p|--product)
                # -log: список продуктов для сбора; иначе — фильтр health/JSON
                if [[ -z "${2:-}" || "$2" == -* ]]; then die "Missing value for $1"; fi
                if [[ $MODE_LOG -eq 1 ]]; then
                    SELECTED_PRODUCTS+=("$2")
                else
                    FILTER_PRODUCT="$2"
                fi
                shift 2
                ;;
            -s|--service)
                if [[ -z "${2:-}" || "$2" == -* ]]; then die "Missing value for $1"; fi
                SELECTED_SERVICES+=("$2"); shift 2
                ;;
            --list-targets)
                LIST_TARGETS=1; shift
                ;;
            --mgcpclient)
                INCLUDE_MGCPCLIENT=1; shift
                ;;
            --no-mgcpclient)
                INCLUDE_MGCPCLIENT=0; shift
                ;;
            -r|--repo)
                SHOW_REPO=1; SHOW_REPOS_JSON=1; shift
                ;;
            -o|--output)
                if [[ -z "${2:-}" || "$2" == -* ]]; then die "Missing value for $1"; fi
                OUTPUT_DIR="$2"; shift 2
                ;;
            --config)
                [[ -z "${2:-}" || "$2" == -* ]] && die "Missing value for $1"
                CONFIG_FILE="$2"; shift 2 ;;
            --pkg)
                [[ -z "${2:-}" || "$2" == -* ]] && die "Missing value for $1"
                SINGLE_PKG="$2"; shift 2 ;;
            --json) OUTPUT_JSON=1; shift ;;
            --push) DO_PUSH=1; shift ;;
            --host-id)
                [[ -z "${2:-}" || "$2" == -* ]] && die "Missing value for $1"
                HOST_ID="$2"; shift 2 ;;
            --host-ip)
                [[ -z "${2:-}" || "$2" == -* ]] && die "Missing value for $1"
                HOST_IP="$2"; shift 2 ;;
            --service-name)
                [[ -z "${2:-}" || "$2" == -* ]] && die "Missing value for $1"
                SERVICE_NAME="$2"; shift 2 ;;
            -h|--help)
                usage
                ;;
            *)
                die "Unknown option: $1 (try -h)"
                ;;
        esac
    done
}

# dispatch_main(): тело main() из flat_check_2.sh (строки 9010-9071) без
# изменений логики, только без повторного вызова parse_args() (это уже
# сделала точка входа flat_check ДО подключения lib/agent/lib/logging).
dispatch_main() {
    init_logging "${OUTPUT_DIR:-$SCRIPT_DIR}"
    _log_line "INFO" "Запуск: $0 $* (аргументов: $#)"

    # -i: интерактивный мастер
    if [[ $MODE_INTERACTIVE -eq 1 ]]; then
        run_interactive_wizard
    fi

    if [[ $LIST_TARGETS -eq 1 ]]; then
        detect_os
        list_log_targets
        exit 0
    fi

    # Самотест: --dev / --selftest / режим 3 мастера
    if [[ -n "${SELFTEST_MODE:-}" ]]; then
        run_selftest "$SELFTEST_MODE"
        exit $?
    fi
    if [[ $MODE_DEV -eq 1 ]]; then
        run_selftest extended
        exit $?
    fi

    [[ -n "$CONFIG_FILE" ]] && _json_load_config "$CONFIG_FILE"

    # JSON / push (1к1 с flat_check.sh) — до -log
    if [[ "$OUTPUT_JSON" -eq 1 || "$DO_PUSH" -eq 1 ]]; then
        run_health_json
        exit $?
    fi

    # -log: только сбор логов
    if [[ $MODE_LOG -eq 1 ]]; then
        _validate_time_cli_combo
        run_log_collection "$LOG_SUBMODE" "$TIMEOUT_RAW"
        [[ $SHOW_REPO -eq 1 ]] && { detect_os; check_repositories; }
        exit 0
    fi

    # Один пакет — текстовый health
    if [[ -n "$SINGLE_PKG" ]]; then
        detect_os
        [[ -n "${PKG_PRODUCT[$SINGLE_PKG]:-}" ]] || die "Unknown package: $SINGLE_PKG"
        check_single_pkg "$SINGLE_PKG"
        exit $?
    fi

    # ПО УМОЛЧАНИЮ: только проверка состояния (исходное поведение flat_check)
    detect_os
    check_system
    local products=("${FLAT_PRODUCTS_ORDER[@]}")
    local p
    if [[ -n "$FILTER_PRODUCT" ]]; then
        products=("$FILTER_PRODUCT")
    fi
    for p in "${products[@]}"; do run_product_checks "$p"; done
    check_infrastructure
    [[ $SHOW_REPO -eq 1 ]] && check_repositories
    print_summary
}

# ==========================================================================
# РАЗДЕЛ: 10_wizard
# ==========================================================================
# Назначение: Интерактивный мастер (-i/--interactive) — язык, выбор режима
#   (health/сбор логов/самотест), для сбора логов: online/offline, scope,
#   диапазон времени, chunk-настройки, выбор продуктов/служб/типов логов.
# Публичные функции: run_interactive_wizard()
# Зависит от: lib/core (00_globals, 02_output, 03_i18n — _l(), 01_catalog —
#   PKG_PRODUCT/PKG_LEGACY); ветка сбора логов (_wizard_configure_log_mode →
#   _wizard_select_log_targets) дополнительно ожидает lib/logging уже
#   подключённым (список целей/типов логов строится через lib/logging.sh (раздел 02_log_discovery)).
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

# ==========================================================================
# РАЗДЕЛ: 11_selftest
# ==========================================================================
# Назначение: --selftest simple|extended — самопроверка ключевых функций/каталога
#   без реального воздействия на систему (кроме чтения состояния). simple — быстрый
#   smoke-test хелперов core+agent; extended — то же плюс проверки lib/logging
#   (парсеры времени, resource-gate, seek+chunk extract) и VERBOSE health-прогон
#   по всем продуктам (то же самое, что --dev).
# Публичные функции: run_selftest(level), _run_selftest_simple(), _run_selftest_extended()
# Зависит от: 00_globals.sh, 02_output.sh, 04_os_detect.sh, 05_system_metrics.sh,
#   06_resource_gate.sh, 07_pkg_checks.sh, 08_infra_checks.sh; ожидает уже
#   подключённые lib/agent/*.sh (build_health_json, push_health_json,
#   _json_collect_infra — проверяются даже на уровне simple) и, для extended,
#   lib/logging/*.sh (parse_time_point/parse_duration/time_to_epoch,
#   _selftest_seek_extract) — точка входа обязана подключать оба слоя перед
#   ЛЮБЫМ run_selftest (см. flat_check и ARCHITECTURE.md).
# Не зависит от: ничего внутри lib/agent или lib/logging не зависит от этого модуля
# Side effects: печатает результаты [OK]/[FAIL], временно выставляет VERBOSE=1
#   и тестовые ALL_DEPENDS/HOST_ID при extended
#
# Источник: simple/run_selftest — перенесено без изменений логики из
#   flat_check.sh (строки 3084-3200). extended дополнительно вобрал в себя
#   logging-проверки из flat_check_2.sh (строки 6120-6176: time formats,
#   parse_duration, _collector_wait_slot, _selftest_seek_extract) — при
#   портировании core в фазе 1 они были пропущены, т.к. flat_check.sh
#   (health-only, без сборщика логов) их не содержит; добавлены в фазе 3,
#   когда появился lib/logging, без изменения логики самих проверок.


_SELFTEST_PASS=0
_SELFTEST_FAIL=0

_selftest_ok() {
    print_ok "selftest: $1"
    _SELFTEST_PASS=$((_SELFTEST_PASS + 1))
}

_selftest_bad() {
    print_fail "selftest: $1"
    _SELFTEST_FAIL=$((_SELFTEST_FAIL + 1))
}

_run_selftest_simple() {
    info "Self-test SIMPLE (smoke: health helpers)"
    detect_os
    if [[ -n "${OS_ID:-}" && -n "${PM:-}" ]]; then
        _selftest_ok "detect_os (${OS_ID}/${PM})"
    else
        _selftest_bad "detect_os"
    fi
    local n
    n=$(_collector_max_jobs)
    [[ "$n" =~ ^[1-9][0-9]*$ ]] && _selftest_ok "_collector_max_jobs=$n" || _selftest_bad "_collector_max_jobs"
    _get_mem_usage_percent >/dev/null && _selftest_ok "_get_mem_usage_percent" || _selftest_bad "_get_mem_usage_percent"
    _get_cpu_usage_percent >/dev/null && _selftest_ok "_get_cpu_usage_percent" || _selftest_bad "_get_cpu_usage_percent"
    declare -F check_system >/dev/null && _selftest_ok "check_system defined" || _selftest_bad "check_system defined"
    declare -F run_product_checks >/dev/null && _selftest_ok "run_product_checks defined" || _selftest_bad "run_product_checks defined"
    declare -F check_infrastructure >/dev/null && _selftest_ok "check_infrastructure defined" || _selftest_bad "check_infrastructure defined"
    declare -F build_health_json >/dev/null && _selftest_ok "build_health_json defined" || _selftest_bad "build_health_json defined"
    declare -F push_health_json >/dev/null && _selftest_ok "push_health_json defined" || _selftest_bad "push_health_json defined"
    local j
    HOST_ID="selftest-host" HOST_IP="127.0.0.1" SERVICE_NAME="flat_check" VERBOSE=0
    j=$(SINGLE_PKG="" build_health_json 2>/dev/null | head -c 200 || true)
    if [[ "$j" == {* ]]; then
        _selftest_ok "build_health_json emits JSON"
    else
        _selftest_bad "build_health_json emits JSON"
    fi
    local pkg_count=0
    pkg_count=${#PKG_PRODUCT[@]}
    [[ "$pkg_count" -ge 100 ]] && _selftest_ok "PKG_PRODUCT entries=$pkg_count" || _selftest_bad "PKG_PRODUCT entries=$pkg_count (want ≥100)"

    if [[ "${PKG_PRODUCT[nginx]:-}" == "Infrastructure" && "${PKG_PRODUCT[fvcs-backend]:-}" == "FVSC" ]]; then
        _selftest_ok "catalog has Infrastructure+FVSC"
    else
        _selftest_bad "catalog has Infrastructure+FVSC"
    fi

    # JSON: hyphen in ALL_DEPENDS key + unmet-only infra + INSTALLED вне subshell
    # -g обязателен: этот код выполняется напрямую (не в субшелле $()), поэтому
    # без -g "declare -A" создал бы ЛОКАЛЬНУЮ тень для _run_selftest_simple, а
    # глобальный ALL_DEPENDS остался бы unset и после возврата ломал бы
    # register_dep() в последующем VERBOSE-проходе по пакетам (см. build_health_json выше).
    declare -gA ALL_DEPENDS=()
    ALL_DEPENDS["fps-server"]="fss-frontend"
    ALL_DEPENDS["nginx"]="fss-server"
    local infra_json
    infra_json=$(_json_collect_infra 2>/dev/null || echo FAIL)
    if [[ "$infra_json" == '['*']' && "$infra_json" != *FAIL* ]]; then
        _selftest_ok "_json_collect_infra tolerates hyphen keys"
    else
        _selftest_bad "_json_collect_infra tolerates hyphen keys (got: $infra_json)"
    fi
    if declare -F check_infrastructure >/dev/null; then
        local dep_hdr
        dep_hdr=$(check_infrastructure 2>/dev/null | head -n 2 | tr '\n' ' ')
        if [[ "$dep_hdr" == *"=== Depends ==="* ]]; then
            _selftest_ok "check_infrastructure section is Depends"
        else
            _selftest_bad "check_infrastructure section is Depends (got: $dep_hdr)"
        fi
    fi

    if [[ "${PKG_CATALOG_SOURCE:-}" == "external" || "${PKG_CATALOG_SOURCE:-}" == "internal" ]]; then
        _selftest_ok "PKG_CATALOG_SOURCE=${PKG_CATALOG_SOURCE}"
    else
        _selftest_bad "PKG_CATALOG_SOURCE set"
    fi
}

_run_selftest_extended() {
    info "Self-test EXTENDED (VERBOSE health + log collector)"
    _run_selftest_simple

    # Проверки сборщика логов (lib/logging) — портировано из flat_check_2.sh
    # _run_selftest_extended(). Точка входа обязана подключить lib/logging до
    # вызова run_selftest extended (см. flat_check и ARCHITECTURE.md); если
    # тест запущен без lib/logging, ниже будут честные [FAIL] "command not
    # found", а не тихий пропуск — это тоже полезный сигнал о поломанной сборке.
    local t1 t2 ep1 ep2 d
    t1=$(parse_time_point "25.06.2026 10:00") || t1=""
    t2=$(parse_time_point "2026-06-25 10:00:00") || t2=""
    ep1=$(time_to_epoch "$t1")
    ep2=$(time_to_epoch "$t2")
    if [[ -n "$t1" && -n "$t2" && "$ep1" =~ ^[0-9]+$ && "$ep2" =~ ^[0-9]+$ && "$ep1" -eq "$ep2" ]]; then
        _selftest_ok "time formats DD.MM.YYYY ≡ YYYY-MM-DD"
    else
        _selftest_bad "time formats DD.MM.YYYY ≡ YYYY-MM-DD (got '$t1'/'$t2')"
    fi
    if parse_time_point "-1h" >/dev/null; then
        _selftest_ok "parse_time_point -1h"
    else
        _selftest_bad "parse_time_point -1h"
    fi
    for d in 30s 5m 2h 1d; do
        if parse_duration "$d"; then
            _selftest_ok "parse_duration $d"
        else
            _selftest_bad "parse_duration $d"
        fi
    done

    # Лимит ресурсов должен разрешать ≥1 воркер (защита от зависания)
    COLLECTOR_JOB_PIDS=()
    if _collector_wait_slot 2; then
        _selftest_ok "_collector_wait_slot (hang-safe)"
    else
        _selftest_bad "_collector_wait_slot"
    fi

    # Полный путь seek + параллельные чанки
    if _selftest_seek_extract; then
        _selftest_ok "seek+chunk extract (bisect)"
    else
        _selftest_bad "seek+chunk extract (bisect)"
    fi

    VERBOSE=1
    detect_os
    check_system
    local products p
    products=("${FLAT_PRODUCTS_ORDER[@]}")
    for p in "${products[@]}"; do
        run_product_checks "$p"
    done
    check_infrastructure
    [[ $SHOW_REPO -eq 1 ]] && check_repositories
    print_summary
    _selftest_ok "health VERBOSE all products"
}

run_selftest() {
    local level="${1:-simple}"
    _SELFTEST_PASS=0
    _SELFTEST_FAIL=0
    echo ""
    info "flat_check self-test ($level) v${SCRIPT_VERSION}"
    case "$level" in
        simple) _run_selftest_simple ;;
        extended|dev) _run_selftest_extended ;;
        *) die "Unknown self-test level: $level (use simple|extended)" ;;
    esac
    echo ""
    if [[ "$_SELFTEST_FAIL" -eq 0 ]]; then
        print_ok "Self-test $level: ${_SELFTEST_PASS} passed, 0 failed"
        return 0
    fi
    print_fail "Self-test $level: ${_SELFTEST_PASS} passed, ${_SELFTEST_FAIL} failed"
    return 1
}
