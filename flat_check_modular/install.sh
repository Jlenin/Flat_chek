#!/bin/bash
# Установка flat_check_modular на ноду: всё дерево (flat_check + lib/ + conf/),
# конфиг, cron. Идиома взята из agent/install_flat_check.sh (die/info/warn,
# --dry-run, безопасная подстановка в conf, само-починка +x) — отличие только
# в том, ЧТО ставится: не один файл, а целое дерево модулей.
#
#   sudo ./install.sh \
#     --push-url https://partner.example.local/api/v1/health/ingest \
#     --push-token SECRET \
#     --host-id ss-n1 \
#     --service-name fss-backend
#
# Документация: README.md, ARCHITECTURE.md

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Само-починка бита +x на всём тулките (install/reinstall/uninstall + сама
# точка входа flat_check): архив с GitHub ("Download ZIP") не всегда сохраняет
# исполняемый бит. Этот, самый первый скрипт, всё ещё нужно один раз сделать
# исполняемым руками (или запустить как `bash install.sh`) — дальше он чинит
# и себя, и соседей сам. lib/**/*.sh не входят в этот список: они никогда не
# запускаются напрямую, только через `source` из flat_check, поэтому им +x
# не нужен в принципе.
chmod +x \
    "$SCRIPT_DIR/install.sh" \
    "$SCRIPT_DIR/reinstall.sh" \
    "$SCRIPT_DIR/uninstall.sh" \
    "$SCRIPT_DIR/flat_check" \
    2>/dev/null || true

SRC_TREE="${SRC_TREE:-$SCRIPT_DIR}"
SRC_CONF="${SRC_CONF:-$SRC_TREE/conf/flat_check.conf.example}"

INSTALL_DEST="${INSTALL_DEST:-/opt/flat_check}"
INSTALL_BIN="${INSTALL_BIN:-/usr/local/bin/flat_check}"
CONF_DIR="${CONF_DIR:-/etc/flat}"
CONF_FILE="${CONF_FILE:-}"
LOG_DIR="${LOG_DIR:-}"          # default ниже: /var/log/flat или $CONF_DIR
CRON_FILE="${CRON_FILE:-/etc/cron.d/flat-check}"

PUSH_URLS="${PUSH_URLS:-}"
PUSH_TOKEN="${PUSH_TOKEN:-}"
PUSH_INSECURE="${PUSH_INSECURE:-}"
HOST_ID="${HOST_ID:-}"
HOST_IP="${HOST_IP:-}"
SERVICE_NAME="${SERVICE_NAME:-}"
CRON_SPEC="${CRON_SPEC:-*/5 * * * *}"

DRY_RUN=0
SKIP_CRON=0
FORCE_CONF=0
RUN_TEST=1
CONF_FILE_EXPLICIT=0

die()  { echo "ERROR: $*" >&2; exit 1; }
info() { echo "[INFO] $*"; }
warn() { echo "[WARN] $*"; }

need_arg() {
    [[ -n "${2:-}" && "$2" != -* ]] || die "нет значения для $1"
}

usage() {
    cat <<EOF
install.sh — установка flat_check_modular на ноду

Usage:
  sudo $0 [OPTIONS]

Пути:
  --src DIR               исходное дерево flat_check_modular (default: рядом с install.sh)
  --dest DIR              куда ставить дерево целиком (default: /opt/flat_check)
  --bin PATH              обёртка-исполняемый файл в PATH (default: /usr/local/bin/flat_check)
  --conf-dir DIR          каталог конфига (default: /etc/flat)
  --conf FILE             файл конфига (default: DIR/flat_check.conf)
  --log-dir DIR           каталог логов push (default: /var/log/flat или CONF_DIR)
  --cron FILE             файл cron.d (default: /etc/cron.d/flat-check)
  --cron-spec SPEC        расписание (default: '*/5 * * * *')
  --skip-cron             не создавать cron
  --force-conf            перезаписать существующий конфиг
  --no-test               не гонять пробный --json/--push

Параметры ноды (пишутся в conf при создании/перезаписи):
  --push-url URL          PUSH_URLS (несколько — через запятую)
  --push-token TOKEN      PUSH_TOKEN
  --push-insecure         PUSH_INSECURE=1 (не проверять TLS-сертификат приёмника, curl -k)
  --host-id ID            HOST_ID (default: hostname -s)
  --host-ip IP            HOST_IP
  --service-name NAME     SERVICE_NAME (fss-backend, fps-backend, …)

Прочее:
  --dry-run               только показать действия
  -h, --help              справка

Переменные окружения с теми же именами тоже принимаются.
EOF
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --src) need_arg "$1" "${2:-}"; SRC_TREE="$2"; shift 2 ;;
        --dest) need_arg "$1" "${2:-}"; INSTALL_DEST="$2"; shift 2 ;;
        --bin) need_arg "$1" "${2:-}"; INSTALL_BIN="$2"; shift 2 ;;
        --conf-dir)
            need_arg "$1" "${2:-}"
            CONF_DIR="$2"
            shift 2
            ;;
        --conf)
            need_arg "$1" "${2:-}"
            CONF_FILE="$2"
            CONF_FILE_EXPLICIT=1
            shift 2
            ;;
        --log-dir) need_arg "$1" "${2:-}"; LOG_DIR="$2"; shift 2 ;;
        --cron) need_arg "$1" "${2:-}"; CRON_FILE="$2"; shift 2 ;;
        --cron-spec) need_arg "$1" "${2:-}"; CRON_SPEC="$2"; shift 2 ;;
        --skip-cron) SKIP_CRON=1; shift ;;
        --force-conf) FORCE_CONF=1; shift ;;
        --no-test) RUN_TEST=0; shift ;;
        --push-url) need_arg "$1" "${2:-}"; PUSH_URLS="$2"; shift 2 ;;
        --push-token) need_arg "$1" "${2:-}"; PUSH_TOKEN="$2"; shift 2 ;;
        --push-insecure) PUSH_INSECURE=1; shift ;;
        --host-id) need_arg "$1" "${2:-}"; HOST_ID="$2"; shift 2 ;;
        --host-ip) need_arg "$1" "${2:-}"; HOST_IP="$2"; shift 2 ;;
        --service-name) need_arg "$1" "${2:-}"; SERVICE_NAME="$2"; shift 2 ;;
        --dry-run) DRY_RUN=1; shift ;;
        -h|--help) usage ;;
        *) die "неизвестный параметр: $1 (см. -h)" ;;
    esac
done

[[ -n "$HOST_ID" ]] || HOST_ID="$(hostname -s 2>/dev/null || hostname)"
[[ $CONF_FILE_EXPLICIT -eq 1 ]] || CONF_FILE="${CONF_FILE:-$CONF_DIR/flat_check.conf}"
if [[ -z "$LOG_DIR" ]]; then
    if [[ "$CONF_DIR" == "/etc/flat" ]]; then
        LOG_DIR="/var/log/flat"
    else
        LOG_DIR="$CONF_DIR"
    fi
fi

# Безопасная подстановка KEY="value" в conf (без sed по URL/токену).
_conf_set() {
    local file="$1" key="$2" val="$3"
    local out line done=0 esc
    esc=${val//\\/\\\\}
    esc=${esc//\"/\\\"}
    out=$(mktemp) || die "mktemp failed"
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" =~ ^#?${key}= ]]; then
            printf '%s="%s"\n' "$key" "$esc"
            done=1
        else
            printf '%s\n' "$line"
        fi
    done < "$file" > "$out"
    if [[ $done -eq 0 ]]; then
        printf '%s="%s"\n' "$key" "$esc" >> "$out"
    fi
    mv "$out" "$file"
}

run() {
    if [[ $DRY_RUN -eq 1 ]]; then
        info "DRY: $*"
        return 0
    fi
    "$@"
}

_can_write() {
    # достаточно, чтобы существовал записываемый родитель (каталоги создадим сами)
    local path="$1" dir
    [[ -w "$path" ]] && return 0
    dir=$(dirname -- "$path")
    while [[ ! -d "$dir" && "$dir" != "/" && "$dir" != "." && "$dir" != "" ]]; do
        dir=$(dirname -- "$dir")
    done
    [[ -n "$dir" && -d "$dir" && -w "$dir" ]]
}

if [[ $DRY_RUN -eq 0 && "$(id -u)" -ne 0 ]]; then
    # root не обязателен, если все целевые пути доступны на запись
    need=0
    _can_write "$INSTALL_DEST" || need=1
    _can_write "$INSTALL_BIN" || need=1
    _can_write "$CONF_FILE" || need=1
    _can_write "$LOG_DIR" || need=1
    if [[ $SKIP_CRON -eq 0 ]]; then
        _can_write "$CRON_FILE" || need=1
    fi
    if [[ $need -eq 1 ]]; then
        die "нужен root: sudo $0 ...   (локально: --dest/--bin/--conf-dir/--skip-cron; проверка: --dry-run)"
    fi
fi
[[ -f "$SRC_TREE/flat_check" ]] || die "не найден $SRC_TREE/flat_check (--src должен указывать на flat_check_modular/)"
[[ -d "$SRC_TREE/lib/core" ]] || die "не найден $SRC_TREE/lib/core"
[[ -f "$SRC_CONF" ]] || die "не найден $SRC_CONF"

if [[ -z "$SERVICE_NAME" ]]; then
    warn "SERVICE_NAME не задан — в JSON будет unknown (лучше --service-name fss-backend)"
fi

info "1) каталоги"
run install -d -m 0755 "$INSTALL_DEST" "$(dirname -- "$INSTALL_BIN")" "$CONF_DIR" "$LOG_DIR"

info "2) дерево flat_check_modular → $INSTALL_DEST"
if [[ $DRY_RUN -eq 1 ]]; then
    info "DRY: cp -a $SRC_TREE/{flat_check,lib,conf} $INSTALL_DEST/"
else
    cp -a "$SRC_TREE/flat_check" "$INSTALL_DEST/flat_check"
    cp -a "$SRC_TREE/lib" "$INSTALL_DEST/lib"
    cp -a "$SRC_TREE/conf" "$INSTALL_DEST/conf"
    chmod 0755 "$INSTALL_DEST/flat_check"
    # lib/**/*.sh подключаются только через `source` — им +x не нужен.
fi

info "2a) обёртка $INSTALL_BIN → $INSTALL_DEST/flat_check"
if [[ $DRY_RUN -eq 1 ]]; then
    info "DRY: write $INSTALL_BIN (exec $INSTALL_DEST/flat_check \"\$@\")"
else
    cat > "$INSTALL_BIN" <<EOF
#!/bin/bash
# Автосгенерировано install.sh — тонкая обёртка, реальный код в $INSTALL_DEST.
exec "$INSTALL_DEST/flat_check" "\$@"
EOF
    chmod 0755 "$INSTALL_BIN"
fi

if [[ -f "$CONF_FILE" && $FORCE_CONF -eq 0 ]]; then
    info "3) $CONF_FILE уже есть — оставляем как есть"
    if [[ -n "$PUSH_URLS$PUSH_TOKEN$PUSH_INSECURE$HOST_IP$SERVICE_NAME" ]]; then
        warn "флаги --push-* / --host-* / --service-name не применены (есть conf; нужен --force-conf)"
    fi
else
    info "3) пишем $CONF_FILE"
    if [[ $DRY_RUN -eq 1 ]]; then
        info "DRY: cp $SRC_CONF → $CONF_FILE + подстановка значений"
    else
        cp "$SRC_CONF" "$CONF_FILE"
        [[ -n "$PUSH_URLS" ]] && _conf_set "$CONF_FILE" PUSH_URLS "$PUSH_URLS"
        [[ -n "$PUSH_TOKEN" ]] && _conf_set "$CONF_FILE" PUSH_TOKEN "$PUSH_TOKEN"
        [[ -n "$PUSH_INSECURE" ]] && _conf_set "$CONF_FILE" PUSH_INSECURE "$PUSH_INSECURE"
        _conf_set "$CONF_FILE" HOST_ID "$HOST_ID"
        if [[ -n "$HOST_IP" ]]; then
            _conf_set "$CONF_FILE" HOST_IP "$HOST_IP"
        fi
        if [[ -n "$SERVICE_NAME" ]]; then
            _conf_set "$CONF_FILE" SERVICE_NAME "$SERVICE_NAME"
        fi
        chmod 0640 "$CONF_FILE"
    fi
fi

if [[ $SKIP_CRON -eq 0 ]]; then
    info "4) cron → $CRON_FILE ($CRON_SPEC)"
    if [[ $DRY_RUN -eq 1 ]]; then
        info "DRY: write $CRON_FILE"
    else
        cat > "$CRON_FILE" <<EOF
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

${CRON_SPEC} root ${INSTALL_BIN} --config ${CONF_FILE} --push >>${LOG_DIR}/flat_check_push.log 2>&1
EOF
        chmod 0644 "$CRON_FILE"
    fi
else
    info "4) cron пропущен (--skip-cron)"
fi

info "5) версия"
if [[ $DRY_RUN -eq 0 ]]; then
    "$INSTALL_BIN" -v || true
fi

if [[ $RUN_TEST -eq 1 && $DRY_RUN -eq 0 ]]; then
    info "6) пробный --json (фрагмент)"
    "$INSTALL_BIN" --config "$CONF_FILE" --json 2>/dev/null | head -c 200 || true
    echo ""
    urls=""
    if [[ -f "$CONF_FILE" ]]; then
        urls=$(grep -E '^PUSH_URLS=' "$CONF_FILE" | head -1 | cut -d= -f2- | tr -d '"')
    fi
    if [[ -n "$urls" && "$urls" != *example.local* && "$urls" != *example.com* ]]; then
        info "6b) пробный --push"
        "$INSTALL_BIN" --config "$CONF_FILE" --push || warn "push не удался — проверьте URL/токен/сеть"
    else
        info "6b) push пропущен (пустой PUSH_URLS или example.* в URL)"
    fi
fi

echo ""
info "готово"
info "  дерево: $INSTALL_DEST"
info "  бинарь: $INSTALL_BIN"
info "  конфиг: $CONF_FILE"
info "  cron:   $CRON_FILE"
info "  лог:    $LOG_DIR/flat_check_push.log"
info "Проверка:"
info "  $INSTALL_BIN --config $CONF_FILE --json | head -c 200"
info "  $INSTALL_BIN --config $CONF_FILE --push"
info "Док: $INSTALL_DEST/README.md"
