# flat_check_agent.sh — самостоятельный агент для мониторинга

`flat_check_agent.sh` — отдельный продукт, не привязанный к
`flat_check.sh`/`flat_check_2.sh` (те устанавливаются отдельно, через
deb/rpm-пакет — см. корневой [`README.md`](../README.md)). Один файл без
внешних зависимостей: скопировать, `chmod +x`, запустить как systemd-сервис.

Без аргументов командной строки. Долгоживущий процесс: три слоя обновляют
кеш каждый со своей периодичностью, а курьер раз в несколько секунд
склеивает кеш в полный JSON и отправляет его на бэк. Бэку ничего не нужно
собирать или хранить: каждый push — полный снимок хоста.

## Состав

| Файл | Назначение |
|------|------------|
| `flat_check_agent.sh` | сам агент — один файл, `chmod +x`, и всё |
| `flat_check_agent.conf.example` | эталонный конфиг (копировать в `flat_check_agent.conf` рядом со скриптом) |
| `flat_check_agent.sudoers.example` | справка по правам для non-root запуска |
| `flat-check-set-push-urls.sh` | вызывается из postinst deb/rpm-пакета `flat-check` — заполняет `PUSH_URLS`/`SERVICE_NAME` в конфиге по реально установленным `*-backend` пакетам и их портам |
| `flat-check.service.example` | пример systemd-юнита (`Type=simple`) |
| `flat-check.logrotate.example` | ротация `LOG_FILE` (см. «Логирование») |
| `health-payload.example.json` | пример полного тела, которое агент шлёт в push (голый объект хоста, без конверта) |
| `ingest-request.example.http` | пример HTTP-запроса push целиком (заголовки + тело) |
| `backend-token.example.yaml` | пример настройки приёма токена на стороне backend (ingest) |
| `service_names.md` | что такое `SERVICE_NAME` и какие значения приняты |

## Слои и курьер

| Кто | Интервал (по умолч.) | Что делает |
|-----|----------------------|------------|
| `full` | `FULL_INTERVAL=3600` | Полное обнаружение, пишет **весь** кеш: какие пакеты каталога установлены и их версии (одним запросом к пакетному менеджеру), зависимости, поиск процессов (`pgrep`), unit-файлы и `is-enabled`, каталоги `/opt/flat`/`/var/log/flat`, конфиги, infrastructure (установлена ли, версия), диски, БД, сертификаты, uptime сервисов. Заодно — начальные значения живых частей (is-active, порты, API, CPU/RAM), чтобы кеш был полным сразу. |
| `services` | `SERVICES_INTERVAL=60` | Живые статусы по списку пакетов из кеша, каталог не сканирует: **один** `systemctl show` на все юниты (is-active + MainPID), **один** `ss -lntu` на все порты, `curl` к API. PID'ы: найденные full'ом (если ещё живы) + свежий MainPID — перезапуск сервиса подхватывается без ожидания full. |
| `metrics` | `METRICS_INTERVAL=5` | CPU/RAM хоста и по сервисам, сеть по каждому интерфейсу — чтение `/proc`, разница с прошлым тиком, **ни одного внешнего процесса**. |
| курьер | с каждым тиком `metrics` | Склеивает кеш в полный JSON, пишет `cache/last_sent.json` и отправляет его на `PUSH_URLS`. |

`full` и `services` работают в фоне и не задерживают `metrics`/курьера.
Если кеша нет или он повреждён (первый запуск, файл удалён или недописан),
в лог пишется одно предупреждение, запускается `full`, а `services`,
`metrics` и курьер ждут, пока кеш появится. После перезапуска демона уже
лежащий кеш отправляется сразу (общий `timestamp` — текущий, `updated_at`
частей — старые, по ним виден возраст данных), `full` запускается, когда
подойдёт его срок.

## Кеш

Каталог `cache/` рядом со скриптом (всегда там). У каждого файла ровно один
писатель — блокировки не нужны:

| Файл | Кто пишет |
|------|-----------|
| `full.cache` | только `full` |
| `services.cache` | только `services` |
| `metrics.cache` | только `metrics` |
| `last_sent.json` | только курьер — ровно то, что ушло последним push'ем (для разбора «что отправилось перед падением / почему на дашборде неверные данные») |

`full` и `services` пишут во временный файл и переименовывают его поверх
старого — читатель никогда не видит файл недописанным. Файлы слоёв — строки
`ключ<TAB>JSON-фрагмент`; первая строка `updated_at`, последняя `end` (без
неё файл считается повреждённым). Курьер собирает итоговый JSON склейкой
строк, без разбора JSON.

При склейке для каждой части берётся слой, чей `updated_at` новее.
`updated_at` у `full` — момент **старта** его прогона, поэтому свежие данные
`services`/`metrics`, записанные, пока `full` работал, не откатываются.

## Что уходит на бэк

Форма — как у прежнего полного снимка (`products`, `infrastructure`,
`system`, `certificates`, `uptime_services`, `issues`, `summary`, …) плюс
блок `layers` — возраст каждой части:

```json
"layers": {
  "full":     {"updated_at": "…", "age_seconds": 3533, "interval_seconds": 3600, "source": "full",     "sections": ["…"]},
  "services": {"updated_at": "…", "age_seconds": 59,   "interval_seconds": 60,   "source": "services", "sections": ["…"]},
  "metrics":  {"updated_at": "…", "age_seconds": 2,    "interval_seconds": 5,    "source": "metrics",  "sections": ["…"]}
}
```

- `timestamp` — момент отправки (каждый push — новый JSON).
- `source` — чьи данные реально попали в эти разделы: например
  `"services": {"source": "full"}` значит, что свежее данных `full`
  у services ещё ничего нет.
- `age_seconds` больше пары `interval_seconds` — слой не обновляется
  (завис/падает), дашборд может это подсветить.
- CPU: `system.cpu.usage_percent` — загрузка всего хоста (все ядра, 0–100),
  `system.cpu.cores` — число ядер. `system.cpu_services[].usage_percent` —
  доля **от всего хоста** (не от одного ядра, как `%CPU` в `top`), два знака
  после запятой: сумма по сервисам сопоставима с общим CPU, как у памяти.
  Сравнить с `top`: `%CPU` процесса ÷ `cores`.
- `issues[]` — находки `full` (unit-файл, `is-enabled`, каталоги, nginx)
  плюс находки `services` (`is-active`, порты, API); `summary.errors`/
  `summary.warnings` — по обоим спискам.

## Особенности

- **Без аргументов командной строки.** Поведение — только через переменные
  окружения и/или `flat_check_agent.conf` рядом со скриптом
  (переопределяется `FLAT_AGENT_CONF`).
- **stdout:** отправляемый JSON печатается только при ручном запуске в
  терминале или при `PRINT_JSON=1` — под systemd иначе это десятки МБ в
  journal в час. Что ушло — всегда в `cache/last_sent.json`.
- **push:** без повторов и с коротким таймаутом (`PUSH_MAX_TIME=4`) —
  следующая отправка и так через `METRICS_INTERVAL` секунд, а зависший
  приёмник не должен задерживать тики.
- **Несколько бэков:** `flat-check-set-push-urls.sh` кладёт в `PUSH_URLS`
  все `*-backend` хоста, но приём настроен не на каждом. URL, ответивший
  404/405 («не настроен») или 401/403 («токен»), опрашивается раз в
  `PUSH_UNCONFIGURED_RETRY` секунд (по умолчанию 300) вместо каждого тика;
  как только ответит 2xx — возвращается к обычной отправке сам. 5xx и
  отсутствие соединения считаются временным сбоем — пробуется каждый тик.
- **Останов:** `SIGTERM`/`SIGINT` — после текущей паузы (не дольше
  `METRICS_INTERVAL` секунд), с ожиданием фоновых `full`/`services`.
- **Права доступа:** обычный пользователь, не root. Нужна запись в `cache/`
  рядом со скриптом (и в каталог `LOG_FILE`). Единственное известное
  ограничение проверок — `configs[].status="sudoers"` (подробности —
  `flat_check_agent.sudoers.example`).

## Логирование

Формат тот же, что у `flat_check.sh`/`flat_check_2.sh` (timestamp + уровень
+ сообщение): `LOG_FILE`, по умолчанию
`/var/log/flat/flat-check/flat_check_agent.log` (соседний с
`/opt/flat/flat-check`). Каталог создаётся сам; нет прав — работает без
файла, только stderr. `LOG_FILE=""` в конфиге — отключить файл.

В лог пишутся только события, а не каждый тик: старт/готовность `full` (с
длительностью), ожидание и появление кеша, ошибки записи кеша, смена
состояния push (`push: OK`, `push: FAIL`, `приём не настроен`, `токен не
принят`, `push: снова OK … (было: …, неудачных попыток: N)`). Каждая попытка push — только при `DEBUG_MODE=1`.

Что смотреть, чтобы понять «всё ок / не ок» — два разных уровня:

1. **Жив ли сам агент:** `systemctl status flat-check`, `grep -E
   '\[FAIL\]|\[WARN\]'` по `LOG_FILE`, `layers.*.age_seconds` в
   `cache/last_sent.json`.
2. **Здоров ли хост, который агент проверяет:** `summary` и `issues[]` в
   отправляемом JSON.

Ротация: `cp agent/flat-check.logrotate.example /etc/logrotate.d/flat-check`
(без `copytruncate`: каждая строка лога открывает файл по пути заново).

## Быстрый старт

```bash
cp agent/flat_check_agent.sh agent/flat_check_agent.conf.example /opt/flat/flat-check/
mv /opt/flat/flat-check/flat_check_agent.conf.example /opt/flat/flat-check/flat_check_agent.conf
chmod +x /opt/flat/flat-check/flat_check_agent.sh
chown -R flat-service:flat-group /opt/flat/flat-check     # запись в cache/
# впишите реальный PUSH_URLS и токен в flat_check_agent.conf

cp agent/flat-check.service.example /etc/systemd/system/flat-check.service
systemctl daemon-reload
systemctl enable --now flat-check.service
tail -f /var/log/flat/flat-check/flat_check_agent.log
```

Вручную, на переднем плане (для проверки конфига перед деплоем — `Ctrl+C`
для останова; в терминале JSON печатается на каждой отправке):

```bash
/opt/flat/flat-check/flat_check_agent.sh
jq . /opt/flat/flat-check/cache/last_sent.json
```

## Сопровождение

`flat_check_agent.sh` — полностью самостоятельный файл: ничего не
подключает и ни от чего в остальном репозитории не зависит. Меняете логику
проверок или каталог продуктов здесь — правьте прямо в этом файле.
