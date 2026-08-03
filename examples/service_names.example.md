# `service_name` — имена из CI/CD статуса (Техдеп / Flat)

Поле верхнего уровня JSON: `"service_name": "…"`.  
Это **роль ноды / основной сервис**, а не обязательно единственный пакет на машине.  
Имена пакетов внутри `products[].packages[].name` — те же стандартизированные имена из CI/CD.

Источник: `CI_CD статус-v96-20260803_104550.docx` (пары frontend↔backend, ALL_LOCAL_PORT).

## Типичные значения для `SERVICE_NAME=` в conf

| Продукт / роль | `service_name` (пример) |
|----------------|-------------------------|
| SoftSwitch backend | `fss-backend` |
| SoftSwitch core | `fss-server` |
| SoftSwitch frontend | `fss-frontend` |
| SoftSwitch media | `fss-mediasrv` |
| SoftSwitch CSTA | `fss-csta` |
| Flat Partner backend | `fps-backend` |
| Flat Partner frontend | `fps-frontend` |
| Flat Partner server | `fps-server` |
| SBC backend | `sbc-backend` |
| SBC frontend | `sbc-frontend` |
| C2C backend | `c2c-backend` |
| LC backend | `lc-backend` |
| Gateway backend | `fg-backend` |
| IVR backend | `ivr-backend` |
| Recording backend | `frec-backend` |
| Tarifficator | `ftr-backend` |

## Пары frontend ↔ backend (CI/CD)

```text
sbc-frontend  ↔  sbc-backend
fss-frontend  ↔  fss-backend
lc-frontend   ↔  lc-backend
c2c-frontend  ↔  c2c-backend
ivr-frontend  ↔  ivr-backend
fg-frontend   ↔  fg-backend
fps-frontend  ↔  fps-backend
```

## Порты backend (ALL_LOCAL_PORT, фрагмент)

| Пакет | Порт |
|-------|------|
| `fss-backend` | 8051 |
| `fps-backend` | 8054 |
| `sbc-backend` | 8052 |
| `lc-backend` | 8041 |
| `c2c-backend` | 8030 |
| `fss-csta` | 8082 |
| `fps-server` | 8081, 8099 |

На одной ноде может быть несколько пакетов (`fss-server` + `fss-backend`);  
`service_name` всё равно один — «главная» роль ноды для UI/инвентаря.
