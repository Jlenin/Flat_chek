# Модуль: 04_extract_single.sh
# Слой: logging
# Назначение: Автономное извлечение диапазона строк из ОДНОГО файла лога службы (parce_service_log) — базовый строительный блок для offline-сбора.
# Публичные функции: parce_service_log()
# Зависит от: 01_time_filters.sh, 00_tunables.sh, lib/core (die/warn/log_debug)
# Не зависит от: 05_extract_multi.sh/06_extract_apply.sh — они вызывают эту функцию, а не наоборот
# Side effects: читает/пишет файлы во временный/выходной каталог сборки архива
#
# Источник: перенесено без изменений логики из flat_check_2.sh (строки 3898-4252).

# --- 8b. Автономное извлечение диапазона из лога службы (parce_service_log) ----
# Получив файл лога службы (или символьную ссылку на него) и диапазон времени
# [from, to], находит байтовые смещения, ограничивающие этот диапазон, через
# интерполяционный поиск — каждая проба нацеливается пропорционально тому,
# где "from"/"to" должны находиться между двумя уже известными epoch в текущих
# границах поиска (так же, как человек предположил бы «прошлое воскресенье
# примерно на 87% файла», прочитав дату только первой строки, а затем
# скорректировал бы прицел по величине промаха), а не всегда делит оставшееся
# окно пополам, как обычная бисекция. Предполагает, что лог хронологически
# отсортирован (append-only) — на этом же предположении опирается весь подход,
# включая существующую bisect-based filter_log_file_by_range() в другом месте этого файла.

# Разрешает путь к логу (следуя одному переходу по символьной ссылке) в
# реальный, читаемый, несжатый файл. Печатает разрешённый путь.
# ПРИМЕЧАНИЕ: stdout этой функции — её возвращаемое значение (вызывающий код
# всегда использует её как real_path=$(_psl_resolve_log_path ...)) — каждый
# вызов warn() ниже явно перенаправлен в stderr, иначе сам текст диагностики
# был бы захвачен в $(...) вместо показа пользователю (та же ошибка смешения
# print/возвращаемого значения, что и в других местах; поймана здесь по той же
# причине, что и на шаге выбора режима в мастере).
_psl_resolve_log_path() {
    local path="$1" real="$1"

    [[ -n "$path" ]] || { warn "parce_service_log: no log path given" >&2; return 1; }
    if [[ -L "$path" ]]; then
        real=$(readlink -f "$path" 2>/dev/null)
        [[ -n "$real" ]] || { warn "parce_service_log: broken symlink: $path" >&2; return 1; }
    fi
    [[ -f "$real" ]] || { warn "parce_service_log: not a regular file: $path" >&2; return 1; }
    [[ -r "$real" ]] || { warn "parce_service_log: not readable: $real" >&2; return 1; }
    case "$real" in
        *.gz|*.bz2|*.xz|*.zip)
            warn "parce_service_log: compressed logs are not byte-seekable: $real" >&2
            return 1
            ;;
    esac
    echo "$real"
}

# Принимает либо уже числовой epoch, либо всё, что понимает `date -d`.
# Та же оговорка про stdout-как-возвращаемое-значение, что и у _psl_resolve_log_path() выше.
# Пустая строка — ошибка: GNU `date -d ""` молча даёт 00:00:00 сегодняшнего дня,
# из‑за чего верхняя граница «за последние Nd» обрывала лог ровно на полуночи.
_psl_parse_timestamp() {
    local raw="$1" ep
    if [[ -z "${raw//[[:space:]]/}" ]]; then
        warn "parce_service_log: cannot parse timestamp '$raw'" >&2
        return 1
    fi
    if [[ "$raw" =~ ^[0-9]+$ ]]; then
        echo "$raw"
        return 0
    fi
    ep=$(time_to_epoch "$raw")
    [[ "$ep" =~ ^[0-9]+$ ]] || { warn "parce_service_log: cannot parse timestamp '$raw'" >&2; return 1; }
    echo "$ep"
}

# Интерполяционный поиск наименьшего байтового смещения, чья строка имеет
# epoch >= target ($size, если такой строки нет). Автоматически переходит на
# обычную бисекцию, когда две известные граничные epoch равны (нечего
# интерполировать). Те же примитивы пробы/парсинга, что и у обычной бисекции
# _binsearch_offset_ge() выше, отличается только выбор "mid".
#
#
# Чистый интерполяционный поиск подвержен известному патологическому
# случаю: логи редко пишутся с равномерной скоростью (всплески сменяются
# затишьями), и когда *глобальная* плотность на [lo,hi] сильно отличается от
# *локальной* плотности возле target, прямое пропорциональное предположение
# почти не сужает окно на каждом шаге — поиск может деградировать почти до
# линейного сканирования. _MIN_PROGRESS_FRAC ниже ограничивает каждое
# предположение так, чтобы оно сдвигалось хотя бы на эту долю текущего окна,
# что ограничивает число итераций логарифмом (та же форма, что у обычной
# бисекции, просто с большим основанием) независимо от того, насколько
# перекошены timestamp'ы, при этом всё ещё используя интерполированное
# предположение — и его обычно намного более быструю сходимость — там, где
# данные ведут себя достаточно хорошо, чтобы предположение само попало в этот диапазон.
_PSL_MIN_PROGRESS_FRAC=10   # гарантируем >=1/10 окна за одну итерацию

_psl_find_offset_for_epoch() {
    local file="$1" size="$2" target="$3"
    local window="${SEEK_PROBE_BYTES:-131072}"
    local lo=0 hi="$size" lo_ep hi_ep mid mid_ep line span min_gap

    line=$(_probe_line_at_offset "$file" "$lo") || line=""
    lo_ep=$(_epoch_of_line "$line")
    [[ "$lo_ep" =~ ^[0-9]+$ ]] || lo_ep=0
    if [[ "$lo_ep" -ge "$target" ]]; then
        echo 0
        return 0
    fi

    line=$(_probe_line_at_offset "$file" "$((size > window ? size - window : 0))") || line=""
    hi_ep=$(_epoch_of_line "$line")
    [[ "$hi_ep" =~ ^[0-9]+$ ]] || hi_ep="$lo_ep"
    if [[ "$hi_ep" -lt "$target" ]]; then
        echo "$size"
        return 0
    fi

    while [[ $((hi - lo)) -gt "$window" ]]; do
        if [[ "$hi_ep" -le "$lo_ep" ]]; then
            # Вырожденное окно (одинаковые epoch) — интерполировать нельзя.
            mid=$(( (lo + hi) / 2 ))
        else
            # Сделано в awk (double precision), а не в целых числах bash: на файле в
            # несколько сотен ГБ (target-lo_ep)*(hi-lo) может переполнить 64-битное целое
            # bash до того, как деление вернёт его в норму.
            mid=$(awk -v lo="$lo" -v hi="$hi" -v lo_ep="$lo_ep" -v hi_ep="$hi_ep" -v target="$target" \
                'BEGIN { frac = (target - lo_ep) / (hi_ep - lo_ep); m = lo + frac * (hi - lo); printf "%d", m }')
            [[ "$mid" =~ ^[0-9]+$ ]] || mid=$(( (lo + hi) / 2 ))

            # Ограничиваем в полосу гарантированного прогресса около середины —
            # именно это не даёт перекошенной плотности застопорить поиск.
            span=$((hi - lo))
            min_gap=$((span / _PSL_MIN_PROGRESS_FRAC))
            [[ "$min_gap" -lt 1 ]] && min_gap=1
            [[ $((mid - lo)) -lt "$min_gap" ]] && mid=$((lo + min_gap))
            [[ $((hi - mid)) -lt "$min_gap" ]] && mid=$((hi - min_gap))
        fi

        line=$(_probe_line_at_offset "$file" "$mid") || { lo=$((mid + 1)); continue; }
        mid_ep=$(_epoch_of_line "$line")
        if [[ ! "$mid_ep" =~ ^[0-9]+$ ]] || [[ "$mid_ep" -lt 0 ]]; then
            lo=$((mid + 4096))
            [[ "$lo" -ge "$hi" ]] && break
            continue
        fi

        if [[ "$mid_ep" -lt "$target" ]]; then
            lo="$mid"; lo_ep="$mid_ep"
        else
            hi="$mid"; hi_ep="$mid_ep"
        fi
    done
    echo "$lo"
}

# Разрешает [from_epoch, to_epoch] в выровненный по строкам байтовый диапазон
# [start_off, end_off). Печатает "start_off end_off"; возвращает 1, если ничего не подошло.
#
# _psl_find_offset_for_epoch() лишь сужает до одного проб-"окна"
# (SEEK_PROBE_BYTES) от истинной границы — так же, как и обычная бисекция
# _binsearch_offset_ge() — ни одна из них никогда не подтверждает точную
# строку. Поэтому, как и filter_log_file_by_range() делает вокруг своих
# вызовов _binsearch_offset_ge(), отступаем на SEEK_BACKOFF_BYTES с обеих
# сторон перед выравниванием: более широкое байтовое окно гарантированно
# полностью содержит истинную границу, а содержательный фильтр по epoch,
# применяемый на шаге копирования (не в этой функции), отбрасывает все
# лишние строки, которые этот запас захватывает с любой стороны.
# $5 = опциональный backoff в байтах (default SEEK_BACKOFF_BYTES; soft → SEEK_SOFT_SORT_*).
_psl_locate_range() {
    local file="$1" size="$2" from_epoch="$3" to_epoch="$4"
    local backoff="${5:-${SEEK_BACKOFF_BYTES:-1048576}}"
    local start_off end_off

    start_off=$(_psl_find_offset_for_epoch "$file" "$size" "$from_epoch")
    [[ "$start_off" -gt "$backoff" ]] && start_off=$((start_off - backoff)) || start_off=0
    start_off=$(_align_to_line_start "$file" "$start_off" "$size")

    end_off=$(_psl_find_offset_for_epoch "$file" "$size" "$((to_epoch + 1))")
    end_off=$((end_off + backoff))
    [[ "$end_off" -gt "$size" ]] && end_off="$size"
    end_off=$(_align_to_line_start "$file" "$end_off" "$size")

    if [[ "$end_off" -le "$start_off" ]]; then
        warn "parce_service_log: no lines fall inside the requested time range" >&2
        return 1
    fi
    echo "$start_off $end_off"
}

# Создаёт свежую, прозрачно названную директорию в /tmp для чанк-файлов
# этого извлечения: /tmp/parce_<basename>_<from>-<to>.<random>/
_psl_make_output_dir() {
    local file="$1" from_epoch="$2" to_epoch="$3"
    local base prefix

    base=$(basename -- "$file")
    base="${base//[^A-Za-z0-9._-]/_}"
    prefix="/tmp/parce_${base}_${from_epoch}-${to_epoch}"
    mktemp -d "${prefix}.XXXXXX" 2>/dev/null
}

# Разбивает [start_off, end_off) на выровненные по строкам куски размером
# MAX_LOG_CHUNK_SIZE. Печатает по одному смещению на строку: N+1 границ образуют N чанков.
_psl_plan_chunk_bounds() {
    local file="$1" start_off="$2" end_off="$3" size="$4"
    local chunk_sz="${MAX_LOG_CHUNK_SIZE:-104857600}" range i off prev

    range=$((end_off - start_off))
    [[ "$chunk_sz" -gt 0 ]] || chunk_sz="$range"
    echo "$start_off"
    prev="$start_off"
    i=1
    while [[ $((start_off + i * chunk_sz)) -lt "$end_off" ]]; do
        off=$(_align_to_line_start "$file" $((start_off + i * chunk_sz)) "$size")
        if [[ "$off" -gt "$prev" && "$off" -lt "$end_off" ]]; then
            echo "$off"
            prev="$off"
        fi
        i=$((i + 1))
    done
    echo "$end_off"
}

# Копирует каждый кусок [off, next) из _psl_plan_chunk_bounds (аргументы
# 6..N) в свой raw_NNNNN.log внутри raw_dir, оставляя только строки внутри
# [from_epoch, to_epoch] — защита от того, что интерполяционный поиск
# приземлился на несколько строк раньше/позже точной границы. Это ВНУТРЕННЯЯ
# параллельная нарезка на воркеры (гранулярность — MAX_LOG_CHUNK_SIZE), а не
# итоговые part_*.log в архиве — вызывающий код (parce_service_log())
# склеивает эти raw_*.log обратно в один файл и режет его заново на
# итоговые части через _psl_split_final_output() (LOG_CHUNK_MODE и т.п.).
# $5=sorted: 1 разрешает ранний выход из awk по каждому куску, как только
# встретилась строка позже to_epoch (безопасно только если файл
# действительно хронологически отсортирован); 0 — сканировать кусок целиком
# (когда _logs_appear_sorted() уже сказал "нет", а границы [off,next) —
# это просто весь файл, а не результат интерполяционного поиска).
# Отбрасывает куски, оказавшиеся пустыми. Печатает число непустых кусков.
_psl_copy_chunks() {
    local file="$1" raw_dir="$2" from_epoch="$3" to_epoch="$4" sorted="$5"
    local -a bounds=("${@:6}")
    local n=$((${#bounds[@]} - 1))
    local max_jobs i off next len part idx=0 count=0

    max_jobs=$(_collector_inner_max_jobs)
    [[ "$max_jobs" -lt 1 ]] && max_jobs=1
    _SEEK_JOB_PIDS=()

    for (( i=0; i<n; i++ )); do
        off="${bounds[$i]}"
        next="${bounds[$((i + 1))]}"
        len=$((next - off))
        [[ "$len" -le 0 ]] && continue
        idx=$((idx + 1))
        part=$(printf '%s/raw_%05d.log' "$raw_dir" "$idx")
        if ! _seek_wait_slot "$max_jobs"; then
            _seek_kill_jobs
            break
        fi
        (
            renice -n 10 $$ >/dev/null 2>&1 || true
            ionice -c 2 -n 7 -p $$ >/dev/null 2>&1 || true
            _extract_chunk_worker "$file" "$off" "$len" "$from_epoch" "$to_epoch" "$sorted" "$part"
        ) &
        _SEEK_JOB_PIDS+=($!)
    done
    _seek_wait_all_jobs

    for part in "$raw_dir"/raw_*.log; do
        [[ -e "$part" ]] || continue
        if [[ -s "$part" ]]; then
            count=$((count + 1))
        else
            rm -f -- "$part" 2>/dev/null
        fi
    done
    echo "$count"
}

# Извлекает часть лог-файла службы, чьи строки попадают в
# [ts_from, ts_to], в один или несколько чанк-файлов под /tmp.
#   $1 = путь к лог-файлу (или символьной ссылке на него)
#   $2 = начало диапазона — секунды epoch, либо всё, что понимает `date -d`
#   $3 = конец диапазона   — секунды epoch, либо всё, что понимает `date -d`
# При успехе: устанавливает PSL_OUTPUT_PATH (директория в /tmp с
# part_00001.log, part_00002.log, ...) и PSL_OUTPUT_CHUNKS (их количество),
# печатает "<PSL_OUTPUT_PATH> <PSL_OUTPUT_CHUNKS>", возвращает 0.
# При неудаче: выводит warn с причиной, возвращает 1, оставляет обе глобальные переменные неустановленными.
parce_service_log() {
    local log_path="$1" ts_from_raw="$2" ts_to_raw="$3"
    local real_path from_epoch to_epoch size range_str start_off end_off sorted=1
    local sort_mode backoff out_dir raw_dir combined raw_count chunk_count
    local -a bounds=()

    unset PSL_OUTPUT_PATH PSL_OUTPUT_CHUNKS

    real_path=$(_psl_resolve_log_path "$log_path") || return 1
    from_epoch=$(_psl_parse_timestamp "$ts_from_raw") || return 1
    to_epoch=$(_psl_parse_timestamp "$ts_to_raw") || return 1
    if [[ "$from_epoch" -gt "$to_epoch" ]]; then
        warn "parce_service_log: start timestamp is after end timestamp"
        return 1
    fi

    size=$(_file_size_bytes "$real_path")
    if [[ "$size" -le 0 ]]; then
        warn "parce_service_log: $real_path is empty or unreadable"
        return 1
    fi
    # Некоторые логгеры (например fcs-swau) пишут в строке только время без
    # даты — дата только в имени файла; без этого такие строки были бы
    # неотличимы от "нет метки времени вообще" везде ниже по конвейеру
    # (line_epoch() в awk читает эту переменную через -v ref_midnight=...).
    _LOG_REF_MIDNIGHT_EPOCH=$(_infer_file_midnight_epoch "$real_path")

    sort_mode=$(_logs_sort_mode "$real_path" "$size")
    case "$sort_mode" in
        sorted)
            range_str=$(_psl_locate_range "$real_path" "$size" "$from_epoch" "$to_epoch") || return 1
            read -r start_off end_off <<< "$range_str"
            ;;
        soft)
            # first≤last, середина плавает — seek с широким окном, без early-stop.
            sorted=0
            backoff="${SEEK_SOFT_SORT_BACKOFF_BYTES:-33554432}"
            log_debug "parce_service_log: soft-sorted seek ($real_path), backoff=${backoff}"
            range_str=$(_psl_locate_range "$real_path" "$size" "$from_epoch" "$to_epoch" "$backoff") || return 1
            read -r start_off end_off <<< "$range_str"
            ;;
        *)
            sorted=0
            warn "parce_service_log: $real_path does not look chronologically sorted — scanning the whole file instead of seeking"
            start_off=0
            end_off="$size"
            ;;
    esac

    out_dir=$(_psl_make_output_dir "$real_path" "$from_epoch" "$to_epoch")
    [[ -n "$out_dir" && -d "$out_dir" ]] || { warn "parce_service_log: cannot create output dir under /tmp"; return 1; }
    raw_dir="$out_dir/.raw"
    mkdir -p "$raw_dir" 2>/dev/null || { warn "parce_service_log: cannot create scratch dir under /tmp"; rm -rf -- "$out_dir" 2>/dev/null; return 1; }

    mapfile -t bounds < <(_psl_plan_chunk_bounds "$real_path" "$start_off" "$end_off" "$size")
    raw_count=$(_psl_copy_chunks "$real_path" "$raw_dir" "$from_epoch" "$to_epoch" "$sorted" "${bounds[@]}")

    if [[ ! "$raw_count" =~ ^[0-9]+$ ]] || [[ "$raw_count" -eq 0 ]]; then
        warn "parce_service_log: no lines matched inside the requested range"
        rm -rf -- "$out_dir" 2>/dev/null
        return 1
    fi

    # Склеиваем внутренние параллельные куски обратно в один файл (порядок
    # сохраняется благодаря нулям в raw_%05d) и режем его заново на итоговые
    # part_*.log согласно LOG_CHUNK_MODE — так же, как это делает
    # _psl_finalize_groups() для директорий/служб целиком.
    combined="$out_dir/.combined.log"
    cat "$raw_dir"/raw_*.log > "$combined" 2>/dev/null
    rm -rf -- "$raw_dir" 2>/dev/null

    chunk_count=$(_psl_split_final_output "$combined" "$out_dir" "part_")
    rm -f -- "$combined" 2>/dev/null

    if [[ ! "$chunk_count" =~ ^[0-9]+$ ]] || [[ "$chunk_count" -eq 0 ]]; then
        warn "parce_service_log: no lines matched inside the requested range"
        rm -rf -- "$out_dir" 2>/dev/null
        return 1
    fi

    PSL_OUTPUT_PATH="$out_dir"
    PSL_OUTPUT_CHUNKS="$chunk_count"
    echo "$PSL_OUTPUT_PATH $PSL_OUTPUT_CHUNKS"
}

