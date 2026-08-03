# flat_check / flat_check_2

Проверка состояния продуктов FLAT/FCS на Linux-хосте (dpkg/rpm + systemd).

| Скрипт | Назначение | Версия |
|--------|------------|--------|
| `flat_check.sh` | health check | 3.7.0 |
| `flat_check_2.sh` | тот же health check + сбор логов | 3.7.0 |

Оба скрипта только читают состояние системы и пакетов. Конфиги служб не меняют.  
Для полного сбора логов в `_2` обычно нужен root или sudo.

Периодическая отправка health JSON в Flat Partner (conf, cron, установщик) — в каталоге [`agent/`](agent/).

---

## Какой скрипт использовать

```bash
# только мониторинг состояния
./flat_check.sh
./flat_check.sh -i          # подробно по всем пакетам
./flat_check.sh -r          # + репозитории

# мониторинг + сбор логов
./flat_check_2.sh
./flat_check_2.sh -log -off -t 4d
```

Замечания по CLI:

- в `flat_check.sh` флаг `-i` = `--info` (подробный health);
- в `flat_check_2.sh` флаг `-i` = интерактивный мастер;
- health у обоих совпадает (общие `PKG_*`, System, пакеты, infrastructure, resource-gate).

---

## Быстрый старт

```bash
chmod +x flat_check.sh flat_check_2.sh

./flat_check.sh -h
./flat_check_2.sh -h

./flat_check.sh
./flat_check.sh -v    # flat_check 3.7.0
```

---

## Health check

```bash
./flat_check.sh
./flat_check.sh -r
./flat_check_2.sh     # тот же путь проверки
```

Порядок вывода:

```text
[INFO]  OS: ...
[INFO]  Package manager: ...

=== System ===
=== SoftSwitch ===
=fss-server=
...
=== Infrastructure ===
=== Summary ===
```

| Блок System | Содержание |
|-------------|------------|
| `cpu` / `cpu top` | общая загрузка и % по службам FLAT |
| `memory` / `memory top` | RAM и % по службам |
| `disk` | разделы |
| `database` / `cluster_db` | PostgreSQL/MariaDB, роль, репликация |
| `network` | rx/tx МБ/с по интерфейсам |
| `cert` | срок сертификатов; &lt;30 дней → `[WARN]` |
| `uptime` | система и systemd-службы |

Метки: `[OK]` норма, `[WARN]` обратить внимание, `[FAIL]` проблема, `[INFO]` справка.

### Основные флаги health

| Флаг | Описание |
|------|----------|
| `-i` / `--info` | только `flat_check.sh`: все пакеты, включая не установленные |
| `-r` / `--repo` | показать репозитории |
| `-j` / `--jobs N` | лимит параллельных воркеров |
| `--pkg NAME` | один пакет |
| `--product NAME` | один продукт |
| `--selftest simple\|extended` | самотест |
| `--dev` | = `--selftest extended` |
| `-v` / `--version` | версия |

Дополнительно оба скрипта понимают `--json` / `--push` / `--config` для выгрузки снимка (см. [`agent/`](agent/)).

---

## Сбор логов (`flat_check_2.sh`)

| Режим | Когда | Что снимает |
|-------|-------|-------------|
| `-log -on` | проблема «сейчас» | новые строки после старта (`tail -F`), tcpdump при `--scope extended` |
| `-log -off` | разбор прошлого интервала | строки по timestamp внутри файла |

```bash
./flat_check_2.sh -log --list-targets
./flat_check_2.sh -log -off -t 2h --scope brief -p SoftSwitch --no-mgcpclient
./flat_check_2.sh -log -off -f -1d --scope extended -s fcs-swui
./flat_check_2.sh -log -on -t 30m --scope brief -p "Contact Center"
```

| Флаг | Смысл |
|------|--------|
| `--scope brief` | только логи выбранных служб (по умолчанию) |
| `--scope extended` | + system / nginx / postgresql / configs (+ tcpdump online) |
| `-p` / `--product` | продукт (в режиме `-log`) |
| `-s` / `--service` | пакет/служба |
| `--mgcpclient` / `--no-mgcpclient` | SoftSwitch: включать ли `mgcpclient*` |
| `-j N` | число offline-воркеров |
| `--chunk-mode size\|lines` | нарезка крупных логов |
| `--chunk-size` / `--chunk-lines` | лимит части |
| `-o` / `--output DIR` | каталог архива |

Без `-p`/`-s` собираются пакеты, присутствующие на хосте. Каталоги вне allowlist пропускаются (`[INFO] skip unknown`).

Нагрузка хоста: новые воркеры не стартуют, если CPU или RAM системы уже ≥ 80%; минимум один воркер всегда разрешён.

### Offline: фильтр по времени

Диапазон режет **строки** по метке времени в файле, не по mtime.

```bash
./flat_check_2.sh -log -off -t 15m
./flat_check_2.sh -log -off -f -2h -e -1h
./flat_check_2.sh -log -off -f '14.07.2026 10:00' -e '14.07.2026 14:00'
./flat_check_2.sh -log -off -t 1d --chunk-mode size --chunk-size 50M
```

| Размер plain-файла | Стратегия |
|--------------------|-----------|
| &lt; 1MB | один поток `awk` |
| ≥ 1MB, упорядочен | bisect границ + параллельный scan окна |
| ≥ 1GB | то же, чанки крупнее |
| ≥ 1MB, не упорядочен | параллельный scan всего файла |
| `.gz` | `zcat \| awk` |

Архив: `YYYY.MM.DD_HH-MM_<hostname>.tar.gz`.

### Сигналы (сбор логов)

| Действие | Поведение |
|----------|-----------|
| Enter (online) | останов → архив |
| `-t` / TERM | graceful → архив |
| Ctrl+C (INT) | abort, без архива |

Рабочие каталоги удаляются только по шаблону `YYYY.MM.DD_HH-MM_*` внутри каталога вывода.

---

## Лог сессии

| Скрипт | Файл | Куда |
|--------|------|------|
| `flat_check.sh` | `flat_check.log` | рядом со скриптом, перезаписывается |
| `flat_check_2.sh` | `flat_check_2.log` | рядом со скриптом; при `-log` — в архив |

На экран это не влияет: `[OK]`/`[WARN]`/`[FAIL]`/`[INFO]` дублируются с timestamp; подробности поиска логов — только в файл.

---

## Зависимости

Обязательно: `bash`, coreutils, `awk` (gawk), `grep`.

Health: `systemctl`, `dpkg`/`rpm`, `ss`/`netstat`, `curl`, `openssl`, при необходимости `psql` / `top` / `free` / `df`.

Сбор логов (`_2`): `tail`, `gzip` или `pigz`; опционально `tcpdump`, `zcat`.

---

## Cron (текстовый health)

```bash
0 6 * * * /opt/flat/scripts/flat_check.sh >> /var/log/flat/health_check.log 2>&1
```

Для JSON-отправки в Partner см. [`agent/`](agent/).

---

## Добавить пакет

Правки вносятся в **оба** скрипта одинаково:

```bash
PKG_PRODUCT["my-pkg"]="Product Name"
PKG_LEGACY["my-pkg"]="old-name"          # или ""
PKG_PORTS["my-pkg"]="8080"
PKG_API["my-pkg"]="/api/health"
PKG_DEPS["my-pkg"]="nginx,postgresql"
```

---

## Структура кода

| Блок | `flat_check.sh` | `flat_check_2.sh` |
|------|-----------------|-------------------|
| 0–5 | флаги, `PKG_*`, System, пакеты, infra | то же |
| 6–10 | — | поиск и сбор логов |
| 9 | resource-gate опроса пакетов | то же + воркеры сбора |
| 11 | help / argv / main / selftest | мастер + log CLI + main |
