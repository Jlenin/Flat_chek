# flat_check_agent.sh — самостоятельный агент для мониторинга

`flat_check_agent.sh` — отдельный, полностью самостоятельный скрипт для
прямой интеграции в мониторинг (Zabbix external check, systemd timer +
HTTP-пуш и т.п.), когда не нужны ни `--help`, ни интерактивный мастер, ни
сессионные логи — только JSON-снимок здоровья хоста. Функционально похож
на `flat_check.sh` (тот же набор проверок продуктов/системы/инфраструктуры),
но живёт полностью независимо от него — отдельный файл, ничего не
подключает и не устанавливается тем же путём.

**Не путать с остальным содержимым этой папки.** `install_flat_check.sh` /
`reinstall_flat_check.sh` / `uninstall_flat_check.sh` — установщик обычного
`flat_check.sh`/`flat_check_2.sh` (health + push через cron), он **не
ставит и не трогает** `flat_check_agent.sh`. Документация установщика —
в корневом [`README.md`](../README.md), раздел «Push в Flat Partner».
У `flat_check_agent.sh` установщика нет и не нужен: один файл, скопировать
и `chmod +x`.

## Состав

| Файл | Назначение |
|------|------------|
| `flat_check_agent.sh` | сам агент — один файл, `chmod +x`, и всё |
| `flat_check_agent.conf.example` | эталонный конфиг (копировать в `flat_check_agent.conf` рядом со скриптом) |
| `flat_check_agent.sudoers.example` | справка по необязательному ACL для non-root запуска |

## Особенности

- **Не подключает** `json_report.inc.sh`/`flat_check.sh`/`flat_check_2.sh` —
  весь нужный код скопирован внутрь одного файла.
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

## Быстрый старт

```bash
cp agent/flat_check_agent.sh agent/flat_check_agent.conf.example /opt/flat/
mv /opt/flat/flat_check_agent.conf.example /opt/flat/flat_check_agent.conf
chmod +x /opt/flat/flat_check_agent.sh
# по умолчанию в конфиге PUSH_URLS указывает на 127.0.0.1 — это эталонный
# пример для локальной проверки; впишите свой реальный приёмник и токен
/opt/flat/flat_check_agent.sh | jq .
```

Пример cron-строки (всё через env, без конфиг-файла):

```cron
*/5 * * * * PUSH_URLS=https://partner.example/api/v1/health/ingest \
            PUSH_TOKEN=*** HOST_ID=ss-n1 SERVICE_NAME=fss-backend \
            /opt/flat/flat_check_agent.sh >/dev/null
```

Или с конфиг-файлом рядом со скриптом (командная строка ещё короче):

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

## Сопровождение

`flat_check_agent.sh` — самостоятельная копия JSON/push-логики из
`json_report.inc.sh` (см. заголовок файла). При правке `json_report.inc.sh`
или каталога пакетов (`flat_check.packages.conf`) проверить, нужна ли та же
правка и в `flat_check_agent.sh` — синхронизация ручная, скрипт её не
подключает.
