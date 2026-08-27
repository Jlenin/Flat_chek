# Модуль: 03_i18n.sh
# Слой: core
# Назначение: Локализация текстов интерфейса (_l key) — переключается через
#   переменную CURRENT_LANG (по умолчанию en, мастер переключает на ru).
#   Используется в основном мастером и сборщиком логов (lib/logging), но
#   живёт в core, т.к. это универсальная утилита без зависимостей от
#   остальных слоёв.
# Публичные функции: _l(key) — печатает локализованную строку по ключу
# Зависит от: 00_globals.sh (объявляет свой собственный CURRENT_LANG ниже,
#   чтобы не требовать правки 00_globals.sh, у которого в flat_check.sh
#   такой переменной не было — i18n нужен только logging/wizard)
# Не зависит от: каталога, вывода, ОС-детекта, проверок пакетов
# Side effects: нет — чистая функция, только echo
#
# Источник: перенесено без изменений логики из flat_check_2.sh (строки 514-736,
#   плюс объявление CURRENT_LANG из строки 128 той же секции 0).

CURRENT_LANG="${CURRENT_LANG:-en}"

# --- 2b. Локализация (_l) --------------------------------------------------------
_l() {
    local key="$1"
    case "$CURRENT_LANG" in
        ru)
            case "$key" in
                err_online_need_t) echo "Online без TTY требует -t/--timeout" ;;
                ask_lang_prompt)   echo "Ваш выбор / Your choice [1-2]: " ;;
                mode_log)          echo "Режим логов" ;;
                workdir)           echo "Рабочая директория" ;;
                found_svcs)        echo "Найдено служб" ;;
                found_logdirs)     echo "Найдено лог-директорий" ;;
                tail_running)      echo "Процессов tail" ;;
                tcpdump_started)   echo "tcpdump запущен (PID" ;;
                tcpdump_fail)      echo "tcpdump не запустился (нужен root?)" ;;
                tcpdump_notfound)  echo "tcpdump не найден" ;;
                log_running)       echo "Сбор логов запущен. Нажмите [Enter] для остановки." ;;
                log_running_online_note) echo "Online: в архив попадают только НОВЫЕ строки, появившиеся после старта сбора." ;;
                log_archive_stats) echo "Лог-файлов с данными в архиве:" ;;
                log_online_no_new) echo "За время сбора новых записей в логах не было (online пишет только новые строки)" ;;
                log_autostop)      echo "Автоостановка через" ;;
                log_stopping)      echo "Остановка сбора..." ;;
                log_files_from)    echo "файлов из" ;;
                log_copydone)      echo "Копирование завершено" ;;
                log_all)           echo "Копирование всех логов" ;;
                archive_pigz)      echo "Архив создан (pigz)" ;;
                archive_gzip)      echo "Архив создан (gzip)" ;;
                archive_at)        echo "Архив" ;;
                done_msg)          echo "Готово" ;;
                err_no_logdirs)    echo "Не найдено лог-директорий" ;;
                err_no_logfiles)   echo "Нет лог-файлов для мониторинга" ;;
                err_perm)          echo "Нет прав на запись" ;;
                err_cmd_notfound)  echo "Не найдена команда" ;;
                config_collected)  echo "Собрано конфигов" ;;
                sys_copied)        echo "Скопирован" ;;
                wiz_title_mode)    echo "=== Режим ===" ;;
                wiz_mode_1)        echo "  1 — Проверка служб (health check)" ;;
                wiz_mode_2)        echo "  2 — Сбор логов" ;;
                wiz_mode_3)        echo "  3 — Самотест скрипта" ;;
                wiz_mode_prompt)   echo "Ваш выбор [1-3]: " ;;
                wiz_title_selftest) echo "=== Самотест ===" ;;
                wiz_selftest_1)    echo "  1 — Простой (факт запуска функций)" ;;
                wiz_selftest_2)    echo "  2 — Расширенный (варианты + health + seek/chunk)" ;;
                wiz_selftest_prompt) echo "Ваш выбор [1-2]: " ;;
                wiz_title_type)    echo "=== Тип сбора ===" ;;
                wiz_type_1)        echo "  1 — Online (tail -F, в реальном времени)" ;;
                wiz_type_2)        echo "  2 — Offline (копирование готовых логов)" ;;
                wiz_type_prompt)   echo "Ваш выбор [1-2]: " ;;
                wiz_timeout)       echo -n "Таймаут сбора (например 5h, 30m, Enter = бесконечно): " ;;
                wiz_tcpdump)       echo -n "tcpdump? (y/n): " ;;
                wiz_title_range)   echo "=== Диапазон ===" ;;
                wiz_range_1)       echo "  1 — За последние N (например 5h)" ;;
                wiz_range_2)       echo "  2 — От даты-времени до даты-времени" ;;
                wiz_range_3)       echo "  3 — От даты-времени + N часов/минут" ;;
                wiz_range_all)     echo "  Enter — Все логи" ;;
                wiz_range_prompt)  echo "Ваш выбор [1-3]: " ;;
                wiz_for_how_long)  echo -n "За сколько? (например 5h, 30m): " ;;
                wiz_from_dt)       echo -n "От (например 25.06.2026 10:00): " ;;
                wiz_to_dt)         echo -n "До (например 25.06.2026 12:00): " ;;
                wiz_from_dt2)      echo -n "От (например 25.06.2026 10:00): " ;;
                wiz_for_offset)    echo -n "На сколько? (например +3h, 3h, +30m): " ;;
                wiz_title_chunk)   echo "=== Разбивка больших логов ===" ;;
                wiz_chunk_1)       echo "  1 — По размеру (например 100MB) [по умолчанию]" ;;
                wiz_chunk_2)       echo "  2 — По количеству строк (например 500000)" ;;
                wiz_chunk_prompt)  echo "Ваш выбор [1-2, Enter=1]: " ;;
                wiz_chunk_size_prompt)  echo -n "Максимальный размер одной части (например 50M, 200M; Enter = 100M): " ;;
                wiz_chunk_lines_prompt) echo -n "Максимум строк в одной части (Enter = 500000): " ;;
                wiz_chunk_size_invalid) echo "Не удалось разобрать размер, используется значение по умолчанию:" ;;
                wiz_output_dir)    echo -n "Директория для архива (Enter = рядом со скриптом): " ;;
                wiz_show_repo)     echo -n "Показать репозитории? (y/n): " ;;
                wiz_title_scope)   echo "=== Объём сбора ===" ;;
                wiz_scope_1)       echo "  1 — Краткий (только логи выбранных продуктов/служб)" ;;
                wiz_scope_2)       echo "  2 — Расширенный (+ system, nginx, PostgreSQL, configs; online: tcpdump)" ;;
                wiz_scope_prompt)  echo "Ваш выбор [1-2]: " ;;
                wiz_title_products) echo "=== Продукты ===" ;;
                wiz_products_all)  echo "  a — Все установленные" ;;
                wiz_products_prompt) echo -n "Номера через запятую/пробел, a=все, n=отмена: " ;;
                wiz_refine_services) echo -n "Уточнить службы? (y/n, Enter=n): " ;;
                wiz_title_services) echo "=== Службы ===" ;;
                wiz_services_all)  echo "  a — Все службы выбранных продуктов" ;;
                wiz_services_prompt) echo -n "Номера через запятую/пробел, a=все, n=отмена: " ;;
                wiz_refine_log_types) echo -n "Выбрать конкретные логи служб? (y/n, Enter=n): " ;;
                wiz_title_log_types) echo "=== Типы логов службы ===" ;;
                wiz_log_types_for) echo "Логи службы" ;;
                wiz_log_types_all) echo "  a — все найденные типы" ;;
                wiz_log_types_prompt) echo -n "Номера через запятую/пробел, a=все, n=отмена: " ;;
                wiz_log_types_none) echo "типы логов не найдены — будут собраны все доступные файлы" ;;
                wiz_preview_log_types) echo "типы логов" ;;
                wiz_no_targets)    echo "На хосте не найдено известных продуктов/служб" ;;
                wiz_preview_pkgs)  echo "Выбрано служб" ;;
                wiz_preview_dirs)  echo "Лог-директорий к сбору" ;;
                ask_mgcpclient)    echo -n "SoftSwitch (fss-server): собирать логи mgcpclient? (y/n, Enter=n): " ;;
                mgcpclient_default_no) echo "SoftSwitch (fss-server): mgcpclient пропущен (нет TTY; укажите --mgcpclient или --no-mgcpclient)" ;;
                mgcpclient_not_found) echo "mgcpclient: каталог логов не найден" ;;
                mgcpclient_include) echo "mgcpclient: добавлено каталогов" ;;
                mgcpclient_skip)   echo "mgcpclient: пропущен (файлы mgcpclient* и отдельные каталоги)" ;;
                resource_limits)   echo "Лимиты нагрузки системы (host-wide)" ;;
                collected)         echo "Скопирован" ;;
                skipped)           echo "Пропущено" ;;
                logs_absent_for_period) echo "за указанное время логи отсутствуют" ;;
                logs_absent_for_collection) echo "за время сбора логи отсутствуют" ;;
                logs_absent)       echo "логи отсутствуют" ;;
                absent_files_unit) echo "файлов" ;;
                more_files)        echo "ещё" ;;
                pg_logs_not_found) echo "каталог логов не найден (логирование в файл не настроено?)" ;;
                pg_logs_dir_missing) echo "каталог логов не существует:" ;;
                pg_logs_not_dir)   echo "путь логов не является каталогом:" ;;
                pg_logs_no_access) echo "нет доступа к каталогу логов:" ;;
                pg_logs_try_sudo)  echo "запустите от root или через sudo" ;;
                *)                 echo "$key" ;;
            esac
            ;;
        *)
            case "$key" in
                err_online_need_t) echo "Online without TTY requires -t/--timeout" ;;
                ask_lang_prompt)   echo "Your choice / Ваш выбор [1-2]: " ;;
                mode_log)          echo "Log mode" ;;
                workdir)           echo "Work directory" ;;
                found_svcs)        echo "Found services" ;;
                found_logdirs)     echo "Found log directories" ;;
                tail_running)      echo "Tail processes" ;;
                tcpdump_started)   echo "tcpdump started (PID" ;;
                tcpdump_fail)      echo "tcpdump failed to start (needs root?)" ;;
                tcpdump_notfound)  echo "tcpdump not found" ;;
                log_running)       echo "Log collection running. Press [Enter] to stop." ;;
                log_running_online_note) echo "Online: archive includes only NEW lines written after collection started." ;;
                log_archive_stats) echo "Log files with data in archive:" ;;
                log_online_no_new) echo "No new log lines during collection (online captures only new lines)" ;;
                log_autostop)      echo "Auto-stop in" ;;
                log_stopping)      echo "Stopping collection..." ;;
                log_files_from)    echo "files from" ;;
                log_copydone)      echo "Copy done" ;;
                log_all)           echo "Copying all logs" ;;
                archive_pigz)      echo "Archive created (pigz)" ;;
                archive_gzip)      echo "Archive created (gzip)" ;;
                archive_at)        echo "Archive" ;;
                done_msg)          echo "Done" ;;
                err_no_logdirs)    echo "No log directories found" ;;
                err_no_logfiles)   echo "No log files to monitor" ;;
                err_perm)          echo "Permission denied" ;;
                err_cmd_notfound)  echo "Command not found" ;;
                config_collected)  echo "Configs collected" ;;
                sys_copied)        echo "Copied" ;;
                wiz_title_mode)    echo "=== Mode ===" ;;
                wiz_mode_1)        echo "  1 — Health check" ;;
                wiz_mode_2)        echo "  2 — Log collection" ;;
                wiz_mode_3)        echo "  3 — Script self-test" ;;
                wiz_mode_prompt)   echo "Your choice [1-3]: " ;;
                wiz_title_selftest) echo "=== Self-test ===" ;;
                wiz_selftest_1)    echo "  1 — Simple (functions launch)" ;;
                wiz_selftest_2)    echo "  2 — Extended (variants + health + seek/chunk)" ;;
                wiz_selftest_prompt) echo "Your choice [1-2]: " ;;
                wiz_title_type)    echo "=== Collection type ===" ;;
                wiz_type_1)        echo "  1 — Online (tail -F, real-time)" ;;
                wiz_type_2)        echo "  2 — Offline (copy existing logs)" ;;
                wiz_type_prompt)   echo "Your choice [1-2]: " ;;
                wiz_timeout)       echo -n "Collection timeout (e.g. 5h, 30m, Enter = forever): " ;;
                wiz_tcpdump)       echo -n "tcpdump? (y/n): " ;;
                wiz_title_range)   echo "=== Range ===" ;;
                wiz_range_1)       echo "  1 — Last N (e.g. 5h)" ;;
                wiz_range_2)       echo "  2 — From date-time to date-time" ;;
                wiz_range_3)       echo "  3 — From date-time + N hours/minutes" ;;
                wiz_range_all)     echo "  Enter — All logs" ;;
                wiz_range_prompt)  echo "Your choice [1-3]: " ;;
                wiz_for_how_long)  echo -n "For how long? (e.g. 5h, 30m): " ;;
                wiz_from_dt)       echo -n "From (e.g. 25.06.2026 10:00): " ;;
                wiz_to_dt)         echo -n "To (e.g. 25.06.2026 12:00): " ;;
                wiz_from_dt2)      echo -n "From (e.g. 25.06.2026 10:00): " ;;
                wiz_for_offset)    echo -n "For how long? (e.g. +3h, 3h, +30m): " ;;
                wiz_title_chunk)   echo "=== Splitting large logs ===" ;;
                wiz_chunk_1)       echo "  1 — By size (e.g. 100MB) [default]" ;;
                wiz_chunk_2)       echo "  2 — By line count (e.g. 500000)" ;;
                wiz_chunk_prompt)  echo "Your choice [1-2, Enter=1]: " ;;
                wiz_chunk_size_prompt)  echo -n "Max size per part (e.g. 50M, 200M; Enter = 100M): " ;;
                wiz_chunk_lines_prompt) echo -n "Max lines per part (Enter = 500000): " ;;
                wiz_chunk_size_invalid) echo "Could not parse size, using default:" ;;
                wiz_output_dir)    echo -n "Output dir (Enter = script dir): " ;;
                wiz_show_repo)     echo -n "Show repositories? (y/n): " ;;
                wiz_title_scope)   echo "=== Collection scope ===" ;;
                wiz_scope_1)       echo "  1 — Brief (selected product/service logs only)" ;;
                wiz_scope_2)       echo "  2 — Extended (+ system, nginx, PostgreSQL, configs; online: tcpdump)" ;;
                wiz_scope_prompt)  echo "Your choice [1-2]: " ;;
                wiz_title_products) echo "=== Products ===" ;;
                wiz_products_all)  echo "  a — All present on host" ;;
                wiz_products_prompt) echo -n "Numbers (comma/space), a=all, n=cancel: " ;;
                wiz_refine_services) echo -n "Refine services? (y/n, Enter=n): " ;;
                wiz_title_services) echo "=== Services ===" ;;
                wiz_services_all)  echo "  a — All services of selected products" ;;
                wiz_services_prompt) echo -n "Numbers (comma/space), a=all, n=cancel: " ;;
                wiz_refine_log_types) echo -n "Select specific service logs? (y/n, Enter=n): " ;;
                wiz_title_log_types) echo "=== Service log types ===" ;;
                wiz_log_types_for) echo "Logs for" ;;
                wiz_log_types_all) echo "  a — all discovered types" ;;
                wiz_log_types_prompt) echo -n "Numbers (comma/space), a=all, n=cancel: " ;;
                wiz_log_types_none) echo "no log types found — all available files will be collected" ;;
                wiz_preview_log_types) echo "log types" ;;
                wiz_no_targets)    echo "No known products/services found on this host" ;;
                wiz_preview_pkgs)  echo "Selected services" ;;
                wiz_preview_dirs)  echo "Log directories to collect" ;;
                ask_mgcpclient)    echo -n "SoftSwitch (fss-server): collect mgcpclient logs? (y/n, Enter=n): " ;;
                mgcpclient_default_no) echo "SoftSwitch (fss-server): skipping mgcpclient (no TTY; pass --mgcpclient or --no-mgcpclient)" ;;
                mgcpclient_not_found) echo "mgcpclient: log directory not found" ;;
                mgcpclient_include) echo "mgcpclient: directories added" ;;
                mgcpclient_skip)   echo "mgcpclient: skipped (mgcpclient* files and extra dirs)" ;;
                resource_limits)   echo "Host system load limits" ;;
                collected)         echo "Copied" ;;
                skipped)           echo "Skipped" ;;
                logs_absent_for_period) echo "no logs for the specified time period" ;;
                logs_absent_for_collection) echo "no logs during collection" ;;
                logs_absent)       echo "no logs" ;;
                absent_files_unit) echo "files" ;;
                more_files)        echo "more" ;;
                pg_logs_not_found) echo "log directory not found (file logging not configured?)" ;;
                pg_logs_dir_missing) echo "log directory does not exist:" ;;
                pg_logs_not_dir)   echo "log path is not a directory:" ;;
                pg_logs_no_access) echo "no access to log directory:" ;;
                pg_logs_try_sudo)  echo "run as root or via sudo" ;;
                *)                 echo "$key" ;;
            esac
            ;;
    esac
}

