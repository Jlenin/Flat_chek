#!/bin/bash
# Опциональный режим координатора (bastion): проверка пакета на remote по SSH.
# Предпочтительно: на remote уже стоит /usr/local/bin/flat_check.
# Fallback: передать скрипт через bash -s (тяжелее, только для bootstrap).

set -euo pipefail

REMOTE_FLAT_CHECK="${REMOTE_FLAT_CHECK:-/usr/local/bin/flat_check}"

# ssh user@host → JSON одного пакета
run_remote_check() {
    local host="$1"   # root@10.0.1.5
    local pkg="$2"    # fss-server

    ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new \
        "$host" \
        "$REMOTE_FLAT_CHECK --pkg $(printf '%q' "$pkg") --json" 2>/dev/null
}

# Fallback, если бинаря на remote ещё нет (bootstrap)
run_remote_check_bootstrap() {
    local host="$1"
    local pkg="$2"
    local local_script="${3:-./flat_check.sh}"

    # Передаём скрипт на stdin; аргументы после -- уходят в bash -s
    ssh -o BatchMode=yes -o ConnectTimeout=5 \
        "$host" "bash -s -- --pkg $(printf '%q' "$pkg") --json" \
        < "$local_script" 2>/dev/null
}

# Пример обхода карты hosts
#   while read -r pkg host; do
#     [[ "$pkg" =~ ^#|^$ ]] && continue
#     echo "=== $pkg @ $host ==="
#     run_remote_check "$host" "$pkg" | jq -c '.summary, .products[0].packages[0].name'
#   done < /etc/flat/flat_check.hosts

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    host="${1:-}"
    pkg="${2:-}"
    [[ -n "$host" && -n "$pkg" ]] || {
        echo "Usage: $0 user@host package" >&2
        exit 2
    }
    run_remote_check "$host" "$pkg"
fi
