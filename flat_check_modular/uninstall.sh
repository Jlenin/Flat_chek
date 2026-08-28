#!/bin/bash
# Удаление flat_check_modular с ноды: дерево в --dest, обёртка в --bin, cron.
# Каталог конфига — по запросу (умолчание при отсутствии флага: ДА).
#
#   sudo ./uninstall.sh          # спросит (Enter = да, удалить конфиг)
#   sudo ./uninstall.sh -y       # удалить конфиг без вопроса
#   sudo ./uninstall.sh -n       # оставить конфиг без вопроса
#
# Документация: README.md

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Само-починка бита +x на всём тулките — см. тот же блок в install.sh.
chmod +x \
    "$SCRIPT_DIR/install.sh" \
    "$SCRIPT_DIR/reinstall.sh" \
    "$SCRIPT_DIR/uninstall.sh" \
    "$SCRIPT_DIR/flat_check" \
    2>/dev/null || true

INSTALL_DEST="${INSTALL_DEST:-/opt/flat_check}"
INSTALL_BIN="${INSTALL_BIN:-/usr/local/bin/flat_check}"
CONF_DIR="${CONF_DIR:-/etc/flat}"
CRON_FILE="${CRON_FILE:-/etc/cron.d/flat-check}"

DRY_RUN=0
PURGE_CONF=""   # "" = спросить; 1 = удалить конфиг; 0 = оставить

die()  { echo "ERROR: $*" >&2; exit 1; }
info() { echo "[INFO] $*"; }

need_arg() {
    [[ -n "${2:-}" && "$2" != -* ]] || die "нет значения для $1"
}

usage() {
    cat <<EOF
uninstall.sh — удаление flat_check_modular с ноды

Usage:
  sudo $0 [OPTIONS]

Пути (те же default, что у install.sh):
  --dest DIR        установленное дерево (default: /opt/flat_check)
  --bin PATH        обёртка-исполняемый файл (default: /usr/local/bin/flat_check)
  --conf-dir DIR    каталог конфига (default: /etc/flat)
  --cron FILE       файл cron.d (default: /etc/cron.d/flat-check)

Конфиг (каталог --conf-dir целиком, включая flat_check.conf):
  -y, --yes         удалить без вопроса (умолчание, если флаг не задан вовсе)
  -n, --no          оставить без вопроса

Прочее:
  --dry-run         только показать действия
  -h, --help        справка

Логи (LOG_DIR, обычно /var/log/flat) не удаляются — только дерево/бинарь-обёртка/
cron и, по запросу, конфиг.
EOF
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dest) need_arg "$1" "${2:-}"; INSTALL_DEST="$2"; shift 2 ;;
        --bin) need_arg "$1" "${2:-}"; INSTALL_BIN="$2"; shift 2 ;;
        --conf-dir) need_arg "$1" "${2:-}"; CONF_DIR="$2"; shift 2 ;;
        --cron) need_arg "$1" "${2:-}"; CRON_FILE="$2"; shift 2 ;;
        -y|--yes) PURGE_CONF=1; shift ;;
        -n|--no) PURGE_CONF=0; shift ;;
        --dry-run) DRY_RUN=1; shift ;;
        -h|--help) usage ;;
        *) die "неизвестный параметр: $1 (см. -h)" ;;
    esac
done

run() {
    if [[ $DRY_RUN -eq 1 ]]; then
        info "DRY: $*"
        return 0
    fi
    "$@"
}

_can_write() {
    local path="$1" dir
    [[ -w "$path" ]] && return 0
    dir=$(dirname -- "$path")
    while [[ ! -d "$dir" && "$dir" != "/" && "$dir" != "." && "$dir" != "" ]]; do
        dir=$(dirname -- "$dir")
    done
    [[ -n "$dir" && -d "$dir" && -w "$dir" ]]
}

if [[ $DRY_RUN -eq 0 && "$(id -u)" -ne 0 ]]; then
    need=0
    _can_write "$INSTALL_DEST" || need=1
    _can_write "$INSTALL_BIN" || need=1
    _can_write "$CRON_FILE" || need=1
    _can_write "$CONF_DIR" || need=1
    if [[ $need -eq 1 ]]; then
        die "нужен root: sudo $0 ...   (проверка: --dry-run)"
    fi
fi

info "1) cron"
if [[ -f "$CRON_FILE" ]]; then
    run rm -f -- "$CRON_FILE"
else
    info "   $CRON_FILE не найден — пропуск"
fi

info "2) обёртка $INSTALL_BIN"
if [[ -f "$INSTALL_BIN" ]]; then
    run rm -f -- "$INSTALL_BIN"
else
    info "   $INSTALL_BIN не найден — пропуск"
fi

info "3) дерево $INSTALL_DEST"
if [[ -d "$INSTALL_DEST" ]]; then
    run rm -rf -- "$INSTALL_DEST"
else
    info "   $INSTALL_DEST не найден — пропуск"
fi

if [[ -z "$PURGE_CONF" ]]; then
    if [[ -t 0 ]]; then
        read -r -p "Удалить каталог конфига $CONF_DIR ? [Y/n] " ans
        case "$ans" in
            [Nn]*) PURGE_CONF=0 ;;
            *) PURGE_CONF=1 ;;
        esac
    else
        PURGE_CONF=1
        info "неинтерактивный запуск без -y/-n — применяю умолчание для uninstall: удалить конфиг"
    fi
fi

info "4) конфиг ($CONF_DIR)"
if [[ "$PURGE_CONF" -eq 1 ]]; then
    if [[ -d "$CONF_DIR" ]]; then
        run rm -rf -- "$CONF_DIR"
    else
        info "   $CONF_DIR не найден — пропуск"
    fi
else
    info "   оставлен как есть"
fi

echo ""
info "готово (лог-каталог не тронут, см. LOG_DIR у install.sh)"
