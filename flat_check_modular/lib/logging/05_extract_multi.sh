# Модуль: 05_extract_multi.sh
# Слой: logging
# Назначение: Извлечение диапазона из ВСЕХ файлов ротации лога службы (parce_service_logs) — соответствие служба → известные директории логов, применение parce_service_log к каждому файлу.
# Публичные функции: parce_service_logs()
# Зависит от: 04_extract_single.sh, 02_log_discovery.sh, 00_tunables.sh
# Не зависит от: 06_extract_apply.sh — вызывается им для применения к найденным директориям
# Side effects: читает/пишет файлы во временный/выходной каталог сборки архива
#
# Источник: перенесено без изменений логики из flat_check_2.sh (строки 4253-4655).

# --- 8c. Извлечение диапазона из логов службы целиком (parce_service_logs) ----
# Оборачивает parce_service_log() всем необходимым, чтобы дойти от просто
# *имени службы* до готового набора чанк-файлов: находит, где служба
# хранит свои логи, находит, какие из её файлов могут содержать данные в [from,to],
# пропускает архивную копию, если существует живая обычная копия того же файла,
# запускает parce_service_log() на каждом из уцелевших файлов (сначала распаковывая
# файлы, существующие только в архиве, во временную копию), затем объединяет и
# перенарезает по *типу* лога (access.log/access.log.1/access.2026-07-22.log.gz
# объединяются вместе; error.log — никогда), так что итоговый вывод — небольшое
# число опрятных файлов размером MAX_LOG_CHUNK_SIZE, а не один крошечный файл на
# каждый оригинал ротации. Все промежуточные файлы/директории удаляются перед
# возвратом — возвращённая директория содержит только финальный результат.

# --- Этап 1: явное соответствие служба -> известная(ые) директория(и) логов ---
# Нужно только для служб, у которых имя директории логов не совпадает с
# именем службы (логи mysqld лежат в /var/log/mysql, а не в /var/log/
# mysqld) — всё, где имя директории == имени службы, уже покрывается
# этапами 2/3 ниже и не требует записи здесь.
declare -A _PSL_SVC_LOG_DIRS=(
    [mysqld]="/var/log/mysql /var/lib/mysql"
    [mysql]="/var/log/mysql /var/lib/mysql"
    [mariadb]="/var/log/mysql /var/lib/mysql"
    [httpd]="/var/log/httpd"
    [redis-server]="/var/log/redis"
    [rabbitmq-server]="/var/log/rabbitmq"
)
# Этап 2: дополнительные родительские директории для поиска одноимённой подпапки
# (помимо стандартного /var/log, который проверяется отдельно на этапе 3). Включает
# /var/log/flat, поэтому внутренние продукты FLAT (любое имя из PKG_PRODUCT)
# находятся здесь автоматически по той же конвенции, которую уже использует
# find_log_dirs_for_pkg(), без необходимости добавлять запись на каждый продукт выше.
_PSL_SVC_SEARCH_ROOTS=(/var/log/flat /opt /opt/flat /var/opt /usr/local/var/log)

# Находит директорию(и) логов для имени службы. Печатает каждую
# отдельную директорию на своей строке (без дублей); возвращает 1 без
# вывода, если ничего не найдено. Например, ssh/sshd на большинстве систем
# закономерно не имеют выделенной директории (они пишут в syslog/auth.log) и
# корректно попадут именно в этот случай.
_psl_find_service_log_dirs() {
    local service="$1"
    local -a found=()
    local d root cfg_dir

    # Этап 1: явное соответствие, плюс пути из конфигов, которые некоторые
    # продукты FLAT уже регистрируют через get_log_path_from_config().
    for d in ${_PSL_SVC_LOG_DIRS[$service]:-}; do
        [[ -d "$d" ]] && found+=("$d")
    done
    cfg_dir=$(get_log_path_from_config "$service" 2>/dev/null)
    if [[ -n "$cfg_dir" ]]; then
        cfg_dir=$(eval echo "$cfg_dir" 2>/dev/null)
        [[ -d "$cfg_dir" ]] && found+=("$cfg_dir")
    fi

    # Этап 2: одноимённая подпапка внутри списка родительских корней.
    for root in "${_PSL_SVC_SEARCH_ROOTS[@]}"; do
        d="$root/$service"
        [[ -d "$d" ]] && found+=("$d")
    done

    # Этап 3: стандартная конвенция, проверяется явно, чтобы никогда не
    # пропускаться, даже если список корней этапа 2 выше в будущем сократят.
    d="/var/log/$service"
    [[ -d "$d" ]] && found+=("$d")

    [[ ${#found[@]} -eq 0 ]] && return 1
    printf '%s\n' "${found[@]}" | sort -u
}

# Печатает "start_epoch end_epoch" для файла: время создания (или время
# изменения inode, если файловая система/ядро не предоставляют настоящее
# время создания) как начало, mtime как конец — самая широкая разумная оценка
# промежутка, в течение которого файл мог получать строки лога.
_psl_file_time_span() {
    local file="$1" birth mtime ctime start

    birth=$(stat -c '%W' "$file" 2>/dev/null)
    ctime=$(stat -c '%Z' "$file" 2>/dev/null)
    mtime=$(stat -c '%Y' "$file" 2>/dev/null)

    if [[ "$birth" =~ ^[0-9]+$ ]] && [[ "$birth" -gt 0 ]]; then
        start="$birth"
    elif [[ "$ctime" =~ ^[0-9]+$ ]]; then
        start="$ctime"
    else
        start="$mtime"
    fi
    [[ "$mtime" =~ ^[0-9]+$ ]] || mtime="$start"
    # ctime (время изменения метаданных) может оказаться *позже* mtime для
    # ротированного файла — например, logrotate переименовывает его заметно
    # позже последней записанной строки, что двигает ctime, но не mtime —
    # ограничиваем, чтобы промежуток никогда не был перевёрнутым (иначе проверка
    # пересечения в _psl_scan_candidate_files() была бы ненадёжной).
    [[ "$start" -gt "$mtime" ]] && start="$mtime"
    echo "$start $mtime"
}

# Сканирует список директорий (не рекурсивно: это уже собственные
# директории логов службы, а не дерево для обхода) на обычные файлы, чей
# промежуток [birth/ctime, mtime] пересекается с [from_epoch, to_epoch]. Печатает
# по одному подходящему пути на строку.
_psl_scan_candidate_files() {
    local from_epoch="$1" to_epoch="$2"
    shift 2
    local -a dirs=("$@")
    local dir f fstart fend

    for dir in "${dirs[@]}"; do
        [[ -d "$dir" ]] || continue
        while IFS= read -r -d '' f; do
            [[ -f "$f" ]] || continue
            read -r fstart fend < <(_psl_file_time_span "$f")
            [[ "$fstart" =~ ^[0-9]+$ && "$fend" =~ ^[0-9]+$ ]] || continue
            [[ "$fstart" -le "$to_epoch" && "$fend" -ge "$from_epoch" ]] && echo "$f"
        done < <(find -L "$dir" -maxdepth 1 -type f -print0 2>/dev/null)
    done
}

# Печатает имя без архивного расширения (убирает .gz/.bz2/.xz/.zip/.Z),
# либо имя без изменений, если оно не архивировано.
_psl_strip_archive_ext() {
    local name="$1" ext
    for ext in .gz .bz2 .xz .zip .Z; do
        if [[ "$name" == *"$ext" ]]; then
            echo "${name%"$ext"}"
            return 0
        fi
    done
    echo "$name"
}

# Снимает суффикс logrotate после .log/.txt/.csv.
# Маска на практике: name.(log|txt|csv).<что угодно> —
#   sipdump.txt.1 | sipdump.txt.-20260731 | sipdump.txt.2026-07-31 | error.log.3
# Редко без точки: name.txt-20260731 / name.log_2026-07-31.
# Без этого sipdump.txt.-20260731 схлопывался в «sipdump.txt.» и отваливался
# от фильтра типов / группы live sipdump.txt (баг на РЕД ОС и др.).
_psl_strip_logrotate_suffix() {
    local name="$1"
    if [[ "$name" =~ ^(.+)\.(log|txt|csv)\..+ ]]; then
        printf '%s.%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
        return 0
    fi
    if [[ "$name" =~ ^(.+)\.(log|txt|csv)[-_][0-9]{4} ]]; then
        printf '%s.%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
        return 0
    fi
    printf '%s\n' "$name"
}

# Читает список кандидатов (по одному пути на строку) из stdin, отбрасывает
# любой архивный файл, у которого есть живой обычный «близнец» с идентичным
# именем (та же директория, то же имя после удаления архивного расширения) —
# один и тот же экземпляр ротации существует дважды, читать нужно только
# обычный — и печатает уцелевшие пути.
_psl_dedupe_archive_copies() {
    local -A has_plain=()
    local -a files=()
    local f dir base identity key

    mapfile -t files

    for f in "${files[@]}"; do
        dir=$(dirname -- "$f")
        base=$(basename -- "$f")
        identity=$(_psl_strip_archive_ext "$base")
        [[ "$base" == "$identity" ]] && has_plain["$dir/$identity"]=1
    done

    for f in "${files[@]}"; do
        dir=$(dirname -- "$f")
        base=$(basename -- "$f")
        identity=$(_psl_strip_archive_ext "$base")
        if [[ "$base" != "$identity" ]]; then
            key="$dir/$identity"
            [[ -n "${has_plain[$key]:-}" ]] && continue
        fi
        echo "$f"
    done
}

# Вычисляет «тип лога», к которому относится ротированный/архивный файл, так что
# access.log / access.log.1 / access.log.2.gz / access.2026-07-22.log /
# sipdump.txt.-20260731 все группируются вместе, а error.log остаётся отдельно.
# Убирает (по порядку): архивное расширение, суффикс logrotate после .log|.txt|.csv,
# ведущую дату в имени (FCS daily), прочие числовые/датированные хвосты.
_psl_log_group_key() {
    local key
    key=$(_psl_strip_archive_ext "$(basename -- "$1")")
    # SoftSwitch / logrotate: name.txt.<что угодно> → name.txt (до ведущей даты FCS)
    key=$(_psl_strip_logrotate_suffix "$key")
    # Ведущая дата в самом начале имени файла — ежедневная ротация вида
    # YYYY_MM_DD_service_log.log / YYYY-MM-DD-service.log (например у
    # fcs-swau/fcs-contact и других продуктов линейки FCS): без этого
    # каждый день считался бы своим собственным "типом" лога и никогда не
    # объединялся бы с остальными днями той же службы.
    key=$(printf '%s' "$key" | sed -E \
        -e 's/^[0-9]{4}[_-][0-9]{2}[_-][0-9]{2}[_-]//' \
        -e 's/^[0-9]{2}[_.][0-9]{2}[_.][0-9]{4}[_-]//')
    key=$(printf '%s' "$key" | sed -E \
        -e 's/\.[0-9]+$//' \
        -e 's/[-.][0-9]{4}-?[0-9]{2}-?[0-9]{2}$//')
    key=$(printf '%s' "$key" | sed -E \
        -e 's/[-.][0-9]{4}-[0-9]{2}-[0-9]{2}(\.log)$/\1/' \
        -e 's/\.[0-9]+(\.log)$/\1/')
    # хвост вроде «sipdump.txt.» после неудачного peel даты
    key="${key%.}"
    printf '%s' "$key"
}

# Если $1 обычный — печатает без изменений. Если он архивирован — распаковывает
# его в $2/scratch/ и вместо этого печатает путь к этой временной копии (вызывающий
# код сам отвечает за её удаление по завершении — сама parce_service_log()
# полностью отбрасывает сжатый ввод, искать внутри сжатого потока
# невозможно). .zip распознаётся выше для целей группировки/дедупликации,
# но здесь не распаковывается (неоднозначное имя внутреннего элемента) — логируется
# и пропускается.
_psl_materialize_plain() {
    local file="$1" work_dir="$2" scratch out

    case "$file" in
        *.gz)  : ;;
        *.bz2) : ;;
        *.xz)  : ;;
        *.zip|*.Z)
            warn "parce_service_logs: skipping unsupported archive format: $file" >&2
            return 1
            ;;
        *) echo "$file"; return 0 ;;
    esac

    scratch="$work_dir/scratch"
    mkdir -p "$scratch" 2>/dev/null || return 1
    out="$scratch/$(basename -- "$file").$$.${RANDOM}.plain"
    case "$file" in
        *.gz)  gunzip -c -- "$file" ;;
        *.bz2) bunzip2 -c -- "$file" ;;
        *.xz)  unxz -c -- "$file" ;;
    esac > "$out" 2>/dev/null

    if [[ -s "$out" ]]; then
        echo "$out"
    else
        rm -f -- "$out" 2>/dev/null
        return 1
    fi
}

# Запускает parce_service_log() на одном файле-кандидате и при успехе добавляет
# его извлечённый чанк(и) в аккумулятор группы этого файла под
# $work_dir/groups/. Немедленно чистит собственную tmp-директорию вывода
# parce_service_log() и любую распакованную во временную копию, независимо от исхода.
# Возвращает 0, если этот файл дал хоть какие-то строки, иначе 1 (нормально для
# ротированного файла, в котором просто нет ничего в диапазоне — это не ошибка).
_psl_process_one_candidate() {
    local file="$1" from_epoch="$2" to_epoch="$3" work_dir="$4"
    local plain is_scratch=0 group group_file rc=1

    plain=$(_psl_materialize_plain "$file" "$work_dir") || return 1
    [[ "$plain" != "$file" ]] && is_scratch=1

    if parce_service_log "$plain" "$from_epoch" "$to_epoch" >/dev/null 2>&1; then
        group=$(_psl_log_group_key "$file")
        group_file="$work_dir/groups/${group}.log"
        mkdir -p "$work_dir/groups" 2>/dev/null
        cat "$PSL_OUTPUT_PATH"/part_*.log >> "$group_file" 2>/dev/null
        rc=0
    fi
    rm -rf -- "${PSL_OUTPUT_PATH:-}" 2>/dev/null
    [[ "$is_scratch" -eq 1 ]] && rm -f -- "$plain" 2>/dev/null
    return "$rc"
}

# Свежая, прозрачно названная директория в /tmp для финального результата
# по службе: /tmp/parces_<service>_<from>-<to>.<random>/
_psl_make_service_output_dir() {
    local service="$1" from_epoch="$2" to_epoch="$3" base prefix
    base="${service//[^A-Za-z0-9._-]/_}"
    prefix="/tmp/parces_${base}_${from_epoch}-${to_epoch}"
    mktemp -d "${prefix}.XXXXXX" 2>/dev/null
}

# Разбивает один уже готовый (отфильтрованный/объединённый) файл на
# part_*.log в out_dir — целиком по строкам, никогда их не разрывая.
# Режим — LOG_CHUNK_MODE: "size" (умолчание) — split -C LOG_CHUNK_SIZE_BYTES;
# "lines" — split -l LOG_CHUNK_LINES. Это единственное место, где
# по-настоящему определяется размер/число строк итоговых файлов в архиве —
# и parce_service_log(), и _psl_finalize_groups() вызывают именно её.
# Печатает число получившихся частей (0, если src_file пуст/отсутствует).
_psl_split_final_output() {
    local src_file="$1" out_dir="$2" prefix="${3:-part_}"
    local count

    [[ -s "$src_file" ]] || { echo 0; return 0; }
    mkdir -p "$out_dir" 2>/dev/null || { echo 0; return 1; }

    if [[ "${LOG_CHUNK_MODE:-size}" == "lines" ]]; then
        split -l "${LOG_CHUNK_LINES:-500000}" -d --numeric-suffixes=1 -a 5 \
            --additional-suffix=.log -- "$src_file" "$out_dir/${prefix}" 2>/dev/null
    else
        split -C "${LOG_CHUNK_SIZE_BYTES:-104857600}" -d --numeric-suffixes=1 -a 5 \
            --additional-suffix=.log -- "$src_file" "$out_dir/${prefix}" 2>/dev/null
    fi

    count=$(find "$out_dir" -maxdepth 1 -type f -name "${prefix}*.log" 2>/dev/null | wc -l)
    echo "${count:-0}"
}

# Перенарезает каждый файл-аккумулятор группы в $work_dir/groups/ на
# part_*.log в $final_dir (через _psl_split_final_output(), см. LOG_CHUNK_*),
# с именами "<group>.part_NN.log". Печатает общее число записанных чанк-файлов.
_psl_finalize_groups() {
    local work_dir="$1" final_dir="$2"
    local gfile gkey count total=0

    for gfile in "$work_dir"/groups/*.log; do
        [[ -s "$gfile" ]] || continue
        gkey=$(basename -- "$gfile"); gkey="${gkey%.log}"
        count=$(_psl_split_final_output "$gfile" "$final_dir" "${gkey}.part_")
        [[ "$count" =~ ^[0-9]+$ ]] && total=$((total + count))
    done

    echo "$total"
}

# Извлекает каждый лог-файл заданной службы, который попадает (хотя бы частично)
# в [ts_from, ts_to], в небольшой набор объединённых, ограниченных по размеру
# чанк-файлов под /tmp.
#   $1 = имя службы (nginx, mysqld, apache2, ssh, имя пакета внутреннего
#        продукта FLAT, ...)
#   $2 = начало диапазона — секунды epoch, либо всё, что понимает `date -d`
#   $3 = конец диапазона   — секунды epoch, либо всё, что понимает `date -d`
# При успехе: устанавливает PSLS_OUTPUT_PATH (директория в /tmp с
# <type>.part_NN.log на каждый тип лога — access/error/и т.д. никогда не смешиваются) и
# PSLS_OUTPUT_CHUNKS, печатает "<PSLS_OUTPUT_PATH> <PSLS_OUTPUT_CHUNKS>",
# возвращает 0. При неудаче: выводит warn с причиной, возвращает 1.
parce_service_logs() {
    local service="$1" ts_from_raw="$2" ts_to_raw="$3"
    local from_epoch to_epoch work_dir final_dir chunk_count processed=0
    local f
    local -a dirs=() candidates=() kept=()

    unset PSLS_OUTPUT_PATH PSLS_OUTPUT_CHUNKS

    [[ -n "$service" ]] || { warn "parce_service_logs: no service name given"; return 1; }
    from_epoch=$(_psl_parse_timestamp "$ts_from_raw") || return 1
    to_epoch=$(_psl_parse_timestamp "$ts_to_raw") || return 1
    if [[ "$from_epoch" -gt "$to_epoch" ]]; then
        warn "parce_service_logs: start timestamp is after end timestamp"
        return 1
    fi

    mapfile -t dirs < <(_psl_find_service_log_dirs "$service")
    if [[ ${#dirs[@]} -eq 0 ]]; then
        warn "parce_service_logs: no log directory found for service '$service'"
        return 1
    fi
    info "parce_service_logs: $service log dirs: ${dirs[*]}"

    mapfile -t candidates < <(_psl_scan_candidate_files "$from_epoch" "$to_epoch" "${dirs[@]}")
    if [[ ${#candidates[@]} -eq 0 ]]; then
        warn "parce_service_logs: no files for '$service' overlap the requested range"
        return 1
    fi
    mapfile -t kept < <(printf '%s\n' "${candidates[@]}" | _psl_dedupe_archive_copies)

    work_dir=$(mktemp -d "/tmp/parces_work_${service}.XXXXXX" 2>/dev/null) || {
        warn "parce_service_logs: cannot create scratch dir under /tmp"
        return 1
    }

    for f in "${kept[@]}"; do
        _psl_process_one_candidate "$f" "$from_epoch" "$to_epoch" "$work_dir" \
            && processed=$((processed + 1))
    done

    if [[ "$processed" -eq 0 ]]; then
        warn "parce_service_logs: no lines matched inside the requested range for '$service'"
        rm -rf -- "$work_dir" 2>/dev/null
        return 1
    fi

    final_dir=$(_psl_make_service_output_dir "$service" "$from_epoch" "$to_epoch")
    if [[ -z "$final_dir" || ! -d "$final_dir" ]]; then
        warn "parce_service_logs: cannot create output dir under /tmp"
        rm -rf -- "$work_dir" 2>/dev/null
        return 1
    fi

    chunk_count=$(_psl_finalize_groups "$work_dir" "$final_dir")
    rm -rf -- "$work_dir" 2>/dev/null

    if [[ ! "$chunk_count" =~ ^[0-9]+$ ]] || [[ "$chunk_count" -eq 0 ]]; then
        warn "parce_service_logs: nothing to output for '$service'"
        rm -rf -- "$final_dir" 2>/dev/null
        return 1
    fi

    PSLS_OUTPUT_PATH="$final_dir"
    PSLS_OUTPUT_CHUNKS="$chunk_count"
    echo "$PSLS_OUTPUT_PATH $PSLS_OUTPUT_CHUNKS"
}

