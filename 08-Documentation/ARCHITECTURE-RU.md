# Архитектура Snipeit Inventory Agent 1.3.3

## Общая схема

```text
Windows PC
  |
  |-- Snipe-IT доступен --> Agent --> Snipe-IT API
  |
  `-- Snipe-IT недоступен --> подписанный JSON --> SMTP/IMAP
                                                   |
                                                   `--> Relay --> локальный Snipe-IT API

Active Directory --> Agent: текущий владелец, disabled, OU, description
Active Directory --> Maintenance: подтверждённый offboarding
Snipe-IT API      --> Maintenance: склад, soft delete, weekly report
```

## 1. Windows Agent

Основной файл: `snipeit_inventory.ps1`, версия `1.3.3`.

Установщик копирует агент в `C:\ProgramData\snipeit_auto`, защищает закрытый конфиг и SSH-ключ, создаёт локальную задачу `\SnipeIT Inventory\Inventory Agent` и удаляет прежнюю задачу `\SnipeIT\Auto Inventory`.

Приватный LDAP SSH-ключ поступает только из `\\AD-SERVER\snipeit_auto_secure$`, устанавливается в `C:\ProgramData\snipeit_auto\Config\snipeit_ldap_sync_ed25519` и получает ACL только для `SYSTEM` и локальных администраторов. После успешной миграции установщик удаляет старые копии ключа и `.pub` из корня агента и локальных профилей пользователей.

Задача работает скрыто от `SYSTEM`:

- запуск Windows: задержка 5 минут;
- вход любого пользователя: задержка 2 минуты;
- расписание: 08:00, 14:00 и 20:00, random delay до 1 часа.

Дополнительные старты не создают дублей: агент учитывает состояние, event ID и суточный интервал. При первой установке или реальном обновлении выполняется один скрытый forced-run.

Agent собирает ПК, CPU, RAM, накопители, ОС и текущего интерактивного пользователя. Служебные учётки, включая `ad_*`, `svc_*`, `service_*` и `transcom`, не становятся владельцами. Disabled-пользователь или подтверждённый признак увольнения приводит к возврату актива на склад. Новый корректный пользователь затем может получить тот же актив обычным checkout.

Логи ограничены 30 днями и 60 запусками. Локальная очередь почты ограничена 30 днями и 200 элементами.

## 2. Прямой API и offline relay

При доступном Snipe-IT агент записывает данные напрямую. При transport-ошибке он формирует JSON-событие со стабильным `event_id`, подписывает его HMAC-SHA256 и отправляет на `it@example.com`.

Relay работает на сервере Snipe-IT каждые 2 минуты:

1. Читает только подходящие письма SnipeIT Inventory.
2. Проверяет отправителя, тему, вложение, размер, JSON-схему и HMAC.
3. Проверяет `event_id` в SQLite.
4. Применяет событие через локальный API.
5. Перемещает письмо в `Processed Events`, либо в `Rejected Events` при необратимой ошибке.

Обычная почта не должна перемещаться. Временная ошибка оставляет событие на повтор, а подтверждённый дубликат считается успешно обработанным.

Почтовая структура:

```text
SnipeIT Inventory/
  ! Weekly Reports
  Reports
  Alerts
  Warnings
  Errors
  Offline Relay
  Processed Events
  Rejected Events
```

Правила Яндекс Почты для этой структуры не обязательны: сортировку выполняет серверный relay.

## 3. Maintenance и offboarding

Maintenance запускается ежедневно в 06:30 с random delay до 15 минут.

Автоматическое удаление разрешается только для учётной записи AD, непрерывно остающейся `disabled` не менее 30 дней. OU и description используются как диагностические признаки, но сами по себе не разрешают удаление. Перед действием дополнительно требуются минимум два успешных LDAP-наблюдения, разнесённых не менее чем на 12 часов.

После подтверждения Maintenance:

1. Находит LDAP-imported пользователя Snipe-IT по точному username.
2. Возвращает выданные активы на склад.
3. Снимает аксессуары и лицензии.
4. Проверяет, что назначений больше нет.
5. Выполняет штатный soft delete пользователя.
6. Сохраняет журнал действий в SQLite.

Защищённые и служебные логины, включая `snipeit`, администраторов, `krbtgt`, `svc_*`, `service_*` и `transcom`, автоматически не удаляются.

## 4. Weekly report

Раз в ISO-неделю, начиная с понедельника, Maintenance отправляет ровно одно полное письмо о состоянии ноутбуков в `! Weekly Reports`. Просроченными считаются машины без успешной инвентаризации 7 и более дней, критическими — 14 и более дней, а также машины без единой успешной инвентаризации. Тема будет `REPORT: WEEKLY` при отсутствии критических записей или `ALERT: WEEKLY` при их наличии. Если отправка не удалась, она повторится при следующем суточном запуске; после успеха до следующей недели дублей нет.

## 5. Идемпотентность и защита

- Агент сравнивает SHA-256 перед обновлением файлов.
- Глобальный mutex блокирует параллельные установки.
- Event ID и SQLite relay предотвращают повторную запись.
- Более старое relay-событие не перезаписывает свежую прямую инвентаризацию.
- Теги активов не создаются и не перезаписываются агентом.
- Секреты отделены от публичных файлов.
- Relay HMAC secret отличается от почтового пароля.
- Сервисные логи, mail folders, SQLite и серверные backup-копии имеют retention.

## 6. Рабочие пути

Windows:

```text
C:\ProgramData\snipeit_auto\
  Config\
  Logs\
  State\
  MailQueue\
```

Linux:

```text
/opt/snipeit-mail-relay
/etc/snipeit-mail-relay/config.json
/var/lib/snipeit-mail-relay/events.sqlite3
/opt/snipeit-maintenance
/etc/snipeit-maintenance/config.json
/var/lib/snipeit-maintenance/state.sqlite3
/var/backups/snipeit-inventory
```

Технические имена systemd сохранены ради совместимости:

```text
snipeit-mail-relay.service / .timer
snipeit-maintenance.service / .timer
```

## 7. Контроль

```bash
systemctl status snipeit-mail-relay.timer --no-pager
systemctl status snipeit-maintenance.timer --no-pager
journalctl -u snipeit-mail-relay.service -n 100 --no-pager
journalctl -u snipeit-maintenance.service -n 100 --no-pager
```

Безопасная проверка компонентов:

```bash
runuser -u snipeit -- python3 /opt/snipeit-mail-relay/snipeit_mail_relay.py --config /etc/snipeit-mail-relay/config.json --check-config
runuser -u snipeit -- python3 /opt/snipeit-maintenance/snipeit_maintenance.py --config /etc/snipeit-maintenance/config.json --dry-run
```
