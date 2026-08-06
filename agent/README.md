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
| `flat_check.conf.example` | шаблон `/etc/flat/flat_check.conf` |
| `cron.example` | шаблон `/etc/cron.d/flat-check` |
| `service_names.md` | допустимые `SERVICE_NAME` |
| `backend-token.example.yaml` | пример приёма токена на backend |
| `health-payload.example.json` | пример тела запроса |
| `ingest-request.example.http` | пример HTTP |
| `cli.examples.sh` | примеры ручных запусков |
| `json_report.inc.sh` | общий блок JSON/push (вшит в оба скрипта в корне) |

---

## Установка

Из корня репозитория (**нужен sudo** для установки в `/usr/local` и `/etc`):

```bash
chmod +x agent/install_flat_check.sh flat_check.sh

sudo ./agent/install_flat_check.sh \
  --push-url 'https://partner.example.local/api/v1/health/ingest' \
  --push-token 'SECRET' \
  --host-id ss-n1 \
  --service-name fss-backend
```

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
встроенный каталог. Схема JSON v2 не менялась: `products`, `infrastructure`, `summary`, …

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
| `http=000` | DNS, firewall, TLS |
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

## Сопровождение

- Логику JSON/push менять в `json_report.inc.sh` и синхронно в обоих скриптах корня.
- Новые пакеты health — в `PKG_*` обоих скриптов (см. корневой README).
- На ноде conf держать с правами `0640`; секреты в git не коммитить.
