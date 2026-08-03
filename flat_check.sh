#!/bin/bash
# Universal FLAT / FCS Health Check Script
# Supports: Debian/Ubuntu (dpkg), RHEL/CentOS/ALMA/Rocky (rpm), and systemd environments

set -o pipefail

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

# ========== Product: AutoCallServer ==========
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

# ============================================================
# Helpers
# ============================================================

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

# Detect OS and package manager
detect_os() {
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        OS_NAME="$NAME"
        OS_ID="$ID"
        OS_VERSION="$VERSION_ID"
    else
        OS_NAME="Unknown"
        OS_ID="unknown"
        OS_VERSION=""
    fi

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

    print_info "OS: $OS_NAME ($OS_ID $OS_VERSION)"
    print_info "Package manager: $PM"
    echo ""
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

    if [[ -n "${ALL_DEPENDS[$dep]}" ]]; then
        if [[ ",${ALL_DEPENDS[$dep]}," != *",$pkg,"* ]]; then
            ALL_DEPENDS[$dep]="${ALL_DEPENDS[$dep]},$pkg"
        fi
    else
        ALL_DEPENDS[$dep]="$pkg"
    fi
}

# Check if package is installed using PM (verbose, prints status)
check_pkg_installed() {
    local pkg="$1"
    local legacy="$2"
    local found=""
    local ver=""
    local status=""

    FOUND_PKG_VER=""
    FOUND_PKG_STATUS=""

    if [[ "$PM" == "dpkg" ]]; then
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
    elif [[ "$PM" == "rpm" ]]; then
        if rpm -q "$pkg" &>/dev/null; then
            ver=$(rpm -q --queryformat '%{VERSION}-%{RELEASE}' "$pkg" 2>/dev/null)
            FOUND_PKG_VER="$ver"
            print_ok "pkg: $pkg installed"
            return 0
        fi
    elif [[ "$PM" == "pacman" ]]; then
        if pacman -Q "$pkg" &>/dev/null; then
            ver=$(pacman -Q "$pkg" 2>/dev/null | awk '{print $2}')
            FOUND_PKG_VER="$ver"
            print_ok "pkg: $pkg installed"
            return 0
        fi
    elif [[ "$PM" == "apk" ]]; then
        if apk info -e "$pkg" &>/dev/null; then
            print_ok "pkg: $pkg installed"
            return 0
        fi
    fi

    # Check legacy names
    if [[ -n "$legacy" ]]; then
        local old
        for old in $(echo "$legacy" | tr ',' ' '); do
            if [[ "$PM" == "dpkg" ]]; then
                found=$(dpkg-query -W -f='${Package}\t${Version}\t${Status}\n' "$old" 2>/dev/null)
                if [[ -n "$found" ]]; then
                    ver=$(echo "$found" | awk '{print $2}')
                    status=$(echo "$found" | awk '{$1=""; $2=""; print $0}' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
                    FOUND_PKG_VER="$ver"
                    FOUND_PKG_STATUS="$status"
                    print_warn "pkg: $pkg not found, but legacy '$old' exists ($ver)"
                    return 2
                fi
            elif [[ "$PM" == "rpm" ]]; then
                if rpm -q "$old" &>/dev/null; then
                    ver=$(rpm -q --queryformat '%{VERSION}-%{RELEASE}' "$old" 2>/dev/null)
                    FOUND_PKG_VER="$ver"
                    print_warn "pkg: $pkg not found, but legacy '$old' exists ($ver)"
                    return 2
                fi
            elif [[ "$PM" == "pacman" ]]; then
                if pacman -Q "$old" &>/dev/null; then
                    ver=$(pacman -Q "$old" 2>/dev/null | awk '{print $2}')
                    FOUND_PKG_VER="$ver"
                    print_warn "pkg: $pkg not found, but legacy '$old' exists ($ver)"
                    return 2
                fi
            elif [[ "$PM" == "apk" ]]; then
                if apk info -e "$old" &>/dev/null; then
                    print_warn "pkg: $pkg not found, but legacy '$old' exists"
                    return 2
                fi
            fi
        done
    fi

    print_fail "pkg: $pkg not installed"
    return 3
}

has_any_trace() {
    local pkg="$1"
    local unit="${pkg}.service"
    [[ -f "/usr/lib/systemd/system/${unit}" ]] || [[ -f "/etc/systemd/system/${unit}" ]] || [[ -f "/lib/systemd/system/${unit}" ]] || [[ -d "/opt/flat/${pkg}" ]]
}

# Silent quick check if package is installed (returns 0/1, no output)
is_pkg_installed_tiny() {
    local pkg="$1"
    local legacy="$2"

    if [[ "$PM" == "dpkg" ]]; then
        dpkg-query -W -f='${Status}\n' "$pkg" 2>/dev/null | grep -q 'install ok installed' && return 0
        if [[ -n "$legacy" ]]; then
            for old in $(echo "$legacy" | tr ',' ' '); do
                dpkg-query -W -f='${Status}\n' "$old" 2>/dev/null | grep -q 'install ok installed' && return 0
            done
        fi
    elif [[ "$PM" == "rpm" ]]; then
        rpm -q "$pkg" &>/dev/null && return 0
        if [[ -n "$legacy" ]]; then
            for old in $(echo "$legacy" | tr ',' ' '); do
                rpm -q "$old" &>/dev/null && return 0
            done
        fi
    elif [[ "$PM" == "pacman" ]]; then
        pacman -Q "$pkg" &>/dev/null && return 0
        if [[ -n "$legacy" ]]; then
            for old in $(echo "$legacy" | tr ',' ' '); do
                pacman -Q "$old" &>/dev/null && return 0
            done
        fi
    elif [[ "$PM" == "apk" ]]; then
        apk info -e "$pkg" &>/dev/null && return 0
    fi

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
    local ports_spec="${PKG_PORTS[$pkg]}"

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
    local endpoint="${PKG_API[$pkg]}"
    local ports_spec="${PKG_PORTS[$pkg]}"

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

# Single package check (respects VERBOSE)
check_single_pkg() {
    local pkg="$1"
    local legacy="${PKG_LEGACY[$pkg]}"

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

    # Print and collect dependencies
    local deps_meta="${PKG_DEPS[$pkg]}"
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

# Run checks for a single product
run_product_checks() {
    local product="$1"
    local installed_count=0
    local total_count=0
    local product_pkgs=()

    for pkg in "${!PKG_PRODUCT[@]}"; do
        if [[ "${PKG_PRODUCT[$pkg]}" == "$product" ]]; then
            product_pkgs+=("$pkg")
            ((total_count++))
            if is_pkg_installed_tiny "$pkg" "${PKG_LEGACY[$pkg]}"; then
                ((installed_count++))
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
    for pkg in "${product_pkgs[@]}"; do
        check_single_pkg "$pkg"
    done
}

# Check if a shared library file exists in standard lib paths
is_lib_available() {
    local lib="$1"
    for path in /usr/lib64 /lib64 /usr/lib /lib; do
        [[ -f "$path/$lib" ]] && return 0
    done
    return 1
}

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
        local req_by="${ALL_DEPENDS[$dep]}"
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

check_repositories() {
    echo ""
    echo "=== Repositories ==="

    if [[ "$PM" == "dpkg" ]]; then
        # APT sources
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

        # APT priorities via apt-cache policy (if available)
        if command -v apt-cache &>/dev/null; then
            local policy
            policy=$(apt-cache policy 2>/dev/null | grep -E '^\s+[0-9]+' | head -20)
            if [[ -n "$policy" ]]; then
                echo ""
                print_info "APT priorities:"
                echo "$policy" | while IFS= read -r line; do
                    print_info "  $line"
                done
            fi
        fi

    elif [[ "$PM" == "rpm" ]]; then
        # YUM/DNF repos
        if command -v yum &>/dev/null; then
            local repolist
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
    fi
}

# Summary
print_summary() {
    echo ""
    echo "=== Summary ==="
    print_info "Installed: $INSTALLED | Errors: $ERRORS | Warnings: $WARNINGS"
}

# Main execution
main() {
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --info|-info|-i)
                VERBOSE=1
                shift
                ;;
            --repo|-repo|-r)
                SHOW_REPO=1
                shift
                ;;
            --no-info)
                VERBOSE=0
                shift
                ;;
            --help|-h|-help)
                cat <<'EOF'
Usage: ./flat_check.sh [OPTIONS]

  -i, --info          Show detailed info for all packages (including not installed)
  -r, --repo          Show repositories (APT/YUM sources)
  --no-info           Show only installed packages and product summary (default)

  -h, --help, -help   Show this help message

Examples:
  ./flat_check.sh                    # Default: show only installed packages
  ./flat_check.sh -i                 # Show all packages with full details
  ./flat_check.sh -i -r              # Show all packages + repositories
  ./flat_check.sh > report.log       # Save output to file

Reading output:
  [OK]    — check passed successfully
  [WARN]  — attention required, but not critical (e.g. old logs, inactive service)
  [FAIL]  — error, needs correction (e.g. missing package, missing dependency)
  [INFO]  — reference information (e.g. version, symlink target, owner)

Hierarchy:
  === Product ===     — product header (e.g. === SoftSwitch ===)
  =package=           — package header inside a product (e.g. =fss-server=)

Log directory notes:
  - If /var/log/flat/<pkg> is a symlink, the target path is shown in [INFO]
  - "fresh logs"     — files modified within last 5 hours
  - "old logs"       — files exist but older than 5 hours; if process is active, [WARN]
  - "empty" / "missing" — [INFO] if process is inactive, [WARN] if process is active

Использование: ./flat_check.sh [ОПЦИИ]

  -i, --info          Показать детальную информацию для всех пакетов (включая неустановленные)
  -r, --repo          Показать репозитории (APT/YUM sources)
  --no-info           Показать только установленные пакеты (по умолчанию)

  -h, --help, -help   Показать эту справку

Примеры:
  ./flat_check.sh                    # По умолчанию: только установленные пакеты
  ./flat_check.sh -i                 # Все пакеты с полной детализацией
  ./flat_check.sh -i -r              # Все пакеты + репозитории
  ./flat_check.sh > report.log       # Сохранить вывод в файл

Чтение вывода:
  [OK]    — проверка пройдена успешно
  [WARN]  — требует внимания, но не критично (например, старые логи, неактивный сервис)
  [FAIL]  — ошибка, требует исправления (например, отсутствует пакет или зависимость)
  [INFO]  — справочная информация (например, версия, цель symlink, владелец)

Иерархия:
  === Продукт ===     — заголовок продукта (например, === SoftSwitch ===)
  =пакет=             — заголовок пакета внутри продукта (например, =fss-server=)

Примечания по логам:
  - Если /var/log/flat/<pkg> — symlink, целевой путь показывается в [INFO]
  - "fresh logs"     — файлы изменены менее чем 5 часов назад
  - "old logs"       — файлы есть, но старше 5 часов; если процесс активен — [WARN]
  - "empty" / "missing" — [INFO] если процесс неактивен, [WARN] если процесс активен
EOF
                exit 0
                ;;
            *)
                echo "Unknown option: $1" >&2
                echo "Usage: $0 [--info|-i] [--repo|-r] [--no-info]" >&2
                exit 1
                ;;
        esac
    done

    detect_os

    # Run product checks
    local products=("AutoCallServer" "BSS" "Click to Call" "Contact Center" "Device Manager" "Gateway" "Partner Server" "SoftSwitch" "Tarifficator" "IVR" "LC" "SMS" "LDAP" "SBC" "Portal" "flat-file")
    for p in "${products[@]}"; do
        run_product_checks "$p"
    done

    # Infrastructure (collected dependencies)
    check_infrastructure

    # Repositories (if requested)
    if [[ $SHOW_REPO -eq 1 ]]; then
        check_repositories
    fi

    print_summary
}

main "$@"
