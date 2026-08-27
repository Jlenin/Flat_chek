# Модуль: 00_globals.sh
# Слой: core
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
# файла (lib/core/00_globals.sh), а не на точку входа `flat_check`. Точка
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
# (lib/core/09_argv.sh) разбирает их независимо от того, подключён ли
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

