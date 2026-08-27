# Модуль: 07_pkg_checks.sh
# Слой: core
# Назначение: Низкоуровневые примитивы по пакетному менеджеру (зависимости, версия, наличие) и проверки состояния конкретного продукта/пакета (служба, порт, API, логи, конфиги).
# Публичные функции: get_pkg_depends(), get_dep_version(), is_dep_installed(), register_dep(), is_pkg_installed_tiny(), check_process(), check_ports(), check_api_health(), check_single_pkg(), run_product_checks(), is_lib_available()
# Зависит от: 00_globals.sh, 01_catalog.sh, 02_output.sh, 04_os_detect.sh, 05_system_metrics.sh (_sys_pkg_pids)
# Не зависит от: от инфраструктуры/repo-проверок и от agent/logging — это их общая база, а не наоборот
# Side effects: запускает dpkg/rpm/pacman/apk/systemctl/ss/curl; печатает разделы по продуктам; заполняет ALL_DEPENDS
#
# Источник: перенесено без изменений логики из flat_check.sh (строки 1006-1880).

# --- Список сырых зависимостей по PM -----------------------------------------
# По одной самодостаточной функции на каждый пакетный менеджер: печатает сырую,
# нефильтрованную строку зависимостей для установленного пакета, используя только
# инструмент(ы) этого PM; печатает ничего, если пакет не установлен.
# get_pkg_depends() ниже диспетчеризует по $PM, затем выполняет общую для обоих
# PM-агностичную очистку (убрать версионные ограничения/альтернативы, дедуп).

# Debian-семья: строка Depends: из dpkg -s, запасной вариант — apt-cache depends.
get_pkg_depends_dpkg() {
    local pkg="$1" deps=""

    dpkg-query -W -f='${Status}\n' "$pkg" 2>/dev/null | grep -q 'install ok installed' || return
    deps=$(dpkg -s "$pkg" 2>/dev/null | grep "^Depends:" | sed 's/^Depends: //')
    if [[ -z "$deps" ]]; then
        deps=$(apt-cache depends "$pkg" 2>/dev/null | grep -E "^\s+Depends:" | sed 's/.*Depends: //' | tr '\n' ', ' | sed 's/, $//')
    fi
    echo "$deps"
}

# RHEL-семья: сырой список requires из rpm -qR, отфильтрованный до реальных имён пакетов.
get_pkg_depends_rpm() {
    local pkg="$1" deps=""

    rpm -q "$pkg" &>/dev/null || return
    deps=$(rpm -qR "$pkg" 2>/dev/null | grep -v "^rpmlib(" | grep -v "^/" | grep -v "^config" | grep -v "^config(" | grep -vi "^package" | grep -vi "^пакет" | sed 's/ .*$//' | sort -u | tr '\n' ', ' | sed 's/, $//')
    echo "$deps"
}

# Получить реальные зависимости пакета из PM (только dpkg/rpm — у пакетов FLAT
# для pacman/apk реальные зависимости здесь и раньше не декларировались, до этого разделения тоже)
get_pkg_depends() {
    local pkg="$1"
    local deps=""

    case "$PM" in
        dpkg) deps=$(get_pkg_depends_dpkg "$pkg") ;;
        rpm)  deps=$(get_pkg_depends_rpm "$pkg") ;;
    esac

    # Очистка: убрать версионные ограничения, альтернативы, оставить только имена пакетов
    echo "$deps" | tr ',' '\n' | sed 's/|.*$//' | sed 's/([^)]*)//g' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | grep -v '^$' | grep -v '^[0-9]' | grep -v '^(' | grep -v '^)' | grep -v '^<' | grep -v '^>' | grep -v '^=' | sort -u | tr '\n' ',' | sed 's/^,//;s/,$//'
}

# --- Запрос версии по PM -------------------------------------------------------
# По одной самодостаточной функции на каждый пакетный менеджер: печатает установленную
# строку версии для имени (пакет или зависимость — поиск один и тот же
# в обоих случаях), либо ничего, если не найдено/не применимо.
# get_pkg_version()/get_dep_version() — это два имени для одной и той же диспетчеризации;
# раньше это были две копии друг друга, по одной на каждого вызывающего.

# Debian-семья: dpkg-query печатает поле Version напрямую.
_pkg_version_dpkg() {
    dpkg-query -W -f='${Version}' "$1" 2>/dev/null
}

# RHEL-семья: у rpm нет однопольного запроса версии, поэтому объединяем VERSION+RELEASE.
_pkg_version_rpm() {
    rpm -q --queryformat '%{VERSION}-%{RELEASE}' "$1" 2>/dev/null
}

# Arch: pacman -Q печатает "имя версия" в одной строке; версия — второе поле.
_pkg_version_pacman() {
    pacman -Q "$1" 2>/dev/null | awk '{print $2}'
}

_pkg_version() {
    local name="$1" ver=""

    case "$PM" in
        dpkg)   ver=$(_pkg_version_dpkg "$name") ;;
        rpm)    ver=$(_pkg_version_rpm "$name") ;;
        pacman) ver=$(_pkg_version_pacman "$name") ;;
    esac

    echo "$ver"
}

# Получить версию пакета из PM
get_pkg_version() { _pkg_version "$1"; }

# Получить версию зависимости из PM (тот же поиск, что и у get_pkg_version)
get_dep_version() { _pkg_version "$1"; }

# --- Проверка наличия зависимости по PM --------------------------------------
# Debian-семья: достаточно одного поля Status из dpkg-query.
_dep_installed_dpkg() {
    dpkg-query -W -f='${Status}\n' "$1" 2>/dev/null | grep -q 'install ok installed'
}

# RHEL-семья: достаточно одного кода возврата rpm -q.
_dep_installed_rpm() {
    rpm -q "$1" &>/dev/null
}

# Arch: достаточно одного кода возврата pacman -Q.
_dep_installed_pacman() {
    pacman -Q "$1" &>/dev/null
}

# Проверить, установлена ли зависимость (только dpkg/rpm/pacman, как и раньше)
is_dep_installed() {
    local dep="$1"
    case "$PM" in
        dpkg)   _dep_installed_dpkg "$dep" ;;
        rpm)    _dep_installed_rpm "$dep" ;;
        pacman) _dep_installed_pacman "$dep" ;;
        *)      return 1 ;;
    esac
}

# Проверить статус службы для зависимости (возвращает строку-описание)
check_dep_service() {
    local dep="$1"
    local svc=""
    local result=""

    # Соответствие распространённых имён пакетов именам служб
    case "$dep" in
        nginx) svc="nginx" ;;
        redis|redis-server) svc="redis-server" ;;
        mariadb|mysql-server|mariadb-server) svc="mariadb" ;;
        postgresql|postgresql-*) svc="postgresql" ;;
        rabbitmq-server|rabbitmq) svc="rabbitmq-server" ;;
        sudo) return 0 ;;  # у sudo нет службы
        *) return 0 ;;
    esac

    if command -v systemctl &>/dev/null; then
        local active
        active=$(systemctl is-active "${svc}.service" 2>/dev/null || echo "unknown")
        if [[ "$active" == "active" ]]; then
            result="service active"
        else
            result="service $active"
        fi
    fi
    echo "$result"
}

# Собрать зависимость в глобальный массив ALL_DEPENDS (dep -> "pkg1,pkg2")
register_dep() {
    local dep="$1"
    local pkg="$2"
    dep=$(echo "$dep" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    [[ -z "$dep" ]] && return

    # Пропускаем непакетные зависимости (файлы, пути, версионные строки, сам пакет, config, RPM capabilities)
    [[ "$dep" == /* ]] && return
    [[ "$dep" == *"("* ]] && return
    [[ "$dep" == *"|"* ]] && return
    [[ "$dep" == *" "* ]] && return
    [[ "$dep" == "config" ]] && return
    [[ "$dep" == "$pkg" ]] && return
    [[ "$dep" == "rtld" ]] && return
    [[ "$dep" == "пакет" ]] && return
    [[ "$dep" == "Пакет" ]] && return
    [[ "$dep" == "package" ]] && return
    [[ "$dep" == "Package" ]] && return

    log_debug "register_dep: dep='$dep' pkg='$pkg'"
    local existing="${ALL_DEPENDS[$dep]:-}"
    if [[ -n "$existing" ]]; then
        if [[ ",${existing}," != *",$pkg,"* ]]; then
            ALL_DEPENDS[$dep]="${existing},$pkg"
        fi
    else
        ALL_DEPENDS[$dep]="$pkg"
    fi
}

# --- Пробы наличия пакета по PM -----------------------------------------------
# По одной самодостаточной функции на каждый пакетный менеджер: основное имя, затем
# каждое legacy-имя через запятую, используя только инструмент запроса этого PM — никаких
# команд других PM внутри. Каждая устанавливает FOUND_PKG_VER/FOUND_PKG_STATUS,
# печатает соответствующую строку ok/warn/fail и возвращает:
#   0 = установлен  1 = установлен, но не полностью настроен (только dpkg)
#   2 = вместо него найдено legacy-имя  3 = не найден совсем
# check_pkg_installed() ниже вызывает их только через диспетчеризацию по $PM.

# Debian-семья: dpkg-query даёт версию + полный статус установки за один вызов.
check_pkg_installed_dpkg() {
    local pkg="$1" legacy="$2" old found ver status

    found=$(dpkg-query -W -f='${Package}\t${Version}\t${Status}\n' "$pkg" 2>/dev/null)
    if [[ -n "$found" ]]; then
        ver=$(echo "$found" | awk '{print $2}')
        status=$(echo "$found" | awk '{$1=""; $2=""; print $0}' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        FOUND_PKG_VER="$ver"
        FOUND_PKG_STATUS="$status"
        if [[ "$status" == "install ok installed" ]]; then
            print_ok "pkg: $pkg installed"
            return 0
        else
            print_warn "pkg: $pkg installed but status='$status'"
            return 1
        fi
    fi

    for old in $(echo "$legacy" | tr ',' ' '); do
        found=$(dpkg-query -W -f='${Package}\t${Version}\t${Status}\n' "$old" 2>/dev/null)
        [[ -n "$found" ]] || continue
        ver=$(echo "$found" | awk '{print $2}')
        status=$(echo "$found" | awk '{$1=""; $2=""; print $0}' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        FOUND_PKG_VER="$ver"
        FOUND_PKG_STATUS="$status"
        print_warn "pkg: $pkg not found, but legacy '$old' exists ($ver)"
        return 2
    done

    print_fail "pkg: $pkg not installed"
    return 3
}

# RHEL-семья: rpm -q только подтверждает наличие, версия — из второго запроса.
check_pkg_installed_rpm() {
    local pkg="$1" legacy="$2" old ver

    if rpm -q "$pkg" &>/dev/null; then
        ver=$(rpm -q --queryformat '%{VERSION}-%{RELEASE}' "$pkg" 2>/dev/null)
        FOUND_PKG_VER="$ver"
        print_ok "pkg: $pkg installed"
        return 0
    fi

    for old in $(echo "$legacy" | tr ',' ' '); do
        rpm -q "$old" &>/dev/null || continue
        ver=$(rpm -q --queryformat '%{VERSION}-%{RELEASE}' "$old" 2>/dev/null)
        FOUND_PKG_VER="$ver"
        print_warn "pkg: $pkg not found, but legacy '$old' exists ($ver)"
        return 2
    done

    print_fail "pkg: $pkg not installed"
    return 3
}

# Arch: pacman -Q печатает "имя версия" в одной строке для установленного пакета.
check_pkg_installed_pacman() {
    local pkg="$1" legacy="$2" old ver

    if pacman -Q "$pkg" &>/dev/null; then
        ver=$(pacman -Q "$pkg" 2>/dev/null | awk '{print $2}')
        FOUND_PKG_VER="$ver"
        print_ok "pkg: $pkg installed"
        return 0
    fi

    for old in $(echo "$legacy" | tr ',' ' '); do
        pacman -Q "$old" &>/dev/null || continue
        ver=$(pacman -Q "$old" 2>/dev/null | awk '{print $2}')
        FOUND_PKG_VER="$ver"
        print_warn "pkg: $pkg not found, but legacy '$old' exists ($ver)"
        return 2
    done

    print_fail "pkg: $pkg not installed"
    return 3
}

# Alpine: apk info -e только подтверждает наличие, отдельный запрос версии здесь не используется.
check_pkg_installed_apk() {
    local pkg="$1" legacy="$2" old

    if apk info -e "$pkg" &>/dev/null; then
        print_ok "pkg: $pkg installed"
        return 0
    fi

    for old in $(echo "$legacy" | tr ',' ' '); do
        apk info -e "$old" &>/dev/null || continue
        print_warn "pkg: $pkg not found, but legacy '$old' exists"
        return 2
    done

    print_fail "pkg: $pkg not installed"
    return 3
}

# Проверить, установлен ли пакет через PM (подробно, печатает статус)
check_pkg_installed() {
    local pkg="$1"
    local legacy="$2"

    FOUND_PKG_VER=""
    FOUND_PKG_STATUS=""

    case "$PM" in
        dpkg)   check_pkg_installed_dpkg "$pkg" "$legacy" ;;
        rpm)    check_pkg_installed_rpm "$pkg" "$legacy" ;;
        pacman) check_pkg_installed_pacman "$pkg" "$legacy" ;;
        apk)    check_pkg_installed_apk "$pkg" "$legacy" ;;
        *)      print_fail "pkg: $pkg not installed"; return 3 ;;
    esac
}

has_any_trace() {
    local pkg="$1"
    local unit="${pkg}.service"
    [[ -f "/usr/lib/systemd/system/${unit}" ]] || [[ -f "/etc/systemd/system/${unit}" ]] || [[ -f "/lib/systemd/system/${unit}" ]] || [[ -d "/opt/flat/${pkg}" ]]
}

# --- Тихие проверки наличия по PM --------------------------------------------
# По одной самодостаточной функции на каждый пакетный менеджер для тихого (без вывода)
# быстрого пути: основное имя, затем каждое legacy-имя через запятую, используя только
# инструмент запроса этого PM. Возвращает 0, если найдено, иначе 1.
# is_pkg_installed_tiny() ниже пробует подходящую через $PM, затем всегда
# откатывается на has_any_trace() независимо от PM/результата.

# Debian-семья: достаточно одного поля Status из dpkg-query, версия не нужна.
is_pkg_installed_tiny_dpkg() {
    local pkg="$1" legacy="$2" old

    dpkg-query -W -f='${Status}\n' "$pkg" 2>/dev/null | grep -q 'install ok installed' && return 0
    for old in $(echo "$legacy" | tr ',' ' '); do
        dpkg-query -W -f='${Status}\n' "$old" 2>/dev/null | grep -q 'install ok installed' && return 0
    done
    return 1
}

# RHEL-семья: для проверки наличия достаточно одного кода возврата rpm -q.
is_pkg_installed_tiny_rpm() {
    local pkg="$1" legacy="$2" old

    rpm -q "$pkg" &>/dev/null && return 0
    for old in $(echo "$legacy" | tr ',' ' '); do
        rpm -q "$old" &>/dev/null && return 0
    done
    return 1
}

# Arch: для проверки наличия достаточно одного кода возврата pacman -Q.
is_pkg_installed_tiny_pacman() {
    local pkg="$1" legacy="$2" old

    pacman -Q "$pkg" &>/dev/null && return 0
    for old in $(echo "$legacy" | tr ',' ' '); do
        pacman -Q "$old" &>/dev/null && return 0
    done
    return 1
}

# Alpine: достаточно одного кода возврата apk info -e; legacy-цикла здесь
# не было и в исходном монолите — у пакетов FLAT для apk-семьи их просто нет.
is_pkg_installed_tiny_apk() {
    local pkg="$1"
    apk info -e "$pkg" &>/dev/null && return 0
    return 1
}

# Тихая быстрая проверка установки пакета (возвращает 0/1, без вывода)
is_pkg_installed() {
    is_pkg_installed_tiny "$@"
}

is_pkg_installed_tiny() {
    local pkg="$1"
    local legacy="$2"

    case "$PM" in
        dpkg)   is_pkg_installed_tiny_dpkg "$pkg" "$legacy" && return 0 ;;
        rpm)    is_pkg_installed_tiny_rpm "$pkg" "$legacy" && return 0 ;;
        pacman) is_pkg_installed_tiny_pacman "$pkg" "$legacy" && return 0 ;;
        apk)    is_pkg_installed_tiny_apk "$pkg" && return 0 ;;
    esac

    # Проверить следы (unit-файл или директория /opt/flat)
    has_any_trace "$pkg" && return 0
    return 1
}

# Проверить systemd unit
check_systemd_unit() {
    local pkg="$1"
    local unit="${pkg}.service"
    local unit_file=""

    if [[ -f "/usr/lib/systemd/system/${unit}" ]]; then
        unit_file="/usr/lib/systemd/system/${unit}"
    elif [[ -f "/etc/systemd/system/${unit}" ]]; then
        unit_file="/etc/systemd/system/${unit}"
    elif [[ -f "/lib/systemd/system/${unit}" ]]; then
        unit_file="/lib/systemd/system/${unit}"
    fi

    if [[ -n "$unit_file" ]]; then
        print_ok "systemd unit: $unit_file exists"

        if command -v systemctl &>/dev/null; then
            local active
            active=$(systemctl is-active "$unit" 2>/dev/null)
            if [[ "$active" == "active" ]]; then
                print_ok "systemd: $unit is active"
            else
                print_warn "systemd: $unit is $active"
            fi

            local enabled
            enabled=$(systemctl is-enabled "$unit" 2>/dev/null)
            if [[ "$enabled" == "enabled" ]]; then
                print_ok "systemd: $unit is enabled"
            else
                print_warn "systemd: $unit is $enabled"
            fi
        fi
    else
        print_warn "systemd unit: $unit not found"
    fi
}

# Попытаться найти путь к логу из известных конфиг-файлов пакета
get_log_path_from_config() {
    local pkg="$1"
    local path=""
    local conf=""

    case "$pkg" in
        fss-server)
            for conf in "/opt/flat/fss-server/settings.ini" "/opt/flat/switchserver/settings.ini"; do
                [[ -f "$conf" ]] || continue
                path=$(grep -s '^LogPath=' "$conf" | head -1 | cut -d '=' -f 2-)
                [[ -n "$path" ]] && break
            done
            ;;
        fss-srclient)
            for conf in "/opt/flat/fss-srclient/settings.ini" "/etc/flat/srclient/settings.ini" "/opt/flat/srclient/settings.ini"; do
                [[ -f "$conf" ]] || continue
                path=$(grep -s '^logger_fileName' "$conf" | head -1 | sed -E 's/.*=\s*"([^"]*)".*/\1/')
                [[ -n "$path" ]] && break
            done
            ;;
        fss-mediasrv)
            for conf in "/opt/flat/fss-mediasrv/config.xml" "/etc/mediasrv/config.xml" "/opt/flat/mediasrv/config.xml"; do
                [[ -f "$conf" ]] || continue
                path=$(grep -s '<LogParams>' "$conf" | head -1 | sed -E 's/.*>([^<]*)<.*/\1/')
                [[ -n "$path" ]] && break
            done
            ;;
        flat-file)
            for conf in "/opt/flat/flat-file/config.yml" "/opt/flat/${pkg}/config.yml"; do
                [[ -f "$conf" ]] || continue
                path=$(grep -s '^\s*dir\s*:' "$conf" | head -1 | cut -d ':' -f 2- | xargs)
                [[ -n "$path" ]] && break
            done
            ;;
    esac

    echo "$path"
}

# Проверить директорию логов со свежестью и запасным вариантом из конфига
check_log_directory() {
    local pkg="$1"
    local log_dir="/var/log/flat/${pkg}"
    local found_log_dir=""
    local log_status=""

    # Проверить, является ли символьной ссылкой
    if [[ -L "$log_dir" ]]; then
        local target
        target=$(readlink -f "$log_dir" 2>/dev/null || readlink "$log_dir" 2>/dev/null)
        print_info "logdir: $log_dir is symlink -> $target"
        # Использовать целевой путь для дальнейших проверок
        log_dir="$target"
    fi

    # Проверить путь по умолчанию
    if [[ -d "$log_dir" ]]; then
        if find -L "$log_dir" -maxdepth 1 -type f -mmin -300 2>/dev/null | head -1 | grep -q .; then
            print_ok "logdir: $log_dir exists (fresh logs)"
            log_status="ok"
        elif [[ -n "$(find -L "$log_dir" -maxdepth 1 -type f 2>/dev/null | head -1)" ]]; then
            log_status="stale"
        else
            log_status="empty"
        fi
    else
        log_status="missing"
    fi

    if [[ "$log_status" == "ok" ]]; then
        local owner
        owner=$(stat -c '%U:%G' "$log_dir" 2>/dev/null || stat -f '%Su:%Sg' "$log_dir" 2>/dev/null)
        print_info "logdir: $log_dir owner=$owner"
        return 0
    fi

    # Проблема с путём по умолчанию — проверить, активен ли процесс.
    # _sys_pkg_pids() — не голый pgrep по имени пакета, иначе пакеты вроде
    # fss-capagent (сторонний бинарь heplify, без "fss-capagent" в argv)
    # всегда считались бы неактивными, хотя systemd видит unit активным.
    local is_active=0
    [[ -n "$(_sys_pkg_pids "$pkg" 2>/dev/null)" ]] && is_active=1

    if [[ "$log_status" == "stale" ]]; then
        if [[ $is_active -eq 0 ]]; then
            print_info "logdir: $log_dir has old logs but process is inactive"
            local owner
            owner=$(stat -c '%U:%G' "$log_dir" 2>/dev/null || stat -f '%Su:%Sg' "$log_dir" 2>/dev/null)
            print_info "logdir: $log_dir owner=$owner"
            return 0
        else
            print_warn "logdir: $log_dir is standard but logs are older than 5 hours, check actuality (process is active)"
        fi
    elif [[ "$log_status" == "empty" ]]; then
        if [[ $is_active -eq 0 ]]; then
            print_info "logdir: $log_dir is empty but process is inactive"
            return 0
        else
            print_warn "logdir: $log_dir is empty but process is active"
        fi
    elif [[ "$log_status" == "missing" ]]; then
        if [[ $is_active -eq 0 ]]; then
            print_info "logdir: $log_dir missing but process is inactive"
            return 0
        else
            print_warn "logdir: $log_dir missing but process is active"
        fi
    fi

    # Процесс активен и есть проблема — попытаться найти путь к логу из конфига
    # Нужно только для empty/missing; для stale путь по умолчанию существует, но устарел.
    # Для stale: запасной вариант только если известен конфиг для этого пакета (иначе пропуск).
    if [[ "$log_status" == "stale" ]]; then
        return 0
    fi

    found_log_dir=$(get_log_path_from_config "$pkg")
    if [[ -n "$found_log_dir" ]]; then
        found_log_dir=$(eval echo "$found_log_dir")
        if [[ -d "$found_log_dir" ]]; then
            if find -L "$found_log_dir" -maxdepth 1 -type f -mmin -300 2>/dev/null | head -1 | grep -q .; then
                print_ok "logdir: $found_log_dir exists (fresh logs from config)"
            elif [[ -n "$(find -L "$found_log_dir" -maxdepth 1 -type f 2>/dev/null | head -1)" ]]; then
                print_warn "logdir: $found_log_dir exists but logs are old (from config)"
            else
                print_warn "logdir: $found_log_dir exists but empty (from config)"
            fi
            local owner
            owner=$(stat -c '%U:%G' "$found_log_dir" 2>/dev/null || stat -f '%Su:%Sg' "$found_log_dir" 2>/dev/null)
            print_info "logdir: $found_log_dir owner=$owner"
        else
            print_warn "logdir: $found_log_dir from config does not exist"
        fi
    else
        print_warn "logdir: no log path found in config for $pkg"
    fi
}

# Проверить директорию opt и права доступа
check_opt_directory() {
    local pkg="$1"
    local opt_dir="/opt/flat/${pkg}"

    if [[ -d "$opt_dir" ]]; then
        print_ok "dir: $opt_dir exists"
        local owner
        owner=$(stat -c '%U:%G' "$opt_dir" 2>/dev/null || stat -f '%Su:%Sg' "$opt_dir" 2>/dev/null)
        print_info "dir: $opt_dir owner=$owner"
    else
        print_warn "dir: $opt_dir missing"
    fi
}

# Проверить конфигурационные файлы
check_configs() {
    local pkg="$1"
    local nginx_avail="/etc/nginx/sites-available/${pkg}"
    local nginx_en="/etc/nginx/sites-enabled/${pkg}"
    local logrotate="/etc/logrotate.d/${pkg}.conf"
    local sudoers="/etc/sudoers.d/${pkg}"

    if [[ -f "$nginx_avail" ]]; then
        print_ok "nginx: $nginx_avail exists"
        if [[ -L "$nginx_en" ]] || [[ -f "$nginx_en" ]]; then
            print_ok "nginx: $nginx_en enabled"
        else
            print_warn "nginx: $nginx_en not enabled"
        fi
    fi

    if [[ -f "$logrotate" ]]; then
        print_ok "logrotate: $logrotate exists"
    fi

    if [[ -f "$sudoers" ]]; then
        print_ok "sudoers: $sudoers exists"
    fi
}

# Проверить процесс по имени или паттерну
check_process() {
    local pkg="$1"
    local pids
    # _sys_pkg_pids() — не голый pgrep по имени пакета, иначе пакеты вроде
    # fss-capagent (запускают сторонний бинарь heplify, без "fss-capagent"
    # где-либо в argv) никогда не находились бы, хотя systemd видит unit
    # активным; у _sys_pkg_pids есть запасной путь через MainPID юнита.
    pids=$(_sys_pkg_pids "$pkg" 2>/dev/null | paste -sd',' - 2>/dev/null)

    if [[ -n "$pids" ]]; then
        print_ok "process: running (PIDs: $pids)"
        for p in $(echo "$pids" | tr ',' ' '); do
            local psline
            psline=$(ps -p "$p" -o pid,comm,args --no-headers 2>/dev/null || true)
            if [[ -n "$psline" ]]; then
                echo "        $psline"
            fi
        done
    fi
}

# Проверить сетевые порты
check_ports() {
    local pkg="$1"
    local ports_spec="${PKG_PORTS[$pkg]:-}"

    [[ -z "$ports_spec" ]] && return 0

    if ! command -v ss &>/dev/null && ! command -v netstat &>/dev/null; then
        print_warn "ports: ss/netstat not found"
        return 1
    fi

    local port
    for port in $(echo "$ports_spec" | tr ',' ' '); do
        local found=""
        if [[ "$port" == *"-"* ]]; then
            local start end
            start=$(echo "$port" | cut -d'-' -f1)
            end=$(echo "$port" | cut -d'-' -f2)
            if command -v ss &>/dev/null; then
                found=$(ss -tan 2>/dev/null | awk -v s="$start" -v e="$end" 'match($4, /:([0-9]+)$/, arr) { if (arr[1]+0 >= s+0 && arr[1]+0 <= e+0) print }' | head -1)
            fi
        else
            local pnum="$port"
            if [[ "$port" == *"/"* ]]; then
                pnum="${port%%/*}"
            fi
            if command -v ss &>/dev/null; then
                found=$(ss -tlnp 2>/dev/null | grep -E ":${pnum} " | head -1 || true)
            elif command -v netstat &>/dev/null; then
                found=$(netstat -tlnp 2>/dev/null | grep -E ":${pnum} " | head -1 || true)
            fi
        fi

        if [[ -n "$found" ]]; then
            print_ok "port: ${port} is open"
        else
            print_warn "port: ${port} not listening"
        fi
    done
}

# Проверить состояние API
check_api_health() {
    local pkg="$1"
    local endpoint="${PKG_API[$pkg]:-}"
    local ports_spec="${PKG_PORTS[$pkg]:-}"

    [[ -z "$endpoint" ]] || [[ -z "$ports_spec" ]] && return 0

    if ! command -v curl &>/dev/null; then
        print_warn "api: curl not found"
        return 1
    fi

    local first_port
    first_port=$(echo "$ports_spec" | tr ',' '\n' | grep -E '^[0-9]+$' | head -1)
    [[ -z "$first_port" ]] && return 0

    local url="http://localhost:${first_port}${endpoint}"
    local code
    code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "$url" 2>/dev/null || true)
    if [[ "$code" == "200" ]] || [[ "$code" == "204" ]]; then
        print_ok "api: $url => $code"
    elif [[ -n "$code" ]]; then
        print_warn "api: $url => $code"
    else
        print_warn "api: $url unreachable"
    fi
}

# --- 4. Проверки состояния по пакетам -------------------------------------------
# Зарегистрировать PKG_DEPS + зависимости PM в ALL_DEPENDS (первый проход перед параллельными проверками)
_register_pkg_deps() {
    local pkg="$1"
    local deps_meta="${PKG_DEPS[$pkg]:-}"
    local deps_real dep

    if [[ -n "$deps_meta" ]]; then
        for dep in $(echo "$deps_meta" | tr ',' ' '); do
            register_dep "$dep" "$pkg"
        done
    fi
    deps_real=$(get_pkg_depends "$pkg" 2>/dev/null)
    if [[ -n "$deps_real" ]]; then
        for dep in $(echo "$deps_real" | tr ',' ' '); do
            register_dep "$dep" "$pkg"
        done
    fi
}

# Проверка одного пакета (учитывает VERBOSE)
check_single_pkg() {
    local pkg="$1"
    local legacy="${PKG_LEGACY[$pkg]:-}"

    # Быстрая тихая проверка для не установленных пакетов
    if ! is_pkg_installed_tiny "$pkg" "$legacy"; then
        if [[ $VERBOSE -eq 1 ]]; then
            echo "=$pkg="
            print_not_installed "$pkg"
            ((NOT_INSTALLED++))
            check_systemd_unit "$pkg"
            check_opt_directory "$pkg"
            check_log_directory "$pkg"
            check_configs "$pkg"
            check_process "$pkg"
            check_ports "$pkg"
            check_api_health "$pkg"
        fi
        return 1
    fi

    echo "=$pkg="

    # Пакет установлен (или есть следы) — печатаем полные детали
    check_pkg_installed "$pkg" "$legacy"
    local rc=$?

    if [[ $rc -eq 3 && -z "$FOUND_PKG_VER" ]]; then
        if has_any_trace "$pkg"; then
            print_warn "pkg: $pkg not found in PM, but traces exist on disk"
        fi
        return 1
    fi

    # Печатаем версию отдельно
    if [[ -n "$FOUND_PKG_VER" ]]; then
        print_info "version: ${FOUND_PKG_VER}"
    fi

    # Печатаем и собираем зависимости (регистрация обычно уже сделана на первом проходе)
    local deps_meta="${PKG_DEPS[$pkg]:-}"
    local deps_real=""
    if [[ -n "$deps_meta" ]]; then
        print_info "depends: ${deps_meta}"
        for dep in $(echo "$deps_meta" | tr ',' ' '); do
            register_dep "$dep" "$pkg"
        done
    fi

    # Пытаемся получить реальные зависимости из пакетного менеджера
    deps_real=$(get_pkg_depends "$pkg" 2>/dev/null)
    if [[ -n "$deps_real" ]]; then
        # Показываем реальные depends только если отличаются от meta
        if [[ "$deps_real" != "$deps_meta" ]]; then
            print_info "depends (PM): ${deps_real}"
        fi
        for dep in $(echo "$deps_real" | tr ',' ' '); do
            register_dep "$dep" "$pkg"
        done
    fi

    ((INSTALLED++))
    if _is_infrastructure_pkg "$pkg"; then
        check_infrastructure_pkg "$pkg"
        return 0
    fi
    check_systemd_unit "$pkg"
    check_opt_directory "$pkg"
    check_log_directory "$pkg"
    check_configs "$pkg"
    check_process "$pkg"
    check_ports "$pkg"
    check_api_health "$pkg"
    return 0
}

# Запуск проверок для одного продукта (параллельные пакеты, буферизованный упорядоченный вывод)
run_product_checks() {
    local product="$1"
    local installed_count=0
    local total_count=0
    local product_pkgs=()
    local pkg legacy max_jobs tmpdir job_idx=0 dw de di dn

    for pkg in "${!PKG_PRODUCT[@]}"; do
        if [[ "${PKG_PRODUCT[$pkg]:-}" == "$product" ]]; then
            product_pkgs+=("$pkg")
            ((total_count++))
            legacy="${PKG_LEGACY[$pkg]:-}"
            if is_pkg_installed_tiny "$pkg" "$legacy"; then
                ((installed_count++))
                _register_pkg_deps "$pkg"
            fi
        fi
    done

    [[ $total_count -eq 0 ]] && return

    if [[ $installed_count -eq 0 ]]; then
        if [[ $VERBOSE -eq 1 ]]; then
            echo ""
            echo "=== $product ==="
            for pkg in "${product_pkgs[@]}"; do
                check_single_pkg "$pkg"
            done
        fi
        return
    fi

    echo ""
    echo "=== $product ==="

    # Сортируем имена пакетов для устойчивого соответствия job_idx ↔ вывод
    IFS=$'\n' product_pkgs=($(printf '%s\n' "${product_pkgs[@]}" | sort)); unset IFS

    max_jobs=$(_collector_max_jobs)
    [[ "$max_jobs" -gt ${#product_pkgs[@]} ]] && max_jobs=${#product_pkgs[@]}
    tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/flat_pkg.XXXXXX" 2>/dev/null) || tmpdir="/tmp/flat_pkg.$$"
    mkdir -p "$tmpdir" 2>/dev/null || true
    _get_cpu_usage_percent >/dev/null

    for pkg in "${product_pkgs[@]}"; do
        if ! _collector_wait_slot "$max_jobs"; then
            break
        fi
        job_idx=$((job_idx + 1))
        (
            renice -n 5 $$ >/dev/null 2>&1 || true
            # Снимаем снэпшот счётчиков до проверки — НЕ "local" (это простой
            # subshell, а не тело функции); дельта записывается ниже в
            # файл, отдельный от человекочитаемого вывода самого check_single_pkg,
            # чтобы родительский процесс мог восстановить именно то, что было
            # увеличено здесь, без необходимости заново вычислять это через grep по
            # напечатанному тексту [WARN]/[FAIL] (хрупко: зависит от того, что текст сообщения никогда не изменится).
            _pj_w0=$WARNINGS; _pj_e0=$ERRORS; _pj_i0=$INSTALLED; _pj_n0=$NOT_INSTALLED
            check_single_pkg "$pkg"
            printf '%d %d %d %d\n' \
                "$((WARNINGS - _pj_w0))" "$((ERRORS - _pj_e0))" \
                "$((INSTALLED - _pj_i0))" "$((NOT_INSTALLED - _pj_n0))" \
                > "$tmpdir/$job_idx.stat" 2>/dev/null
        ) > "$tmpdir/$job_idx" 2>&1 &
        COLLECTOR_JOB_PIDS+=($!)
    done
    _collector_wait_all_jobs

    # Печатаем в порядке пакетов; восстанавливаем счётчики, потерянные в subshell'ах (Summary /
    # Zabbix), из собственного дельта-файла каждой задачи, а не разбором напечатанного текста.
    job_idx=0
    for pkg in "${product_pkgs[@]}"; do
        job_idx=$((job_idx + 1))
        [[ -f "$tmpdir/$job_idx" ]] || continue
        cat "$tmpdir/$job_idx"
        if [[ -f "$tmpdir/$job_idx.stat" ]]; then
            read -r dw de di dn < "$tmpdir/$job_idx.stat"
            [[ "$dw" =~ ^-?[0-9]+$ ]] && WARNINGS=$((WARNINGS + dw))
            [[ "$de" =~ ^-?[0-9]+$ ]] && ERRORS=$((ERRORS + de))
            [[ "$di" =~ ^-?[0-9]+$ ]] && INSTALLED=$((INSTALLED + di))
            [[ "$dn" =~ ^-?[0-9]+$ ]] && NOT_INSTALLED=$((NOT_INSTALLED + dn))
        fi
    done
    rm -rf -- "$tmpdir" 2>/dev/null
}

# Проверить, существует ли файл разделяемой библиотеки в стандартных lib-путях
is_lib_available() {
    local lib="$1"
    for path in /usr/lib64 /lib64 /usr/lib /lib; do
        [[ -f "$path/$lib" ]] && return 0
    done
    return 1
}

