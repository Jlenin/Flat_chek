# Модуль: 04_os_detect.sh
# Слой: core
# Назначение: Определение дистрибутива и пакетного менеджера (dpkg/rpm/pacman/apk) — detect_os().
# Публичные функции: detect_os(), get_os_release()
# Зависит от: 02_output.sh (log_debug)
# Не зависит от: от каталога пакетов и проверок — они читают уже установленную переменную PKG_MANAGER
# Side effects: читает /etc/os-release, запускает dpkg/rpm/pacman/apk для проверки наличия
#
# Источник: перенесено без изменений логики из flat_check.sh (строки 373-479).

# --- 3. ОС / пакетный менеджер ---------------------------------------------------
# Определить ОС и пакетный менеджер
detect_os() {
    OS_NAME="Unknown"
    OS_ID="unknown"
    OS_VERSION=""
    OS_FULL_VER=""

    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        OS_NAME="$NAME"
        OS_ID="$ID"
        OS_VERSION="${VERSION_ID:-}"
        OS_FULL_VER="${PRETTY_NAME:-$NAME}"
    fi

    # Специфичные для дистрибутива файлы версий для более точного определения релиза
    local ver_files=(
        "/etc/astra_version"
        "/etc/centos-release"
        "/etc/redhat-release"
        "/etc/oracle-release"
        "/etc/rocky-release"
        "/etc/almalinux-release"
        "/etc/alpine-release"
        "/etc/arch-release"
        "/etc/debian_version"
    )
    for vf in "${ver_files[@]}"; do
        [[ -f "$vf" ]] || continue
        local ver_content
        ver_content=$(head -1 "$vf" 2>/dev/null | tr -d '\n')
        [[ -z "$ver_content" ]] && continue
        # Обновить OS_NAME из файла релиза, если ещё не определено
        if [[ "$OS_NAME" == "Unknown" ]]; then
            OS_NAME=$(echo "$ver_content" | sed 's/ release.*//' | sed 's/ Linux//')
        fi
        # Извлечь номер версии
        local ver_num
        ver_num=$(echo "$ver_content" | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1)
        [[ -n "$ver_num" ]] && OS_FULL_VER="$OS_NAME $ver_num"
        # Для Debian /etc/debian_version содержит только номер
        if [[ "$vf" == "/etc/debian_version" && -z "$ver_num" ]]; then
            ver_num=$(echo "$ver_content" | grep -oE '[0-9]+(\.[0-9]+)?' | head -1)
            [[ -n "$ver_num" ]] && OS_FULL_VER="$OS_NAME $ver_num"
        fi
        break
    done

    [[ -z "$OS_FULL_VER" ]] && OS_FULL_VER="${OS_NAME} ${OS_VERSION}"

    if command -v dpkg &>/dev/null; then
        PM="dpkg"
    elif command -v rpm &>/dev/null; then
        PM="rpm"
    elif command -v pacman &>/dev/null; then
        PM="pacman"
    elif command -v apk &>/dev/null; then
        PM="apk"
    else
        PM="unknown"
    fi

    print_info "OS: $OS_FULL_VER"
    print_info "Package manager: $PM"
    echo ""
}

# Канонический id дистрибутива для OS-специфичной диспетчеризации (get_sys_cpu_<id> и т.п.).
# Тот же порядок определения, что и в detect_os(): сначала /etc/os-release, затем legacy
# файлы релиза для систем без os-release. Чистая функция — без глобальных переменных,
# без вывода, просто печатает одно из:
#   debian ubuntu astra centos rhel oracle rocky almalinux arch alpine unknown
get_os_release() {
    local id=""

    if [[ -f /etc/os-release ]]; then
        id=$(. /etc/os-release 2>/dev/null; echo "${ID:-}")
        id="${id,,}"
    fi

    if [[ -z "$id" ]]; then
        if   [[ -f /etc/astra_version ]];     then id="astra"
        elif [[ -f /etc/centos-release ]];    then id="centos"
        elif [[ -f /etc/rocky-release ]];      then id="rocky"
        elif [[ -f /etc/almalinux-release ]];  then id="almalinux"
        elif [[ -f /etc/oracle-release ]];     then id="oracle"
        elif [[ -f /etc/redhat-release ]];     then id="rhel"
        elif [[ -f /etc/alpine-release ]];     then id="alpine"
        elif [[ -f /etc/arch-release ]];       then id="arch"
        elif [[ -f /etc/debian_version ]];     then id="debian"
        fi
    fi

    # Нормализуем пару алиасов, которые os-release использует, но которые не совпадают с
    # именами файлов релиза выше (у Oracle Linux ID "ol"; у RHEL — "redhat"
    # в очень старых релизах). Всё остальное передаётся как есть и
    # попадает в общую ветку диспетчеризации у вызывающего кода.
    case "$id" in
        ol)     id="oracle" ;;
        redhat) id="rhel" ;;
        "")     id="unknown" ;;
    esac

    echo "$id"
}

