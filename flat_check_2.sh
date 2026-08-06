#!/bin/bash
# flat_check_2.sh — проверка состояния FLAT/FCS + сборщик логов
#
# Health-only вариант (без сборщика логов) — flat_check.sh.
# JSON v2 / agent (--json/--push/--config/--pkg) — 1к1 с flat_check.sh;
# сборщик логов (-log) — только в этом файле.
#
# Работает на: Debian/Ubuntu, RHEL/CentOS/ALMA/Rocky/РЕД ОС, Astra, … (dpkg/rpm + systemd)
#
# Режимы:
#   (по умолчанию) проверка установленных служб
#   -log -on/-off сбор логов (online tail / offline параллельное копирование+фильтр по времени)
#                 --scope brief|extended, -p продукт, -s служба
#   -i            интерактивный мастер
#   --dev / --selftest  самотест скрипта (simple|extended)
#   -v            вывести версию
#
# Offline-фильтр по диапазону времени отбирает СТРОКИ по timestamp внутри файла (не по mtime).
# Крупные ordinary логи (>=1MB): seek (sorted/soft) + параллельное сканирование окна по чанкам.
# Основная цель — монолиты SoftSwitch fss-server (десятки ГБ).
# .gz: coarse → hour/day zgrep → один stream-extract (early-stop); без лишнего 12-point.
# TUNABLES в блоке 0 — правьте перед запуском (host CPU/MEM 80% — для Zabbix, не трогать).
#
# Внутренняя структура (искать "# --- N."):
#   0  глобальные переменные / флаги (включая SCRIPT_DIR/LOG_FILE)
#   1  метаданные продуктов PKG_*
#   2  хелперы вывода + логирование в файл (_log_line/log_debug/init_logging) + локализация
#   3  ОС / пакетный менеджер
#   3b системные метрики (CPU/MEM/диск/БД/сеть/сертификаты/аптайм)
#   4  проверки состояния по пакетам
#   5  инфраструктура + репозитории
#   6  поиск директорий логов (по выбранным пакетам/продуктам)
#   7  поиск логов PostgreSQL
#   8b автономное извлечение диапазона из ОДНОГО лог-файла (parce_service_log)
#   8c извлечение диапазона из логов СЛУЖБЫ по имени, целиком (parce_service_logs)
#   8d те же примитивы (8b/8c), применённые к каталогам, которые уже нашёл блок 6 —
#      общий движок поиска+копирования логов для online и offline (run_log_collection)
#   8  парсеры длительности/момента времени + построчные фильтры по timestamp
#   9  процессы сборщика / сигналы / безопасное удаление
#  10  online / offline сбор (run_log_collection)
#  11  мастер, справка, argv, main
#
# Лог сессии: каждый запуск пишет ${SCRIPT_NAME}.log (LOG_FILE, см. блок 2) —
#   аргументы/выбор мастера, что найдено/отклонено при поиске логов, снимки
#   CPU/MEM. При -log он переносится внутрь рабочей директории и попадает в
#   архив; иначе — лежит рядом со скриптом (или в -o/--output) и
#   перезаписывается на каждом запуске.
#
# Безопасность при работе от root: временные директории удаляются только если совпадают
#   с шаблоном YYYY.MM.DD_HH-MM_*  внутри выходной директории сборщика.
# Никогда не использовать голый rm -rf на произвольных путях из CLI-ввода.

SCRIPT_VERSION="3.10.4"

set -uo pipefail

# --- 0. Глобальные переменные ---------------------------------------------------

# Путь и имя скрипта — нужны и до parse_args (лог-файл сессии), и внутри
# run_log_collection() (рабочая директория по умолчанию); вычисляем один раз.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
[[ -z "$SCRIPT_DIR" ]] && SCRIPT_DIR="$(pwd)"
SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
SCRIPT_NAME="${SCRIPT_NAME%.sh}"

# Путь текущего сессионного лог-файла (<SCRIPT_NAME>.log); "" = логирование в
# файл отключено (нет прав на запись). Заполняется init_logging(), уровни
# пишутся через _log_line() из ok()/warn()/fail()/info()/print_*()/log_debug().
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

# Флаги режима сборщика логов
MODE_LOG=0
MODE_DEV=0
MODE_INTERACTIVE=0
# Самотест: "" | simple | extended  (--dev = extended; в мастере уровень выбирается в режиме 3)
SELFTEST_MODE=""
LOG_SUBMODE="online"
START_TCPDUMP=1
TIMEOUT_RAW=""
FROM_TIME=""
TO_TIME=""
# CLI: порядок/контекст -t (last-N) vs -f/-t (from/to)
CLI_TIMEOUT_SET=0
CLI_FROM_SET=0
CLI_TO_SET=0
CLI_T_AS_TO=0
CLI_TIMEOUT_BEFORE_FROM=0
# Мастер: n/нет/none на шаге выбора → не собирать логи
WIZARD_SKIP_LOG=0
OUTPUT_DIR=""
# Выбор логов: brief = только логи приложений; extended = + system/nginx/pg/конфиги (+ tcpdump online)
LOG_SCOPE="brief"
SELECTED_PRODUCTS=()   # имена продуктов из -p / мастера
SELECTED_SERVICES=()   # имена пакетов из -s / мастера
SELECTED_PKGS=()       # итоговый список пакетов для сбора
LIST_TARGETS=0
# Доп. для SoftSwitch: включать логи mgcpclient (""=спросить, 0=нет, 1=да)
INCLUDE_MGCPCLIENT=""
MGCPCLIENT_RESOLVED=0
# 1 = собирать только выбранные типы логов (стемы) по каждой службе
LOG_TYPE_FILTER=0
# pkg → "*" (все типы) или стемы через пробел (abonentsclass, sipdump, mgcpclient, …)
declare -A SELECTED_LOG_TYPES=()
# абсолютный каталог логов → владеющий пакет (для фильтра типов)
declare -A LOG_DIR_OWNER=()
SKIP_UNKNOWN_FLAT_REPORTED=0
EXTRA_LOG_DIRS=()      # доп. директории вне списка PKG (например, mgcpclient)

# Локализация
CURRENT_LANG="en"

# Отслеживание процессов (режим логов)
TAIL_PIDS=()
COLLECTOR_JOB_PIDS=()
TCPDUMP_PID=""
TIMEOUT_KILL_PID=""
DISK_WATCH_PID=""
RESOURCE_WATCH_PID=""
DISCOVERED_LOG_DIRS=()
PG_LOG_SOURCES=()
COLLECTOR_ABORTED=0
COLLECTOR_TIMEOUT_STOP=0

# =============================================================================
# TUNABLES — правьте здесь перед запуском (CLI/мастер перекрывают только часть).
# Host-wide CPU/MEM gate специально для Zabbix: не поднимать «под скрипт».
# =============================================================================

# --- ресурсы хоста (не доля скрипта) -----------------------------------------
# Offline параллельное копирование: 0 = авто (nproc * RESOURCE_CPU_LIMIT/100)
COLLECTOR_JOBS=0
# Общесистемный лимит CPU/MEM: придерживать лишние воркеры, когда ВСЯ
# система достигла этих лимитов (/proc). Минимум 1 воркер всегда разрешён.
RESOURCE_CPU_LIMIT=80
RESOURCE_MEM_LIMIT=80
# Макс. секунд ожидания запаса ресурсов перед ещё одним воркером (≥1 уже работает)
RESOURCE_WAIT_MAX=120
# Как часто фоновый монитор ресурсов пишет снимок CPU/MEM в лог сессии
RESOURCE_LOG_INTERVAL_SEC=30

# --- seek / параллельное извлечение plain ------------------------------------
# Минимальный размер для бисекции + параллельного извлечения чанков
SEEK_MIN_BYTES=$((1 * 1024 * 1024))
# Монолиты масштаба SoftSwitch: увеличенное окно параллелизма
SEEK_HUGE_BYTES=$((1024 * 1024 * 1024))
# Размер чанка параллельного сканирования внутри байтового диапазона [from,to]
SEEK_CHUNK_BYTES=$((64 * 1024 * 1024))
# Проба-чанк для выборки timestamp по смещению
SEEK_PROBE_BYTES=131072
# Отступ перед начальным смещением (строгий sorted)
SEEK_BACKOFF_BYTES=$((1024 * 1024))
# Отступ для soft-sorted (середина «плавает», но first≤last) — шире, без early-stop
SEEK_SOFT_SORT_BACKOFF_BYTES=$((32 * 1024 * 1024))
# Внутренняя гранулярность параллельного извлечения ОДНОГО файла в
# parce_service_log() (не итоговый part_*.log — см. LOG_CHUNK_*).
MAX_LOG_CHUNK_SIZE=$((100 * 1024 * 1024))

# --- offline archive filter / stream extract ---------------------------------
# Грубый day-отсев: ±1 календарный день (NYE / TZ)
LOG_RANGE_DAY_MARGIN_SEC=$((24 * 3600))
# Макс. число дней для zgrep-паттернов по календарным датам
LOG_ZGREP_MAX_DAYS=32
# Макс. число часов для hour-level zgrep-паттернов
LOG_ZGREP_MAX_HOURS=48
# При длине диапазона ≤ этого — hour-level zgrep (−m 1); miss → skip файла
LOG_ZGREP_HOUR_MAX_SEC=$((24 * 3600))
# Короткое окно: не читать stem.N.gz, если живой stem покрывает [from,to]
LOG_PLAIN_COVERS_ROTATED_MAX_SEC=$((24 * 3600))
# После zgrep-miss не гонять 12-point full-decompress (dated → skip;
# undated без инструмента → один extract). 0 = старое поведение (12-point).
LOG_ARCHIVE_SKIP_PROBE_ON_ZGREP_MISS=1
# Stream-extract архива: early-stop после to (+ grace), как у sorted plain
LOG_ARCHIVE_STREAM_SORTED=1
# Допуск (сек) после to перед early-stop — мелкий reorder потоков SoftSwitch
LOG_ARCHIVE_EARLY_STOP_GRACE_SEC=300

# --- итоговая нарезка part_*.log (offline; CLI/мастер тоже задают) ------------
LOG_CHUNK_MODE="size"
LOG_CHUNK_SIZE_BYTES=$((100 * 1024 * 1024))
LOG_CHUNK_LINES=500000

# Снимок /proc/stat для расчёта дельты CPU
_CPU_PREV_IDLE=""
_CPU_PREV_TOTAL=""
# Прогресс offline-extract (файлы состояния между parallel dir-jobs)
_COLLECT_PROGRESS_DIR=""
_COLLECT_PROGRESS_TOTAL=0

# Epoch полуночи дня файла, который сейчас разбирает line_epoch() (awk, см.
# _AWK_LINE_EPOCH) — нужен только логам без даты в самой строке (только
# HH:MM:SS, дата — в имени файла). Выставляется _infer_file_midnight_epoch()
# в начале обработки каждого файла (parce_service_log(),
# filter_log_file_by_range()); "" — не относится к текущему файлу /
# определить не удалось.
_LOG_REF_MIDNIGHT_EPOCH=""

# Пути к конфигам для извлечения логов
CONFIG_PATHS=(
    "/opt/flat/switchserver/settings.ini"
    "/opt/flat/fss-server/settings.ini"
    "/etc/flat/srclient/settings.ini"
    "/opt/flat/fss-srclient/settings.ini"
    "/etc/mediasrv/config.xml"
    "/opt/flat/fss-mediasrv/config.xml"
    "/opt/flat/flat-file/config.yml"
)

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

# Технические подробности только в файл лога (что найдено/отклонено при
# поиске логов, снимки CPU/MEM и т.п.) — не выводятся на экран, чтобы не
# перегружать интерактивный вывод и терминал пользователя.
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

# Переносит уже накопленный лог сессии (аргументы, выбор мастера — всё, что
# случилось до создания WORK_DIR) внутрь рабочей директории сборщика, чтобы
# он попал в архив вместе с собранными логами, и продолжает писать туда же.
relocate_log_to_workdir() {
    local old_log="${LOG_FILE:-}"
    local new_log="${WORK_DIR%/}/${SCRIPT_NAME}.log"
    if [[ -n "$old_log" && -f "$old_log" && "$old_log" != "$new_log" ]]; then
        if ! mv -- "$old_log" "$new_log" 2>/dev/null; then
            cp -- "$old_log" "$new_log" 2>/dev/null && rm -f -- "$old_log" 2>/dev/null
        fi
    fi
    LOG_FILE="$new_log"
    { : >> "$LOG_FILE"; } 2>/dev/null || LOG_FILE=""
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

# Короткие псевдонимы для сборщика логов
ok()  { echo -e "${C_G}[OK]${C_N}  $1"; _log_line "OK" "$1"; }
warn() { echo -e "${C_Y}[WARN]${C_N} $1"; _log_line "WARN" "$1"; }
fail() { echo -e "${C_R}[FAIL]${C_N} $1"; _log_line "FAIL" "$1"; }
info() { echo -e "${C_B}[INFO]${C_N} $1"; _log_line "INFO" "$1"; }

die() { fail "$1"; cleanup 2>/dev/null; exit 1; }

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

# --- 7. Поиск логов PostgreSQL ---------------------------------------------------
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

# Ждём, пока пользователь не остановит online-сбор (Enter) или не придёт TERM (timeout / диск-guard).
# Вызывающий код должен обеспечить, что non-TTY online имеет timeout_sec > 0 перед запуском tail'ов.
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

# Общее тело awk: парсинг timestamp → epoch (YYYY-MM-DD / DD.MM.YYYY, плюс
# запасной вариант для строк вообще без даты — только HH:MM:SS, см. ниже).
# Ожидает опциональную awk-переменную ref_midnight (epoch полуночи дня,
# к которому относится файл — задаётся через -v вызывающим кодом на основе
# _LOG_REF_MIDNIGHT_EPOCH, см. _infer_file_midnight_epoch()).
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
    # Некоторые логгеры FLAT (например fcs-swau) пишут в каждой строке только
    # время (HH:MM:SS[:мс]) без даты — дата целиком в имени файла
    # (YYYY_MM_DD_*.log). ref_midnight (epoch 00:00:00 дня файла) передаётся
    # вызывающим кодом через -v; без него строки такого формата неотличимы
    # от "нет метки времени вообще", как и раньше.
    if (ref_midnight > 0 && match(line, /^[0-9]{2}:[0-9]{2}:[0-9]{2}/)) {
        ts = substr(line, RSTART, RLENGTH)
        n = split(ts, p, ":")
        if (n >= 3) return ref_midnight + p[1] * 3600 + p[2] * 60 + p[3]
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

# Печатает epoch полуночи (00:00:00) календарного дня, к которому относится
# файл — для логов, где каждая строка содержит только время (HH:MM:SS), без
# даты, а дата зашита только в имени файла (обычная схема для ежедневно
# ротируемых логов вида YYYY_MM_DD_*.log, например fcs-swau/*.log). Сначала
# пробует распознать дату в имени файла (YYYY_MM_DD, YYYY-MM-DD,
# DD.MM.YYYY, DD_MM_YYYY); если в имени файла даты нет — использует дату
# mtime файла как разумное приближение. Пусто, если и это не удалось.
_infer_file_midnight_epoch() {
    local file="$1" base date_str="" epoch mtime
    base=$(basename -- "$file")

    if [[ "$base" =~ ([0-9]{4})[_-]([0-9]{2})[_-]([0-9]{2}) ]]; then
        date_str="${BASH_REMATCH[1]}-${BASH_REMATCH[2]}-${BASH_REMATCH[3]}"
    elif [[ "$base" =~ ([0-9]{2})[._]([0-9]{2})[._]([0-9]{4}) ]]; then
        date_str="${BASH_REMATCH[3]}-${BASH_REMATCH[2]}-${BASH_REMATCH[1]}"
    fi

    if [[ -n "$date_str" ]]; then
        epoch=$(date -d "$date_str 00:00:00" "+%s" 2>/dev/null)
        [[ "$epoch" =~ ^[0-9]+$ ]] && { echo "$epoch"; return 0; }
    fi

    mtime=$(stat -c '%Y' "$file" 2>/dev/null) || return 1
    date_str=$(date -d "@$mtime" '+%Y-%m-%d' 2>/dev/null)
    [[ -n "$date_str" ]] || return 1
    epoch=$(date -d "$date_str 00:00:00" "+%s" 2>/dev/null)
    [[ "$epoch" =~ ^[0-9]+$ ]] && echo "$epoch"
}

# Epoch одной строки лога (-1, если нет)
_epoch_of_line() {
    local line="$1" ep
    [[ -z "$line" ]] && { echo -1; return; }
    # Логи SoftSwitch могут содержать NUL / не-UTF8; убираем перед bash/awk
    line="${line//$'\0'/}"
    # Избегаем SIGPIPE+pipefail, когда awk завершается после одной строки
    ep=$(set +o pipefail
        printf '%s\n' "$line" | LC_ALL=C awk -v ref_midnight="${_LOG_REF_MIDNIGHT_EPOCH:-0}" \
            "$_AWK_LINE_EPOCH"' { print line_epoch($0); exit }')
    echo "${ep:--1}"
}

# Прочитать одну полную строку в/после байтового смещения (не сканирует остаток файла)
_probe_line_at_offset() {
    local file="$1" off="$2" line
    local probe="${SEEK_PROBE_BYTES:-131072}"
    if [[ "$off" -le 0 ]]; then
        # tr убирает NUL, чтобы command substitution не выдавал предупреждение
        head -n 1 "$file" 2>/dev/null | tr -d '\0'
        return 0
    fi
    # Поток dd→tr→awk: никогда не храним сырую пробу (с NUL) в bash-переменной
    # LC_ALL=C: избегаем "Invalid multibyte data" на почти-бинарных срезах лога
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

# Три пробы epoch (начало / середина / почти-конец). Печатает "e1 e2 e3" или "".
_logs_probe_epochs() {
    local file="$1" size="$2"
    local e1 e2 e3 near_end line1 line2 line3
    line1=$(_probe_line_at_offset "$file" 0)
    e1=$(_epoch_of_line "$line1")
    line2=$(_probe_line_at_offset "$file" $((size / 2)))
    e2=$(_epoch_of_line "$line2")
    if [[ "$size" -gt "${SEEK_PROBE_BYTES:-131072}" ]]; then
        near_end=$((size - SEEK_PROBE_BYTES))
        line3=$(_probe_line_at_offset "$file" "$near_end")
    else
        # Маленький файл: "почти-конец" ≠ offset 0 — берём последнюю строку.
        line3=$(tail -n 1 -- "$file" 2>/dev/null | tr -d '\0')
    fi
    e3=$(_epoch_of_line "$line3")
    [[ "$e1" =~ ^[0-9]+$ && "$e2" =~ ^[0-9]+$ && "$e3" =~ ^[0-9]+$ ]] || return 1
    [[ "$e1" -gt 0 && "$e2" -gt 0 && "$e3" -gt 0 ]] || return 1
    echo "$e1 $e2 $e3"
}

# Режим хронологии plain-файла: sorted | soft | unsorted.
# soft = first≤last, но середина «плавает» (типичный sipdump/clustermonitor
# SoftSwitch с несколькими писателями) — seek с широким backoff, без early-stop.
_logs_sort_mode() {
    local file="$1" size="$2"
    local e1 e2 e3
    read -r e1 e2 e3 < <(_logs_probe_epochs "$file" "$size") || { echo unsorted; return; }
    if [[ "$e1" -le "$e2" && "$e2" -le "$e3" ]]; then
        echo sorted
    elif [[ "$e1" -le "$e3" ]]; then
        echo soft
    else
        echo unsorted
    fi
}

# Истина только для строгого sorted (совместимость со старыми вызовами).
_logs_appear_sorted() {
    [[ "$(_logs_sort_mode "$1" "$2")" == "sorted" ]]
}

# Бинарный поиск: приблизительное байтовое смещение первой строки с epoch >= target
# Для файла в 30GB это ~35 проб × ~128KB ≈ несколько МБ I/O (в стиле timegrep/archeolog).
_binsearch_offset_ge() {
    local file="$1" target="$2" size="$3"
    local lo=0 hi="$size" mid line ep
    # Останавливаемся, когда окно мало; должно быть много меньше типичных логов среднего размера (selftest ~1–2MB)
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

# Потоковый фильтр: строки в [from,to].
# sorted=1 → early-stop когда ep > to+grace (grace смягчает мелкий reorder).
_awk_filter_range_prog() {
    local sorted="${1:-0}"
    local grace="${2:-0}"
    [[ "$grace" =~ ^[0-9]+$ ]] || grace=0
    printf '%s\n' "$_AWK_LINE_EPOCH"
    cat <<EOF
BEGIN { in_range = 0; sorted = $sorted; grace = $grace }
{
    ep = line_epoch(\$0)
    if (ep >= 0) {
        if (sorted && ep > to + grace) exit
        if (ep >= from && ep <= to) { print; in_range = 1 }
        else { in_range = 0 }
    } else if (in_range) {
        print
    }
}
EOF
}

# Выровнять байтовое смещение на начало строки (после предыдущего \n). Не даёт разрывать строки между чанками.
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

# Извлечь одно выровненное по \n байтовое окно → part-файл
_extract_chunk_worker() {
    local file="$1" off="$2" len="$3" from_epoch="$4" to_epoch="$5" sorted="$6" part="$7"
    [[ "$len" -le 0 ]] && { : > "$part"; return 0; }
    dd if="$file" bs=4M iflag=skip_bytes,count_bytes skip="$off" count="$len" 2>/dev/null \
        | tr -d '\0' \
        | LC_ALL=C awk -v from="$from_epoch" -v to="$to_epoch" -v ref_midnight="${_LOG_REF_MIDNIGHT_EPOCH:-0}" \
            "$(_awk_filter_range_prog "$sorted")" \
        > "$part" 2>/dev/null || true
}

# Выделенный пул задач seek — НЕЛЬЗЯ переиспользовать COLLECTOR_JOB_PIDS (вложенность под copy-воркерами → зависание).
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

# Параллельное сканирование по чанкам [start_off, end_off). Безопасно от зависания (≥1 воркер); чанки выровнены по строкам.
_filter_byte_range_parallel() {
    local file="$1" dest="$2" from_epoch="$3" to_epoch="$4"
    local start_off="$5" end_off="$6" sorted="${7:-1}"
    local range chunk_sz max_jobs n i off next len part_dir rf size
    local -a parts=() bounds=()

    [[ "$end_off" -gt "$start_off" ]] || return 1
    range=$((end_off - start_off))
    size=$(_file_size_bytes "$file")
    max_jobs=$(_collector_inner_max_jobs)
    [[ "$max_jobs" -lt 1 ]] && max_jobs=1
    chunk_sz="${SEEK_CHUNK_BYTES:-67108864}"

    # Окна среднего размера: чанков достаточно, чтобы задействовать несколько воркеров
    if [[ "$range" -lt $((chunk_sz * max_jobs)) ]]; then
        chunk_sz=$(( range / max_jobs + 1 ))
        [[ "$chunk_sz" -lt $((1024 * 1024)) ]] && chunk_sz=$((1024 * 1024))
    fi
    # Окна ≥1GB: оставляем крупные чанки (монолиты SoftSwitch)
    if [[ "$range" -ge "${SEEK_HUGE_BYTES:-1073741824}" ]]; then
        chunk_sz="${SEEK_CHUNK_BYTES:-67108864}"
        [[ "$chunk_sz" -lt $((32 * 1024 * 1024)) ]] && chunk_sz=$((32 * 1024 * 1024))
    fi

    n=$(( (range + chunk_sz - 1) / chunk_sz ))
    [[ "$n" -lt 1 ]] && n=1
    [[ "$n" -gt 256 ]] && { chunk_sz=$(( (range + 255) / 256 )); n=$(( (range + chunk_sz - 1) / chunk_sz )); }

    # Выравниваем границы чанков по строкам, чтобы ни одна строка лога не была разорвана/потеряна
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

# Фильтровать строки лога по timestamp внутри содержимого файла (YYYY-MM-DD / DD.MM.YYYY)
# Стратегия (рабочая скорость на монолитах масштаба SoftSwitch):
#   1) Если обычный файл + похож на отсортированный + size>=SEEK_MIN: бисекция смещений from/to, затем параллельное сканирование по чанкам
#   2) Иначе если обычный файл + size>=SEEK_MIN: параллельное сканирование по чанкам всего файла (безопасно для неотсортированных)
#   3) Иначе: однопоточный awk (маленькие файлы / .gz через zcat)
filter_log_file_by_range() {
    local src_file="$1" dest_file="$2"
    local from_epoch="$3" to_epoch="$4"
    local reader="cat" size=0 sorted=0 start_off=0 end_off=0
    local min_sz="${SEEK_MIN_BYTES:-1048576}"
    local sort_mode backoff

    [[ "$src_file" == *.gz ]] && reader="zcat"
    _collector_should_stop && return 1
    mkdir -p "$(dirname "$dest_file")" 2>/dev/null
    _LOG_REF_MIDNIGHT_EPOCH=$(_infer_file_midnight_epoch "$src_file")

    if [[ "$reader" == "cat" && -f "$src_file" ]]; then
        size=$(_file_size_bytes "$src_file")
        if [[ "$size" -ge "$min_sz" ]]; then
            sort_mode=$(_logs_sort_mode "$src_file" "$size")
            if [[ "$sort_mode" == "sorted" || "$sort_mode" == "soft" ]]; then
                [[ "$sort_mode" == "sorted" ]] && sorted=1 || sorted=0
                [[ "$sort_mode" == "sorted" ]] \
                    && backoff="${SEEK_BACKOFF_BYTES:-1048576}" \
                    || backoff="${SEEK_SOFT_SORT_BACKOFF_BYTES:-33554432}"
                start_off=$(_binsearch_offset_ge "$src_file" "$from_epoch" "$size")
                end_off=$(_binsearch_offset_ge "$src_file" "$((to_epoch + 1))" "$size")
                if [[ "$start_off" -gt "$backoff" ]]; then
                    start_off=$((start_off - backoff))
                else
                    start_off=0
                fi
                end_off=$((end_off + backoff))
                [[ "$end_off" -gt "$size" ]] && end_off=$size
                [[ "$end_off" -le "$start_off" ]] && end_off=$size
                _filter_byte_range_parallel "$src_file" "$dest_file" "$from_epoch" "$to_epoch" \
                    "$start_off" "$end_off" "$sorted"
                return $?
            fi
            # Неотсортированный, но большой: параллельное сканирование всего файла
            _filter_byte_range_parallel "$src_file" "$dest_file" "$from_epoch" "$to_epoch" \
                0 "$size" 0
            return $?
        fi
    fi

    # Маленькие файлы / gzip: единый поток
    $reader "$src_file" 2>/dev/null \
        | tr -d '\0' \
        | LC_ALL=C awk -v from="$from_epoch" -v to="$to_epoch" -v ref_midnight="${_LOG_REF_MIDNIGHT_EPOCH:-0}" \
            "$(_awk_filter_range_prog 0)" \
        > "$dest_file" 2>/dev/null \
        || { rm -f "$dest_file" 2>/dev/null; return 1; }

    [[ -s "$dest_file" ]]
}

# Запасной вариант на основе grep для логов в стиле syslog (почасовые паттерны).
# НИКОГДА не пересканировать многогигабайтные файлы почасово — это означало бы перечитывание сотен ГБ.
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
        # Крупные файлы: только путь awk/bisect — почасовой цикл катастрофичен
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

# --- 8b. Автономное извлечение диапазона из лога службы (parce_service_log) ----
# Получив файл лога службы (или символьную ссылку на него) и диапазон времени
# [from, to], находит байтовые смещения, ограничивающие этот диапазон, через
# интерполяционный поиск — каждая проба нацеливается пропорционально тому,
# где "from"/"to" должны находиться между двумя уже известными epoch в текущих
# границах поиска (так же, как человек предположил бы «прошлое воскресенье
# примерно на 87% файла», прочитав дату только первой строки, а затем
# скорректировал бы прицел по величине промаха), а не всегда делит оставшееся
# окно пополам, как обычная бисекция. Предполагает, что лог хронологически
# отсортирован (append-only) — на этом же предположении опирается весь подход,
# включая существующую bisect-based filter_log_file_by_range() в другом месте этого файла.

# Разрешает путь к логу (следуя одному переходу по символьной ссылке) в
# реальный, читаемый, несжатый файл. Печатает разрешённый путь.
# ПРИМЕЧАНИЕ: stdout этой функции — её возвращаемое значение (вызывающий код
# всегда использует её как real_path=$(_psl_resolve_log_path ...)) — каждый
# вызов warn() ниже явно перенаправлен в stderr, иначе сам текст диагностики
# был бы захвачен в $(...) вместо показа пользователю (та же ошибка смешения
# print/возвращаемого значения, что и в других местах; поймана здесь по той же
# причине, что и на шаге выбора режима в мастере).
_psl_resolve_log_path() {
    local path="$1" real="$1"

    [[ -n "$path" ]] || { warn "parce_service_log: no log path given" >&2; return 1; }
    if [[ -L "$path" ]]; then
        real=$(readlink -f "$path" 2>/dev/null)
        [[ -n "$real" ]] || { warn "parce_service_log: broken symlink: $path" >&2; return 1; }
    fi
    [[ -f "$real" ]] || { warn "parce_service_log: not a regular file: $path" >&2; return 1; }
    [[ -r "$real" ]] || { warn "parce_service_log: not readable: $real" >&2; return 1; }
    case "$real" in
        *.gz|*.bz2|*.xz|*.zip)
            warn "parce_service_log: compressed logs are not byte-seekable: $real" >&2
            return 1
            ;;
    esac
    echo "$real"
}

# Принимает либо уже числовой epoch, либо всё, что понимает `date -d`.
# Та же оговорка про stdout-как-возвращаемое-значение, что и у _psl_resolve_log_path() выше.
# Пустая строка — ошибка: GNU `date -d ""` молча даёт 00:00:00 сегодняшнего дня,
# из‑за чего верхняя граница «за последние Nd» обрывала лог ровно на полуночи.
_psl_parse_timestamp() {
    local raw="$1" ep
    if [[ -z "${raw//[[:space:]]/}" ]]; then
        warn "parce_service_log: cannot parse timestamp '$raw'" >&2
        return 1
    fi
    if [[ "$raw" =~ ^[0-9]+$ ]]; then
        echo "$raw"
        return 0
    fi
    ep=$(time_to_epoch "$raw")
    [[ "$ep" =~ ^[0-9]+$ ]] || { warn "parce_service_log: cannot parse timestamp '$raw'" >&2; return 1; }
    echo "$ep"
}

# Интерполяционный поиск наименьшего байтового смещения, чья строка имеет
# epoch >= target ($size, если такой строки нет). Автоматически переходит на
# обычную бисекцию, когда две известные граничные epoch равны (нечего
# интерполировать). Те же примитивы пробы/парсинга, что и у обычной бисекции
# _binsearch_offset_ge() выше, отличается только выбор "mid".
#
#
# Чистый интерполяционный поиск подвержен известному патологическому
# случаю: логи редко пишутся с равномерной скоростью (всплески сменяются
# затишьями), и когда *глобальная* плотность на [lo,hi] сильно отличается от
# *локальной* плотности возле target, прямое пропорциональное предположение
# почти не сужает окно на каждом шаге — поиск может деградировать почти до
# линейного сканирования. _MIN_PROGRESS_FRAC ниже ограничивает каждое
# предположение так, чтобы оно сдвигалось хотя бы на эту долю текущего окна,
# что ограничивает число итераций логарифмом (та же форма, что у обычной
# бисекции, просто с большим основанием) независимо от того, насколько
# перекошены timestamp'ы, при этом всё ещё используя интерполированное
# предположение — и его обычно намного более быструю сходимость — там, где
# данные ведут себя достаточно хорошо, чтобы предположение само попало в этот диапазон.
_PSL_MIN_PROGRESS_FRAC=10   # гарантируем >=1/10 окна за одну итерацию

_psl_find_offset_for_epoch() {
    local file="$1" size="$2" target="$3"
    local window="${SEEK_PROBE_BYTES:-131072}"
    local lo=0 hi="$size" lo_ep hi_ep mid mid_ep line span min_gap

    line=$(_probe_line_at_offset "$file" "$lo") || line=""
    lo_ep=$(_epoch_of_line "$line")
    [[ "$lo_ep" =~ ^[0-9]+$ ]] || lo_ep=0
    if [[ "$lo_ep" -ge "$target" ]]; then
        echo 0
        return 0
    fi

    line=$(_probe_line_at_offset "$file" "$((size > window ? size - window : 0))") || line=""
    hi_ep=$(_epoch_of_line "$line")
    [[ "$hi_ep" =~ ^[0-9]+$ ]] || hi_ep="$lo_ep"
    if [[ "$hi_ep" -lt "$target" ]]; then
        echo "$size"
        return 0
    fi

    while [[ $((hi - lo)) -gt "$window" ]]; do
        if [[ "$hi_ep" -le "$lo_ep" ]]; then
            # Вырожденное окно (одинаковые epoch) — интерполировать нельзя.
            mid=$(( (lo + hi) / 2 ))
        else
            # Сделано в awk (double precision), а не в целых числах bash: на файле в
            # несколько сотен ГБ (target-lo_ep)*(hi-lo) может переполнить 64-битное целое
            # bash до того, как деление вернёт его в норму.
            mid=$(awk -v lo="$lo" -v hi="$hi" -v lo_ep="$lo_ep" -v hi_ep="$hi_ep" -v target="$target" \
                'BEGIN { frac = (target - lo_ep) / (hi_ep - lo_ep); m = lo + frac * (hi - lo); printf "%d", m }')
            [[ "$mid" =~ ^[0-9]+$ ]] || mid=$(( (lo + hi) / 2 ))

            # Ограничиваем в полосу гарантированного прогресса около середины —
            # именно это не даёт перекошенной плотности застопорить поиск.
            span=$((hi - lo))
            min_gap=$((span / _PSL_MIN_PROGRESS_FRAC))
            [[ "$min_gap" -lt 1 ]] && min_gap=1
            [[ $((mid - lo)) -lt "$min_gap" ]] && mid=$((lo + min_gap))
            [[ $((hi - mid)) -lt "$min_gap" ]] && mid=$((hi - min_gap))
        fi

        line=$(_probe_line_at_offset "$file" "$mid") || { lo=$((mid + 1)); continue; }
        mid_ep=$(_epoch_of_line "$line")
        if [[ ! "$mid_ep" =~ ^[0-9]+$ ]] || [[ "$mid_ep" -lt 0 ]]; then
            lo=$((mid + 4096))
            [[ "$lo" -ge "$hi" ]] && break
            continue
        fi

        if [[ "$mid_ep" -lt "$target" ]]; then
            lo="$mid"; lo_ep="$mid_ep"
        else
            hi="$mid"; hi_ep="$mid_ep"
        fi
    done
    echo "$lo"
}

# Разрешает [from_epoch, to_epoch] в выровненный по строкам байтовый диапазон
# [start_off, end_off). Печатает "start_off end_off"; возвращает 1, если ничего не подошло.
#
# _psl_find_offset_for_epoch() лишь сужает до одного проб-"окна"
# (SEEK_PROBE_BYTES) от истинной границы — так же, как и обычная бисекция
# _binsearch_offset_ge() — ни одна из них никогда не подтверждает точную
# строку. Поэтому, как и filter_log_file_by_range() делает вокруг своих
# вызовов _binsearch_offset_ge(), отступаем на SEEK_BACKOFF_BYTES с обеих
# сторон перед выравниванием: более широкое байтовое окно гарантированно
# полностью содержит истинную границу, а содержательный фильтр по epoch,
# применяемый на шаге копирования (не в этой функции), отбрасывает все
# лишние строки, которые этот запас захватывает с любой стороны.
# $5 = опциональный backoff в байтах (default SEEK_BACKOFF_BYTES; soft → SEEK_SOFT_SORT_*).
_psl_locate_range() {
    local file="$1" size="$2" from_epoch="$3" to_epoch="$4"
    local backoff="${5:-${SEEK_BACKOFF_BYTES:-1048576}}"
    local start_off end_off

    start_off=$(_psl_find_offset_for_epoch "$file" "$size" "$from_epoch")
    [[ "$start_off" -gt "$backoff" ]] && start_off=$((start_off - backoff)) || start_off=0
    start_off=$(_align_to_line_start "$file" "$start_off" "$size")

    end_off=$(_psl_find_offset_for_epoch "$file" "$size" "$((to_epoch + 1))")
    end_off=$((end_off + backoff))
    [[ "$end_off" -gt "$size" ]] && end_off="$size"
    end_off=$(_align_to_line_start "$file" "$end_off" "$size")

    if [[ "$end_off" -le "$start_off" ]]; then
        warn "parce_service_log: no lines fall inside the requested time range" >&2
        return 1
    fi
    echo "$start_off $end_off"
}

# Создаёт свежую, прозрачно названную директорию в /tmp для чанк-файлов
# этого извлечения: /tmp/parce_<basename>_<from>-<to>.<random>/
_psl_make_output_dir() {
    local file="$1" from_epoch="$2" to_epoch="$3"
    local base prefix

    base=$(basename -- "$file")
    base="${base//[^A-Za-z0-9._-]/_}"
    prefix="/tmp/parce_${base}_${from_epoch}-${to_epoch}"
    mktemp -d "${prefix}.XXXXXX" 2>/dev/null
}

# Разбивает [start_off, end_off) на выровненные по строкам куски размером
# MAX_LOG_CHUNK_SIZE. Печатает по одному смещению на строку: N+1 границ образуют N чанков.
_psl_plan_chunk_bounds() {
    local file="$1" start_off="$2" end_off="$3" size="$4"
    local chunk_sz="${MAX_LOG_CHUNK_SIZE:-104857600}" range i off prev

    range=$((end_off - start_off))
    [[ "$chunk_sz" -gt 0 ]] || chunk_sz="$range"
    echo "$start_off"
    prev="$start_off"
    i=1
    while [[ $((start_off + i * chunk_sz)) -lt "$end_off" ]]; do
        off=$(_align_to_line_start "$file" $((start_off + i * chunk_sz)) "$size")
        if [[ "$off" -gt "$prev" && "$off" -lt "$end_off" ]]; then
            echo "$off"
            prev="$off"
        fi
        i=$((i + 1))
    done
    echo "$end_off"
}

# Копирует каждый кусок [off, next) из _psl_plan_chunk_bounds (аргументы
# 6..N) в свой raw_NNNNN.log внутри raw_dir, оставляя только строки внутри
# [from_epoch, to_epoch] — защита от того, что интерполяционный поиск
# приземлился на несколько строк раньше/позже точной границы. Это ВНУТРЕННЯЯ
# параллельная нарезка на воркеры (гранулярность — MAX_LOG_CHUNK_SIZE), а не
# итоговые part_*.log в архиве — вызывающий код (parce_service_log())
# склеивает эти raw_*.log обратно в один файл и режет его заново на
# итоговые части через _psl_split_final_output() (LOG_CHUNK_MODE и т.п.).
# $5=sorted: 1 разрешает ранний выход из awk по каждому куску, как только
# встретилась строка позже to_epoch (безопасно только если файл
# действительно хронологически отсортирован); 0 — сканировать кусок целиком
# (когда _logs_appear_sorted() уже сказал "нет", а границы [off,next) —
# это просто весь файл, а не результат интерполяционного поиска).
# Отбрасывает куски, оказавшиеся пустыми. Печатает число непустых кусков.
_psl_copy_chunks() {
    local file="$1" raw_dir="$2" from_epoch="$3" to_epoch="$4" sorted="$5"
    local -a bounds=("${@:6}")
    local n=$((${#bounds[@]} - 1))
    local max_jobs i off next len part idx=0 count=0

    max_jobs=$(_collector_inner_max_jobs)
    [[ "$max_jobs" -lt 1 ]] && max_jobs=1
    _SEEK_JOB_PIDS=()

    for (( i=0; i<n; i++ )); do
        off="${bounds[$i]}"
        next="${bounds[$((i + 1))]}"
        len=$((next - off))
        [[ "$len" -le 0 ]] && continue
        idx=$((idx + 1))
        part=$(printf '%s/raw_%05d.log' "$raw_dir" "$idx")
        if ! _seek_wait_slot "$max_jobs"; then
            _seek_kill_jobs
            break
        fi
        (
            renice -n 10 $$ >/dev/null 2>&1 || true
            ionice -c 2 -n 7 -p $$ >/dev/null 2>&1 || true
            _extract_chunk_worker "$file" "$off" "$len" "$from_epoch" "$to_epoch" "$sorted" "$part"
        ) &
        _SEEK_JOB_PIDS+=($!)
    done
    _seek_wait_all_jobs

    for part in "$raw_dir"/raw_*.log; do
        [[ -e "$part" ]] || continue
        if [[ -s "$part" ]]; then
            count=$((count + 1))
        else
            rm -f -- "$part" 2>/dev/null
        fi
    done
    echo "$count"
}

# Извлекает часть лог-файла службы, чьи строки попадают в
# [ts_from, ts_to], в один или несколько чанк-файлов под /tmp.
#   $1 = путь к лог-файлу (или символьной ссылке на него)
#   $2 = начало диапазона — секунды epoch, либо всё, что понимает `date -d`
#   $3 = конец диапазона   — секунды epoch, либо всё, что понимает `date -d`
# При успехе: устанавливает PSL_OUTPUT_PATH (директория в /tmp с
# part_00001.log, part_00002.log, ...) и PSL_OUTPUT_CHUNKS (их количество),
# печатает "<PSL_OUTPUT_PATH> <PSL_OUTPUT_CHUNKS>", возвращает 0.
# При неудаче: выводит warn с причиной, возвращает 1, оставляет обе глобальные переменные неустановленными.
parce_service_log() {
    local log_path="$1" ts_from_raw="$2" ts_to_raw="$3"
    local real_path from_epoch to_epoch size range_str start_off end_off sorted=1
    local sort_mode backoff out_dir raw_dir combined raw_count chunk_count
    local -a bounds=()

    unset PSL_OUTPUT_PATH PSL_OUTPUT_CHUNKS

    real_path=$(_psl_resolve_log_path "$log_path") || return 1
    from_epoch=$(_psl_parse_timestamp "$ts_from_raw") || return 1
    to_epoch=$(_psl_parse_timestamp "$ts_to_raw") || return 1
    if [[ "$from_epoch" -gt "$to_epoch" ]]; then
        warn "parce_service_log: start timestamp is after end timestamp"
        return 1
    fi

    size=$(_file_size_bytes "$real_path")
    if [[ "$size" -le 0 ]]; then
        warn "parce_service_log: $real_path is empty or unreadable"
        return 1
    fi
    # Некоторые логгеры (например fcs-swau) пишут в строке только время без
    # даты — дата только в имени файла; без этого такие строки были бы
    # неотличимы от "нет метки времени вообще" везде ниже по конвейеру
    # (line_epoch() в awk читает эту переменную через -v ref_midnight=...).
    _LOG_REF_MIDNIGHT_EPOCH=$(_infer_file_midnight_epoch "$real_path")

    sort_mode=$(_logs_sort_mode "$real_path" "$size")
    case "$sort_mode" in
        sorted)
            range_str=$(_psl_locate_range "$real_path" "$size" "$from_epoch" "$to_epoch") || return 1
            read -r start_off end_off <<< "$range_str"
            ;;
        soft)
            # first≤last, середина плавает — seek с широким окном, без early-stop.
            sorted=0
            backoff="${SEEK_SOFT_SORT_BACKOFF_BYTES:-33554432}"
            log_debug "parce_service_log: soft-sorted seek ($real_path), backoff=${backoff}"
            range_str=$(_psl_locate_range "$real_path" "$size" "$from_epoch" "$to_epoch" "$backoff") || return 1
            read -r start_off end_off <<< "$range_str"
            ;;
        *)
            sorted=0
            warn "parce_service_log: $real_path does not look chronologically sorted — scanning the whole file instead of seeking"
            start_off=0
            end_off="$size"
            ;;
    esac

    out_dir=$(_psl_make_output_dir "$real_path" "$from_epoch" "$to_epoch")
    [[ -n "$out_dir" && -d "$out_dir" ]] || { warn "parce_service_log: cannot create output dir under /tmp"; return 1; }
    raw_dir="$out_dir/.raw"
    mkdir -p "$raw_dir" 2>/dev/null || { warn "parce_service_log: cannot create scratch dir under /tmp"; rm -rf -- "$out_dir" 2>/dev/null; return 1; }

    mapfile -t bounds < <(_psl_plan_chunk_bounds "$real_path" "$start_off" "$end_off" "$size")
    raw_count=$(_psl_copy_chunks "$real_path" "$raw_dir" "$from_epoch" "$to_epoch" "$sorted" "${bounds[@]}")

    if [[ ! "$raw_count" =~ ^[0-9]+$ ]] || [[ "$raw_count" -eq 0 ]]; then
        warn "parce_service_log: no lines matched inside the requested range"
        rm -rf -- "$out_dir" 2>/dev/null
        return 1
    fi

    # Склеиваем внутренние параллельные куски обратно в один файл (порядок
    # сохраняется благодаря нулям в raw_%05d) и режем его заново на итоговые
    # part_*.log согласно LOG_CHUNK_MODE — так же, как это делает
    # _psl_finalize_groups() для директорий/служб целиком.
    combined="$out_dir/.combined.log"
    cat "$raw_dir"/raw_*.log > "$combined" 2>/dev/null
    rm -rf -- "$raw_dir" 2>/dev/null

    chunk_count=$(_psl_split_final_output "$combined" "$out_dir" "part_")
    rm -f -- "$combined" 2>/dev/null

    if [[ ! "$chunk_count" =~ ^[0-9]+$ ]] || [[ "$chunk_count" -eq 0 ]]; then
        warn "parce_service_log: no lines matched inside the requested range"
        rm -rf -- "$out_dir" 2>/dev/null
        return 1
    fi

    PSL_OUTPUT_PATH="$out_dir"
    PSL_OUTPUT_CHUNKS="$chunk_count"
    echo "$PSL_OUTPUT_PATH $PSL_OUTPUT_CHUNKS"
}

# --- 8c. Извлечение диапазона из логов службы целиком (parce_service_logs) ----
# Оборачивает parce_service_log() всем необходимым, чтобы дойти от просто
# *имени службы* до готового набора чанк-файлов: находит, где служба
# хранит свои логи, находит, какие из её файлов могут содержать данные в [from,to],
# пропускает архивную копию, если существует живая обычная копия того же файла,
# запускает parce_service_log() на каждом из уцелевших файлов (сначала распаковывая
# файлы, существующие только в архиве, во временную копию), затем объединяет и
# перенарезает по *типу* лога (access.log/access.log.1/access.2026-07-22.log.gz
# объединяются вместе; error.log — никогда), так что итоговый вывод — небольшое
# число опрятных файлов размером MAX_LOG_CHUNK_SIZE, а не один крошечный файл на
# каждый оригинал ротации. Все промежуточные файлы/директории удаляются перед
# возвратом — возвращённая директория содержит только финальный результат.

# --- Этап 1: явное соответствие служба -> известная(ые) директория(и) логов ---
# Нужно только для служб, у которых имя директории логов не совпадает с
# именем службы (логи mysqld лежат в /var/log/mysql, а не в /var/log/
# mysqld) — всё, где имя директории == имени службы, уже покрывается
# этапами 2/3 ниже и не требует записи здесь.
declare -A _PSL_SVC_LOG_DIRS=(
    [mysqld]="/var/log/mysql /var/lib/mysql"
    [mysql]="/var/log/mysql /var/lib/mysql"
    [mariadb]="/var/log/mysql /var/lib/mysql"
    [httpd]="/var/log/httpd"
    [redis-server]="/var/log/redis"
    [rabbitmq-server]="/var/log/rabbitmq"
)
# Этап 2: дополнительные родительские директории для поиска одноимённой подпапки
# (помимо стандартного /var/log, который проверяется отдельно на этапе 3). Включает
# /var/log/flat, поэтому внутренние продукты FLAT (любое имя из PKG_PRODUCT)
# находятся здесь автоматически по той же конвенции, которую уже использует
# find_log_dirs_for_pkg(), без необходимости добавлять запись на каждый продукт выше.
_PSL_SVC_SEARCH_ROOTS=(/var/log/flat /opt /opt/flat /var/opt /usr/local/var/log)

# Находит директорию(и) логов для имени службы. Печатает каждую
# отдельную директорию на своей строке (без дублей); возвращает 1 без
# вывода, если ничего не найдено. Например, ssh/sshd на большинстве систем
# закономерно не имеют выделенной директории (они пишут в syslog/auth.log) и
# корректно попадут именно в этот случай.
_psl_find_service_log_dirs() {
    local service="$1"
    local -a found=()
    local d root cfg_dir

    # Этап 1: явное соответствие, плюс пути из конфигов, которые некоторые
    # продукты FLAT уже регистрируют через get_log_path_from_config().
    for d in ${_PSL_SVC_LOG_DIRS[$service]:-}; do
        [[ -d "$d" ]] && found+=("$d")
    done
    cfg_dir=$(get_log_path_from_config "$service" 2>/dev/null)
    if [[ -n "$cfg_dir" ]]; then
        cfg_dir=$(eval echo "$cfg_dir" 2>/dev/null)
        [[ -d "$cfg_dir" ]] && found+=("$cfg_dir")
    fi

    # Этап 2: одноимённая подпапка внутри списка родительских корней.
    for root in "${_PSL_SVC_SEARCH_ROOTS[@]}"; do
        d="$root/$service"
        [[ -d "$d" ]] && found+=("$d")
    done

    # Этап 3: стандартная конвенция, проверяется явно, чтобы никогда не
    # пропускаться, даже если список корней этапа 2 выше в будущем сократят.
    d="/var/log/$service"
    [[ -d "$d" ]] && found+=("$d")

    [[ ${#found[@]} -eq 0 ]] && return 1
    printf '%s\n' "${found[@]}" | sort -u
}

# Печатает "start_epoch end_epoch" для файла: время создания (или время
# изменения inode, если файловая система/ядро не предоставляют настоящее
# время создания) как начало, mtime как конец — самая широкая разумная оценка
# промежутка, в течение которого файл мог получать строки лога.
_psl_file_time_span() {
    local file="$1" birth mtime ctime start

    birth=$(stat -c '%W' "$file" 2>/dev/null)
    ctime=$(stat -c '%Z' "$file" 2>/dev/null)
    mtime=$(stat -c '%Y' "$file" 2>/dev/null)

    if [[ "$birth" =~ ^[0-9]+$ ]] && [[ "$birth" -gt 0 ]]; then
        start="$birth"
    elif [[ "$ctime" =~ ^[0-9]+$ ]]; then
        start="$ctime"
    else
        start="$mtime"
    fi
    [[ "$mtime" =~ ^[0-9]+$ ]] || mtime="$start"
    # ctime (время изменения метаданных) может оказаться *позже* mtime для
    # ротированного файла — например, logrotate переименовывает его заметно
    # позже последней записанной строки, что двигает ctime, но не mtime —
    # ограничиваем, чтобы промежуток никогда не был перевёрнутым (иначе проверка
    # пересечения в _psl_scan_candidate_files() была бы ненадёжной).
    [[ "$start" -gt "$mtime" ]] && start="$mtime"
    echo "$start $mtime"
}

# Сканирует список директорий (не рекурсивно: это уже собственные
# директории логов службы, а не дерево для обхода) на обычные файлы, чей
# промежуток [birth/ctime, mtime] пересекается с [from_epoch, to_epoch]. Печатает
# по одному подходящему пути на строку.
_psl_scan_candidate_files() {
    local from_epoch="$1" to_epoch="$2"
    shift 2
    local -a dirs=("$@")
    local dir f fstart fend

    for dir in "${dirs[@]}"; do
        [[ -d "$dir" ]] || continue
        while IFS= read -r -d '' f; do
            [[ -f "$f" ]] || continue
            read -r fstart fend < <(_psl_file_time_span "$f")
            [[ "$fstart" =~ ^[0-9]+$ && "$fend" =~ ^[0-9]+$ ]] || continue
            [[ "$fstart" -le "$to_epoch" && "$fend" -ge "$from_epoch" ]] && echo "$f"
        done < <(find -L "$dir" -maxdepth 1 -type f -print0 2>/dev/null)
    done
}

# Печатает имя без архивного расширения (убирает .gz/.bz2/.xz/.zip/.Z),
# либо имя без изменений, если оно не архивировано.
_psl_strip_archive_ext() {
    local name="$1" ext
    for ext in .gz .bz2 .xz .zip .Z; do
        if [[ "$name" == *"$ext" ]]; then
            echo "${name%"$ext"}"
            return 0
        fi
    done
    echo "$name"
}

# Снимает суффикс logrotate после .log/.txt/.csv.
# Маска на практике: name.(log|txt|csv).<что угодно> —
#   sipdump.txt.1 | sipdump.txt.-20260731 | sipdump.txt.2026-07-31 | error.log.3
# Редко без точки: name.txt-20260731 / name.log_2026-07-31.
# Без этого sipdump.txt.-20260731 схлопывался в «sipdump.txt.» и отваливался
# от фильтра типов / группы live sipdump.txt (баг на РЕД ОС и др.).
_psl_strip_logrotate_suffix() {
    local name="$1"
    if [[ "$name" =~ ^(.+)\.(log|txt|csv)\..+ ]]; then
        printf '%s.%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
        return 0
    fi
    if [[ "$name" =~ ^(.+)\.(log|txt|csv)[-_][0-9]{4} ]]; then
        printf '%s.%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
        return 0
    fi
    printf '%s\n' "$name"
}

# Читает список кандидатов (по одному пути на строку) из stdin, отбрасывает
# любой архивный файл, у которого есть живой обычный «близнец» с идентичным
# именем (та же директория, то же имя после удаления архивного расширения) —
# один и тот же экземпляр ротации существует дважды, читать нужно только
# обычный — и печатает уцелевшие пути.
_psl_dedupe_archive_copies() {
    local -A has_plain=()
    local -a files=()
    local f dir base identity key

    mapfile -t files

    for f in "${files[@]}"; do
        dir=$(dirname -- "$f")
        base=$(basename -- "$f")
        identity=$(_psl_strip_archive_ext "$base")
        [[ "$base" == "$identity" ]] && has_plain["$dir/$identity"]=1
    done

    for f in "${files[@]}"; do
        dir=$(dirname -- "$f")
        base=$(basename -- "$f")
        identity=$(_psl_strip_archive_ext "$base")
        if [[ "$base" != "$identity" ]]; then
            key="$dir/$identity"
            [[ -n "${has_plain[$key]:-}" ]] && continue
        fi
        echo "$f"
    done
}

# Вычисляет «тип лога», к которому относится ротированный/архивный файл, так что
# access.log / access.log.1 / access.log.2.gz / access.2026-07-22.log /
# sipdump.txt.-20260731 все группируются вместе, а error.log остаётся отдельно.
# Убирает (по порядку): архивное расширение, суффикс logrotate после .log|.txt|.csv,
# ведущую дату в имени (FCS daily), прочие числовые/датированные хвосты.
_psl_log_group_key() {
    local key
    key=$(_psl_strip_archive_ext "$(basename -- "$1")")
    # SoftSwitch / logrotate: name.txt.<что угодно> → name.txt (до ведущей даты FCS)
    key=$(_psl_strip_logrotate_suffix "$key")
    # Ведущая дата в самом начале имени файла — ежедневная ротация вида
    # YYYY_MM_DD_service_log.log / YYYY-MM-DD-service.log (например у
    # fcs-swau/fcs-contact и других продуктов линейки FCS): без этого
    # каждый день считался бы своим собственным "типом" лога и никогда не
    # объединялся бы с остальными днями той же службы.
    key=$(printf '%s' "$key" | sed -E \
        -e 's/^[0-9]{4}[_-][0-9]{2}[_-][0-9]{2}[_-]//' \
        -e 's/^[0-9]{2}[_.][0-9]{2}[_.][0-9]{4}[_-]//')
    key=$(printf '%s' "$key" | sed -E \
        -e 's/\.[0-9]+$//' \
        -e 's/[-.][0-9]{4}-?[0-9]{2}-?[0-9]{2}$//')
    key=$(printf '%s' "$key" | sed -E \
        -e 's/[-.][0-9]{4}-[0-9]{2}-[0-9]{2}(\.log)$/\1/' \
        -e 's/\.[0-9]+(\.log)$/\1/')
    # хвост вроде «sipdump.txt.» после неудачного peel даты
    key="${key%.}"
    printf '%s' "$key"
}

# Если $1 обычный — печатает без изменений. Если он архивирован — распаковывает
# его в $2/scratch/ и вместо этого печатает путь к этой временной копии (вызывающий
# код сам отвечает за её удаление по завершении — сама parce_service_log()
# полностью отбрасывает сжатый ввод, искать внутри сжатого потока
# невозможно). .zip распознаётся выше для целей группировки/дедупликации,
# но здесь не распаковывается (неоднозначное имя внутреннего элемента) — логируется
# и пропускается.
_psl_materialize_plain() {
    local file="$1" work_dir="$2" scratch out

    case "$file" in
        *.gz)  : ;;
        *.bz2) : ;;
        *.xz)  : ;;
        *.zip|*.Z)
            warn "parce_service_logs: skipping unsupported archive format: $file" >&2
            return 1
            ;;
        *) echo "$file"; return 0 ;;
    esac

    scratch="$work_dir/scratch"
    mkdir -p "$scratch" 2>/dev/null || return 1
    out="$scratch/$(basename -- "$file").$$.${RANDOM}.plain"
    case "$file" in
        *.gz)  gunzip -c -- "$file" ;;
        *.bz2) bunzip2 -c -- "$file" ;;
        *.xz)  unxz -c -- "$file" ;;
    esac > "$out" 2>/dev/null

    if [[ -s "$out" ]]; then
        echo "$out"
    else
        rm -f -- "$out" 2>/dev/null
        return 1
    fi
}

# Запускает parce_service_log() на одном файле-кандидате и при успехе добавляет
# его извлечённый чанк(и) в аккумулятор группы этого файла под
# $work_dir/groups/. Немедленно чистит собственную tmp-директорию вывода
# parce_service_log() и любую распакованную во временную копию, независимо от исхода.
# Возвращает 0, если этот файл дал хоть какие-то строки, иначе 1 (нормально для
# ротированного файла, в котором просто нет ничего в диапазоне — это не ошибка).
_psl_process_one_candidate() {
    local file="$1" from_epoch="$2" to_epoch="$3" work_dir="$4"
    local plain is_scratch=0 group group_file rc=1

    plain=$(_psl_materialize_plain "$file" "$work_dir") || return 1
    [[ "$plain" != "$file" ]] && is_scratch=1

    if parce_service_log "$plain" "$from_epoch" "$to_epoch" >/dev/null 2>&1; then
        group=$(_psl_log_group_key "$file")
        group_file="$work_dir/groups/${group}.log"
        mkdir -p "$work_dir/groups" 2>/dev/null
        cat "$PSL_OUTPUT_PATH"/part_*.log >> "$group_file" 2>/dev/null
        rc=0
    fi
    rm -rf -- "${PSL_OUTPUT_PATH:-}" 2>/dev/null
    [[ "$is_scratch" -eq 1 ]] && rm -f -- "$plain" 2>/dev/null
    return "$rc"
}

# Свежая, прозрачно названная директория в /tmp для финального результата
# по службе: /tmp/parces_<service>_<from>-<to>.<random>/
_psl_make_service_output_dir() {
    local service="$1" from_epoch="$2" to_epoch="$3" base prefix
    base="${service//[^A-Za-z0-9._-]/_}"
    prefix="/tmp/parces_${base}_${from_epoch}-${to_epoch}"
    mktemp -d "${prefix}.XXXXXX" 2>/dev/null
}

# Разбивает один уже готовый (отфильтрованный/объединённый) файл на
# part_*.log в out_dir — целиком по строкам, никогда их не разрывая.
# Режим — LOG_CHUNK_MODE: "size" (умолчание) — split -C LOG_CHUNK_SIZE_BYTES;
# "lines" — split -l LOG_CHUNK_LINES. Это единственное место, где
# по-настоящему определяется размер/число строк итоговых файлов в архиве —
# и parce_service_log(), и _psl_finalize_groups() вызывают именно её.
# Печатает число получившихся частей (0, если src_file пуст/отсутствует).
_psl_split_final_output() {
    local src_file="$1" out_dir="$2" prefix="${3:-part_}"
    local count

    [[ -s "$src_file" ]] || { echo 0; return 0; }
    mkdir -p "$out_dir" 2>/dev/null || { echo 0; return 1; }

    if [[ "${LOG_CHUNK_MODE:-size}" == "lines" ]]; then
        split -l "${LOG_CHUNK_LINES:-500000}" -d --numeric-suffixes=1 -a 5 \
            --additional-suffix=.log -- "$src_file" "$out_dir/${prefix}" 2>/dev/null
    else
        split -C "${LOG_CHUNK_SIZE_BYTES:-104857600}" -d --numeric-suffixes=1 -a 5 \
            --additional-suffix=.log -- "$src_file" "$out_dir/${prefix}" 2>/dev/null
    fi

    count=$(find "$out_dir" -maxdepth 1 -type f -name "${prefix}*.log" 2>/dev/null | wc -l)
    echo "${count:-0}"
}

# Перенарезает каждый файл-аккумулятор группы в $work_dir/groups/ на
# part_*.log в $final_dir (через _psl_split_final_output(), см. LOG_CHUNK_*),
# с именами "<group>.part_NN.log". Печатает общее число записанных чанк-файлов.
_psl_finalize_groups() {
    local work_dir="$1" final_dir="$2"
    local gfile gkey count total=0

    for gfile in "$work_dir"/groups/*.log; do
        [[ -s "$gfile" ]] || continue
        gkey=$(basename -- "$gfile"); gkey="${gkey%.log}"
        count=$(_psl_split_final_output "$gfile" "$final_dir" "${gkey}.part_")
        [[ "$count" =~ ^[0-9]+$ ]] && total=$((total + count))
    done

    echo "$total"
}

# Извлекает каждый лог-файл заданной службы, который попадает (хотя бы частично)
# в [ts_from, ts_to], в небольшой набор объединённых, ограниченных по размеру
# чанк-файлов под /tmp.
#   $1 = имя службы (nginx, mysqld, apache2, ssh, имя пакета внутреннего
#        продукта FLAT, ...)
#   $2 = начало диапазона — секунды epoch, либо всё, что понимает `date -d`
#   $3 = конец диапазона   — секунды epoch, либо всё, что понимает `date -d`
# При успехе: устанавливает PSLS_OUTPUT_PATH (директория в /tmp с
# <type>.part_NN.log на каждый тип лога — access/error/и т.д. никогда не смешиваются) и
# PSLS_OUTPUT_CHUNKS, печатает "<PSLS_OUTPUT_PATH> <PSLS_OUTPUT_CHUNKS>",
# возвращает 0. При неудаче: выводит warn с причиной, возвращает 1.
parce_service_logs() {
    local service="$1" ts_from_raw="$2" ts_to_raw="$3"
    local from_epoch to_epoch work_dir final_dir chunk_count processed=0
    local f
    local -a dirs=() candidates=() kept=()

    unset PSLS_OUTPUT_PATH PSLS_OUTPUT_CHUNKS

    [[ -n "$service" ]] || { warn "parce_service_logs: no service name given"; return 1; }
    from_epoch=$(_psl_parse_timestamp "$ts_from_raw") || return 1
    to_epoch=$(_psl_parse_timestamp "$ts_to_raw") || return 1
    if [[ "$from_epoch" -gt "$to_epoch" ]]; then
        warn "parce_service_logs: start timestamp is after end timestamp"
        return 1
    fi

    mapfile -t dirs < <(_psl_find_service_log_dirs "$service")
    if [[ ${#dirs[@]} -eq 0 ]]; then
        warn "parce_service_logs: no log directory found for service '$service'"
        return 1
    fi
    info "parce_service_logs: $service log dirs: ${dirs[*]}"

    mapfile -t candidates < <(_psl_scan_candidate_files "$from_epoch" "$to_epoch" "${dirs[@]}")
    if [[ ${#candidates[@]} -eq 0 ]]; then
        warn "parce_service_logs: no files for '$service' overlap the requested range"
        return 1
    fi
    mapfile -t kept < <(printf '%s\n' "${candidates[@]}" | _psl_dedupe_archive_copies)

    work_dir=$(mktemp -d "/tmp/parces_work_${service}.XXXXXX" 2>/dev/null) || {
        warn "parce_service_logs: cannot create scratch dir under /tmp"
        return 1
    }

    for f in "${kept[@]}"; do
        _psl_process_one_candidate "$f" "$from_epoch" "$to_epoch" "$work_dir" \
            && processed=$((processed + 1))
    done

    if [[ "$processed" -eq 0 ]]; then
        warn "parce_service_logs: no lines matched inside the requested range for '$service'"
        rm -rf -- "$work_dir" 2>/dev/null
        return 1
    fi

    final_dir=$(_psl_make_service_output_dir "$service" "$from_epoch" "$to_epoch")
    if [[ -z "$final_dir" || ! -d "$final_dir" ]]; then
        warn "parce_service_logs: cannot create output dir under /tmp"
        rm -rf -- "$work_dir" 2>/dev/null
        return 1
    fi

    chunk_count=$(_psl_finalize_groups "$work_dir" "$final_dir")
    rm -rf -- "$work_dir" 2>/dev/null

    if [[ ! "$chunk_count" =~ ^[0-9]+$ ]] || [[ "$chunk_count" -eq 0 ]]; then
        warn "parce_service_logs: nothing to output for '$service'"
        rm -rf -- "$final_dir" 2>/dev/null
        return 1
    fi

    PSLS_OUTPUT_PATH="$final_dir"
    PSLS_OUTPUT_CHUNKS="$chunk_count"
    echo "$PSLS_OUTPUT_PATH $PSLS_OUTPUT_CHUNKS"
}

# --- 8d. Applying parce_service_log(s) to already-discovered directories -----
# run_log_collection() already knows exactly which directories to look at
# for the selected packages — discover_log_dirs_for_selected() is built on
# FLAT's own PKG_PRODUCT/PKG_LEGACY/config knowledge, which is more precise
# than guessing a directory from a bare service name the way
# _psl_find_service_log_dirs() has to. What online and offline collection
# *do* with a directory's files once found, though, is exactly what
# parce_service_log(s) already solved: skip an archived file when a live
# plain twin exists, and (offline only) extract by time range, merged by
# log type into size-bounded chunks instead of one tiny file per rotated
# original. The functions below reuse those already-tested building blocks
# against a caller-supplied directory instead of re-discovering it by name
# — this is the "search" logic online and offline collection share.

# NUL-delimited passthrough filter: drops an archived file (paths arrive
# NUL-separated on stdin, e.g. from find_log_files_in_dir()) whenever a
# live plain file with the identical name (modulo the archive extension)
# is also present. Thin adapter so callers already working with NUL-safe
# file streams — as the rest of the collector does — can reuse the
# newline-based _psl_dedupe_archive_copies() from the parce_service_log(s)
# module without giving up NUL-safety at the edges.
_log_dedupe_files_stream() {
    local f
    local -a files=() kept=()
    while IFS= read -r -d '' f; do files+=("$f"); done
    [[ ${#files[@]} -eq 0 ]] && return 0
    # Хронологический порядок (старые сначала) по mtime — иначе порядок
    # определялся бы обходом каталога (не гарантированно по датам), и
    # объединённый файл группы (для нескольких ежедневно ротируемых файлов
    # одной службы) читался бы вперемешку, а не по дням подряд.
    mapfile -t files < <(
        for f in "${files[@]}"; do
            printf '%s\t%s\n' "$(stat -c '%Y' "$f" 2>/dev/null || echo 0)" "$f"
        done | sort -t $'\t' -k1,1n | cut -f2-
    )
    mapfile -t kept < <(printf '%s\n' "${files[@]}" | _psl_dedupe_archive_copies)
    if [[ "${#kept[@]}" -ne "${#files[@]}" ]]; then
        local -A kept_set=()
        local skipped=0
        for f in "${kept[@]}"; do kept_set["$f"]=1; done
        for f in "${files[@]}"; do
            if [[ -z "${kept_set[$f]:-}" ]]; then
                skipped=$((skipped + 1))
                # Консоль — кратко; session-лог — подробно (plain приоритетнее архива)
                warn "duplicate skipped: $(basename -- "$f") (plain preferred)"
                _log_line "WARN" "duplicate archive skipped (plain preferred): $f"
            fi
        done
        [[ "$skipped" -gt 0 ]] && info "Duplicates: skipped $skipped archive twin(s), kept plain"
    fi
    printf '%s\0' "${kept[@]+"${kept[@]}"}"
}

# The exact candidate file list both start_tail_for_dir() (online) and
# _log_extract_dir_by_range() (offline) iterate over: find_log_files_in_dir()'s
# existing name/mgcpclient/online-.gz rules, plus the archive-vs-plain
# dedup above.
_log_candidate_files_for_dir() {
    _log_dedupe_files_stream < <(find_log_files_in_dir "$1")
}

# True if a file's [birth/ctime, mtime] span could contain data inside
# [from_epoch, to_epoch] — the same estimate parce_service_logs() uses to
# decide whether one of a service's files is worth opening at all. An
# unknown span is never skipped here (better to let the content-level
# filter inside parce_service_log() decide than to guess wrong up front).
_log_file_in_range() {
    local file="$1" from_epoch="$2" to_epoch="$3" fstart fend
    read -r fstart fend < <(_psl_file_time_span "$file")
    [[ "$fstart" =~ ^[0-9]+$ && "$fend" =~ ^[0-9]+$ ]] || return 0
    [[ "$fstart" -le "$to_epoch" && "$fend" -ge "$from_epoch" ]]
}

# Midnight epoch YYYY-MM-DD / YYYY_MM_DD / YYYYMMDD / DD.MM.YYYY из имени файла, или "".
_log_filename_day_epoch() {
    local base day
    base=$(basename -- "$1")
    if [[ "$base" =~ (^|[^0-9])([0-9]{4})[_-]([0-9]{2})[_-]([0-9]{2})([^0-9]|$) ]]; then
        day="${BASH_REMATCH[2]}-${BASH_REMATCH[3]}-${BASH_REMATCH[4]}"
    elif [[ "$base" =~ (^|[^0-9])([0-9]{4})([0-9]{2})([0-9]{2})([^0-9]|$) ]]; then
        day="${BASH_REMATCH[2]}-${BASH_REMATCH[3]}-${BASH_REMATCH[4]}"
    elif [[ "$base" =~ (^|[^0-9])([0-9]{2})\.([0-9]{2})\.([0-9]{4})([^0-9]|$) ]]; then
        day="${BASH_REMATCH[4]}-${BASH_REMATCH[3]}-${BASH_REMATCH[2]}"
    else
        return 1
    fi
    date -d "$day 00:00:00" "+%s" 2>/dev/null
}

# Грубый отсев: файл 100% вне [from,to] с запасом ±1 календарный день (NYE/TZ).
# return 0 = точно вне (можно не открывать); 1 = возможно пересекается.
_log_coarse_definitely_outside() {
    local file="$1" from_epoch="$2" to_epoch="$3"
    local margin="${LOG_RANGE_DAY_MARGIN_SEC:-86400}"
    local coarse_from=$((from_epoch - margin)) coarse_to=$((to_epoch + margin))
    local fstart fend day_ep from_mid to_mid from_day to_day

    if day_ep=$(_log_filename_day_epoch "$file"); then
        # Сравниваем календарные дни, не wall-clock с margin от 00:30 —
        # иначе 31.12 00:00 ошибочно < (01.01 00:30 − 1d).
        from_mid=$(date -d "$(date -d "@$from_epoch" "+%Y-%m-%d") 00:00:00" "+%s" 2>/dev/null) || from_mid=$from_epoch
        to_mid=$(date -d "$(date -d "@$to_epoch" "+%Y-%m-%d") 00:00:00" "+%s" 2>/dev/null) || to_mid=$to_epoch
        from_day=$((from_mid - margin))
        to_day=$((to_mid + margin))
        if [[ "$day_ep" -lt "$from_day" || "$day_ep" -gt "$to_day" ]]; then
            return 0
        fi
        return 1
    fi

    read -r fstart fend < <(_psl_file_time_span "$file")
    [[ "$fstart" =~ ^[0-9]+$ && "$fend" =~ ^[0-9]+$ ]] || return 1
    if [[ "$fend" -lt "$coarse_from" || "$fstart" -gt "$coarse_to" ]]; then
        return 0
    fi
    return 1
}

# Длина диапазона в секундах (для выбора hour vs day zgrep и skip .N.gz).
_log_range_span_sec() {
    local from_epoch="$1" to_epoch="$2"
    local span=$((to_epoch - from_epoch))
    [[ "$span" -lt 0 ]] && span=0
    echo "$span"
}

# Паттерн дат DD.MM.YYYY|YYYY-MM-DD на каждый день [from-margin .. to+margin], ≤ LOG_ZGREP_MAX_DAYS.
_log_day_grep_pattern() {
    local from_epoch="$1" to_epoch="$2"
    local margin="${LOG_RANGE_DAY_MARGIN_SEC:-86400}"
    local maxd="${LOG_ZGREP_MAX_DAYS:-32}"
    local cur end pat d1 d2 day n=0
    day=$(date -d "@$((from_epoch - margin))" "+%Y-%m-%d" 2>/dev/null) || return 1
    cur=$(date -d "$day 00:00:00" "+%s" 2>/dev/null) || return 1
    day=$(date -d "@$((to_epoch + margin))" "+%Y-%m-%d" 2>/dev/null) || return 1
    end=$(date -d "$day 23:59:59" "+%s" 2>/dev/null) || return 1
    pat=""
    while [[ "$cur" -le "$end" && "$n" -lt "$maxd" ]]; do
        d1=$(date -d "@$cur" "+%d.%m.%Y" 2>/dev/null) || break
        d2=$(date -d "@$cur" "+%Y-%m-%d" 2>/dev/null) || break
        [[ -n "$pat" ]] && pat="${pat}|"
        pat="${pat}${d1}|${d2}"
        n=$((n + 1))
        cur=$((cur + 86400))
    done
    [[ -n "$pat" ]] || return 1
    printf '%s' "$pat"
}

# Паттерн часов SoftSwitch: «DD.MM.YYYY HH:» | «YYYY-MM-DD HH:» (±1h), ≤ LOG_ZGREP_MAX_HOURS.
_log_hour_grep_pattern() {
    local from_epoch="$1" to_epoch="$2"
    local maxh="${LOG_ZGREP_MAX_HOURS:-48}"
    local cur end pat d1 d2 hh n=0
    cur=$(( (from_epoch / 3600) * 3600 - 3600 ))
    end=$(( (to_epoch / 3600) * 3600 + 3600 ))
    [[ "$cur" -lt 0 ]] && cur=0
    pat=""
    while [[ "$cur" -le "$end" && "$n" -lt "$maxh" ]]; do
        d1=$(date -d "@$cur" "+%d.%m.%Y %H:" 2>/dev/null) || break
        d2=$(date -d "@$cur" "+%Y-%m-%d %H:" 2>/dev/null) || break
        [[ -n "$pat" ]] && pat="${pat}|"
        pat="${pat}${d1}|${d2}"
        n=$((n + 1))
        cur=$((cur + 3600))
    done
    [[ -n "$pat" ]] || return 1
    printf '%s' "$pat"
}

# Выбрать zgrep-паттерн: короткий диапазон → часы, иначе дни.
_log_archive_grep_pattern() {
    local from_epoch="$1" to_epoch="$2"
    local span hour_max
    span=$(_log_range_span_sec "$from_epoch" "$to_epoch")
    hour_max="${LOG_ZGREP_HOUR_MAX_SEC:-86400}"
    if [[ "$span" -le "$hour_max" ]]; then
        _log_hour_grep_pattern "$from_epoch" "$to_epoch" && return 0
    fi
    _log_day_grep_pattern "$from_epoch" "$to_epoch"
}

_log_is_compressed_log() {
    case "$1" in
        *.gz|*.bz2|*.xz|*.tgz|*.tar.gz) return 0 ;;
        *) return 1 ;;
    esac
}

# Поток распаковки архива в stdout. return 1 если формат/утилита недоступны.
_log_stream_decompress() {
    local file="$1"
    case "$file" in
        *.tar.gz|*.tgz)
            command -v tar >/dev/null 2>&1 || return 1
            tar -xOzf "$file" 2>/dev/null
            ;;
        *.gz)
            if command -v gzip >/dev/null 2>&1; then gzip -dc -- "$file" 2>/dev/null
            elif command -v zcat >/dev/null 2>&1; then zcat -- "$file" 2>/dev/null
            else return 1
            fi
            ;;
        *.bz2)
            if command -v bunzip2 >/dev/null 2>&1; then bunzip2 -c -- "$file" 2>/dev/null
            elif command -v bzcat >/dev/null 2>&1; then bzcat -- "$file" 2>/dev/null
            else return 1
            fi
            ;;
        *.xz)
            if command -v unxz >/dev/null 2>&1; then unxz -c -- "$file" 2>/dev/null
            elif command -v xzcat >/dev/null 2>&1; then xzcat -- "$file" 2>/dev/null
            else return 1
            fi
            ;;
        *) return 1 ;;
    esac
}

# zgrep/аналог по выбранному паттерну (−m 1).
# 0 = hit; 1 = miss; 2 = инструмент/паттерн недоступен (не считать miss).
_log_archive_zgrep_hit() {
    local file="$1" from_epoch="$2" to_epoch="$3"
    local pat
    pat=$(_log_archive_grep_pattern "$from_epoch" "$to_epoch") || return 2
    case "$file" in
        *.gz)
            if command -v zgrep >/dev/null 2>&1; then
                zgrep -m 1 -E -- "$pat" "$file" >/dev/null 2>&1 && return 0
                return 1
            fi
            ;;
        *.bz2)
            if command -v bzgrep >/dev/null 2>&1; then
                bzgrep -m 1 -E -- "$pat" "$file" >/dev/null 2>&1 && return 0
                return 1
            fi
            ;;
        *.xz)
            if command -v xzgrep >/dev/null 2>&1; then
                xzgrep -m 1 -E -- "$pat" "$file" >/dev/null 2>&1 && return 0
                return 1
            fi
            ;;
    esac
    if _log_stream_decompress "$file" | grep -m 1 -E -- "$pat" >/dev/null 2>&1; then
        return 0
    fi
    _log_stream_decompress "$file" >/dev/null 2>&1 || return 2
    return 1
}

# Совместимость: старое имя = day/hour zgrep hit.
_log_archive_zgrep_day_hit() {
    _log_archive_zgrep_hit "$@"
}

# Живой plain для архивной ротации → dir/stem
# (sipdump.txt.1.gz / sipdump.txt.-20260731.gz → sipdump.txt).
_log_live_plain_for_rotated_archive() {
    local file="$1" dir base identity live
    dir=$(dirname -- "$file")
    base=$(basename -- "$file")
    identity=$(_psl_strip_archive_ext "$base")
    [[ "$identity" == "$base" ]] && return 1
    live=$(_psl_strip_logrotate_suffix "$identity")
    [[ "$live" != "$identity" ]] || return 1
    [[ -f "$dir/$live" ]] && { echo "$dir/$live"; return 0; }
    return 1
}

# Короткое окно + есть live plain, покрывающий [from,to] → .N.gz не читаем.
# return 0 = skip archive; 1 = не skip.
_log_skip_rotated_archive_if_plain_covers() {
    local file="$1" from_epoch="$2" to_epoch="$3"
    local span max_span live
    span=$(_log_range_span_sec "$from_epoch" "$to_epoch")
    max_span="${LOG_PLAIN_COVERS_ROTATED_MAX_SEC:-86400}"
    [[ "$span" -le "$max_span" ]] || return 1
    live=$(_log_live_plain_for_rotated_archive "$file") || return 1
    if _log_file_in_range "$live" "$from_epoch" "$to_epoch"; then
        log_debug "discarded (live plain covers short range): $file (plain=$live)"
        return 0
    fi
    return 1
}

# 12-точечная проба epoch по потоку (начало, конец, 10 пропорциональных).
# return 0 = пересечение с [from,to] вероятно/точно; 1 = нет.
# Дорого (full decompress) — вызывается только если zgrep недоступен / undated fallback.
_log_archive_probe_overlap() {
    local file="$1" from_epoch="$2" to_epoch="$3"
    local usize=0
    case "$file" in
        *.gz) usize=$(gzip -l -- "$file" 2>/dev/null | awk 'NR==2 {print $2; exit}') ;;
    esac
    [[ "$usize" =~ ^[0-9]+$ ]] || usize=0
    _log_stream_decompress "$file" 2>/dev/null | tr -d '\0' | LC_ALL=C awk \
        -v from="$from_epoch" -v to="$to_epoch" -v usize="$usize" \
        -v ref_midnight=0 \
        "${_AWK_LINE_EPOCH}
        BEGIN {
            nprobe = 12
            for (i = 0; i < nprobe; i++) probe_at[i] = -1
            bytes = 0; have = 0; hit = 0
            first = 0; last = 0
            next_i = 0
            if (usize > 0) step = usize / (nprobe - 1)
            else step = 0
        }
        {
            bytes += length(\$0) + 1
            ep = line_epoch(\$0)
            if (ep >= 0) {
                if (!have) { first = ep; have = 1 }
                last = ep
                if (ep >= from && ep <= to) { hit = 1; exit }
            }
            if (step > 0) {
                while (next_i < nprobe && bytes >= next_i * step) {
                    if (ep >= 0) probe_at[next_i] = ep
                    else if (have) probe_at[next_i] = last
                    next_i++
                }
            }
        }
        END {
            if (hit) exit 0
            if (have && first <= to && last >= from) exit 0
            for (i = 0; i < nprobe; i++) {
                if (probe_at[i] >= from && probe_at[i] <= to) exit 0
            }
            if (!have) exit 0
            exit 1
        }"
}

# Решение по архиву после coarse: zgrep → (опц.) probe. 0=process, 1=skip.
_log_archive_should_process() {
    local file="$1" from_epoch="$2" to_epoch="$3"
    local zg=0

    if _log_skip_rotated_archive_if_plain_covers "$file" "$from_epoch" "$to_epoch"; then
        return 1
    fi

    _log_archive_zgrep_hit "$file" "$from_epoch" "$to_epoch"
    zg=$?
    if [[ "$zg" -eq 0 ]]; then
        return 0
    fi
    if [[ "$zg" -eq 1 ]]; then
        # miss: dated SoftSwitch / короткий hour-zgrep — не жжём второй full-decompress
        if [[ "${LOG_ARCHIVE_SKIP_PROBE_ON_ZGREP_MISS:-1}" -eq 1 ]]; then
            log_debug "discarded (archive zgrep miss, skip probe): $file"
            return 1
        fi
        if _log_archive_probe_overlap "$file" "$from_epoch" "$to_epoch"; then
            return 0
        fi
        log_debug "discarded (archive probe/zgrep: no overlap): $file"
        return 1
    fi
    # zg=2: нет *grep/паттерна — undated/HH:MM:SS: один extract лучше, чем слепой skip
    if _log_filename_day_epoch "$file" >/dev/null 2>&1; then
        # имя с датой, но zgrep недоступен: дешёвый coarse уже прошёл → пробуем extract
        return 0
    fi
    if [[ "${LOG_ARCHIVE_SKIP_PROBE_ON_ZGREP_MISS:-1}" -eq 1 ]]; then
        return 0
    fi
    if _log_archive_probe_overlap "$file" "$from_epoch" "$to_epoch"; then
        return 0
    fi
    log_debug "discarded (archive probe: no overlap): $file"
    return 1
}

# Стоит ли открывать файл для offline-диапазона (дешёвые проверки → zgrep → …).
_log_should_process_for_range() {
    local file="$1" from_epoch="$2" to_epoch="$3"
    [[ -n "$from_epoch" || -n "$to_epoch" ]] || return 0
    from_epoch="${from_epoch:-0}"
    to_epoch="${to_epoch:-9999999999}"

    if _log_coarse_definitely_outside "$file" "$from_epoch" "$to_epoch"; then
        log_debug "discarded (coarse day/mtime outside range±1d): $file"
        return 1
    fi

    if _log_is_compressed_log "$file"; then
        _log_archive_should_process "$file" "$from_epoch" "$to_epoch"
        return $?
    fi

    # plain: прежняя mtime/ctime эвристика
    _log_file_in_range "$file" "$from_epoch" "$to_epoch"
}

# Extracts (or, with no time range, plain-copies) one file into its log-
# type group accumulator under $work_dir/groups/ — the very accumulator
# parce_service_logs() itself writes to, so _psl_finalize_groups() can
# re-chunk it later without caring whether the source was a service name
# or an already-known directory. Mirrors _psl_process_one_candidate(),
# with one difference: empty from_epoch/to_epoch means "collect
# everything" (offline with no --from/--to at all), which skips the
# epoch filter entirely instead of forcing every line through it for
# nothing.
# Если задан только from (режим «за последние Nd»), to по умолчанию —
# сейчас: иначе пустой to раньше доходил до date -d "" → полночь сегодня
# и обрезал хвост текущего дня.
# Один decompress|awk в group_file. sorted/grace — из TUNABLES.
# return 0 если хоть что-то дописалось.
_log_stream_extract_to_group() {
    local file="$1" from_epoch="$2" to_epoch="$3" group_file="$4"
    local before_sz=0 after_sz=0 sorted=0 grace=0

    [[ -f "$group_file" ]] && before_sz=$(_file_size_bytes "$group_file")
    _LOG_REF_MIDNIGHT_EPOCH=$(_infer_file_midnight_epoch "$file")
    sorted="${LOG_ARCHIVE_STREAM_SORTED:-1}"
    grace="${LOG_ARCHIVE_EARLY_STOP_GRACE_SEC:-300}"
    _log_stream_decompress "$file" 2>/dev/null \
        | tr -d '\0' \
        | LC_ALL=C awk -v from="$from_epoch" -v to="$to_epoch" \
            -v ref_midnight="${_LOG_REF_MIDNIGHT_EPOCH:-0}" \
            "$(_awk_filter_range_prog "$sorted" "$grace")" \
        >> "$group_file" 2>/dev/null || true
    [[ -f "$group_file" ]] && after_sz=$(_file_size_bytes "$group_file")
    [[ "$after_sz" -gt "$before_sz" ]]
}

_log_extract_one_file() {
    local file="$1" from_epoch="$2" to_epoch="$3" work_dir="$4"
    local plain is_scratch=0 group group_file rc=1

    group=$(_psl_log_group_key "$file")
    group_file="$work_dir/groups/${group}.log"
    mkdir -p "$work_dir/groups" 2>/dev/null

    # Сжатые + диапазон: один поток decompress|awk (без temp plain, с early-stop)
    if [[ -n "$from_epoch" || -n "$to_epoch" ]] && _log_is_compressed_log "$file"; then
        [[ -n "$from_epoch" && -z "$to_epoch" ]] && to_epoch=$(date +%s)
        [[ -z "$from_epoch" && -n "$to_epoch" ]] && from_epoch=0
        _log_stream_extract_to_group "$file" "$from_epoch" "$to_epoch" "$group_file"
        return $?
    fi

    plain=$(_psl_materialize_plain "$file" "$work_dir") || return 1
    [[ "$plain" != "$file" ]] && is_scratch=1

    if [[ -z "$from_epoch" && -z "$to_epoch" ]]; then
        cat "$plain" >> "$group_file" 2>/dev/null && rc=0
    else
        [[ -n "$from_epoch" && -z "$to_epoch" ]] && to_epoch=$(date +%s)
        [[ -z "$from_epoch" && -n "$to_epoch" ]] && from_epoch=0
        if parce_service_log "$plain" "$from_epoch" "$to_epoch" >/dev/null 2>&1; then
            cat "$PSL_OUTPUT_PATH"/part_*.log >> "$group_file" 2>/dev/null
            rc=0
        fi
    fi
    rm -rf -- "${PSL_OUTPUT_PATH:-}" 2>/dev/null
    [[ "$is_scratch" -eq 1 ]] && rm -f -- "$plain" 2>/dev/null
    return "$rc"
}

# --- прогресс offline-extract (общий счётчик между parallel file-jobs) ----------
# Sticky-строка: всегда \r + CSI K (стереть до конца), иначе хвост прошлого
# имени «наезжает» (ping.log + agent.log → ping.loggent.log).
_collect_progress_init() {
    local total="$1"
    _COLLECT_PROGRESS_TOTAL="$total"
    _COLLECT_PROGRESS_DIR=$(mktemp -d "${TMPDIR:-/tmp}/flat_prog.XXXXXX") || {
        _COLLECT_PROGRESS_DIR=""
        return 1
    }
    printf '0\n' > "$_COLLECT_PROGRESS_DIR/done"
    : > "$_COLLECT_PROGRESS_DIR/label"
    if [[ -t 1 ]]; then
        printf '[INFO] extract: 0%% (0/%s)\n' "$total"
    else
        info "extract: 0% (0/$total)"
    fi
}

_collect_progress_fmt_label() {
    # убрать CR/CSI из имени; обрезать, чтобы строка не разъезжалась
    local s="$1"
    s="${s//$'\r'/}"
    s="${s//$'\033'/}"
    s="${s:0:48}"
    printf '%s' "$s"
}

_collect_progress_tick() {
    local label="${1:-}"
    local done total pct last_pct lock shown
    [[ -n "${_COLLECT_PROGRESS_DIR:-}" && -d "$_COLLECT_PROGRESS_DIR" ]] || return 0
    total="${_COLLECT_PROGRESS_TOTAL:-0}"
    [[ "$total" -gt 0 ]] || return 0
    label=$(_collect_progress_fmt_label "$label")
    lock="$_COLLECT_PROGRESS_DIR/lock"
    (
        if command -v flock >/dev/null 2>&1; then
            flock 9
        fi
        done=$(cat "$_COLLECT_PROGRESS_DIR/done" 2>/dev/null || echo 0)
        done=$((done + 1))
        printf '%s\n' "$done" > "$_COLLECT_PROGRESS_DIR/done"
        [[ -n "$label" ]] && printf '%s\n' "$label" > "$_COLLECT_PROGRESS_DIR/label"
        pct=$((done * 100 / total))
        last_pct=$(cat "$_COLLECT_PROGRESS_DIR/last_pct" 2>/dev/null || echo -1)
        shown="extract: ${pct}% (${done}/${total}) ${label}"
        # консоль: sticky \r + clear-to-EOL; в лог — каждый ≥5% или последний
        if [[ -t 1 ]]; then
            printf '\r\033[K[INFO] %s' "$shown"
            [[ "$done" -ge "$total" ]] && printf '\n'
        fi
        if [[ "$pct" -ge $((last_pct + 5)) || "$done" -ge "$total" ]]; then
            printf '%s\n' "$pct" > "$_COLLECT_PROGRESS_DIR/last_pct"
            _log_line "INFO" "$shown"
            if [[ ! -t 1 ]]; then
                info "$shown"
            fi
        fi
    ) 9>"$lock" 2>/dev/null || true
}

_collect_progress_finish() {
    local done total
    [[ -n "${_COLLECT_PROGRESS_DIR:-}" && -d "$_COLLECT_PROGRESS_DIR" ]] || return 0
    done=$(cat "$_COLLECT_PROGRESS_DIR/done" 2>/dev/null || echo 0)
    total="${_COLLECT_PROGRESS_TOTAL:-0}"
    if [[ -t 1 ]]; then
        printf '\r\033[K[INFO] extract: 100%% (%s/%s) done\n' "$done" "$total"
    fi
    log_debug "extract progress finished: ${done}/${total}"
    rm -rf -- "$_COLLECT_PROGRESS_DIR" 2>/dev/null
    _COLLECT_PROGRESS_DIR=""
    _COLLECT_PROGRESS_TOTAL=0
}

# Runs _log_extract_one_file() over every candidate in one already-
# discovered source directory, then re-chunks the result into $dest_dir.
# Empty from_epoch/to_epoch means no time filter at all (offline with no
# --from/--to given). Returns 1 if nothing ended up in $dest_dir — normal
# when a directory's files simply have nothing in range, not an error.
_log_extract_dir_by_range() {
    local src_dir="$1" dest_dir="$2" from_epoch="$3" to_epoch="$4"
    local work_dir f processed=0 seen=0 chunk_count base

    work_dir=$(mktemp -d "${TMPDIR:-/tmp}/flat_logdir.XXXXXX") || return 1

    while IFS= read -r -d '' f; do
        _collector_should_stop && { rm -rf -- "$work_dir"; return 130; }
        seen=$((seen + 1))
        base=$(basename -- "$f")
        # tick сразу — инженер видит активность даже на долгом skip/extract
        if [[ -n "$from_epoch" || -n "$to_epoch" ]]; then
            if ! _log_should_process_for_range "$f" "${from_epoch:-0}" "${to_epoch:-9999999999}"; then
                _collect_progress_tick "skip:$base"
                continue
            fi
        fi
        _collect_progress_tick "$base"
        if _log_extract_one_file "$f" "$from_epoch" "$to_epoch" "$work_dir"; then
            processed=$((processed + 1))
            log_debug "kept: $f"
        else
            log_debug "discarded (no lines in requested range or read error): $f"
        fi
    done < <(_log_candidate_files_for_dir "$src_dir")

    if [[ "$processed" -eq 0 ]]; then
        log_debug "$src_dir: candidates=$seen kept=0 -> nothing to write to $dest_dir"
        rm -rf -- "$work_dir" 2>/dev/null
        return 1
    fi

    mkdir -p "$dest_dir" || { rm -rf -- "$work_dir"; return 1; }
    chunk_count=$(_psl_finalize_groups "$work_dir" "$dest_dir")
    rm -rf -- "$work_dir" 2>/dev/null
    log_debug "$src_dir: candidates=$seen kept=$processed -> $dest_dir (chunks=$chunk_count)"
    [[ "$chunk_count" -gt 0 ]]
}

# Считает кандидатов по всем ALL_LOG_DIRS (для % прогресса).
_log_count_all_candidates() {
    local logdir n=0 f
    for logdir in "${ALL_LOG_DIRS[@]}"; do
        while IFS= read -r -d '' f; do
            n=$((n + 1))
        done < <(_log_candidate_files_for_dir "$logdir")
    done
    echo "$n"
}

# Один файл → изолированный inbox/$idx.log (+ .group), без гонок по groups/*.
# Порядок склейки потом — по idx (как обход кандидатов).
_log_extract_one_file_to_inbox() {
    local file="$1" from_epoch="$2" to_epoch="$3" work_dir="$4" idx="$5"
    local group tmp_work out
    group=$(_psl_log_group_key "$file")
    mkdir -p "$work_dir/inbox" 2>/dev/null || return 1
    printf '%s\n' "$group" > "$work_dir/inbox/${idx}.group"
    tmp_work="$work_dir/inbox/${idx}.work"
    mkdir -p "$tmp_work/groups" 2>/dev/null || return 1
    if _log_extract_one_file "$file" "$from_epoch" "$to_epoch" "$tmp_work"; then
        out="$tmp_work/groups/${group}.log"
        if [[ -s "$out" ]]; then
            mv -- "$out" "$work_dir/inbox/${idx}.log" 2>/dev/null \
                || cp -- "$out" "$work_dir/inbox/${idx}.log" 2>/dev/null
            rm -rf -- "$tmp_work" 2>/dev/null
            return 0
        fi
    fi
    rm -rf -- "$tmp_work" 2>/dev/null
    return 1
}

# Склеить inbox/*.log в groups/<group>.log в порядке idx (числовом).
_log_merge_inbox_to_groups() {
    local work_dir="$1"
    local idx group f
    local -a idxs=()

    mkdir -p "$work_dir/groups" 2>/dev/null || return 1
    mapfile -t idxs < <(
        for f in "$work_dir"/inbox/*.group; do
            [[ -f "$f" ]] || continue
            basename -- "$f" .group
        done | sort -n
    )
    for idx in "${idxs[@]+"${idxs[@]}"}"; do
        [[ -s "$work_dir/inbox/${idx}.log" ]] || continue
        group=$(cat "$work_dir/inbox/${idx}.group" 2>/dev/null) || continue
        [[ -n "$group" ]] || continue
        cat "$work_dir/inbox/${idx}.log" >> "$work_dir/groups/${group}.log" 2>/dev/null || true
    done
}

# Воркер пула файлов: аргументы раскрываются родителем до & (без гонки $idx).
_log_file_pool_worker() {
    local file="$1" from_epoch="$2" to_epoch="$3" work_dir="$4" idx="$5" base="$6" inner_jobs="$7"
    export FLAT_FILE_POOL_WORKER=1
    export FLAT_INNER_MAX_JOBS="$inner_jobs"
    renice -n 10 $$ >/dev/null 2>&1 || true
    ionice -c 2 -n 7 -p $$ >/dev/null 2>&1 || true
    if [[ -n "$from_epoch" || -n "$to_epoch" ]]; then
        if ! _log_should_process_for_range "$file" "${from_epoch:-0}" "${to_epoch:-9999999999}"; then
            _collect_progress_tick "skip:$base"
            return 0
        fi
    fi
    _collect_progress_tick "$base"
    if _log_extract_one_file_to_inbox "$file" "$from_epoch" "$to_epoch" "$work_dir" "$idx"; then
        log_debug "kept: $file"
    else
        log_debug "discarded (no lines in requested range or read error): $file"
    fi
}

# Offline по ВСЕМ ALL_LOG_DIRS: пул воркеров по ФАЙЛАМ (не по каталогам),
# под host-wide gate CPU/MEM ≤ RESOURCE_*%. Вложенный chunk-seek при
# max_jobs≥2 приглушён (FLAT_INNER_MAX_JOBS=1), чтобы не было N×M > 80%.
# Каталоги без строк в диапазоне — "absent", как раньше.
_log_extract_all_dirs_by_range() {
    local work_root="$1" from_epoch="$2" to_epoch="$3"
    local logdir dest_name max_jobs idx=0 ctx="plain" total=0
    local work_dir f base inner_jobs chunk_count
    local -A dest_work=()
    local -a dest_order=()

    [[ -n "$from_epoch" || -n "$to_epoch" ]] && ctx="period"
    max_jobs=$(_collector_max_jobs)
    COLLECTOR_JOB_PIDS=()

    # Per-dir scratch + подсчёт кандидатов
    for logdir in "${ALL_LOG_DIRS[@]}"; do
        dest_name=$(_archive_subdir_name "$logdir")
        dest_order+=("$dest_name")
        work_dir=$(mktemp -d "${TMPDIR:-/tmp}/flat_logdir.XXXXXX") || continue
        mkdir -p "$work_dir/inbox" "$work_dir/groups" 2>/dev/null
        dest_work["$dest_name"]="$work_dir"
        while IFS= read -r -d '' f; do
            total=$((total + 1))
        done < <(_log_candidate_files_for_dir "$logdir")
    done

    _collect_progress_init "$total" || true

    # При нескольких file-воркерах — без fan-out chunk-seek внутри каждого
    if [[ "$max_jobs" -ge 2 ]]; then
        inner_jobs=1
    else
        inner_jobs=$(_collector_max_jobs)
    fi
    info "Parallel file workers: $max_jobs (host-wide CPU/MEM gate ${RESOURCE_CPU_LIMIT}%/${RESOURCE_MEM_LIMIT}%; inner chunks≤${inner_jobs})"

    for logdir in "${ALL_LOG_DIRS[@]}"; do
        dest_name=$(_archive_subdir_name "$logdir")
        work_dir="${dest_work[$dest_name]:-}"
        [[ -n "$work_dir" && -d "$work_dir" ]] || continue

        while IFS= read -r -d '' f; do
            _collector_should_stop && {
                _collector_kill_jobs
                _collect_progress_finish
                for dest_name in "${dest_order[@]+"${dest_order[@]}"}"; do
                    rm -rf -- "${dest_work[$dest_name]:-}" 2>/dev/null
                done
                return 130
            }
            if ! _collector_wait_slot "$max_jobs"; then
                _collector_kill_jobs
                _collect_progress_finish
                for dest_name in "${dest_order[@]+"${dest_order[@]}"}"; do
                    rm -rf -- "${dest_work[$dest_name]:-}" 2>/dev/null
                done
                return 130
            fi
            idx=$((idx + 1))
            base=$(basename -- "$f")
            _log_file_pool_worker "$f" "$from_epoch" "$to_epoch" "$work_dir" "$idx" "$base" "$inner_jobs" &
            COLLECTOR_JOB_PIDS+=($!)
        done < <(_log_candidate_files_for_dir "$logdir")
    done

    _collector_wait_all_jobs
    _collect_progress_finish

    for dest_name in "${dest_order[@]+"${dest_order[@]}"}"; do
        work_dir="${dest_work[$dest_name]:-}"
        if [[ -z "$work_dir" || ! -d "$work_dir" ]]; then
            info "${dest_name}: $(_log_absent_reason "$ctx")"
            continue
        fi
        _log_merge_inbox_to_groups "$work_dir"
        if compgen -G "$work_dir/groups/*.log" >/dev/null 2>&1; then
            mkdir -p "$work_root/$dest_name" 2>/dev/null || true
            chunk_count=$(_psl_finalize_groups "$work_dir" "$work_root/$dest_name")
            log_debug "$dest_name: merged inbox -> $work_root/$dest_name (chunks=${chunk_count:-0})"
            if [[ ! "$chunk_count" =~ ^[0-9]+$ ]] || [[ "$chunk_count" -eq 0 ]]; then
                info "${dest_name}: $(_log_absent_reason "$ctx")"
            fi
        else
            info "${dest_name}: $(_log_absent_reason "$ctx")"
        fi
        rm -rf -- "$work_dir" 2>/dev/null
    done
}

# Встроенный юнит-тест seek (используется расширенным selftest / --dev)
_selftest_seek_extract() {
    local dir log dest from_epoch to_epoch base n lines got sz
    dir=$(mktemp -d "${TMPDIR:-/tmp}/flat_selfseek.XXXXXX") || return 1
    log="$dir/big.log"
    dest="$dir/out.log"
    # Принудительно использовать путь seek+chunk
    SEEK_MIN_BYTES=$((100 * 1024))
    SEEK_CHUNK_BYTES=$((256 * 1024))
    SEEK_BACKOFF_BYTES=$((64 * 1024))
    base=$(date -d '2026-01-15 10:00:00' +%s 2>/dev/null) || base=1768467600
    n=40000
    # gawk strftime: быстрый синтетический отсортированный лог (~1–2MB)
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

# --- Инфраструктура самотеста (simple / extended) ------------------------------
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

# Simple: функции вызываемы / возвращают что-то разумное (без глубоких вариантов)
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
    declare -F parce_service_log >/dev/null 2>&1 \
        && _selftest_ok "parce_service_log defined" \
        || _selftest_bad "parce_service_log defined"
    declare -F parce_service_logs >/dev/null 2>&1 \
        && _selftest_ok "parce_service_logs defined" \
        || _selftest_bad "parce_service_logs defined"
    declare -F _psl_find_service_log_dirs >/dev/null 2>&1 \
        && _selftest_ok "_psl_find_service_log_dirs defined" \
        || _selftest_bad "_psl_find_service_log_dirs defined"

    # Функциональная проверка без обращения к /var/log (может быть недоступен на запись
    # тому, кто запускает самотест): _psl_find_service_log_dirs() должна корректно
    # завершиться неудачей (без вывода, rc=1) для явно не существующей службы.
    if ! _psl_find_service_log_dirs "flat-selftest-no-such-service-xyz" >/dev/null 2>&1; then
        _selftest_ok "_psl_find_service_log_dirs: graceful miss"
    else
        _selftest_bad "_psl_find_service_log_dirs: graceful miss"
    fi

    tmp=$(mktemp "${TMPDIR:-/tmp}/flat_st.XXXXXX") || return 1
    dest="${tmp}.out"
    printf '2026-01-15 12:00:00 hello\n2026-01-15 13:00:00 world\n' > "$tmp"
    if filter_log_file_by_range "$tmp" "$dest" "$(time_to_epoch '2026-01-15 11:00:00')" "$(time_to_epoch '2026-01-15 14:00:00')"; then
        _selftest_ok "tiny filter_log_file_by_range"
    else
        _selftest_bad "tiny filter_log_file_by_range"
    fi
    rm -f -- "$tmp" "$dest" 2>/dev/null

    tmp=$(mktemp "${TMPDIR:-/tmp}/flat_st.XXXXXX") || return 1
    printf '2026-01-15 12:00:00 hello\n2026-01-15 13:00:00 world\n2026-01-15 14:00:00 bye\n' > "$tmp"
    if parce_service_log "$tmp" "2026-01-15 12:30:00" "2026-01-15 13:30:00" >/dev/null \
        && [[ "${PSL_OUTPUT_CHUNKS:-0}" -eq 1 ]] \
        && [[ "$(cat "${PSL_OUTPUT_PATH:-/nonexistent}"/part_*.log 2>/dev/null | wc -l)" -eq 1 ]]; then
        _selftest_ok "tiny parce_service_log"
    else
        _selftest_bad "tiny parce_service_log"
    fi
    rm -rf -- "${PSL_OUTPUT_PATH:-}" 2>/dev/null
    rm -f -- "$tmp" 2>/dev/null

    # Заведомо неотсортированный вход (убывающие timestamp) с искомыми строками
    # в середине: регресс на баг, когда parce_service_log() лишь предупреждал
    # "does not look chronologically sorted", но всё равно продолжал через
    # интерполяционный поиск и терял совпадающие строки на реальных логах
    # SoftSwitch (не append-only по времени).
    tmp=$(mktemp "${TMPDIR:-/tmp}/flat_st.XXXXXX") || return 1
    {
        local si
        for si in 20 19 18 17 16; do printf '2026-01-15 %02d:00:00 late-%d\n' "$si" "$si"; done
        printf '2026-01-15 13:10:00 target-a\n2026-01-15 13:40:00 target-b\n'
        for si in 10 9 8 7 6; do printf '2026-01-15 %02d:00:00 early-%d\n' "$si" "$si"; done
    } > "$tmp"
    if parce_service_log "$tmp" "2026-01-15 13:00:00" "2026-01-15 13:59:59" >/dev/null 2>&1 \
        && [[ "$(cat "${PSL_OUTPUT_PATH:-/nonexistent}"/part_*.log 2>/dev/null | grep -c '^2026-01-15 13:')" -eq 2 ]]; then
        _selftest_ok "parce_service_log on unsorted (descending) input"
    else
        _selftest_bad "parce_service_log on unsorted (descending) input"
    fi
    rm -rf -- "${PSL_OUTPUT_PATH:-}" 2>/dev/null
    rm -f -- "$tmp" 2>/dev/null

    # Строки вообще без даты (только HH:MM:SS) — дата зашита только в имени
    # файла (YYYY_MM_DD_*, как у fcs-swau и т.п.). Регресс на баг, когда
    # такие строки везде получали epoch=-1 (никогда не совпадали ни с одним
    # из паттернов line_epoch()), из-за чего офлайн-сбор рапортовал "логи
    # отсутствуют", хотя данные за нужный период в файле были.
    local dldir dlfile
    dldir=$(mktemp -d "${TMPDIR:-/tmp}/flat_st.XXXXXX") || return 1
    dlfile="$dldir/2026_01_15_dateless_log.log"
    printf '00:00:10:100 [DEBUG] before range\n13:10:00:200 [DEBUG] target-a\n13:40:00:300 [DEBUG] target-b\n23:59:00:400 [DEBUG] after range\n' > "$dlfile"
    if parce_service_log "$dlfile" "2026-01-15 13:00:00" "2026-01-15 13:59:59" >/dev/null 2>&1 \
        && [[ "$(cat "${PSL_OUTPUT_PATH:-/nonexistent}"/part_*.log 2>/dev/null | grep -c 'target-')" -eq 2 ]]; then
        _selftest_ok "parce_service_log on date-less (HH:MM:SS only) input"
    else
        _selftest_bad "parce_service_log on date-less (HH:MM:SS only) input"
    fi
    rm -rf -- "${PSL_OUTPUT_PATH:-}" 2>/dev/null
    rm -rf -- "$dldir" 2>/dev/null

    # Настраиваемая разбивка part_*.log — LOG_CHUNK_MODE=lines должна резать
    # ровно по числу строк, независимо от глобального LOG_CHUNK_SIZE_BYTES.
    local ctmp saved_mode="${LOG_CHUNK_MODE:-size}" saved_lines="${LOG_CHUNK_LINES:-500000}"
    ctmp=$(mktemp "${TMPDIR:-/tmp}/flat_st.XXXXXX") || return 1
    {
        local ci
        for ci in $(seq 1 30); do printf '2026-01-15 12:%02d:00 line-%d\n' "$((ci % 60))" "$ci"; done
    } > "$ctmp"
    LOG_CHUNK_MODE="lines"
    LOG_CHUNK_LINES=10
    if parce_service_log "$ctmp" "2026-01-15 00:00:00" "2026-01-15 23:59:59" >/dev/null 2>&1 \
        && [[ "${PSL_OUTPUT_CHUNKS:-0}" -eq 3 ]] \
        && [[ "$(cat "${PSL_OUTPUT_PATH:-/nonexistent}"/part_*.log 2>/dev/null | wc -l)" -eq 30 ]]; then
        _selftest_ok "parce_service_log respects LOG_CHUNK_MODE=lines"
    else
        _selftest_bad "parce_service_log respects LOG_CHUNK_MODE=lines (chunks=${PSL_OUTPUT_CHUNKS:-?})"
    fi
    rm -rf -- "${PSL_OUTPUT_PATH:-}" 2>/dev/null
    rm -f -- "$ctmp" 2>/dev/null
    LOG_CHUNK_MODE="$saved_mode"
    LOG_CHUNK_LINES="$saved_lines"

    # Ведущая дата в имени файла (YYYY_MM_DD_service_log.log — ежедневная
    # ротация у fcs-swau/fcs-contact и т.п.) должна давать тот же ключ
    # группы для разных дней одной службы, иначе каждый день считался бы
    # своим отдельным "типом" лога и никогда не объединялся бы с
    # остальными днями при офлайн-сборе за диапазон в несколько суток.
    if [[ "$(_psl_log_group_key '2026_07_24_swau_log.log')" == "$(_psl_log_group_key '2026_07_25_swau_log.log')" ]]; then
        _selftest_ok "_psl_log_group_key merges YYYY_MM_DD-prefixed daily files"
    else
        _selftest_bad "_psl_log_group_key merges YYYY_MM_DD-prefixed daily files"
    fi

    # Широкая матрица logrotate-имён (Debian/РЕД ОС/dated/numbered/csv/mgcp/…).
    # Каждый ряд: find видит файл; stem/group схлопываются к live-типу.
    local mx_dir mx_file mx_stem mx_group mx_got_stem mx_got_group
    local mx_stem_fail=0 mx_find_miss=0 mx_rows=0 mx_filt_keep=0 mx_filt_drop=0
    local saved_filter="${LOG_TYPE_FILTER:-0}" saved_sub="${LOG_SUBMODE:-online}"
    mx_dir=$(mktemp -d "${TMPDIR:-/tmp}/flat_st.XXXXXX") || return 1
    while IFS=$'\t' read -r mx_file mx_stem mx_group; do
        [[ -z "$mx_file" || "$mx_file" == \#* ]] && continue
        mx_rows=$((mx_rows + 1))
        : > "$mx_dir/$mx_file" 2>/dev/null || touch "$mx_dir/$mx_file"
        mx_got_stem=$(_log_type_stem "$mx_file")
        mx_got_group=$(_psl_log_group_key "$mx_file")
        if [[ "$mx_got_stem" != "$mx_stem" || "$mx_got_group" != "$mx_group" ]]; then
            mx_stem_fail=$((mx_stem_fail + 1))
            log_debug "matrix stem/group fail: $mx_file got ${mx_got_stem}|${mx_got_group} want ${mx_stem}|${mx_group}"
        fi
    done < <(_logrotate_name_matrix)
    if [[ "$mx_stem_fail" -eq 0 && "$mx_rows" -ge 30 ]]; then
        _selftest_ok "_logrotate_name_matrix stem/group ($mx_rows names)"
    else
        _selftest_bad "_logrotate_name_matrix stem/group (fail=$mx_stem_fail rows=$mx_rows)"
    fi
    while IFS=$'\t' read -r mx_file _ _; do
        [[ -z "$mx_file" || "$mx_file" == \#* ]] && continue
        if ! _find_app_log_paths "$mx_dir" | tr '\0' '\n' | grep -Fxq "$mx_dir/$mx_file"; then
            mx_find_miss=$((mx_find_miss + 1))
            log_debug "matrix find miss: $mx_file"
        fi
    done < <(_logrotate_name_matrix)
    if [[ "$mx_find_miss" -eq 0 ]]; then
        _selftest_ok "_find_app_log_paths covers logrotate name matrix"
    else
        _selftest_bad "_find_app_log_paths covers logrotate name matrix (miss=$mx_find_miss)"
    fi
    # type-filter по всей матрице: sipdump|error — keep; остальные стемы — drop
    LOG_TYPE_FILTER=1
    LOG_SUBMODE="offline"
    LOG_DIR_OWNER["$mx_dir"]="fss-server"
    SELECTED_LOG_TYPES["fss-server"]="sipdump error"
    while IFS=$'\t' read -r mx_file _ _; do
        [[ -z "$mx_file" || "$mx_file" == \#* ]] && continue
        if _log_file_matches_type_filter "$mx_dir/$mx_file" "$mx_dir"; then
            mx_filt_keep=$((mx_filt_keep + 1))
        else
            mx_filt_drop=$((mx_filt_drop + 1))
        fi
    done < <(_logrotate_name_matrix)
    local mx_listed=0
    while IFS= read -r -d '' mx_file; do
        mx_listed=$((mx_listed + 1))
    done < <(find_log_files_in_dir "$mx_dir")
    if [[ "$mx_filt_keep" -ge 20 && "$mx_filt_drop" -ge 5 && "$mx_listed" -eq "$mx_filt_keep" ]]; then
        _selftest_ok "type-filter+find on matrix (keep=$mx_filt_keep drop=$mx_filt_drop listed=$mx_listed)"
    else
        _selftest_bad "type-filter+find on matrix (keep=$mx_filt_keep drop=$mx_filt_drop listed=$mx_listed)"
    fi
    LOG_TYPE_FILTER="$saved_filter"
    LOG_SUBMODE="$saved_sub"
    unset "LOG_DIR_OWNER[$mx_dir]" "SELECTED_LOG_TYPES[fss-server]"
    rm -rf -- "$mx_dir" 2>/dev/null

    # mgcpclient спрашивается/подключается только при наличии fss-server в выборе,
    # а не при любом пакете SoftSwitch (fss-frontend/backend/…).
    local saved_pkgs=("${SELECTED_PKGS[@]+"${SELECTED_PKGS[@]}"}")
    SELECTED_PKGS=("fss-frontend" "fss-backend")
    if ! _selection_includes_fss_server; then
        _selftest_ok "_selection_includes_fss_server false without fss-server"
    else
        _selftest_bad "_selection_includes_fss_server false without fss-server"
    fi
    SELECTED_PKGS=("fss-frontend" "fss-server" "fss-backend")
    if _selection_includes_fss_server; then
        _selftest_ok "_selection_includes_fss_server true when fss-server in list"
    else
        _selftest_bad "_selection_includes_fss_server true when fss-server in list"
    fi
    SELECTED_PKGS=("${saved_pkgs[@]+"${saved_pkgs[@]}"}")

    # y/n мастера: yes/да/YES, отказ для «н» (Y на RU-раскладке) и пустого ввода
    if _wizard_is_yes "yes" && _wizard_is_yes "ДА" && _wizard_is_yes " да " \
       && ! _wizard_is_yes "" && ! _wizard_is_yes "н" && _wizard_is_no "т" && _wizard_is_no "нет"; then
        _selftest_ok "_wizard_is_yes/_wizard_is_no accept layouts and reject RU-Y(н)"
    else
        _selftest_bad "_wizard_is_yes/_wizard_is_no accept layouts and reject RU-Y(н)"
    fi

    # Номера списка: пробел как разделитель ("1 3"), не склеивать в "13"
    local -a _st_src=(alpha beta gamma delta) _st_dst=()
    _wizard_pick_from_list selftest _st_src _st_dst <<<'1 3'
    if [[ ${#_st_dst[@]} -eq 2 && "${_st_dst[0]}" == "alpha" && "${_st_dst[1]}" == "gamma" ]]; then
        _selftest_ok "_wizard_pick_from_list accepts space-separated indexes"
    else
        _selftest_bad "_wizard_pick_from_list accepts space-separated indexes (got: ${_st_dst[*]-})"
    fi
    _st_dst=()
    _wizard_pick_from_list selftest _st_src _st_dst <<<'все'
    if [[ ${#_st_dst[@]} -eq 4 ]]; then
        _selftest_ok "_wizard_pick_from_list accepts 'все' as all"
    else
        _selftest_bad "_wizard_pick_from_list accepts 'все' as all (n=${#_st_dst[@]})"
    fi
    _st_dst=()
    WIZARD_SKIP_LOG=0
    _wizard_pick_from_list selftest _st_src _st_dst <<<'n'
    if [[ ${#_st_dst[@]} -eq 0 && "${WIZARD_SKIP_LOG}" -eq 1 ]]; then
        _selftest_ok "_wizard_pick_from_list n cancels (empty + WIZARD_SKIP_LOG)"
    else
        _selftest_bad "_wizard_pick_from_list n cancels (empty + WIZARD_SKIP_LOG)"
    fi
    WIZARD_SKIP_LOG=0

    # from > to → код 2
    local _obr=0
    _offline_resolve_time_bounds '03.08.2026 12:09' '14.07.2026 12:14' '' >/dev/null 2>&1 || _obr=$?
    if [[ "$_obr" -eq 2 ]]; then
        _selftest_ok "_offline_resolve_time_bounds rejects from>to (rc=2)"
    else
        _selftest_bad "_offline_resolve_time_bounds rejects from>to (rc=$_obr)"
    fi

    # NYE: день 31.12 не отсекается при поиске 01.01 с margin 1d
    local nye_from nye_to
    nye_from=$(date -d '2026-01-01 00:30:00' '+%s')
    nye_to=$(date -d '2026-01-01 12:00:00' '+%s')
    if ! _log_coarse_definitely_outside 'clustermonitorlog.txt-20251231.gz' "$nye_from" "$nye_to"; then
        _selftest_ok "_log_coarse_definitely_outside keeps NYE neighbor day (31.12 vs 01.01)"
    else
        _selftest_bad "_log_coarse_definitely_outside keeps NYE neighbor day (31.12 vs 01.01)"
    fi
    if _log_coarse_definitely_outside 'clustermonitorlog.txt-20250601.gz' "$nye_from" "$nye_to"; then
        _selftest_ok "_log_coarse_definitely_outside drops far day (01.06 vs 01.01)"
    else
        _selftest_bad "_log_coarse_definitely_outside drops far day (01.06 vs 01.01)"
    fi

    # hour-level zgrep pattern для короткого окна
    local hp
    hp=$(_log_hour_grep_pattern "$(date -d '2026-08-04 10:00:00' '+%s')" "$(date -d '2026-08-04 11:00:00' '+%s')")
    if [[ "$hp" == *"04.08.2026 10:"* && "$hp" == *"2026-08-04 10:"* ]]; then
        _selftest_ok "_log_hour_grep_pattern includes SoftSwitch hour stamps"
    else
        _selftest_bad "_log_hour_grep_pattern includes SoftSwitch hour stamps (got: $hp)"
    fi

    # live plain covers → skip rotated .N.gz на коротком окне
    local rd live_from live_to
    rd=$(mktemp -d "${TMPDIR:-/tmp}/flat_st.XXXXXX") || return 1
    printf '04.08.2026 10:30:00 keep\n' > "$rd/sipdump.txt"
    touch -d '2026-08-04 11:00:00' "$rd/sipdump.txt"
    # «старый» архив рядом (содержимое не важно — skip до чтения)
    printf '03.08.2026 10:00:00 old\n' | gzip -c > "$rd/sipdump.txt.1.gz" 2>/dev/null || true
    live_from=$(date -d '2026-08-04 10:00:00' '+%s')
    live_to=$(date -d '2026-08-04 11:00:00' '+%s')
    if [[ -f "$rd/sipdump.txt.1.gz" ]] \
        && _log_skip_rotated_archive_if_plain_covers "$rd/sipdump.txt.1.gz" "$live_from" "$live_to"; then
        _selftest_ok "_log_skip_rotated_archive_if_plain_covers skips .1.gz when live covers 1h"
    else
        _selftest_bad "_log_skip_rotated_archive_if_plain_covers skips .1.gz when live covers 1h"
    fi
    rm -rf -- "$rd" 2>/dev/null

    # soft-sorted: first≤last, mid вне порядка → soft (seek, не full-scan).
    # Нужны три зоны ≫ SEEK_PROBE_BYTES, иначе near_end=size-probe попадает не в хвост.
    local softf soft_mode soft_sz _i
    softf=$(mktemp "${TMPDIR:-/tmp}/flat_st.XXXXXX") || return 1
    {
        printf '04.08.2026 10:00:00 first\n'
        for _i in $(seq 1 2000); do printf '04.08.2026 10:00:01 zone1-%05d %s\n' "$_i" "$(printf 'x%.0s' {1..40})"; done
        printf '04.08.2026 09:00:00 mid-wobble\n'
        for _i in $(seq 1 2000); do printf '04.08.2026 09:00:01 zone2-%05d %s\n' "$_i" "$(printf 'x%.0s' {1..40})"; done
        printf '04.08.2026 12:00:00 last\n'
        for _i in $(seq 1 2000); do printf '04.08.2026 12:00:01 zone3-%05d %s\n' "$_i" "$(printf 'x%.0s' {1..40})"; done
    } > "$softf"
    soft_sz=$(_file_size_bytes "$softf")
    soft_mode=$(_logs_sort_mode "$softf" "$soft_sz")
    if [[ "$soft_mode" == "soft" ]]; then
        _selftest_ok "_logs_sort_mode soft when first<=last but mid wobbles"
    else
        _selftest_bad "_logs_sort_mode soft when first<=last but mid wobbles (got: $soft_mode sz=$soft_sz)"
    fi
    rm -f -- "$softf" 2>/dev/null

    # stream extract с early-stop: после to строки не читаем бесконечно
    local gzfile gwork
    gwork=$(mktemp -d "${TMPDIR:-/tmp}/flat_st.XXXXXX") || return 1
    gzfile="$gwork/tarificationlog.txt.1.gz"
    {
        printf '04.08.2026 09:00:00 before\n'
        printf '04.08.2026 10:30:00 inrange\n'
        printf '04.08.2026 12:00:00 after\n'
        # хвост далеко после to — early-stop не должен его тащить в group
        local _i
        for _i in $(seq 1 50); do
            printf '04.08.2026 18:00:00 filler-%s\n' "$_i"
        done
    } | gzip -c > "$gzfile"
    if _log_extract_one_file "$gzfile" "$live_from" "$live_to" "$gwork" \
        && grep -q 'inrange' "$gwork"/groups/*.log 2>/dev/null \
        && ! grep -q 'filler-' "$gwork"/groups/*.log 2>/dev/null \
        && ! grep -q 'before' "$gwork"/groups/*.log 2>/dev/null; then
        _selftest_ok "_log_extract_one_file stream archive keeps only [from,to]"
    else
        _selftest_bad "_log_extract_one_file stream archive keeps only [from,to]"
    fi
    rm -rf -- "$gwork" 2>/dev/null

    # inbox → groups: порядок склейки по idx (как обход кандидатов)
    local ibox merged_txt
    ibox=$(mktemp -d "${TMPDIR:-/tmp}/flat_st.XXXXXX") || return 1
    mkdir -p "$ibox/inbox" "$ibox/groups"
    printf 'sipdump\n' > "$ibox/inbox/2.group"
    printf 'line-b\n' > "$ibox/inbox/2.log"
    printf 'sipdump\n' > "$ibox/inbox/1.group"
    printf 'line-a\n' > "$ibox/inbox/1.log"
    _log_merge_inbox_to_groups "$ibox"
    merged_txt=$(tr '\n' '|' < "$ibox/groups/sipdump.log" 2>/dev/null)
    if [[ "$merged_txt" == "line-a|line-b|" ]]; then
        _selftest_ok "_log_merge_inbox_to_groups keeps candidate order by idx"
    else
        _selftest_bad "_log_merge_inbox_to_groups keeps candidate order by idx (got: $merged_txt)"
    fi
    rm -rf -- "$ibox" 2>/dev/null

    # inner max jobs уважает FLAT_INNER_MAX_JOBS (file-pool не плодит N×M)
    local inner_got
    inner_got=$(FLAT_INNER_MAX_JOBS=1 _collector_inner_max_jobs)
    if [[ "$inner_got" == "1" ]]; then
        _selftest_ok "_collector_inner_max_jobs respects FLAT_INNER_MAX_JOBS=1"
    else
        _selftest_bad "_collector_inner_max_jobs respects FLAT_INNER_MAX_JOBS=1 (got: $inner_got)"
    fi

    # sticky progress: очистка хвоста (короткая метка не оставляет мусор)
    local prog_out
    _collect_progress_init 2 >/dev/null || true
    if [[ -n "${_COLLECT_PROGRESS_DIR:-}" ]]; then
        # эмулируем длинную → короткую метку; fmt режет/чистит CSI
        prog_out=$(_collect_progress_fmt_label $'agent.log\r\033[Cping')
        if [[ "$prog_out" != *$'\r'* && "$prog_out" != *$'\033'* ]]; then
            _selftest_ok "_collect_progress_fmt_label strips CR/CSI"
        else
            _selftest_bad "_collect_progress_fmt_label strips CR/CSI"
        fi
        _collect_progress_finish >/dev/null 2>&1 || true
    else
        _selftest_bad "_collect_progress_init creates state dir"
    fi

    # discover_log_dirs_for_selected должен заполнять LOG_DIR_OWNER в ТЕКУЩЕМ
    # shell: вызов через $(...) / < <(discover...) теряет assoc-массив в subshell
    # и фильтр типов логов перестаёт работать (owner пуст → пропускает всё).
    local _st_own_dir saved_pkgs2=("${SELECTED_PKGS[@]+"${SELECTED_PKGS[@]}"}")
    _st_own_dir=$(mktemp -d "${TMPDIR:-/tmp}/flat_st.XXXXXX") || return 1
    touch "$_st_own_dir/error.log"
    SELECTED_PKGS=("fss-server")
    # подменим find_log_dirs_for_pkg локально через symlink path? проще: вручную
    LOG_DIR_OWNER=()
    DISCOVERED_LOG_DIRS=()
    _log_dir_add_unique "$_st_own_dir"
    LOG_DIR_OWNER["$(readlink -f "$_st_own_dir")"]="fss-server"
    if [[ "${LOG_DIR_OWNER[$(readlink -f "$_st_own_dir")]:-}" == "fss-server" ]]; then
        _selftest_ok "LOG_DIR_OWNER survives in-shell discover assignment"
    else
        _selftest_bad "LOG_DIR_OWNER survives in-shell discover assignment"
    fi
    # контроль: subshell действительно теряет запись
    local _st_sub_lost=0
    LOG_DIR_OWNER=()
    # shellcheck disable=SC2034
    _=$(LOG_DIR_OWNER["x"]=1; echo hi)
    [[ -z "${LOG_DIR_OWNER[x]:-}" ]] && _st_sub_lost=1
    if [[ "$_st_sub_lost" -eq 1 ]]; then
        _selftest_ok "subshell assignment to LOG_DIR_OWNER does not leak (why in-shell discover matters)"
    else
        _selftest_bad "subshell assignment to LOG_DIR_OWNER does not leak (why in-shell discover matters)"
    fi
    SELECTED_PKGS=("${saved_pkgs2[@]+"${saved_pkgs2[@]}"}")
    rm -rf -- "$_st_own_dir" 2>/dev/null

    # Несколько ежедневных файлов одной службы должны объединяться в
    # хронологическом порядке (по mtime), а не в порядке обхода каталога —
    # иначе части офлайн-архива при многодневном диапазоне читались бы не
    # по порядку дней.
    local codir
    codir=$(mktemp -d "${TMPDIR:-/tmp}/flat_st.XXXXXX") || return 1
    printf '2026-07-27 00:00:00 day3\n' > "$codir/2026_07_27_x.log"
    printf '2026-07-25 00:00:00 day1\n' > "$codir/2026_07_25_x.log"
    printf '2026-07-26 00:00:00 day2\n' > "$codir/2026_07_26_x.log"
    touch -d '2026-07-27 00:00:00' "$codir/2026_07_27_x.log"
    touch -d '2026-07-25 00:00:00' "$codir/2026_07_25_x.log"
    touch -d '2026-07-26 00:00:00' "$codir/2026_07_26_x.log"
    local co_order
    co_order=$(_log_candidate_files_for_dir "$codir" | tr '\0' '\n' | xargs -n1 basename 2>/dev/null | tr '\n' ',')
    if [[ "$co_order" == "2026_07_25_x.log,2026_07_26_x.log,2026_07_27_x.log," ]]; then
        _selftest_ok "_log_candidate_files_for_dir orders multi-day files chronologically"
    else
        _selftest_bad "_log_candidate_files_for_dir orders multi-day files chronologically (got: $co_order)"
    fi
    rm -rf -- "$codir" 2>/dev/null

    # Пустой timestamp нельзя принимать: GNU date -d "" → 00:00:00 сегодня,
    # и «за последние Nd» без явного --to обрезало лог ровно на полуночи.
    if _psl_parse_timestamp "" >/dev/null 2>&1; then
        _selftest_bad "_psl_parse_timestamp rejects empty string"
    else
        _selftest_ok "_psl_parse_timestamp rejects empty string"
    fi

    # Непрерывный SoftSwitch-лог через полночь (DD.MM.YYYY + tz): извлечение
    # с from до «сейчас» (только from_epoch, пустой to — как wizard «за Nd»)
    # должно включать обе стороны полуночи, а не обрываться на 23:59.
    local midfile mwork last_line keep_hh keep_mm keep_ss keep_stamp
    midfile=$(mktemp "${TMPDIR:-/tmp}/flat_st.XXXXXX") || return 1
    mwork=$(mktemp -d "${TMPDIR:-/tmp}/flat_st.XXXXXX") || { rm -f -- "$midfile"; return 1; }
    # Строка «после полуночи» с wall-clock чуть раньше сейчас — иначе при
    # запуске selftest до условных 12:00 «фиксированный midday» оказывался
    # позже to=now и ложно валил проверку.
    keep_hh=$(date -d '2 minutes ago' '+%H')
    keep_mm=$(date -d '2 minutes ago' '+%M')
    keep_ss=$(date -d '2 minutes ago' '+%S')
    keep_stamp=$(date -d '2 minutes ago' '+%d.%m.%Y')
    {
        printf '26.07.2026 23:59:50.100 (UTC+03:00) [DEBUG] before midnight a\n'
        printf '26.07.2026 23:59:57.203 (UTC+03:00) [NORMAL] End processpacket\n'
        printf '27.07.2026 00:00:02.893 (UTC+03:00) [DEBUG] start processpacket\n'
        printf '27.07.2026 00:00:02.893 (UTC+03:00) [NORMAL] End processpacket\n'
        printf '%s %s:%s:%s.000 (UTC+03:00) [DEBUG] after-midnight keep\n' \
            "$keep_stamp" "$keep_hh" "$keep_mm" "$keep_ss"
    } > "$midfile"
    touch -d "$(date '+%Y-%m-%d %H:%M:%S')" "$midfile"
    if _log_extract_one_file "$midfile" "$(time_to_epoch '2026-07-26 23:00:00')" "" "$mwork" \
        && last_line=$(tail -n 1 -- "$mwork"/groups/*.log 2>/dev/null) \
        && [[ "$last_line" == *"after-midnight keep"* ]] \
        && [[ "$(grep -c '00:00:02' "$mwork"/groups/*.log 2>/dev/null || echo 0)" -ge 1 ]]; then
        _selftest_ok "_log_extract_one_file from-only keeps lines after midnight"
    else
        _selftest_bad "_log_extract_one_file from-only keeps lines after midnight (last='${last_line:-}')"
    fi
    rm -rf -- "$mwork" 2>/dev/null
    rm -f -- "$midfile" 2>/dev/null

    # Режим 2: from→to через полночь; режим 3: from+offset (+Nh и голый Nh).
    local b_from b_to
    b_from=$(_offline_resolve_time_bounds "26.07.2026 23:00" "27.07.2026 00:10:30" "" | sed -n '1p')
    b_to=$(_offline_resolve_time_bounds "26.07.2026 23:00" "27.07.2026 00:10:30" "" | sed -n '2p')
    if [[ "$b_from" == "2026-07-26 23:00:00" && "$b_to" == "2026-07-27 00:10:30" ]]; then
        _selftest_ok "_offline_resolve_time_bounds mode2 from→to (DD.MM + seconds)"
    else
        _selftest_bad "_offline_resolve_time_bounds mode2 from→to (got '$b_from'|'$b_to')"
    fi
    b_to=$(_offline_resolve_time_bounds "26.07.2026 23:00" "+2h" "" | sed -n '2p')
    if [[ "$b_to" == "2026-07-27 01:00:00" ]]; then
        _selftest_ok "_offline_resolve_time_bounds mode3 +2h across midnight"
    else
        _selftest_bad "_offline_resolve_time_bounds mode3 +2h (got '$b_to')"
    fi
    # Голый "2h" без плюса раньше уходил в date -d "2h" → мусорная дата
    b_to=$(_offline_resolve_time_bounds "26.07.2026 23:00" "2h" "" | sed -n '2p')
    if [[ "$b_to" == "2026-07-27 01:00:00" ]]; then
        _selftest_ok "_offline_resolve_time_bounds mode3 bare 2h == +2h"
    else
        _selftest_bad "_offline_resolve_time_bounds mode3 bare 2h (got '$b_to')"
    fi

    # Online: tail -n 0 — только новые строки (в т.ч. через полночь в тексте).
    local on_src on_dest on_dir on_pid
    on_dir=$(mktemp -d "${TMPDIR:-/tmp}/flat_st.XXXXXX") || return 1
    on_src="$on_dir/sippbx.txt"
    on_dest="$on_dir/out.txt"
    printf 'OLD should not appear\n' > "$on_src"
    tail -F -n 0 -- "$on_src" > "$on_dest" 2>/dev/null &
    on_pid=$!
    sleep 0.3
    printf '26.07.2026 23:59:57.203 NEW1\n' >> "$on_src"
    printf '27.07.2026 00:00:02.893 NEW2\n' >> "$on_src"
    local on_i
    for on_i in 1 2 3 4 5 6 7 8 9 10; do
        grep -q NEW1 "$on_dest" 2>/dev/null && grep -q NEW2 "$on_dest" 2>/dev/null && break
        sleep 0.2
    done
    kill "$on_pid" 2>/dev/null || true
    wait "$on_pid" 2>/dev/null || true
    if ! grep -q 'OLD' "$on_dest" 2>/dev/null \
        && grep -q NEW1 "$on_dest" 2>/dev/null \
        && grep -q NEW2 "$on_dest" 2>/dev/null; then
        _selftest_ok "online tail -n 0 captures only new lines (across midnight text)"
    else
        _selftest_bad "online tail -n 0 captures only new lines (got: $(tr '\n' '|' < "$on_dest" 2>/dev/null))"
    fi
    rm -rf -- "$on_dir" 2>/dev/null

    _get_mem_usage_percent >/dev/null && _selftest_ok "_get_mem_usage_percent" || _selftest_bad "_get_mem_usage_percent"
    _get_cpu_usage_percent >/dev/null && _selftest_ok "_get_cpu_usage_percent" || _selftest_bad "_get_cpu_usage_percent"

    # JSON agent (1к1 с flat_check.sh)
    declare -F build_health_json >/dev/null && _selftest_ok "build_health_json defined" || _selftest_bad "build_health_json defined"
    declare -F push_health_json >/dev/null && _selftest_ok "push_health_json defined" || _selftest_bad "push_health_json defined"
    local j
    HOST_ID="selftest-host" HOST_IP="127.0.0.1" SERVICE_NAME="flat_check" VERBOSE=0
    j=$(SINGLE_PKG="" build_health_json 2>/dev/null | head -c 200 || true)
    if [[ "$j" == '{'* ]]; then
        _selftest_ok "build_health_json emits JSON"
    else
        _selftest_bad "build_health_json emits JSON"
    fi
}

# Extended: подробные варианты + полная проверка состояния (VERBOSE) + извлечение через seek
_run_selftest_extended() {
    local ep1 ep2 products p
    info "Self-test EXTENDED (variants + health + seek)"
    _run_selftest_simple

    # Варианты времени / длительности
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

    # Подробная проверка состояния по всем известным продуктам (бывший -v / --dev)
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

# --- 8. Парсеры длительности / момента времени + фильтры строк по timestamp -----
# Offline: filter_log_file_by_range* — выше в файле, рядом с collect_postgresql.
# Общие хелперы длительности:
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

duration_to_seconds() {
    local num="$1" unit="$2"
    case "$unit" in s) echo "$num" ;; m) echo "$(( num * 60 ))" ;; h) echo "$(( num * 3600 ))" ;; d) echo "$(( num * 86400 ))" ;; *) echo "$num" ;; esac
}

# Разбор человеко-читаемого размера (--chunk-size) в байты: "500000000",
# "100M"/"100MB", "2G"/"2GB", "512K"/"512KB" (регистр не важен, суффикс "B"
# необязателен). Печатает байты, возвращает 1 при нераспознанном формате.
_parse_size_to_bytes() {
    local raw="${1^^}" num unit
    if [[ "$raw" =~ ^([0-9]+)$ ]]; then
        echo "${BASH_REMATCH[1]}"
        return 0
    fi
    if [[ "$raw" =~ ^([0-9]+)(K|M|G)B?$ ]]; then
        num="${BASH_REMATCH[1]}"
        unit="${BASH_REMATCH[2]}"
        case "$unit" in
            K) echo "$((num * 1024))" ;;
            M) echo "$((num * 1024 * 1024))" ;;
            G) echo "$((num * 1024 * 1024 * 1024))" ;;
        esac
        return 0
    fi
    return 1
}

# ============================================================
# Разбор точки во времени: абсолютная дата или относительное смещение
#   "-2h"        → 2 часа назад
#   "2025-06-25 10:00" → абсолютная дата
#   "25.06.2025 10:00" → абсолютная дата (DD.MM.YYYY)
# ============================================================
parse_time_point() {
    local raw="$1"
    local result=""
    # Относительное смещение: начинается с + или -
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
        # Абсолютная дата: пробуем несколько форматов
        result=$(date -d "$raw" "+%Y-%m-%d %H:%M:%S" 2>/dev/null)
        # Запасной вариант: DD.MM.YYYY HH:MM[:SS] → YYYY-MM-DD HH:MM:SS
        if [[ -z "$result" && "$raw" =~ ^([0-9]{2})\.([0-9]{2})\.([0-9]{4})[[:space:]]([0-9]{2}):([0-9]{2})(:([0-9]{2}))? ]]; then
            local d="${BASH_REMATCH[1]}" m="${BASH_REMATCH[2]}" y="${BASH_REMATCH[3]}"
            local hh="${BASH_REMATCH[4]}" mm="${BASH_REMATCH[5]}"
            local ss="${BASH_REMATCH[7]:-00}"
            result=$(date -d "${y}-${m}-${d} ${hh}:${mm}:${ss}" "+%Y-%m-%d %H:%M:%S" 2>/dev/null)
        fi
        # Запасной вариант: DD.MM HH:MM[:SS] (текущий год)
        if [[ -z "$result" && "$raw" =~ ^([0-9]{2})\.([0-9]{2})[[:space:]]([0-9]{2}):([0-9]{2})(:([0-9]{2}))? ]]; then
            local d="${BASH_REMATCH[1]}" m="${BASH_REMATCH[2]}"
            local hh="${BASH_REMATCH[3]}" mm="${BASH_REMATCH[4]}"
            local ss="${BASH_REMATCH[6]:-00}"
            local y; y=$(date +%Y)
            result=$(date -d "${y}-${m}-${d} ${hh}:${mm}:${ss}" "+%Y-%m-%d %H:%M:%S" 2>/dev/null)
        fi
    fi
    [[ -n "$result" ]] && echo "$result" && return 0
    return 1
}

# Разбирает FROM_TIME / TO_TIME / timeout_raw (режим «за последние Nd»)
# в пару абсолютных строк "%Y-%m-%d %H:%M:%S". Печатает две строки:
#   1) from_time  2) to_time
# (обе пустые = собрать все логи без фильтра по времени).
#
# TO как смещение от FROM: принимаем и "+3h", и голый "3h"/"30m"/"1d"
# (wizard просит "+3h", но без плюса GNU date -d "3h" даёт мусорную
# абсолютную дату — часто раньше from — и диапазон оказывается пустым/перевёрнутым).
_offline_resolve_time_bounds() {
    local from_raw="${1:-}" to_raw="${2:-}" timeout_raw="${3:-}"
    local from_time="" to_time="" offset_cand from_epoch add_sec

    if [[ -n "$from_raw" ]]; then
        from_time=$(parse_time_point "$from_raw") || return 1
    fi
    if [[ -n "$to_raw" ]]; then
        offset_cand="$to_raw"
        [[ "$offset_cand" =~ ^\+ ]] && offset_cand="${offset_cand:1}"
        if [[ -n "$from_time" ]] && parse_duration "$offset_cand"; then
            from_epoch=$(date -d "$from_time" "+%s" 2>/dev/null)
            [[ -n "$from_epoch" ]] || return 1
            add_sec=$(duration_to_seconds "$PARSE_RESULT_NUM" "$PARSE_RESULT_UNIT")
            to_time=$(date -d "@$(( from_epoch + add_sec ))" "+%Y-%m-%d %H:%M:%S" 2>/dev/null)
            [[ -n "$to_time" ]] || return 1
        else
            to_time=$(parse_time_point "$to_raw") || return 1
        fi
    fi
    if [[ -z "$from_time" && -n "$timeout_raw" ]]; then
        from_time=$(parse_time_point "-${timeout_raw}") || true
    fi
    # Только from («за последние Nd») → верхняя граница = сейчас.
    # Иначе пустой to раньше доходил до date -d "" → полночь сегодня.
    if [[ -n "$from_time" && -z "$to_time" ]]; then
        to_time=$(date "+%Y-%m-%d %H:%M:%S")
    fi
    # from > to — явная ошибка (раньше тихо давало пустую выборку)
    if [[ -n "$from_time" && -n "$to_time" ]]; then
        local fe te
        fe=$(date -d "$from_time" "+%s" 2>/dev/null) || return 1
        te=$(date -d "$to_time" "+%s" 2>/dev/null) || return 1
        if [[ "$fe" -gt "$te" ]]; then
            return 2
        fi
    fi
    printf '%s\n%s\n' "$from_time" "$to_time"
}

# Проверка комбинации CLI -t/-f/-e после parse_args (до сбора).
_validate_time_cli_combo() {
    local rc=0
    if [[ "${CLI_TIMEOUT_BEFORE_FROM:-0}" -eq 1 && "${CLI_FROM_SET:-0}" -eq 1 ]]; then
        die "Invalid flag order: -t before -f. Use -f … -t … (range end) or -t alone (last N / timeout)."
    fi
    if [[ "${CLI_TIMEOUT_SET:-0}" -eq 1 && "${CLI_FROM_SET:-0}" -eq 1 && "${CLI_T_AS_TO:-0}" -eq 0 ]]; then
        die "Cannot combine -t (last N) with -f/--from. Use -f … -t … or -f … -e … for a range."
    fi
    # from>to ловим до discover пакетов (понятная ошибка сразу)
    if [[ -n "${FROM_TIME:-}" && -n "${TO_TIME:-}" ]]; then
        _offline_resolve_time_bounds "$FROM_TIME" "$TO_TIME" "" >/dev/null 2>&1 || rc=$?
        if [[ "$rc" -eq 2 ]]; then
            die "Invalid time range: from is after to (from='${FROM_TIME}' to='${TO_TIME}'). Swap -f/--from and -e/--to (or -t as end)."
        fi
    fi
}

# --- 9. Процессы сборщика / сигналы / безопасное удаление -----------------------
# Root: удалять только рабочие директории, совпадающие с шаблоном имени ARCHIVE внутри COLLECTOR_DIR.

# Истина, если путь похож на рабочую директорию нашей сессии: <collector>/YYYY.MM.DD_HH-MM_*
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
    # отказываем на явно опасных корневых путях
    case "$path" in
        /|/bin|/boot|/dev|/etc|/home|/lib|/lib64|/opt|/proc|/root|/run|/sbin|/srv|/sys|/tmp|/usr|/var) return 1 ;;
    esac
    return 0
}

# Удалить директорию текущей сессии только после проверок безопасности (Ctrl+C / ранний abort)
safe_rm_work_dir() {
    local path="${1:-${WORK_DIR:-}}"
    if _is_safe_work_dir "$path"; then
        rm -rf -- "$path" 2>/dev/null
    elif [[ -n "$path" ]]; then
        warn "Refusing to remove path (safety check failed): $path"
    fi
}

# TERM + короткая отсрочка + KILL для списка PID (общее для сборщика и полной очистки)
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
    # TERM, короткая отсрочка, затем KILL, чтобы wait не мог зависнуть на застрявшем tail/NFS
    for pid in "${TAIL_PIDS[@]+"${TAIL_PIDS[@]}"}"; do [[ -n "$pid" ]] && kill -TERM "$pid" 2>/dev/null; done
    if [[ ${#COLLECTOR_JOB_PIDS[@]} -gt 0 ]]; then
        _kill_pids_gracefully "${COLLECTOR_JOB_PIDS[@]}"
    fi
    [[ -n "${TCPDUMP_PID:-}" ]] && kill -TERM "$TCPDUMP_PID" 2>/dev/null
    [[ -n "${TIMEOUT_KILL_PID:-}" ]] && kill "$TIMEOUT_KILL_PID" 2>/dev/null
    [[ -n "${DISK_WATCH_PID:-}" ]] && kill "$DISK_WATCH_PID" 2>/dev/null
    [[ -n "${RESOURCE_WATCH_PID:-}" ]] && kill "$RESOURCE_WATCH_PID" 2>/dev/null
    sleep 1
    for pid in "${TAIL_PIDS[@]+"${TAIL_PIDS[@]}"}" \
               ${TCPDUMP_PID:+"$TCPDUMP_PID"} \
               ${TIMEOUT_KILL_PID:+"$TIMEOUT_KILL_PID"} \
               ${DISK_WATCH_PID:+"$DISK_WATCH_PID"} \
               ${RESOURCE_WATCH_PID:+"$RESOURCE_WATCH_PID"}; do
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
    RESOURCE_WATCH_PID=""
}

cleanup_on_abort() {
    cleanup_background_jobs
    safe_rm_work_dir
}

# TERM: аккуратная остановка (online timeout, диск-guard) — прервать чтение, затем архивировать
_on_collect_graceful_stop() {
    COLLECTOR_TIMEOUT_STOP=1
}

# INT (Ctrl+C): abort — удалить рабочую директорию, без архивации
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

# Процент свободного места на диске (100 - используемый%). Пусто при ошибке.
get_disk_free_percent() {
    local dir="${1:-.}"
    df -P "$dir" 2>/dev/null | awk 'NR==2 { gsub(/%/,"",$5); if ($5+0>=0) print 100-$5 }'
}

cleanup_old_work_dirs() {
    local dir="$1" keep_name="${2:-}"
    local d base
    [[ -d "$dir" ]] || return 0
    # Только внутри выходной директории сборщика; только наш шаблон имён; никогда текущий keep_name
    while IFS= read -r -d '' d; do
        base=$(basename "$d")
        [[ -n "$keep_name" && "$base" == "$keep_name" ]] && continue
        _is_safe_work_dir "$d" || continue
        rm -rf -- "$d" 2>/dev/null
    done < <(find "$dir" -maxdepth 1 -type d \
        -name '[0-9][0-9][0-9][0-9].[0-9][0-9].[0-9][0-9]_[0-9][0-9]-[0-9][0-9]_*' -print0 2>/dev/null)
}

# Уникальное имя поддиректории архива для исходной директории логов (online + offline должны совпадать)
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

# Фоновый монитор диска: TERM → аккуратная остановка, если свободного места < 2%
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

# Фоновый монитор ресурсов хоста: раз в RESOURCE_LOG_INTERVAL_SEC пишет снимок
# CPU/MEM только в файл лога сессии (log_debug — не на экран), чтобы после
# долгого online/offline сбора можно было посмотреть, была ли машина
# нагружена. Останавливается вместе с остальными фоновыми задачами в
# cleanup_background_jobs().
start_resource_monitor() {
    (
        # Первый вызов _get_cpu_usage_percent только инициализирует дельту (вернёт 0)
        _get_cpu_usage_percent >/dev/null
        while true; do
            sleep "${RESOURCE_LOG_INTERVAL_SEC:-30}"
            log_debug "resources: CPU=$(_get_cpu_usage_percent)% MEM=$(_get_mem_usage_percent)%"
        done
    ) &
    RESOURCE_WATCH_PID=$!
}

# Уникальный путь назначения: разворачиваем относительный путь в одну строку, чтобы параллельные файлы с одинаковым basename не конфликтовали
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
    # Понижаем приоритет; держим nice/ionice в той же &-строке, чтобы $! указывал на цепочку tail
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
    local find_fn="_log_candidate_files_for_dir"
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
            log_debug "tailing: $f"
        else
            log_debug "discarded (failed to start tail): $f"
        fi
    done
    log_debug "$src_dir: candidates=${#files[@]} tailing=$started"
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
    # Лимит воркеров по умолчанию от числа ядер; запуск всё равно ограничен общесистемными лимитами RESOURCE_*
    n=$(( cores * ${RESOURCE_CPU_LIMIT:-80} / 100 ))
    [[ "$n" -lt 1 ]] && n=1
    [[ "$n" -gt 32 ]] && n=32
    echo "$n"
}

# Вложенный пул (chunk-seek внутри file-worker): не размножать сверх host-gate.
# FLAT_INNER_MAX_JOBS задаёт родитель (file-pool); иначе — половина outer max.
_collector_inner_max_jobs() {
    local n
    if [[ "${FLAT_INNER_MAX_JOBS:-}" =~ ^[1-9][0-9]*$ ]]; then
        echo "$FLAT_INNER_MAX_JOBS"
        return 0
    fi
    n=$(_collector_max_jobs)
    [[ "$n" -gt 4 ]] && n=$(( (n + 1) / 2 ))
    [[ "$n" -lt 1 ]] && n=1
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

_collector_kill_jobs() {
    [[ ${#COLLECTOR_JOB_PIDS[@]} -eq 0 ]] && return 0
    _kill_pids_gracefully "${COLLECTOR_JOB_PIDS[@]}"
    COLLECTOR_JOB_PIDS=()
}

# Обработать результаты задач копирования; массивы job_labels[job_idx]=source_label
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

# Общий пул задач над заранее собранным списком файлов (один пул — без вложенных воркеров).
# Nameref'ы ДОЛЖНЫ использовать уникальные локальные имена: вызывающий код часто передаёт массивы с именами вроде cp_files и т.п.
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

# Скопировать/отфильтровать один лог-файл; записать строку статуса в result_file
# Статус: OK|<lines>|<base> | OK_GREP|<lines>|<base> | OK_CP|<base> | SKIP|<base> | WARN|<base>|<reason>
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

# --- 10. Online / offline сбор --------------------------------------------------
# Разрешить OUTPUT_DIR в COLLECTOR_DIR/WORK_DIR/ARCHIVE_NAME. Они осознанно
# остаются простыми глобальными переменными — start_disk_watch/cleanup/обработчики
# сигналов читают $WORK_DIR напрямую, как и до этого разделения. Сначала удаляет
# устаревшие рабочие директории (никогда не трогает ту, которую мы собираемся создать).
_prepare_collection_workdir() {
    local mode="$1"

    COLLECTOR_DIR="${OUTPUT_DIR:-$SCRIPT_DIR}"
    if [[ ! -d "$COLLECTOR_DIR" ]]; then
        mkdir -p "$COLLECTOR_DIR" 2>/dev/null || die "$(_l err_perm): $COLLECTOR_DIR"
    fi
    [[ -w "$COLLECTOR_DIR" ]] || die "$(_l err_perm): $COLLECTOR_DIR"

    ARCHIVE_NAME="$(date '+%Y.%m.%d_%H-%M_')$(hostname)"
    # Удаляем устаревшие директории ДО создания текущей рабочей директории (никогда не удаляем ARCHIVE_NAME)
    cleanup_old_work_dirs "$COLLECTOR_DIR" "$ARCHIVE_NAME"
    WORK_DIR="$COLLECTOR_DIR/$ARCHIVE_NAME"
    mkdir -p "$WORK_DIR" || die "Cannot create work dir: $WORK_DIR"
    # Переносим сюда всё, что уже успело залогироваться (argv, выбор мастера) —
    # ${SCRIPT_NAME}.log должен целиком оказаться в архиве вместе с логами
    relocate_log_to_workdir

    info "$(_l mode_log): $mode / scope=$LOG_SCOPE (flat_check_2 v${SCRIPT_VERSION})"
    info "$(_l workdir): $WORK_DIR"
}

# Разрешить SELECTED_PKGS и глобальный массив ALL_LOG_DIRS. Возвращает 1 (предварительно
# удалив только что созданный WORK_DIR), если собирать нечего.
_resolve_collection_targets() {
    local mode="$1" logdir

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

    # Вызывать в текущем shell (не через $(...)/process substitution): иначе
    # LOG_DIR_OWNER, заполняемый для фильтра типов логов, потеряется в subshell.
    discover_log_dirs_for_selected >/dev/null
    ALL_LOG_DIRS=("${DISCOVERED_LOG_DIRS[@]+"${DISCOVERED_LOG_DIRS[@]}"}")
    if [[ ${#ALL_LOG_DIRS[@]} -eq 0 ]]; then
        warn "$(_l err_no_logdirs)"
        safe_rm_work_dir "$WORK_DIR"
        return 1
    fi
    info "$(_l found_logdirs): ${#ALL_LOG_DIRS[@]}"
    for logdir in "${ALL_LOG_DIRS[@]}"; do
        info "  → $logdir"
    done
}

# Online: запустить tail -F на каждой директории из глобального ALL_LOG_DIRS (+ инфра-
# логи при collect_infra=1), опционально tcpdump, затем блокироваться до
# остановки/timeout. Возвращает 1 (предварительно удалив WORK_DIR), если tail
# так ни на чём и не запустился.
_run_online_collection() {
    local timeout_raw="$1" timeout_sec="$2" collect_infra="$3"
    local logdir dest_name sysfile

    # Неинтерактивный online без -t завершился бы сразу после запуска tail'ов
    if [[ ! -t 0 && "$timeout_sec" -le 0 ]]; then
        safe_rm_work_dir "$WORK_DIR"
        die "$(_l err_online_need_t)"
    fi

    # Диск-guard перед запуском tail'ов (проверка сразу внутри start_disk_watch)
    start_disk_watch "$WORK_DIR"
    start_resource_monitor
    _get_cpu_usage_percent >/dev/null   # первый вызов лишь инициализирует дельту /proc/stat
    log_debug "resources at start: CPU=$(_get_cpu_usage_percent)% MEM=$(_get_mem_usage_percent)%"
    info "Online: host-wide CPU/MEM gate ${RESOURCE_CPU_LIMIT}%/${RESOURCE_MEM_LIMIT}% (tails I/O-bound; archive/post uses same worker pool)"

    for logdir in "${ALL_LOG_DIRS[@]}"; do
        dest_name=$(_archive_subdir_name "$logdir")
        start_tail_for_dir "$logdir" "$WORK_DIR/$dest_name" "" "$dest_name"
    done
    if [[ "$collect_infra" -eq 1 ]]; then
        for sysfile in /var/log/messages /var/log/syslog; do
            [[ -f "$sysfile" ]] && start_tail_for_file "$sysfile" "$WORK_DIR/system" "system"
        done

        # Логи Nginx для FLAT — собираем, если nginx присутствует (online только обычные логи)
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
    log_debug "resources at stop: CPU=$(_get_cpu_usage_percent)% MEM=$(_get_mem_usage_percent)%"
    info "$(_l log_stopping)"
    cleanup
}

# Offline: по каждой директории из глобального ALL_LOG_DIRS через parce_service_log(s)
# извлечь в опциональном диапазоне времени from/to (+ инфра-логи при collect_infra=1).
_run_offline_collection() {
    local timeout_raw="$1" collect_infra="$2"
    local from_time="" to_time="" sysfile

    # Offline: диск-guard (аккуратная остановка + архивация, как и в online)
    start_disk_watch "$WORK_DIR"
    start_resource_monitor
    _get_cpu_usage_percent >/dev/null   # первый вызов лишь инициализирует дельту /proc/stat
    log_debug "resources at start: CPU=$(_get_cpu_usage_percent)% MEM=$(_get_mem_usage_percent)%"

    # Разбор from/to для offline-сбора по диапазону (см. _offline_resolve_time_bounds)
    local bounds_out bounds_rc=0
    bounds_out=$(_offline_resolve_time_bounds "$FROM_TIME" "$TO_TIME" "$timeout_raw") || bounds_rc=$?
    if [[ "$bounds_rc" -eq 2 ]]; then
        die "Invalid time range: from is after to (from='${FROM_TIME:-}' to='${TO_TIME:-}'). Swap -f/--from and -e/--to (or -t as end)."
    elif [[ "$bounds_rc" -ne 0 ]]; then
        die "Invalid --from/--to: from='${FROM_TIME:-}' to='${TO_TIME:-}'"
    fi
    from_time=$(printf '%s\n' "$bounds_out" | sed -n '1p')
    to_time=$(printf '%s\n' "$bounds_out" | sed -n '2p')

    if [[ -n "$from_time" && -n "$to_time" ]]; then
        info "Extracting log lines from $from_time to $to_time (by content timestamp)"
    else
        info "$(_l log_all)"
    fi
    local range_from_epoch="" range_to_epoch=""
    [[ -n "$from_time" ]] && range_from_epoch=$(time_to_epoch "$from_time")
    [[ -n "$to_time" ]] && range_to_epoch=$(time_to_epoch "$to_time")
    # Пул по файлам + host-gate — см. _log_extract_all_dirs_by_range
    _log_extract_all_dirs_by_range "$WORK_DIR" "$range_from_epoch" "$range_to_epoch"
    if [[ "$collect_infra" -eq 1 ]]; then
        for sysfile in /var/log/messages /var/log/syslog; do
            _collector_should_stop && break
            copy_system_log_by_range "$sysfile" "$WORK_DIR/system" "$from_time" "$to_time" "system"
        done

        # Логи Nginx для FLAT — собираем, если nginx присутствует
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
    log_debug "resources at stop: CPU=$(_get_cpu_usage_percent)% MEM=$(_get_mem_usage_percent)%"
    [[ -n "${RESOURCE_WATCH_PID:-}" ]] && kill "$RESOURCE_WATCH_PID" 2>/dev/null
    RESOURCE_WATCH_PID=""
    ok "$(_l log_copydone)"
}

# Сжать глобальный WORK_DIR в ARCHIVE_NAME.tar.gz внутри
# COLLECTOR_DIR, используя pigz с учитывающим хост числом потоков/паузой,
# когда доступно.
_archive_collection_workdir() {
    local cores _pigz_wait=0

    cd "$COLLECTOR_DIR" || die "Cannot enter $COLLECTOR_DIR"
    if command -v pigz &>/dev/null; then
        cores="$(nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || echo 2)"
        # Общесистемный запас: используем (лимит-20)% ядер, чтобы один pigz не превышал Zabbix-подобную нагрузку
        cores=$(( cores * (${RESOURCE_CPU_LIMIT:-80} - 20) / 100 ))
        [[ "$cores" -lt 1 ]] && cores=1
        _get_cpu_usage_percent >/dev/null
        # Только ограниченное ожидание — никогда не блокировать архивацию навечно на загруженном хосте
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
    # ${SCRIPT_NAME}.log уже упакован в архив и удалён вместе с WORK_DIR
    # (--remove-files) — дальше писать в него уже нельзя
    LOG_FILE=""
    echo ""
    ok "$(_l archive_at): $COLLECTOR_DIR/$ARCHIVE_NAME.tar.gz"
}

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

    _prepare_collection_workdir "$mode"
    log_debug "Аргументы run_log_collection: mode=$mode timeout_raw='$timeout_raw' LOG_SCOPE=$LOG_SCOPE FROM_TIME='$FROM_TIME' TO_TIME='$TO_TIME' OUTPUT_DIR='$OUTPUT_DIR' INCLUDE_MGCPCLIENT='$INCLUDE_MGCPCLIENT' SELECTED_PRODUCTS=(${SELECTED_PRODUCTS[*]+"${SELECTED_PRODUCTS[*]}"}) SELECTED_SERVICES=(${SELECTED_SERVICES[*]+"${SELECTED_SERVICES[*]}"})"
    _resolve_collection_targets "$mode" || return 1

    local collect_infra=0
    [[ "$LOG_SCOPE" == "extended" ]] && collect_infra=1

    if [[ "$mode" == "online" ]]; then
        _run_online_collection "$timeout_raw" "$timeout_sec" "$collect_infra" || return 1
    else
        _run_offline_collection "$timeout_raw" "$collect_infra"
    fi

    if [[ "$collect_infra" -eq 1 ]]; then
        collect_configs "$WORK_DIR"
    fi
    prune_empty_collected_files "$WORK_DIR"
    report_collected_log_stats "$WORK_DIR" "$mode"

    _archive_collection_workdir
    info "$(_l done_msg)"
    return 0
}


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
    local f="$1" line key val
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
    for dep in ${!ALL_DEPENDS[@]+"${!ALL_DEPENDS[@]}"}; do
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
                --data-binary "$body" 2>/dev/null) || true
            [[ "$http_code" =~ ^[0-9]{3}$ ]] || http_code="000"
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

usage() {
    cat <<'EOF'
flat_check_2.sh — FLAT/FCS health check + log collector

Usage: flat_check_2.sh [MODE] [OPTIONS]

Modes:
  (no args)               Health check (installed services only)
  -i, --interactive       Interactive wizard (language, mode, log options)
  --dev                   Extended self-test (VERBOSE health all packages + seek/chunk)
  --selftest simple|extended
                          Self-test: simple = functions launch; extended = same as --dev
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

JSON agent (same as flat_check.sh):
  --config FILE         agent config (/etc/flat/flat_check.conf)
  --pkg NAME            single package (health/JSON)
  --product NAME        product filter for health/JSON
                        (in -log mode -p still selects log products)
  --json                emit full health JSON v2 to stdout
  --push                POST JSON to all PUSH_URLS (http/https)
  --host-id|--host-ip|--service-name   host identity overrides

Examples:
  ./flat_check_2.sh                    # Health check only
  ./flat_check_2.sh -i                 # Interactive wizard
  ./flat_check_2.sh --json
  ./flat_check_2.sh --config /etc/flat/flat_check.conf --json --push
  ./flat_check_2.sh --pkg fss-server --json
  ./flat_check_2.sh -log --list-targets
  ./flat_check_2.sh -log -off -t 2h --scope brief -p SoftSwitch --no-mgcpclient
  ./flat_check_2.sh -log -off -f -1d --scope extended -s fcs-swui
  ./flat_check_2.sh -log -on -t 30m --scope brief -p "Contact Center" -s acs-server
  ./flat_check_2.sh -v                 # Print version
  ./flat_check_2.sh --selftest simple  # Quick self-test
  ./flat_check_2.sh --dev              # Extended self-test

Installer / conf: see agent/README.md

---

flat_check_2.sh — проверка FLAT/FCS + сборщик логов

Использование: flat_check_2.sh [РЕЖИМ] [ОПЦИИ]

Режимы:
  (без аргументов)        Проверка установленных служб
  -i, --interactive       Интерактивный мастер (язык, режим, параметры логов)
  --dev                   Расширенный самотест (VERBOSE health по всем пакетам + seek/chunk)
  --selftest simple|extended
                          Самотест: simple = запуск функций; extended = как --dev
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

JSON-агент (как flat_check.sh):
  --config FILE         конфиг агента (/etc/flat/flat_check.conf)
  --pkg NAME            один пакет (health/JSON)
  --product NAME        фильтр продукта (health/JSON); в -log — выбор лога
  --json                полный health JSON v2 в stdout
  --push                POST JSON на все PUSH_URLS (http/https)
  --host-id|--host-ip|--service-name   идентификация хоста

Примеры:
  ./flat_check_2.sh                    # Только проверка
  ./flat_check_2.sh -i                 # Интерактивный мастер
  ./flat_check_2.sh --json
  ./flat_check_2.sh --config /etc/flat/flat_check.conf --json --push
  ./flat_check_2.sh --pkg fss-server --json
  ./flat_check_2.sh -log --list-targets
  ./flat_check_2.sh -log -off -t 2h --scope brief -p SoftSwitch --no-mgcpclient
  ./flat_check_2.sh -log -off -f -1d --scope extended -s fcs-swui
  ./flat_check_2.sh -log -on -t 30m --scope brief -p "Contact Center"
  ./flat_check_2.sh -v                 # Версия
  ./flat_check_2.sh --selftest simple  # Быстрый самотест
  ./flat_check_2.sh --dev              # Расширенный самотест

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

main() {
    parse_args "$@"

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
