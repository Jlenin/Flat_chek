# Примеры: агент health → Partner (как Zabbix active)

Черновики контрактов и установки. Код `flat_check.sh` пока **не** умеет `--json`/`--push` —
это целевой вид после доработки.

## Схема

```text
[каждая нода продукта]
  cron → flat_check --json --push
           │
           ▼
     Partner ingest API
           │
           ▼
     GET /health → UI (сводка / пакеты / система / infra)
```

## Файлы

| Файл | Назначение |
|------|------------|
| `health-payload.example.json` | снимок одной ноды под поля дашборда |
| `flat_check.conf.example` | конфиг агента на ноде |
| `flat_check.hosts.example` | опциональный remote-map (bastion/SSH) |
| `cron.example` | crontab |
| `install_flat_check.sh.example` | скелет установщика |
| `cli.examples.sh` | примеры команд |

## Быстрый просмотр CLI

```bash
# локально, один пакет (будущий флаг)
./flat_check.sh --pkg fss-server --json

# нода → push на Partner
./flat_check.sh --json --push

# bastion: удаленная проверка по карте хостов (опционально)
./flat_check.sh --remote-map /etc/flat/flat_check.hosts --json
```
