#!/bin/bash
# Примеры ручного запуска агента (из корня репо или после установки).

set -euo pipefail
FLAT_CHECK="${FLAT_CHECK:-./flat_check.sh}"
CONF="${CONF:-/etc/flat/flat_check.conf}"

echo "=== human health ==="
"$FLAT_CHECK" || true

echo "=== one package, JSON ==="
"$FLAT_CHECK" --pkg fss-server --json 2>/dev/null | head -c 300 || true
echo

echo "=== full JSON ==="
"$FLAT_CHECK" --json --host-id demo --service-name fss-backend 2>/dev/null | head -c 300 || true
echo

if [[ -f "$CONF" ]]; then
  echo "=== push from conf ==="
  "$FLAT_CHECK" --config "$CONF" --push || true
else
  echo "=== conf $CONF отсутствует — push через env (ожидаемо может FAIL без реального ingest) ==="
  PUSH_URLS="${PUSH_URLS:-https://partner.example.local/api/v1/health/ingest}" \
  PUSH_TOKEN="${PUSH_TOKEN:-secret}" \
  HOST_ID="${HOST_ID:-demo}" \
  SERVICE_NAME="${SERVICE_NAME:-fss-backend}" \
    "$FLAT_CHECK" --push || true
fi
