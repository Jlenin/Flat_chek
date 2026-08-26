# CONTEXT — handoff для другого агента

Внутренний контекст репозитория **Flat_chek** (`github.com/Jlenin/Flat_chek`).  
Обновлять при смене версии, JSON-контракта, установщика или паритета скриптов.

**Обновлено:** 2026-08-25  
**Версия:** `flat_check.sh` 3.8.6 / `flat_check_2.sh` 3.11.6

---

## Роли файлов

| Путь | Роль |
|------|------|
| `flat_check.sh` | health (+ JSON/push CLI) |
| `flat_check_2.sh` | тот же health/JSON **1к1** + сбор логов |
| `flat_check.packages.conf` | каталог пакетов рядом со скриптом (optional; иначе builtin) |
| `agent/` | установка push-агента на ноду (conf, cron, install, док) |
| `README.md` | пользовательская дока по check / check_2 |
| `agent/README.md` | дока по агенту и установщику |
| `CONTEXT.md` | этот handoff (в корневой README не ссылаемся) |

Каталог `examples/` удалён — всё актуальное лежит в `agent/`.

---

## Сделано по смыслу

1. Offline log path в `_2` (midnight, unsorted, daily merge, chunk modes).
2. Health-only `flat_check.sh` из `_2` без collector.
3. Модель доставки: агент на ноде → JSON push (не SSH-координатор как основной путь).
4. **3.7.0:** `--json`/`--push`/`--config`/`--pkg`/identity в обоих скриптах; комплект `agent/`.
5. Docs cleanup: корневой README только про check/check_2; агент — в `agent/`.
6. **3.8.0 (`_2`):** в мастере третий слой выбора логов — типы внутри каталога службы; `mgcpclient` спрашивается только если выбран `fss-server` и типы не уточняли.
7. **3.9.0 (`_2`):** `-t` контекст (last-N vs to после `-f`); `from<=to`; отсев архивов (day±1 + zgrep/12-probe); stream-extract `.gz` без temp; `n` в pick = отмена сбора.
8. **3.10.0 (`_2`):** ускорение offline — hour-zgrep для коротких окон, skip `.N.gz` если live plain покрывает диапазон, без 12-point после zgrep-miss, stream early-stop, soft-sorted seek для plain; TUNABLES-блок в начале; прогресс `%` в консоли. Host CPU/MEM 80% не трогаем (Zabbix).
9. **3.10.1 (`_2`):** offline пул по **файлам** (не по каталогам) под host-gate; inner chunk≤1 при нескольких file-workers; sticky progress `\r`+`CSI K`; check уже на том же пуле.
10. **3.10.2 (`_2`):** logrotate `name.txt.<anything>` схлопывается в тот же stem/group, что и live.
11. **3.10.3 (`_2`):** find видит РЕД ОС-стиль `name.txt-YYYYMMDD[.gz]` (`*.txt-*` / `*.log-*`), не только `name.txt.*`.
12. **3.10.4 (`_2`):** широкая матрица `_logrotate_name_matrix` (40+ имён) в selftest — stem/group/find/type-filter.
13. **3.8.0 / 3.11.0:** каталог `flat_check.packages.conf`; продукт Infrastructure (PKG); раздел зависимостей переименован в `=== Depends ===` (полный список, как раньше); FVSC/fc-*/fpw-frontend; фикс JSON `ALL_DEPENDS` hyphen + `summary.installed` subshell.
14. **3.8.2 / 3.11.2:** `PUSH_INSECURE=1` (conf/env, `install_flat_check.sh --push-insecure`) — curl `-k` для push на https с self-signed сертификатом (иначе `push: FAIL (last http=000)` при рабочем URL).
15. **3.8.3 / 3.11.3:** фикс `system.cpu.usage_percent=0` в `--json`/`--push` — `_json_collect_system` вызывал `_get_cpu_usage_percent` дважды через `$(...)`, оба раза в новом субшелле, поэтому дельта `/proc/stat` никогда не сохранялась и результат всегда был 0 (экранный вывод не затронут — там init-вызов уже был прямым, без `$(...)`). Теперь переиспользует `_sys_cpu_via_procstat()`; заодно окно замера (`sleep`) там увеличено с 0.25s до 0.5s для более стабильного отсчёта (действует и на экранный вывод, и на JSON).
16. **3.8.4 / 3.11.4:** фикс `--dev`/`--selftest extended`: `unset ALL_DEPENDS; declare -A ALL_DEPENDS` в `_run_selftest_simple` и в `build_health_json` выполнял `declare -A` **внутри функции без `-g`**, из-за чего создавалась ЛОКАЛЬНАЯ тень, а глобальный `ALL_DEPENDS` (объявлен `-A` в разделе 0) оставался unset после возврата. Дальше `register_dep()` видел его как обычный индексированный массив и пытался вычислить `"$dep"` арифметически — на дефисных именах вида `fss-frontend` это падает под `set -u`: `"fss: unbound variable"` (именно так и разово проявлялось в `--dev`, сразу после `_run_selftest_simple`, на первом же пакете с такой зависимостью). Исправлено на `declare -gA ALL_DEPENDS=()` во всех 5 местах (`agent/json_report.inc.sh`, оба `.sh` × 2). Заодно добавлен `--debug` (обоим скриптам) — дублирует `log_debug()`/`DEBUG`-строки сессионного лога на экран (stderr); `register_dep()` теперь логирует каждый `dep`/`pkg` через `log_debug`, так что с `--debug` последняя строка перед похожим крашем сразу называет виновную зависимость.
17. **3.8.5 / 3.11.5:**
    - фикс ложного `mariadb not installed`: Debian/Ubuntu/Astra не поставляют пакет с именем `mariadb` — только `mariadb-server`; каталог (`flat_check.packages.conf` + builtin в обоих `.sh`) для `mariadb` не указывал legacy-имя, поэтому `is_pkg_installed_tiny`/`check_pkg_installed_dpkg` не находили пакет по литеральному имени и правильная infra-логика (`check_infrastructure_pkg`/`_infra_dep_satisfied`, уже умеющая про `mariadb-server`/`mysql-server`) даже не запускалась. Добавлен legacy `"mariadb-server,mysql-server"`.
    - фикс неполного `"infrastructure"` в JSON: `build_health_json` регистрировал в `ALL_DEPENDS` только `PKG_DEPS[$pkg]` (статическая мета из каталога), а не реальные зависимости от пакетного менеджера (`get_pkg_depends`) — в отличие от текстового пути (`_register_pkg_deps`/`check_single_pkg`), который регистрирует оба источника. Из-за этого `"infrastructure"` в `--json`/`--push` был значительно короче текстового `=== Depends ===`. Теперь `build_health_json` вызывает `_register_pkg_deps "$pkg"` (тот же хелпер, что и текстовый путь) — оба вывода дают одинаковый набор зависимостей.
    - `system.cpu.usage_percent`: если первый замер `_sys_cpu_via_procstat` (после фикса 3.8.3/3.11.3) вернул 0, теперь берётся соседнее окно ещё раз — единичная 0.5s-проба может честно попасть на затишье между всплесками нагрузки; это не тот же баг, что раньше (структурно фикс 15 уже верен), а точность на volatile-нагрузке (VoIP-подобные процессы).
    - `agent/reinstall_flat_check.sh` (новый): тонкая обёртка над `install_flat_check.sh` — только решает, сбрасывать ли существующий conf на шаблон (`-y`/`--yes`) или сохранить (`-n`/`--no`, умолчание); остальное делегирует установщику как есть.
    - `agent/uninstall_flat_check.sh` (новый): убирает бинарь(и)/cron/каталог пакетов; конфиг — по `-y`/`-n` (умолчание при отсутствии флага: удалить, в отличие от reinstall). В обоих: без флага и без tty — тихо применяется соответствующее умолчание (не виснут в ожидании ввода).
18. **agent, без версии скрипта:** `reinstall_flat_check.sh` вызывал `install_flat_check.sh` через `exec` — требовал бит `+x` на нём; после скачивания архивом с GitHub («Download ZIP», папка вида `<repo>-main`) бит не всегда сохраняется, и `sudo` тут не помогает (как и при `noexec` на `/home`). Заменено на `exec bash "$INSTALLER" ...` (нужно только чтение). Заодно все три скрипта агента (`install`/`reinstall`/`uninstall_flat_check.sh`) при каждом запуске лучше-эффортно чинят бит `+x` — себе, друг другу и `flat_check.sh`/`flat_check_2.sh` в корне: ручной `chmod +x` нужен один раз на любом из трёх (или запуск через `bash script.sh`), дальше остальные подхватываются сами.
19. **3.8.6 / 3.11.6:** `push_health_json` глушил `stderr` curl (`2>/dev/null`) — при `http=000` не было видно ПОЧЕМУ (DNS/connection refused/timeout/TLS), только сам факт неудачи. Теперь curl-ошибка каждой попытки уходит в `log_debug` (`push: curl → $url: ...`) — видно в файле сессионного лога всегда, на экране — с `--debug`.

---

## Паритет (обязательно)

Совпадают в обоих `.sh`:

- каталог/`PKG_*` (через `_pkg_set` + conf), System/packages/infra, resource-gate
- блок JSON/push = `agent/json_report.inc.sh`

Только в `_2`: `-log`, wizard `-i`, seek/chunk, tcpdump и т.п.  
В `flat_check.sh` флаг `-i` **не используется** (чтобы не путать с мастером `_2`).  
VERBOSE health по всем пакетам — через `--dev` / `--selftest extended` (одинаково в обоих).

CLI:

- `-i`: только `_2` (мастер); в `flat_check` — unknown option
- `-p` / `--product`: health/JSON фильтр; в `_2` при `-log` — выбор логов
- `--json`/`--push` обрабатываются до `-log` и завершают процесс

Приоритет настроек агента: **CLI > env > conf > авто**.

---

## Агент (кратко)

```bash
sudo ./agent/install_flat_check.sh \
  --push-url 'https://…/ingest' \
  --push-token SECRET \
  --host-id ss-n1 \
  --service-name fss-backend
```

- JSON: `host_id`, `host_ip`, `service_name` + products/system/…
- `PUSH_URLS` — несколько http/https
- cron по умолчанию: `--push` (без `--json`, чтобы не раздувать лог)
- `SERVICE_NAME` — CI/CD имя (`fss-backend`…), см. `agent/service_names.md`

Известные правки, которые уже внесены:

- дефолты JSON-блока через `: "${VAR:=…}"` (не затирать env);
- conf не перетирает уже заданные CLI/env;
- установщик пишет conf без хрупкого `sed` по URL/токену;
- `--conf-dir` корректно задаёт путь conf.
- push: код ответа curl не дублируется в `000000`.
- install: без root можно ставить в свой префикс (`--bin/--conf-dir/--skip-cron`); system-wide — через `sudo`.
- `agent/reinstall_flat_check.sh` / `agent/uninstall_flat_check.sh` — см. п.17 выше; `-y`/`-n` (или `--yes`/`--no`) отвечают за судьбу конфига без интерактивного вопроса.

---

## Проверка

```bash
bash -n flat_check.sh flat_check_2.sh agent/install_flat_check.sh
./flat_check.sh --selftest simple
./flat_check_2.sh --selftest simple
./flat_check.sh --json --host-id t --service-name fss-backend | jq .summary
./agent/install_flat_check.sh --dry-run --host-id t --service-name fss-backend \
  --push-url https://example/ingest
```

---

## Куда смотреть

```text
README.md                 ← check / check_2
agent/README.md           ← установка и push
agent/json_report.inc.sh  ← канон JSON/push
agent/install_flat_check.sh
CONTEXT.md                ← handoff
```
