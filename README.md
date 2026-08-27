# Snipeit Inventory Agent

Обезличенная reference-реализация автоматической инвентаризации Windows-компьютеров
для Snipe-IT. Текущий пакет: `1.3.3`.

## Зачем

Агент собирает характеристики ПК, определяет фактического пользователя,
обновляет актив в Snipe-IT и умеет доставить инвентаризацию через offline relay,
если прямой API недоступен.

## Как устроено

```text
Windows Agent -> Snipe-IT API
       |             |
       `-> SMTP -> IMAP Relay -> локальный Snipe-IT API

Active Directory -> владелец и disabled/offboarding-признаки
Maintenance      -> склад, очистка и weekly report
```

Репозиторий содержит PowerShell-агент, Python relay/maintenance, systemd units,
GPO-материалы, примеры конфигурации и тесты. Production secrets намеренно
заменены placeholders. Подставлять реальные значения нужно только в закрытом
окружении.

## Почта и защита от дублей

Отчёты, предупреждения, ошибки, offline relay, обработанные и отклонённые
события разделяются по темам и папкам. Relay проверяет отправителя, JSON-схему,
размер, HMAC и стабильный `event_id`. Дубликаты не выполняют повторный checkout,
а обычные письма не перемещаются.

## Документация

- Архитектура и потоки: `08-Documentation/ARCHITECTURE-RU.md`.
- Развёртывание и GPO: `08-Documentation/README-GPO.txt`.
- Изменения: `08-Documentation/CHANGELOG-1.3.3-RU.md`.
- Примеры конфигурации: `01-Agent-PUBLIC`, `03-Relay-PUBLIC`, `05-Maintenance-PUBLIC`.

Не используйте этот репозиторий как production-конфигурацию без настройки
секретов, ACL, TLS и проверок окружения.
