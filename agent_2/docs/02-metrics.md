# 02 — Метрики: контракт для фронта

[← к оглавлению](../README.md)

Этот документ — **контракт между flat_agent и фронтами продуктов**: какие ряды
есть, с какими метками и какими запросами строить экраны. Запросы в документе
прогнаны на прототипе: синтаксис проверен, результаты — там, где есть данные.

## Общие правила

Метрики следуют соглашениям Prometheus:

- **Базовые единицы:** секунды, байты. Проценты и Мбит/с считает запрос или
  фронт, в базе их нет.
- **Счётчики** оканчиваются на `_total` и только растут (сбрасываются при
  перезапуске источника). Скорость — через `rate(x[1m])`.
- **`*_info`-метрики** всегда равны `1`, полезная информация — в метках
  (версии, названия).
- **Время события**, а не «сколько прошло»: `*_timestamp_seconds`,
  `*_start_time_seconds`. «Сколько прошло» — `time() - x`.
- **Никаких высококардинальных меток:** PID, командные строки, тексты
  сообщений в метки не попадают.

### Метки

| Метка | Где есть | Значение |
|---|---|---|
| `host` | **на всех рядах** | имя виртуалки (`FLAT_HOST`, по умолчанию `hostname -s`) |
| `job` | на всех собранных рядах | имя задания сбора: `node`, `systemd`, `softswitch-api`, … |
| `instance` | на всех собранных рядах | адрес цели; у проб — проверяемый URL или `адрес:порт` |
| `check` | пробы и метрики приложений | `api` — HTTP health, `port` — TCP-порт, `app` — метрики бэкенда |
| `product` | всё, что относится к FLAT | продукт: `SoftSwitch`, `Contact Center`, … |
| `package` | всё, что относится к FLAT | пакет: `fss-backend`, … |
| `port` | пробы портов, `flat_port_listening` | номер порта |
| `name` | метрики `systemd_exporter` | имя юнита: `fss-backend.service` |

Фронту не нужно знать `job` и `instance`: экраны строятся по `product`,
`package`, `check`, `name`.

## Источники

### node_exporter — хост

Имена проверены на `node_exporter` 1.12.1.

| Метрика | Тип | Метки | Что это |
|---|---|---|---|
| `node_cpu_seconds_total` | counter | `cpu`, `mode` | время CPU по ядрам и режимам (`idle`, `user`, `system`, `iowait`, …) |
| `node_load1`, `node_load5`, `node_load15` | gauge | — | средняя загрузка |
| `node_memory_MemTotal_bytes` | gauge | — | вся память |
| `node_memory_MemAvailable_bytes` | gauge | — | доступная память |
| `node_memory_SwapTotal_bytes`, `node_memory_SwapFree_bytes` | gauge | — | swap |
| `node_filesystem_size_bytes`, `node_filesystem_avail_bytes` | gauge | `device`, `fstype`, `mountpoint` | размер и свободное место ФС |
| `node_filesystem_readonly` | gauge | `device`, `fstype`, `mountpoint` | ФС только для чтения (1) |
| `node_disk_read_bytes_total`, `node_disk_written_bytes_total` | counter | `device` | чтение и запись дисков |
| `node_network_receive_bytes_total`, `node_network_transmit_bytes_total` | counter | `device` | трафик интерфейсов |
| `node_boot_time_seconds` | gauge | — | время загрузки ОС |
| `node_time_seconds` | gauge | — | время на хосте (сверка часов) |
| `node_os_info` | info | `pretty_name`, `id`, `version_id`, … | ОС |
| `node_uname_info` | info | `nodename`, `release`, `machine`, … | ядро и имя машины |
| `node_textfile_scrape_error` | gauge | — | 1 — ошибка чтения файлов textfile (MVP flat-exporter) |
| `node_textfile_mtime_seconds` | gauge | `file` | время изменения файла textfile |

### systemd_exporter — юниты

Имена по исходникам `systemd_exporter` 0.7.0 (на живом systemd в прототипе не
запускался). Какие юниты собирать, задаёт регулярное выражение
`FLAT_SYSTEMD_UNITS` (флаг `--systemd.collector.unit-include`): сейчас — все
сервисы, после появления `catalog.d/` — только юниты FLAT и инфраструктуры
(см. [06 — Сборка и пакет](06-packaging.md#systemd)).

| Метрика | Тип | Метки | Что это |
|---|---|---|---|
| `systemd_unit_state` | gauge | `name`, `type`, `state` | по ряду на каждое состояние (`active`, `activating`, `deactivating`, `inactive`, `failed`); текущее равно `1`, остальные `0` |
| `systemd_unit_info` | info | `name`, `type`, `mount_type`, `service_type` | сведения о юните |
| `systemd_unit_start_time_seconds` | gauge | `name`, `type` | время последнего старта (0 — не запущен) |
| `systemd_unit_cpu_seconds_total` | counter | `name`, `type`, `mode` | время CPU юнита по cgroup |
| `systemd_unit_tasks_current` | gauge | `name` | процессов и потоков в юните сейчас |
| `systemd_service_restart_total` | counter | `name` | перезапуски; нужен флаг `--systemd.collector.enable-restart-count` и systemd ≥ 235 |

### blackbox_exporter — HTTP health и TCP-порты

Проверено на прототипе.

| Метрика | Метки | Что это |
|---|---|---|
| `probe_success` | `check`, `product`, `package`, `instance`, (`port`) | 1 — проверка прошла, 0 — нет |
| `probe_duration_seconds` | те же | длительность проверки |
| `probe_http_status_code` | те же | HTTP-код ответа (для `check="api"`) |
| `probe_ssl_earliest_cert_expiry` | те же | для HTTPS: время истечения ближайшего сертификата |

Метки `check`, `product`, `package`, `port` задаёт файл продукта в
`scrape.d/` (см. [01 — Архитектура](01-architecture.md#соглашения-для-файлов-продуктов)).

### flat-exporter — каталог FLAT (проект контракта)

То, чего нет в готовых экспортерах. **Имена и метки — проект**: фронт может
опираться на них, но финальную версию утверждаем вместе с реализацией.
На первом этапе эти ряды пишет скрипт в файл
`/var/lib/flat-agent/textfile/flat.prom`, их отдаёт `node_exporter`.

| Метрика | Метки | Значение |
|---|---|---|
| `flat_package_info` | `product`, `package`, `version` | 1 — пакет установлен (по пакетному менеджеру или unit-файлу) |
| `flat_package_depends` | `product`, `package`, `dependency` | 1 — пакет зависит от `dependency` |
| `flat_unit_file_present` | `product`, `package`, `unit` | 1 — unit-файл есть |
| `flat_unit_enabled` | `product`, `package`, `unit` | 1 — юнит в автозапуске |
| `flat_path_present` | `product`, `package`, `kind`, `path` | 1 — путь есть; `kind`: `opt`, `log`, `nginx_available`, `nginx_enabled`, `logrotate`, `sudoers` |
| `flat_port_listening` | `product`, `package`, `port`, `proto` | 1 — порт слушается (по `/proc/net`, в том числе UDP) |
| `flat_package_processes` | `product`, `package` | число живых процессов пакета |
| `flat_package_memory_rss_bytes` | `product`, `package` | память процессов пакета (RSS) |
| `flat_cert_not_after_timestamp_seconds` | `path`, `subject` | время истечения сертификата из файла |
| `flat_dependency_info` | `dependency`, `version` | 1 — инфраструктурная зависимость установлена |
| `flat_host_info` | `ip`, `pm` | 1 — сведения о хосте: основной IP и пакетный менеджер (по необходимости) |
| `flat_exporter_build_info` | `version` | версия flat-exporter |
| `flat_exporter_last_success_timestamp_seconds` | `collector` | когда проверка последний раз прошла без ошибок |
| `flat_exporter_collect_duration_seconds` | `collector` | длительность последнего прогона проверки |

Пример файла на первом этапе:

```text
# HELP flat_package_info Installed FLAT package (catalog-driven).
# TYPE flat_package_info gauge
flat_package_info{product="SoftSwitch",package="fss-backend",version="3.2.1-1"} 1
flat_package_info{product="SoftSwitch",package="fss-server",version="2.14.0-1"} 1
# HELP flat_unit_enabled systemd unit is enabled (1) or not (0).
# TYPE flat_unit_enabled gauge
flat_unit_enabled{product="SoftSwitch",package="fss-backend",unit="fss-backend.service"} 1
# HELP flat_port_listening Catalog port is listening (1) or not (0).
# TYPE flat_port_listening gauge
flat_port_listening{product="SoftSwitch",package="fss-mediasrv",port="5060",proto="udp"} 1
```

Файл пишется атомарно: во временный файл, затем `mv` поверх старого.

### Самомониторинг flat_agent

Собирается выборочно (см. [01 — Архитектура](01-architecture.md#сбор-метрик)).

| Метрика | Метки | Что это |
|---|---|---|
| `up` | `job`, `instance` | 1 — источник ответил на последнем опросе |
| `scrape_duration_seconds` | `job`, `instance` | длительность опроса |
| `vm_free_disk_space_bytes` | `path` | свободное место под базой |
| `vm_free_disk_space_limit_bytes` | `path` | порог `-storage.minFreeDiskSpaceBytes` |
| `vm_storage_is_read_only` | `path` | 1 — база перестала принимать данные (мало места) |
| `vm_data_size_bytes` | `type` | размер данных по типам |
| `vm_rows_added_to_storage_total` | — | сколько точек записано |
| `vm_app_version` | `version`, `short_version` | версия VictoriaMetrics |
| `vmalert_alerts_firing`, `vmalert_alerts_pending` | `alertname`, `group` | число алертов в состоянии |
| `vmalert_alerting_rules_errors_total`, `vmalert_recording_rules_errors_total` | правило | ошибки вычисления правил |
| `vmalert_config_last_reload_successful` | — | 1 — последняя перезагрузка правил успешна |
| `process_resident_memory_bytes`, `process_cpu_seconds_total` | `job` | память и CPU компонентов |

### Алерты и производные ряды (vmalert)

| Ряд | Что это |
|---|---|
| `ALERTS{alertname, alertstate, severity, code, …}` | 1, пока алерт в состоянии `alertstate` (`pending` или `firing`); история проблем |
| `ALERTS_FOR_STATE` | служебный ряд для восстановления состояния после перезапуска |
| `host:cpu_busy:ratio_rate1m` | загрузка CPU хоста, 0–1 |
| `host:memory_used:ratio` | занятая память, 0–1 |
| `host:filesystem_used:ratio` | заполненность ФС, 0–1 (без tmpfs и подобных) |
| `host:network_receive_bytes:rate1m`, `host:network_transmit_bytes:rate1m` | трафик интерфейсов, байт/с |
| `package:cpu_host_share:ratio_rate1m` | доля CPU **всего хоста**, которую тратит юнит, 0–1 |

Производные ряды считает vmalert по правилам из
[03 — Алерты](03-alerts.md#базовый-файл-правил). Их удобно использовать на
экранах: запросы короче и быстрее. История у них есть только с момента
установки правила; для графиков за прошлые периоды подходят и исходные запросы
ниже.

## Соответствие старому JSON

Как получить то, что раньше приходило в JSON-снимке `flat_check_agent.sh`
(см. `agent/health-payload.example.json`). Все запросы — **мгновенные**
(`/api/v1/query` с `step=1m`, см.
[04 — API](04-frontend-api.md#текущее-состояние-и-параметр-step)), если не
сказано иное.

| Поле JSON | Источник | Запрос |
|---|---|---|
| `host_id` | метка `host` | `GET /api/v1/label/host/values` |
| `host_ip` | flat-exporter (по необходимости) | `flat_host_info` → метка `ip`; обычно фронт и так знает адрес, по которому открыт |
| `service_name` | — | не нужен: продукт и пакет — метки `product` и `package` |
| `os` | node_exporter | `node_os_info` → метка `pretty_name` |
| `package_manager` | flat-exporter (по необходимости) | `flat_host_info` → метка `pm` |
| `script_version` | компоненты | `flat_exporter_build_info`, `vm_app_version` |
| `layers.*.age_seconds` | опрос | `time() - timestamp(up)`; живость источника — `up` |
| `summary.installed` | flat-exporter | `count(flat_package_info)` |
| `summary.errors`, `summary.warnings` | vmalert | `count by (severity) (ALERTS{alertstate="firing"})` или `GET /api/v1/alerts` |
| `issues[]` | vmalert | `GET /api/v1/alerts` (см. [03 — Алерты](03-alerts.md#как-фронт-получает-алерты)) |
| `products[].name` | flat-exporter | `count by (product) (flat_package_info)` |
| `packages[].name`, `version`, `status` | flat-exporter | `flat_package_info` → метки `package`, `version` |
| `packages[].depends_meta`, `depends_pm` | flat-exporter | `flat_package_depends` |
| `packages[].systemd.status` | systemd_exporter | `systemd_unit_state{type="service"} == 1` → метка `state` |
| `packages[].systemd.unit_path` | flat-exporter | `flat_unit_file_present` |
| is-enabled (раньше только в `issues`) | flat-exporter | `flat_unit_enabled` |
| `packages[].process.status` | systemd_exporter | `systemd_unit_tasks_current > 0` |
| `packages[].process.pids`, `ps_lines` | — | не экспортируются (высокая кардинальность) |
| `packages[].ports[]` | blackbox, flat-exporter | TCP: `probe_success{check="port"}`; UDP: `flat_port_listening{proto="udp"}` |
| `packages[].api` | blackbox | `probe_success{check="api"}`, `probe_http_status_code`, `probe_duration_seconds` |
| `packages[].directories[]` | flat-exporter | `flat_path_present{kind=~"opt\|log"}` |
| `packages[].configs[]` | flat-exporter | `flat_path_present{kind=~"nginx_.*\|logrotate\|sudoers"}` |
| `infrastructure[]` | flat-exporter, systemd_exporter | `flat_dependency_info`; состояние службы — `systemd_unit_state{name=~"(nginx\|postgresql.*\|mariadb)\\.service", state="active"}` |
| `repositories[]` | — | не переносится (не метрика) |
| `system.cpu.usage_percent` | node_exporter | `100 * host:cpu_busy:ratio_rate1m` |
| `system.cpu.cores` | node_exporter | `count(node_cpu_seconds_total{mode="idle"})` |
| `system.cpu_services[]` | systemd_exporter | `100 * package:cpu_host_share:ratio_rate1m` |
| `system.memory.total_mb` | node_exporter | `node_memory_MemTotal_bytes` (байты) |
| `system.memory.available_mb` | node_exporter | `node_memory_MemAvailable_bytes` |
| `system.memory.used_mb` | node_exporter | `node_memory_MemTotal_bytes - node_memory_MemAvailable_bytes` |
| `system.memory_services[]` | flat-exporter | `flat_package_memory_rss_bytes` |
| `system.disk[]` | node_exporter | `100 * host:filesystem_used:ratio` → метки `mountpoint`, `device` |
| `system.network[].mbps` | node_exporter | `host:network_receive_bytes:rate1m * 8 / 1e6` (и `transmit`) |
| `system.database` | systemd_exporter | `systemd_unit_state{name=~"(postgresql.*\|mariadb\|mysqld)\\.service", state="active"}` |
| `system.uptime_seconds` | node_exporter | `time() - node_boot_time_seconds` |
| `uptime_services[]` | systemd_exporter | `time() - (systemd_unit_start_time_seconds{type="service"} > 0)` |
| `certificates[].days_left` | flat-exporter, blackbox | файлы: `(flat_cert_not_after_timestamp_seconds - time()) / 86400`; HTTPS-эндпоинты: `(probe_ssl_earliest_cert_expiry - time()) / 86400` |

В таблице `\|` — экранированная для Markdown вертикальная черта; в запросе это
обычная `|`.

## Запросы для экранов

### Обзор хоста

Текущие значения (мгновенные запросы):

```promql
# Загрузка CPU, %
100 * host:cpu_busy:ratio_rate1m
```

```promql
# Число ядер
count(node_cpu_seconds_total{mode="idle"})
```

```promql
# Память: занято, %
100 * host:memory_used:ratio
```

```promql
# Заполненность файловых систем, % (по mountpoint)
100 * host:filesystem_used:ratio
```

```promql
# Время работы ОС, секунды
time() - node_boot_time_seconds
```

Графики (запросы по диапазону, `/api/v1/query_range`):

```promql
# CPU хоста, % — без производного ряда (есть и история до установки правил)
100 * (1 - avg without (cpu, mode) (rate(node_cpu_seconds_total{mode="idle"}[1m])))
```

```promql
# Входящий трафик по интерфейсам, Мбит/с
rate(node_network_receive_bytes_total{device!~"lo|veth.*|docker.*|br-.*"}[1m]) * 8 / 1e6
```

```promql
# Запись на диски, байт/с
rate(node_disk_written_bytes_total[1m])
```

### Продукты и пакеты

```promql
# Установленные пакеты и версии (для таблицы: метки product, package, version)
flat_package_info
```

```promql
# Состояние юнитов пакетов: ряд с value=1 несёт текущее состояние в метке state
systemd_unit_state{type="service"} == 1
```

```promql
# Health API по пакетам: 1 — ок, 0 — нет
probe_success{check="api"}
```

```promql
# Порты: TCP через blackbox
probe_success{check="port"}
```

```promql
# Сколько пакетов в каждом продукте
count by (product) (flat_package_info)
```

### Карточка пакета

Пример для `fss-backend` (юнит `fss-backend.service`):

```promql
# Доля CPU всего хоста, % — график
100 * package:cpu_host_share:ratio_rate1m{name="fss-backend.service"}
```

```promql
# То же без производного ряда
100 * sum(rate(systemd_unit_cpu_seconds_total{name="fss-backend.service"}[1m])) / count(node_cpu_seconds_total{mode="idle"})
```

```promql
# Время работы сервиса, секунды
time() - systemd_unit_start_time_seconds{name="fss-backend.service"}
```

```promql
# Перезапуски за сутки
increase(systemd_service_restart_total{name="fss-backend.service"}[1d])
```

```promql
# Время ответа health API, секунды — график
probe_duration_seconds{check="api", package="fss-backend"}
```

```promql
# История состояния юнита: 1 — active — график
systemd_unit_state{name="fss-backend.service", state="active"}
```

### Проблемы

Список текущих проблем — через API vmalert, история — по рядам `ALERTS`.
Подробно — в [03 — Алерты](03-alerts.md#как-фронт-получает-алерты).

```promql
# Счётчики для шапки: сколько проблем каждой важности
count by (severity) (ALERTS{alertstate="firing"})
```

### Здоровье самого мониторинга

```promql
# Источники, которые не отвечают
up == 0
```

```promql
# Свободно под базой, % от порога остановки записи
vm_free_disk_space_bytes / vm_free_disk_space_limit_bytes
```

```promql
# База перестала принимать данные
vm_storage_is_read_only == 1
```

```promql
# Ошибки правил за 15 минут
increase(vmalert_alerting_rules_errors_total[15m]) > 0
```

## Особенности запросов

- **Окно `rate()` — не меньше 4 интервалов опроса.** При опросе раз в 15 с —
  `[1m]`. Меньшее окно даёт пропуски и скачки.
- **Текущее состояние — с `step=1m`.** Без `step` мгновенный запрос ищет
  последнее значение за 5 минут и покажет ряды, которые уже исчезли (например,
  удалённый пакет). См. [04 — API](04-frontend-api.md#текущее-состояние-и-параметр-step).
- **Счётчики сбрасываются** при перезапуске источника; `rate()` и
  `increase()` это учитывают. Сырые значения `*_total` на экран не выводить.
- **Округление** — параметр `round_digits` запроса, а не пересчёт на фронте.
- **Проценты и единицы** — на стороне запроса (`100 *`, `* 8 / 1e6`) или фронта;
  в базе только базовые единицы.
