# Модуль: 02_output.sh
# Слой: core
# Назначение: Печать статусов (ok/warn/fail/info), запись сессионного лога (_log_line/log_debug/init_logging), die().
# Публичные функции: print_ok/warn/fail/info/not_installed(), ok/warn/fail/info(), _log_line(), log_debug(), init_logging(), die()
# Зависит от: 00_globals.sh (ERRORS/WARNINGS/LOG_FILE/DEBUG_MODE/цвета)
# Не зависит от: от каталога, ОС-детекта, проверок — используется ими, а не наоборот
# Side effects: пишет в LOG_FILE (session-лог), печатает в stdout/stderr
#
# Источник: перенесено без изменений логики из flat_check.sh (строки 283-372).
# Единственная сознательная правка: баннер в init_logging() печатал
# "${SCRIPT_NAME}.sh v..." — там ".sh" дописывался руками, т.к. SCRIPT_NAME
# всегда был "flat_check"/"flat_check_2" без расширения. Точка входа новой
# сборки называется просто `flat_check` (без .sh), поэтому дописывание ".sh"
# убрано — иначе баннер лгал бы ("flat_check.sh" при реальном имени файла
# "flat_check"). Сам факт и текст остальных сообщений не менялся.
#
# Вторая правка (фаза 3, при добавлении lib/logging): die() здесь портирован
# из flat_check.sh как `die() { fail "$1"; exit 1; }` — health-only скрипт не
# знает о рабочих каталогах сборщика логов. flat_check_2.sh (строка 512)
# определяет die() как `fail "$1"; cleanup 2>/dev/null; exit 1;`, чтобы
# фатальная ошибка в режиме -log не оставляла недоделанный рабочий каталог.
# В unified-инструменте die() общий на все режимы, поэтому взята версия
# flat_check_2.sh: `cleanup` определена только в lib/logging/07_collector.sh,
# но 2>/dev/null безопасно проглатывает "command not found", если lib/logging
# не подключён (health-only запуск) — ровно так же безопасно, как и в
# оригинале, где cleanup() тоже мог быть вызван до того, как до неё дошли
# другие ветки кода.

# --- 2. Хелперы вывода + логирование в файл --------------------------------------
# (print_ok / print_warn / print_fail / print_info — используются при проверке состояния)

# Пишет строку сессионного лога (без ANSI-кодов, с таймстампом и уровнем).
# Тихо ничего не делает, если LOG_FILE не задан/недоступен для записи —
# логирование в файл никогда не должно ронять сам скрипт или его вывод.
_log_line() {
    [[ -n "${LOG_FILE:-}" ]] || return 0
    # Группа скобок обязательна: если каталог LOG_FILE уже исчез (сборщик
    # только что заархивировал и удалил WORK_DIR), сам bash печатает "No such
    # file or directory" в свой stderr при настройке редиректа >> — до того,
    # как успевает сработать 2>/dev/null самой команды printf.
    { printf '%s [%-5s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" "$2" >> "$LOG_FILE"; } 2>/dev/null
}

# Технические подробности обычно только в файл лога (снимки CPU/MEM и т.п.) —
# не выводятся на экран, чтобы не перегружать вывод. С --debug — дублируются
# и на экран (stderr), чтобы разбирать проблему прямо в терминале.
log_debug() {
    _log_line "DEBUG" "$1"
    [[ "${DEBUG_MODE:-0}" -eq 1 ]] && echo -e "${C_C}[DEBUG]${C_N} $1" >&2
}

# Инициализирует LOG_FILE в $dir/${SCRIPT_NAME}.log (перезаписывается на
# каждом запуске — без ротации, чтобы файл не разрастался при частых
# вызовах из cron/Zabbix). При отсутствии прав на запись — тихо отключает
# логирование в файл (на экран это не влияет).
init_logging() {
    local dir="${1:-$SCRIPT_DIR}"
    LOG_FILE="${dir%/}/${SCRIPT_NAME}.log"
    if ! { : > "$LOG_FILE"; } 2>/dev/null; then
        LOG_FILE=""
        return 1
    fi
    _log_line "INFO" "=== ${SCRIPT_NAME} v${SCRIPT_VERSION} — сессия начата ==="
    # Версия на экран в human-режиме (при --json/--push только в session-log)
    if [[ "${OUTPUT_JSON:-0}" -ne 1 && "${DO_PUSH:-0}" -ne 1 ]]; then
        info "${SCRIPT_NAME} v${SCRIPT_VERSION}"
    fi
    if [[ "${PKG_CATALOG_SOURCE:-internal}" == "external" ]]; then
        _log_line "INFO" "package catalog: external (${PKG_CATALOG_PATH})"
        if [[ "${OUTPUT_JSON:-0}" -ne 1 && "${DO_PUSH:-0}" -ne 1 ]]; then
            info "package catalog: external (${PKG_CATALOG_PATH})"
        fi
    else
        _log_line "INFO" "package catalog: internal (builtin)"
        if [[ "${OUTPUT_JSON:-0}" -ne 1 && "${DO_PUSH:-0}" -ne 1 ]]; then
            info "package catalog: internal (builtin)"
        fi
    fi
    return 0
}


print_ok() {
    echo -e "${C_G}[OK]${C_N}    $1"
    _log_line "OK" "$1"
}

print_warn() {
    echo -e "${C_Y}[WARN]${C_N}  $1"
    _log_line "WARN" "$1"
    ((WARNINGS++))
}

print_fail() {
    echo -e "${C_R}[FAIL]${C_N}  $1"
    _log_line "FAIL" "$1"
    ((ERRORS++))
}

print_info() {
    echo -e "${C_B}[INFO]${C_N}  $1"
    _log_line "INFO" "$1"
}

print_not_installed() {
    echo -e "${C_B}[INFO]${C_N}  $1 — not installed"
    _log_line "INFO" "$1 — not installed"
}

# Короткие псевдонимы (selftest / внутренние хелперы)
ok()  { echo -e "${C_G}[OK]${C_N}  $1"; _log_line "OK" "$1"; }
warn() { echo -e "${C_Y}[WARN]${C_N} $1"; _log_line "WARN" "$1"; }
fail() { echo -e "${C_R}[FAIL]${C_N} $1"; _log_line "FAIL" "$1"; }
info() { echo -e "${C_B}[INFO]${C_N} $1"; _log_line "INFO" "$1"; }

die() { fail "$1"; cleanup 2>/dev/null; exit 1; }


