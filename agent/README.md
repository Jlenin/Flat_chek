# Агент flat_check → Flat Partner

Установка и настройка периодической отправки health JSON с ноды продукта на ingest Flat Partner.

```text
нода ── cron ──► flat_check --config … --push
                      │
                      ▼  POST JSON (token)
                 Partner ingest (1…N URL)
                      │
                      ▼
                 GET /health → UI
```

Скрипт агента — `../flat_check.sh` (тот же health, что у `flat_check_2.sh`).  
Версия: **3.7.0**.

---

## Состав каталога

| Файл | Назначение |
|------|------------|
| `install_flat_check.sh` | установка: бинарь, conf, cron, пробный прогон |
| `reinstall_flat_check.sh` | переустановка (обёртка над install; конфиг — по `-y`/`-n`, умолчание: сохранить) |
| `uninstall_flat_check.sh` | удаление бинаря/cron/каталога пакетов; конфиг — по `-y`/`-n`, умолчание: удалить |
| `flat_check.conf.example` | шаблон `/etc/flat/flat_check.conf` |
| `cron.example` | шаблон `/etc/cron.d/flat-check` |
| `service_names.md` | допустимые `SERVICE_NAME` |
| `backend-token.example.yaml` | пример приёма токена на backend |
| `health-payload.example.json` | пример тела запроса |
| `ingest-request.example.http` | пример HTTP |
| `cli.examples.sh` | примеры ручных запусков |
| `json_report.inc.sh` | общий блок JSON/push (вшит в оба скрипта в корне) |
| `flat_check_agent.sh` | автономный JSON-агент для мониторинга (без argv/логов, см. ниже) |
| `flat_check_agent.conf.example` | шаблон конфига для `flat_check_agent.sh` |
| `flat_check_agent.sudoers.example` | справка по необязательному ACL для non-root запуска |

---

## Установка

Из корня репозитория (**нужен sudo** для установки в `/usr/local` и `/etc`):

```bash
chmod +x agent/install_flat_check.sh

sudo ./agent/install_flat_check.sh \
  --push-url 'https://partner.example.local/api/v1/health/ingest' \
  --push-token 'SECRET' \
  --host-id ss-n1 \
  --service-name fss-backend
```

`chmod +x` нужен вручную только один раз, на самом `install_flat_check.sh`
(если скачали архивом с GitHub — «Download ZIP» не всегда сохраняет
исполняемый бит). Дальше он сам чинит бит `+x` себе, `reinstall_flat_check.sh`,
`uninstall_flat_check.sh` и `flat_check.sh`/`flat_check_2.sh` — их отдельно
делать исполняемыми не нужно. Не хочется даже этого одного `chmod` —
запустите через `bash agent/install_flat_check.sh ...`, результат тот же.

Без root — только в свой префикс:

```bash
./agent/install_flat_check.sh \
  --bin "$HOME/flat/bin/flat_check" \
  --conf-dir "$HOME/flat/etc" \
  --skip-cron \
  --push-url 'https://…/ingest' --push-token 'SECRET' \
  --host-id ss-n1 --service-name fss-backend
```

Шаги установщика:

1. `flat_check.sh` → `/usr/local/bin/flat_check`
2. каталоги `/etc/flat`, `/var/log/flat`
3. конфиг `/etc/flat/flat_check.conf` (если файла ещё нет)
4. cron `/etc/cron.d/flat-check` — каждые 5 минут `--push`
5. пробный `--json`; `--push` только если URL не из `example.*`

### Несколько URL

```bash
sudo ./agent/install_flat_check.sh \
  --push-url 'https://a.example/ingest,https://b.example/ingest' \
  --push-token 'SECRET' \
  --host-id ss-n1 \
  --service-name fss-backend
```

### Вместе со сборщиком логов

```bash
sudo ./agent/install_flat_check.sh ... --with-logs
# дополнительно: /usr/local/bin/flat_check_2
```

### Прочие флаги

| Флаг | Описание |
|------|----------|
| `--dry-run` | показать действия без изменений |
| `--bin PATH` | путь бинаря |
| `--conf-dir DIR` | каталог конфига (по умолчанию `/etc/flat`) |
| `--conf FILE` | явный путь conf |
| `--cron-spec '*/10 * * * *'` | расписание |
| `--skip-cron` | не ставить cron |
| `--force-conf` | перезаписать существующий conf |
| `--no-test` | без пробного прогона |
| `--host-ip IP` | зафиксировать IP в conf |

Если conf уже есть, параметры `--push-*` / `--host-*` / `--service-name` **не меняют** его — нужен `--force-conf` либо правка файла вручную.

---

## Переустановка / удаление

```bash
# переустановка: бинарь/cron/каталог пакетов обновляются всегда;
# конфиг — по умолчанию (без -y/-n) СОХРАНЯЕТСЯ как есть
sudo ./agent/reinstall_flat_check.sh
sudo ./agent/reinstall_flat_check.sh -y                    # сбросить конфиг на шаблон
sudo ./agent/reinstall_flat_check.sh -n --push-token NEW    # сохранить конфиг, обновить токен

# удаление: конфиг — по умолчанию (без -y/-n) УДАЛЯЕТСЯ вместе с остальным
sudo ./agent/uninstall_flat_check.sh
sudo ./agent/uninstall_flat_check.sh -n                     # оставить /etc/flat как есть
sudo ./agent/uninstall_flat_check.sh -y                     # удалить конфиг без вопроса
```

`reinstall_flat_check.sh` — тонкая обёртка над `install_flat_check.sh` (принимает те же `--bin`/`--conf-dir`/`--push-*`/…, см. его `-h`); `-y` эквивалентен `--force-conf`. `uninstall_flat_check.sh` не трогает `LOG_DIR` (логи push). Без tty и без `-y`/`-n` оба применяют своё умолчание молча, не дожидаясь ввода.

Отдельный `chmod +x` для `reinstall_flat_check.sh`/`uninstall_flat_check.sh`
не нужен — оба, как и `install_flat_check.sh`, чинят бит `+x` себе и соседям
при каждом запуске, так что достаточно один раз сделать исполняемым любой
из трёх (см. «Установка» выше).

---

## Конфиг

Минимальный рабочий набор:

```bash
PUSH_URLS="https://partner.example.local/api/v1/health/ingest"
PUSH_TOKEN="SECRET"
HOST_ID="ss-n1"
SERVICE_NAME="fss-backend"
```

| Ключ | Нужен | Описание |
|------|-------|----------|
| `PUSH_URLS` | для push | URL через запятую/пробел (`http`/`https`) |
| `PUSH_TOKEN` | обычно да | токен стенда |
| `HOST_ID` | да | id хоста в UI |
| `SERVICE_NAME` | да | имя сервиса CI/CD, см. `service_names.md` |
| `HOST_IP` | нет | иначе определяется автоматически |
| `PACKAGES` / `PRODUCT` | нет | сузить набор проверок |
| `PUSH_CONNECT_TIMEOUT` / `PUSH_MAX_TIME` / `PUSH_RETRIES` | нет | таймауты curl |
| `PUSH_INSECURE` | нет | `1` = не проверять TLS-сертификат приёмника (`curl -k`); нужно при self-signed на https, иначе push падает с `FAIL (last http=000)` |

Приоритет значений: **CLI → переменные окружения → conf → автоопределение**.

Полный шаблон: `flat_check.conf.example`.

---

## Запуск

```bash
# снимок в stdout
flat_check --config /etc/flat/flat_check.conf --json

# отправка на все PUSH_URLS (без печати JSON)
flat_check --config /etc/flat/flat_check.conf --push

# снимок + отправка
flat_check --config /etc/flat/flat_check.conf --json --push

# один пакет / явная идентичность
flat_check --pkg fss-server --json
flat_check --json --host-id ss-n1 --host-ip 10.0.1.5 --service-name fss-backend
```

Те же флаги есть в `flat_check_2.sh`. Режим `-log` с `--json`/`--push` в одном запуске не комбинируется: JSON-путь завершает процесс раньше.

Cron по умолчанию вызывает `--push` без `--json`, чтобы лог не раздувался телом снимка.

---

## Каталог пакетов

При установке `install_flat_check.sh` копирует `flat_check.packages.conf` рядом с бинарём
(`dirname(INSTALL_BIN)/flat_check.packages.conf`). Если файла нет — скрипт использует
встроенный каталог. Human-раздел зависимостей называется `=== Depends ===`; в JSON ключ
по-прежнему `infrastructure` (схема v2 не менялась).

---

## Формат JSON

Обязательные поля идентичности:

- `host_id`
- `host_ip`
- `service_name`

Далее: `timestamp`, `script_version`, `os`, `package_manager`, `products`, `infrastructure`, `summary`, `system`, `certificates`, …

Примеры: `health-payload.example.json`, `ingest-request.example.http`.

Заголовки при push:

```http
Content-Type: application/json
Authorization: Bearer <PUSH_TOKEN>
X-Flat-Host-Id: <HOST_ID>
X-Flat-Service-Name: <SERVICE_NAME>
```

Настройка приёма токена на стороне backend: `backend-token.example.yaml`.

---

## Проверка

```bash
flat_check -v
flat_check --selftest simple
flat_check --config /etc/flat/flat_check.conf --json | jq '.host_id, .service_name, .summary'
flat_check --config /etc/flat/flat_check.conf --push
tail -f /var/log/flat/flat_check_push.log
```

| Симптом | Что проверить |
|---------|----------------|
| `PUSH_URLS пуст` | conf / env |
| `curl не найден` | пакет `curl` |
| `http=401/403` | токен, `PUSH_AUTH_HEADER` |
| `http=000` | DNS, firewall, TLS; если приёмник на self-signed https — `PUSH_INSECURE=1`. Точную причину curl (connection refused / timed out / …) смотрите в `flat_check_push.log` или `--push --debug` — строка `push: curl → URL: ...` |
| `service_name: unknown` | `SERVICE_NAME` в conf или `--service-name` |

---

## Установка вручную

```bash
install -m 0755 flat_check.sh /usr/local/bin/flat_check
install -d -m 0755 /etc/flat /var/log/flat
cp agent/flat_check.conf.example /etc/flat/flat_check.conf
# заполнить PUSH_URLS, PUSH_TOKEN, HOST_ID, SERVICE_NAME
chmod 0640 /etc/flat/flat_check.conf
cp agent/cron.example /etc/cron.d/flat-check
chmod 0644 /etc/cron.d/flat-check
```

---

## Standalone-агент для мониторинга (`flat_check_agent.sh`)

Отдельный, полностью самостоятельный скрипт для прямой интеграции в
мониторинг (Zabbix external check, systemd timer + HTTP-пуш и т.п.), когда
не нужны ни `--help`, ни интерактивный мастер, ни сессионные логи — только
JSON-снимок здоровья хоста.

- **Не подключает** `json_report.inc.sh`/`flat_check.sh`/`flat_check_2.sh` —
  весь нужный код скопирован внутрь одного файла. Разворачивается как один
  файл, без установщика: скопировать и `chmod +x`.
- **Без аргументов командной строки.** Поведение — только через переменные
  окружения и/или конфиг-файл `flat_check_agent.conf` рядом со скриптом
  (переопределяется `FLAT_AGENT_CONF`). Это даёт одну строку для cron/timer.
- **Вывод:** в stdout — всегда только JSON, одной строкой (безопасно
  парсить как есть, даже если настроен push). Диагностика push (`curl`
  ошибки, `push: OK/FAIL`) — в stderr. При ручном запуске в терминале видно
  оба потока сразу, то есть видно и снимок, и что именно отправилось.
- **Код возврата:** `0` — JSON собран (и push, если был настроен, прошёл
  успешно); ненулевой — сбой сборки JSON или сбой хотя бы одного push.
  Содержимое JSON (какие пакеты не установлены и т.п.) на код возврата не
  влияет — это для дашборда, не признак поломки самого агента.
- **Права доступа:** рассчитан на обычного пользователя, не root. Почти
  все проверки (dpkg/rpm/pacman/apk, systemctl, слушающие порты, curl к
  локальным API, чтение сертификатов) прав не требуют. Единственное
  известное исключение — `configs[].status="sudoers"` (не может проверить
  файл внутри `/etc/sudoers.d`, если у каталога нет `x` для остальных):
  без доп. прав деградирует до `"missing"`, без падений. Подробности и
  необязательный узкий ACL — `flat_check_agent.sudoers.example`.

Пример cron-строки (всё через env, без конфиг-файла):

```cron
*/5 * * * * PUSH_URLS=https://partner.example/api/v1/health/ingest \
            PUSH_TOKEN=*** HOST_ID=ss-n1 SERVICE_NAME=fss-backend \
            /opt/flat/flat_check_agent.sh >/dev/null
```

Или с конфиг-файлом рядом со скриптом (командная строка короче):

```bash
cp agent/flat_check_agent.sh agent/flat_check_agent.conf.example /opt/flat/
mv /opt/flat/flat_check_agent.conf.example /opt/flat/flat_check_agent.conf
# заполнить PUSH_URLS, PUSH_TOKEN, HOST_ID, SERVICE_NAME в конфиге
chmod +x /opt/flat/flat_check_agent.sh
```

```cron
*/5 * * * * /opt/flat/flat_check_agent.sh >/dev/null
```

Пример systemd timer + service (та же логика, если в организации принят
timer, а не cron):

```ini
# /etc/systemd/system/flat-check-agent.service
[Unit]
Description=flat_check_agent health snapshot + push

[Service]
Type=oneshot
User=flat-agent
ExecStart=/opt/flat/flat_check_agent.sh
```

```ini
# /etc/systemd/system/flat-check-agent.timer
[Unit]
Description=Run flat-check-agent.service every 5 minutes

[Timer]
OnBootSec=1min
OnUnitActiveSec=5min

[Install]
WantedBy=timers.target
```

```bash
systemctl enable --now flat-check-agent.timer
```

---

## Сопровождение

- Логику JSON/push менять в `json_report.inc.sh` и синхронно в обоих скриптах корня.
- Новые пакеты health — в `PKG_*` обоих скриптов (см. корневой README).
- На ноде conf держать с правами `0640`; секреты в git не коммитить.
- `flat_check_agent.sh` — самостоятельная копия той же JSON/push-логики
  (см. заголовок файла). При правке `json_report.inc.sh`/каталога пакетов
  проверить, нужна ли та же правка и в `flat_check_agent.sh` — синхронизация
  ручная, скрипт её не подключает.
