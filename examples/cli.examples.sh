#!/bin/bash
# Примеры будущих вызовов flat_check (после --json/--push/--pkg).
# Сейчас flat_check.sh этих флагов ещё не понимает.

set -euo pipefail
FLAT_CHECK="${FLAT_CHECK:-/usr/local/bin/flat_check}"

echo "=== 1) Human-readable (как сейчас) ==="
"$FLAT_CHECK"

echo "=== 2) Один пакет → JSON v2 (stdout) ==="
"$FLAT_CHECK" --pkg fss-server --json | jq '{host_id, host_ip, service_name, summary}'

echo "=== 3) Полный локальный снимок → JSON v2 ==="
"$FLAT_CHECK" --config /etc/flat/flat_check.conf --json | jq 'keys'

echo "=== 4) Push на ВСЕ URL из PUSH_URLS (http и https) ==="
"$FLAT_CHECK" --config /etc/flat/flat_check.conf --json --push

echo "=== 5) Push через env (несколько URL) ==="
HOST_ID="ss-n1" \
HOST_IP="10.0.1.5" \
SERVICE_NAME="fss-backend" \
PUSH_URLS="https://partner.example.local/api/v1/health/ingest,http://fps.example.local:8054/api/v1/health/ingest" \
PUSH_TOKEN="CHANGE_ME_FLAT_CHECK_TOKEN" \
  "$FLAT_CHECK" --json --push

echo "=== 6) Только сформировать JSON в файл (без push) ==="
"$FLAT_CHECK" --config /etc/flat/flat_check.conf --json > /var/tmp/flat_check.json
jq '.host_id, .host_ip, .service_name, .summary' /var/tmp/flat_check.json
