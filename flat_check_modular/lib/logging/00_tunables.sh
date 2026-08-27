# Модуль: 00_tunables.sh
# Слой: logging
# Назначение: Настраиваемые константы сборщика логов — лимиты ресурсов хоста,
#   пороги seek/bisect для больших plain-логов, пороги zgrep/archive-фильтров,
#   состояние прогресса offline-extract, пути к конфигам служб. Это тот самый
#   "блок TUNABLES", который README называет местом для правки перед запуском —
#   в модульной версии он вынесен в отдельный файл вместо начала монолита.
# Публичные функции: (нет функций — только константы/состояние)
# Зависит от: ничего (грузится в числе первых файлов lib/logging)
# Не зависит от: LOG_CHUNK_MODE/LOG_CHUNK_SIZE_BYTES/LOG_CHUNK_LINES и
#   _CPU_PREV_IDLE/_CPU_PREV_TOTAL сюда НЕ включены — они уже объявлены в
#   lib/core/00_globals.sh и к моменту подключения lib/logging могут быть уже
#   изменены parse_args() (--chunk-mode/--chunk-size/--chunk-lines); повторное
#   объявление здесь затёрло бы выбор пользователя обратно на дефолт.
# Side effects: нет
#
# Источник: перенесено без изменений логики из flat_check_2.sh (строки 147-194,
#   204-225 — секция 0, за вычетом LOG_CHUNK_*/_CPU_PREV_* по причине выше).

# --- ресурсы хоста (не доля скрипта) -----------------------------------------
# Offline параллельное копирование: 0 = авто (nproc * RESOURCE_CPU_LIMIT/100)
COLLECTOR_JOBS=0
# Общесистемный лимит CPU/MEM: придерживать лишние воркеры, когда ВСЯ
# система достигла этих лимитов (/proc). Минимум 1 воркер всегда разрешён.
RESOURCE_CPU_LIMIT=80
RESOURCE_MEM_LIMIT=80
# Макс. секунд ожидания запаса ресурсов перед ещё одним воркером (≥1 уже работает)
RESOURCE_WAIT_MAX=120
# Как часто фоновый монитор ресурсов пишет снимок CPU/MEM в лог сессии
RESOURCE_LOG_INTERVAL_SEC=30

# --- seek / параллельное извлечение plain ------------------------------------
# Минимальный размер для бисекции + параллельного извлечения чанков
SEEK_MIN_BYTES=$((1 * 1024 * 1024))
# Монолиты масштаба SoftSwitch: увеличенное окно параллелизма
SEEK_HUGE_BYTES=$((1024 * 1024 * 1024))
# Размер чанка параллельного сканирования внутри байтового диапазона [from,to]
SEEK_CHUNK_BYTES=$((64 * 1024 * 1024))
# Проба-чанк для выборки timestamp по смещению
SEEK_PROBE_BYTES=131072
# Отступ перед начальным смещением (строгий sorted)
SEEK_BACKOFF_BYTES=$((1024 * 1024))
# Отступ для soft-sorted (середина «плавает», но first≤last) — шире, без early-stop
SEEK_SOFT_SORT_BACKOFF_BYTES=$((32 * 1024 * 1024))
# Внутренняя гранулярность параллельного извлечения ОДНОГО файла в
# parce_service_log() (не итоговый part_*.log — см. LOG_CHUNK_*).
MAX_LOG_CHUNK_SIZE=$((100 * 1024 * 1024))

# --- offline archive filter / stream extract ---------------------------------
# Грубый day-отсев: ±1 календарный день (NYE / TZ)
LOG_RANGE_DAY_MARGIN_SEC=$((24 * 3600))
# Макс. число дней для zgrep-паттернов по календарным датам
LOG_ZGREP_MAX_DAYS=32
# Макс. число часов для hour-level zgrep-паттернов
LOG_ZGREP_MAX_HOURS=48
# При длине диапазона ≤ этого — hour-level zgrep (−m 1); miss → skip файла
LOG_ZGREP_HOUR_MAX_SEC=$((24 * 3600))
# Короткое окно: не читать stem.N.gz, если живой stem покрывает [from,to]
LOG_PLAIN_COVERS_ROTATED_MAX_SEC=$((24 * 3600))
# После zgrep-miss не гонять 12-point full-decompress (dated → skip;
# undated без инструмента → один extract). 0 = старое поведение (12-point).
LOG_ARCHIVE_SKIP_PROBE_ON_ZGREP_MISS=1
# Stream-extract архива: early-stop после to (+ grace), как у sorted plain.
# Soft-стемы (sipdump/…) всегда без early-stop — см. _log_archive_stream_sorted().
LOG_ARCHIVE_STREAM_SORTED=1
# Допуск (сек) после to перед early-stop — мелкий reorder потоков SoftSwitch
LOG_ARCHIVE_EARLY_STOP_GRACE_SEC=300

# Прогресс offline-extract (файлы состояния между parallel dir-jobs)
_COLLECT_PROGRESS_DIR=""
_COLLECT_PROGRESS_TOTAL=0

# Epoch полуночи дня файла, который сейчас разбирает line_epoch() (awk, см.
# _AWK_LINE_EPOCH) — нужен только логам без даты в самой строке (только
# HH:MM:SS, дата — в имени файла). Выставляется _infer_file_midnight_epoch()
# в начале обработки каждого файла (parce_service_log(),
# filter_log_file_by_range()); "" — не относится к текущему файлу /
# определить не удалось.
_LOG_REF_MIDNIGHT_EPOCH=""

# Пути к конфигам для извлечения логов
CONFIG_PATHS=(
    "/opt/flat/switchserver/settings.ini"
    "/opt/flat/fss-server/settings.ini"
    "/etc/flat/srclient/settings.ini"
    "/opt/flat/fss-srclient/settings.ini"
    "/etc/mediasrv/config.xml"
    "/opt/flat/fss-mediasrv/config.xml"
    "/opt/flat/flat-file/config.yml"
)
