# Примеры: агент `flat_check` → несколько продуктов (JSON v2)

Черновики под модель «активный агент»: на каждой ноде cron → **один JSON** → push на **несколько** HTTP/HTTPS endpoints (Partner и другие продукты).

> Флаги `--json` / `--push` / `--pkg` в `flat_check.sh` пока **не реализованы** — здесь целевой контракт.

## Требования (зафиксировано)

1. **Несколько серверов push** — `PUSH_URLS` (http и https).
2. Вывод сразу **JSON v2** (структура мониторинга Flat Partner / dashboard) — без текстового парсинга на каждом бэке.
3. В конфиге **бэкенда-приёмника** — токен для `flat_check` (см. `backend-token.example.yaml`).
4. URL: **HTTP или HTTPS**.
5. В JSON обязательно: **`host_id`**, **`host_ip`**, **`service_name`** (имена из CI/CD статуса).

## Схема

```text
[нода fss-backend]
  flat_check --json --push
       │  один JSON body
       ├──► https://partner…/health/ingest   (токен Partner)
       └──► http://fps-admin…/health/ingest  (токен FPS / общий)
                    │
                    ▼
              GET /health → UI продукта
```

## Файлы

| Файл | Назначение |
|------|------------|
| `health-payload.example.json` | JSON v2 (1.1.9) + host_id/host_ip/service_name |
| `flat_check.conf.example` | conf ноды: идентификация + `PUSH_URLS` |
| `backend-token.example.yaml` | строка токена в конфиге бэка-приёмника |
| `service_names.example.md` | допустимые `service_name` из CI/CD |
| `cron.example` | `/etc/cron.d/flat-check` |
| `install_flat_check.sh.example` | скелет установщика |
| `cli.examples.sh` | примеры CLI |
| `ingest-request.example.http` | POST на несколько URL |
| `flat_check.hosts.example` | опциональный SSH remote-map |
| `run_remote_check.example.sh` | опциональный bastion/SSH |

## Минимальный conf на ноде

```bash
HOST_ID="ss-n1"
HOST_IP="10.0.1.5"
SERVICE_NAME="fss-backend"   # см. service_names.example.md

PUSH_URLS="https://partner.example.local/api/v1/health/ingest http://other.example.local:8054/api/v1/health/ingest"
PUSH_TOKEN="CHANGE_ME_FLAT_CHECK_TOKEN"
```

## Верхний уровень JSON

```json
{
  "timestamp": "2026-08-03T10:45:00Z",
  "host_id": "ss-n1",
  "host_ip": "10.0.1.5",
  "service_name": "fss-backend",
  "os": "…",
  "package_manager": "dpkg",
  "products": [ … ],
  "infrastructure": [ … ],
  "repositories": [ … ],
  "apt_priorities": [ … ],
  "summary": { "installed": 7, "errors": 1, "warnings": 3 },
  "system": { … },
  "certificates": [ … ],
  "uptime_services": [ … ]
}
```

Полный пример: [`health-payload.example.json`](health-payload.example.json).

## Установка (эскиз)

```bash
sudo SERVICE_NAME=fss-backend HOST_IP=10.0.1.5 \
  PUSH_URLS="https://partner.example.local/api/v1/health/ingest http://fps.example.local:8054/api/v1/health/ingest" \
  PUSH_TOKEN="secret" \
  ./examples/install_flat_check.sh.example
```
