# Модуль: 11_selftest.sh
# Слой: core
# Назначение: --selftest simple|extended — самопроверка ключевых функций/каталога
#   без реального воздействия на систему (кроме чтения состояния). simple — быстрый
#   smoke-test хелперов; extended — тот же VERBOSE health-прогон, что и --dev.
# Публичные функции: run_selftest(level), _run_selftest_simple(), _run_selftest_extended()
# Зависит от: 00_globals.sh, 02_output.sh, 04_os_detect.sh, 05_system_metrics.sh,
#   06_resource_gate.sh, 07_pkg_checks.sh, 08_infra_checks.sh; extended-ветка
#   дополнительно ожидает уже подключённые lib/agent/*.sh (build_health_json,
#   push_health_json, _json_collect_infra) — точка входа обязана подключать agent
#   до вызова run_selftest extended (см. flat_check и ARCHITECTURE.md).
# Не зависит от: lib/logging — самотест логов не проверяет
# Side effects: печатает результаты [OK]/[FAIL], временно выставляет VERBOSE=1
#   и тестовые ALL_DEPENDS/HOST_ID при extended
#
# Источник: перенесено без изменений логики из flat_check.sh (строки 3084-3200).

_SELFTEST_PASS=0
_SELFTEST_FAIL=0

_selftest_ok() {
    print_ok "selftest: $1"
    _SELFTEST_PASS=$((_SELFTEST_PASS + 1))
}

_selftest_bad() {
    print_fail "selftest: $1"
    _SELFTEST_FAIL=$((_SELFTEST_FAIL + 1))
}

_run_selftest_simple() {
    info "Self-test SIMPLE (smoke: health helpers)"
    detect_os
    if [[ -n "${OS_ID:-}" && -n "${PM:-}" ]]; then
        _selftest_ok "detect_os (${OS_ID}/${PM})"
    else
        _selftest_bad "detect_os"
    fi
    local n
    n=$(_collector_max_jobs)
    [[ "$n" =~ ^[1-9][0-9]*$ ]] && _selftest_ok "_collector_max_jobs=$n" || _selftest_bad "_collector_max_jobs"
    _get_mem_usage_percent >/dev/null && _selftest_ok "_get_mem_usage_percent" || _selftest_bad "_get_mem_usage_percent"
    _get_cpu_usage_percent >/dev/null && _selftest_ok "_get_cpu_usage_percent" || _selftest_bad "_get_cpu_usage_percent"
    declare -F check_system >/dev/null && _selftest_ok "check_system defined" || _selftest_bad "check_system defined"
    declare -F run_product_checks >/dev/null && _selftest_ok "run_product_checks defined" || _selftest_bad "run_product_checks defined"
    declare -F check_infrastructure >/dev/null && _selftest_ok "check_infrastructure defined" || _selftest_bad "check_infrastructure defined"
    declare -F build_health_json >/dev/null && _selftest_ok "build_health_json defined" || _selftest_bad "build_health_json defined"
    declare -F push_health_json >/dev/null && _selftest_ok "push_health_json defined" || _selftest_bad "push_health_json defined"
    local j
    HOST_ID="selftest-host" HOST_IP="127.0.0.1" SERVICE_NAME="flat_check" VERBOSE=0
    j=$(SINGLE_PKG="" build_health_json 2>/dev/null | head -c 200 || true)
    if [[ "$j" == {* ]]; then
        _selftest_ok "build_health_json emits JSON"
    else
        _selftest_bad "build_health_json emits JSON"
    fi
    local pkg_count=0
    pkg_count=${#PKG_PRODUCT[@]}
    [[ "$pkg_count" -ge 100 ]] && _selftest_ok "PKG_PRODUCT entries=$pkg_count" || _selftest_bad "PKG_PRODUCT entries=$pkg_count (want ≥100)"

    if [[ "${PKG_PRODUCT[nginx]:-}" == "Infrastructure" && "${PKG_PRODUCT[fvcs-backend]:-}" == "FVSC" ]]; then
        _selftest_ok "catalog has Infrastructure+FVSC"
    else
        _selftest_bad "catalog has Infrastructure+FVSC"
    fi

    # JSON: hyphen in ALL_DEPENDS key + unmet-only infra + INSTALLED вне subshell
    # -g обязателен: этот код выполняется напрямую (не в субшелле $()), поэтому
    # без -g "declare -A" создал бы ЛОКАЛЬНУЮ тень для _run_selftest_simple, а
    # глобальный ALL_DEPENDS остался бы unset и после возврата ломал бы
    # register_dep() в последующем VERBOSE-проходе по пакетам (см. build_health_json выше).
    declare -gA ALL_DEPENDS=()
    ALL_DEPENDS["fps-server"]="fss-frontend"
    ALL_DEPENDS["nginx"]="fss-server"
    local infra_json
    infra_json=$(_json_collect_infra 2>/dev/null || echo FAIL)
    if [[ "$infra_json" == '['*']' && "$infra_json" != *FAIL* ]]; then
        _selftest_ok "_json_collect_infra tolerates hyphen keys"
    else
        _selftest_bad "_json_collect_infra tolerates hyphen keys (got: $infra_json)"
    fi
    if declare -F check_infrastructure >/dev/null; then
        local dep_hdr
        dep_hdr=$(check_infrastructure 2>/dev/null | head -n 2 | tr '\n' ' ')
        if [[ "$dep_hdr" == *"=== Depends ==="* ]]; then
            _selftest_ok "check_infrastructure section is Depends"
        else
            _selftest_bad "check_infrastructure section is Depends (got: $dep_hdr)"
        fi
    fi

    if [[ "${PKG_CATALOG_SOURCE:-}" == "external" || "${PKG_CATALOG_SOURCE:-}" == "internal" ]]; then
        _selftest_ok "PKG_CATALOG_SOURCE=${PKG_CATALOG_SOURCE}"
    else
        _selftest_bad "PKG_CATALOG_SOURCE set"
    fi
}

_run_selftest_extended() {
    info "Self-test EXTENDED (VERBOSE health)"
    _run_selftest_simple
    VERBOSE=1
    detect_os
    check_system
    local products p
    products=("${FLAT_PRODUCTS_ORDER[@]}")
    for p in "${products[@]}"; do
        run_product_checks "$p"
    done
    check_infrastructure
    [[ $SHOW_REPO -eq 1 ]] && check_repositories
    print_summary
    _selftest_ok "health VERBOSE all products"
}

run_selftest() {
    local level="${1:-simple}"
    _SELFTEST_PASS=0
    _SELFTEST_FAIL=0
    echo ""
    info "flat_check self-test ($level) v${SCRIPT_VERSION}"
    case "$level" in
        simple) _run_selftest_simple ;;
        extended|dev) _run_selftest_extended ;;
        *) die "Unknown self-test level: $level (use simple|extended)" ;;
    esac
    echo ""
    if [[ "$_SELFTEST_FAIL" -eq 0 ]]; then
        print_ok "Self-test $level: ${_SELFTEST_PASS} passed, 0 failed"
        return 0
    fi
    print_fail "Self-test $level: ${_SELFTEST_PASS} passed, ${_SELFTEST_FAIL} failed"
    return 1
}
