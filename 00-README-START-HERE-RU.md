# Snipeit Inventory Agent 1.3.3

Дата сборки комплекта: 12.08.2026.

Это актуальный комплект всей системы автоинвентаризации:

- Windows Agent;
- offline relay через SMTP/IMAP;
- серверное обслуживание и offboarding;
- скрипты развёртывания;
- закрытые production-конфиги;
- документация и результаты проверок.

## Важно

Каталоги `02-Agent-SECURE`, `04-Relay-SECURE` и `06-Maintenance-SECURE` содержат реальные секреты. Не публиковать их, не класть в открытую шару и не отправлять в мессенджеры.

Закрытые файлы на этом компьютере ограничены NTFS ACL для текущего пользователя, `SYSTEM` и локальных администраторов. При переносе на другой диск или в облако эти ACL могут потеряться.

## Состав CURRENT

| Каталог | Назначение |
|---|---|
| `01-Agent-PUBLIC` | Файлы для `\\AD-SERVER\snipeit_auto$` |
| `02-Agent-SECURE` | JSON и SSH-ключ для `\\AD-SERVER\snipeit_auto_secure$` |
| `03-Relay-PUBLIC` | Код, unit-файлы и установщик IMAP relay |
| `04-Relay-SECURE` | Рабочий production-конфиг relay |
| `05-Maintenance-PUBLIC` | Код, unit-файлы и установщик maintenance |
| `06-Maintenance-SECURE` | Рабочий production-конфиг maintenance |
| `07-Deployment` | Скрипты массового развёртывания и серверные deploy-скрипты |
| `08-Documentation` | Wiki, changelog, схема и результаты проверок |
| `09-Tests` | Полный набор тестов и безопасный `Run-All-Tests.ps1` |

## Что куда загружать

В открытую шару `\\AD-SERVER\snipeit_auto$` копируются только:

```text
install_snipeit_auto.ps1
install_snipeit_auto.vbs
install_snipeit_manual.cmd
install_snipeit_manual.ps1
snipeit_inventory.ps1
snipeit_auto.vbs
snipeit_manual.cmd
snipeit_dry_run.cmd
```

В закрытую шару `\\AD-SERVER\snipeit_auto_secure$` копируются:

```text
snipeit_inventory.local.json
snipeit_ldap_sync_ed25519
snipeit_ldap_sync_ed25519.pub
```

Relay и Maintenance устанавливаются только на сервер Snipe-IT. Их рабочие `config.json` нельзя размещать в открытой шаре.

## Ручная установка на одном компьютере

После загрузки обеих шар запустить от имени администратора:

```text
\\AD-SERVER\snipeit_auto$\install_snipeit_manual.cmd
```

CMD показывает только ход ручного bootstrap. Сама установка запускается одноразовой скрытой задачей от `SYSTEM`, создаёт постоянную `\SnipeIT Inventory\Inventory Agent`, проверяет результат и удаляет одноразовую задачу. Журнал: `C:\ProgramData\snipeit_auto\Logs\manual-install.log`.

Автоматическая GPO-установка продолжает использовать `install_snipeit_auto.vbs` и остаётся полностью скрытой.

## Что этот комплект не менял

DC1, GPO и клиентские компьютеры при сборке не изменялись. На сервере Snipe-IT уже применён тихий совместимый фикс relay/maintenance: отдельная папка `! Weekly Reports` и ровно одно полное недельное письмо.

## Контроль целостности

Хеши всех файлов находятся в `SHA256SUMS.txt`. Проверка PowerShell:

```powershell
$root = "C:\Users\user\Desktop\SnipeIT-Inventory-CURRENT-v1.3.3-20260812"
Get-Content "$root\SHA256SUMS.txt" | ForEach-Object {
    $hash, $relative = $_ -split '  ', 2
    $actual = (Get-FileHash -LiteralPath (Join-Path $root $relative) -Algorithm SHA256).Hash.ToLower()
    [pscustomobject]@{ File = $relative; OK = ($actual -eq $hash) }
}
```

Полная схема находится в `08-Documentation\ARCHITECTURE-RU.md`. Порядок восстановления находится в полном backup-комплекте.
