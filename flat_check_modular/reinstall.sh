#!/bin/bash
# Переустановка flat_check_modular: тонкая обёртка над install.sh.
# install.sh и так безусловно перезаписывает дерево/бинарь-обёртку/cron при
# повторном запуске — единственное, чем управляет "переустановка" — сбрасывать
# ли существующий конфиг на шаблон (--force-conf) или сохранить как есть.
# Умолчание при отсутствии флага: НЕТ (конфиг сохраняется).
#
#   sudo ./reinstall.sh                     # спросит (Enter = нет, сохранить)
#   sudo ./reinstall.sh -y                  # сбросить конфиг на шаблон без вопроса
#   sudo ./reinstall.sh -n --push-token NEW # сохранить конфиг, обновить токен
#
# Остальные флаги (--dest/--bin/--conf-dir/--push-url/--host-id/--dry-run/…)
# прокидываются как есть в install.sh — см. его -h.
#
# Документация: README.md

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALLER="$SCRIPT_DIR/install.sh"

# Само-починка бита +x на всём тулките — см. тот же блок в install.sh.
chmod +x \
    "$SCRIPT_DIR/install.sh" \
    "$SCRIPT_DIR/reinstall.sh" \
    "$SCRIPT_DIR/uninstall.sh" \
    "$SCRIPT_DIR/flat_check" \
    2>/dev/null || true

die()  { echo "ERROR: $*" >&2; exit 1; }
info() { echo "[INFO] $*"; }

[[ -f "$INSTALLER" ]] || die "не найден $INSTALLER"

RESET_CONF=""   # "" = спросить; 1 = сбросить конфиг на шаблон; 0 = сохранить
pass_args=()

usage() {
    cat <<EOF
reinstall.sh — переустановка flat_check_modular (обёртка над install.sh)

Usage:
  sudo $0 [-y|-n] [опции install.sh...]

Конфиг:
  -y, --yes    сбросить конфиг на шаблон (эквивалент install --force-conf); значения
               из --push-url/--push-token/--host-id/… (если переданы) применяются к
               свежему конфигу так же, как при обычной установке
  -n, --no     сохранить существующий конфиг как есть (умолчание, если флаг не задан)

Остальные опции — те же, что у install.sh (--dest/--bin/--conf-dir/--conf/
--push-url/--push-token/--push-insecure/--host-id/--host-ip/--service-name/
--skip-cron/--cron-spec/--dry-run/--no-test/…) и передаются ему без изменений.
Полная справка: $INSTALLER -h

Документация: README.md
EOF
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -y|--yes) RESET_CONF=1; shift ;;
        -n|--no) RESET_CONF=0; shift ;;
        -h|--help) usage ;;
        *) pass_args+=("$1"); shift ;;
    esac
done

if [[ -z "$RESET_CONF" ]]; then
    if [[ -t 0 ]]; then
        read -r -p "Сбросить существующий конфиг на шаблон? [y/N] " ans
        case "$ans" in
            [Yy]*) RESET_CONF=1 ;;
            *) RESET_CONF=0 ;;
        esac
    else
        RESET_CONF=0
        info "неинтерактивный запуск без -y/-n — применяю умолчание для reinstall: сохранить конфиг"
    fi
fi

if [[ "$RESET_CONF" -eq 1 ]]; then
    info "конфиг будет сброшен на шаблон (--force-conf)"
    pass_args+=(--force-conf)
else
    info "существующий конфиг сохраняется (без --force-conf)"
fi

# bash "$INSTALLER" вместо exec "$INSTALLER": не требует бита +x на самом
# install.sh (например, после скачивания ZIP с GitHub, или на /home,
# смонтированном noexec).
exec bash "$INSTALLER" "${pass_args[@]}"
