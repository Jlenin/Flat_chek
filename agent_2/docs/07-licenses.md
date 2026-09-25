# 07 — Лицензии

[← к оглавлению](../README.md)

> Это инженерная сводка для юристов и сборки, а не юридическое заключение.
> Выводы для конкретных договоров, реестра российского ПО и сертификации
> делает юрист.

## Коротко

- Все программы в пакете — под **Apache-2.0**: VictoriaMetrics
  (`victoria-metrics`, `vmalert`, `vmagent`), `node_exporter`,
  `systemd_exporter`, `blackbox_exporter`.
- Их зависимости на Go — 82 модуля под MIT, Apache-2.0, BSD-2-Clause,
  BSD-3-Clause и два модуля под MPL-2.0. Встроенный в VictoriaMetrics
  веб-интерфейс VMUI содержит 38 JS-библиотек под MIT, BSD-3-Clause и
  Apache-2.0. **GPL, LGPL и AGPL нет.**
- Эти лицензии разрешают бесплатно использовать, изменять и распространять
  программы в составе своего продукта, в том числе закрытого и платного.
- Обязанности: приложить тексты лицензий и файлы NOTICE, для MPL-2.0 — дать
  исходники этих модулей, не выдавать чужие товарные знаки за свои. Как это
  делает пакет — в [«Требования и как они выполняются»](#требования-и-как-они-выполняются).

Данные получены 2026-09-25 по сборке из тегов релизов (версии — в
[06 — Сборка и пакет](06-packaging.md#версии)).

## Программы

| Программа | Версия | Лицензия | Правообладатель | Файл NOTICE |
|---|---|---|---|---|
| VictoriaMetrics: `victoria-metrics`, `vmalert`, `vmagent` | v1.152.0 | Apache-2.0 | VictoriaMetrics, Inc. (Copyright 2019-2026) | нет |
| `node_exporter` | v1.12.1 | Apache-2.0 | The Prometheus Authors | есть |
| `systemd_exporter` | v0.7.0 | Apache-2.0 | The Prometheus Authors | нет |
| `blackbox_exporter` | v0.28.0 | Apache-2.0 | The Prometheus Authors | есть |

Исходники не изменяются: в каждом бинарнике записаны коммит тега и
`vcs.modified=false` (см. [06](06-packaging.md#происхождение-и-состав-sbom)).
Наш код (`flat-exporter`, конфигурация, скрипты) остаётся под нашей
лицензией: ни одна из лицензий компонентов не требует раскрывать его.

## Зависимости на Go

Проверено `go-licenses` 1.6.0 с теми же настройками, что и сборка
(`CGO_ENABLED=0`, linux/amd64). Считаем модули: один модуль в разных
программах может быть разных версий, лицензия у него одна.

| Лицензия | Модулей |
|---|---|
| MIT | 40 |
| Apache-2.0 | 20 |
| BSD-3-Clause | 16 |
| BSD-2-Clause | 2 |
| MPL-2.0 | 2 |
| несколько лицензий в одном модуле | 2 |
| **Всего** | **82** |

- **Несколько лицензий:** `github.com/klauspost/compress` (Apache-2.0,
  BSD-3-Clause, MIT — у разных пакетов модуля) и
  `github.com/prometheus/client_golang` (Apache-2.0, внутренний пакет под
  BSD-3-Clause).
- **По программам** (с самой программой): `victoria-metrics` — 19 модулей,
  `vmalert` — 26, `vmagent` — 19, `node_exporter` — 47, `systemd_exporter` —
  27, `blackbox_exporter` — 41.
- **Полный список** — в пакете, `/usr/share/doc/flat-agent/THIRD_PARTY.csv`:
  программа, модуль, ссылка на лицензию, лицензия.

### MPL-2.0

| Модуль | Версия | В какой программе |
|---|---|---|
| `github.com/hashicorp/go-envparse` | v0.1.0 | `node_exporter` |
| `github.com/cyphar/filepath-securejoin` | v0.6.1 | `node_exporter` |

MPL-2.0 — «слабый копилефт» на уровне файлов: при распространении бинарника
нужно дать исходники **именно этих файлов** и сообщить, где их взять.
Остальной код программы и наш код лицензия не затрагивает. `go-licenses save`
кладёт в `licenses/` полный исходный код этих модулей (проверено), так что
исходники едут в том же пакете.

### Файлы NOTICE

Файлы NOTICE есть у 12 модулей: `coreos/go-systemd/v22`,
`hashicorp/go-envparse` (`NOTICES.txt`), `prometheus/blackbox_exporter`,
`prometheus/client_golang`, `prometheus/client_model`, `prometheus/common`,
`prometheus/node_exporter`, `prometheus/procfs`, `go.yaml.in/yaml/v2`,
`go.yaml.in/yaml/v3`, `google.golang.org/grpc` (`NOTICE.txt`),
`gopkg.in/yaml.v2`. `go-licenses save` копирует их вместе с текстами
лицензий.

## Веб-интерфейсы внутри программ

`go-licenses` видит только модули Go. Внутри бинарников есть ещё
веб-интерфейсы с библиотеками на JavaScript и CSS.

**VMUI** (в `victoria-metrics`) лежит в бинарнике готовым бандлом
(`app/vmselect/vmui`, `go:embed`), и **комментариев с лицензиями в бандле нет**
(проверено). Библиотеки берутся из `package-lock.json` VMUI: всё, что
достижимо из зависимостей времени выполнения, — 38 пакетов.

| Библиотека | Версия | Лицензия |
|---|---|---|
| `preact` | 10.29.7 | MIT |
| `react-router-dom` | 7.18.1 | MIT |
| `uplot` | 1.6.32 | MIT |
| `dayjs` | 1.11.21 | MIT |
| `marked` | 18.0.6 | MIT |
| `classnames` | 2.5.1 | MIT |
| `lodash.debounce` | 4.0.8 | MIT |
| `react-input-mask` | 2.0.4 | MIT |
| `qs` | 6.15.3 | BSD-3-Clause |
| `web-vitals` | 5.3.0 | Apache-2.0 |
| ещё 28 пакетов, от которых зависят эти | — | MIT |

- `vite` тоже записан в зависимостях VMUI, но это сборщик: в бандл попадает
  не он, а результат сборки. В его собственных зависимостях есть
  `lightningcss` под MPL-2.0 — это инструмент сборки, в бинарник не входит.
- Тексты лицензий этих 38 пакетов собирает скрипт
  [`vmui-licenses.py`](#vmui-licensespy) (проверено: у всех 38 пакетов есть
  файл лицензии, хеши совпали с `package-lock.json`).

**UI vmalert и страница vmagent** используют Bootstrap (MIT; в vmalert
v5.3.5, в vmagent v5.0.2). Заголовок с лицензией сохранён в самих файлах —
этого достаточно.

## Требования и как они выполняются

| Требование | Лицензии | Как выполняется в `flat-agent` |
|---|---|---|
| Приложить текст лицензии | все | `/usr/share/doc/flat-agent/licenses/` — тексты для каждой программы, модуля Go и JS-библиотеки VMUI |
| Приложить NOTICE | Apache-2.0, п. 4(d) | NOTICE модулей — там же; общий `NOTICE` пакета перечисляет программы, версии и лицензии |
| Сохранить уведомления об авторских правах | MIT, BSD, Apache-2.0 | в тех же файлах; программы не переименовываются, `--version` показывает исходную программу и версию |
| Отмечать изменения | Apache-2.0, п. 4(b); MPL-2.0 | исходники не изменяем (`vcs.modified=false`); если начнём — пометки об изменениях в изменённых файлах |
| Дать исходный код | MPL-2.0, п. 3.2 | полные исходники двух модулей MPL-2.0 — в `licenses/node_exporter/…` |
| Не использовать имена авторов для продвижения | BSD-3-Clause, п. 3 | продукт называется flat_agent; имена компонентов — только в описании состава |
| Не использовать чужие товарные знаки | Apache-2.0, п. 6 | см. [«Товарные знаки»](#товарные-знаки) |

Ещё два условия, о которых стоит знать:

- **Патенты.** Apache-2.0 (п. 3) даёт и лицензию на патенты авторов.
  Она прекращается для того, кто сам подаст патентный иск, утверждая, что
  компонент нарушает его патент.
- **Без гарантий.** Все лицензии — «как есть» (Apache-2.0, пп. 7–8). За
  работу компонентов в составе нашего продукта перед заказчиком отвечаем мы;
  исправления берём из публичных релизов.

## Товарные знаки

Prometheus — товарный знак The Linux Foundation. Название и логотип
VictoriaMetrics принадлежат VictoriaMetrics, Inc. Лицензия Apache-2.0 прав на
товарные знаки не даёт (п. 6), кроме указания на происхождение компонента.

- **Можно:** «совместим с Prometheus», «на базе VictoriaMetrics», названия
  компонентов в описании состава и в документации.
- **Нельзя:** включать эти названия в имя нашего продукта, использовать их
  логотипы как свои.
- VMUI и UI vmalert показывают логотип VictoriaMetrics: это их исходный вид,
  мы его за свой не выдаём. Если VMUI будут пересобирать со своим
  оформлением (см. [04](04-frontend-api.md#свой-вид-вместо-vmui)), логотип
  убирают или оставляют только как указание на происхождение.

## Что не используем

| Что | Лицензия | Почему не входит в пакет |
|---|---|---|
| VictoriaMetrics Enterprise: прореживание данных, фильтры срока хранения, mTLS, vmbackupmanager, Kafka и др. | коммерческая | не нужно; собираем только open source из публичного репозитория |
| Grafana | AGPL-3.0 | в пакет не входит. Grafana заказчика может читать данные с виртуалки ([05](05-integrations.md#grafana)): это сетевой доступ, Grafana мы не распространяем |
| gozstd и C-библиотека zstd из официальных сборок VictoriaMetrics | MIT; zstd — BSD-3-Clause или GPL-2.0 на выбор | собираем без CGO: этого кода в наших бинарниках нет |
| Alertmanager | Apache-2.0 | пока не нужен ([03](03-alerts.md#alertmanager-варианты)); при добавлении условия те же, что у остальных компонентов |
| Любой код под GPL, LGPL, AGPL | — | не используется; проверяется при каждом обновлении (`licenses.sh`) |

## РФ

- **Условия не зависят от страны.** В лицензиях компонентов нет ограничений
  по территории, сфере применения или пользователю: Apache-2.0 и MPL-2.0
  прямо говорят «worldwide», в MIT и BSD таких условий нет вовсе.
- **Лицензии бессрочные и безотзывные.** Apache-2.0 (пп. 2–3) — «perpetual,
  worldwide, non-exclusive, no-charge, royalty-free, irrevocable». Уже
  полученные версии можно использовать и распространять дальше, даже если
  правообладатель сменит лицензию будущих версий или закроет доступ к
  репозиторию. Прекращаются права только при нарушении условий самой
  лицензии.
- **Гражданский кодекс.** Лицензии такого вида соответствуют открытой
  лицензии (ст. 1286.1 ГК РФ): договор присоединения, заключается началом
  использования, безвозмездный, если не сказано иное; для программ для ЭВМ
  без указания срока — на весь срок действия исключительного права, без
  указания территории — на территории всего мира.
- **Главный практический риск — доступность, а не лицензия.** Репозитории и
  сервисы могут быть недоступны из РФ или из закрытого контура. В песочнице
  прототипа уже были закрыты `go.dev`, `dl.google.com`,
  `docs.victoriametrics.com`, `vuln.go.dev`. Поэтому храним у себя исходники
  тегов вместе с `vendor/`, держим внутренний прокси модулей Go и npm,
  собранные пакеты и собранные лицензии (см.
  [06 — Сборка без интернета](06-packaging.md#сборка-без-интернета)).
- **Реестр российского ПО, КИИ, сертификация ФСТЭК.** Компоненты со свободными
  лицензиями в составе продукта не запрещены, но требования к составу, правам
  и документации проверяет юрист. Для сертификации обычно нужен перечень
  заимствованных компонентов (SBOM) и анализ их уязвимостей: исходные данные —
  `THIRD_PARTY.csv`, `go version -m` и отчёты `go-licenses`. flat-agent сам
  не обращается во внешнюю сеть, не обновляется сам и не отправляет
  телеметрию ([01](01-architecture.md#доступ-и-безопасность)) — это обычно
  спрашивают при такой оценке.

## Проверка лицензий

Лицензии собираются при каждой сборке пакета, после `build.sh`. Сборка
останавливается, если у зависимости появилась лицензия не из списка
разрешённых. Новая лицензия в списке — решение юриста, а не сборщика.

### licenses.sh

Составлен из проверенных команд `go-licenses check`, `save` и `report`;
скрипт целиком не запускался.

```sh
#!/bin/sh
# licenses.sh — лицензии всех компонентов в licenses/ и THIRD_PARTY.csv (запускать после build.sh).
set -eu
SRC=${SRC:-$PWD/src}
LIC=${LIC:-$PWD/licenses}
CSV=$PWD/THIRD_PARTY.csv
ALLOWED=MIT,Apache-2.0,BSD-2-Clause,BSD-3-Clause,MPL-2.0
# Как при сборке: иначе go-licenses учтёт модули, которые нужны только с CGO.
export CGO_ENABLED=0 GOOS=linux GOARCH="${GOARCH:-amd64}"

mkdir -p "$LIC"
echo "binary,library,license_url,license" > "$CSV"
lic() {  # <исходники> <пакет main> <бинарник>
  (cd "$1" && go-licenses check "$2" --allowed_licenses="$ALLOWED" \
    && go-licenses save "$2" --save_path="$LIC/$3" --force \
    && go-licenses report "$2" > "$LIC/$3.csv")
  sed "s|^|$3,|" "$LIC/$3.csv" >> "$CSV"
}
lic "$SRC/VictoriaMetrics" ./app/victoria-metrics victoria-metrics
lic "$SRC/VictoriaMetrics" ./app/vmalert vmalert
lic "$SRC/VictoriaMetrics" ./app/vmagent vmagent
lic "$SRC/node_exporter" . node_exporter
lic "$SRC/systemd_exporter" . systemd_exporter
lic "$SRC/blackbox_exporter" . blackbox_exporter

# JS-библиотеки VMUI: встроен в victoria-metrics, go-licenses его не видит.
python3 "$(dirname "$0")/vmui-licenses.py" "$SRC/VictoriaMetrics" "$LIC/victoria-metrics/vmui"
cat "$LIC/victoria-metrics/vmui/THIRD_PARTY-vmui.csv" >> "$CSV"
wc -l "$CSV"
```

Что важно знать о `go-licenses`:

- **`CGO_ENABLED=0` обязательно.** Первое сканирование прототипа шло с CGO
  и показало `github.com/valyala/gozstd`, которого в наших бинарниках нет.
- Предупреждения `contains non-Go code that can't be inspected` (файлы на
  ассемблере) — норма.
- Для VictoriaMetrics, собранной из локальной копии, `go-licenses` пишет
  `has empty version, defaults to HEAD`: неточной может быть только ссылка в
  отчёте, тип лицензии определяется верно.
- `go-licenses check` без MPL-2.0 в списке разрешённых проверен: код 1 и
  `Not allowed license MPL-2.0 found for library github.com/hashicorp/go-envparse`.

### vmui-licenses.py

Проверен: 38 пакетов, у всех есть файл лицензии, хеши совпали с
`package-lock.json`. Нужен доступ к реестру npm или внутреннему зеркалу.
Результат зависит только от тега VictoriaMetrics, поэтому его можно хранить
вместе с исходниками и не скачивать при каждой сборке.

```python
#!/usr/bin/env python3
"""vmui-licenses.py — тексты лицензий JS-библиотек VMUI, встроенного в victoria-metrics.

go-licenses видит только модули Go; VMUI лежит в бинарнике готовым бандлом без
заголовков лицензий. Скрипт берёт зависимости из package-lock.json, скачивает
пакеты из npm, сверяет хеш и сохраняет файлы лицензий.

Запуск: vmui-licenses.py <исходники VictoriaMetrics> <каталог для лицензий>
"""
import base64, csv, hashlib, io, json, os, re, sys, tarfile, urllib.request

src, out = sys.argv[1], sys.argv[2]
ui = os.path.join(src, "app/vmui/packages/vmui")
deps = json.load(open(os.path.join(ui, "package.json")))["dependencies"]
lock = json.load(open(os.path.join(ui, "package-lock.json")))["packages"]


def find(name, parent):
    """Разрешение имени пакета как в Node.js: вложенный node_modules, затем выше."""
    while True:
        key = (parent + "/" if parent else "") + "node_modules/" + name
        if key in lock:
            return key
        if not parent:
            return None
        parent = parent.rsplit("/node_modules/", 1)[0] if "/node_modules/" in parent else ""


# Всё, что достижимо из зависимостей времени выполнения. vite — сборщик, в бандл не входит.
todo, seen = [(name, "") for name in deps if name != "vite"], {}
while todo:
    name, parent = todo.pop()
    key = find(name, parent)
    if key and key not in seen:
        seen[key] = name
        meta = lock[key]
        todo += [(d, key) for d in {**meta.get("dependencies", {}), **meta.get("peerDependencies", {})}]

os.makedirs(out, exist_ok=True)
with open(os.path.join(out, "THIRD_PARTY-vmui.csv"), "w", newline="") as f:
    report = csv.writer(f)
    for key, name in sorted(seen.items(), key=lambda kv: kv[1]):
        meta = lock[key]
        data = urllib.request.urlopen(meta["resolved"]).read()
        algo, digest = meta["integrity"].split("-", 1)
        if hashlib.new(algo, data).digest() != base64.b64decode(digest):
            sys.exit(f"{name}: хеш не совпадает с package-lock.json")
        target = os.path.join(out, f"{name}@{meta['version']}")
        os.makedirs(target, exist_ok=True)
        found = 0
        with tarfile.open(fileobj=io.BytesIO(data)) as tar:
            for member in tar.getmembers():
                base = member.name.split("/", 1)[-1]
                if member.isfile() and re.match(r"(?i)^(licen[cs]e|copying|notice)([.-].*)?$", base):
                    with open(os.path.join(target, base), "wb") as lic:
                        lic.write(tar.extractfile(member).read())
                    found += 1
        if not found:
            sys.exit(f"{name}: в пакете нет файла лицензии, нужна ручная проверка")
        report.writerow(["victoria-metrics (vmui)", f"{name}@{meta['version']}", meta["resolved"], meta.get("license", "")])
print(f"{len(seen)} пакетов, лицензии в {out}")
```

### При обновлении компонентов

1. `licenses.sh` после сборки.
2. Сравнить новый `THIRD_PARTY.csv` с прошлым: новые модули, новые лицензии,
   новые модули под MPL-2.0 (их исходники тоже должны попасть в пакет).
3. Если `go-licenses check` остановил сборку — к юристу, а не расширять
   список разрешённых лицензий самим.
