#!/bin/bash
# flat_check.sh — проверка состояния FLAT/FCS (health check)
#
# Работает на: Debian/Ubuntu, RHEL/CentOS/ALMA/Rocky/РЕД ОС, Astra, … (dpkg/rpm + systemd)
#
# Режимы:
#   (по умолчанию) проверка установленных служб и ресурсов хоста
#   -i / --info     подробный вывод по всем пакетам (включая не установленные)
#   -r / --repo     показать репозитории
#   -v / --version  версия скрипта
#   --json / --push агент JSON v2 → stdout / PUSH_URLS (см. agent/)
#   --config/--pkg/--product/--host-id/--host-ip/--service-name
#   --dev / --selftest  самотест (simple|extended)
#
# Это health-only вариант flat_check_2.sh: тот же опрос ОС/CPU/MEM/диска/БД/
# сети/сертификатов/uptime, пакетов, портов, API и инфраструктуры — без
# сборщика логов (online/offline, tail, tcpdump, parce_service_log*).
#
# Внутренняя структура (искать "# --- N."):
#   0  глобальные переменные / флаги (включая SCRIPT_DIR/LOG_FILE)
#   1  метаданные продуктов PKG_*
#   2  хелперы вывода + логирование в файл (_log_line/log_debug/init_logging)
#   3  ОС / пакетный менеджер
#   3b системные метрики (CPU/MEM/диск/БД/сеть/сертификаты/аптайм)
#   4  проверки состояния по пакетам
#   5  инфраструктура + репозитории
#   9  параллельный опрос пакетов (resource-gate, те же хелперы что в flat_check_2)
#  11  справка, argv, main, selftest
#
# Лог сессии: каждый запуск пишет ${SCRIPT_NAME}.log рядом со скриптом
#   (перезаписывается). Сборщик логов — в flat_check_2.sh.

SCRIPT_VERSION="3.7.0"

set -uo pipefail

# --- 0. Глобальные переменные ---------------------------------------------------

# Путь и имя скрипта — для сессионного лога; вычисляем один раз.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
[[ -z "$SCRIPT_DIR" ]] && SCRIPT_DIR="$(pwd)"
SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
SCRIPT_NAME="${SCRIPT_NAME%.sh}"

# Путь текущего сессионного лог-файла (<SCRIPT_NAME>.log); "" = логирование в
# файл отключено (нет прав на запись).
LOG_FILE=""

# Цвета
C_R='\033[0;31m'
C_G='\033[0;32m'
C_Y='\033[1;33m'
C_B='\033[0;34m'
C_N='\033[0m'

ERRORS=0
WARNINGS=0
INSTALLED=0
NOT_INSTALLED=0
VERBOSE=0
SHOW_REPO=0
MODE_DEV=0
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

# Ассоциативные массивы метаданных
# Формат: PKG_PORTS["имя"]="порт1,порт2"
# Формат: PKG_API["имя"]="/health/endpoint"
# Формат: PKG_LEGACY["имя"]="старое_имя1,старое_имя2"
# Формат: PKG_PRODUCT["имя"]="Имя продукта"
# Формат: PKG_DEPS["имя"]="nginx,mariadb"

declare -A PKG_PORTS
declare -A PKG_API
declare -A PKG_LEGACY
declare -A PKG_PRODUCT
declare -A PKG_DEPS

# Собрать все уникальные зависимости по установленным пакетам
# ALL_DEPENDS["имя_зависимости"]="pkg1,pkg2"
declare -A ALL_DEPENDS

# --- 1. Метаданные продуктов PKG_* ----------------------------------------------
PKG_PRODUCT["acs-frontend"]="AutoCallServer"
PKG_LEGACY["acs-frontend"]=""
PKG_PORTS["acs-frontend"]=""
PKG_API["acs-frontend"]=""
PKG_DEPS["acs-frontend"]="nginx"

PKG_PRODUCT["acs-media"]="AutoCallServer"
PKG_LEGACY["acs-media"]="acs-media"
PKG_PORTS["acs-media"]="5060,10000-20000"
PKG_API["acs-media"]=""
PKG_DEPS["acs-media"]=""

PKG_PRODUCT["acs-tools"]="AutoCallServer"
PKG_LEGACY["acs-tools"]="acs-tools"
PKG_PORTS["acs-tools"]=""
PKG_API["acs-tools"]=""
PKG_DEPS["acs-tools"]=""

PKG_PRODUCT["acs-server"]="AutoCallServer"
PKG_LEGACY["acs-server"]="acs-web"
PKG_PORTS["acs-server"]="8080"
PKG_API["acs-server"]=""
PKG_DEPS["acs-server"]=""

# ========== Продукт: BSS ==========
PKG_PRODUCT["fcs-bssimp"]="BSS"
PKG_LEGACY["fcs-bssimp"]="bssimp"
PKG_PORTS["fcs-bssimp"]=""
PKG_API["fcs-bssimp"]=""
PKG_DEPS["fcs-bssimp"]=""

PKG_PRODUCT["fcs-bssexp"]="BSS"
PKG_LEGACY["fcs-bssexp"]="bssexpa"
PKG_PORTS["fcs-bssexp"]=""
PKG_API["fcs-bssexp"]=""
PKG_DEPS["fcs-bssexp"]=""

# ========== Продукт: Click to Call ==========
PKG_PRODUCT["c2c-backend"]="Click to Call"
PKG_LEGACY["c2c-backend"]=""
PKG_PORTS["c2c-backend"]="8080"
PKG_API["c2c-backend"]="/api/health"
PKG_DEPS["c2c-backend"]=""

PKG_PRODUCT["c2c-frontend"]="Click to Call"
PKG_LEGACY["c2c-frontend"]=""
PKG_PORTS["c2c-frontend"]=""
PKG_API["c2c-frontend"]=""
PKG_DEPS["c2c-frontend"]="nginx"

# ========== Продукт: Contact Center ==========
PKG_PRODUCT["fcs-span"]="Contact Center"
PKG_LEGACY["fcs-span"]=""
PKG_PORTS["fcs-span"]=""
PKG_API["fcs-span"]=""
PKG_DEPS["fcs-span"]=""

PKG_PRODUCT["fcs-chat"]="Contact Center"
PKG_LEGACY["fcs-chat"]="fcs-chat-server"
PKG_PORTS["fcs-chat"]=""
PKG_API["fcs-chat"]=""
PKG_DEPS["fcs-chat"]=""

PKG_PRODUCT["fcs-contact"]="Contact Center"
PKG_LEGACY["fcs-contact"]="fcs-flexconnect"
PKG_PORTS["fcs-contact"]=""
PKG_API["fcs-contact"]=""
PKG_DEPS["fcs-contact"]=""

PKG_PRODUCT["fcs-contact-db"]="Contact Center"
PKG_LEGACY["fcs-contact-db"]=""
PKG_PORTS["fcs-contact-db"]=""
PKG_API["fcs-contact-db"]=""
PKG_DEPS["fcs-contact-db"]="mariadb"

PKG_PRODUCT["fcs-contact-db-pg"]="Contact Center"
PKG_LEGACY["fcs-contact-db-pg"]=""
PKG_PORTS["fcs-contact-db-pg"]=""
PKG_API["fcs-contact-db-pg"]=""
PKG_DEPS["fcs-contact-db-pg"]="postgresql"

PKG_PRODUCT["fcs-recognize"]="Contact Center"
PKG_LEGACY["fcs-recognize"]="flat-contact-recognize"
PKG_PORTS["fcs-recognize"]=""
PKG_API["fcs-recognize"]=""
PKG_DEPS["fcs-recognize"]=""

PKG_PRODUCT["fcs-replication"]="Contact Center"
PKG_LEGACY["fcs-replication"]="fcs-record-replication,flat-record-replication"
PKG_PORTS["fcs-replication"]=""
PKG_API["fcs-replication"]=""
PKG_DEPS["fcs-replication"]=""

PKG_PRODUCT["fcs-recordtask"]="Contact Center"
PKG_LEGACY["fcs-recordtask"]="fcs-recproc,flat-record-taskservice"
PKG_PORTS["fcs-recordtask"]=""
PKG_API["fcs-recordtask"]=""
PKG_DEPS["fcs-recordtask"]=""

PKG_PRODUCT["fcs-screen"]="Contact Center"
PKG_LEGACY["fcs-screen"]="fcs-screen-record,flat-screen-recording"
PKG_PORTS["fcs-screen"]=""
PKG_API["fcs-screen"]=""
PKG_DEPS["fcs-screen"]=""

PKG_PRODUCT["fcs-swau"]="Contact Center"
PKG_LEGACY["fcs-swau"]="fcs-swau"
PKG_PORTS["fcs-swau"]=""
PKG_API["fcs-swau"]=""
PKG_DEPS["fcs-swau"]=""

PKG_PRODUCT["fcs-swau-db"]="Contact Center"
PKG_LEGACY["fcs-swau-db"]=""
PKG_PORTS["fcs-swau-db"]=""
PKG_API["fcs-swau-db"]=""
PKG_DEPS["fcs-swau-db"]="mariadb"

PKG_PRODUCT["fcs-swau-db-pg"]="Contact Center"
PKG_LEGACY["fcs-swau-db-pg"]=""
PKG_PORTS["fcs-swau-db-pg"]=""
PKG_API["fcs-swau-db-pg"]=""
PKG_DEPS["fcs-swau-db-pg"]="postgresql"

PKG_PRODUCT["fcs-swiam"]="Contact Center"
PKG_LEGACY["fcs-swiam"]="fcs-swfo,fcs-alarm,flat-contact-alarm"
PKG_PORTS["fcs-swiam"]=""
PKG_API["fcs-swiam"]=""
PKG_DEPS["fcs-swiam"]=""

PKG_PRODUCT["fcs-swiam-db"]="Contact Center"
PKG_LEGACY["fcs-swiam-db"]=""
PKG_PORTS["fcs-swiam-db"]=""
PKG_API["fcs-swiam-db"]=""
PKG_DEPS["fcs-swiam-db"]="mariadb"

PKG_PRODUCT["fcs-swiam-db-pg"]="Contact Center"
PKG_LEGACY["fcs-swiam-db-pg"]=""
PKG_PORTS["fcs-swiam-db-pg"]=""
PKG_API["fcs-swiam-db-pg"]=""
PKG_DEPS["fcs-swiam-db-pg"]="postgresql"

PKG_PRODUCT["fcs-swicl"]="Contact Center"
PKG_LEGACY["fcs-swicl"]=""
PKG_PORTS["fcs-swicl"]=""
PKG_API["fcs-swicl"]=""
PKG_DEPS["fcs-swicl"]=""

PKG_PRODUCT["fcs-swiib"]="Contact Center"
PKG_LEGACY["fcs-swiib"]=""
PKG_PORTS["fcs-swiib"]=""
PKG_API["fcs-swiib"]=""
PKG_DEPS["fcs-swiib"]=""

PKG_PRODUCT["fcs-swikc"]="Contact Center"
PKG_LEGACY["fcs-swikc"]="flat-contact-center"
PKG_PORTS["fcs-swikc"]=""
PKG_API["fcs-swikc"]=""
PKG_DEPS["fcs-swikc"]=""

PKG_PRODUCT["fcs-swikc-db"]="Contact Center"
PKG_LEGACY["fcs-swikc-db"]=""
PKG_PORTS["fcs-swikc-db"]=""
PKG_API["fcs-swikc-db"]=""
PKG_DEPS["fcs-swikc-db"]="mariadb"

PKG_PRODUCT["fcs-swikc-db-pg"]="Contact Center"
PKG_LEGACY["fcs-swikc-db-pg"]=""
PKG_PORTS["fcs-swikc-db-pg"]=""
PKG_API["fcs-swikc-db-pg"]=""
PKG_DEPS["fcs-swikc-db-pg"]="postgresql"

PKG_PRODUCT["fcs-swiop"]="Contact Center"
PKG_LEGACY["fcs-swiop"]="flat-contact-operator-interface"
PKG_PORTS["fcs-swiop"]=""
PKG_API["fcs-swiop"]=""
PKG_DEPS["fcs-swiop"]=""

PKG_PRODUCT["fcs-swir"]="Contact Center"
PKG_LEGACY["fcs-swir"]="flat-contact-recording"
PKG_PORTS["fcs-swir"]=""
PKG_API["fcs-swir"]=""
PKG_DEPS["fcs-swir"]=""

PKG_PRODUCT["fcs-swir-db"]="Contact Center"
PKG_LEGACY["fcs-swir-db"]=""
PKG_PORTS["fcs-swir-db"]=""
PKG_API["fcs-swir-db"]=""
PKG_DEPS["fcs-swir-db"]="mariadb"

PKG_PRODUCT["fcs-swir-db-pg"]="Contact Center"
PKG_LEGACY["fcs-swir-db-pg"]=""
PKG_PORTS["fcs-swir-db-pg"]=""
PKG_API["fcs-swir-db-pg"]=""
PKG_DEPS["fcs-swir-db-pg"]="postgresql"

PKG_PRODUCT["fcs-swui"]="Contact Center"
PKG_LEGACY["fcs-swui"]="flat-constact-system-of-analytics"
PKG_PORTS["fcs-swui"]=""
PKG_API["fcs-swui"]=""
PKG_DEPS["fcs-swui"]=""

PKG_PRODUCT["fcs-swui-db"]="Contact Center"
PKG_LEGACY["fcs-swui-db"]="data-base-system-analytics"
PKG_PORTS["fcs-swui-db"]=""
PKG_API["fcs-swui-db"]=""
PKG_DEPS["fcs-swui-db"]="mariadb"

PKG_PRODUCT["fcs-unigy"]="Contact Center"
PKG_LEGACY["fcs-unigy"]="fcs-unigy-connector"
PKG_PORTS["fcs-unigy"]=""
PKG_API["fcs-unigy"]=""
PKG_DEPS["fcs-unigy"]=""

PKG_PRODUCT["frec-frontend"]="Contact Center"
PKG_LEGACY["frec-frontend"]=""
PKG_PORTS["frec-frontend"]=""
PKG_API["frec-frontend"]=""
PKG_DEPS["frec-frontend"]="nginx"

PKG_PRODUCT["frec-backend"]="Contact Center"
PKG_LEGACY["frec-backend"]="flat-recording-backend"
PKG_PORTS["frec-backend"]=""
PKG_API["frec-backend"]=""
PKG_DEPS["frec-backend"]=""

PKG_PRODUCT["fcs-record-export"]="Contact Center"
PKG_LEGACY["fcs-record-export"]="flat-record-export-service"
PKG_PORTS["fcs-record-export"]=""
PKG_API["fcs-record-export"]=""
PKG_DEPS["fcs-record-export"]=""

PKG_PRODUCT["fcs-recognition"]="Contact Center"
PKG_LEGACY["fcs-recognition"]="asr"
PKG_PORTS["fcs-recognition"]=""
PKG_API["fcs-recognition"]=""
PKG_DEPS["fcs-recognition"]=""

PKG_PRODUCT["asr-backend"]="Contact Center"
PKG_LEGACY["asr-backend"]=""
PKG_PORTS["asr-backend"]=""
PKG_API["asr-backend"]=""
PKG_DEPS["asr-backend"]=""

PKG_PRODUCT["asr-analytics"]="Contact Center"
PKG_LEGACY["asr-analytics"]=""
PKG_PORTS["asr-analytics"]=""
PKG_API["asr-analytics"]=""
PKG_DEPS["asr-analytics"]=""

# ========== Продукт: Device Manager ==========
PKG_PRODUCT["fdm-server"]="Device Manager"
PKG_LEGACY["fdm-server"]="fdm-server"
PKG_PORTS["fdm-server"]=""
PKG_API["fdm-server"]=""
PKG_DEPS["fdm-server"]=""

PKG_PRODUCT["fcc-frontend"]="Device Manager"
PKG_LEGACY["fcc-frontend"]=""
PKG_PORTS["fcc-frontend"]=""
PKG_API["fcc-frontend"]=""
PKG_DEPS["fcc-frontend"]="nginx"

PKG_PRODUCT["fcc-backend"]="Device Manager"
PKG_LEGACY["fcc-backend"]=""
PKG_PORTS["fcc-backend"]=""
PKG_API["fcc-backend"]=""
PKG_DEPS["fcc-backend"]=""

# ========== Продукт: Gateway ==========
PKG_PRODUCT["fg-frontend"]="Gateway"
PKG_LEGACY["fg-frontend"]=""
PKG_PORTS["fg-frontend"]=""
PKG_API["fg-frontend"]=""
PKG_DEPS["fg-frontend"]="nginx"

PKG_PRODUCT["fg-backend"]="Gateway"
PKG_LEGACY["fg-backend"]=""
PKG_PORTS["fg-backend"]=""
PKG_API["fg-backend"]=""
PKG_DEPS["fg-backend"]=""

# ========== Продукт: Partner Server ==========
PKG_PRODUCT["fps-backend"]="Partner Server"
PKG_LEGACY["fps-backend"]="flatPartnerAuth"
PKG_PORTS["fps-backend"]=""
PKG_API["fps-backend"]=""
PKG_DEPS["fps-backend"]=""

PKG_PRODUCT["fps-profile"]="Partner Server"
PKG_LEGACY["fps-profile"]="flatImageProcessor"
PKG_PORTS["fps-profile"]=""
PKG_API["fps-profile"]=""
PKG_DEPS["fps-profile"]=""

PKG_PRODUCT["fps-frontend"]="Partner Server"
PKG_LEGACY["fps-frontend"]="flatPartnerFrontend"
PKG_PORTS["fps-frontend"]=""
PKG_API["fps-frontend"]=""
PKG_DEPS["fps-frontend"]="nginx"

PKG_PRODUCT["fps-license"]="Partner Server"
PKG_LEGACY["fps-license"]="flatPartnerLicense"
PKG_PORTS["fps-license"]=""
PKG_API["fps-license"]=""
PKG_DEPS["fps-license"]=""

PKG_PRODUCT["fps-admin"]="Partner Server"
PKG_LEGACY["fps-admin"]="flatPartnerLicenseAdmin"
PKG_PORTS["fps-admin"]=""
PKG_API["fps-admin"]=""
PKG_DEPS["fps-admin"]=""

PKG_PRODUCT["fps-agent"]="Partner Server"
PKG_LEGACY["fps-agent"]="flatPartnerLicenseAgent"
PKG_PORTS["fps-agent"]=""
PKG_API["fps-agent"]=""
PKG_DEPS["fps-agent"]=""

PKG_PRODUCT["fps-server"]="Partner Server"
PKG_LEGACY["fps-server"]="flatPartnerServer"
PKG_PORTS["fps-server"]=""
PKG_API["fps-server"]=""
PKG_DEPS["fps-server"]=""

PKG_PRODUCT["fps-push"]="Partner Server"
PKG_LEGACY["fps-push"]="flatPushNotificationServer"
PKG_PORTS["fps-push"]=""
PKG_API["fps-push"]=""
PKG_DEPS["fps-push"]=""

PKG_PRODUCT["fps-control"]="Partner Server"
PKG_LEGACY["fps-control"]="flatPartnerFLC"
PKG_PORTS["fps-control"]=""
PKG_API["fps-control"]=""
PKG_DEPS["fps-control"]=""

PKG_PRODUCT["fps-phonebook"]="Partner Server"
PKG_LEGACY["fps-phonebook"]=""
PKG_PORTS["fps-phonebook"]=""
PKG_API["fps-phonebook"]=""
PKG_DEPS["fps-phonebook"]=""

# ========== Продукт: SoftSwitch ==========
PKG_PRODUCT["fss-frontend"]="SoftSwitch"
PKG_LEGACY["fss-frontend"]="softswitch-frontend"
PKG_PORTS["fss-frontend"]=""
PKG_API["fss-frontend"]=""
PKG_DEPS["fss-frontend"]="nginx"

PKG_PRODUCT["fss-backend"]="SoftSwitch"
PKG_LEGACY["fss-backend"]="flatSoftSwitchBackend"
PKG_PORTS["fss-backend"]="8082"
PKG_API["fss-backend"]="/api/health"
PKG_DEPS["fss-backend"]="postgresql"

PKG_PRODUCT["fss-mediasrv"]="SoftSwitch"
PKG_LEGACY["fss-mediasrv"]="mediasrv"
PKG_PORTS["fss-mediasrv"]="5060,10000-20000"
PKG_API["fss-mediasrv"]=""
PKG_DEPS["fss-mediasrv"]=""

PKG_PRODUCT["fss-srclient"]="SoftSwitch"
PKG_LEGACY["fss-srclient"]="srclient"
PKG_PORTS["fss-srclient"]=""
PKG_API["fss-srclient"]=""
PKG_DEPS["fss-srclient"]="fss-server"

PKG_PRODUCT["fss-server"]="SoftSwitch"
PKG_LEGACY["fss-server"]=""
PKG_PORTS["fss-server"]="8080,8081"
PKG_API["fss-server"]="/api/v1/health"
PKG_DEPS["fss-server"]="nginx,postgresql"

PKG_PRODUCT["fss-web"]="SoftSwitch"
PKG_LEGACY["fss-web"]="fss-web"
PKG_PORTS["fss-web"]=""
PKG_API["fss-web"]=""
PKG_DEPS["fss-web"]="nginx"

PKG_PRODUCT["fss-csta"]="SoftSwitch"
PKG_LEGACY["fss-csta"]="csta-rest-broker"
PKG_PORTS["fss-csta"]=""
PKG_API["fss-csta"]=""
PKG_DEPS["fss-csta"]=""

PKG_PRODUCT["fss-capagent"]="SoftSwitch"
PKG_LEGACY["fss-capagent"]="flat-capagent"
PKG_PORTS["fss-capagent"]=""
PKG_API["fss-capagent"]=""
PKG_DEPS["fss-capagent"]=""

# ========== Продукт: Tarifficator ==========
PKG_PRODUCT["ftr-frontend"]="Tarifficator"
PKG_LEGACY["ftr-frontend"]="tarifficator-frontend"
PKG_PORTS["ftr-frontend"]=""
PKG_API["ftr-frontend"]=""
PKG_DEPS["ftr-frontend"]="nginx"

PKG_PRODUCT["ftr-server"]="Tarifficator"
PKG_LEGACY["ftr-server"]=""
PKG_PORTS["ftr-server"]=""
PKG_API["ftr-server"]=""
PKG_DEPS["ftr-server"]=""

PKG_PRODUCT["ftr-backend"]="Tarifficator"
PKG_LEGACY["ftr-backend"]=""
PKG_PORTS["ftr-backend"]=""
PKG_API["ftr-backend"]=""
PKG_DEPS["ftr-backend"]=""

PKG_PRODUCT["ftr-server-db"]="Tarifficator"
PKG_LEGACY["ftr-server-db"]=""
PKG_PORTS["ftr-server-db"]=""
PKG_API["ftr-server-db"]=""
PKG_DEPS["ftr-server-db"]="mariadb"

PKG_PRODUCT["ftr-server-db-pg"]="Tarifficator"
PKG_LEGACY["ftr-server-db-pg"]=""
PKG_PORTS["ftr-server-db-pg"]=""
PKG_API["ftr-server-db-pg"]=""
PKG_DEPS["ftr-server-db-pg"]="postgresql"

PKG_PRODUCT["ftr-web"]="Tarifficator"
PKG_LEGACY["ftr-web"]=""
PKG_PORTS["ftr-web"]=""
PKG_API["ftr-web"]=""
PKG_DEPS["ftr-web"]="nginx"

# ========== Продукт: IVR ==========
PKG_PRODUCT["ivr-frontend"]="IVR"
PKG_LEGACY["ivr-frontend"]=""
PKG_PORTS["ivr-frontend"]=""
PKG_API["ivr-frontend"]=""
PKG_DEPS["ivr-frontend"]="nginx"

PKG_PRODUCT["ivr-backend"]="IVR"
PKG_LEGACY["ivr-backend"]="flatIVRBuilder"
PKG_PORTS["ivr-backend"]=""
PKG_API["ivr-backend"]=""
PKG_DEPS["ivr-backend"]=""

# ========== Продукт: LC ==========
PKG_PRODUCT["lc-frontend"]="LC"
PKG_LEGACY["lc-frontend"]="lc-softswitch-frontend"
PKG_PORTS["lc-frontend"]=""
PKG_API["lc-frontend"]=""
PKG_DEPS["lc-frontend"]="nginx"

PKG_PRODUCT["lc-backend"]="LC"
PKG_LEGACY["lc-backend"]="flatSoftSwitchLK"
PKG_PORTS["lc-backend"]=""
PKG_API["lc-backend"]=""
PKG_DEPS["lc-backend"]=""

# ========== Продукт: SMS ==========
PKG_PRODUCT["flat-sms"]="SMS"
PKG_LEGACY["flat-sms"]=""
PKG_PORTS["flat-sms"]=""
PKG_API["flat-sms"]=""
PKG_DEPS["flat-sms"]=""

PKG_PRODUCT["flat-smpp"]="SMS"
PKG_LEGACY["flat-smpp"]=""
PKG_PORTS["flat-smpp"]=""
PKG_API["flat-smpp"]=""
PKG_DEPS["flat-smpp"]=""

# ========== Продукт: LDAP ==========
PKG_PRODUCT["fbr-frontend"]="LDAP"
PKG_LEGACY["fbr-frontend"]="fpbf-frontend"
PKG_PORTS["fbr-frontend"]=""
PKG_API["fbr-frontend"]=""
PKG_DEPS["fbr-frontend"]="nginx"

PKG_PRODUCT["fbr-backend"]="LDAP"
PKG_LEGACY["fbr-backend"]="flatPartnerBroker,flat-broker"
PKG_PORTS["fbr-backend"]=""
PKG_API["fbr-backend"]=""
PKG_DEPS["fbr-backend"]=""

PKG_PRODUCT["flat-ldap"]="LDAP"
PKG_LEGACY["flat-ldap"]="ldapSynchronizer"
PKG_PORTS["flat-ldap"]=""
PKG_API["flat-ldap"]=""
PKG_DEPS["flat-ldap"]=""

PKG_PRODUCT["flat-broker"]="LDAP"
PKG_LEGACY["flat-broker"]=""
PKG_PORTS["flat-broker"]=""
PKG_API["flat-broker"]=""
PKG_DEPS["flat-broker"]=""

PKG_PRODUCT["flat-transfer-server"]="LDAP"
PKG_LEGACY["flat-transfer-server"]=""
PKG_PORTS["flat-transfer-server"]=""
PKG_API["flat-transfer-server"]=""
PKG_DEPS["flat-transfer-server"]=""

# ========== Продукт: SBC ==========
PKG_PRODUCT["sbc-backend"]="SBC"
PKG_LEGACY["sbc-backend"]="flat.sbc.backend"
PKG_PORTS["sbc-backend"]=""
PKG_API["sbc-backend"]=""
PKG_DEPS["sbc-backend"]=""

PKG_PRODUCT["sbc-core"]="SBC"
PKG_LEGACY["sbc-core"]="flat.sbc.core"
PKG_PORTS["sbc-core"]=""
PKG_API["sbc-core"]=""
PKG_DEPS["sbc-core"]=""

PKG_PRODUCT["sbc-frontend"]="SBC"
PKG_LEGACY["sbc-frontend"]=""
PKG_PORTS["sbc-frontend"]=""
PKG_API["sbc-frontend"]=""
PKG_DEPS["sbc-frontend"]="nginx"

# ========== Продукт: Portal ==========
PKG_PRODUCT["fpl-backend"]="Portal"
PKG_LEGACY["fpl-backend"]=""
PKG_PORTS["fpl-backend"]=""
PKG_API["fpl-backend"]=""
PKG_DEPS["fpl-backend"]=""

PKG_PRODUCT["fpl-frontend"]="Portal"
PKG_LEGACY["fpl-frontend"]=""
PKG_PORTS["fpl-frontend"]=""
PKG_API["fpl-frontend"]=""
PKG_DEPS["fpl-frontend"]="nginx"

PKG_PRODUCT["fpl2-frontend"]="Portal"
PKG_LEGACY["fpl2-frontend"]=""
PKG_PORTS["fpl2-frontend"]=""
PKG_API["fpl2-frontend"]=""
PKG_DEPS["fpl2-frontend"]="nginx"

PKG_PRODUCT["fsft-frontend"]="Portal"
PKG_LEGACY["fsft-frontend"]=""
PKG_PORTS["fsft-frontend"]=""
PKG_API["fsft-frontend"]=""
PKG_DEPS["fsft-frontend"]="nginx"

# ========== Продукт: flat-file ==========
PKG_PRODUCT["flat-file"]="flat-file"
PKG_LEGACY["flat-file"]="flatFileManager,fss-file"
PKG_PORTS["flat-file"]="8083"
PKG_API["flat-file"]="/api/health"
PKG_DEPS["flat-file"]="nginx"

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

# Технические подробности только в файл лога (снимки CPU/MEM и т.п.) —
# не выводятся на экран, чтобы не перегружать вывод.
log_debug() {
    _log_line "DEBUG" "$1"
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
    _log_line "INFO" "=== ${SCRIPT_NAME}.sh v${SCRIPT_VERSION} — сессия начата ==="
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

die() { fail "$1"; exit 1; }


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
    sleep 0.25
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

    # Проблема с путём по умолчанию — проверить, активен ли процесс
    local is_active=0
    if pgrep -x "$pkg" &>/dev/null || pgrep -f "$pkg" &>/dev/null; then
        is_active=1
    fi

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
    pids=$(pgrep -d ',' -x "$pkg" 2>/dev/null || true)
    if [[ -z "$pids" ]]; then
        pids=$(pgrep -d ',' -f "$pkg" 2>/dev/null || true)
    fi

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

check_infrastructure() {
    echo ""
    echo "=== Infrastructure ==="

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


# --- 9. Параллельный опрос пакетов (resource-gate) ------------------------------
# Те же хелперы, что использует run_product_checks() в flat_check_2.sh.
# Имена _collector_* сохранены намеренно — поведение 1к1 с flat_check_2.

# Для health-check всегда «не останавливаться» (флаги сборщика логов отсутствуют).
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
: "${SHOW_REPOS_JSON:=0}"

_json_load_config() {
    # Conf заполняет только пустые переменные: CLI и env имеют приоритет.
    local f="$1" line key val cur
    [[ -n "$f" && -f "$f" ]] || return 0
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ -z "${line//[[:space:]]/}" ]] && continue
        if [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
            key="${BASH_REMATCH[1]}"
            val="${BASH_REMATCH[2]}"
            val="${val%\"}"; val="${val#\"}"
            val="${val%\'}"; val="${val#\'}"
            case "$key" in
                HOST_ID|HOST_IP|SERVICE_NAME|PUSH_URLS|PUSH_URL|PUSH_TOKEN|PUSH_TOKENS|PUSH_AUTH_HEADER|PACKAGES|PRODUCT)
                    cur="${!key-}"
                    if [[ -z "$cur" ]]; then
                        printf -v "$key" '%s' "$val"
                    fi
                    ;;
                PUSH_CONNECT_TIMEOUT|PUSH_MAX_TIME|PUSH_RETRIES)
                    if [[ "$val" =~ ^[0-9]+$ ]]; then
                        printf -v "$key" '%s' "$val"
                    fi
                    ;;
                COLLECTOR_JOBS|JOBS)
                    if [[ "$val" =~ ^[0-9]+$ ]]; then
                        [[ "$key" == "JOBS" ]] && key="COLLECTOR_JOBS"
                        # 0 = авто; не затираем явный -j/--jobs
                        if [[ "${COLLECTOR_JOBS:-0}" -eq 0 ]]; then
                            printf -v "$key" '%s' "$val"
                        fi
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
    if command -v pgrep >/dev/null 2>&1; then
        pids=$(pgrep -d',' -f "/opt/flat/$pkg|/usr/lib.*/$pkg|$pkg" 2>/dev/null | head -c 200 || true)
    fi
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
            api_code=$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 2 --max-time 5 "$api_url" 2>/dev/null || echo 0)
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
    cpu_pct=$(_get_cpu_usage_percent 2>/dev/null || echo 0)
    [[ "$cpu_pct" == "0" ]] && { sleep 0.2; cpu_pct=$(_get_cpu_usage_percent 2>/dev/null || echo 0); }

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
    for dep in "${!ALL_DEPENDS[@]}"; do
        status="unknown"; ver=""; port=""; req="${ALL_DEPENDS[$dep]}"
        if command -v systemctl >/dev/null 2>&1; then
            if systemctl is-active --quiet "$dep" 2>/dev/null; then
                status="active"
            elif systemctl status "$dep" &>/dev/null; then
                status=$(systemctl is-active "$dep" 2>/dev/null || echo inactive)
            fi
        fi
        ver=$(get_dep_version "$dep" 2>/dev/null || true)
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
    unset ALL_DEPENDS; declare -A ALL_DEPENDS

    ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    system_json=$(_json_collect_system)
    certs_json=$(cat "${_JSON_TMP}/certificates.json" 2>/dev/null || echo '[]')

    products_list=("AutoCallServer" "BSS" "Click to Call" "Contact Center" "Device Manager" "Gateway" "Partner Server" "SoftSwitch" "Tarifficator" "IVR" "LC" "SMS" "LDAP" "SBC" "Portal" "flat-file")
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
        IFS=$'\n' product_pkgs=($(printf '%s\n' "${product_pkgs[@]}" | sort)); unset IFS
        for pkg in "${product_pkgs[@]}"; do
            local pj
            pj=$(_json_collect_pkg "$pkg") || continue
            # регистрация deps для infra
            local d
            for d in $(echo "${PKG_DEPS[$pkg]:-}" | tr ',' ' '); do
                [[ -n "$d" ]] && register_dep "$d" "$pkg" 2>/dev/null || true
            done
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
push_health_json() {
    local body="$1"
    local urls=() tokens=() url token i rc=0 http_code
    local auth_hdr="${PUSH_AUTH_HEADER:-Authorization: Bearer}"

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

        local attempt=0 ok=0
        while [[ $attempt -le ${PUSH_RETRIES:-2} ]]; do
            attempt=$((attempt + 1))
            http_code=$(curl -sS -o /tmp/flat_push_body.$$ -w '%{http_code}' \
                --connect-timeout "${PUSH_CONNECT_TIMEOUT:-5}" \
                --max-time "${PUSH_MAX_TIME:-30}" \
                -X POST "$url" \
                -H "Content-Type: application/json" \
                -H "X-Flat-Host-Id: ${HOST_ID}" \
                -H "X-Flat-Service-Name: ${SERVICE_NAME}" \
                ${token:+-H "$auth_hdr $token"} \
                --data-binary "$body" 2>/dev/null || echo "000")
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

run_health_json() {
    local body
    [[ -n "$CONFIG_FILE" ]] && _json_load_config "$CONFIG_FILE"
    body=$(build_health_json) || { fail "не удалось собрать JSON"; return 1; }
    if [[ "$DO_PUSH" -eq 1 ]]; then
        # при --push JSON тоже можно показать через --json; иначе только push
        [[ "$OUTPUT_JSON" -eq 1 ]] && printf '%s\n' "$body"
        push_health_json "$body"
        return $?
    fi
    printf '%s\n' "$body"
}

# --- 11. Selftest / справка / argv / main ---------------------------------------

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
    [[ "$pkg_count" -gt 0 ]] && _selftest_ok "PKG_PRODUCT entries=$pkg_count" || _selftest_bad "PKG_PRODUCT empty"
}

_run_selftest_extended() {
    info "Self-test EXTENDED (VERBOSE health)"
    _run_selftest_simple
    VERBOSE=1
    detect_os
    check_system
    local products p
    products=("AutoCallServer" "BSS" "Click to Call" "Contact Center" "Device Manager" "Gateway" "Partner Server" "SoftSwitch" "Tarifficator" "IVR" "LC" "SMS" "LDAP" "SBC" "Portal" "flat-file")
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

usage() {
    cat <<EOF
flat_check.sh v${SCRIPT_VERSION} — FLAT/FCS health check (JSON agent / no log collector)

Usage:
  $0 [OPTIONS]

Health (text):
  -i, --info            detailed info for all packages
  -r, --repo            show repositories
  -j, --jobs N          parallel package-check workers
  -v, --version         print version
  -h, --help            this help

JSON agent (dashboard / multi-product):
  --config FILE         agent config (/etc/flat/flat_check.conf)
  --pkg NAME            single package only
  --product NAME        single product only
  --json                emit health JSON v2 to stdout
  --push                POST JSON to all PUSH_URLS (http/https)
  --host-id ID          override HOST_ID
  --host-ip IP          override HOST_IP
  --service-name NAME   override SERVICE_NAME (fss-backend, fps-backend, …)

Selftest:
  --selftest [simple|extended]
  --dev                 = --selftest extended

Examples:
  $0
  $0 --config /etc/flat/flat_check.conf --json
  $0 --config /etc/flat/flat_check.conf --json --push
  $0 --pkg fss-server --json

Installer: see agent/README.md
Log collector: flat_check_2.sh
EOF
    exit 0
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -i|--info|-info) VERBOSE=1; shift ;;
            --no-info) VERBOSE=0; shift ;;
            -r|--repo|-repo) SHOW_REPO=1; SHOW_REPOS_JSON=1; shift ;;
            -v|--version) echo "flat_check ${SCRIPT_VERSION}"; exit 0 ;;
            -j|--jobs)
                [[ -z "${2:-}" || "$2" == -* ]] && die "Missing value for $1"
                [[ "$2" =~ ^[1-9][0-9]*$ ]] || die "Invalid --jobs: '$2'"
                COLLECTOR_JOBS="$2"; shift 2 ;;
            --config)
                [[ -z "${2:-}" || "$2" == -* ]] && die "Missing value for $1"
                CONFIG_FILE="$2"; shift 2 ;;
            --pkg)
                [[ -z "${2:-}" || "$2" == -* ]] && die "Missing value for $1"
                SINGLE_PKG="$2"; shift 2 ;;
            --product)
                [[ -z "${2:-}" || "$2" == -* ]] && die "Missing value for $1"
                FILTER_PRODUCT="$2"; shift 2 ;;
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
            --selftest)
                if [[ -n "${2:-}" && "$2" != -* ]]; then SELFTEST_MODE="$2"; shift 2
                else SELFTEST_MODE="simple"; shift; fi ;;
            --dev) MODE_DEV=1; SELFTEST_MODE="extended"; shift ;;
            -h|--help|-help) usage ;;
            *) die "Unknown option: $1 (try -h)" ;;
        esac
    done
}

main() {
    parse_args "$@"
    [[ -n "$CONFIG_FILE" ]] && _json_load_config "$CONFIG_FILE"

    init_logging "${SCRIPT_DIR}"
    _log_line "INFO" "Запуск: $0 $* (аргументов: $#)"

    if [[ -n "${SELFTEST_MODE:-}" ]]; then
        run_selftest "$SELFTEST_MODE"
        exit $?
    fi
    if [[ $MODE_DEV -eq 1 ]]; then
        run_selftest extended
        exit $?
    fi

    # JSON / push (dashboard)
    if [[ "$OUTPUT_JSON" -eq 1 || "$DO_PUSH" -eq 1 ]]; then
        run_health_json
        exit $?
    fi

    # Single package — text mode
    if [[ -n "$SINGLE_PKG" ]]; then
        detect_os
        if [[ -z "${PKG_PRODUCT[$SINGLE_PKG]:-}" ]]; then
            die "Unknown package: $SINGLE_PKG"
        fi
        check_single_pkg "$SINGLE_PKG"
        exit $?
    fi

    detect_os
    check_system
    local products=("AutoCallServer" "BSS" "Click to Call" "Contact Center" "Device Manager" "Gateway" "Partner Server" "SoftSwitch" "Tarifficator" "IVR" "LC" "SMS" "LDAP" "SBC" "Portal" "flat-file")
    local p
    if [[ -n "$FILTER_PRODUCT" ]]; then
        products=("$FILTER_PRODUCT")
    fi
    for p in "${products[@]}"; do run_product_checks "$p"; done
    check_infrastructure
    [[ $SHOW_REPO -eq 1 ]] && check_repositories
    print_summary
}

main "$@"
