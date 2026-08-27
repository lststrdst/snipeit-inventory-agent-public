# SnipeIT Inventory 1.3.3 - production verification

Дата проверки: 11 августа 2026.

## Компоненты

- `SnipeIT Inventory Agent` - Windows-агент;
- `SnipeIT Inventory Relay` - автономная доставка через IMAP;
- `SnipeIT Inventory Maintenance` - offboarding, cleanup и недельный контроль;
- `SnipeIT Inventory Weekly Report` - недельный отчёт.

## Почтовая структура

```text
SnipeIT Inventory
  Reports
  Warnings
  Errors
  Offline Relay
  Processed Events
  Rejected Events
```

Коллектор сам сортирует известные письма из `INBOX`. Правила Яндекс.Почты для SnipeIT не требуются.

При миграции Яндекс переместил содержимое удалённых старых папок в `Trash`. Все `396` писем были классифицированы до изменения, сохранены как `.eml` с SHA-256 и восстановлены:

```text
Reports           277
Errors             85
Processed Events   34
Warnings             0
Offline Relay        0
Rejected Events      0
Trash                 0
```

Посторонних писем среди восстановленных: `0`. Резервная копия восстановления:

```text
/var/backups/snipeit-inventory/20260811-165252-mail-recovery
```

## Проверки

- PowerShell: 7/7 наборов агента и установщика;
- Agent relay/state assertions: 34;
- SnipeIT Inventory Relay: 34/34 unit-теста;
- SnipeIT Inventory Maintenance: 9/9 unit-тестов;
- синтаксис PowerShell и Python проверен;
- конфигурация production Relay принята без изменения секретов;
- живые темы `REPORT`, `WARNING`, `ERROR` разложены в отдельные папки;
- контрольные письма удалены после проверки;
- три последовательных production-цикла Relay: `success`, `exit 0`;
- `snipeit-mail-relay.timer`: `active`.

Тестами отдельно подтверждено:

- постороннее письмо после неточного IMAP-поиска остаётся во входящих;
- временный сбой поиска человеческих отчётов не блокирует offline relay;
- старые темы и папки распознаются для миграции;
- родительская папка с дочерними папками не удаляется;
- повторное событие не выполняется второй раз.

## Retention

```text
agent/install logs     30 дней, максимум 60 запусков
local mail queue       30 дней, максимум 200 событий
Processed Events       30 дней
Rejected Events        60 дней
Reports               180 дней
Warnings              180 дней
Errors                365 дней
Relay SQLite          365 дней
Maintenance SQLite    365 дней
server logs           logrotate
server update backups  90 дней
```

`INBOX` и `Offline Relay` не очищаются по возрасту. Неуведомлённые relay-ошибки не удаляются до формирования уведомления.

## Итог

Production-цепочка автоматизирует установку и обновление через GPO, прямую и автономную инвентаризацию, смену владельца, возврат на склад, disabled-only offboarding, soft delete пользователя, дедупликацию, повтор временных ошибок, недельный контроль и retention.

Физическое ограничение остаётся одно: нельзя получить свежие данные с выключенного компьютера, который не видит одновременно GPO и SMTP. Такой компьютер остаётся видимым в Weekly Report как `Overdue` или `Never`.
