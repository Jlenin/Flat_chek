# 04 — API для фронта

[← к оглавлению](../README.md)

Фронт продукта получает данные мониторинга через **HTTP API, совместимый с
Prometheus**. Отдаёт его VictoriaMetrics, API алертов проксируется в vmalert.
Поэтому подойдёт любая клиентская библиотека или обёртка для Prometheus API.

Все примеры ответов сняты с прототипа через nginx с авторизацией и префиксом
`/monitoring` — ровно в той схеме, что описана в
[01 — Архитектура](01-architecture.md#доступ-и-безопасность).

## Базовый адрес и авторизация

- **Адрес:** `https://<виртуалка>/monitoring/…` — тот же домен, что у фронта
  продукта.
- **Авторизация:** сессия продукта. nginx проверяет её подзапросом
  `auth_request` в бэкенд продукта: без сессии ответ **401**.
- **CORS не нужен и выключен** (`-http.disableCORS`): запросы идут с того же
  домена. Если приложение фронта живёт на другом домене, ходите через бэкенд
  продукта, а не включайте CORS.
- **Закрытые пути:** запись, импорт, удаление рядов, снапшоты, служебные
  эндпоинты — **403** на уровне nginx.
- **Метод:** запросы данных принимают и `GET`, и `POST`
  (`application/x-www-form-urlencoded`). Для длинных запросов — `POST`.

## Эндпоинты

| Метод | Путь | Назначение |
|---|---|---|
| GET, POST | `/monitoring/api/v1/query` | мгновенный запрос: значения на момент времени |
| GET, POST | `/monitoring/api/v1/query_range` | запрос по диапазону: данные для графиков |
| GET, POST | `/monitoring/api/v1/series` | какие ряды были за период |
| GET | `/monitoring/api/v1/labels` | имена меток |
| GET | `/monitoring/api/v1/label/<метка>/values` | значения метки: списки продуктов, пакетов |
| GET | `/monitoring/api/v1/export` | сырые точки (выгрузка) |
| GET | `/monitoring/api/v1/alerts` | текущие алерты (vmalert через прокси) |
| GET | `/monitoring/api/v1/rules` | правила и их состояние (vmalert через прокси) |
| GET | `/monitoring/vmui/` | встроенный UI с графиками и дашбордами |
| GET | `/monitoring/vmui/custom-dashboards` | наши дашборды в JSON |
| GET | `/monitoring/vmalert/` | UI vmalert: группы, правила, алерты |
| GET | `/monitoring/health` | живость VictoriaMetrics (`OK`) |
| GET | `/monitoring/federate` | текущие значения в формате Prometheus — для внешних систем, по токену |

## Мгновенный запрос: `/api/v1/query`

| Параметр | Обязателен | Значение |
|---|---|---|
| `query` | да | запрос PromQL/MetricsQL |
| `time` | нет | момент вычисления; по умолчанию «сейчас» |
| `step` | нет | насколько назад искать последнее значение; по умолчанию `5m`. **Для текущего состояния — `1m`** |
| `timeout` | нет | предел времени запроса, например `5s` (максимум `-search.maxQueryDuration`, по умолчанию 30 с) |
| `round_digits` | нет | округлить значения до N знаков после запятой |
| `nocache` | нет | `1` — не использовать кеш результатов |

Запрос:

```http
POST /monitoring/api/v1/query
Content-Type: application/x-www-form-urlencoded

query=probe_success{check="api"}&step=1m
```

Ответ (прототип):

```json
{
  "status": "success",
  "data": {
    "resultType": "vector",
    "result": [
      {
        "metric": {
          "__name__": "probe_success",
          "check": "api",
          "host": "proto-n1",
          "instance": "http://127.0.0.1:8428/monitoring/health",
          "job": "softswitch-api",
          "package": "fss-backend",
          "product": "SoftSwitch"
        },
        "value": [1790338401, "1"]
      }
    ]
  },
  "stats": {"seriesFetched": "1", "executionTimeMsec": 0}
}
```

- `value` — пара `[unix-время в секундах, "значение строкой"]`. Значение нужно
  привести к числу; бывают `"NaN"`, `"+Inf"`, `"-Inf"`.
- Если к ряду применена функция или арифметика, `__name__` в ответе нет.
- `stats` — расширение VictoriaMetrics, в Prometheus его нет.

### Текущее состояние и параметр `step`

Мгновенный запрос берёт **последнее значение за окно `step`**. По умолчанию
окно 5 минут, поэтому ряды, которые уже не обновляются (удалили пакет,
перезапустили сбор с другими метками), ещё до 5 минут видны в ответе.
Проверено на прототипе: после перезапуска старые ряды видны без `step` и
пропадают с `step=30s`.

Правило для фронта:

| Что показываем | `step` |
|---|---|
| текущее состояние (статусы, таблицы, числа) | `1m` |
| счётчики по рядам `ALERTS` | `1m` (ряды отстают на ~25–40 с) |
| «последнее известное значение, даже старое» | не задавать (5 минут) |

## Запрос по диапазону: `/api/v1/query_range`

| Параметр | Значение |
|---|---|
| `query` | запрос |
| `start`, `end` | границы: unix-время, RFC3339 (`2026-09-25T10:00:00Z`) или относительное (`-1h`); `end` по умолчанию — «сейчас» |
| `step` | шаг точек на графике |
| `round_digits` | округление |

Выбор `step` — чтобы на графике было 200–1000 точек:

| Период | `step` |
|---|---|
| 15 минут – 1 час | `15s` |
| 6 часов | `1m` |
| сутки | `5m` |
| неделя | `30m` |
| 30 дней | `2h` |

Меньше интервала опроса (15 с) шаг делать бессмысленно.

Ответ (прототип, три первые точки):

```json
{
  "status": "success",
  "data": {
    "resultType": "matrix",
    "result": [
      {
        "metric": {"host": "proto-n1", "instance": "127.0.0.1:9100", "job": "node"},
        "values": [[1790336737.902, "1.5"], [1790336767.902, "1.63"], [1790336797.902, "1.68"]]
      }
    ]
  },
  "stats": {"seriesFetched": "2", "executionTimeMsec": 1}
}
```

Запрос был `100 * host:cpu_busy:ratio_rate1m`, `start=-2m`, `step=30s`,
`round_digits=2`.

Если в данных пропуск меньше обычного интервала, VictoriaMetrics заполняет его
последним значением; большие пропуски остаются пропусками в `values`.

## Списки для фильтров

```http
GET /monitoring/api/v1/label/package/values?start=-1h
```

```json
{"status": "success", "data": ["fss-backend", "fss-mediasrv", "fss-server"]}
```

- VictoriaMetrics по умолчанию ищет значения **за последние сутки**, а не за
  всё время, как Prometheus. Передавайте `start`/`end` явно.
- `/api/v1/series` и `/api/v1/label/…/values` возвращают всё, что было **за
  период**, включая исчезнувшие ряды. Для списка «что есть сейчас» — мгновенный
  запрос с `step=1m`, например `flat_package_info`.

## Алерты

- Текущие: `GET /monitoring/api/v1/alerts`.
- Правила: `GET /monitoring/api/v1/rules`.
- История: `query_range` по `ALERTS`.

Форматы, поля и примеры — в
[03 — Алерты](03-alerts.md#как-фронт-получает-алерты).

## Встроенные графики: VMUI

VMUI — готовый UI VictoriaMetrics, доступный по адресу `/monitoring/vmui/`.
Проверено в браузере через nginx с авторизацией: запросы, графики, вкладки
Dashboards и Alerting работают.

Способы использовать во фронте продукта:

1. **Ссылка «Мониторинг»** на `/monitoring/vmui/#/dashboards` — открывает
   наши дашборды.
2. **Встраивание в `iframe`** того же домена: cookie сессии передаётся,
   заголовок `X-Frame-Options` VictoriaMetrics по умолчанию не ставит.
3. **Ссылка на график с готовым запросом:**

   ```text
   /monitoring/vmui/#/?g0.expr=<запрос, URL-encoded>&g0.range_input=1h
   ```

   Проверено: открывается редактор с запросом и график за период.

Часовой пояс VMUI по умолчанию — UTC. Поменять можно флагом
`-vmui.defaultTimezone=Europe/Moscow` у VictoriaMetrics.

### Дашборды VMUI

Файлы JSON в `/etc/flat-agent/dashboards/`: базовый от пакета и по одному от
каждого продукта. Формат (по исходникам VMUI):

```json
{
  "title": "FLAT: host overview",
  "rows": [
    {
      "title": "Host",
      "panels": [
        {
          "title": "CPU busy, %",
          "description": "Загрузка всех ядер",
          "unit": "%",
          "width": 6,
          "expr": ["100 * (1 - avg(rate(node_cpu_seconds_total{mode=\"idle\"}[1m])))"],
          "alias": ["CPU"],
          "showLegend": true
        }
      ]
    }
  ]
}
```

| Поле | Обязательно | Значение |
|---|---|---|
| `title` | нет | название дашборда |
| `rows[].title` | нет | заголовок строки (строку можно свернуть) |
| `rows[].panels[].expr` | да | массив запросов панели |
| `rows[].panels[].title`, `description`, `unit` | нет | подписи |
| `rows[].panels[].alias` | нет | подписи рядов, по порядку `expr` |
| `rows[].panels[].showLegend` | нет | показывать легенду |
| `rows[].panels[].width` | нет | ширина в колонках сетки из 12 |

Дашборды перечитываются при открытии страницы, перезапуск не нужен.

Один файл с ошибкой ломает вкладку Dashboards целиком:
`/monitoring/vmui/custom-dashboards` отвечает 400 для всех дашбордов
(проверено). Поэтому продукт проверяет свой JSON до установки
(см. [06 — Сборка и пакет](06-packaging.md#файлы-продуктов)).

### Свой вид вместо VMUI

VMUI написан на React и лежит в исходниках VictoriaMetrics под Apache-2.0
(`app/vmui`). Его можно пересобрать со своим оформлением, но проще рисовать
графики во фронте продукта по `query_range`: API стандартный.

## Задержки и время

| Что | Значение |
|---|---|
| Новые точки видны в запросах | через интервал опроса (до 15 с) + `-search.latencyOffset` (10 с) |
| Алерт в API | см. [03 — Алерты](03-alerts.md#время-и-задержки) |
| Время в ответах | unix-секунды (UTC), в `query_range` — с долями секунды |
| Время в параметрах | unix-секунды или миллисекунды, RFC3339, относительное (`-1h`, `now-5m`) |

## Ошибки

| HTTP | Когда | Тело |
|---|---|---|
| 400 | ошибка в запросе | JSON `{"status":"error","errorType":"400","error":"…"}` |
| 401 | нет сессии продукта (nginx) | страница nginx |
| 403 | закрытый путь (nginx) | страница nginx |
| 429 | VictoriaMetrics перегружена очередью запросов; заголовок `Retry-After: 10` | текст ошибки |
| 503 | VictoriaMetrics в процессе остановки | текст ошибки |
| 502, 504 | VictoriaMetrics недоступна или не ответила (nginx) | страница nginx |

Реальный пример ошибки синтаксиса (HTTP 400):

```json
{"status":"error","errorType":"400","error":"error when executing query=\"rate(node_cpu_seconds_total[1m\" for (time=1790338015836, step=300000): windowAndStep: unexpected token \"\"; want \"]\"; unparsed data: \"\""}
```

## Пример клиента (TypeScript)

```ts
type Sample = { metric: Record<string, string>; value: [number, string] };

async function promInstant(query: string, step = "1m"): Promise<Sample[]> {
  const body = new URLSearchParams({ query, step });
  const resp = await fetch("/monitoring/api/v1/query", {
    method: "POST",
    body,
    credentials: "same-origin",
  });
  const json = await resp.json();
  if (!resp.ok || json.status !== "success") {
    throw new Error(json.error ?? `HTTP ${resp.status}`);
  }
  return json.data.result as Sample[];
}

// Пакеты с неработающим health API
const down = (await promInstant('probe_success{check="api"} == 0'))
  .map((s) => s.metric.package);
```

## Нагрузка

- VictoriaMetrics ограничивает число одновременных запросов
  (`-search.maxConcurrentRequests`); лишние ждут в очереди, потом 429.
- Обновлять экраны не чаще интервала опроса (15 с): чаще данные не меняются.
- Не запрашивать сырые счётчики и `export` на экранах — только агрегаты и
  `rate()`.

## Автотесты UI

Headless-браузеры в CI бывают с «кривой» локалью (например, `en-US@posix`), и
VMUI на ней падает с ошибкой `Invalid language tag`. В тестах задавайте локаль
явно, например `locale: 'ru-RU'` в Playwright.
