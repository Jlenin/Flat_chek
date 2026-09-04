#!/usr/bin/env bash
# flat-check-set-push-urls.sh — генерирует PUSH_URLS в flat_check_agent.conf
# из реально установленных на хосте *-backend пакетов и их портов.
#
# Вызывается из POSTINST_INSTALL пакета flat-check ОДНОЙ строкой:
#   bash $DESTINATION_PATH/flat-check-set-push-urls.sh "$DESTINATION_PATH" "$CONFIG_FILE"
#
# Так и не иначе: постинст этого пакета исполняет каждую строку
# POSTINST_INSTALL как отдельную самостоятельную команду (через cmd_color,
# eval в подшелле) — многострочные if/while/for там не работают, каждая
# строка теряет состояние предыдущей. Поэтому вся логика — здесь, в
# обычном файле, вызываемом одним вызовом bash.
#
# $1 — DESTINATION_PATH (каталог агента, там же лежит all_local_port.json)
# $2 — CONFIG_FILE (имя конфига агента, напр. flat_check_agent.conf)
#
# Карта портов (all_local_port.json) — JSON вида [ { "pkg-name": "port ...", ... } ],
# копируется в тот же каталог до вызова этого скрипта (before_script сборки).
# Ничего не делает и не падает, если карты/jq нет — конфиг остаётся как был.
# Если на хосте не установлено ни одного *-backend — PUSH_URLS всё равно
# перезаписывается, но пустой строкой (не остаётся дефолт из example-конфига):
# flat_check_agent.sh при пустом PUSH_URLS просто печатает JSON и не пытается
# пушить — это штатный режим "нечего пушить", а не ошибка.

set -uo pipefail

dest_path="${1:?usage: $0 DESTINATION_PATH CONFIG_FILE}"
config_file="${2:?usage: $0 DESTINATION_PATH CONFIG_FILE}"
port_map="$dest_path/all_local_port.json"

[[ -f "$port_map" ]] || exit 0
command -v jq >/dev/null 2>&1 || exit 0

urls=""
while IFS=$'\t' read -r name ports; do
    [[ "$name" == *-backend ]] || continue
    if command -v dpkg >/dev/null 2>&1 && dpkg -s "$name" >/dev/null 2>&1; then
        :
    elif command -v rpm >/dev/null 2>&1 && rpm -q "$name" >/dev/null 2>&1; then
        :
    else
        continue
    fi
    for port in $ports; do
        urls="${urls:+$urls,}http://127.0.0.1:${port}/api/v1/health/ingest"
    done
done < <(jq -r '.[0] | to_entries[] | "\(.key)\t\(.value)"' "$port_map")

sed -i "s#^PUSH_URLS=.*#PUSH_URLS=\"${urls}\"#" "$dest_path/$config_file"

rm -f "$port_map"
