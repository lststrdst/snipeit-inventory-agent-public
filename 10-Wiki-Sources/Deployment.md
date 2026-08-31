# Развертывание

Я разделяю публичный пакет и закрытую конфигурацию. Репозиторий содержит агент,
установщик, server units и placeholders; реальные API, SMTP, IMAP и
HMAC-значения должны поступать только из защищенного хранилища.

На Windows агент устанавливается в `%ProgramData%`, работает скрытой задачей от
`SYSTEM` и обновляется после изменения SHA-256 пакета. Для GPO используется
VBS-wrapper, чтобы не показывать пользователю окно PowerShell или Terminal.

На Linux relay и maintenance запускаются отдельными systemd service/timer.
Перед включением production я рекомендую выполнить проверку конфигурации,
соединения IMAP/API и полный dry-run.

Пошаговые шаблоны находятся в `01-Agent-PUBLIC`, `03-Relay-PUBLIC`,
`05-Maintenance-PUBLIC` и `08-Documentation`.
