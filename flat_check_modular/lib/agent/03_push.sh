# Модуль: 03_push.sh
# Слой: agent
# Назначение: Отправка собранного JSON на PUSH_URLS (http/https, с ретраями
#   и диагностикой curl) и верхнеуровневый диспетчер run_health_json(),
#   вызываемый из lib/core/09_argv.sh при --json/--push.
# Публичные функции: push_health_json(body), run_health_json()
# Зависит от: 01_config.sh (_json_load_config), 02_json_build.sh
#   (build_health_json, _json_print, _json_ensure_identity), lib/core
#   (warn/info/fail/log_debug)
# Не зависит от: lib/logging
# Side effects: запускает curl (сетевые запросы наружу), пишет временные файлы
#   /tmp/flat_push_body.$$ и /tmp/flat_push_err.$$ (удаляются сразу после использования)
#
# Источник: перенесено без изменений логики из agent/json_report.inc.sh
#   (push_health_json — строки 576-650; run_health_json — строки 668-679).

# Отправка JSON на все URL из PUSH_URLS (http/https).
# PUSH_INSECURE=1 — не проверять TLS-сертификат (curl -k), для https с self-signed.
push_health_json() {
    local body="$1"
    local urls=() tokens=() url token i rc=0 http_code
    local auth_hdr="${PUSH_AUTH_HEADER:-Authorization: Bearer}"
    local curl_insecure=()
    [[ "${PUSH_INSECURE:-0}" == "1" ]] && curl_insecure=(-k)

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

        local attempt=0 ok=0 curl_errfile="/tmp/flat_push_err.$$"
        while [[ $attempt -le ${PUSH_RETRIES:-2} ]]; do
            attempt=$((attempt + 1))
            # Логируем реальную вызываемую команду (токен маскируем), а не
            # реконструкцию "по мотивам" — чтобы можно было взять и повторить
            # руками (curl -v ...) без гадания, какие флаги реально ушли.
            local curl_display="curl -sS -o <body> -w '%{http_code}'"
            [[ ${#curl_insecure[@]} -gt 0 ]] && curl_display+=" ${curl_insecure[*]}"
            curl_display+=" --connect-timeout ${PUSH_CONNECT_TIMEOUT:-5} --max-time ${PUSH_MAX_TIME:-30}"
            curl_display+=" -X POST '$url' -H 'Content-Type: application/json'"
            curl_display+=" -H 'X-Flat-Host-Id: ${HOST_ID}' -H 'X-Flat-Service-Name: ${SERVICE_NAME}'"
            [[ -n "$token" ]] && curl_display+=" -H '${auth_hdr} ***'"
            curl_display+=" --data-binary <json>"
            log_debug "push: attempt $attempt → run: $curl_display"
            http_code=$(curl -sS -o /tmp/flat_push_body.$$ -w '%{http_code}' \
                "${curl_insecure[@]}" \
                --connect-timeout "${PUSH_CONNECT_TIMEOUT:-5}" \
                --max-time "${PUSH_MAX_TIME:-30}" \
                -X POST "$url" \
                -H "Content-Type: application/json" \
                -H "X-Flat-Host-Id: ${HOST_ID}" \
                -H "X-Flat-Service-Name: ${SERVICE_NAME}" \
                ${token:+-H "$auth_hdr $token"} \
                --data-binary "$body" 2>"$curl_errfile") || true
            [[ "$http_code" =~ ^[0-9]{3}$ ]] || http_code="000"
            # http=000 сам по себе не говорит, ПОЧЕМУ (DNS/refused/timeout/TLS) —
            # curl обычно пишет это в stderr, раньше просто выбрасывался в /dev/null.
            [[ -s "$curl_errfile" ]] && log_debug "push: attempt $attempt → curl said: $(tr '\n' ' ' < "$curl_errfile" 2>/dev/null)"
            rm -f "$curl_errfile" 2>/dev/null
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
        [[ "$OUTPUT_JSON" -eq 1 ]] && _json_print "$body"
        push_health_json "$body"
        return $?
    fi
    _json_print "$body"
}
