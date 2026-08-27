# SnipeIT Inventory Relay 1.3.3

Relay установлен на сервере Snipe-IT. Когда ноутбук не видит локальный DNS или API, SnipeIT Inventory Agent отправляет подписанное JSON-событие по SMTP. Relay читает его через IMAP, проверяет HMAC и применяет через локальный API.

Технические имена `snipeit-mail-relay.service`, каталоги и пути сохранены, чтобы обновление не создавало второй сервис.

## Единая структура почты

Родительская папка:

```text
SnipeIT Inventory
```

Дочерние папки:

```text
! Weekly Reports  одно полное недельное письмо: REPORT или ALERT
Reports           значимые отчёты агента
Alerts            Users Deletion и другие серверные действия
Warnings          предупреждения, при которых инвентаризация завершилась безопасно
Errors            ошибки агента и события, не исправленные автоматически за 24 часа
Offline Relay     автономные события, ожидающие обработки или повтора
Processed Events  применённые, повторные и безопасно устаревшие события
Rejected Events   неподписанные, повреждённые или недоверенные relay-события
```

`Processed Events` означает окончательный безопасный результат:

- `processed` — изменения применены;
- `duplicate` — тот же `event_id` уже применялся;
- `stale` — в Snipe-IT уже есть более свежая прямая инвентаризация.

## Темы

```text
[SNIPEIT-INVENTORY] REPORT: WEEKLY: -> ! Weekly Reports
[SNIPEIT-INVENTORY] ALERT: WEEKLY:  -> ! Weekly Reports
[SNIPEIT-INVENTORY] REPORT:   -> Reports
[SNIPEIT-INVENTORY] ALERT:    -> Alerts
[SNIPEIT-INVENTORY] WARNING:  -> Warnings
[SNIPEIT-INVENTORY] ERROR:    -> Errors
[SNIPEIT-INVENTORY] RELAY:    -> Offline Relay, затем Processed Events или Rejected Events
```

На переходный период принимаются старые `[PCINV-REPORT]`, `[PCINV-ALERT]`, `[SNIPEIT-INVENTORY] ALERT:`, `PC Inventory ERROR` и `[SNIPEIT-RELAY]`. Известные старые папки автоматически мигрируют в новую структуру. Пустая старая папка удаляется только после переноса всех сообщений.

Правила Яндекс.Почты не нужны: relay сам ищет служебные и человеческие письма в `INBOX`. Старые правила сортировки после обновления лучше удалить, иначе они могут заново создавать прежние папки.

## Учётная запись Яндекса

Production использует `it@example.com` и один пароль приложения с названием `Snipeit imap collector`. Тип пароля в Яндекс ID: `Почта - IMAP, POP3, SMTP`. Поэтому одно значение разрешено использовать одновременно в `imap_password` и `smtp_password`.

Сам пароль хранится только в `/etc/snipeit-mail-relay/config.json` и в закрытом агентском JSON на `\\AD-SERVER\snipeit_auto_secure$`. В публичные архивы и документацию значение не включается. При ротации оба закрытых конфига обновляются до удаления старого пароля.

## Безопасность

Перед любым API-действием проверяются:

1. точный разрешённый отправитель;
2. заголовок `X-SnipeIT-Relay: 1`;
3. допустимый префикс темы;
4. ограничение размера письма;
5. единственное JSON-вложение;
6. HMAC-SHA256;
7. JSON-схема и обязательные поля;
8. стабильный `event_id`.

Постороннее письмо из `INBOX` не перемещается. Даже ложное совпадение IMAP сначала проверяется локально.

## Идемпотентность

Состояние хранится в SQLite. Один `event_id` не выполняется дважды. Повтор после частично выполненного API-запроса безопасно продолжает операцию. Старая почтовая инвентаризация не перезаписывает более свежую прямую.

## Расписание и ошибки

Relay проверяет и сортирует почту строго каждые 2 минуты без случайной задержки. Автономные события сначала ищутся по служебному заголовку `X-SnipeIT-Relay: 1`, затем по широким маркерам `SNIPEIT` и `RELAY`; человеческие отчёты - по `PCINV`, `SNIPEIT-INVENTORY` и `PC Inventory`. Такой поиск работает и со старыми темами `[SNIPEIT-RELAY]`, для которых Yandex IMAP иногда возвращает пустой результат. После поиска отправитель и полный префикс темы всё равно проверяются локально, поэтому посторонние письма не перемещаются. Временная ошибка API оставляет событие в `Offline Relay` для повтора. Если событие не удалось обработать 24 часа, отправляется одно письмо:

```text
[SNIPEIT-INVENTORY] ERROR: RELAY FAILED 24H: <computer>
```

`--dry-run` использует временную SQLite in-memory и не создаёт постоянную
запись дедупликации. Он не изменяет Snipe-IT и не перемещает письма.

## Retention

```text
Processed Events  30 дней
Rejected Events   60 дней
! Weekly Reports  365 дней
Reports           180 дней
Alerts            365 дней
Warnings          180 дней
Errors            365 дней
SQLite            365 дней
```

`INBOX` и рабочая папка `Offline Relay` по возрасту не очищаются. Неуведомлённые ошибки SQLite не удаляются. Cleanup выполняется раз в сутки, после удаления SQLite делает checkpoint и периодический `VACUUM`; журналы ограничивает `logrotate`.

## Проверка

```bash
systemctl status snipeit-mail-relay.timer --no-pager
systemctl status snipeit-mail-relay.service --no-pager
journalctl -u snipeit-mail-relay.service -n 100 --no-pager
tail -n 100 /var/log/snipeit-mail-relay/relay.log
```

```bash
runuser -u snipeit -- python3 /opt/snipeit-mail-relay/snipeit_mail_relay.py \
  --config /etc/snipeit-mail-relay/config.json --check-config
runuser -u snipeit -- python3 /opt/snipeit-mail-relay/snipeit_mail_relay.py \
  --config /etc/snipeit-mail-relay/config.json --check-imap
runuser -u snipeit -- python3 /opt/snipeit-mail-relay/snipeit_mail_relay.py \
  --config /etc/snipeit-mail-relay/config.json --check-snipe
```

Agent и Relay не передают `asset_tag`, поэтому внутренние номера оборудования сохраняются при обычной инвентаризации, обновлении агента и смене владельца.
