# Агент flat_check → Flat Partner

Папка с **конфигом, установщиком и контрактом** доставки health JSON на нодах продукта.  
Модель как у Zabbix active: на каждой ноде свой агент, cron, push на один или несколько HTTP/HTTPS endpoint.

```text
[нода продукта]
  cron → flat_check --config … --json --push
           │
           ▼  POST JSON v2 (+ token)
     Partner ingest (1..N URL)
           │
           ▼
     GET /health → UI (сводка / пакеты / система / infra)
```

Скрипты в корне репозитория:

| Файл | Роль |
|------|------|
| `../flat_check.sh` | health + JSON-агент (**ставить на ноды**) |
| `../flat_check_2.sh` | то же health/JSON **1к1** + сбор логов |

Версия агента: **3.7.0**.

---

## Состав папки

| Файл | Назначение |
|------|------------|
| `install_flat_check.sh` | установщик: бинарь → conf → cron → пробный прогон |
| `flat_check.conf.example` | шаблон `/etc/flat/flat_check.conf` |
| `cron.example` | пример `/etc/cron.d/flat-check` |
| `service_names.md` | справочник `SERVICE_NAME` (fss-backend, …) |
| `backend-token.example.yaml` | как принять токен на backend |
| `health-payload.example.json` | пример тела JSON v2 |
| `ingest-request.example.http` | пример HTTP-запроса |
| `cli.examples.sh` | примеры команд |
| `json_report.inc.sh` | исходный блок JSON/push (вшит в оба скрипта) |

---

## Быстрая установка

Из корня репозитория (нужен root):

```bash
chmod +x agent/install_flat_check.sh flat_check.sh

sudo ./agent/install_flat_check.sh \
  --push-url 'https://partner.example.local/api/v1/health/ingest' \
  --push-token 'SECRET' \
  --host-id ss-n1 \
  --service-name fss-backend
```

Что произойдёт:

1. `flat_check.sh` → `/usr/local/bin/flat_check`
2. каталоги `/etc/flat`, `/var/log/flat`
3. конфиг `/etc/flat/flat_check.conf` (из example + ваши значения)
4. cron `/etc/cron.d/flat-check` каждые 5 минут: `--json --push`
5. пробный `--json` (и `--push`, если URL не example.local)

### Несколько ingest URL

```bash
sudo ./agent/install_flat_check.sh \
  --push-url 'https://partner-a.example/ingest,https://partner-b.example/ingest' \
  --push-token 'SECRET' \
  --host-id ss-n1 \
  --service-name fss-backend
```

### Сбор логов на той же ноде

```bash
sudo ./agent/install_flat_check.sh ... --with-logs
# → ещё /usr/local/bin/flat_check_2
```

### Dry-run (без изменений)

```bash
./agent/install_flat_check.sh --dry-run \
  --push-url https://partner.example.local/api/v1/health/ingest \
  --host-id ss-n1 --service-name fss-backend
```

### Полезные флаги установщика

| Флаг | Смысл |
|------|--------|
| `--bin PATH` | куда положить бинарь |
| `--conf FILE` | путь конфига |
| `--cron-spec '*/10 * * * *'` | расписание |
| `--skip-cron` | только бинарь+conf |
| `--force-conf` | перезаписать существующий conf |
| `--no-test` | не делать пробный прогон |
| `--host-ip IP` | явный IP в conf |
| `--with-logs` | поставить `flat_check_2` |

---

## Конфиг `/etc/flat/flat_check.conf`

Минимум:

```bash
PUSH_URLS="https://partner.example.local/api/v1/health/ingest"
PUSH_TOKEN="SECRET"
HOST_ID="ss-n1"
SERVICE_NAME="fss-backend"
```

| Ключ | Обязателен | Описание |
|------|------------|----------|
| `PUSH_URLS` | для push | URL через запятую/пробел, `http://` или `https://` |
| `PUSH_TOKEN` | обычно да | токен стенда |
| `HOST_ID` | да | id хоста в UI |
| `HOST_IP` | нет | иначе авто |
| `SERVICE_NAME` | да* | CI/CD-имя (`fss-backend` …), см. `service_names.md` |
| `PACKAGES` / `PRODUCT` | нет | сузить снимок |
| `PUSH_*_TIMEOUT` / `PUSH_RETRIES` | нет | таймауты curl |

`*` без `SERVICE_NAME` в JSON будет `unknown` (или имя `--pkg`).

Переменные окружения с теми же именами тоже работают и **не затираются** конфигом при уже заданном CLI (conf читается в `main` / `run_health_json`).

---

## CLI агента

```bash
# локальный снимок
flat_check --config /etc/flat/flat_check.conf --json

# снимок + отправка на все PUSH_URLS
flat_check --config /etc/flat/flat_check.conf --json --push

# только push (JSON в cron-лог не дублируется в stdout)
flat_check --config /etc/flat/flat_check.conf --push

# один пакет
flat_check --pkg fss-server --json

# идентичность явно
flat_check --json --host-id ss-n1 --host-ip 10.0.1.5 --service-name fss-backend
```

Те же флаги есть в `flat_check_2.sh` (health/JSON 1к1). Режим `-log` не смешивается с `--json/--push`: JSON обрабатывается раньше и завершает процесс.

---

## JSON v2 (что уходит на ingest)

Обязательные поля идентичности:

- `host_id`
- `host_ip`
- `service_name`

Плюс: `timestamp`, `script_version`, `os`, `package_manager`, `products[]`, `infrastructure[]`, `summary`, `system`, `certificates`, …

Пример: [`health-payload.example.json`](health-payload.example.json).  
HTTP: [`ingest-request.example.http`](ingest-request.example.http).

Заголовки при push:

```http
Content-Type: application/json
Authorization: Bearer <PUSH_TOKEN>
X-Flat-Host-Id: <HOST_ID>
X-Flat-Service-Name: <SERVICE_NAME>
```

Backend-настройка токена: [`backend-token.example.yaml`](backend-token.example.yaml).

---

## Проверка после установки

```bash
# 1) версия
flat_check -v          # flat_check 3.7.0

# 2) selftest
flat_check --selftest simple

# 3) валидный JSON
flat_check --config /etc/flat/flat_check.conf --json | jq '.host_id, .service_name, .summary'

# 4) push вручную
flat_check --config /etc/flat/flat_check.conf --push
# ожидайте: [INFO] push: OK 2xx → https://…

# 5) лог cron
tail -f /var/log/flat/flat_check_push.log
```

Типичные проблемы:

| Симптом | Что проверить |
|---------|----------------|
| `PUSH_URLS пуст` | conf / env |
| `curl не найден` | поставить curl |
| `FAIL … http=401/403` | токен / `PUSH_AUTH_HEADER` |
| `FAIL … http=000` | DNS, firewall, TLS |
| `service_name: unknown` | `SERVICE_NAME=` или `--service-name` |

---

## Ручная установка (без скрипта)

```bash
install -m 0755 flat_check.sh /usr/local/bin/flat_check
install -d -m 0755 /etc/flat /var/log/flat
cp agent/flat_check.conf.example /etc/flat/flat_check.conf
# отредактировать PUSH_URLS, PUSH_TOKEN, HOST_ID, SERVICE_NAME
chmod 0640 /etc/flat/flat_check.conf
cp agent/cron.example /etc/cron.d/flat-check
chmod 0644 /etc/cron.d/flat-check
```

---

## Сопровождение

- Меняете JSON/push-логику → правьте `json_report.inc.sh` и **оба** скрипта одинаково (или перегенерируйте вставку из inc).
- Новые пакеты в health → `PKG_*` в обоих скриптах (см. корневой README).
- Токены не коммитить: в conf на ноде `chmod 0640`, в git только `CHANGE_ME`.
