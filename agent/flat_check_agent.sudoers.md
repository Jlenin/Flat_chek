# flat_check_agent.sh — права доступа

**Установка — от root, работа — обычным сервисом.**

Это справка, а не sudoers-конфиг: в `/etc/sudoers.d` ничего класть не нужно,
правил sudo здесь нет. Агенту sudo не нужен ни для одной проверки.

| Этап | От кого | Что происходит |
|---|---|---|
| Установка | root (sudo), один раз | пакет `flat-check` или [шаги ниже](#1-установка-от-root-один-раз) |
| Работа | `flat-service:flat-group` | systemd-сервис `flat-check.service` (`User=`/`Group=` в [`flat-check.service.example`](flat-check.service.example)); без sudo, без root, без дополнительных capabilities |

> Проверено на Ubuntu 24.04: установка по шагам ниже от root, затем запуск
> агента от `flat-service` через `runuser` — кеш, лог и push работают, ошибок
> прав нет. Сам systemd-юнит в песочнице не запускался (systemd там не
> работает).

## 1. Установка (от root, один раз)

Пакет `flat-check` делает шаги «каталог агента» сам (postinst в
`.gitlab-ci.yml`: `chown -R` на `/opt/flat/flat-check`, `chmod 640` на
конфиг). **Каталог лога пакет пока не создаёт** — этот шаг нужен и при
установке пакетом.

Пользователь и группа сервиса (если их ещё нет на хосте):

```bash
getent group flat-group >/dev/null || groupadd --system flat-group
getent passwd flat-service >/dev/null || useradd --system -g flat-group \
    -d /opt/flat/flat-check -M -s /usr/sbin/nologin flat-service
```

Каталог агента. Писать сервис будет только в `cache/` (создаёт его сам):

```bash
install -d -m 0755 /opt/flat/flat-check
cp flat_check_agent.sh /opt/flat/flat-check/
cp flat_check_agent.conf.example /opt/flat/flat-check/flat_check_agent.conf
chown -R flat-service:flat-group /opt/flat/flat-check
chmod 0755 /opt/flat/flat-check/flat_check_agent.sh
chmod 0640 /opt/flat/flat-check/flat_check_agent.conf   # в конфиге PUSH_TOKEN
```

Каталог файлового лога (`LOG_FILE`):

```bash
install -d -m 0755 /var/log/flat
install -d -m 0755 -o flat-service -g flat-group /var/log/flat/flat-check
```

- Без этого шага сервис не может создать `/var/log/flat/flat-check` и тихо
  работает без файла, только stderr (`journalctl -u flat-check`).
- Права именно `0755`, не `0775`: logrotate (работает от root) отказывается
  ротировать файл в каталоге, доступном на запись группе, отличной от root
  (`parent directory has insecure permissions`).

Юнит и ротация лога:

```bash
cp flat-check.service.example /etc/systemd/system/flat-check.service
cp flat-check.logrotate.example /etc/logrotate.d/flat-check
systemctl daemon-reload
systemctl enable --now flat-check.service
```

## 2. Работа (обычный сервис, без sudo)

Пишет агент только в два места:

| Путь | Что | Кто создаёт |
|---|---|---|
| `/opt/flat/flat-check/cache/` | кеш и `last_sent.json` | агент сам |
| `/var/log/flat/flat-check/` | `LOG_FILE` | установка (см. выше) |

Читает свой конфиг `/opt/flat/flat-check/flat_check_agent.conf` (`0640`).

Всё остальное — только чтение, root для этого не нужен:

| Что проверяет | Чем | Что нужно |
|---|---|---|
| установленные пакеты | `dpkg-query`, `dpkg -s`, `rpm -q/-qa/-qR`, `pacman -Q` | ничего |
| состояние юнитов | `systemctl show`, `systemctl is-active` (D-Bus, только чтение) | ничего |
| слушающие порты | `ss -lntu` или `netstat -lntu` (без `-p`, имена процессов не нужны) | ничего |
| процессы | `pgrep`, `/proc/<pid>/stat`, `status`, `comm`, `cmdline` | ничего (кроме `hidepid`, см. ниже) |
| CPU, память, сеть, диски | `/proc/stat`, `/proc/meminfo`, `/proc/net/dev`, `/proc/uptime`, `/sys/class/net`, `df -P` | ничего |
| health-API и отправка | `curl` к локальным API и на `PUSH_URLS` | ничего |
| сертификаты | `openssl x509` по `/etc/nginx/ssl`, `/opt/flat/cert`, `/etc/ssl/certs/flat*.pem` | право на чтение файла (сертификаты обычно `0644`) |
| каталоги и конфиги пакетов | существование `/opt/flat/<pkg>`, `/var/log/flat/<pkg>`, `/etc/nginx/sites-*`, `/etc/logrotate.d` | только проход по каталогам |

Проверить, что сервис работает не от root:

```bash
systemctl show flat-check -p User -p Group
ps -o user=,group=,args= -p "$(systemctl show flat-check -p MainPID --value)"
ls -l /opt/flat/flat-check/cache /var/log/flat/flat-check   # владелец flat-service
```

Запустить вручную (проверить конфиг) — тоже от имени сервиса, не от root.
`runuser` работает и с оболочкой `nologin`, JSON печатается в терминал:

```bash
runuser -u flat-service -- /opt/flat/flat-check/flat_check_agent.sh
```

## 3. Что без root видно хуже

Это осознанные компромиссы: агент не падает и не пишет ошибок.

### `configs[].status` для `service_name="sudoers"`

Проверяется файл `/etc/sudoers.d/<pkg>`. На Debian/Ubuntu каталог
`/etc/sudoers.d` обычно `0750 root:root`: без права прохода проверка «есть ли
файл» всегда отвечает «нет», и поле всегда `"missing"`, даже если файл есть.

Если поле нужно, самый узкий вариант — право только на проход по каталогу
(пакет `acl`):

```bash
setfacl -m u:flat-service:x /etc/sudoers.d   # дать
getfacl /etc/sudoers.d                       # проверить
setfacl -x u:flat-service /etc/sudoers.d     # откатить
```

Так агент проверяет файл по имени, а листинг каталога и чтение файлов
по-прежнему запрещены (проверено). Шаг необязателен: деградация до
`"missing"` безопасна.

### `/proc` с `hidepid=2`

Чужие процессы не видны, `process.status` покажет `"not running"`. Если
нужно — добавить `flat-service` в группу, указанную в опции `gid=`
монтирования `/proc`.

### Сертификат без права на чтение

Файл попадёт в `certificates[]` с `"days_left":0` и пустым `subject` — это не
реальный срок. Сертификаты (не ключи) обычно `0644` и читаются.

## 4. Чего делать не нужно

- **Не давать `flat-service` sudo** (тем более `NOPASSWD:ALL`) и не класть
  этот файл в `/etc/sudoers.d` — ни одной проверке это не нужно.
- **Не убирать `User=`/`Group=` из юнита и не запускать агент от root** «для
  простоты». Первый запуск от root создаёт `cache/` и файл лога от root
  (`0755`/`0644`), после чего сервис не может писать кеш
  (`Permission denied`) и тихо теряет файловый лог (проверено). Если так уже
  случилось:

  ```bash
  chown -R flat-service:flat-group /opt/flat/flat-check /var/log/flat/flat-check
  ```
