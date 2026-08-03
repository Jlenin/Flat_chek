#!/bin/bash
# Живые примеры CLI агента (после установки или из корня репо).

set -euo pipefail
FLAT_CHECK="${FLAT_CHECK:-./flat_check.sh}"
CONF="${CONF:-/etc/flat/flat_check.conf}"

echo "=== 1) Обычный human-readable health ==="
"$FLAT_CHECK"

echo "=== 2) Один пакет, текст ==="
"$FLAT_CHECK" --pkg fss-server || true

echo "=== 3) Один пакет, JSON ==="
"$FLAT_CHECK" --pkg fss-server --json | head -c 400; echo

echo "=== 4) Полный JSON-снимок ноды ==="
"$FLAT_CHECK" --json | head -c 400; echo

echo "=== 5) Push по конфигу ==="
if [[ -f "$CONF" ]]; then
  "$FLAT_CHECK" --config "$CONF" --json --push
else
  echo "(нет $CONF — пропуск)"
fi

echo "=== 6) Push через env (без файла) ==="
PUSH_URLS="https://partner.example.local/api/v1/health/ingest" \
PUSH_TOKEN="secret" \
HOST_ID="ss-n1" \
SERVICE_NAME="fss-backend" \
  "$FLAT_CHECK" --json --push || true

echo "=== 7) Несколько ingest URL ==="
PUSH_URLS="https://partner-a.example/ingest,https://partner-b.example/ingest" \
PUSH_TOKEN="secret" \
  "$FLAT_CHECK" --push || true

echo "=== 8) Идентичность хоста явно ==="
"$FLAT_CHECK" --json \
  --host-id ss-n1 \
  --host-ip 10.0.1.5 \
  --service-name fss-backend | head -c 300; echo
