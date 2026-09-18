#!/usr/bin/env bash
# flat-check-set-push-urls.sh — генерирует PUSH_URLS и SERVICE_NAME в
# flat_check_agent.conf из реально установленных на хосте *-backend
# пакетов и их портов.
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
# Ничего не делает и не падает, если карты/jq нет.
#
# Первая установка (конфига ещё нет вообще) — копируем шаблон из
# flat_check_agent.conf.example и сразу прописываем в него PUSH_URLS/
# SERVICE_NAME по найденным *-backend пакетам.
#
# Переустановка/upgrade/повторная установка после удаления — конфиг уже
# ЕСТЬ, и в нём мог быть добавлен собственный контент инженера (сторонние
# PUSH_URLS, доп. значения и т.п.), который безусловный sed-патч тихо бы
# затёр. Поэтому в этом случае молча НИЧЕГО не патчим — спрашиваем:
#   - есть терминал (интерактивный dpkg/rpm -i) — задаём вопрос
#     "перезаписать конфиг шаблоном?"; да → конфиг пересоздаётся из example
#     и получает свежие PUSH_URLS/SERVICE_NAME, как при первой установке;
#     нет/Enter → конфиг остаётся полностью как был, ничего не трогаем;
#   - нет терминала (headless upgrade, unattended-upgrades, автоматизация) —
#     спросить нельзя, поэтому применяется безопасный умолчательный ответ
#     "нет": конфиг остаётся как был, ничего не трогаем.
#
# Это единственное место в цепочке постинста, которое исполняется обычным
# bash, а не eval-однострочником — поэтому именно здесь, а не во внешнем
# POSTINST_INSTALL, и должна жить эта логика. Если во внешнем
# POSTINST_INSTALL пакета flat-check ЕСТЬ отдельная строка, безусловно
# копирующая .example поверх рабочего конфига ДО вызова этого скрипта —
# её нужно убрать или сделать условной, иначе она отменит эту защиту,
# отработав раньше.

set -uo pipefail

dest_path="${1:?usage: $0 DESTINATION_PATH CONFIG_FILE}"
config_file="${2:?usage: $0 DESTINATION_PATH CONFIG_FILE}"
conf_path="$dest_path/$config_file"
example_path="$dest_path/flat_check_agent.conf.example"
port_map="$dest_path/all_local_port.json"

apply_template=0

if [[ ! -f "$conf_path" ]]; then
    apply_template=1
else
    if [[ -t 0 ]]; then
        read -r -p "Конфиг $conf_path уже существует. Перезаписать шаблоном и переопределить PUSH_URLS/SERVICE_NAME? [y/N] " ans
        case "$ans" in
            [Yy]*) apply_template=1 ;;
            *) apply_template=0 ;;
        esac
    else
        apply_template=0
        echo "[INFO] $conf_path уже существует, неинтерактивный запуск — конфиг оставлен как есть" >&2
    fi
fi

if [[ $apply_template -eq 0 ]]; then
    rm -f "$port_map"
    exit 0
fi

if [[ -f "$example_path" ]]; then
    cp "$example_path" "$conf_path"
fi

[[ -f "$port_map" ]] || exit 0
command -v jq >/dev/null 2>&1 || exit 0

urls=""
names=""
while IFS=$'\t' read -r name ports; do
    [[ "$name" == *-backend ]] || continue
    if command -v dpkg >/dev/null 2>&1 && dpkg -s "$name" >/dev/null 2>&1; then
        :
    elif command -v rpm >/dev/null 2>&1 && rpm -q "$name" >/dev/null 2>&1; then
        :
    else
        continue
    fi
    names="${names:+$names,}$name"
    for port in $ports; do
        urls="${urls:+$urls,}http://127.0.0.1:${port}/api/v1/health/ingest"
    done
done < <(jq -r '.[0] | to_entries[] | "\(.key)\t\(.value)"' "$port_map")

if [[ -n "$urls" ]]; then
    sed -i "s#^PUSH_URLS=.*#PUSH_URLS=\"${urls}\"#" "$conf_path"
fi

if [[ -n "$names" ]]; then
    sed -i "s#^SERVICE_NAME=.*#SERVICE_NAME=\"${names}\"#" "$conf_path"
fi

rm -f "$port_map"
