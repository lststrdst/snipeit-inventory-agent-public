# SnipeIT Inventory Maintenance 1.3.3

Серверный модуль ежедневно выполняет техническое обслуживание SnipeIT Inventory:

- безопасный Users Deletion отключённых AD-пользователей;
- возврат назначенной техники на склад;
- soft delete пользователя из рабочего списка Snipe-IT;
- очистку собственной SQLite-базы и журналов;
- еженедельный отчёт о состоянии инвентаризации.

Технические имена `snipeit-maintenance.service`, каталоги и пути сохранены для совместимости с уже установленной системой.

## Users Deletion

Единственный признак, разрешающий автоматические действия, — `disabled` у учётной записи Active Directory. Описание с текстом `увол` и OU с похожим названием сохраняются только как диагностические признаки и сами по себе не запускают удаление.

Перед действием сервер требует не менее двух успешных LDAP-наблюдений и 30 полных дней непрерывного состояния `disabled`. Повторное включение учётки сбрасывает отсчёт. Затем модуль:

1. Находит LDAP-imported пользователя Snipe-IT по точному `username`.
2. Возвращает выданное ему оборудование.
3. Ставит оборудованию статус `Склад`.
4. Снимает аксессуары и license seats.
5. Повторно проверяет отсутствие назначений.
6. Выполняет штатный soft delete через Snipe-IT API.

За один запуск обрабатывается не более 10 пользователей. Локальные пользователи Snipe-IT и защищённые логины, включая `snipeit`, `admin`, `administrator`, `krbtgt`, `svc_*`, `service_*` и `transcom`, не удаляются.

## Weekly Report

Maintenance запускается ежедневно в 06:30 с random delay до 15 минут, но письмо здоровья отправляет один раз за ISO-неделю, начиная с понедельника.

Тема:

```text
[SNIPEIT-INVENTORY] REPORT: WEEKLY: <overdue> overdue / <total> total
```

Отчёт содержит все ноутбуки выбранной категории и поля:

- имя и серийный номер;
- владелец;
- версия агента;
- дата последней успешной инвентаризации;
- возраст данных в днях;
- статус `Current`, `Overdue`, `Critical` или `Never`;
- последняя ошибка.

Порог `Overdue` — 7 дней, `Critical` — 14 дней. За ISO-неделю в `! Weekly Reports` попадает ровно одно полное письмо. При отсутствии критических компьютеров тема начинается с `REPORT: WEEKLY`, а при наличии `Critical` или `Never` — с `ALERT: WEEKLY`. Если SMTP недоступен в понедельник, отметка недели не сохраняется и maintenance повторит отправку при следующем суточном запуске. После успешной отправки повторов до следующей недели нет. Отдельных ежедневных `WATCHDOG` и `WATCHDOG RECOVERED` больше нет.

## Расписание

```text
maintenance service: ежедневно 06:30
random delay:         до 15 минут
weekly report:        один раз, начиная с понедельника
Persistent:           true
```

Ежедневный запуск нужен даже при недельной почте: Users Deletion контролирует непрерывные 30 дней `disabled`, а cleanup должен работать регулярно.

## Проверка

```bash
systemctl status snipeit-maintenance.timer --no-pager
systemctl status snipeit-maintenance.service --no-pager
journalctl -u snipeit-maintenance.service -n 100 --no-pager
tail -n 100 /var/log/snipeit-maintenance/maintenance.log
```

Проверка без изменений:

```bash
runuser -u snipeit -- python3 /opt/snipeit-maintenance/snipeit_maintenance.py \
  --config /etc/snipeit-maintenance/config.json --dry-run
```

Только недельный отчёт без отправки:

```bash
runuser -u snipeit -- python3 /opt/snipeit-maintenance/snipeit_maintenance.py \
  --config /etc/snipeit-maintenance/config.json --weekly-report-only --dry-run
```

Принудительная реальная отправка для контролируемого теста:

```bash
runuser -u snipeit -- python3 /opt/snipeit-maintenance/snipeit_maintenance.py \
  --config /etc/snipeit-maintenance/config.json --weekly-report-only --force-weekly-report
```

Устаревший аргумент `--watchdog-only` временно принимается как alias для `--weekly-report-only`, чтобы старые команды проверки не ломались.

## Retention

`maintenance_actions` и завершённые записи кандидатов хранятся 365 дней. Активные staged-кандидаты очистка не удаляет. Журнал ограничивается через `logrotate`. Резервные копии серверных обновлений в `/var/backups/snipeit-inventory` автоматически очищаются через 90 дней посредством `systemd-tmpfiles`.
