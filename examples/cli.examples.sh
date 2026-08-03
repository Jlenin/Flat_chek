#!/bin/bash
# Примеры будущих вызовов flat_check (после реализации --json/--push/--pkg).
# Сейчас скрипт этих флагов ещё не понимает — файл для согласования CLI.

set -euo pipefail
FLAT_CHECK="${FLAT_CHECK:-/usr/local/bin/flat_check}"

echo "=== 1) Обычный human-readable health (как сейчас) ==="
"$FLAT_CHECK"

echo "=== 2) Один пакет, текст ==="
"$FLAT_CHECK" --pkg fss-server

echo "=== 3) Один пакет, JSON в stdout ==="
"$FLAT_CHECK" --pkg fss-server --json

echo "=== 4) Все локально установленные пакеты → JSON ==="
"$FLAT_CHECK" --json | jq '.summary, .products[].name'

echo "=== 5) Push на Partner (читает /etc/flat/flat_check.conf) ==="
"$FLAT_CHECK" --config /etc/flat/flat_check.conf --json --push

echo "=== 6) Push без файла конфига (env) ==="
PUSH_URL="https://partner.example.local/api/v1/health/ingest" \
PUSH_TOKEN="secret" \
HOST_ID="ss-n1" \
  "$FLAT_CHECK" --json --push

echo "=== 7) Bastion: remote-map по SSH (опционально) ==="
# На удалённой ноде уже должен быть установлен flat_check той же версии.
"$FLAT_CHECK" --remote-map /etc/flat/flat_check.hosts --json | jq .

echo "=== 8) Ручной remote одной команды (без карты) ==="
ssh -o BatchMode=yes -o ConnectTimeout=5 root@10.0.1.5 \
  '/usr/local/bin/flat_check --pkg fss-server --json'
