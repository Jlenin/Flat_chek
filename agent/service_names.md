# SERVICE_NAME — имена сервисов CI/CD

Поле `service_name` в JSON-снимке и флаг `--service-name` / `SERVICE_NAME=` в конфиге —
это **имя сервиса из CI/CD / пакета**, а не hostname.

Используется Partner UI и ingest для привязки ноды к продукту/бэкенду.

## Backend (типичные значения)

| SERVICE_NAME | Продукт / назначение |
|--------------|----------------------|
| `fss-backend` | SoftSwitch backend |
| `fps-backend` | Partner Server / FPS admin backend |
| `sbc-backend` | SBC |
| `fg-backend` | Gateway |
| `c2c-backend` | Click to Call |
| `lc-backend` | LC / личный кабинет |
| `ivr-backend` | IVR |
| `ftr-backend` | Tarifficator |
| `fbr-backend` | BSS / billing related |
| `fpw-backend` | Partner web related |
| `frec-backend` | Recording |
| `asr-backend` | ASR |
| `fc-backend` | FCS related |
| `license-backend` | License |
| `fpl-backend` | Partner license / related |
| `fvcs-backend` | Video conference |

## Frontend (если агент стоит на UI-ноде)

| SERVICE_NAME | Пара к backend |
|--------------|----------------|
| `fss-frontend` | `fss-backend` |
| `fps-frontend` | `fps-backend` |
| `sbc-frontend` | `sbc-backend` |
| `fg-frontend` | `fg-backend` |
| `c2c-frontend` | `c2c-backend` |
| `lc-frontend` | `lc-backend` |
| `ivr-frontend` | `ivr-backend` |

## Как задать

```bash
# в конфиге
SERVICE_NAME="fss-backend"

# или CLI
./flat_check.sh --service-name fss-backend --json

# или установщик
sudo ./agent/install_flat_check.sh --service-name fss-backend ...
```

Если не задано: подставится `SINGLE_PKG` (при `--pkg`) или `unknown`.
