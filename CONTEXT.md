# CONTEXT — handoff для другого агента

Внутренний контекст репозитория **Flat_chek** (`github.com/Jlenin/Flat_chek`).  
Обновлять при смене версии, JSON-контракта, установщика или паритета скриптов.

**Обновлено:** 2026-08-03  
**Версия:** `flat_check.sh` 3.7.1 / `flat_check_2.sh` 3.8.0

---

## Роли файлов

| Путь | Роль |
|------|------|
| `flat_check.sh` | health (+ JSON/push CLI) |
| `flat_check_2.sh` | тот же health/JSON **1к1** + сбор логов |
| `agent/` | установка push-агента на ноду (conf, cron, install, док) |
| `README.md` | пользовательская дока по check / check_2 |
| `agent/README.md` | дока по агенту и установщику |
| `CONTEXT.md` | этот handoff (в корневой README не ссылаемся) |

Каталог `examples/` удалён — всё актуальное лежит в `agent/`.

---

## Сделано по смыслу

1. Offline log path в `_2` (midnight, unsorted, daily merge, chunk modes).
2. Health-only `flat_check.sh` из `_2` без collector.
3. Модель доставки: агент на ноде → JSON push (не SSH-координатор как основной путь).
4. **3.7.0:** `--json`/`--push`/`--config`/`--pkg`/identity в обоих скриптах; комплект `agent/`.
5. Docs cleanup: корневой README только про check/check_2; агент — в `agent/`.
6. **3.8.0 (`_2`):** в мастере третий слой выбора логов — типы внутри каталога службы; `mgcpclient` спрашивается только если типы не уточняли.

---

## Паритет (обязательно)

Совпадают в обоих `.sh`:

- `PKG_*`, System/packages/infra, resource-gate
- блок JSON/push = `agent/json_report.inc.sh`

Только в `_2`: `-log`, wizard `-i`, seek/chunk, tcpdump и т.п.  
В `flat_check.sh` флаг `-i` **не используется** (чтобы не путать с мастером `_2`).  
VERBOSE health по всем пакетам — через `--dev` / `--selftest extended` (одинаково в обоих).

CLI:

- `-i`: только `_2` (мастер); в `flat_check` — unknown option
- `-p` / `--product`: health/JSON фильтр; в `_2` при `-log` — выбор логов
- `--json`/`--push` обрабатываются до `-log` и завершают процесс

Приоритет настроек агента: **CLI > env > conf > авто**.

---

## Агент (кратко)

```bash
sudo ./agent/install_flat_check.sh \
  --push-url 'https://…/ingest' \
  --push-token SECRET \
  --host-id ss-n1 \
  --service-name fss-backend
```

- JSON: `host_id`, `host_ip`, `service_name` + products/system/…
- `PUSH_URLS` — несколько http/https
- cron по умолчанию: `--push` (без `--json`, чтобы не раздувать лог)
- `SERVICE_NAME` — CI/CD имя (`fss-backend`…), см. `agent/service_names.md`

Известные правки, которые уже внесены:

- дефолты JSON-блока через `: "${VAR:=…}"` (не затирать env);
- conf не перетирает уже заданные CLI/env;
- установщик пишет conf без хрупкого `sed` по URL/токену;
- `--conf-dir` корректно задаёт путь conf.
- push: код ответа curl не дублируется в `000000`.
- install: без root можно ставить в свой префикс (`--bin/--conf-dir/--skip-cron`); system-wide — через `sudo`.

---

## Проверка

```bash
bash -n flat_check.sh flat_check_2.sh agent/install_flat_check.sh
./flat_check.sh --selftest simple
./flat_check_2.sh --selftest simple
./flat_check.sh --json --host-id t --service-name fss-backend | jq .summary
./agent/install_flat_check.sh --dry-run --host-id t --service-name fss-backend \
  --push-url https://example/ingest
```

---

## Куда смотреть

```text
README.md                 ← check / check_2
agent/README.md           ← установка и push
agent/json_report.inc.sh  ← канон JSON/push
agent/install_flat_check.sh
CONTEXT.md                ← handoff
```
