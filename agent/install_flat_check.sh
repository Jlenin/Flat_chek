#!/bin/bash
# Установщик агента flat_check на ноде продукта.
# Ставит бинарь, конфиг, cron; умеет dry-run и пробный --json/--push.
#
# Быстрый старт:
#   sudo ./agent/install_flat_check.sh \
#     --push-url https://partner.example.local/api/v1/health/ingest \
#     --push-token SECRET \
#     --host-id ss-n1 \
#     --service-name fss-backend
#
# Подробно: agent/README.md

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

SRC_CHECK="${SRC_CHECK:-$REPO_ROOT/flat_check.sh}"
SRC_CONF="${SRC_CONF:-$SCRIPT_DIR/flat_check.conf.example}"
SRC_CRON="${SRC_CRON:-$SCRIPT_DIR/cron.example}"

INSTALL_BIN="${INSTALL_BIN:-/usr/local/bin/flat_check}"
CONF_DIR="${CONF_DIR:-/etc/flat}"
CONF_FILE="${CONF_FILE:-$CONF_DIR/flat_check.conf}"
LOG_DIR="${LOG_DIR:-/var/log/flat}"
CRON_FILE="${CRON_FILE:-/etc/cron.d/flat-check}"

PUSH_URLS="${PUSH_URLS:-}"
PUSH_TOKEN="${PUSH_TOKEN:-}"
HOST_ID="${HOST_ID:-}"
HOST_IP="${HOST_IP:-}"
SERVICE_NAME="${SERVICE_NAME:-}"
CRON_SPEC="${CRON_SPEC:-*/5 * * * *}"
DRY_RUN=0
SKIP_CRON=0
FORCE_CONF=0
RUN_TEST=1
WITH_LOGS=0   # 1 = поставить ещё flat_check_2 как flat_check_2

die()  { echo "ERROR: $*" >&2; exit 1; }
info() { echo "[INFO] $*"; }
warn() { echo "[WARN] $*"; }

usage() {
    cat <<EOF
install_flat_check.sh — установка агента flat_check на ноду

Usage:
  sudo $0 [OPTIONS]

Options:
  --src FILE              путь к flat_check.sh (по умолчанию: ../flat_check.sh)
  --bin PATH              куда поставить бинарь (default: $INSTALL_BIN)
  --conf-dir DIR          каталог конфига (default: $CONF_DIR)
  --conf FILE             файл конфига (default: $CONF_FILE)
  --cron FILE             cron.d файл (default: $CRON_FILE)
  --cron-spec SPEC        расписание (default: '*/5 * * * *')
  --skip-cron             не ставить cron
  --force-conf            перезаписать существующий конфиг
  --no-test               не делать пробный прогон после установки

  --push-url URL          один или несколько URL (через запятую) → PUSH_URLS
  --push-token TOKEN      токен → PUSH_TOKEN
  --host-id ID            HOST_ID (default: hostname -s)
  --host-ip IP            HOST_IP (optional)
  --service-name NAME     SERVICE_NAME (fss-backend, fps-backend, …)

  --with-logs             также установить flat_check_2.sh → /usr/local/bin/flat_check_2
  --dry-run               только показать, что будет сделано
  -h, --help              справка

Env (альтернатива флагам): PUSH_URLS, PUSH_TOKEN, HOST_ID, HOST_IP, SERVICE_NAME,
  SRC_CHECK, INSTALL_BIN, CONF_FILE, CRON_FILE, CRON_SPEC
EOF
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --src) SRC_CHECK="$2"; shift 2 ;;
        --bin) INSTALL_BIN="$2"; shift 2 ;;
        --conf-dir) CONF_DIR="$2"; shift 2 ;;
        --conf) CONF_FILE="$2"; shift 2 ;;
        --cron) CRON_FILE="$2"; shift 2 ;;
        --cron-spec) CRON_SPEC="$2"; shift 2 ;;
        --skip-cron) SKIP_CRON=1; shift ;;
        --force-conf) FORCE_CONF=1; shift ;;
        --no-test) RUN_TEST=0; shift ;;
        --push-url) PUSH_URLS="$2"; shift 2 ;;
        --push-token) PUSH_TOKEN="$2"; shift 2 ;;
        --host-id) HOST_ID="$2"; shift 2 ;;
        --host-ip) HOST_IP="$2"; shift 2 ;;
        --service-name) SERVICE_NAME="$2"; shift 2 ;;
        --with-logs) WITH_LOGS=1; shift ;;
        --dry-run) DRY_RUN=1; shift ;;
        -h|--help) usage ;;
        *) die "Unknown option: $1 (try -h)" ;;
    esac
done

[[ -n "$HOST_ID" ]] || HOST_ID="$(hostname -s 2>/dev/null || hostname)"

run() {
    if [[ $DRY_RUN -eq 1 ]]; then
        info "DRY: $*"
        return 0
    fi
    "$@"
}

write_file() {
    local dest="$1" mode="$2"
    shift 2
    if [[ $DRY_RUN -eq 1 ]]; then
        info "DRY: write $dest (mode $mode)"
        return 0
    fi
    cat > "$dest"
    chmod "$mode" "$dest"
}

[[ $DRY_RUN -eq 1 || "$(id -u)" -eq 0 ]] || die "нужен root (или --dry-run)"
[[ -f "$SRC_CHECK" ]] || die "не найден $SRC_CHECK"
[[ -f "$SRC_CONF" ]] || die "не найден $SRC_CONF"

info "1) бинарь → $INSTALL_BIN"
if [[ $DRY_RUN -eq 1 ]]; then
    info "DRY: install -m 0755 $SRC_CHECK $INSTALL_BIN"
else
    install -m 0755 "$SRC_CHECK" "$INSTALL_BIN"
fi

if [[ $WITH_LOGS -eq 1 ]]; then
    src2="$REPO_ROOT/flat_check_2.sh"
    [[ -f "$src2" ]] || die "не найден $src2"
    info "1b) flat_check_2 → /usr/local/bin/flat_check_2"
    if [[ $DRY_RUN -eq 1 ]]; then
        info "DRY: install -m 0755 $src2 /usr/local/bin/flat_check_2"
    else
        install -m 0755 "$src2" /usr/local/bin/flat_check_2
    fi
fi

info "2) каталоги $CONF_DIR, $LOG_DIR"
run install -d -m 0755 "$CONF_DIR" "$LOG_DIR"

if [[ -f "$CONF_FILE" && $FORCE_CONF -eq 0 ]]; then
    info "3) $CONF_FILE уже есть — не трогаем (см. --force-conf)"
else
    info "3) пишем $CONF_FILE"
    if [[ $DRY_RUN -eq 1 ]]; then
        info "DRY: generate conf from $SRC_CONF"
    else
        cp "$SRC_CONF" "$CONF_FILE"
        # подставить значения
        if [[ -n "$PUSH_URLS" ]]; then
            if grep -q '^PUSH_URLS=' "$CONF_FILE"; then
                sed -i "s|^PUSH_URLS=.*|PUSH_URLS=\"${PUSH_URLS//\//\\/}\"|" "$CONF_FILE"
            else
                echo "PUSH_URLS=\"$PUSH_URLS\"" >> "$CONF_FILE"
            fi
        fi
        if [[ -n "$PUSH_TOKEN" ]]; then
            sed -i "s|^PUSH_TOKEN=.*|PUSH_TOKEN=\"${PUSH_TOKEN}\"|" "$CONF_FILE"
        fi
        sed -i "s|^HOST_ID=.*|HOST_ID=\"${HOST_ID}\"|" "$CONF_FILE"
        if [[ -n "$HOST_IP" ]]; then
            if grep -q '^#*HOST_IP=' "$CONF_FILE"; then
                sed -i "s|^#*HOST_IP=.*|HOST_IP=\"${HOST_IP}\"|" "$CONF_FILE"
            else
                echo "HOST_IP=\"$HOST_IP\"" >> "$CONF_FILE"
            fi
        fi
        if [[ -n "$SERVICE_NAME" ]]; then
            if grep -q '^SERVICE_NAME=' "$CONF_FILE"; then
                sed -i "s|^SERVICE_NAME=.*|SERVICE_NAME=\"${SERVICE_NAME}\"|" "$CONF_FILE"
            else
                echo "SERVICE_NAME=\"$SERVICE_NAME\"" >> "$CONF_FILE"
            fi
        fi
        chmod 0640 "$CONF_FILE"
    fi
fi

if [[ $SKIP_CRON -eq 0 ]]; then
    info "4) cron → $CRON_FILE ($CRON_SPEC)"
    write_file "$CRON_FILE" 0644 <<EOF
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

${CRON_SPEC} root ${INSTALL_BIN} --config ${CONF_FILE} --json --push >>${LOG_DIR}/flat_check_push.log 2>&1
EOF
else
    info "4) cron пропущен (--skip-cron)"
fi

info "5) проверка версии"
if [[ $DRY_RUN -eq 0 ]]; then
    "$INSTALL_BIN" -v || true
fi

if [[ $RUN_TEST -eq 1 && $DRY_RUN -eq 0 ]]; then
    info "6) пробный --json (без push, первые 200 байт)"
    "$INSTALL_BIN" --config "$CONF_FILE" --json 2>/dev/null | head -c 200 || true
    echo ""
    if grep -qE '^PUSH_URLS="[^"]+"|^PUSH_URLS=[^[:space:]#]+' "$CONF_FILE" 2>/dev/null; then
        urls=$(grep -E '^PUSH_URLS=' "$CONF_FILE" | head -1 | cut -d= -f2- | tr -d '"')
        if [[ -n "$urls" && "$urls" != *example.local* ]]; then
            info "6b) пробный --push"
            "$INSTALL_BIN" --config "$CONF_FILE" --push || warn "push не удался — проверьте URL/токен/сеть"
        else
            info "6b) push пропущен (в конфиге example.local или пустой PUSH_URLS)"
        fi
    fi
fi

echo ""
info "готово."
info "  бинарь:  $INSTALL_BIN"
info "  конфиг:  $CONF_FILE"
info "  cron:    $CRON_FILE"
info "  лог:     $LOG_DIR/flat_check_push.log"
info "Ручной прогон:"
info "  $INSTALL_BIN --config $CONF_FILE --json"
info "  $INSTALL_BIN --config $CONF_FILE --json --push"
info "Документация: $SCRIPT_DIR/README.md"
