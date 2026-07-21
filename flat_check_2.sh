#!/bin/bash
# flat_check_2.sh — FLAT/FCS health check + log collector
#
# Runs on: Debian/Ubuntu, RHEL/CentOS/ALMA/Rocky/РЕД ОС, Astra, … (dpkg/rpm + systemd)
#
# Modes:
#   (default)     health check of installed packages
#   -log -on/-off collect logs (online tail / offline parallel copy+time filter)
#                 --scope brief|extended, -p product, -s service
#   -i            interactive wizard
#   --dev / --selftest  script self-test (simple|extended)
#   -v            print version
#
# Offline time range filters LINES by timestamp inside the file (not mtime).
# Large plain logs (>=1MB): binary-search bounds + parallel chunk-scan of the window.
# SoftSwitch fss-server monoliths (tens of GB) are the main target.
# .gz and unsorted files: linear / parallel full-file chunk scan.
#
# Internal layout (search for "# --- N."):
#   0  globals / flags
#   1  PKG_* product metadata
#   2  print helpers + localization
#   3  OS / package manager
#   3b system metrics (CPU/MEM/disk/DB/net/certs/uptime)
#   4  per-package health checks
#   5  infrastructure + repositories
#   6  log directory discovery
#   7  PostgreSQL log discovery
#   8  line filters by time
#   9  collector processes / signals / safe remove
#  10  online / offline collection
#  11  wizard, help, argv, main
#
# Root safety: temporary dirs are only removed if they match
#   YYYY.MM.DD_HH-MM_*  under the collector output directory.
# Never use bare rm -rf on arbitrary paths from CLI input.

SCRIPT_VERSION="3.5.1"

set -uo pipefail

# --- 0. Globals ----------------------------------------------------------------

# Colors
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

# Log collector mode flags
MODE_LOG=0
MODE_DEV=0
MODE_INTERACTIVE=0
# Self-test: "" | simple | extended  (--dev = extended; wizard mode 3 picks level)
SELFTEST_MODE=""
LOG_SUBMODE="online"
START_TCPDUMP=1
TIMEOUT_RAW=""
TIMEOUT_SEC=0
FROM_TIME=""
TO_TIME=""
OUTPUT_DIR=""
# Log selection: brief = app logs only; extended = + system/nginx/pg/configs (+ tcpdump online)
LOG_SCOPE="brief"
SELECTED_PRODUCTS=()   # product names from -p / wizard
SELECTED_SERVICES=()   # package names from -s / wizard
SELECTED_PKGS=()       # resolved package list for collection
LIST_TARGETS=0
# SoftSwitch extra: include mgcpclient logs (""=ask, 0=no, 1=yes)
INCLUDE_MGCPCLIENT=""
MGCPCLIENT_RESOLVED=0
SKIP_UNKNOWN_FLAT_REPORTED=0
EXTRA_LOG_DIRS=()      # optional dirs outside PKG allowlist (e.g. mgcpclient)

# Localization
CURRENT_LANG="en"

# Process tracking (log mode)
TAIL_PIDS=()
COLLECTOR_JOB_PIDS=()
TCPDUMP_PID=""
TIMEOUT_KILL_PID=""
DISK_WATCH_PID=""
DISCOVERED_LOG_DIRS=()
PG_LOG_SOURCES=()
COLLECTOR_ABORTED=0
COLLECTOR_TIMEOUT_STOP=0
# Offline parallel copy: 0 = auto (nproc*0.8), or set COLLECTOR_JOBS env / -j
COLLECTOR_JOBS=0
# Host-wide CPU/MEM gate (Zabbix-friendly): throttle extra workers when the whole
# system is at/above these limits (/proc — not this script's share).
# IMPORTANT: never deadlock — at least 1 worker is always allowed so offline
# collection cannot hang forever on an already-busy host (common MEM≥80%).
RESOURCE_CPU_LIMIT=80
RESOURCE_MEM_LIMIT=80
# Max seconds to wait for headroom before spawning another worker (when ≥1 already runs)
RESOURCE_WAIT_MAX=120
# Min size for bisect + parallel chunk extract (below → single-thread awk)
SEEK_MIN_BYTES=$((1 * 1024 * 1024))
# SoftSwitch-scale monoliths: larger parallel window
SEEK_HUGE_BYTES=$((1024 * 1024 * 1024))
# Parallel scan chunk size inside the [from,to] byte range
SEEK_CHUNK_BYTES=$((64 * 1024 * 1024))
# Probe chunk for timestamp samples at an offset
SEEK_PROBE_BYTES=131072
# Back off before start offset so we do not miss the first matching line
SEEK_BACKOFF_BYTES=$((1024 * 1024))
# /proc/stat snapshot for CPU delta
_CPU_PREV_IDLE=""
_CPU_PREV_TOTAL=""

# Config paths for log extraction
CONFIG_PATHS=(
    "/opt/flat/switchserver/settings.ini"
    "/opt/flat/fss-server/settings.ini"
    "/etc/flat/srclient/settings.ini"
    "/opt/flat/fss-srclient/settings.ini"
    "/etc/mediasrv/config.xml"
    "/opt/flat/fss-mediasrv/config.xml"
    "/opt/flat/flat-file/config.yml"
)

# Associative metadata arrays
# Format: PKG_PORTS["name"]="port1,port2"
# Format: PKG_API["name"]="/health/endpoint"
# Format: PKG_LEGACY["name"]="oldname1,oldname2"
# Format: PKG_PRODUCT["name"]="Product Name"
# Format: PKG_DEPS["name"]="nginx,mariadb"

declare -A PKG_PORTS
declare -A PKG_API
declare -A PKG_LEGACY
declare -A PKG_PRODUCT
declare -A PKG_DEPS

# Collect all unique dependencies across installed packages
# ALL_DEPENDS["dep_name"]="pkg1,pkg2"
declare -A ALL_DEPENDS

# --- 1. PKG_* product metadata -------------------------------------------------
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

# ========== Product: BSS ==========
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

# ========== Product: Click to Call ==========
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

# ========== Product: Contact Center ==========
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

# ========== Product: Device Manager ==========
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

# ========== Product: Gateway ==========
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

# ========== Product: Partner Server ==========
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

# ========== Product: SoftSwitch ==========
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

# ========== Product: Tarifficator ==========
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

# ========== Product: IVR ==========
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

# ========== Product: LC ==========
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

# ========== Product: SMS ==========
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

# ========== Product: LDAP ==========
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

# ========== Product: SBC ==========
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

# ========== Product: Portal ==========
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

# ========== Product: flat-file ==========
PKG_PRODUCT["flat-file"]="flat-file"
PKG_LEGACY["flat-file"]="flatFileManager,fss-file"
PKG_PORTS["flat-file"]="8083"
PKG_API["flat-file"]="/api/health"
PKG_DEPS["flat-file"]="nginx"

# --- 2. Print helpers ----------------------------------------------------------
# (print_ok / print_warn / print_fail / print_info — used by health check)

print_ok() {
    echo -e "${C_G}[OK]${C_N}    $1"
}

print_warn() {
    echo -e "${C_Y}[WARN]${C_N}  $1"
    ((WARNINGS++))
}

print_fail() {
    echo -e "${C_R}[FAIL]${C_N}  $1"
    ((ERRORS++))
}

print_info() {
    echo -e "${C_B}[INFO]${C_N}  $1"
}

print_not_installed() {
    echo -e "${C_B}[INFO]${C_N}  $1 — not installed"
}

# Short aliases for log collector
ok()  { echo -e "${C_G}[OK]${C_N}  $1"; }
warn() { echo -e "${C_Y}[WARN]${C_N} $1"; }
fail() { echo -e "${C_R}[FAIL]${C_N} $1"; }
info() { echo -e "${C_B}[INFO]${C_N} $1"; }

die() { fail "$1"; cleanup 2>/dev/null; exit 1; }

# --- 2b. Localization (_l) -----------------------------------------------------
_l() {
    local key="$1"
    case "$CURRENT_LANG" in
        ru)
            case "$key" in
                help_usage)        echo "Usage: flat_check_2.sh [РЕЖИМ] [ОПЦИИ]" ;;
                err_online_need_t) echo "Online без TTY требует -t/--timeout" ;;
                help_check)        echo "  (без аргументов)        Проверка установленных служб" ;;
                help_dev)          echo "  --dev                   Расширенный самотест (варианты + health + seek)" ;;
                help_selftest)     echo "  --selftest simple|extended  Самотест (simple=дымовой; extended=как --dev)" ;;
                help_v)            echo "  -v, --version           Показать версию скрипта и выйти" ;;
                help_log)          echo "  -log                    Режим сборщика логов" ;;
                help_log_on)       echo "    -on, --online         Сбор в реальном времени (tail -F + опц. tcpdump)" ;;
                help_log_off)      echo "    -off, --offline       Копирование готовых логов" ;;
                help_log_t)        echo "    -t, --timeout ДЛИТ    Online: автостоп через N (например 5h, 30m)" ;;
                help_log_t2)       echo "                          Offline: извлечь строки за последние N (по метке в файле). Без -t: все логи" ;;
                help_log_n)        echo "    -n, --no-tcpdump      Не записывать сетевой трафик (только online)" ;;
                help_log_j)        echo "    -j, --jobs N          Offline: параллельных копий (по умолч. nproc*80%, макс. 32; не стартуют при CPU/RAM системы ≥80%)" ;;
                help_scope)        echo "    --scope brief|extended  Краткий (только службы) / расширенный (+ system/nginx/pg/configs)" ;;
                help_product)      echo "    -p, --product NAME    Продукт (повторяемый; см. --list-targets)" ;;
                help_service)      echo "    -s, --service PKG     Служба/пакет (повторяемый)" ;;
                help_list_targets) echo "    --list-targets        Показать доступные продукты/службы и выйти" ;;
                help_mgcp)         echo "    --mgcpclient          SoftSwitch: включить mgcpclient (без вопроса)" ;;
                help_no_mgcp)      echo "    --no-mgcpclient       SoftSwitch: не собирать mgcpclient" ;;
                help_from)         echo "    -f, --from TIME       Начало диапазона (например -2h, 25.06.2026 10:00)" ;;
                help_to)           echo "    -e, --to TIME         Конец диапазона (например -1h, 25.06.2026 12:00)" ;;
                help_range_note)   echo "    Варианты: -f -2h -e -1h | -f '25.06.2026 10:00' -e '25.06.2026 12:00' | -f '25.06.2026 10:00' -e +2h" ;;
                help_repo)         echo "  -r, --repo              Показать репозитории (APT/YUM sources)" ;;
                help_out)          echo "  -o, --output ДИР        Записать архив в директорию (только -log)" ;;
                help_h)            echo "  -h, --help              Показать справку" ;;
                help_dur)          echo "Суффиксы: s=секунды, m=минуты, h=часы, d=дни. Чистое число = секунды" ;;
                ask_lang)          echo "Выберите язык / Select language:" ;;
                ask_lang_ru)       echo "  1 — Русский" ;;
                ask_lang_en)       echo "  2 — English" ;;
                ask_lang_prompt)   echo "Ваш выбор / Your choice [1-2]: " ;;
                ask_log)           echo "Нажмите [Enter] для сбора online-логов, или Ctrl+C для выхода" ;;
                mode_log)          echo "Режим логов" ;;
                mode_check)        echo "Режим проверки" ;;
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
                log_copied)        echo "Скопировано" ;;
                log_files_from)    echo "файлов из" ;;
                log_copydone)      echo "Копирование завершено" ;;
                log_all)           echo "Копирование всех логов" ;;
                log_depth)         echo "Копирование логов за последние" ;;
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
                wiz_for_offset)    echo -n "На сколько? (например +3h, +30m): " ;;
                wiz_output_dir)    echo -n "Директория для архива (Enter = рядом со скриптом): " ;;
                wiz_show_repo)     echo -n "Показать репозитории? (y/n): " ;;
                wiz_title_scope)   echo "=== Объём сбора ===" ;;
                wiz_scope_1)       echo "  1 — Краткий (только логи выбранных продуктов/служб)" ;;
                wiz_scope_2)       echo "  2 — Расширенный (+ system, nginx, PostgreSQL, configs; online: tcpdump)" ;;
                wiz_scope_prompt)  echo "Ваш выбор [1-2]: " ;;
                wiz_title_products) echo "=== Продукты ===" ;;
                wiz_products_all)  echo "  a — Все установленные" ;;
                wiz_products_prompt) echo -n "Номера через запятую или a: " ;;
                wiz_refine_services) echo -n "Уточнить службы? (y/n, Enter=n): " ;;
                wiz_title_services) echo "=== Службы ===" ;;
                wiz_services_all)  echo "  a — Все службы выбранных продуктов" ;;
                wiz_services_prompt) echo -n "Номера через запятую или a: " ;;
                wiz_no_targets)    echo "На хосте не найдено известных продуктов/служб" ;;
                wiz_preview_pkgs)  echo "Выбрано служб" ;;
                wiz_preview_dirs)  echo "Лог-директорий к сбору" ;;
                ask_mgcpclient)    echo -n "SoftSwitch: собирать логи mgcpclient? (y/n): " ;;
                mgcpclient_default_no) echo "SoftSwitch: mgcpclient пропущен (нет TTY; укажите --mgcpclient или --no-mgcpclient)" ;;
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
                help_usage)        echo "Usage: flat_check_2.sh [MODE] [OPTIONS]" ;;
                err_online_need_t) echo "Online without TTY requires -t/--timeout" ;;
                help_check)        echo "  (no args)               Health check (installed services only)" ;;
                help_dev)          echo "  --dev                   Extended self-test (variants + health + seek)" ;;
                help_selftest)     echo "  --selftest simple|extended  Self-test (simple=smoke; extended=same as --dev)" ;;
                help_v)            echo "  -v, --version           Print script version and exit" ;;
                help_log)          echo "  -log                    Log collector mode" ;;
                help_log_on)       echo "    -on, --online         Real-time capture (tail -F + optional tcpdump)" ;;
                help_log_off)      echo "    -off, --offline       Copy existing logs" ;;
                help_log_t)        echo "    -t, --timeout DUR     Online: auto-stop after N (e.g. 5h, 30m)" ;;
                help_log_t2)       echo "                          Offline: extract lines from last N (by content timestamp). Without -t: all" ;;
                help_log_n)        echo "    -n, --no-tcpdump      Skip network capture (online only)" ;;
                help_log_j)        echo "    -j, --jobs N          Offline: parallel copy workers (default nproc*80%, max 32; no spawn if host CPU/RAM ≥80%)" ;;
                help_scope)        echo "    --scope brief|extended  Brief (services only) / extended (+ system/nginx/pg/configs)" ;;
                help_product)      echo "    -p, --product NAME    Product (repeatable; see --list-targets)" ;;
                help_service)      echo "    -s, --service PKG     Service/package (repeatable)" ;;
                help_list_targets) echo "    --list-targets        List available products/services and exit" ;;
                help_mgcp)         echo "    --mgcpclient          SoftSwitch: include mgcpclient (no prompt)" ;;
                help_no_mgcp)      echo "    --no-mgcpclient       SoftSwitch: skip mgcpclient" ;;
                help_from)         echo "    -f, --from TIME       Range start (e.g. -2h, 25.06.2026 10:00)" ;;
                help_to)           echo "    -e, --to TIME         Range end (e.g. -1h, 25.06.2026 12:00)" ;;
                help_range_note)   echo "    Range: -f -2h -e -1h | -f '25.06.2026 10:00' -e '25.06.2026 12:00' | -f '25.06.2026 10:00' -e +2h" ;;
                help_repo)         echo "  -r, --repo              Show repositories (APT/YUM sources)" ;;
                help_out)          echo "  -o, --output DIR        Write archive to DIR (log mode only)" ;;
                help_h)            echo "  -h, --help              Show this help" ;;
                help_dur)          echo "Duration suffixes: s=sec, m=min, h=hour, d=day. Bare number = seconds" ;;
                ask_lang)          echo "Select language / Выберите язык:" ;;
                ask_lang_ru)       echo "  1 — Русский" ;;
                ask_lang_en)       echo "  2 — English" ;;
                ask_lang_prompt)   echo "Your choice / Ваш выбор [1-2]: " ;;
                ask_log)           echo "Press [Enter] to collect online logs, or Ctrl+C to exit" ;;
                mode_log)          echo "Log mode" ;;
                mode_check)        echo "Check mode" ;;
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
                log_copied)        echo "Copied" ;;
                log_files_from)    echo "files from" ;;
                log_copydone)      echo "Copy done" ;;
                log_all)           echo "Copying all logs" ;;
                log_depth)         echo "Copying logs for last" ;;
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
                wiz_for_offset)    echo -n "For how long? (e.g. +3h, +30m): " ;;
                wiz_output_dir)    echo -n "Output dir (Enter = script dir): " ;;
                wiz_show_repo)     echo -n "Show repositories? (y/n): " ;;
                wiz_title_scope)   echo "=== Collection scope ===" ;;
                wiz_scope_1)       echo "  1 — Brief (selected product/service logs only)" ;;
                wiz_scope_2)       echo "  2 — Extended (+ system, nginx, PostgreSQL, configs; online: tcpdump)" ;;
                wiz_scope_prompt)  echo "Your choice [1-2]: " ;;
                wiz_title_products) echo "=== Products ===" ;;
                wiz_products_all)  echo "  a — All present on host" ;;
                wiz_products_prompt) echo -n "Numbers comma-separated or a: " ;;
                wiz_refine_services) echo -n "Refine services? (y/n, Enter=n): " ;;
                wiz_title_services) echo "=== Services ===" ;;
                wiz_services_all)  echo "  a — All services of selected products" ;;
                wiz_services_prompt) echo -n "Numbers comma-separated or a: " ;;
                wiz_no_targets)    echo "No known products/services found on this host" ;;
                wiz_preview_pkgs)  echo "Selected services" ;;
                wiz_preview_dirs)  echo "Log directories to collect" ;;
                ask_mgcpclient)    echo -n "SoftSwitch: collect mgcpclient logs? (y/n): " ;;
                mgcpclient_default_no) echo "SoftSwitch: skipping mgcpclient (no TTY; pass --mgcpclient or --no-mgcpclient)" ;;
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

# --- 3. OS / package manager ---------------------------------------------------
# Detect OS and package manager
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

    # Distro-specific version files for more precise release info
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
        # Update OS_NAME from release file if still unknown
        if [[ "$OS_NAME" == "Unknown" ]]; then
            OS_NAME=$(echo "$ver_content" | sed 's/ release.*//' | sed 's/ Linux//')
        fi
        # Extract version number
        local ver_num
        ver_num=$(echo "$ver_content" | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1)
        [[ -n "$ver_num" ]] && OS_FULL_VER="$OS_NAME $ver_num"
        # For Debian, /etc/debian_version has just the number
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

# Canonical distro id for OS-specific dispatch (get_sys_cpu_<id>, etc.).
# Same detection order as detect_os(): /etc/os-release first, then legacy
# release files for systems that don't ship os-release. Pure — no globals,
# no output, just echoes one of:
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

    # Normalize the couple of aliases os-release uses that don't match our
    # release-file naming above (Oracle Linux ID is "ol"; RHEL is "redhat"
    # on very old releases). Anything else is passed through as-is and
    # falls into the generic branch of the caller's dispatch.
    case "$id" in
        ol)     id="oracle" ;;
        redhat) id="rhel" ;;
        "")     id="unknown" ;;
    esac

    echo "$id"
}

# --- 3b. System metrics (host overview for dashboard / health JSON) ------------
# Always prints === System === block; missing data → n/a (never skip the section).

_sys_installed_pkgs() {
    local pkg
    for pkg in $(printf '%s\n' "${!PKG_PRODUCT[@]}" | sort); do
        if is_pkg_installed_tiny "$pkg" "${PKG_LEGACY[$pkg]:-}"; then
            echo "$pkg"
        fi
    done
}

# Sum %cpu or %mem for PIDs (ps field: pcpu|pmem). Prints float or empty.
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

# Escape a string for use inside a basic extended regex (pgrep -f)
_sys_regex_escape() {
    printf '%s' "$1" | sed 's/[][(){}.^$*+?|\\]/\\&/g'
}

# Candidate process/unit names for a package (canonical + legacy aliases)
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

# PIDs for a package name (exact + path-ish pgrep, systemd MainPID; legacy units too)
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

# --- 3b-1. Per-OS CPU load probes -------------------------------------------
# Each probe echoes an integer/decimal usage percentage on stdout and
# returns 0, or returns 1 with no stdout when it cannot get a reading.
# _sys_cpu() below only ever calls these through get_os_release() dispatch.

# /proc/stat is a kernel interface, identical on every Linux distro we
# support — this is the one non-OS-specific building block every probe
# below is allowed to share, exactly like they'd all share `uname -r`.
_sys_cpu_via_procstat() {
    declare -F _get_cpu_usage_percent >/dev/null 2>&1 || return 1
    _get_cpu_usage_percent >/dev/null   # prime the delta window
    sleep 0.25
    local pct
    pct=$(_get_cpu_usage_percent)
    [[ "$pct" =~ ^[0-9]+$ ]] || return 1
    echo "$pct"
}

# Debian family (Debian/Ubuntu/Astra all ship procps-ng >= 3.3.10):
# `top -bn1` prints "%Cpu(s):  3.2 us,  1.1 sy, ..., 95.3 id, ..."
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

get_sys_cpu_ubuntu() { get_sys_cpu_debian; }   # same procps-ng family as Debian
get_sys_cpu_astra()  { get_sys_cpu_debian; }   # Astra Linux is Debian-based

# RHEL family (RHEL/CentOS/Oracle/Rocky/AlmaLinux are the same userland):
# older procps prints "Cpu(s):  10.0%us,  2.0%sy, ..., 87.0%id, ..." — no
# leading '%' on the line and no space before each field's own '%'.
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

get_sys_cpu_centos()    { get_sys_cpu_rhel; }   # CentOS is a RHEL rebuild
get_sys_cpu_oracle()    { get_sys_cpu_rhel; }   # Oracle Linux is a RHEL rebuild
get_sys_cpu_rocky()     { get_sys_cpu_rhel; }   # Rocky Linux is a RHEL rebuild
get_sys_cpu_almalinux() { get_sys_cpu_rhel; }   # AlmaLinux is a RHEL rebuild

# Arch always tracks latest procps-ng — same output shape as Debian family.
get_sys_cpu_arch() { get_sys_cpu_debian; }

# Alpine is musl/busybox: `top -bn1` output is not stable enough to parse
# across busybox versions, and sysstat/mpstat isn't part of the base image.
# /proc/stat is still a kernel interface, so it alone is the whole probe —
# no format-guessing fallback here, on purpose.
get_sys_cpu_alpine() {
    _sys_cpu_via_procstat
}

# Unknown/unsupported distro: try everything we know, in order of reliability.
get_sys_cpu_generic() {
    _sys_cpu_via_procstat && return 0
    get_sys_cpu_debian && return 0
    get_sys_cpu_rhel
}

# --- 3b-2. CPU section (host overview) --------------------------------------
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
    # Prefer /proc/meminfo (stable columns); free -m as fallback
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
        # df -P: Filesystem 1024-blocks Used Available Capacity Mounted
        fs=$(echo "$line" | awk '{print $1}')
        size=$(echo "$line" | awk '{print $2}')
        used=$(echo "$line" | awk '{print $3}')
        avail=$(echo "$line" | awk '{print $4}')
        usep=$(echo "$line" | awk '{print $5}')
        mount=$(echo "$line" | awk '{print $6}')
        # human-readable via df -h for display
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

_sys_database() {
    local db="n/a" cluster="n/a" role="" lag="" n=""
    local euid
    euid="${EUID:-$(id -u)}"

    if command -v systemctl &>/dev/null; then
        if systemctl is-active --quiet postgresql 2>/dev/null \
            || systemctl is-active --quiet postgresql.service 2>/dev/null \
            || systemctl list-units --type=service --state=running 2>/dev/null | grep -qE 'postgresql(@|-)'; then
            db="postgresql active"
            if command -v psql &>/dev/null && [[ "$euid" -eq 0 || -n "${PGUSER:-}" || -n "${PGDATABASE:-}" ]]; then
                role=$(_sys_psql "SELECT CASE WHEN pg_is_in_recovery() THEN 'standby' ELSE 'primary' END")
                if [[ "$role" == "primary" || "$role" == "standby" ]]; then
                    db="postgresql active ($role)"
                    if [[ "$role" == "primary" ]]; then
                        n=$(_sys_psql "SELECT count(*) FROM pg_stat_replication")
                        if [[ "$n" =~ ^[0-9]+$ && "$n" -gt 0 ]]; then
                            lag=$(_sys_psql "SELECT COALESCE((EXTRACT(EPOCH FROM MAX(COALESCE(replay_lag, write_lag, flush_lag))))::int, 0) FROM pg_stat_replication")
                            if [[ -z "$lag" || ! "$lag" =~ ^[0-9]+$ ]]; then
                                lag=$(_sys_psql "SELECT COALESCE(EXTRACT(EPOCH FROM (now()-min(reply_time)))::int,0) FROM pg_stat_replication")
                            fi
                            [[ -z "$lag" || ! "$lag" =~ ^[0-9]+$ ]] && lag="0"
                            cluster="replication=ok lag=${lag}s replicas=$n"
                        else
                            cluster="replication=none replicas=0"
                        fi
                    else
                        # Standby: lag vs primary from local replay timestamp
                        lag=$(_sys_psql "SELECT COALESCE(EXTRACT(EPOCH FROM (now()-pg_last_xact_replay_timestamp()))::int, 0)")
                        [[ -z "$lag" || ! "$lag" =~ ^[0-9]+$ ]] && lag="n/a"
                        if [[ "$lag" == "n/a" ]]; then
                            cluster="replication=standby lag=n/a"
                        else
                            cluster="replication=standby lag=${lag}s"
                        fi
                    fi
                else
                    cluster="n/a"
                fi
            else
                cluster="n/a"
            fi
        elif systemctl is-active --quiet mariadb 2>/dev/null || systemctl is-active --quiet mysql 2>/dev/null; then
            db="mariadb/mysql active"
            cluster="n/a"
        fi
    fi

    # Fallback: package present but systemd unknown
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
        # Skip CA bundle dumps and huge hashed dir noise: only leaf-looking names
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
                # only explicitly named certs, not hash symlinks
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
    # Parallel host probes while cpu/memory take their samples (sleep)
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
    # Stable dashboard order; reclaim WARN counts lost in subshells
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

# Get package real dependencies from PM
get_pkg_depends() {
    local pkg="$1"
    local deps=""

    if [[ "$PM" == "dpkg" ]]; then
        if ! dpkg-query -W -f='${Status}\n' "$pkg" 2>/dev/null | grep -q 'install ok installed'; then
            return
        fi
        deps=$(dpkg -s "$pkg" 2>/dev/null | grep "^Depends:" | sed 's/^Depends: //')
        if [[ -z "$deps" ]]; then
            deps=$(apt-cache depends "$pkg" 2>/dev/null | grep -E "^\s+Depends:" | sed 's/.*Depends: //' | tr '\n' ', ' | sed 's/, $//')
        fi
    elif [[ "$PM" == "rpm" ]]; then
        if ! rpm -q "$pkg" &>/dev/null; then
            return
        fi
        deps=$(rpm -qR "$pkg" 2>/dev/null | grep -v "^rpmlib(" | grep -v "^/" | grep -v "^config" | grep -v "^config(" | grep -vi "^package" | grep -vi "^пакет" | sed 's/ .*$//' | sort -u | tr '\n' ', ' | sed 's/, $//')
    fi

    # Clean: remove version constraints, alternatives, keep only package names
    echo "$deps" | tr ',' '\n' | sed 's/|.*$//' | sed 's/([^)]*)//g' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | grep -v '^$' | grep -v '^[0-9]' | grep -v '^(' | grep -v '^)' | grep -v '^<' | grep -v '^>' | grep -v '^=' | sort -u | tr '\n' ',' | sed 's/^,//;s/,$//'
}

# Get package version from PM
get_pkg_version() {
    local pkg="$1"
    local ver=""

    if [[ "$PM" == "dpkg" ]]; then
        ver=$(dpkg-query -W -f='${Version}' "$pkg" 2>/dev/null)
    elif [[ "$PM" == "rpm" ]]; then
        ver=$(rpm -q --queryformat '%{VERSION}-%{RELEASE}' "$pkg" 2>/dev/null)
    elif [[ "$PM" == "pacman" ]]; then
        ver=$(pacman -Q "$pkg" 2>/dev/null | awk '{print $2}')
    fi

    echo "$ver"
}

# Check if a dependency is installed
is_dep_installed() {
    local dep="$1"
    if [[ "$PM" == "dpkg" ]]; then
        dpkg-query -W -f='${Status}\n' "$dep" 2>/dev/null | grep -q 'install ok installed'
    elif [[ "$PM" == "rpm" ]]; then
        rpm -q "$dep" &>/dev/null
    elif [[ "$PM" == "pacman" ]]; then
        pacman -Q "$dep" &>/dev/null
    else
        return 1
    fi
}

# Get dependency version
get_dep_version() {
    local dep="$1"
    local ver=""

    if [[ "$PM" == "dpkg" ]]; then
        ver=$(dpkg-query -W -f='${Version}' "$dep" 2>/dev/null)
    elif [[ "$PM" == "rpm" ]]; then
        ver=$(rpm -q --queryformat '%{VERSION}-%{RELEASE}' "$dep" 2>/dev/null)
    elif [[ "$PM" == "pacman" ]]; then
        ver=$(pacman -Q "$dep" 2>/dev/null | awk '{print $2}')
    fi

    echo "$ver"
}

# Check service status for a dependency (returns description string)
check_dep_service() {
    local dep="$1"
    local svc=""
    local result=""

    # Map common package names to service names
    case "$dep" in
        nginx) svc="nginx" ;;
        redis|redis-server) svc="redis-server" ;;
        mariadb|mysql-server|mariadb-server) svc="mariadb" ;;
        postgresql|postgresql-*) svc="postgresql" ;;
        rabbitmq-server|rabbitmq) svc="rabbitmq-server" ;;
        sudo) return 0 ;;  # sudo has no service
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

# Collect dependency into global ALL_DEPENDS array (dep -> "pkg1,pkg2")
register_dep() {
    local dep="$1"
    local pkg="$2"
    dep=$(echo "$dep" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    [[ -z "$dep" ]] && return

    # Skip non-package dependencies (files, paths, versioned strings, self, config, RPM capabilities)
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

# --- Per-PM package presence probes -----------------------------------------
# One self-contained function per package manager: main name, then each
# comma-separated legacy name, using only that PM's own query tool — no
# other PM's commands appear inside. Each sets FOUND_PKG_VER/FOUND_PKG_STATUS,
# prints the matching ok/warn/fail line and returns:
#   0 = installed  1 = installed but not fully configured (dpkg only)
#   2 = legacy name found instead  3 = not found at all
# check_pkg_installed() below only ever calls these through a $PM dispatch.

# Debian family: dpkg-query gives version + full install status in one call.
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

# RHEL family: rpm -q only confirms presence, version comes from a second query.
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

# Arch: pacman -Q prints "name version" on one line for an installed package.
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

# Alpine: apk info -e only confirms presence, no separate version query used here.
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

# Check if package is installed using PM (verbose, prints status)
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

# --- Per-PM silent presence checks ------------------------------------------
# One self-contained function per package manager for the silent (no output)
# fast path: main name, then each comma-separated legacy name, using only
# that PM's own query tool. Returns 0 if found, 1 otherwise.
# is_pkg_installed_tiny() below tries the matching one via $PM, then always
# falls back to has_any_trace() regardless of PM/result.

# Debian family: dpkg-query's Status field alone is enough, no version needed.
is_pkg_installed_tiny_dpkg() {
    local pkg="$1" legacy="$2" old

    dpkg-query -W -f='${Status}\n' "$pkg" 2>/dev/null | grep -q 'install ok installed' && return 0
    for old in $(echo "$legacy" | tr ',' ' '); do
        dpkg-query -W -f='${Status}\n' "$old" 2>/dev/null | grep -q 'install ok installed' && return 0
    done
    return 1
}

# RHEL family: rpm -q's exit code alone is enough for a presence check.
is_pkg_installed_tiny_rpm() {
    local pkg="$1" legacy="$2" old

    rpm -q "$pkg" &>/dev/null && return 0
    for old in $(echo "$legacy" | tr ',' ' '); do
        rpm -q "$old" &>/dev/null && return 0
    done
    return 1
}

# Arch: pacman -Q's exit code alone is enough for a presence check.
is_pkg_installed_tiny_pacman() {
    local pkg="$1" legacy="$2" old

    pacman -Q "$pkg" &>/dev/null && return 0
    for old in $(echo "$legacy" | tr ',' ' '); do
        pacman -Q "$old" &>/dev/null && return 0
    done
    return 1
}

# Alpine: apk info -e's exit code alone is enough; no legacy loop here in
# the original monolith either — apk-family FLAT packages have none.
is_pkg_installed_tiny_apk() {
    local pkg="$1"
    apk info -e "$pkg" &>/dev/null && return 0
    return 1
}

# Silent quick check if package is installed (returns 0/1, no output)
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

    # Check traces (unit file or /opt/flat dir)
    has_any_trace "$pkg" && return 0
    return 1
}

# Check systemd unit
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

# Try to find log path from known config files for a package
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

# Check log directory with freshness and config fallback
check_log_directory() {
    local pkg="$1"
    local log_dir="/var/log/flat/${pkg}"
    local found_log_dir=""
    local log_status=""

    # Check if it's a symlink
    if [[ -L "$log_dir" ]]; then
        local target
        target=$(readlink -f "$log_dir" 2>/dev/null || readlink "$log_dir" 2>/dev/null)
        print_info "logdir: $log_dir is symlink -> $target"
        # Use target for further checks
        log_dir="$target"
    fi

    # Check default path
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

    # Problem with default path — check if process is active
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

    # Process is active and we have a problem — try to find log path from config
    # Only needed for empty/missing; for stale the default path exists but is old.
    # For stale: only fallback if we know a config for this pkg (skip if unknown).
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

# Check opt directory and permissions
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

# Check configuration files
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

# Check process by name or pattern
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

# Check network ports
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

# Check API health
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

# --- 4. Per-package health checks ----------------------------------------------
# Register PKG_DEPS + PM depends into ALL_DEPENDS (first pass before parallel checks)
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

# Single package check (respects VERBOSE)
check_single_pkg() {
    local pkg="$1"
    local legacy="${PKG_LEGACY[$pkg]:-}"

    # Quick silent check for not installed packages
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

    # Package is installed (or has traces) — print full details
    check_pkg_installed "$pkg" "$legacy"
    local rc=$?

    if [[ $rc -eq 3 && -z "$FOUND_PKG_VER" ]]; then
        if has_any_trace "$pkg"; then
            print_warn "pkg: $pkg not found in PM, but traces exist on disk"
        fi
        return 1
    fi

    # Print version separately
    if [[ -n "$FOUND_PKG_VER" ]]; then
        print_info "version: ${FOUND_PKG_VER}"
    fi

    # Print and collect dependencies (registration usually done in first pass)
    local deps_meta="${PKG_DEPS[$pkg]:-}"
    local deps_real=""
    if [[ -n "$deps_meta" ]]; then
        print_info "depends: ${deps_meta}"
        for dep in $(echo "$deps_meta" | tr ',' ' '); do
            register_dep "$dep" "$pkg"
        done
    fi

    # Try to get real dependencies from package manager
    deps_real=$(get_pkg_depends "$pkg" 2>/dev/null)
    if [[ -n "$deps_real" ]]; then
        # Show real depends only if different from meta
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

# Run checks for a single product (parallel pkgs, buffered ordered output)
run_product_checks() {
    local product="$1"
    local installed_count=0
    local total_count=0
    local product_pkgs=()
    local pkg legacy max_jobs tmpdir job_idx=0 w e

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

    # Sort package names for stable job_idx ↔ print mapping
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
            check_single_pkg "$pkg"
        ) > "$tmpdir/$job_idx" 2>&1 &
        COLLECTOR_JOB_PIDS+=($!)
    done
    _collector_wait_all_jobs

    # Print in package order; reclaim counters lost in subshells (Summary / Zabbix)
    job_idx=0
    for pkg in "${product_pkgs[@]}"; do
        job_idx=$((job_idx + 1))
        [[ -f "$tmpdir/$job_idx" ]] || continue
        cat "$tmpdir/$job_idx"
        w=$(grep -c '\[WARN\]' "$tmpdir/$job_idx" 2>/dev/null || true)
        e=$(grep -c '\[FAIL\]' "$tmpdir/$job_idx" 2>/dev/null || true)
        [[ "$w" =~ ^[0-9]+$ ]] && WARNINGS=$((WARNINGS + w))
        [[ "$e" =~ ^[0-9]+$ ]] && ERRORS=$((ERRORS + e))
        if grep -qE '\[OK\].*pkg:.*installed' "$tmpdir/$job_idx" 2>/dev/null \
            || grep -qE '\[WARN\].*pkg:.*legacy' "$tmpdir/$job_idx" 2>/dev/null; then
            ((INSTALLED++))
        elif grep -q '— not installed' "$tmpdir/$job_idx" 2>/dev/null; then
            ((NOT_INSTALLED++))
        fi
    done
    rm -rf -- "$tmpdir" 2>/dev/null
}

# Check if a shared library file exists in standard lib paths
is_lib_available() {
    local lib="$1"
    for path in /usr/lib64 /lib64 /usr/lib /lib; do
        [[ -f "$path/$lib" ]] && return 0
    done
    return 1
}

# --- 5. Infrastructure + repositories ------------------------------------------
# Check all collected dependencies (Infrastructure)
check_infrastructure() {
    echo ""
    echo "=== Infrastructure ==="

    local has_any=0
    local dep_list=()

    # Sort unique dependencies
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

        # Shared libraries: check file existence in lib paths (RHEL/ReOS 7.3 uses /usr/lib64/)
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
                        local svc
                        for svc in mariadb mysql; do
                            if systemctl list-unit-files --type=service 2>/dev/null | grep -q "^${svc}.service"; then
                                local active
                                active=$(systemctl is-active "${svc}.service" 2>/dev/null)
                                if [[ "$active" == "active" ]]; then
                                    print_ok "mariadb: $svc active"
                                else
                                    print_warn "mariadb: $svc $active"
                                fi
                                break
                            fi
                        done
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
                        local svc
                        for svc in postgresql postgresql-12 postgresql-13 postgresql-14 postgresql-15 postgresql-16; do
                            if systemctl list-unit-files --type=service 2>/dev/null | grep -q "^${svc}.service"; then
                                local active
                                active=$(systemctl is-active "${svc}.service" 2>/dev/null)
                                if [[ "$active" == "active" ]]; then
                                    print_ok "postgresql: $svc active"
                                else
                                    print_warn "postgresql: $svc $active"
                                fi
                                break
                            fi
                        done
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
                        local active
                        for svc in redis-server redis; do
                            if systemctl list-unit-files --type=service 2>/dev/null | grep -q "^${svc}.service"; then
                                active=$(systemctl is-active "${svc}.service" 2>/dev/null)
                                if [[ "$active" == "active" ]]; then
                                    print_ok "redis: $svc active"
                                else
                                    print_warn "redis: $svc $active"
                                fi
                                break
                            fi
                        done
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

# Check repositories

# --- Per-PM repository listing ----------------------------------------------
# One self-contained function per package manager — each reads that PM's own
# repo config files/tools only. check_repositories() below just prints the
# section header and dispatches on $PM.

# Debian family: sources.list(.d) entries, then apt-cache policy priorities.
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

# RHEL family: `yum repolist` output, then raw *.repo files under yum.repos.d.
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

# Print configured package repositories for the detected PM (dpkg/rpm only —
# pacman/apk repo listing was never implemented, same as before this split).
check_repositories() {
    echo ""
    echo "=== Repositories ==="

    case "$PM" in
        dpkg) check_repositories_dpkg ;;
        rpm)  check_repositories_rpm ;;
    esac
}

# Summary
print_summary() {
    echo ""
    echo "=== Summary ==="
    print_info "Installed: $INSTALLED | Errors: $ERRORS | Warnings: $WARNINGS"
}

# --- 6. Log directory discovery ------------------------------------------------
# Allowlisted paths only: PKG_PRODUCT (+ PKG_LEGACY) via find_log_dirs_for_pkg.
# Unknown dirs under /var/log/flat (e.g. logforflat) are skipped.

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
    # Expand leading ~ only (avoid eval on config-controlled paths)
    [[ "$path" == "~" ]] && path="$HOME"
    [[ "$path" == "~/"* ]] && path="$HOME/${path:2}"
    if [[ -d "$path" ]]; then
        echo "$path"
    elif [[ -f "$path" ]]; then
        dirname "$path"
    fi
}

_parse_log_path_from_config_file() {
    local conf="$1"
    local path=""
    [[ -f "$conf" ]] || return 1

    case "$conf" in
        *switchserver*|*fss-server*)
            path=$(grep -s '^LogPath=' "$conf" | head -1 | cut -d '=' -f 2- | tr -d '[:space:]')
            ;;
        *srclient*|*fss-srclient*)
            path=$(grep -s '^logger_fileName' "$conf" | head -1 | sed -E 's/.*=\s*"([^"]*)".*/\1/')
            [[ -z "$path" ]] && path=$(grep -s '^logger_fileName' "$conf" | head -1 | cut -d '"' -f 2)
            ;;
        *mediasrv*|*fss-mediasrv*)
            path=$(grep -s '<LogParams>' "$conf" | head -1 | sed -E 's/.*>([^<]*)<.*/\1/')
            ;;
        *flat-file*)
            path=$(grep -s '^\s*dir\s*:' "$conf" | head -1 | cut -d ':' -f 2- | xargs)
            ;;
        *)
            path=$(grep -siE '^(LogPath|log_path|logPath|logger_fileName|log_dir)\s*=' "$conf" 2>/dev/null | head -1 | sed -E 's/^[^=]+=\s*"?([^"]*)"?/\1/' | tr -d '[:space:]')
            [[ -z "$path" ]] && path=$(grep -s '<LogParams>' "$conf" 2>/dev/null | head -1 | sed -E 's/.*>([^<]*)<.*/\1/')
            ;;
    esac
    _log_path_to_dir "$path"
}

# Normalize product/service name for fuzzy match: lower, strip spaces/_/-
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
    # $1 = nameref-like array name via eval; simpler: use global SELECTED_PKGS
    local pkg="$1" e
    for e in "${SELECTED_PKGS[@]+"${SELECTED_PKGS[@]}"}"; do
        [[ "$e" == "$pkg" ]] && return 1
    done
    SELECTED_PKGS+=("$pkg")
    return 0
}

# True if canonical product name matches user input (exact or normalized)
_product_name_matches() {
    local want="$1" have="$2"
    [[ -z "$want" || -z "$have" ]] && return 1
    [[ "$want" == "$have" ]] && return 0
    [[ "$(_norm_target_name "$want")" == "$(_norm_target_name "$have")" ]] && return 0
    return 1
}

# Resolve user product string to canonical PKG_PRODUCT value (or empty)
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

# Resolve service/pkg string to a PKG_PRODUCT key
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

# Fill SELECTED_PKGS from SELECTED_PRODUCTS / SELECTED_SERVICES (or all present pkgs)
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

# True if current selection includes SoftSwitch (product or any SoftSwitch package)
_selection_includes_softswitch() {
    local pkg want
    for pkg in "${SELECTED_PKGS[@]+"${SELECTED_PKGS[@]}"}"; do
        [[ "${PKG_PRODUCT[$pkg]:-}" == "SoftSwitch" ]] && return 0
    done
    for want in "${SELECTED_PRODUCTS[@]+"${SELECTED_PRODUCTS[@]}"}"; do
        _product_name_matches "$want" "SoftSwitch" && return 0
    done
    for want in "${SELECTED_SERVICES[@]+"${SELECTED_SERVICES[@]}"}"; do
        pkg=$(_resolve_service_canonical "$want" 2>/dev/null) || continue
        [[ "${PKG_PRODUCT[$pkg]:-}" == "SoftSwitch" ]] && return 0
    done
    return 1
}

# Discover mgcpclient log dirs (not in PKG_PRODUCT allowlist)
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

# Ask / apply SoftSwitch → mgcpclient inclusion; fills EXTRA_LOG_DIRS when yes
# quiet=1: refill EXTRA_LOG_DIRS only, no prompt/spam (INCLUDE already decided)
_resolve_mgcpclient_option() {
    local quiet="${1:-0}"
    EXTRA_LOG_DIRS=()
    _selection_includes_softswitch || return 0

    if [[ -z "${INCLUDE_MGCPCLIENT}" ]]; then
        if [[ "$quiet" -eq 1 ]]; then
            # Second pass without a prior decision — skip silently
            INCLUDE_MGCPCLIENT=0
        elif [[ -t 0 ]]; then
            echo ""
            echo -n "$(_l ask_mgcpclient)"
            local ans=""
            read -r ans 2>/dev/null || true
            if [[ "$ans" == "y" || "$ans" == "Y" || "$ans" == "д" || "$ans" == "Д" || "$ans" == "yes" || "$ans" == "да" ]]; then
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

# Print products/services available on this host
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

# Report unknown dirs under /var/log/flat (junk like logforflat) — once per run
_report_skipped_unknown_flat_dirs() {
    local d base
    [[ "${SKIP_UNKNOWN_FLAT_REPORTED:-0}" -eq 1 ]] && return 0
    SKIP_UNKNOWN_FLAT_REPORTED=1
    [[ -d "/var/log/flat" ]] || return 0
    for d in /var/log/flat/*/; do
        [[ -d "$d" ]] || continue
        base=$(basename "$d")
        # mgcpclient is optional SoftSwitch extra — not "unknown junk"
        [[ "$base" == "mgcpclient" ]] && continue
        if ! _is_known_log_basename "$base"; then
            info "skip unknown: $base"
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

# Build DISCOVERED_LOG_DIRS from SELECTED_PKGS (allowlist only) + EXTRA_LOG_DIRS
discover_log_dirs_for_selected() {
    DISCOVERED_LOG_DIRS=()
    local pkg d
    local result=()

    _report_skipped_unknown_flat_dirs

    for pkg in "${SELECTED_PKGS[@]+"${SELECTED_PKGS[@]}"}"; do
        while IFS= read -r d; do
            [[ -n "$d" ]] && _log_dir_add_unique "$d"
        done < <(find_log_dirs_for_pkg "$pkg")
    done

    for d in "${EXTRA_LOG_DIRS[@]+"${EXTRA_LOG_DIRS[@]}"}"; do
        [[ -n "$d" && -d "$d" ]] && _log_dir_add_unique "$d"
    done

    for d in "${DISCOVERED_LOG_DIRS[@]+"${DISCOVERED_LOG_DIRS[@]}"}"; do
        # Include dirs that have any log-like files (incl. .gz). Online skips .gz at tail time.
        _dir_has_any_log_files "$d" && result+=("$d")
    done
    DISCOVERED_LOG_DIRS=("${result[@]+"${result[@]}"}")
    printf '%s\n' "${DISCOVERED_LOG_DIRS[@]+"${DISCOVERED_LOG_DIRS[@]}"}"
}

# Resolve selection (CLI/wizard filters or all present pkgs) → dirs
discover_all_log_dirs() {
    resolve_selected_packages
    discover_log_dirs_for_selected
}

is_log_like_file() {
    local f="$1"
    [[ -f "$f" ]] || return 1
    case "$f" in
        *.log|*.txt|*.log.*|*.out) return 0 ;;
        *.gz)
            case "$f" in
                *.log.gz|*.txt.gz) return 0 ;;
            esac
            return 1
            ;;
        *)
            [[ "$(basename "$f")" == "messages" || "$(basename "$f")" == "syslog" ]] && return 0
            return 1
            ;;
    esac
}

# True if basename looks like SoftSwitch mgcpclient dump (mgcpclient_2.txt, …)
_is_mgcpclient_log_file() {
    local base
    base=$(basename "$1")
    [[ "$base" == mgcpclient || "$base" == mgcpclient.* || "$base" == mgcpclient_* ]]
}

# find_log_files_in_dir respects INCLUDE_MGCPCLIENT: when not 1, skip mgcpclient* files
# Online: also skip *.gz (tail -F cannot follow gzip content)
find_log_files_in_dir() {
    local src_dir="$1" f
    [[ -d "$src_dir" ]] || return 0
    while IFS= read -r -d '' f; do
        if [[ "${INCLUDE_MGCPCLIENT:-0}" != "1" ]] && _is_mgcpclient_log_file "$f"; then
            continue
        fi
        if [[ "${LOG_SUBMODE:-}" == "online" && "$f" == *.gz ]]; then
            continue
        fi
        printf '%s\0' "$f"
    done < <(find -L "$src_dir" -maxdepth 2 -type f \( \
        -name '*.log' -o -name '*.txt' -o -name '*.log.*' -o -name '*.log.gz' -o -name '*.txt.gz' \
    \) -print0 2>/dev/null)
}

# True if dir has any collectable log-like file (including .gz) — for discovery
_dir_has_any_log_files() {
    local d="$1" f
    [[ -d "$d" ]] || return 1
    while IFS= read -r -d '' f; do
        if [[ "${INCLUDE_MGCPCLIENT:-0}" != "1" ]] && _is_mgcpclient_log_file "$f"; then
            continue
        fi
        return 0
    done < <(find -L "$d" -maxdepth 2 -type f \( \
        -name '*.log' -o -name '*.txt' -o -name '*.log.*' -o -name '*.log.gz' -o -name '*.txt.gz' \
    \) -print0 2>/dev/null)
    return 1
}

# True if dir has files collectable in current mode (online: no .gz)
has_log_files() {
    local d="$1"
    [[ -d "$d" ]] || return 1
    [[ -n "$(find_log_files_in_dir "$d" | head -c 1)" ]]
}

# --- 7. PostgreSQL log discovery -----------------------------------------------
find_pg_log_files_in_dir() {
    local src_dir="$1" f
    [[ -d "$src_dir" ]] || return 0
    while IFS= read -r -d '' f; do
        if [[ "${LOG_SUBMODE:-}" == "online" && "$f" == *.gz ]]; then
            continue
        fi
        printf '%s\0' "$f"
    done < <(find -L "$src_dir" -maxdepth 2 -type f \( \
        -name '*.log' -o -name '*.csv' -o -name '*.txt' \
        -o -name '*.log.*' -o -name '*.log.gz' -o -name '*.csv.gz' \
        -o -name 'postgresql-*' \
    \) -print0 2>/dev/null)
}

has_pg_log_files() {
    local d="$1"
    [[ -d "$d" ]] || return 1
    [[ -n "$(find_pg_log_files_in_dir "$d" | head -c 1)" ]]
}

_pg_conf_get_value() {
    local key="$1" conf="$2" line val
    line=$(grep -E "^[[:space:]]*${key}[[:space:]]*=" "$conf" 2>/dev/null | grep -v '^[[:space:]]*#' | head -1)
    [[ -z "$line" ]] && return 1
    val=$(echo "$line" | sed -E "s/^[[:space:]]*${key}[[:space:]]*=[[:space:]]*'([^']*)'.*/\1/")
    if [[ "$val" == "$line" ]]; then
        val=$(echo "$line" | sed -E 's/^[^=]+=[[:space:]]*"?([^"#]*)"?.*$/\1/')
    fi
    val=$(echo "$val" | sed 's/[[:space:]]*$//')
    [[ -n "$val" ]] && echo "$val"
}

_pg_resolve_log_dir_from_conf() {
    local conf="$1"
    local data_dir log_dir
    [[ -f "$conf" ]] || return 1
    data_dir=$(_pg_conf_get_value "data_directory" "$conf")
    [[ -z "$data_dir" ]] && return 1
    log_dir=$(_pg_conf_get_value "log_directory" "$conf")
    [[ -z "$log_dir" ]] && log_dir="log"
    if [[ "$log_dir" != /* ]]; then
        echo "${data_dir%/}/${log_dir}"
    else
        echo "$log_dir"
    fi
}

_pg_log_source_add() {
    local path="$1" label="$2" conf="${3:-}"
    local entry existing_path normalized
    [[ -z "$path" ]] && return 1
    normalized=$(readlink -f "$path" 2>/dev/null || echo "$path")
    for entry in "${PG_LOG_SOURCES[@]}"; do
        existing_path="${entry%%|*}"
        [[ "$existing_path" == "$normalized" ]] && return 1
    done
    PG_LOG_SOURCES+=("${normalized}|${label}|${conf}")
}

_discover_pg_from_systemd_service() {
    local svc="$1"
    local exec_start data_dir conf log_dir sub
    [[ -z "$svc" ]] && return 1
    exec_start=$(systemctl show "$svc" -p ExecStart --value 2>/dev/null)
    [[ -z "$exec_start" ]] && return 1

    data_dir=$(echo "$exec_start" | sed -n 's/.*-D[[:space:]]\+\([^[:space:]]\+\).*/\1/p')
    conf=$(echo "$exec_start" | sed -n 's/.*config_file=\([^[:space:]]\+\).*/\1/p')

    if [[ -n "$conf" && -f "$conf" ]]; then
        log_dir=$(_pg_resolve_log_dir_from_conf "$conf")
        if [[ -n "$log_dir" ]]; then
            _pg_log_source_add "$log_dir" "$svc" "$conf"
            return 0
        fi
    fi

    if [[ -n "$data_dir" ]]; then
        for sub in log pg_log; do
            _pg_log_source_add "${data_dir%/}/${sub}" "$svc" "${conf:-}"
        done
    fi
}

discover_postgresql_log_sources() {
    local conf svc log_dir pg_dir
    PG_LOG_SOURCES=()

    for conf in /etc/postgresql/*/main/postgresql.conf /var/lib/pgsql/*/data/postgresql.conf; do
        [[ -f "$conf" ]] || continue
        log_dir=$(_pg_resolve_log_dir_from_conf "$conf")
        [[ -n "$log_dir" ]] && _pg_log_source_add "$log_dir" "${conf%/postgresql.conf}" "$conf"
    done

    if command -v systemctl &>/dev/null; then
        while read -r svc; do
            [[ -z "$svc" ]] && continue
            _discover_pg_from_systemd_service "$svc"
        done < <(systemctl list-unit-files --type=service --no-pager 2>/dev/null | awk '{print $1}' | grep -E '^postgresql' || true)
    fi

    for pg_dir in /var/lib/postgresql/*/main/pg_log /var/lib/postgresql/*/main/log; do
        [[ -d "$pg_dir" ]] && _pg_log_source_add "$pg_dir" "discovered:$(dirname "$pg_dir")" ""
    done
    [[ -d /var/log/postgresql ]] && _pg_log_source_add "/var/log/postgresql" "discovered:/var/log/postgresql" ""
}

is_postgresql_present() {
    command -v psql &>/dev/null && return 0
    command -v systemctl &>/dev/null && systemctl list-unit-files --type=service --no-pager 2>/dev/null | grep -qE '^postgresql'
}

check_postgresql_log_access() {
    local dir="$1"
    [[ -e "$dir" ]] || return 1
    [[ -d "$dir" ]] || return 2
    ls "$dir" &>/dev/null || return 3
    return 0
}

_logs_time_context() {
    local mode="${1:-offline}"
    local from_time="${2:-}"
    local to_time="${3:-}"
    if [[ "$mode" == "online" ]]; then
        echo "collection"
    elif [[ -n "$from_time" || -n "$to_time" ]]; then
        echo "period"
    else
        echo "plain"
    fi
}

_log_absent_reason() {
    local ctx="$1"
    case "$ctx" in
        period)     _l logs_absent_for_period ;;
        collection) _l logs_absent_for_collection ;;
        *)          _l logs_absent ;;
    esac
}

_join_comma_list() {
    local result="" item
    for item in "$@"; do
        [[ -n "$result" ]] && result+=", "
        result+="$item"
    done
    echo "$result"
}

_format_absent_files_hint() {
    local max_show=4
    local -A seen=()
    local -a unique=() f shown=0 extra summary=""
    for f in "$@"; do
        [[ -n "${seen[$f]+x}" ]] && continue
        seen[$f]=1
        unique+=("$f")
    done
    local total=${#unique[@]}
    [[ "$total" -eq 0 ]] && return 0
    if [[ "$total" -le 5 ]]; then
        _join_comma_list "${unique[@]}"
        return 0
    fi
    for f in "${unique[@]}"; do
        [[ $shown -ge $max_show ]] && break
        [[ -n "$summary" ]] && summary+=", "
        summary+="$f"
        ((shown++)) || true
    done
    extra=$(( total - shown ))
    echo "${total} $(_l absent_files_unit): ${summary} (+${extra} $(_l more_files))"
}

_log_absent_info() {
    local label="$1" ctx="$2"
    shift 2
    local hint
    hint=$(_format_absent_files_hint "$@")
    if [[ -n "$hint" ]]; then
        info "${label}: $(_log_absent_reason "$ctx") (${hint})"
    else
        info "${label}: $(_log_absent_reason "$ctx")"
    fi
}

_collector_should_stop() {
    [[ "${COLLECTOR_ABORTED:-0}" -eq 1 || "${COLLECTOR_TIMEOUT_STOP:-0}" -eq 1 ]]
}

# Wait until user stops online collection (Enter) or TERM (timeout / disk guard).
# Caller must ensure non-TTY online has timeout_sec > 0 before starting tails.
_online_wait_for_stop() {
    if [[ -t 0 ]]; then
        while [[ "${COLLECTOR_TIMEOUT_STOP:-0}" -eq 0 && "${COLLECTOR_ABORTED:-0}" -eq 0 ]]; do
            if read -r -t 1 _ 2>/dev/null; then
                break
            fi
        done
    else
        while [[ "${COLLECTOR_TIMEOUT_STOP:-0}" -eq 0 && "${COLLECTOR_ABORTED:-0}" -eq 0 ]]; do
            sleep 1
        done
    fi
}

collect_postgresql_logs() {
    local work_dir="$1" mode="$2"
    local from_time="${3:-}" to_time="${4:-}"
    local entry path label conf status dest safe_label

    discover_postgresql_log_sources

    if [[ ${#PG_LOG_SOURCES[@]} -eq 0 ]]; then
        is_postgresql_present && info "postgresql: $(_l pg_logs_not_found)"
        return 0
    fi

    for entry in "${PG_LOG_SOURCES[@]}"; do
        IFS='|' read -r path label conf <<< "$entry"
        status=0
        check_postgresql_log_access "$path" || status=$?

        case "$status" in
            1) info "postgresql ($label): $(_l pg_logs_dir_missing) $path"; continue ;;
            2) warn "postgresql ($label): $(_l pg_logs_not_dir) $path"; continue ;;
            3)
                if [[ "${EUID:-$(id -u 2>/dev/null)}" -ne 0 ]]; then
                    warn "postgresql ($label): $(_l pg_logs_no_access) $path — $(_l pg_logs_try_sudo)"
                else
                    warn "postgresql ($label): $(_l pg_logs_no_access) $path"
                fi
                continue
                ;;
        esac

        if ! has_pg_log_files "$path"; then
            local ctx pg_label
            ctx=$(_logs_time_context "$mode" "$from_time" "$to_time")
            pg_label="postgresql ($(basename "$path"))"
            info "${pg_label}: $(_log_absent_reason "$ctx")"
            continue
        fi

        safe_label=$(echo "$label" | sed 's|^/||; s|/|_|g; s|@|_|g')
        [[ -z "$safe_label" ]] && safe_label=$(basename "$path")
        dest="$work_dir/postgresql/${safe_label}"
        local pg_display="postgresql ($(basename "$path"))"

        if [[ "$mode" == "online" ]]; then
            start_tail_for_dir "$path" "$dest" "pg" "$pg_display"
        else
            copy_existing_logs "$path" "$dest" "$from_time" "$to_time" "pg" "$pg_display"
        fi
    done
}

time_to_epoch() {
    date -d "$1" "+%s" 2>/dev/null
}

# Shared awk body: parse timestamp → epoch (YYYY-MM-DD / DD.MM.YYYY)
_AWK_LINE_EPOCH='
function line_epoch(line, ts, n, p) {
    if (match(line, /[0-9]{4}-[0-9]{2}-[0-9]{2}[ T][0-9]{2}:[0-9]{2}:[0-9]{2}/)) {
        ts = substr(line, RSTART, RLENGTH)
        gsub(/[-T:]/, " ", ts)
        n = split(ts, p, " ")
        if (n >= 6) return mktime(p[1] " " p[2] " " p[3] " " p[4] " " p[5] " " p[6])
    }
    if (match(line, /[0-9]{2}\.[0-9]{2}\.[0-9]{4}[ T][0-9]{2}:[0-9]{2}:[0-9]{2}/)) {
        ts = substr(line, RSTART, RLENGTH)
        gsub(/[T]/, " ", ts)
        n = split(ts, p, /[. :]/)
        if (n >= 6) return mktime(p[3] " " p[2] " " p[1] " " p[4] " " p[5] " " p[6])
    }
    if (match(line, /[0-9]{2}\.[0-9]{2}\.[0-9]{4}[ T][0-9]{2}:[0-9]{2}/)) {
        ts = substr(line, RSTART, RLENGTH)
        gsub(/[T]/, " ", ts)
        n = split(ts, p, /[. :]/)
        if (n >= 5) return mktime(p[3] " " p[2] " " p[1] " " p[4] " " p[5] " 0")
    }
    if (match(line, /[0-9]{4}-[0-9]{2}-[0-9]{2}[ T][0-9]{2}:[0-9]{2}/)) {
        ts = substr(line, RSTART, RLENGTH)
        gsub(/[-T:]/, " ", ts)
        n = split(ts, p, " ")
        if (n >= 5) return mktime(p[1] " " p[2] " " p[3] " " p[4] " " p[5] " 0")
    }
    return -1
}
'

_file_size_bytes() {
    local s
    s=$(stat -c '%s' "$1" 2>/dev/null) && { echo "$s"; return 0; }
    s=$(wc -c < "$1" 2>/dev/null | tr -d '[:space:]')
    echo "${s:-0}"
}

# Epoch of a single log line (-1 if none)
_epoch_of_line() {
    local line="$1" ep
    [[ -z "$line" ]] && { echo -1; return; }
    # SoftSwitch logs may contain NULs / non-UTF8; strip before bash/awk
    line="${line//$'\0'/}"
    # Avoid SIGPIPE+pipefail when awk exits after one line
    ep=$(set +o pipefail
        printf '%s\n' "$line" | LC_ALL=C awk "$_AWK_LINE_EPOCH"' { print line_epoch($0); exit }')
    echo "${ep:--1}"
}

# Read one full line at/after byte offset (does not scan the rest of the file)
_probe_line_at_offset() {
    local file="$1" off="$2" line
    local probe="${SEEK_PROBE_BYTES:-131072}"
    if [[ "$off" -le 0 ]]; then
        # tr drops NULs so command substitution does not warn
        head -n 1 "$file" 2>/dev/null | tr -d '\0'
        return 0
    fi
    # Stream dd→tr→awk: never store raw probe (with NULs) in a bash variable
    # LC_ALL=C: avoid "Invalid multibyte data" on binary-ish log slices
    line=$(set +o pipefail
        dd if="$file" bs=65536 iflag=skip_bytes,count_bytes skip="$off" count="$probe" 2>/dev/null \
            | tr -d '\0' \
            | LC_ALL=C awk '
                NR == 1 { partial = $0; next }
                { print; exit }
                END { if (NR <= 1 && length(partial)) print partial }
            ')
    [[ -n "$line" ]] || return 1
    printf '%s\n' "$line"
    return 0
}

# True if first/mid/near-end timestamps are non-decreasing (typical append-only logs)
_logs_appear_sorted() {
    local file="$1" size="$2"
    local e1 e2 e3 near_end line1 line2 line3
    line1=$(_probe_line_at_offset "$file" 0)
    e1=$(_epoch_of_line "$line1")
    line2=$(_probe_line_at_offset "$file" $((size / 2)))
    e2=$(_epoch_of_line "$line2")
    near_end=$((size > SEEK_PROBE_BYTES ? size - SEEK_PROBE_BYTES : 0))
    line3=$(_probe_line_at_offset "$file" "$near_end")
    e3=$(_epoch_of_line "$line3")
    [[ "$e1" =~ ^[0-9]+$ && "$e2" =~ ^[0-9]+$ && "$e3" =~ ^[0-9]+$ ]] || return 1
    [[ "$e1" -gt 0 && "$e2" -gt 0 && "$e3" -gt 0 ]] || return 1
    [[ "$e1" -le "$e2" && "$e2" -le "$e3" ]]
}

# Binary search: approximate byte offset of first line with epoch >= target
# For a 30GB file this is ~35 probes × ~128KB ≈ a few MB of I/O (timegrep/archeolog style).
_binsearch_offset_ge() {
    local file="$1" target="$2" size="$3"
    local lo=0 hi="$size" mid line ep
    # Stop when window is small; must be << typical mid-size logs (selftest ~1–2MB)
    local window="${SEEK_PROBE_BYTES:-131072}"

    while [[ $((hi - lo)) -gt "$window" ]]; do
        mid=$(( (lo + hi) / 2 ))
        line=$(_probe_line_at_offset "$file" "$mid") || { lo=$((mid + 1)); continue; }
        ep=$(_epoch_of_line "$line")
        if [[ ! "$ep" =~ ^[0-9]+$ ]] || [[ "$ep" -lt 0 ]]; then
            lo=$((mid + 4096))
            [[ "$lo" -ge "$hi" ]] && break
            continue
        fi
        if [[ "$ep" -lt "$target" ]]; then
            lo=$mid
        else
            hi=$mid
        fi
    done
    echo "$lo"
}

# Stream filter: print lines in [from,to]; if sorted=1 stop after to (and skip before from)
_awk_filter_range_prog() {
    local sorted="${1:-0}"
    printf '%s\n' "$_AWK_LINE_EPOCH"
    cat <<EOF
BEGIN { in_range = 0; sorted = $sorted }
{
    ep = line_epoch(\$0)
    if (ep >= 0) {
        if (sorted && ep > to) exit
        if (ep >= from && ep <= to) { print; in_range = 1 }
        else { in_range = 0 }
    } else if (in_range) {
        print
    }
}
EOF
}

# Align byte offset to the start of a line (after previous \n). Avoids splitting lines across chunks.
_align_to_line_start() {
    local file="$1" off="$2" size="${3:-0}"
    local prev nskip
    [[ "$off" -le 0 ]] && { echo 0; return; }
    [[ "$size" -gt 0 && "$off" -ge "$size" ]] && { echo "$size"; return; }
    prev=$(dd if="$file" bs=1 iflag=skip_bytes,count_bytes skip=$((off - 1)) count=1 2>/dev/null) || true
    if [[ "$prev" == $'\n' ]]; then
        echo "$off"
        return
    fi
    nskip=$(set +o pipefail
        dd if="$file" bs=64K iflag=skip_bytes,count_bytes skip="$off" count=65536 2>/dev/null \
            | tr -d '\0' \
            | LC_ALL=C awk 'BEGIN{RS="\n"; ORS=""} NR==1 { print length($0)+1; exit }')
    [[ "$nskip" =~ ^[0-9]+$ ]] || nskip=0
    echo $((off + nskip))
}

# Extract one newline-aligned byte window → part file
_extract_chunk_worker() {
    local file="$1" off="$2" len="$3" from_epoch="$4" to_epoch="$5" sorted="$6" part="$7"
    [[ "$len" -le 0 ]] && { : > "$part"; return 0; }
    dd if="$file" bs=4M iflag=skip_bytes,count_bytes skip="$off" count="$len" 2>/dev/null \
        | tr -d '\0' \
        | LC_ALL=C awk -v from="$from_epoch" -v to="$to_epoch" "$(_awk_filter_range_prog "$sorted")" \
        > "$part" 2>/dev/null || true
}

# Dedicated seek job pool — MUST NOT reuse COLLECTOR_JOB_PIDS (nested under copy workers → hang).
_SEEK_JOB_PIDS=()

_seek_kill_jobs() {
    local pid
    for pid in "${_SEEK_JOB_PIDS[@]+"${_SEEK_JOB_PIDS[@]}"}"; do
        kill -TERM "$pid" 2>/dev/null || true
    done
    sleep 0.2
    for pid in "${_SEEK_JOB_PIDS[@]+"${_SEEK_JOB_PIDS[@]}"}"; do
        kill -KILL "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
    done
    _SEEK_JOB_PIDS=()
}

_seek_wait_slot() {
    local max_jobs="$1" pid alive
    local waited=0
    local max_wait="${RESOURCE_WAIT_MAX:-120}"
    local gate_warned=0
    _get_cpu_usage_percent >/dev/null
    while true; do
        alive=()
        for pid in "${_SEEK_JOB_PIDS[@]+"${_SEEK_JOB_PIDS[@]}"}"; do
            if kill -0 "$pid" 2>/dev/null; then
                alive+=("$pid")
            else
                wait "$pid" 2>/dev/null || true
            fi
        done
        _SEEK_JOB_PIDS=("${alive[@]+"${alive[@]}"}")

        if [[ ${#_SEEK_JOB_PIDS[@]} -lt "$max_jobs" ]]; then
            if _collector_resources_ok; then
                return 0
            fi
            if [[ ${#_SEEK_JOB_PIDS[@]} -eq 0 ]]; then
                return 0
            fi
            if [[ "$waited" -ge "$max_wait" ]]; then
                return 0
            fi
        fi

        _collector_should_stop && return 1

        if [[ ${#_SEEK_JOB_PIDS[@]} -gt 0 ]]; then
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

_seek_wait_all_jobs() {
    local pid
    for pid in "${_SEEK_JOB_PIDS[@]+"${_SEEK_JOB_PIDS[@]}"}"; do
        wait "$pid" 2>/dev/null || true
    done
    _SEEK_JOB_PIDS=()
}

# Parallel chunk-scan of [start_off, end_off). Hang-safe (≥1 worker); line-aligned chunks.
_filter_byte_range_parallel() {
    local file="$1" dest="$2" from_epoch="$3" to_epoch="$4"
    local start_off="$5" end_off="$6" sorted="${7:-1}"
    local range chunk_sz max_jobs n i off next len part_dir rf size
    local -a parts=() bounds=()

    [[ "$end_off" -gt "$start_off" ]] || return 1
    range=$((end_off - start_off))
    size=$(_file_size_bytes "$file")
    max_jobs=$(_collector_max_jobs)
    # Nested under a copy worker: leave headroom for sibling copy jobs
    [[ "$max_jobs" -gt 4 ]] && max_jobs=$(( (max_jobs + 1) / 2 ))
    [[ "$max_jobs" -lt 1 ]] && max_jobs=1
    chunk_sz="${SEEK_CHUNK_BYTES:-67108864}"

    # Mid-size windows: enough chunks to use several workers
    if [[ "$range" -lt $((chunk_sz * max_jobs)) ]]; then
        chunk_sz=$(( range / max_jobs + 1 ))
        [[ "$chunk_sz" -lt $((1024 * 1024)) ]] && chunk_sz=$((1024 * 1024))
    fi
    # ≥1GB windows: keep large chunks (SoftSwitch monoliths)
    if [[ "$range" -ge "${SEEK_HUGE_BYTES:-1073741824}" ]]; then
        chunk_sz="${SEEK_CHUNK_BYTES:-67108864}"
        [[ "$chunk_sz" -lt $((32 * 1024 * 1024)) ]] && chunk_sz=$((32 * 1024 * 1024))
    fi

    n=$(( (range + chunk_sz - 1) / chunk_sz ))
    [[ "$n" -lt 1 ]] && n=1
    [[ "$n" -gt 256 ]] && { chunk_sz=$(( (range + 255) / 256 )); n=$(( (range + chunk_sz - 1) / chunk_sz )); }

    # Line-align chunk boundaries so no log line is split/lost
    bounds=("$start_off")
    for (( i=1; i<n; i++ )); do
        off=$(_align_to_line_start "$file" $((start_off + i * chunk_sz)) "$size")
        [[ "$off" -lt "$end_off" ]] || break
        [[ "$off" -gt "${bounds[$((${#bounds[@]} - 1))]}" ]] || continue
        bounds+=("$off")
    done
    bounds+=("$end_off")
    n=$(( ${#bounds[@]} - 1 ))

    part_dir=$(mktemp -d "${TMPDIR:-/tmp}/flat_seek.XXXXXX") || return 1
    _SEEK_JOB_PIDS=()

    for (( i=0; i<n; i++ )); do
        _collector_should_stop && { _seek_kill_jobs; rm -rf -- "$part_dir"; return 1; }
        if ! _seek_wait_slot "$max_jobs"; then
            _seek_kill_jobs
            rm -rf -- "$part_dir"
            return 1
        fi
        off="${bounds[$i]}"
        next="${bounds[$((i + 1))]}"
        len=$((next - off))
        [[ "$len" -le 0 ]] && continue
        rf="$part_dir/$(printf '%05d' "$i")"
        parts+=("$rf")
        (
            renice -n 10 $$ >/dev/null 2>&1 || true
            ionice -c 2 -n 7 -p $$ >/dev/null 2>&1 || true
            _extract_chunk_worker "$file" "$off" "$len" "$from_epoch" "$to_epoch" "$sorted" "$rf"
        ) &
        _SEEK_JOB_PIDS+=($!)
    done
    _seek_wait_all_jobs

    : > "$dest" 2>/dev/null || { rm -rf -- "$part_dir"; return 1; }
    for rf in "${parts[@]}"; do
        [[ -f "$rf" && -s "$rf" ]] && cat "$rf" >> "$dest"
    done
    rm -rf -- "$part_dir" 2>/dev/null
    [[ -s "$dest" ]]
}

# Filter log lines by timestamp inside file content (YYYY-MM-DD / DD.MM.YYYY)
# Strategy (operational speed on SoftSwitch-scale monoliths):
#   1) If plain + looks sorted + size>=SEEK_MIN: bisect from/to offsets, then parallel chunk-scan
#   2) Else if plain + size>=SEEK_MIN: parallel chunk-scan of whole file (unsorted-safe)
#   3) Else: single-thread awk (small files / .gz via zcat)
filter_log_file_by_range() {
    local src_file="$1" dest_file="$2"
    local from_epoch="$3" to_epoch="$4"
    local reader="cat" size=0 sorted=0 start_off=0 end_off=0
    local min_sz="${SEEK_MIN_BYTES:-1048576}"

    [[ "$src_file" == *.gz ]] && reader="zcat"
    _collector_should_stop && return 1
    mkdir -p "$(dirname "$dest_file")" 2>/dev/null

    if [[ "$reader" == "cat" && -f "$src_file" ]]; then
        size=$(_file_size_bytes "$src_file")
        if [[ "$size" -ge "$min_sz" ]]; then
            if _logs_appear_sorted "$src_file" "$size"; then
                sorted=1
                start_off=$(_binsearch_offset_ge "$src_file" "$from_epoch" "$size")
                # End: first line strictly after to (to+1), then pad forward a bit
                end_off=$(_binsearch_offset_ge "$src_file" "$((to_epoch + 1))" "$size")
                if [[ "$start_off" -gt "${SEEK_BACKOFF_BYTES:-1048576}" ]]; then
                    start_off=$((start_off - SEEK_BACKOFF_BYTES))
                else
                    start_off=0
                fi
                # Include some bytes after approx end (last matching lines / multiline)
                end_off=$((end_off + SEEK_BACKOFF_BYTES))
                [[ "$end_off" -gt "$size" ]] && end_off=$size
                [[ "$end_off" -le "$start_off" ]] && end_off=$size
                _filter_byte_range_parallel "$src_file" "$dest_file" "$from_epoch" "$to_epoch" \
                    "$start_off" "$end_off" 1
                return $?
            fi
            # Unsorted but large: parallel full-file chunk scan (no early-exit across file)
            _filter_byte_range_parallel "$src_file" "$dest_file" "$from_epoch" "$to_epoch" \
                0 "$size" 0
            return $?
        fi
    fi

    # Small files / gzip: single stream
    $reader "$src_file" 2>/dev/null \
        | tr -d '\0' \
        | LC_ALL=C awk -v from="$from_epoch" -v to="$to_epoch" "$(_awk_filter_range_prog 0)" \
        > "$dest_file" 2>/dev/null \
        || { rm -f "$dest_file" 2>/dev/null; return 1; }

    [[ -s "$dest_file" ]]
}

# Grep-based fallback for syslog-style logs (hour patterns).
# NEVER re-scan multi-GB files hour-by-hour — that would re-read hundreds of GB.
filter_log_file_by_range_grep() {
    local src_file="$1" dest_file="$2"
    local from_time="$3" to_time="$4"
    local from_epoch to_epoch size=0
    from_epoch=$(time_to_epoch "$from_time")
    to_epoch=$(time_to_epoch "$to_time")
    [[ -z "$from_epoch" || -z "$to_epoch" ]] && return 1
    _collector_should_stop && return 1

    if [[ "$src_file" != *.gz && -f "$src_file" ]]; then
        size=$(_file_size_bytes "$src_file")
        # Large files: awk/bisect path only — hour-loop is catastrophic
        if [[ "$size" -ge "${SEEK_MIN_BYTES:-1048576}" ]]; then
            return 1
        fi
    fi

    local patterns=() d y m dd hh
    local cur_epoch="$from_epoch"
    local span_h=$(( (to_epoch - from_epoch) / 3600 + 1 ))
    [[ "$span_h" -gt 168 ]] && return 1

    while [[ "$cur_epoch" -le "$to_epoch" ]]; do
        y=$(date -d "@$cur_epoch" "+%Y" 2>/dev/null)
        m=$(date -d "@$cur_epoch" "+%m" 2>/dev/null)
        dd=$(date -d "@$cur_epoch" "+%d" 2>/dev/null)
        hh=$(date -d "@$cur_epoch" "+%H" 2>/dev/null)
        patterns+=("${y}-${m}-${dd} ${hh}:")
        patterns+=("${dd}.${m}.${y} ${hh}:")
        patterns+=("${y}/${m}/${dd} ${hh}:")
        cur_epoch=$(( cur_epoch + 3600 ))
    done

    local pat reader="cat" combined=""
    [[ "$src_file" == *.gz ]] && reader="zcat"
    mkdir -p "$(dirname "$dest_file")" 2>/dev/null
    : > "$dest_file" 2>/dev/null || return 1

    combined=$(printf '%s|' "${patterns[@]}")
    combined="${combined%|}"
    $reader "$src_file" 2>/dev/null | grep -a -E "$combined" > "$dest_file" 2>/dev/null || true
    [[ -s "$dest_file" ]]
}

# Built-in seek unit-test (used by extended selftest / --dev)
_selftest_seek_extract() {
    local dir log dest from_epoch to_epoch base n lines got sz
    dir=$(mktemp -d "${TMPDIR:-/tmp}/flat_selfseek.XXXXXX") || return 1
    log="$dir/big.log"
    dest="$dir/out.log"
    # Force seek+chunk path
    SEEK_MIN_BYTES=$((100 * 1024))
    SEEK_CHUNK_BYTES=$((256 * 1024))
    SEEK_BACKOFF_BYTES=$((64 * 1024))
    base=$(date -d '2026-01-15 10:00:00' +%s 2>/dev/null) || base=1768467600
    n=40000
    # gawk strftime: fast synthetic sorted log (~1–2MB)
    awk -v base="$base" -v n="$n" 'BEGIN {
        for (i = 0; i < n; i++)
            printf "%s line-%d\n", strftime("%Y-%m-%d %H:%M:%S", base + i), i
    }' > "$log" 2>/dev/null || {
        for (( i=0; i<n; i++ )); do
            printf '%s line-%d\n' "$(date -d "@$((base + i))" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "2026-01-15 10:00:00")" "$i"
        done > "$log"
    }
    sz=$(wc -c < "$log" | tr -d ' ')
    from_epoch=$((base + 10000))
    to_epoch=$((base + 15000))
    if ! filter_log_file_by_range "$log" "$dest" "$from_epoch" "$to_epoch"; then
        echo "SELFTEST-SEEK: FAIL filter returned false (size=$sz)" >&2
        rm -rf -- "$dir"
        return 1
    fi
    lines=$(wc -l < "$dest" | tr -d ' ')
    if [[ "$lines" -lt 4000 || "$lines" -gt 6000 ]]; then
        echo "SELFTEST-SEEK: FAIL line count=$lines (want ~5001) size=$sz" >&2
        rm -rf -- "$dir"
        return 1
    fi
    got=$(head -1 "$dest" | grep -oE 'line-[0-9]+' | head -1)
    echo "SELFTEST-SEEK: OK lines=$lines first=$got size=$sz"
    rm -rf -- "$dir"
    return 0
}

# --- Self-test harness (simple / extended) ------------------------------------
_SELFTEST_PASS=0
_SELFTEST_FAIL=0

_selftest_ok() {
    _SELFTEST_PASS=$((_SELFTEST_PASS + 1))
    ok "selftest: $1"
}

_selftest_bad() {
    _SELFTEST_FAIL=$((_SELFTEST_FAIL + 1))
    fail "selftest: $1"
}

# Simple: functions are callable / return something sane (no deep variants)
_run_selftest_simple() {
    local ep jobs tmp dest
    info "Self-test SIMPLE (smoke: functions launch)"
    detect_os
    [[ -n "${OS_ID:-}" && -n "${PM:-}" ]] && _selftest_ok "detect_os ($OS_ID/$PM)" || _selftest_bad "detect_os"

    jobs=$(_collector_max_jobs)
    [[ "$jobs" =~ ^[1-9][0-9]*$ ]] && _selftest_ok "_collector_max_jobs=$jobs" || _selftest_bad "_collector_max_jobs"

    ep=$(time_to_epoch "$(parse_time_point '-1h')")
    [[ "$ep" =~ ^[0-9]+$ ]] && _selftest_ok "time_to_epoch via parse_time_point -1h" || _selftest_bad "time_to_epoch via parse_time_point -1h"

    if parse_duration "5m"; then
        _selftest_ok "parse_duration 5m"
    else
        _selftest_bad "parse_duration 5m"
    fi

    declare -F filter_log_file_by_range >/dev/null 2>&1 \
        && _selftest_ok "filter_log_file_by_range defined" \
        || _selftest_bad "filter_log_file_by_range defined"
    declare -F _binsearch_offset_ge >/dev/null 2>&1 \
        && _selftest_ok "_binsearch_offset_ge defined" \
        || _selftest_bad "_binsearch_offset_ge defined"
    declare -F _filter_byte_range_parallel >/dev/null 2>&1 \
        && _selftest_ok "_filter_byte_range_parallel defined" \
        || _selftest_bad "_filter_byte_range_parallel defined"

    tmp=$(mktemp "${TMPDIR:-/tmp}/flat_st.XXXXXX") || return 1
    dest="${tmp}.out"
    printf '2026-01-15 12:00:00 hello\n2026-01-15 13:00:00 world\n' > "$tmp"
    if filter_log_file_by_range "$tmp" "$dest" "$(time_to_epoch '2026-01-15 11:00:00')" "$(time_to_epoch '2026-01-15 14:00:00')"; then
        _selftest_ok "tiny filter_log_file_by_range"
    else
        _selftest_bad "tiny filter_log_file_by_range"
    fi
    rm -f -- "$tmp" "$dest" 2>/dev/null

    _get_mem_usage_percent >/dev/null && _selftest_ok "_get_mem_usage_percent" || _selftest_bad "_get_mem_usage_percent"
    _get_cpu_usage_percent >/dev/null && _selftest_ok "_get_cpu_usage_percent" || _selftest_bad "_get_cpu_usage_percent"
}

# Extended: detailed variants + full health (VERBOSE) + seek extract
_run_selftest_extended() {
    local ep1 ep2 products p
    info "Self-test EXTENDED (variants + health + seek)"
    _run_selftest_simple

    # Time / duration variants
    local t1 t2
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

    # Resource gate must allow ≥1 worker (hang-safety)
    COLLECTOR_JOB_PIDS=()
    if _collector_wait_slot 2; then
        _selftest_ok "_collector_wait_slot (hang-safe)"
    else
        _selftest_bad "_collector_wait_slot"
    fi

    # Full seek + parallel chunk path
    if _selftest_seek_extract; then
        _selftest_ok "seek+chunk extract (bisect)"
    else
        _selftest_bad "seek+chunk extract (bisect)"
    fi

    # Verbose health across all known products (former -v / --dev)
    VERBOSE=1
    detect_os
    check_system
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
    info "flat_check_2 self-test ($level) v${SCRIPT_VERSION}"
    case "$level" in
        simple)
            _run_selftest_simple
            ;;
        extended|dev)
            _run_selftest_extended
            ;;
        *)
            die "Unknown self-test level: $level (use simple|extended)"
            ;;
    esac
    echo ""
    if [[ "$_SELFTEST_FAIL" -eq 0 ]]; then
        ok "Self-test $level: $_SELFTEST_PASS passed, 0 failed"
        return 0
    fi
    fail "Self-test $level: $_SELFTEST_PASS passed, $_SELFTEST_FAIL failed"
    return 1
}

# --- 8. Duration / time-point parsers + line filters by timestamp --------------
# Offline: filter_log_file_by_range* — earlier in file near collect_postgresql.
# Shared duration helpers:
parse_duration() {
    local raw="$1"
    PARSE_RESULT_NUM=0
    PARSE_RESULT_UNIT=""
    if [[ "$raw" =~ ^[0-9]+$ ]]; then
        PARSE_RESULT_NUM="$raw"
        PARSE_RESULT_UNIT="s"
        return 0
    fi
    if [[ "$raw" =~ ^([0-9]+)([smhd])$ ]]; then
        PARSE_RESULT_NUM="${BASH_REMATCH[1]}"
        PARSE_RESULT_UNIT="${BASH_REMATCH[2]}"
        return 0
    fi
    return 1
}

duration_to_minutes() {
    local num="$1" unit="$2"
    case "$unit" in s) echo "$(( (num + 59) / 60 ))" ;; m) echo "$num" ;; h) echo "$(( num * 60 ))" ;; d) echo "$(( num * 1440 ))" ;; *) echo "$num" ;; esac
}

duration_to_seconds() {
    local num="$1" unit="$2"
    case "$unit" in s) echo "$num" ;; m) echo "$(( num * 60 ))" ;; h) echo "$(( num * 3600 ))" ;; d) echo "$(( num * 86400 ))" ;; *) echo "$num" ;; esac
}

# ============================================================
# Parse time point: absolute date or relative offset
#   "-2h"        → 2 hours ago
#   "2025-06-25 10:00" → absolute date
#   "25.06.2025 10:00" → absolute date (DD.MM.YYYY)
# ============================================================
parse_time_point() {
    local raw="$1"
    local result=""
    # Relative offset: starts with + or -
    if [[ "$raw" =~ ^[+-] ]]; then
        local sign="${raw:0:1}"
        local dur="${raw:1}"
        if ! parse_duration "$dur"; then
            return 1
        fi
        local unit_str=""
        case "$PARSE_RESULT_UNIT" in
            s) unit_str="seconds" ;;
            m) unit_str="minutes" ;;
            h) unit_str="hours" ;;
            d) unit_str="days" ;;
        esac
        result=$(date -d "${sign}${PARSE_RESULT_NUM} ${unit_str}" "+%Y-%m-%d %H:%M:%S" 2>/dev/null)
    else
        # Absolute date: try multiple formats
        result=$(date -d "$raw" "+%Y-%m-%d %H:%M:%S" 2>/dev/null)
        # Fallback: DD.MM.YYYY HH:MM → convert to YYYY-MM-DD HH:MM
        if [[ -z "$result" && "$raw" =~ ^([0-9]{2})\.([0-9]{2})\.([0-9]{4})[[:space:]]([0-9]{2}):([0-9]{2}).*$ ]]; then
            local d="${BASH_REMATCH[1]}" m="${BASH_REMATCH[2]}" y="${BASH_REMATCH[3]}"
            local hh="${BASH_REMATCH[4]}" mm="${BASH_REMATCH[5]}"
            result=$(date -d "${y}-${m}-${d} ${hh}:${mm}" "+%Y-%m-%d %H:%M:%S" 2>/dev/null)
        fi
        # Fallback: DD.MM HH:MM (current year)
        if [[ -z "$result" && "$raw" =~ ^([0-9]{2})\.([0-9]{2})[[:space:]]([0-9]{2}):([0-9]{2}).*$ ]]; then
            local d="${BASH_REMATCH[1]}" m="${BASH_REMATCH[2]}"
            local hh="${BASH_REMATCH[3]}" mm="${BASH_REMATCH[4]}"
            local y; y=$(date +%Y)
            result=$(date -d "${y}-${m}-${d} ${hh}:${mm}" "+%Y-%m-%d %H:%M:%S" 2>/dev/null)
        fi
    fi
    [[ -n "$result" ]] && echo "$result" && return 0
    return 1
}

# --- 9. Collector processes / signals / safe remove ----------------------------
# Root: only delete work dirs matching ARCHIVE name pattern under COLLECTOR_DIR.

# True if path looks like our session work dir: <collector>/YYYY.MM.DD_HH-MM_*
_is_safe_work_dir() {
    local path="$1" base parent
    [[ -n "$path" && -d "$path" ]] || return 1
    path=$(readlink -f "$path" 2>/dev/null || echo "$path")
    base=$(basename "$path")
    parent=$(dirname "$path")
    [[ "$base" =~ ^[0-9]{4}\.[0-9]{2}\.[0-9]{2}_[0-9]{2}-[0-9]{2}_ ]] || return 1
    if [[ -n "${COLLECTOR_DIR:-}" ]]; then
        local coll
        coll=$(readlink -f "$COLLECTOR_DIR" 2>/dev/null || echo "$COLLECTOR_DIR")
        [[ "$parent" == "$coll" ]] || return 1
    fi
    # refuse obviously dangerous roots
    case "$path" in
        /|/bin|/boot|/dev|/etc|/home|/lib|/lib64|/opt|/proc|/root|/run|/sbin|/srv|/sys|/tmp|/usr|/var) return 1 ;;
    esac
    return 0
}

# Remove current session dir only after safety checks (Ctrl+C / early abort)
safe_rm_work_dir() {
    local path="${1:-${WORK_DIR:-}}"
    if _is_safe_work_dir "$path"; then
        rm -rf -- "$path" 2>/dev/null
    elif [[ -n "$path" ]]; then
        warn "Refusing to remove path (safety check failed): $path"
    fi
}

# TERM + brief grace + KILL for a PID list (shared by collector and full cleanup)
_kill_pids_gracefully() {
    local pid
    for pid in "$@"; do
        [[ -n "$pid" ]] && kill -TERM "$pid" 2>/dev/null
    done
    sleep 1
    for pid in "$@"; do
        [[ -n "$pid" ]] || continue
        if kill -0 "$pid" 2>/dev/null; then
            kill -KILL "$pid" 2>/dev/null
        fi
        wait "$pid" 2>/dev/null || true
    done
}

cleanup_background_jobs() {
    local pid
    # TERM, brief grace, then KILL so wait cannot hang on stuck tail/NFS
    for pid in "${TAIL_PIDS[@]+"${TAIL_PIDS[@]}"}"; do [[ -n "$pid" ]] && kill -TERM "$pid" 2>/dev/null; done
    if [[ ${#COLLECTOR_JOB_PIDS[@]} -gt 0 ]]; then
        _kill_pids_gracefully "${COLLECTOR_JOB_PIDS[@]}"
    fi
    [[ -n "${TCPDUMP_PID:-}" ]] && kill -TERM "$TCPDUMP_PID" 2>/dev/null
    [[ -n "${TIMEOUT_KILL_PID:-}" ]] && kill "$TIMEOUT_KILL_PID" 2>/dev/null
    [[ -n "${DISK_WATCH_PID:-}" ]] && kill "$DISK_WATCH_PID" 2>/dev/null
    sleep 1
    for pid in "${TAIL_PIDS[@]+"${TAIL_PIDS[@]}"}" \
               ${TCPDUMP_PID:+"$TCPDUMP_PID"} \
               ${TIMEOUT_KILL_PID:+"$TIMEOUT_KILL_PID"} \
               ${DISK_WATCH_PID:+"$DISK_WATCH_PID"}; do
        [[ -n "$pid" ]] || continue
        if kill -0 "$pid" 2>/dev/null; then
            kill -KILL "$pid" 2>/dev/null
        fi
        wait "$pid" 2>/dev/null || true
    done
    TAIL_PIDS=()
    COLLECTOR_JOB_PIDS=()
    TCPDUMP_PID=""
    TIMEOUT_KILL_PID=""
    DISK_WATCH_PID=""
}

cleanup_on_abort() {
    cleanup_background_jobs
    safe_rm_work_dir
}

# TERM: graceful stop (online timeout, disk guard) — interrupt read, then archive
_on_collect_graceful_stop() {
    COLLECTOR_TIMEOUT_STOP=1
}

# INT (Ctrl+C): abort — delete work dir, no archive
_on_collect_abort() {
    COLLECTOR_ABORTED=1
    cleanup_on_abort
    exit 130
}

cleanup() {
    cleanup_background_jobs
}

trap _on_collect_abort INT
trap _on_collect_graceful_stop TERM
trap cleanup EXIT

# Disk free percent (100 - used%). Empty on failure.
get_disk_free_percent() {
    local dir="${1:-.}"
    df -P "$dir" 2>/dev/null | awk 'NR==2 { gsub(/%/,"",$5); if ($5+0>=0) print 100-$5 }'
}

cleanup_old_work_dirs() {
    local dir="$1" keep_name="${2:-}"
    local d base
    [[ -d "$dir" ]] || return 0
    # Only under collector output; only our naming pattern; never current keep_name
    while IFS= read -r -d '' d; do
        base=$(basename "$d")
        [[ -n "$keep_name" && "$base" == "$keep_name" ]] && continue
        _is_safe_work_dir "$d" || continue
        rm -rf -- "$d" 2>/dev/null
    done < <(find "$dir" -maxdepth 1 -type d \
        -name '[0-9][0-9][0-9][0-9].[0-9][0-9].[0-9][0-9]_[0-9][0-9]-[0-9][0-9]_*' -print0 2>/dev/null)
}

# Unique archive subdirectory name for a source log dir (online + offline must match)
_archive_subdir_name() {
    local path="$1" name
    path=$(readlink -f "$path" 2>/dev/null || echo "$path")
    path="${path%/}"
    if [[ "$path" == /var/log/flat ]]; then
        echo "flat"
        return 0
    fi
    if [[ "$path" == /var/log/flat/* ]]; then
        name="${path#/var/log/flat/}"
        echo "${name////_}"
        return 0
    fi
    if [[ "$path" =~ ^/opt/flat/([^/]+)/(log|logs)$ ]]; then
        echo "${BASH_REMATCH[1]}"
        return 0
    fi
    echo "${path#/}" | tr '/' '_'
}

# Background disk monitor: TERM → graceful stop if free space < 2%
start_disk_watch() {
    local watch_dir="$1"
    (
        while true; do
            local free
            free=$(get_disk_free_percent "$watch_dir")
            if [[ -n "$free" && "$free" -lt 2 ]]; then
                kill -TERM $$ 2>/dev/null
                break
            fi
            sleep 10
        done
    ) &
    DISK_WATCH_PID=$!
}

# Unique destination path: flatten relative path so parallel same-basename files don't collide
_unique_dest_path() {
    local src_file="$1" dest_dir="$2" src_dir="${3:-}"
    local rel base dest_path n=0
    if [[ -n "$src_dir" ]]; then
        rel="${src_file#"$src_dir"/}"
        rel="${rel#/}"
        [[ -z "$rel" || "$rel" == "$src_file" ]] && rel=$(basename "$src_file")
    else
        rel=$(basename "$src_file")
    fi
    base="${rel////_}"
    dest_path="$dest_dir/$base"
    while [[ -e "$dest_path" ]]; do
        n=$((n + 1))
        dest_path="$dest_dir/${base}.$$.$RANDOM.$n"
        [[ "$n" -gt 50 ]] && break
    done
    echo "$dest_path"
}

_start_tail_one_file() {
    local src_file="$1" dest_dir="$2" display_label="$3" src_dir="${4:-}"
    local dest_path pid
    dest_path=$(_unique_dest_path "$src_file" "$dest_dir" "$src_dir")
    mkdir -p "$dest_dir" || return 1
    # Lower priority; keep nice/ionice on the same & line so $! is the tail chain
    if command -v nice >/dev/null 2>&1 && command -v ionice >/dev/null 2>&1; then
        nice -n 10 ionice -c3 tail -F -n 0 "$src_file" > "$dest_path" 2>/dev/null &
    elif command -v nice >/dev/null 2>&1; then
        nice -n 10 tail -F -n 0 "$src_file" > "$dest_path" 2>/dev/null &
    else
        tail -F -n 0 "$src_file" > "$dest_path" 2>/dev/null &
    fi
    pid=$!
    if kill -0 "$pid" 2>/dev/null; then
        TAIL_PIDS+=("$pid")
        ok "Monitoring ${display_label}: $(basename "$src_file") PID=$pid"
        return 0
    fi
    warn "Failed to start tail for ${display_label}: $(basename "$src_file")"
    return 1
}

start_tail_for_file() {
    local src_file="$1" dest_dir="$2"
    local display_label="${3:-$(basename "$src_file")}"
    _start_tail_one_file "$src_file" "$dest_dir" "$display_label"
}

prune_empty_collected_files() {
    local root="$1"
    [[ -d "$root" ]] || return 0
    find "$root" -type f -empty ! -path '*/configs/*' ! -name '*.pcap' -delete 2>/dev/null
    find "$root" -type d -empty -delete 2>/dev/null
}

_count_collected_log_stats() {
    local root="$1" count=0 bytes=0 f sz
    while IFS= read -r -d '' f; do
        sz=$(stat -c '%s' "$f" 2>/dev/null || echo 0)
        count=$((count + 1))
        bytes=$(( bytes + sz ))
    done < <(find "$root" -type f ! -path '*/configs/*' ! -name '*.pcap' -size +0c -print0 2>/dev/null)
    echo "$count $bytes"
}

report_collected_log_stats() {
    local root="$1" mode="$2" count=0 bytes=0 kb=0
    read -r count bytes < <(_count_collected_log_stats "$root")
    kb=$(( (bytes + 1023) / 1024 ))
    if [[ "$count" -gt 0 ]]; then
        info "$(_l log_archive_stats) $count ($kb KB)"
    elif [[ "$mode" == "online" ]]; then
        info "$(_l log_online_no_new)"
    fi
}

start_tail_for_dir() {
    local src_dir="$1" dest_dir="$2"
    local find_fn="find_log_files_in_dir"
    local display_label="${4:-$(basename "$src_dir")}"
    [[ "${3:-}" == "pg" ]] && find_fn="find_pg_log_files_in_dir"
    local files=() f started=0
    while IFS= read -r -d '' f; do files+=("$f"); done < <($find_fn "$src_dir")
    if [[ ${#files[@]} -eq 0 ]]; then
        local ctx
        ctx=$(_logs_time_context "${LOG_SUBMODE:-online}")
        info "${display_label}: $(_log_absent_reason "$ctx")"
        return 0
    fi
    mkdir -p "$dest_dir" || return 1
    for f in "${files[@]}"; do
        if _start_tail_one_file "$f" "$dest_dir" "$display_label" "$src_dir"; then
            started=$((started + 1))
        fi
    done
    [[ "$started" -eq 0 ]] && warn "Failed to start tail for ${display_label} ($src_dir)"
}

_collector_max_jobs() {
    local n cores
    if [[ "${COLLECTOR_JOBS:-0}" -gt 0 ]]; then
        echo "$COLLECTOR_JOBS"
        return 0
    fi
    cores=$(nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)
    [[ -z "$cores" || "$cores" -lt 1 ]] && cores=4
    # Default worker cap from cores; spawning still gated by host-wide RESOURCE_* limits
    n=$(( cores * ${RESOURCE_CPU_LIMIT:-80} / 100 ))
    [[ "$n" -lt 1 ]] && n=1
    [[ "$n" -gt 32 ]] && n=32
    echo "$n"
}

# Memory used percent for whole host (100 - MemAvailable/MemTotal*100)
_get_mem_usage_percent() {
    local pct
    # Prefer MemAvailable; fall back to MemFree (Git Bash / odd kernels may lack Available)
    pct=$(awk '/MemTotal:/ {t=$2} /MemAvailable:/ {a=$2} /MemFree:/ {f=$2} END {
        if (t+0 <= 0) { print 0; exit }
        if (a+0 <= 0) a = f
        printf "%d", int((t - a) * 100 / t);
    }' /proc/meminfo 2>/dev/null)
    echo "${pct:-0}"
}

# System CPU busy percent via /proc/stat delta (first call primes, returns 0)
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

# True if whole-host CPU and memory are under configured limits
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
    # First /proc/stat sample always returns 0 — always take a second sample
    if [[ "$cpu" -eq 0 ]]; then
        sleep 0.2
        cpu=$(_get_cpu_usage_percent)
        [[ "$cpu" =~ ^[0-9]+$ ]] || cpu=0
    fi
    [[ "$cpu" -lt "$cpu_lim" ]]
}

# Wait for a free job slot. Host-wide gate throttles *additional* workers when
# CPU/MEM ≥ limit, but never blocks forever:
#   - 0 running workers → always allow 1 (progress guarantee; avoids hang on busy hosts)
#   - ≥1 running → wait for headroom or a finished job, up to RESOURCE_WAIT_MAX
_collector_wait_slot() {
    local max_jobs="$1" pid alive
    local waited=0
    local max_wait="${RESOURCE_WAIT_MAX:-120}"
    local gate_warned=0
    # Prime CPU counter
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
            # No workers yet → must start one or we deadlock on busy hosts (MEM often ≥80%)
            if [[ ${#COLLECTOR_JOB_PIDS[@]} -eq 0 ]]; then
                if [[ "$gate_warned" -eq 0 ]]; then
                    info "host CPU/MEM at/above ${RESOURCE_CPU_LIMIT}%/${RESOURCE_MEM_LIMIT}% — starting 1 worker (avoid hang)"
                    gate_warned=1
                fi
                return 0
            fi
            # Already have workers: wait for load to drop or a job to finish
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

_collector_kill_jobs() {
    [[ ${#COLLECTOR_JOB_PIDS[@]} -eq 0 ]] && return 0
    _kill_pids_gracefully "${COLLECTOR_JOB_PIDS[@]}"
    COLLECTOR_JOB_PIDS=()
}

# Process copy job results; arrays job_labels[job_idx]=source_label
_process_copy_job_results() {
    local result_dir="$1" use_content_filter="$2"
    local -n pjob_labels=$3
    local -A lbl_copied=() lbl_skipped=() lbl_warns=()
    local -a lbl_order=()
    local rf job_idx kind a b c source_label copied=0
    local skipped_no_range_files=() skipped_warn_entries=()
    local reason_entry dest_dir

    for rf in "$result_dir"/*; do
        [[ -f "$rf" ]] || continue
        job_idx=$(basename "$rf")
        source_label="${pjob_labels[$job_idx]:-}"
        if [[ -n "$source_label" ]]; then
            if [[ ",${lbl_order[*]}," != *",$source_label,"* ]]; then
                lbl_order+=("$source_label")
            fi
        fi
        IFS='|' read -r kind a b c < "$rf" || continue
        case "$kind" in
            OK)
                copied=$((copied + 1))
                lbl_copied["$source_label"]=$((${lbl_copied[$source_label]:-0} + 1))
                ok "$(_l collected) $a lines from $b ($source_label)"
                ;;
            OK_GREP)
                copied=$((copied + 1))
                lbl_copied["$source_label"]=$((${lbl_copied[$source_label]:-0} + 1))
                ok "$(_l collected) $a lines (grep) from $b ($source_label)"
                ;;
            OK_CP)
                copied=$((copied + 1))
                lbl_copied["$source_label"]=$((${lbl_copied[$source_label]:-0} + 1))
                ;;
            SKIP)
                skipped_no_range_files+=("$source_label|$a")
                ;;
            WARN)
                skipped_warn_entries+=("$source_label|$a: $b")
                ;;
        esac
    done

    local lbl entry base files_for_lbl=() seen=""
    for lbl in "${lbl_order[@]}"; do
        [[ -z "$lbl" ]] && continue
        files_for_lbl=()
        for entry in "${skipped_no_range_files[@]}"; do
            [[ "$entry" == "$lbl|"* ]] || continue
            base="${entry#"$lbl"|}"
            files_for_lbl+=("$base")
        done
        if [[ ${#files_for_lbl[@]} -gt 0 ]]; then
            _log_absent_info "$lbl" "period" "${files_for_lbl[@]}"
        fi
        local warn_for_lbl=()
        for entry in "${skipped_warn_entries[@]}"; do
            [[ "$entry" == "$lbl|"* ]] && warn_for_lbl+=("${entry#"$lbl"|}")
        done
        if [[ ${#warn_for_lbl[@]} -gt 0 ]]; then
            warn "$(_l skipped) ${#warn_for_lbl[@]} $(_l log_files_from) $lbl"
            for reason_entry in "${warn_for_lbl[@]}"; do
                warn "  → $reason_entry"
            done
        fi
        if [[ ${lbl_copied[$lbl]:-0} -gt 0 && "$use_content_filter" -eq 0 ]]; then
            ok "$(_l collected) ${lbl_copied[$lbl]} $(_l log_files_from) $lbl"
        fi
    done
    echo "$copied"
}

# Shared job pool over a pre-built file list (one pool — no nested workers).
# Namerefs MUST use distinct local names: caller often passes arrays named cp_files etc.
_copy_log_files_parallel() {
    local from_time="${1:-}" to_time="${2:-}"
    local -n _ref_files=$3
    local -n _ref_src=$4
    local -n _ref_dest=$5
    local -n _ref_label=$6
    local -a _empty_labels=("${@:7}")

    local n=${#_ref_files[@]} max_jobs result_dir job_idx=0 rf f i
    local from_epoch="" to_epoch="" use_content_filter=0 copied

    if [[ "$n" -eq 0 ]]; then
        local lbl ctx
        for lbl in "${_empty_labels[@]}"; do
            [[ -z "$lbl" ]] && continue
            ctx=$(_logs_time_context "offline" "$from_time" "$to_time")
            info "${lbl}: $(_log_absent_reason "$ctx")"
        done
        return 0
    fi

    if [[ -n "$from_time" || -n "$to_time" ]]; then
        use_content_filter=1
        [[ -z "$to_time" ]] && to_time=$(date "+%Y-%m-%d %H:%M:%S")
        [[ -z "$from_time" ]] && from_time="1970-01-01 00:00:00"
        from_epoch=$(time_to_epoch "$from_time")
        to_epoch=$(time_to_epoch "$to_time")
        [[ -z "$from_epoch" || -z "$to_epoch" ]] && use_content_filter=0
    fi

    max_jobs=$(_collector_max_jobs)
    [[ "$max_jobs" -gt "$n" ]] && max_jobs="$n"
    result_dir=$(mktemp -d "${TMPDIR:-/tmp}/flat_copy.XXXXXX") || return 1
    declare -A _copy_job_labels=()

    for (( i=0; i<n; i++ )); do
        f="${_ref_files[$i]}"
        mkdir -p "${_ref_dest[$i]}" || continue
        if _collector_should_stop; then
            _collector_kill_jobs
            rm -rf -- "$result_dir" 2>/dev/null
            return 130
        fi
        if ! _collector_wait_slot "$max_jobs"; then
            _collector_kill_jobs
            rm -rf -- "$result_dir" 2>/dev/null
            return 130
        fi
        job_idx=$((job_idx + 1))
        _copy_job_labels["$job_idx"]="${_ref_label[$i]}"
        rf="$result_dir/$job_idx"
        (
            renice -n 10 $$ >/dev/null 2>&1 || true
            ionice -c 2 -n 7 -p $$ >/dev/null 2>&1 || true
            _copy_one_existing_log "$f" "${_ref_src[$i]}" "${_ref_dest[$i]}" \
                "$use_content_filter" "$from_epoch" "$to_epoch" \
                "$from_time" "$to_time" "$rf"
        ) &
        COLLECTOR_JOB_PIDS+=($!)
    done

    _collector_wait_all_jobs

    if _collector_should_stop; then
        rm -rf -- "$result_dir" 2>/dev/null
        return 130
    fi

    copied=$(_process_copy_job_results "$result_dir" "$use_content_filter" _copy_job_labels)
    rm -rf -- "$result_dir" 2>/dev/null
    return 0
}

# Copy/filter one log file; write status line to result_file
# Status: OK|<lines>|<base> | OK_GREP|<lines>|<base> | OK_CP|<base> | SKIP|<base> | WARN|<base>|<reason>
_copy_one_existing_log() {
    local f="$1" src_dir="$2" dest_dir="$3"
    local use_content_filter="$4" from_epoch="$5" to_epoch="$6"
    local from_time="$7" to_time="$8" result_file="$9"

    local base dest_path lines rel err_msg reason

    dest_path=$(_unique_dest_path "$f" "$dest_dir" "$src_dir")
    rel="${f#"$src_dir"/}"
    rel="${rel#/}"
    [[ -z "$rel" || "$rel" == "$f" ]] && rel=$(basename "$f")
    base="${rel////_}"

    if [[ "$use_content_filter" -eq 1 ]]; then
        if filter_log_file_by_range "$f" "$dest_path" "$from_epoch" "$to_epoch"; then
            lines=$(wc -l < "$dest_path" 2>/dev/null || echo 0)
            printf 'OK|%s|%s\n' "$lines" "$base" > "$result_file"
        elif filter_log_file_by_range_grep "$f" "$dest_path" "$from_time" "$to_time"; then
            lines=$(wc -l < "$dest_path" 2>/dev/null || echo 0)
            printf 'OK_GREP|%s|%s\n' "$lines" "$base" > "$result_file"
        else
            rm -f "$dest_path" 2>/dev/null
            printf 'SKIP|%s\n' "$base" > "$result_file"
        fi
    else
        err_msg=$(cp -p "$f" "$dest_path" 2>&1)
        if [[ $? -eq 0 ]]; then
            printf 'OK_CP|%s\n' "$base" > "$result_file"
        else
            if [[ "$err_msg" == *"Permission denied"* ]]; then
                reason="Permission denied (try sudo)"
            elif [[ "$err_msg" == *"No space left"* ]]; then
                reason="No space left on device"
            else
                reason="${err_msg:-unknown error}"
            fi
            printf 'WARN|%s|%s\n' "$base" "$reason" > "$result_file"
        fi
    fi
}

copy_existing_logs() {
    local src_dir="$1" dest_dir="$2"
    local from_time="${3:-}"
    local to_time="${4:-}"
    local log_kind="${5:-}"
    local source_label="${6:-$(basename "$src_dir")}"
    local find_fn="find_log_files_in_dir"
    [[ "$log_kind" == "pg" ]] && find_fn="find_pg_log_files_in_dir"
    local -a cp_files=() cp_src=() cp_dest=() cp_label=()
    local f rc

    while IFS= read -r -d '' f; do
        cp_files+=("$f")
        cp_src+=("$src_dir")
        cp_dest+=("$dest_dir")
        cp_label+=("$source_label")
    done < <($find_fn "$src_dir")

    if [[ ${#cp_files[@]} -eq 0 ]]; then
        _copy_log_files_parallel "$from_time" "$to_time" cp_files cp_src cp_dest cp_label "$source_label"
        return 0
    fi

    mkdir -p "$dest_dir" || return 1
    _copy_log_files_parallel "$from_time" "$to_time" cp_files cp_src cp_dest cp_label
    rc=$?
    [[ $rc -eq 130 ]] && return 130
    if [[ -d "$dest_dir" ]] && [[ -z "$(find "$dest_dir" -mindepth 1 -print -quit 2>/dev/null)" ]]; then
        rmdir "$dest_dir" 2>/dev/null
    fi
}

# Flatten all log dirs into one shared job pool (avoids nested worker pools)
copy_all_log_dirs_parallel() {
    local work_root="$1"
    local from_time="${2:-}"
    local to_time="${3:-}"
    local logdir dest_name f file_count
    local -a cp_files=() cp_src=() cp_dest=() cp_label=() empty_labels=()

    for logdir in "${ALL_LOG_DIRS[@]}"; do
        _collector_should_stop && return 130
        dest_name=$(_archive_subdir_name "$logdir")
        file_count=0
        while IFS= read -r -d '' f; do
            cp_files+=("$f")
            cp_src+=("$logdir")
            cp_dest+=("$work_root/$dest_name")
            cp_label+=("$dest_name")
            file_count=$((file_count + 1))
        done < <(find_log_files_in_dir "$logdir")
        [[ "$file_count" -eq 0 ]] && empty_labels+=("$dest_name")
    done

    _copy_log_files_parallel "$from_time" "$to_time" cp_files cp_src cp_dest cp_label "${empty_labels[@]}"
}

copy_system_log_by_range() {
    local sysfile="$1" sysdest="$2"
    local from_time="${3:-}" to_time="${4:-}"
    local source_label="${5:-}"
    local base dest_path from_epoch to_epoch

    [[ -f "$sysfile" ]] || return 0
    base=$(basename "$sysfile")
    mkdir -p "$sysdest" || return 1
    dest_path="$sysdest/$base"
    [[ -z "$source_label" ]] && source_label="system"

    if [[ -n "$from_time" || -n "$to_time" ]]; then
        [[ -z "$to_time" ]] && to_time=$(date "+%Y-%m-%d %H:%M:%S")
        [[ -z "$from_time" ]] && from_time="1970-01-01 00:00:00"
        from_epoch=$(time_to_epoch "$from_time")
        to_epoch=$(time_to_epoch "$to_time")
        if filter_log_file_by_range "$sysfile" "$dest_path" "$from_epoch" "$to_epoch"; then
            ok "${source_label}: $(_l sys_copied) $base ($(wc -l < "$dest_path" 2>/dev/null || echo 0) lines)"
        elif filter_log_file_by_range_grep "$sysfile" "$dest_path" "$from_time" "$to_time"; then
            ok "${source_label}: $(_l sys_copied) $base (grep, $(wc -l < "$dest_path" 2>/dev/null || echo 0) lines)"
        else
            rm -f "$dest_path" 2>/dev/null
            info "${source_label}: $base — $(_log_absent_reason period)"
        fi
    else
        cp -p "$sysfile" "$dest_path" 2>/dev/null && ok "${source_label}: $(_l sys_copied) $base"
    fi
}

_copy_one_config() {
    local src="$1" dest="$2" result_file="$3"
    mkdir -p "$(dirname "$dest")" 2>/dev/null || true
    if cp -p "$src" "$dest" 2>/dev/null; then
        printf 'OK\n' > "$result_file"
    else
        printf 'FAIL\n' > "$result_file"
    fi
}

collect_configs() {
    local dest="$1"
    local -a cfg_src=() cfg_dest=()
    local conf f rel subdir collected=() dup existing
    local max_jobs result_dir job_idx=0 rf count=0

    for conf in "${CONFIG_PATHS[@]}"; do
        if [[ -f "$conf" ]]; then
            subdir=$(dirname "$conf" | sed 's|^/||;s|/|_|g')
            cfg_src+=("$conf")
            cfg_dest+=("$dest/configs/$subdir/$(basename "$conf")")
        fi
    done
    if [[ -d "/opt/flat" ]]; then
        collected=()
        while IFS= read -r -d '' f; do
            collected+=("$f")
        done < <(find "/opt/flat" -maxdepth 5 \( -name node_modules -o -name .git -o -name vendor -o -name dist -o -name build -o -name .pnpm -o -name .cache \) -prune -o \
            -type f -path '*/config/*' \
            \( -name '*.ini' -o -name '*.xml' -o -name '*.yml' -o -name '*.yaml' -o -name '*.conf' -o -name '*.json' -o -name '*.properties' -o -name '*.cfg' \) \
            -print0 2>/dev/null)
        while IFS= read -r -d '' f; do
            dup=0
            for existing in "${collected[@]}"; do [[ "$existing" == "$f" ]] && dup=1 && break; done
            [[ "$dup" -eq 0 ]] && collected+=("$f")
        done < <(find "/opt/flat" -maxdepth 5 \( -name node_modules -o -name .git -o -name vendor -o -name dist -o -name build -o -name .pnpm -o -name .cache \) -prune -o \
            -type f \( -iname '*config*' -o -iname '*version*' -o -iname '*settings*' \) \
            \( -name '*.ini' -o -name '*.xml' -o -name '*.yml' -o -name '*.yaml' -o -name '*.conf' -o -name '*.json' -o -name '*.properties' -o -name '*.cfg' \) \
            -print0 2>/dev/null)
        for f in "${collected[@]}"; do
            rel=$(echo "$f" | sed 's|^/opt/flat/||;s|/|_|g')
            cfg_src+=("$f")
            cfg_dest+=("$dest/configs/${rel}")
        done
    fi

    [[ ${#cfg_src[@]} -eq 0 ]] && return 0

    max_jobs=$(_collector_max_jobs)
    [[ "$max_jobs" -gt ${#cfg_src[@]} ]] && max_jobs=${#cfg_src[@]}
    result_dir=$(mktemp -d "${TMPDIR:-/tmp}/flat_cfg.XXXXXX" 2>/dev/null) || return 0
    _get_cpu_usage_percent >/dev/null

    for (( i=0; i<${#cfg_src[@]}; i++ )); do
        if ! _collector_wait_slot "$max_jobs"; then
            break
        fi
        job_idx=$((job_idx + 1))
        rf="$result_dir/$job_idx"
        (
            renice -n 10 $$ >/dev/null 2>&1 || true
            _copy_one_config "${cfg_src[$i]}" "${cfg_dest[$i]}" "$rf"
        ) &
        COLLECTOR_JOB_PIDS+=($!)
    done
    _collector_wait_all_jobs

    for rf in "$result_dir"/*; do
        [[ -f "$rf" ]] || continue
        [[ "$(cat "$rf" 2>/dev/null)" == OK ]] && count=$((count + 1))
    done
    rm -rf -- "$result_dir" 2>/dev/null
    [[ "$count" -gt 0 ]] && info "$(_l config_collected): $count"
}

# --- 10. Online / offline collection -------------------------------------------
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

    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    COLLECTOR_DIR="${OUTPUT_DIR:-$SCRIPT_DIR}"
    if [[ ! -d "$COLLECTOR_DIR" ]]; then
        mkdir -p "$COLLECTOR_DIR" 2>/dev/null || die "$(_l err_perm): $COLLECTOR_DIR"
    fi
    [[ -w "$COLLECTOR_DIR" ]] || die "$(_l err_perm): $COLLECTOR_DIR"

    ARCHIVE_NAME="$(date '+%Y.%m.%d_%H-%M_')$(hostname)"
    # Remove stale dirs BEFORE creating current work dir (never delete ARCHIVE_NAME)
    cleanup_old_work_dirs "$COLLECTOR_DIR" "$ARCHIVE_NAME"
    WORK_DIR="$COLLECTOR_DIR/$ARCHIVE_NAME"
    mkdir -p "$WORK_DIR" || die "Cannot create work dir: $WORK_DIR"

    info "$(_l mode_log): $mode / scope=$LOG_SCOPE (flat_check_2 v${SCRIPT_VERSION})"
    info "$(_l workdir): $WORK_DIR"

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

    mapfile -t ALL_LOG_DIRS < <(discover_log_dirs_for_selected)
    # mapfile may leave one empty element when no output
    if [[ ${#ALL_LOG_DIRS[@]} -eq 1 && -z "${ALL_LOG_DIRS[0]:-}" ]]; then
        ALL_LOG_DIRS=()
    fi
    if [[ ${#ALL_LOG_DIRS[@]} -eq 0 ]]; then
        warn "$(_l err_no_logdirs)"
        safe_rm_work_dir "$WORK_DIR"
        return 1
    fi
    info "$(_l found_logdirs): ${#ALL_LOG_DIRS[@]}"
    for logdir in "${ALL_LOG_DIRS[@]}"; do
        info "  → $logdir"
    done

    local collect_infra=0
    [[ "$LOG_SCOPE" == "extended" ]] && collect_infra=1

    if [[ "$mode" == "online" ]]; then
        # Non-interactive online without -t would exit immediately after starting tails
        if [[ ! -t 0 && "$timeout_sec" -le 0 ]]; then
            safe_rm_work_dir "$WORK_DIR"
            die "$(_l err_online_need_t)"
        fi

        # Disk guard before spawning tails (check immediately inside start_disk_watch)
        start_disk_watch "$WORK_DIR"

        local logdir dest_name
        for logdir in "${ALL_LOG_DIRS[@]}"; do
            dest_name=$(_archive_subdir_name "$logdir")
            start_tail_for_dir "$logdir" "$WORK_DIR/$dest_name" "" "$dest_name"
        done
        if [[ "$collect_infra" -eq 1 ]]; then
            for sysfile in /var/log/messages /var/log/syslog; do
                [[ -f "$sysfile" ]] && start_tail_for_file "$sysfile" "$WORK_DIR/system" "system"
            done

            # Nginx logs for FLAT — collect if nginx is present (plain logs only online)
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
        info "$(_l log_stopping)"
        cleanup
    else
        # Offline: disk space guard (graceful stop + archive, same as online)
        start_disk_watch "$WORK_DIR"

        # Parse from/to for offline range collection
        local from_time="" to_time=""
        if [[ -n "$FROM_TIME" ]]; then
            from_time=$(parse_time_point "$FROM_TIME") || die "Invalid --from: '$FROM_TIME'"
        fi
        if [[ -n "$TO_TIME" ]]; then
            # Mixed mode: +3h with --from = from_time + 3 hours
            if [[ "$TO_TIME" =~ ^[+] && -n "$from_time" ]]; then
                local offset="${TO_TIME:1}"
                if ! parse_duration "$offset"; then
                    die "Invalid --to offset: '$TO_TIME'"
                fi
                local from_epoch add_sec
                from_epoch=$(date -d "$from_time" "+%s" 2>/dev/null)
                [[ -z "$from_epoch" ]] && die "Invalid --from for offset: '$FROM_TIME'"
                add_sec=$(duration_to_seconds "$PARSE_RESULT_NUM" "$PARSE_RESULT_UNIT")
                to_time=$(date -d "@$(( from_epoch + add_sec ))" "+%Y-%m-%d %H:%M:%S" 2>/dev/null)
                [[ -z "$to_time" ]] && die "Invalid --to offset: '$TO_TIME'"
            else
                to_time=$(parse_time_point "$TO_TIME") || die "Invalid --to: '$TO_TIME'"
            fi
        fi
        # Legacy: -t in offline mode = --from -${value}
        if [[ -z "$from_time" && -n "$timeout_raw" ]]; then
            from_time=$(parse_time_point "-${timeout_raw}") || true
        fi

        if [[ -n "$from_time" && -n "$to_time" ]]; then
            info "Extracting log lines from $from_time to $to_time (by content timestamp)"
        elif [[ -n "$from_time" ]]; then
            info "Extracting log lines from $from_time to now (by content timestamp)"
        else
            info "$(_l log_all)"
        fi
        info "Parallel copy workers: $(_collector_max_jobs) (host-wide CPU/MEM gate ${RESOURCE_CPU_LIMIT}%/${RESOURCE_MEM_LIMIT}%)"
        copy_all_log_dirs_parallel "$WORK_DIR" "$from_time" "$to_time"
        if [[ "$collect_infra" -eq 1 ]]; then
            for sysfile in /var/log/messages /var/log/syslog; do
                _collector_should_stop && break
                copy_system_log_by_range "$sysfile" "$WORK_DIR/system" "$from_time" "$to_time" "system"
            done

            # Nginx logs for FLAT — collect if nginx is present
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
        ok "$(_l log_copydone)"
    fi

    if [[ "$collect_infra" -eq 1 ]]; then
        collect_configs "$WORK_DIR"
    fi
    prune_empty_collected_files "$WORK_DIR"
    report_collected_log_stats "$WORK_DIR" "$mode"

    cd "$COLLECTOR_DIR" || die "Cannot enter $COLLECTOR_DIR"
    if command -v pigz &>/dev/null; then
        cores="$(nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || echo 2)"
        # Host-wide headroom: use (limit-20)% of cores so pigz alone stays under Zabbix-ish load
        cores=$(( cores * (${RESOURCE_CPU_LIMIT:-80} - 20) / 100 ))
        [[ "$cores" -lt 1 ]] && cores=1
        _get_cpu_usage_percent >/dev/null
        local _pigz_wait=0
        # Bounded wait only — never block archive forever on busy host
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
    echo ""
    ok "$(_l archive_at): $COLLECTOR_DIR/$ARCHIVE_NAME.tar.gz"
    info "$(_l done_msg)"
}

# --- 11. Wizard / help / argv / main -------------------------------------------

# Interactive product/service picker; sets SELECTED_PRODUCTS / SELECTED_SERVICES
_wizard_select_log_targets() {
    local -a prods=()
    local -A prod_pkgs=()
    local pkg prod i choice="" refine=""
    local -a idx_map=()
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

    echo ""
    echo "$(_l wiz_title_products)"
    i=1
    for prod in "${prods[@]}"; do
        echo "  $i — $prod (${prod_pkgs[$prod]})"
        idx_map+=("$prod")
        i=$((i + 1))
    done
    echo "$(_l wiz_products_all)"
    echo -n "$(_l wiz_products_prompt)"
    read -r choice 2>/dev/null || true
    choice="${choice:-a}"

    if [[ "$choice" == "a" || "$choice" == "A" || "$choice" == "а" || "$choice" == "А" ]]; then
        SELECTED_PRODUCTS=("${prods[@]}")
    else
        local part
        IFS=',' read -ra _parts <<< "$choice"
        for part in "${_parts[@]}"; do
            part="${part// /}"
            [[ -z "$part" ]] && continue
            if [[ "$part" =~ ^[0-9]+$ ]] && [[ "$part" -ge 1 && "$part" -le ${#idx_map[@]} ]]; then
                SELECTED_PRODUCTS+=("${idx_map[$((part - 1))]}")
            else
                warn "Invalid product choice: $part"
            fi
        done
        [[ ${#SELECTED_PRODUCTS[@]} -eq 0 ]] && SELECTED_PRODUCTS=("${prods[@]}")
    fi

    # Optional service refine: always offer when at least one product selected
    echo ""
    echo -n "$(_l wiz_refine_services)"
    read -r refine 2>/dev/null || true
    if [[ "$refine" == "y" || "$refine" == "Y" || "$refine" == "д" || "$refine" == "Д" ]]; then
        svc_list=()
        for prod in "${SELECTED_PRODUCTS[@]}"; do
            for pkg in ${prod_pkgs[$prod]}; do
                svc_list+=("$pkg")
            done
        done
        echo "$(_l wiz_title_services)"
        i=1
        idx_map=()
        for pkg in "${svc_list[@]}"; do
            echo "  $i — $pkg [${PKG_PRODUCT[$pkg]}]"
            idx_map+=("$pkg")
            i=$((i + 1))
        done
        echo "$(_l wiz_services_all)"
        echo -n "$(_l wiz_services_prompt)"
        read -r choice 2>/dev/null || true
        choice="${choice:-a}"
        SELECTED_PRODUCTS=()
        SELECTED_SERVICES=()
        if [[ "$choice" == "a" || "$choice" == "A" || "$choice" == "а" || "$choice" == "А" ]]; then
            SELECTED_SERVICES=("${svc_list[@]}")
        else
            IFS=',' read -ra _parts <<< "$choice"
            for part in "${_parts[@]}"; do
                part="${part// /}"
                [[ -z "$part" ]] && continue
                if [[ "$part" =~ ^[0-9]+$ ]] && [[ "$part" -ge 1 && "$part" -le ${#idx_map[@]} ]]; then
                    SELECTED_SERVICES+=("${idx_map[$((part - 1))]}")
                else
                    warn "Invalid service choice: $part"
                fi
            done
            [[ ${#SELECTED_SERVICES[@]} -eq 0 ]] && SELECTED_SERVICES=("${svc_list[@]}")
        fi
    fi

    resolve_selected_packages
    _resolve_mgcpclient_option
    echo ""
    info "$(_l wiz_preview_pkgs): ${#SELECTED_PKGS[@]}"
    for pkg in "${SELECTED_PKGS[@]+"${SELECTED_PKGS[@]}"}"; do
        info "  → $pkg"
    done
    local dirs=() d
    while IFS= read -r d; do
        [[ -n "$d" ]] && dirs+=("$d")
    done < <(discover_log_dirs_for_selected)
    info "$(_l wiz_preview_dirs): ${#dirs[@]}"
    for d in "${dirs[@]+"${dirs[@]}"}"; do
        info "  → $d"
    done
}

run_interactive_wizard() {
    # Reset modes so a prior -log/--dev on argv cannot leak into health-check choice
    MODE_LOG=0
    MODE_DEV=0
    SELFTEST_MODE=""
    # Init before read — set -u aborts on EOF if vars were never assigned
    local lang_choice="" mode_choice="" submode_choice="" scope_choice=""
    local tcpdump_choice="" range_choice="" repo_choice="" out_dir=""
    local selftest_choice=""

    # Step 1: Language
    echo ""
    echo "=== Language / Язык ==="
    echo "  1 — Русский"
    echo "  2 — English"
    echo -n "$(_l ask_lang_prompt)"
    read -r lang_choice 2>/dev/null || true
    if [[ "$lang_choice" == "1" ]]; then CURRENT_LANG="ru"; else CURRENT_LANG="en"; fi

    # Step 2: Mode
    echo ""
    echo "$(_l wiz_title_mode)"
    echo "$(_l wiz_mode_1)"
    echo "$(_l wiz_mode_2)"
    echo "$(_l wiz_mode_3)"
    echo -n "$(_l wiz_mode_prompt)"
    read -r mode_choice 2>/dev/null || true

    case "$mode_choice" in
        2)
            MODE_LOG=1
            MODE_DEV=0
            SELFTEST_MODE=""
            # Step 3: Online / Offline
            echo ""
            echo "$(_l wiz_title_type)"
            echo "$(_l wiz_type_1)"
            echo "$(_l wiz_type_2)"
            echo -n "$(_l wiz_type_prompt)"
            read -r submode_choice 2>/dev/null || true
            [[ "$submode_choice" == "2" ]] && LOG_SUBMODE="offline" || LOG_SUBMODE="online"

            # Scope: brief / extended
            echo ""
            echo "$(_l wiz_title_scope)"
            echo "$(_l wiz_scope_1)"
            echo "$(_l wiz_scope_2)"
            echo -n "$(_l wiz_scope_prompt)"
            read -r scope_choice 2>/dev/null || true
            [[ "$scope_choice" == "2" ]] && LOG_SCOPE="extended" || LOG_SCOPE="brief"

            # Time settings
            if [[ "$LOG_SUBMODE" == "online" ]]; then
                echo ""
                echo -n "$(_l wiz_timeout)"
                read -r TIMEOUT_RAW 2>/dev/null || true
                TIMEOUT_RAW="${TIMEOUT_RAW:-}"
                if [[ "$LOG_SCOPE" == "extended" ]]; then
                    echo -n "$(_l wiz_tcpdump)"
                    read -r tcpdump_choice 2>/dev/null || true
                    [[ "$tcpdump_choice" == "n" || "$tcpdump_choice" == "N" || "$tcpdump_choice" == "н" || "$tcpdump_choice" == "Н" ]] && START_TCPDUMP=0
                else
                    START_TCPDUMP=0
                fi
            else
                # Offline: range selection
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
            fi

            # Product / service selection
            detect_os
            _wizard_select_log_targets

            # Output directory
            echo -n "$(_l wiz_output_dir)"
            read -r out_dir 2>/dev/null || true
            [[ -n "$out_dir" ]] && OUTPUT_DIR="$out_dir"
            ;;
        3)
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
            ;;
        *)
            # Default: health check
            MODE_LOG=0
            MODE_DEV=0
            SELFTEST_MODE=""
            echo -n "$(_l wiz_show_repo)"
            read -r repo_choice 2>/dev/null || true
            [[ "$repo_choice" == "y" || "$repo_choice" == "Y" || "$repo_choice" == "д" || "$repo_choice" == "Д" ]] && SHOW_REPO=1
            ;;
    esac
}

usage() {
    cat <<'EOF'
flat_check_2.sh — FLAT/FCS health check + log collector

Usage: flat_check_2.sh [MODE] [OPTIONS]

Modes:
  (no args)               Health check (installed services only)
  -i, --interactive       Interactive wizard (language, mode, log options)
  --dev                   Extended self-test (variants + verbose health + seek/chunk)
  --selftest simple|extended
                          Self-test: simple = functions launch; extended = same as --dev
  -log                    Log collector mode
    -on, --online         Real-time capture (tail -F + optional tcpdump)
    -off, --offline       Copy/extract existing logs
    -t, --timeout DUR     Online: auto-stop after N (e.g. 5h, 30m)
                          Offline: extract lines from last N (by content timestamp)
    -f, --from TIME       Range start (e.g. -2h, 25.06.2026 10:00)
    -e, --to TIME         Range end (e.g. -1h, 25.06.2026 12:00)
                          Range: -f -2h -e -1h | -f '25.06.2026 10:00' -e '25.06.2026 12:00'
    -n, --no-tcpdump      Skip network capture (online only)
    -j, --jobs N          Offline: parallel file copy workers (default: nproc*80%, max 32)
    --scope brief|extended  Brief = selected services only (default);
                          extended = + system/nginx/postgresql/configs (+ tcpdump online)
    -p, --product NAME    Product to collect (repeatable; see --list-targets)
    -s, --service PKG     Service/package to collect (repeatable)
    --list-targets        List products/services present on host and exit
    --mgcpclient          SoftSwitch: include mgcpclient logs (no prompt)
    --no-mgcpclient       SoftSwitch: skip mgcpclient logs (no prompt)
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
  SoftSwitch: prompts for mgcpclient (or use --mgcpclient / --no-mgcpclient).
  When skipped: excludes mgcpclient* files inside service dirs (e.g. fss-server) as well.
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

Examples:
  ./flat_check_2.sh                    # Health check only
  ./flat_check_2.sh -i                 # Interactive wizard
  ./flat_check_2.sh -log --list-targets
  ./flat_check_2.sh -log -off -t 2h --scope brief -p SoftSwitch --no-mgcpclient
  ./flat_check_2.sh -log -off -f -1d --scope extended -s fcs-swui
  ./flat_check_2.sh -log -on -t 30m --scope brief -p "Contact Center" -s acs-server
  ./flat_check_2.sh -v                 # Print version
  ./flat_check_2.sh --selftest simple  # Quick self-test
  ./flat_check_2.sh --dev              # Extended self-test

---

flat_check_2.sh — проверка FLAT/FCS + сборщик логов

Использование: flat_check_2.sh [РЕЖИМ] [ОПЦИИ]

Режимы:
  (без аргументов)        Проверка установленных служб
  -i, --interactive       Интерактивный мастер (язык, режим, параметры логов)
  --dev                   Расширенный самотест (варианты + health + seek/chunk)
  --selftest simple|extended
                          Самотест: simple = запуск функций; extended = как --dev
  -log                    Режим сборщика логов
    -on, --online         Сбор в реальном времени (tail -F + опц. tcpdump)
    -off, --offline       Копирование/извлечение готовых логов
    -t, --timeout ДЛИТ    Online: автостоп через N (например 5h, 30m)
                          Offline: извлечь строки за последние N (по метке в файле)
    -f, --from TIME       Начало диапазона (например -2h, 25.06.2026 10:00)
    -e, --to TIME         Конец диапазона (например -1h, 25.06.2026 12:00)
    -n, --no-tcpdump      Не записывать сетевой трафик (только online)
    -j, --jobs N          Offline: число параллельных копий файлов (по умолч. nproc*80%, макс. 32)
    --scope brief|extended  Краткий = только выбранные службы (по умолч.);
                          расширенный = + system/nginx/postgresql/configs (+ tcpdump online)
    -p, --product NAME    Продукт (повторяемый; см. --list-targets)
    -s, --service PKG     Служба/пакет (повторяемый)
    --list-targets        Показать продукты/службы на хосте и выйти
    --mgcpclient          SoftSwitch: включить логи mgcpclient (без вопроса)
    --no-mgcpclient       SoftSwitch: не собирать mgcpclient (без вопроса)
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
  SoftSwitch: спрашивает про mgcpclient (или --mgcpclient / --no-mgcpclient).
  При отказе: исключает и файлы mgcpclient* внутри каталогов служб (например fss-server).
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

Примеры:
  ./flat_check_2.sh                    # Только проверка
  ./flat_check_2.sh -i                 # Интерактивный мастер
  ./flat_check_2.sh -log --list-targets
  ./flat_check_2.sh -log -off -t 2h --scope brief -p SoftSwitch --no-mgcpclient
  ./flat_check_2.sh -log -off -f -1d --scope extended -s fcs-swui
  ./flat_check_2.sh -log -on -t 30m --scope brief -p "Contact Center"
  ./flat_check_2.sh -v                 # Версия
  ./flat_check_2.sh --selftest simple  # Быстрый самотест
  ./flat_check_2.sh --dev              # Расширенный самотест
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
                echo "flat_check_2 ${SCRIPT_VERSION}"
                exit 0
                ;;
            --dev)
                SELFTEST_MODE="extended"
                MODE_DEV=1
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
                TIMEOUT_RAW="$2"; shift 2
                ;;
            -f|--from)
                if [[ -z "${2:-}" ]]; then die "Missing value for $1"; fi
                FROM_TIME="$2"; shift 2
                ;;
            -e|--to)
                if [[ -z "${2:-}" ]]; then die "Missing value for $1"; fi
                TO_TIME="$2"; shift 2
                ;;
            -n|--no-tcpdump)
                START_TCPDUMP=0; shift
                ;;
            -j|--jobs)
                if [[ -z "${2:-}" || "$2" == -* ]]; then die "Missing value for $1"; fi
                if ! [[ "$2" =~ ^[1-9][0-9]*$ ]]; then die "Invalid -j/--jobs value: '$2' (positive integer)"; fi
                COLLECTOR_JOBS="$2"; shift 2
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
                if [[ -z "${2:-}" || "$2" == -* ]]; then die "Missing value for $1"; fi
                SELECTED_PRODUCTS+=("$2"); shift 2
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
                SHOW_REPO=1; shift
                ;;
            -o|--output)
                if [[ -z "${2:-}" || "$2" == -* ]]; then die "Missing value for $1"; fi
                OUTPUT_DIR="$2"; shift 2
                ;;
            -h|--help)
                usage
                ;;
            *)
                die "Unknown option: $1 (try -h)"
                ;;
        esac
    done
}

main() {
    parse_args "$@"

    # -i: interactive wizard
    if [[ $MODE_INTERACTIVE -eq 1 ]]; then
        run_interactive_wizard
    fi

    if [[ $LIST_TARGETS -eq 1 ]]; then
        detect_os
        list_log_targets
        exit 0
    fi

    # Self-test: --dev / --selftest / wizard mode 3
    if [[ -n "${SELFTEST_MODE:-}" ]]; then
        run_selftest "$SELFTEST_MODE"
        exit $?
    fi
    if [[ $MODE_DEV -eq 1 ]]; then
        run_selftest extended
        exit $?
    fi

    # -log: log collection only
    if [[ $MODE_LOG -eq 1 ]]; then
        run_log_collection "$LOG_SUBMODE" "$TIMEOUT_RAW"
        [[ $SHOW_REPO -eq 1 ]] && { detect_os; check_repositories; }
        exit 0
    fi

    # DEFAULT: health check only (original flat_check behavior)
    detect_os
    check_system
    local products=("AutoCallServer" "BSS" "Click to Call" "Contact Center" "Device Manager" "Gateway" "Partner Server" "SoftSwitch" "Tarifficator" "IVR" "LC" "SMS" "LDAP" "SBC" "Portal" "flat-file")
    for p in "${products[@]}"; do run_product_checks "$p"; done
    check_infrastructure
    [[ $SHOW_REPO -eq 1 ]] && check_repositories
    print_summary
}

main "$@"
