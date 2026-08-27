# Модуль: 01_config.sh
# Слой: agent
# Назначение: Дефолты переменных JSON/push-агента (не затирают уже заданные CLI/env),
#   разбор конфиг-файла (--config FILE) с безопасным снятием кавычек/инлайн-комментариев.
# Публичные функции: _json_load_config(file), _conf_strip_value(raw)
# Зависит от: lib/core (переменные HOST_ID/HOST_IP/SERVICE_NAME/... уже объявлены
#   в lib/core/00_globals.sh; здесь только достраиваются PUSH_*-дефолты)
# Не зависит от: 02_json_build.sh, 03_push.sh — грузится первым в каталоге agent/
# Side effects: читает файл конфига с диска; заполняет глобальные переменные
#   (только если они ещё пустые — CLI и env имеют приоритет)
#
# Источник: перенесено без изменений логики из agent/json_report.inc.sh (строки 5-85).

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
: "${PUSH_INSECURE:=0}"
: "${SHOW_REPOS_JSON:=0}"

# Значение из "KEY=..." строки конфига: снимает окружающие кавычки и то, что
# после них (инлайн-комментарий) — например,
# SERVICE_NAME="fss-backend"    # см. service_names.md
# наивный ${val%\"} снимает кавычку только если она в самом конце строки, а
# ".*" в regex вызова уже захватил весь хвост вместе с комментарием, так что
# без этой функции в SERVICE_NAME утекало 'fss-backend"    # см. ...'.
_conf_strip_value() {
    local raw="$1" val
    if [[ "$raw" =~ ^[[:space:]]*\"(.*)$ ]]; then
        val="${BASH_REMATCH[1]%%\"*}"
    elif [[ "$raw" =~ ^[[:space:]]*\'(.*)$ ]]; then
        val="${BASH_REMATCH[1]%%\'*}"
    else
        val="${raw%%#*}"
        val="${val%"${val##*[![:space:]]}"}"
        val="${val#"${val%%[![:space:]]*}"}"
    fi
    printf '%s' "$val"
}

_json_load_config() {
    # Conf заполняет только пустые переменные: CLI и env имеют приоритет.
    local f="$1" line key val
    [[ -n "$f" && -f "$f" ]] || return 0
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ -z "${line//[[:space:]]/}" ]] && continue
        if [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
            key="${BASH_REMATCH[1]}"
            val="$(_conf_strip_value "${BASH_REMATCH[2]}")"
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
                PUSH_INSECURE)
                    [[ "$val" =~ ^[01]$ ]] && PUSH_INSECURE="$val"
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
