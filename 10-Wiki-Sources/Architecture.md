# Архитектура

Версия `1.3.3` использует два пути доставки:

```text
Windows Agent -> Snipe-IT API
       |
       `-> SMTP -> IMAP Relay -> локальный Snipe-IT API

Directory service -> владелец и disabled
Maintenance       -> склад, cleanup и weekly report
```

PowerShell-агент собирает характеристики и пользователя. Python relay проверяет
подписанные события и применяет их через локальный API. Maintenance обслуживает
offboarding, retention и контроль свежести данных. SQLite хранит состояние и
защищает повторную доставку через стабильный `event_id`.

Это переходная архитектура: HMAC обеспечивает целостность, но payload не
шифруется, а прямой API доступ остается на клиентах. Эти ограничения устранены
в отдельной архитектуре SnipeIT Inventory Gateway.
