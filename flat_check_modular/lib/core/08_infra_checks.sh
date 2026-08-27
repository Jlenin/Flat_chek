# Модуль: 08_infra_checks.sh
# Слой: core
# Назначение: Инфраструктурные пакеты (nginx/postgresql/mariadb — без require /opt/flat), список репозиториев по PM, финальный === Summary ===.
# Публичные функции: check_infrastructure(), check_repositories(), print_summary()
# Зависит от: 00_globals.sh, 02_output.sh, 04_os_detect.sh, 07_pkg_checks.sh
# Не зависит от: ничего в core/logging не зависит от этого модуля
# Side effects: печатает разделы === Infrastructure === / === Summary ===, читает списки репозиториев PM
#
# Источник: перенесено без изменений логики из flat_check.sh (строки 1881-2241).

# --- 5. Инфраструктура + репозитории --------------------------------------------
# Проверить все собранные зависимости (Infrastructure)
# Найти первую службу-кандидата systemd, чей unit-*файл* существует, и
# сообщить, активна ли она. Это ровно тот паттерн, который раньше был
# скопипащен для mariadb/postgresql/redis ниже: пробуем кандидатов в заданном
# порядке, останавливаемся на первом совпадении unit-файла (независимо от активности) —
# никогда не сообщаем о кандидате, чей unit вообще не был установлен.
# Возвращает 0, если найден подходящий unit-файл, иначе 1 (вызывающий код решает,
# что значит "нет ни одного подходящего unit" для этой зависимости).
_infra_report_first_unit() {
    local label="$1"; shift
    local svc active
    for svc in "$@"; do
        if systemctl list-unit-files --type=service 2>/dev/null | grep -q "^${svc}.service"; then
            active=$(systemctl is-active "${svc}.service" 2>/dev/null)
            if [[ "$active" == "active" ]]; then
                print_ok "$label: $svc active"
            else
                print_warn "$label: $svc $active"
            fi
            return 0
        fi
    done
    return 1
}

# Пакет из продукта Infrastructure (nginx/postgresql/…): не /opt/flat, а системный.
_is_infrastructure_pkg() {
    [[ "${PKG_PRODUCT[$1]:-}" == "Infrastructure" ]]
}

# Зависимость удовлетворена? (для дедупа авто-раздела Infrastructure)
_infra_dep_satisfied() {
    local dep="$1"
    if [[ "$dep" == *.so.* ]]; then
        is_lib_available "$dep" 2>/dev/null
        return $?
    fi
    case "$dep" in
        nginx)
            command -v nginx &>/dev/null && return 0
            is_dep_installed "$dep" 2>/dev/null && return 0
            return 1
            ;;
        mariadb|mysql|mysql-server|mariadb-server)
            command -v mysql &>/dev/null && return 0
            is_dep_installed "mariadb" 2>/dev/null && return 0
            is_dep_installed "mysql" 2>/dev/null && return 0
            is_dep_installed "mariadb-server" 2>/dev/null && return 0
            is_dep_installed "mysql-server" 2>/dev/null && return 0
            return 1
            ;;
        postgresql|postgresql-*)
            command -v psql &>/dev/null && return 0
            is_dep_installed "$dep" 2>/dev/null && return 0
            return 1
            ;;
        redis|redis-server)
            is_dep_installed "redis" 2>/dev/null || is_dep_installed "redis-server" 2>/dev/null
            return $?
            ;;
        *)
            is_dep_installed "$dep" 2>/dev/null
            return $?
            ;;
    esac
}

# Подробная проверка одного infra-пакета в секции продукта Infrastructure.
check_infrastructure_pkg() {
    local pkg="$1"
    local ver="" active=""

    if _infra_dep_satisfied "$pkg"; then
        ver=$(get_dep_version "$pkg" 2>/dev/null || true)
        case "$pkg" in
            nginx)
                if command -v nginx &>/dev/null; then
                    print_ok "nginx: $(nginx -v 2>&1 | head -1)"
                    if nginx -t &>/dev/null; then
                        print_ok "nginx: config valid"
                    else
                        print_fail "nginx: config invalid"
                    fi
                else
                    print_ok "nginx: installed${ver:+ ($ver)}"
                fi
                ;;
            postgresql|mariadb)
                print_ok "$pkg: ${ver:-installed}"
                ;;
            *)
                print_ok "$pkg: ${ver:-installed}"
                ;;
        esac
        if command -v systemctl &>/dev/null; then
            active=$(systemctl is-active "$pkg" 2>/dev/null || systemctl is-active "${pkg}.service" 2>/dev/null || echo "")
            if [[ "$active" == "active" ]]; then
                print_ok "$pkg: service active"
            elif [[ -n "$active" && "$active" != "unknown" ]]; then
                print_info "$pkg: service $active"
            fi
        fi
    else
        print_fail "$pkg: not installed"
    fi
    check_ports "$pkg"
    check_api_health "$pkg"
}

check_infrastructure() {
    echo ""
    echo "=== Depends ==="

    local has_any=0
    local dep_list=()

    # Сортируем уникальные зависимости
    for dep in "${!ALL_DEPENDS[@]}"; do
        dep_list+=("$dep")
        ((has_any++))
    done

    if [[ $has_any -eq 0 ]]; then
        print_info "No dependencies registered by installed packages"
        return
    fi

    IFS=$'\n' dep_list=($(sort <<<"${dep_list[*]}")); unset IFS

    for dep in "${dep_list[@]}"; do
        local req_by="${ALL_DEPENDS[$dep]:-}"
        local dep_ver=""
        local svc_status=""
        local dep_found=0

        # Разделяемые библиотеки: проверяем наличие файла в lib-путях (RHEL/ReOS 7.3 использует /usr/lib64/)
        if [[ "$dep" == *.so.* ]]; then
            if is_lib_available "$dep"; then
                print_ok "$dep: library found"
            else
                print_fail "$dep: library not found (required by: $req_by)"
            fi
            continue
        fi

        if is_dep_installed "$dep"; then
            dep_found=1
            dep_ver=$(get_dep_version "$dep")
            svc_status=$(check_dep_service "$dep")
        fi

        case "$dep" in
            nginx)
                if command -v nginx &>/dev/null; then
                    local ver
                    ver=$(nginx -v 2>&1 | head -1)
                    print_ok "nginx: $ver"
                    if command -v systemctl &>/dev/null; then
                        local active
                        active=$(systemctl is-active nginx.service 2>/dev/null || systemctl is-active nginx 2>/dev/null || echo "unknown")
                        if [[ "$active" == "active" ]]; then
                            print_ok "nginx: service active"
                        else
                            print_warn "nginx: service $active"
                        fi
                    fi
                    if nginx -t &>/dev/null; then
                        print_ok "nginx: config valid"
                    else
                        print_fail "nginx: config invalid"
                    fi
                elif [[ $dep_found -eq 0 ]]; then
                    print_fail "nginx: not installed (required by: $req_by)"
                else
                    print_warn "nginx: installed but binary not found"
                fi
                ;;
            mariadb|mysql|mysql-server|mariadb-server)
                if command -v mysql &>/dev/null; then
                    local ver
                    ver=$(mysql --version 2>/dev/null | head -1 | cut -d' ' -f1-4)
                    print_ok "mariadb/mysql: $ver"
                    if command -v systemctl &>/dev/null; then
                        _infra_report_first_unit mariadb mariadb mysql
                    fi
                    if command -v ss &>/dev/null && ss -tlnp 2>/dev/null | grep -q ':3306 '; then
                        print_ok "mariadb: port 3306 open"
                    fi
                elif [[ $dep_found -eq 0 ]]; then
                    print_fail "mariadb/mysql: not installed (required by: $req_by)"
                else
                    print_warn "mariadb/mysql: installed but client not found"
                fi
                ;;
            postgresql|postgresql-*)
                if command -v psql &>/dev/null; then
                    local ver
                    ver=$(psql --version 2>/dev/null | head -1)
                    print_ok "postgresql: $ver"
                    if command -v systemctl &>/dev/null; then
                        _infra_report_first_unit postgresql postgresql postgresql-12 postgresql-13 postgresql-14 postgresql-15 postgresql-16
                    fi
                    if command -v ss &>/dev/null && ss -tlnp 2>/dev/null | grep -q ':5432 '; then
                        print_ok "postgresql: port 5432 open"
                    fi
                elif is_dep_installed "mariadb" || is_dep_installed "mysql-server" || is_dep_installed "mariadb-server" || is_dep_installed "mysql"; then
                    print_info "postgresql: not installed, but mariadb/mysql is available (required by: $req_by)"
                elif [[ $dep_found -eq 0 ]]; then
                    print_fail "postgresql: not installed (required by: $req_by)"
                else
                    print_warn "postgresql: installed but client not found"
                fi
                ;;
            redis|redis-server)
                if [[ $dep_found -eq 1 ]]; then
                    print_ok "redis: $dep_ver installed"
                    if command -v systemctl &>/dev/null; then
                        _infra_report_first_unit redis redis-server redis
                    fi
                else
                    print_fail "redis: not installed (required by: $req_by)"
                fi
                ;;
            rabbitmq-server|rabbitmq)
                if [[ $dep_found -eq 1 ]]; then
                    print_ok "rabbitmq: $dep_ver installed"
                    if command -v systemctl &>/dev/null; then
                        local active
                        active=$(systemctl is-active rabbitmq-server.service 2>/dev/null || echo "unknown")
                        if [[ "$active" == "active" ]]; then
                            print_ok "rabbitmq: service active"
                        else
                            print_warn "rabbitmq: service $active"
                        fi
                    fi
                else
                    print_fail "rabbitmq: not installed (required by: $req_by)"
                fi
                ;;
            sudo)
                if [[ $dep_found -eq 1 ]]; then
                    print_ok "sudo: $dep_ver installed"
                else
                    print_fail "sudo: not installed (required by: $req_by)"
                fi
                ;;
            nodejs|nodejs-*)
                if command -v node &>/dev/null; then
                    local ver
                    ver=$(node --version 2>/dev/null | head -1)
                    print_ok "nodejs: $ver"
                elif is_dep_installed "nsolid" || command -v nsolid &>/dev/null; then
                    print_info "nodejs: not installed, but nsolid is available (required by: $req_by)"
                elif [[ $dep_found -eq 0 ]]; then
                    print_fail "nodejs: not installed (required by: $req_by)"
                else
                    print_warn "nodejs: installed but client not found"
                fi
                ;;
            *)
                if [[ $dep_found -eq 1 ]]; then
                    print_ok "$dep: $dep_ver installed"
                    if [[ -n "$svc_status" ]]; then
                        if [[ "$svc_status" == "service active" ]]; then
                            print_ok "$dep: $svc_status"
                        else
                            print_warn "$dep: $svc_status"
                        fi
                    fi
                else
                    print_fail "$dep: not installed (required by: $req_by)"
                fi
                ;;
        esac
    done
}

# Проверить репозитории

# --- Список репозиториев по PM ------------------------------------------------
# По одной самодостаточной функции на каждый пакетный менеджер — каждая читает только
# свои конфиг-файлы/инструменты репозиториев этого PM. check_repositories() ниже просто
# печатает заголовок секции и диспетчеризует по $PM.

# Debian-семья: записи sources.list(.d), затем приоритеты apt-cache policy.
check_repositories_dpkg() {
    local f line policy

    if [[ -f /etc/apt/sources.list ]]; then
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            [[ "$line" == \#* ]] && continue
            print_info "[apt] $line"
        done < /etc/apt/sources.list
    fi

    for f in /etc/apt/sources.list.d/*.list; do
        [[ -f "$f" ]] || continue
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            [[ "$line" == \#* ]] && continue
            print_info "[apt] $line"
        done < "$f"
    done

    if command -v apt-cache &>/dev/null; then
        policy=$(apt-cache policy 2>/dev/null | grep -E '^\s+[0-9]+' | head -20)
        if [[ -n "$policy" ]]; then
            echo ""
            print_info "APT priorities:"
            echo "$policy" | while IFS= read -r line; do
                print_info "  $line"
            done
        fi
    fi
}

# RHEL-семья: вывод `yum repolist`, затем сырые файлы *.repo внутри yum.repos.d.
check_repositories_rpm() {
    local f line repolist

    if command -v yum &>/dev/null; then
        repolist=$(yum repolist 2>/dev/null | tail -n +2 | grep -v "^repolist" | head -30)
        if [[ -n "$repolist" ]]; then
            echo "$repolist" | while IFS= read -r line; do
                print_info "[yum] $line"
            done
        fi
    fi

    for f in /etc/yum.repos.d/*.repo; do
        [[ -f "$f" ]] || continue
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            [[ "$line" == \#* ]] && continue
            print_info "[yum] $line"
        done < "$f"
    done
}

# Печатает настроенные репозитории пакетов для определённого PM (только dpkg/rpm —
# для pacman/apk список репозиториев никогда не был реализован, как и до этого разделения).
check_repositories() {
    echo ""
    echo "=== Repositories ==="

    case "$PM" in
        dpkg) check_repositories_dpkg ;;
        rpm)  check_repositories_rpm ;;
    esac
}

# Итоги
print_summary() {
    echo ""
    echo "=== Summary ==="
    print_info "Installed: $INSTALLED | Errors: $ERRORS | Warnings: $WARNINGS"
}


