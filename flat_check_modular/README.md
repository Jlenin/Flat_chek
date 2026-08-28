# flat_check_modular

Модульная версия `flat_check.sh` / `flat_check_2.sh` — тот же health check +
JSON/push-агент + сборщик логов + интерактивный мастер, но код разложен по
слоям в `lib/` вместо одного файла на 3-9 тысяч строк. Один и тот же
исполняемый файл `flat_check` делает то, что раньше требовало запускать
`flat_check.sh` **или** `flat_check_2.sh` — нужный код подключается по
флагам, а не «на всякий случай».

**Оригиналы (`flat_check.sh`, `flat_check_2.sh`, `agent/`) не менялись и
продолжают работать как раньше.** Это отдельная, самостоятельная поставка —
подробности и обоснование см. в [`ARCHITECTURE.md`](ARCHITECTURE.md).

---

## Чем это отличается от `flat_check.sh`/`flat_check_2.sh`

| | `flat_check.sh` + `flat_check_2.sh` + `agent/` | `flat_check_modular/` |
|---|---|---|
| Файлов с логикой | 3 (два почти-дублирующих монолита + agent-инклюд) | 1 точка входа + 3 файла в `lib/` (core/agent/logging) |
| Паритет между health/JSON/логами | вручную, патчем в 2-3 места | один источник истины на функцию |
| Интерфейс командной строки | `-h`/`-i`/`-r`/`-v`/`--json`/`--dev`/`-log`/… | **тот же самый**, ни один флаг не менялся |
| Установка | `agent/install_flat_check.sh` (один файл) | `install.sh` (всё дерево `flat_check_modular/`) |
| Что нужно знать, чтобы поправить одну проверку | где именно в 3000-9000 строках | один из 3 файлов `lib/`, внутри — по разделам (`grep -n "РАЗДЕЛ:"`) |

Если вы уже пользуетесь `flat_check.sh`/`flat_check_2.sh` — ничего менять не
обязательно, они никуда не делись. `flat_check_modular/` — вариант для
новых установок или постепенного перехода.

---

## Быстрый старт

```bash
cd flat_check_modular
chmod +x install.sh          # один раз; дальше install/reinstall/uninstall чинят +x сами
./install.sh --service-name fss-backend --host-id ss-n1 \
    --push-url https://partner.example.local/api/v1/health/ingest \
    --push-token SECRET
```

`install.sh` копирует всё дерево (`flat_check` + `lib/` + `conf/`) в
`/opt/flat_check` (см. `--dest`) и кладёт тонкую обёртку в
`/usr/local/bin/flat_check` (см. `--bin`), чтобы `flat_check` работал из
любого каталога. Конфиг пишется в `/etc/flat/flat_check.conf`, cron — в
`/etc/cron.d/flat-check`. Полный список флагов: `./install.sh -h`.

Без установки — прямо из этой папки:

```bash
./flat_check -h
./flat_check                 # health check
./flat_check -i               # интерактивный мастер
./flat_check --selftest extended
```

---

## Переустановка / удаление

```bash
sudo ./reinstall.sh           # спросит, сбрасывать ли конфиг на шаблон (Enter = нет)
sudo ./reinstall.sh -y        # сбросить конфиг на шаблон без вопроса
sudo ./uninstall.sh           # спросит, удалять ли конфиг (Enter = да)
sudo ./uninstall.sh -n        # оставить конфиг
```

Оба — тонкие обёртки над `install.sh` / прямое удаление дерева+обёртки+cron.
Логи (`LOG_DIR`, обычно `/var/log/flat`) не удаляются никогда.

---

## Флаги (не меняются относительно `flat_check.sh`/`flat_check_2.sh`)

```bash
./flat_check                              # health check (только установленные службы)
./flat_check -r                           # + репозитории
./flat_check -i                           # интерактивный мастер (язык/режим/логи/самотест)
./flat_check --selftest simple|extended
./flat_check --dev                        # = --selftest extended
./flat_check --debug                      # дублировать DEBUG-строки сессионного лога на экран

./flat_check --config /etc/flat/flat_check.conf --json
./flat_check --config /etc/flat/flat_check.conf --json --push
./flat_check --pkg fss-server --json

./flat_check -log --list-targets
./flat_check -log -off -t 2h --scope brief -p SoftSwitch --no-mgcpclient
./flat_check -log -on -t 30m --scope brief -s fcs-swui
```

Полная и всегда актуальная справка: `./flat_check -h` (там же — обе версии,
русская и английская, как было в `flat_check_2.sh`).

---

## Каталог пакетов

`conf/flat_check.packages.conf` — точная копия каталога из корня репозитория
(`../flat_check.packages.conf`), без изменений. Формат и правила добавления
записей — как в основном `README.md` репозитория, раздел «Добавить пакет».
Зависимости (`_pkg_set` → `PKG_DEPS`) — данные, изменять существующие связи
без явной необходимости не стоит (см. `ARCHITECTURE.md`).

---

## Структура кода

Код лежит в трёх файлах — `lib/core.sh` (всегда), `lib/agent.sh`
(`--json`/`--push`), `lib/logging.sh` (`-log`). Внутри каждого — разделы по
одной функциональной группе, с заголовком (Назначение/Публичные функции/
Зависит от/Не зависит от/Side effects/Источник) перед каждым — искать по
`grep -n "РАЗДЕЛ:" lib/core.sh`. Подробная карта слоёв, порядок подключения
и таблица «что искать в каком разделе» — в [`ARCHITECTURE.md`](ARCHITECTURE.md).

## Зависимости

Те же, что у `flat_check.sh`/`flat_check_2.sh` — см. основной `README.md`
репозитория (`bash`, coreutils, `awk`, `systemctl`, `dpkg`/`rpm`, `curl`,
`openssl`; опционально `tcpdump`/`zcat`/`jq`/`python3`). Ничего нового
модульная раскладка не требует.
