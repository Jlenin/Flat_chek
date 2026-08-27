# Модуль: 01_catalog.sh
# Слой: core
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

