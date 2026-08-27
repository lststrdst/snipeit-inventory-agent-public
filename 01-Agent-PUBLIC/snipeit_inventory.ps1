#requires -version 5.1

[CmdletBinding()]
param(
    [switch]$GpoMode,
    [switch]$ManualMode,
    [switch]$ForceInventory,
    [switch]$ForceEmailReport,
    [switch]$DeploymentRun,
    [switch]$DryRun,
    [switch]$LibraryMode
)

if (-not $GpoMode -and -not $ManualMode) {
    $ManualMode = $true
}

# ==========================
# SNIPE-IT INVENTORY AGENT
# ==========================
$InventoryAgentVersion = "1.3.3"
$InventoryStateSchemaVersion = 3
$InventoryProductName = "SnipeIT Inventory"
$InventoryReportSubjectPrefix = "[SNIPEIT-INVENTORY] REPORT:"
$InventoryWarningSubjectPrefix = "[SNIPEIT-INVENTORY] WARNING:"
$InventoryErrorSubjectPrefix = "[SNIPEIT-INVENTORY] ERROR:"

# Что делает:
# 1) собирает инвентаризацию ПК
# 2) при необходимости запускает LDAP sync на сервере Snipe-IT по SSH
# 3) берет текущего/последнего доменного пользователя вида EXAMPLE\user -> user
# 4) ищет пользователя в Snipe-IT
# 5) ищет актив по serial, потом по имени ПК
# 6) если актива нет — создает актив
# 7) если актив есть — обновляет имя/serial/model/status
# 8) если актив привязан не к тому пользователю — checkin + checkout на текущего
# 9) отправляет HTML/TXT отчет на почту

# ==========================
# SMTP НАСТРОЙКИ
# ==========================
$SmtpServer = "smtp.yandex.ru"
$SmtpPort   = 587
$UseSsl     = $true

$SmtpUser = ""
$SmtpPass = ""

$MailFrom = "user@example.com"
$MailTo   = "it@example.com"

# ==========================
# SNIPE-IT API
# ==========================
$SnipeEnabled = $true
$SnipeUrl     = "https://snipeit.example.internal"
$SnipeToken   = "PUT_SNIPEIT_API_TOKEN_HERE"
$SnipeIgnoreSslCertificateErrors = $true
$SnipeApiUserAgent = "SnipeIT-Inventory-Agent/$InventoryAgentVersion"
$SnipeApiFallbackToCurl = $true
$SnipeFallbackUrls = @(
    "https://192.0.2.10",
    "http://snipeit.example.internal",
    "http://192.0.2.10"
)
$SnipeApiFallbackToSsh = $true
$SnipeApiSshLocalUrls = @(
    "https://127.0.0.1",
    "http://127.0.0.1",
    "https://localhost",
    "http://localhost"
)

# Статусы/категории под твою структуру
# status_id: лучше поставить ID статуса "Выдан" или "Ready to Deploy".
# category_id: ID категории "Ноутбуки".
# manufacturer_id: если модель не найдена и надо создать модель, используется этот ID.
$SnipeDefaultStatusId       = 8
$SnipeStockStatusId         = 1 # Реальный статус "Склад" в этой установке Snipe-IT.
$SnipeDefaultCategoryId     = 1
$SnipeDefaultManufacturerId = 1
$SnipeDefaultFieldsetId     = 2 # Laptops and Desktops
$SnipeCustomFieldRam        = "_snipeit_ram_3"
$SnipeCustomFieldCpu        = "_snipeit_cpu_4"
$SnipeCustomFieldOs         = "_snipeit_os_9"
$SnipeCustomFieldStorage    = "_snipeit_storage_10"
$SnipeCustomFieldAgentVersion = "_snipeit_agent_version_11"
$SnipeCustomFieldLastSuccess  = "_snipeit_last_successful_inventory_12"
$SnipeCustomFieldLastError    = "_snipeit_last_error_13"

# Если модель ПК не найдена в Snipe-IT, создать ее автоматически
$SnipeAutoCreateModel = $true

# Asset tag не входит в payload агента. Новый тег назначает штатный
# автонумератор Snipe-IT; существующий внутренний номер агент не меняет.

# Делать checkout на текущего пользователя автоматически
$SnipeAutoCheckout = $true

# Если актив уже выдан другому — сначала checkin, потом checkout на нового
$SnipeCheckinBeforeReassign = $true

# ВАЖНО: не переводить найденный актив на склад во время обычного обновления.
# Склад ставится только при создании нового актива или когда реально нет пользователя для выдачи.
$SnipeSetDefaultStatusOnUpdate = $false

# ==========================
# LDAP SYNC
# ==========================
# Основной LDAP sync должен идти на сервере Snipe-IT по расписанию.
# Клиентский sync оставлен как fallback: если пользователь не найден в Snipe-IT,
# агент один раз дернет sync по SSH-ключу и повторит поиск.
$RunLdapSyncBeforeSnipeSearch = $false
$RunLdapSyncIfUserMissing = $true
$SnipeSshHost    = "192.0.2.10"
$SnipeSshUser    = "snipeit"
$SnipeSshKeyPath = "C:\ProgramData\snipeit_auto\Config\snipeit_ldap_sync_ed25519"
$SnipeSshPassword = "" # штатный ssh.exe не принимает пароль в скрытом GPO-режиме; используется ключ.
$SnipeLdapSyncCommand = "cd /var/www/snipe-it && /usr/bin/php artisan snipeit:ldap-sync --summary --no-interaction"

# ==========================
# ПАУЗА В КОНЦЕ
# ==========================
# Без параметров скрипт работает как ручной запуск.
# Для GPO запускай этот же файл с параметром -GpoMode.
$PauseAtEnd = $true

# ==========================
# АВТОИНВЕНТАРИЗАЦИЯ / ПОЧТА
# ==========================
# GPO может запускать скрипт при каждом входе, но Snipe-IT дергаем только:
# 1) если сменился пользователь на этом ПК
# 2) если прошло N дней с последней успешной инвентаризации
# 3) если запуск ручной
$InventoryIntervalDays = 1
$InventoryStatePathOverride = ""
$InventoryLogDirOverride = ""
$InventoryEnableLegacyUsernameAliases = $true
$InventoryUsernameAliases = @{}
$SendEmailReport = $true
$SendEmailOnUserChange = $true
$SendEmailOnSnipeUserChange = $true
$SendEmailOnStockCheckin = $true
$SendEmailOnWarning = $true
$SendEmailOnError = $true
$InventoryMailQueueWarningItems = 20
$InventoryMailSendBatchSize = 5
# Одинаковая уже отправленная ошибка/предупреждение повторяется не чаще этого интервала.
# Ручной -ForceEmailReport всегда обходит подавление.
$InventoryMailDuplicateSuppressionHours = 72
$InventoryMailEventHistoryDays = 30
$InventoryMailEventHistoryMaxItems = 200
$InventoryMailQueueRetentionDays = 30
$InventoryMailQueueMaxItems = 200
$InventoryLogRetentionDays = 30
$InventoryLogRetentionRuns = 60

# Если Snipe-IT недоступен несколько полных запусков подряд, агент отправляет
# подписанный JSON в служебный ящик. IMAP collector на сервере применяет его
# через локальный API. По умолчанию письмо отправляется в ящик SMTP-пользователя.
$InventoryRelayEnabled = $true
$InventoryRelayFailureThreshold = 1
$InventoryRelayMailTo = ""
$InventoryRelayHmacSecret = ""
$InventoryRelaySubjectPrefix = "[SNIPEIT-INVENTORY] RELAY:"

# Если последний интерактивный вход выполнен такой учеткой, ПК считается возвращенным на склад.
$InventoryStockUsernamePatterns = @(
    '^ad_'
)

# Агент читает AD напрямую через LDAP (RSAT на клиенте не нужен). Только disabled
# переводит актив на склад; description/OU сохраняются как подтверждающие признаки.
# Ошибка или недоступность AD сама по себе никогда не является основанием для checkin.
$InventoryAdLookupEnabled = $true
$InventoryAdLookupTimeoutSeconds = 10
$InventoryTerminatedDescriptionPattern = '(?i)увол'
$InventoryTerminatedOuPatterns = @(
    '(?i)(?:^|,)OU=[^,]*увол[^,]*(?:,|$)'
)
$InventoryTreatDisabledAdUserAsTerminated = $true
$InventoryCheckinIfSnipeUserMissing = $true

# Эти логины не считаются владельцами ПК. Это важно для ручного запуска от админа:
# актив не должен перепривязываться на ad_* / administrator.
$InventoryExcludedUsernamePatterns = @(
    '^ad_',
    '^admin$',
    '^administrator$',
    '^администратор$',
    '^svc[_\.-]',
    '^service[_\.-]',
    '^defaultuser\d*$',
    '^defaultaccount$',
    '^wdagutilityaccount$',
    '^guest$',
    '^гость$',
    '^transcom$'
)

$InventoryPreferredDomains = @("EXAMPLE", "EXAMPLE")
$InventoryInvalidSerialNumberPatterns = @(
    '^(?i:0+)$',
    '^(?i:to be filled by o\.e\.m\.|default string|system serial number|none|null|n/a|not applicable|unknown|serial number|chassis serial number)$'
)

# Optional override files. Keep machine/site specific secrets out of the main script when possible.
$LoadedInventoryConfigPaths = @()
$InventoryConfigurableVariables = @(
    "SmtpServer",
    "SmtpPort",
    "UseSsl",
    "SmtpUser",
    "SmtpPass",
    "MailFrom",
    "MailTo",
    "SnipeEnabled",
    "SnipeUrl",
    "SnipeToken",
    "SnipeIgnoreSslCertificateErrors",
    "SnipeApiUserAgent",
    "SnipeApiFallbackToCurl",
    "SnipeFallbackUrls",
    "SnipeApiFallbackToSsh",
    "SnipeApiSshLocalUrls",
    "SnipeDefaultStatusId",
    "SnipeStockStatusId",
    "SnipeDefaultCategoryId",
    "SnipeDefaultManufacturerId",
    "SnipeDefaultFieldsetId",
    "SnipeCustomFieldRam",
    "SnipeCustomFieldCpu",
    "SnipeCustomFieldOs",
    "SnipeCustomFieldStorage",
    "SnipeCustomFieldAgentVersion",
    "SnipeCustomFieldLastSuccess",
    "SnipeCustomFieldLastError",
    "SnipeAutoCreateModel",
    "SnipeAutoCheckout",
    "SnipeCheckinBeforeReassign",
    "SnipeSetDefaultStatusOnUpdate",
    "RunLdapSyncBeforeSnipeSearch",
    "RunLdapSyncIfUserMissing",
    "SnipeSshHost",
    "SnipeSshUser",
    "SnipeSshKeyPath",
    "SnipeSshPassword",
    "SnipeLdapSyncCommand",
    "PauseAtEnd",
    "InventoryIntervalDays",
    "InventoryStatePathOverride",
    "InventoryLogDirOverride",
    "InventoryEnableLegacyUsernameAliases",
    "InventoryUsernameAliases",
    "SendEmailReport",
    "SendEmailOnUserChange",
    "SendEmailOnSnipeUserChange",
    "SendEmailOnStockCheckin",
    "SendEmailOnWarning",
    "SendEmailOnError",
    "InventoryMailQueueWarningItems",
    "InventoryMailSendBatchSize",
    "InventoryMailDuplicateSuppressionHours",
    "InventoryMailEventHistoryDays",
    "InventoryMailEventHistoryMaxItems",
    "InventoryMailQueueRetentionDays",
    "InventoryMailQueueMaxItems",
    "InventoryLogRetentionDays",
    "InventoryLogRetentionRuns",
    "InventoryRelayEnabled",
    "InventoryRelayFailureThreshold",
    "InventoryRelayMailTo",
    "InventoryRelayHmacSecret",
    "InventoryRelaySubjectPrefix",
    "InventoryStockUsernamePatterns",
    "InventoryAdLookupEnabled",
    "InventoryAdLookupTimeoutSeconds",
    "InventoryTerminatedDescriptionPattern",
    "InventoryTerminatedOuPatterns",
    "InventoryTreatDisabledAdUserAsTerminated",
    "InventoryCheckinIfSnipeUserMissing",
    "InventoryExcludedUsernamePatterns",
    "InventoryPreferredDomains",
    "InventoryInvalidSerialNumberPatterns"
)

function Get-ScriptRootSafe {
    if (-not [string]::IsNullOrWhiteSpace($PSScriptRoot)) { return $PSScriptRoot }
    if (-not [string]::IsNullOrWhiteSpace($PSCommandPath)) { return (Split-Path -Parent $PSCommandPath) }
    return (Get-Location).Path
}

function Import-InventoryConfigFile {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -ErrorAction SilentlyContinue)) { return }

    try {
        $config = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($name in $InventoryConfigurableVariables) {
            $property = $config.PSObject.Properties[$name]
            if ($property) {
                Set-Variable -Name $name -Scope Script -Value $property.Value
            }
        }
        $script:LoadedInventoryConfigPaths += $Path
    }
    catch {
        throw "Не удалось прочитать inventory config '$Path': $($_.Exception.Message)"
    }
}

function Import-InventoryEnvironmentOverrides {
    $envMap = @{
        "SNIPEIT_URL"          = "SnipeUrl"
        "SNIPEIT_API_TOKEN"    = "SnipeToken"
        "SNIPEIT_SMTP_USER"    = "SmtpUser"
        "SNIPEIT_SMTP_PASS"    = "SmtpPass"
        "SNIPEIT_MAIL_FROM"    = "MailFrom"
        "SNIPEIT_MAIL_TO"      = "MailTo"
        "SNIPEIT_SSH_HOST"     = "SnipeSshHost"
        "SNIPEIT_SSH_USER"     = "SnipeSshUser"
        "SNIPEIT_SSH_KEY_PATH" = "SnipeSshKeyPath"
        "SNIPEIT_SSH_PASSWORD" = "SnipeSshPassword"
    }

    foreach ($envName in $envMap.Keys) {
        $value = [Environment]::GetEnvironmentVariable($envName, "Process")
        if ([string]::IsNullOrWhiteSpace($value)) {
            $value = [Environment]::GetEnvironmentVariable($envName, "Machine")
        }
        if (-not [string]::IsNullOrWhiteSpace($value)) {
            Set-Variable -Name $envMap[$envName] -Scope Script -Value $value
        }
    }
}

function Import-InventoryConfiguration {
    $scriptRoot = Get-ScriptRootSafe
    $paths = @(
        (Join-Path $scriptRoot "snipeit_inventory.config.json"),
        (Join-Path $scriptRoot "snipeit_inventory.local.json")
    )

    if (-not [string]::IsNullOrWhiteSpace($env:ProgramData)) {
        $paths += (Join-Path $env:ProgramData "snipeit_auto\snipeit_inventory.config.json")
        $paths += (Join-Path $env:ProgramData "snipeit_auto\snipeit_inventory.local.json")
        $paths += (Join-Path $env:ProgramData "snipeit_auto\Config\snipeit_inventory.config.json")
        $paths += (Join-Path $env:ProgramData "snipeit_auto\Config\snipeit_inventory.local.json")
    }

    foreach ($path in ($paths | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)) {
        Import-InventoryConfigFile -Path $path
    }
    Import-InventoryEnvironmentOverrides
}

Import-InventoryConfiguration

if ([string]$InventoryRelaySubjectPrefix -eq "[SNIPEIT-RELAY]") {
    $InventoryRelaySubjectPrefix = "[SNIPEIT-INVENTORY] RELAY:"
}

# These Windows/service logins must never become asset owners, including when
# an older protected config replaces the default pattern array wholesale.
$InventoryExcludedUsernamePatterns = @(
    @($InventoryExcludedUsernamePatterns) + @(
        '^defaultuser\d*$',
        '^defaultaccount$',
        '^wdagutilityaccount$',
        '^guest$',
        '^гость$',
        '^transcom$'
    ) |
        Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } |
        Select-Object -Unique
)

if ([string]::IsNullOrWhiteSpace($InventoryRelayMailTo)) {
    $InventoryRelayMailTo = $SmtpUser
}
if ([string]::IsNullOrWhiteSpace($InventoryRelayHmacSecret)) {
    $InventoryRelayHmacSecret = $SmtpPass
}

# ==========================
# ЛОГ
# ==========================
function Invoke-InventoryHistoryLogRetention {
    param(
        [AllowNull()][string]$Path,
        [int]$RetentionDays = 30,
        [int]$MaxRuns = 60
    )

    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return 0
    }

    try {
        $content = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
        if ([string]::IsNullOrWhiteSpace($content)) { return 0 }

        $blocks = @([regex]::Split(
            $content,
            '(?m)(?=^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2} \| ==== START ====\s*$)'
        ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        if ($blocks.Count -eq 0) { return 0 }

        $cutoff = (Get-Date).AddDays(-[Math]::Max(1, $RetentionDays))
        $kept = @($blocks | Where-Object {
            $firstLine = ([string]$_ -split "`r?`n", 2)[0]
            $timestamp = [datetime]::MinValue
            if ($firstLine.Length -ge 19) {
                [void][datetime]::TryParseExact(
                    $firstLine.Substring(0, 19),
                    'yyyy-MM-dd HH:mm:ss',
                    [System.Globalization.CultureInfo]::InvariantCulture,
                    [System.Globalization.DateTimeStyles]::None,
                    [ref]$timestamp
                )
            }
            $timestamp -eq [datetime]::MinValue -or $timestamp -ge $cutoff
        })

        if ($MaxRuns -gt 0 -and $kept.Count -gt $MaxRuns) {
            $kept = @($kept | Select-Object -Last $MaxRuns)
        }
        $removed = $blocks.Count - $kept.Count
        if ($removed -le 0) { return 0 }

        $tempPath = "$Path.retention-$([guid]::NewGuid().ToString('N')).tmp"
        [System.IO.File]::WriteAllText(
            $tempPath,
            (($kept -join '').TrimStart("`r", "`n") + "`r`n"),
            (New-Object System.Text.UTF8Encoding($true))
        )
        Move-Item -LiteralPath $tempPath -Destination $Path -Force
        Remove-Item -LiteralPath "$Path.old" -Force -ErrorAction SilentlyContinue
        return $removed
    }
    catch {
        return 0
    }
}

function Get-SafeTempRoot {
    $candidates = @(
        $env:TEMP,
        $env:TMP,
        [System.IO.Path]::GetTempPath()
    )

    if (-not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
        $candidates += (Join-Path $env:LOCALAPPDATA "Temp")
    }
    if (-not [string]::IsNullOrWhiteSpace($env:ProgramData)) {
        $candidates += (Join-Path $env:ProgramData "snipeit_auto\Temp")
    }
    if (-not [string]::IsNullOrWhiteSpace($env:SystemRoot)) {
        $candidates += (Join-Path $env:SystemRoot "Temp")
    }

    foreach ($candidate in ($candidates | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)) {
        try {
            New-Item -ItemType Directory -Path $candidate -Force -ErrorAction Stop | Out-Null
            return ([System.IO.Path]::GetFullPath($candidate)).TrimEnd('\')
        }
        catch {}
    }

    throw "Не удалось найти доступную временную папку для логов/отчета."
}

$TempRoot = Get-SafeTempRoot
$LogDir  = Join-Path $TempRoot "SnipeIT Inventory"
$LogFile = Join-Path $LogDir "last_run.log"

function Get-ProgramDataInventoryLogDir {
    if (-not [string]::IsNullOrWhiteSpace($InventoryLogDirOverride)) {
        return ([System.IO.Path]::GetFullPath($InventoryLogDirOverride)).TrimEnd('\')
    }
    if (-not [string]::IsNullOrWhiteSpace($env:ProgramData)) {
        return (Join-Path $env:ProgramData "snipeit_auto\Logs")
    }
    return $null
}

$ProgramDataLogDir = Get-ProgramDataInventoryLogDir
$ProgramDataLastRunLogFile = $null
$ProgramDataHistoryLogFile = $null
if (-not [string]::IsNullOrWhiteSpace($ProgramDataLogDir)) {
    $ProgramDataLastRunLogFile = Join-Path $ProgramDataLogDir "last_run.log"
    $ProgramDataHistoryLogFile = Join-Path $ProgramDataLogDir "inventory-agent.log"
}

try {
    New-Item -ItemType Directory -Path $LogDir -Force -ErrorAction Stop | Out-Null
    if (Test-Path -LiteralPath $LogFile) {
        Remove-Item -LiteralPath $LogFile -Force -ErrorAction Stop
    }
}
catch {
    Write-Warning "Не удалось подготовить лог $LogFile : $($_.Exception.Message)"
}

try {
    if (-not [string]::IsNullOrWhiteSpace($ProgramDataLogDir)) {
        New-Item -ItemType Directory -Path $ProgramDataLogDir -Force -ErrorAction Stop | Out-Null
        if (Test-Path -LiteralPath $ProgramDataLastRunLogFile) {
            Remove-Item -LiteralPath $ProgramDataLastRunLogFile -Force -ErrorAction Stop
        }
    }
}
catch {
    Write-Warning "Не удалось подготовить ProgramData лог $ProgramDataLogDir : $($_.Exception.Message)"
    $ProgramDataLastRunLogFile = $null
    $ProgramDataHistoryLogFile = $null
}

# GPO mode: quiet, no pause, no mail by default
if ($GpoMode) {
    $PauseAtEnd = $false
}

function Protect-LogMessage {
    param([AllowNull()][string]$Message)

    $text = [string]$Message
    foreach ($secret in @($SnipeToken, $SmtpPass, $SnipeSshPassword, $InventoryRelayHmacSecret)) {
        if (-not [string]::IsNullOrWhiteSpace($secret) -and $secret.Length -ge 8) {
            $text = $text.Replace($secret, "***")
        }
    }
    return $text
}

function Write-Log {
    param([string]$Message)

    $safeMessage = Protect-LogMessage -Message $Message
    $line = "{0} | {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $safeMessage
    $targets = @(
        $LogFile,
        $ProgramDataLastRunLogFile,
        $ProgramDataHistoryLogFile
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique

    foreach ($target in $targets) {
        $written = $false
        for ($i = 1; $i -le 5 -and -not $written; $i++) {
            try {
                Add-Content -LiteralPath $target -Value $line -Encoding UTF8 -ErrorAction Stop
                $written = $true
            }
            catch {
                Start-Sleep -Milliseconds (100 * $i)
            }
        }
    }
    if (-not $GpoMode) { Write-Host $line }
}

function Write-DryRunAction {
    param(
        [Parameter(Mandatory=$true)][string]$Action,
        [AllowNull()][string]$Reason = "",
        [AllowNull()][string]$DetectedUsername = ""
    )

    $parts = @("DRY RUN: Would $Action")
    if (-not [string]::IsNullOrWhiteSpace($Reason)) { $parts += "Reason=$Reason" }
    if (-not [string]::IsNullOrWhiteSpace($DetectedUsername)) { $parts += "Detected=$DetectedUsername" }
    Write-Log ($parts -join " | ")
}

if ($LoadedInventoryConfigPaths.Count -gt 0) {
    Write-Log "Config loaded: $($LoadedInventoryConfigPaths -join '; ')"
}

function Get-StateFilePath {
    if (-not [string]::IsNullOrWhiteSpace($InventoryStatePathOverride)) {
        try {
            $overridePath = [System.IO.Path]::GetFullPath($InventoryStatePathOverride)
            $overrideDir = Split-Path -Path $overridePath -Parent
            if (-not [string]::IsNullOrWhiteSpace($overrideDir)) {
                New-Item -ItemType Directory -Path $overrideDir -Force -ErrorAction Stop | Out-Null
            }
            return $overridePath
        }
        catch {
            Write-Log "State: не удалось использовать InventoryStatePathOverride='$InventoryStatePathOverride'"
            Write-Log (Get-ExceptionText $_.Exception)
        }
    }

    $preferredDir = Join-Path $env:ProgramData "snipeit_auto\State"
    $fallbackDir = $LogDir

    try {
        New-Item -ItemType Directory -Path $preferredDir -Force -ErrorAction Stop | Out-Null
        $testFile = Join-Path $preferredDir ".write-test"
        Set-Content -Path $testFile -Value "ok" -Encoding UTF8 -ErrorAction Stop
        Remove-Item -Path $testFile -Force -ErrorAction SilentlyContinue
        return (Join-Path $preferredDir "inventory-state.json")
    }
    catch {
        Write-Log "State: нет прав на $preferredDir, использую $fallbackDir"
        return (Join-Path $fallbackDir "inventory-state.json")
    }
}

function Get-InventoryState {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }

    try {
        return (Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json)
    }
    catch {
        Write-Log "State: не удалось прочитать $Path, начинаю как первый запуск."
        return $null
    }
}

function Save-InventoryState {
    param(
        [string]$Path,
        [object]$State
    )

    if ($DryRun) {
        Write-DryRunAction -Action "save inventory state to '$Path'"
        return $true
    }

    $tempPath = "$Path.tmp"
    try {
        $dir = Split-Path -Path $Path -Parent
        New-Item -ItemType Directory -Path $dir -Force -ErrorAction Stop | Out-Null
        $State | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $tempPath -Encoding UTF8 -ErrorAction Stop
        Move-Item -LiteralPath $tempPath -Destination $Path -Force -ErrorAction Stop
        Write-Log "State: сохранено $Path"
        return $true
    }
    catch {
        Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
        Write-Log "State: не удалось сохранить $Path"
        Write-Log (Get-ExceptionText $_.Exception)
        return $false
    }
}

function ConvertTo-InventoryStateMap {
    param([object]$State)

    $result = [ordered]@{}
    if ($null -ne $State) {
        foreach ($property in $State.PSObject.Properties) {
            $result[$property.Name] = $property.Value
        }
    }
    return $result
}

function Get-PendingMailQueue {
    param([object]$State)

    if ($null -eq $State -or -not $State.PSObject.Properties["pending_mails"]) {
        return @()
    }
    return @($State.pending_mails | Where-Object { $null -ne $_ -and -not [string]::IsNullOrWhiteSpace([string]$_.id) })
}

function Limit-PendingInventoryMailQueue {
    param(
        [AllowNull()][array]$Queue,
        [datetime]$Now = (Get-Date)
    )

    $items = @($Queue | Where-Object { $null -ne $_ -and -not [string]::IsNullOrWhiteSpace([string]$_.id) })
    if ([int]$InventoryMailQueueRetentionDays -gt 0) {
        $cutoff = $Now.AddDays(-[int]$InventoryMailQueueRetentionDays)
        $items = @($items | Where-Object {
            try { ([datetime]$_.created_at) -ge $cutoff }
            catch { $false }
        })
    }

    if ([int]$InventoryMailQueueMaxItems -gt 0 -and $items.Count -gt [int]$InventoryMailQueueMaxItems) {
        $relayItems = @($items | Where-Object { [string]$_.reason -eq 'snipeit_relay' } |
            Sort-Object { try { [datetime]$_.created_at } catch { [datetime]::MinValue } } -Descending)
        $regularItems = @($items | Where-Object { [string]$_.reason -ne 'snipeit_relay' } |
            Sort-Object { try { [datetime]$_.created_at } catch { [datetime]::MinValue } } -Descending)
        $items = @(@($relayItems) + @($regularItems) | Select-Object -First ([int]$InventoryMailQueueMaxItems))
    }
    return @($items)
}

function Format-InventoryDisplayTimestamp {
    param([AllowNull()][string]$Timestamp)

    if ([string]::IsNullOrWhiteSpace($Timestamp)) { return "" }

    try {
        $parsed = [datetimeoffset]::Parse(
            $Timestamp,
            [System.Globalization.CultureInfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::AllowWhiteSpaces
        )
        return $parsed.ToString(
            "HH:mm dd.MM.yyyy",
            [System.Globalization.CultureInfo]::InvariantCulture
        )
    }
    catch {
        return $Timestamp
    }
}

function Format-InventoryNotesTimestamp {
    param(
        [AllowNull()][string]$Timestamp,
        [AllowNull()][string]$Fallback = ""
    )

    if (-not [string]::IsNullOrWhiteSpace($Timestamp)) {
        try {
            $parsed = [datetimeoffset]::Parse(
                $Timestamp,
                [System.Globalization.CultureInfo]::InvariantCulture,
                [System.Globalization.DateTimeStyles]::AllowWhiteSpaces
            )
            return $parsed.ToString(
                "dd.MM.yyyy HH:mm:ss",
                [System.Globalization.CultureInfo]::InvariantCulture
            )
        }
        catch {}
    }

    return [string]$Fallback
}

function Get-InventoryMailEventHistory {
    param([object]$State)

    if ($null -eq $State -or -not $State.PSObject.Properties["mail_event_history"]) {
        return @()
    }
    return @($State.mail_event_history | Where-Object {
        $null -ne $_ -and -not [string]::IsNullOrWhiteSpace([string]$_.event_key)
    })
}

function Test-InventoryMailEventSuppressed {
    param(
        [AllowNull()][array]$History,
        [string]$EventKey,
        [datetime]$Now = (Get-Date)
    )

    if ([int]$InventoryMailDuplicateSuppressionHours -le 0 -or [string]::IsNullOrWhiteSpace($EventKey)) {
        return $false
    }

    $entry = @($History | Where-Object { [string]$_.event_key -eq $EventKey } | Select-Object -First 1)
    if ($entry.Count -eq 0) { return $false }

    $timestampText = [string]$entry[0].last_sent_at
    if ([string]::IsNullOrWhiteSpace($timestampText)) {
        $timestampText = [string]$entry[0].last_queued_at
    }
    if ([string]::IsNullOrWhiteSpace($timestampText)) { return $false }

    try {
        $timestamp = [datetime]$timestampText
        return (($Now - $timestamp).TotalHours -lt [int]$InventoryMailDuplicateSuppressionHours)
    }
    catch {
        return $false
    }
}

function Update-InventoryMailEventHistory {
    param(
        [AllowNull()][array]$History,
        [string]$EventKey,
        [string]$Subject,
        [ValidateSet("queued", "sent")][string]$Event,
        [datetime]$Timestamp = (Get-Date)
    )

    if ([string]::IsNullOrWhiteSpace($EventKey)) { return @($History) }

    $existing = @($History | Where-Object { [string]$_.event_key -eq $EventKey } | Select-Object -First 1)
    $timestampText = $Timestamp.ToString("o")
    $firstSeenAt = $timestampText
    $lastQueuedAt = $null
    $lastSentAt = $null
    if ($existing.Count -gt 0) {
        if (-not [string]::IsNullOrWhiteSpace([string]$existing[0].first_seen_at)) {
            $firstSeenAt = [string]$existing[0].first_seen_at
        }
        $lastQueuedAt = $existing[0].last_queued_at
        $lastSentAt = $existing[0].last_sent_at
        if ([string]::IsNullOrWhiteSpace($Subject)) { $Subject = [string]$existing[0].subject }
    }
    if ($Event -eq "queued") { $lastQueuedAt = $timestampText }
    if ($Event -eq "sent") { $lastSentAt = $timestampText }

    $updatedEntry = [PSCustomObject]@{
        event_key      = $EventKey
        subject        = $Subject
        first_seen_at  = $firstSeenAt
        last_queued_at = $lastQueuedAt
        last_sent_at   = $lastSentAt
        updated_at     = $timestampText
    }

    $result = @($History | Where-Object { [string]$_.event_key -ne $EventKey }) + $updatedEntry
    if ([int]$InventoryMailEventHistoryDays -gt 0) {
        $cutoff = $Timestamp.AddDays(-[int]$InventoryMailEventHistoryDays)
        $result = @($result | Where-Object {
            try { ([datetime]$_.updated_at) -ge $cutoff }
            catch { $false }
        })
    }
    if ([int]$InventoryMailEventHistoryMaxItems -gt 0) {
        $result = @($result | Sort-Object { try { [datetime]$_.updated_at } catch { [datetime]::MinValue } } -Descending |
            Select-Object -First ([int]$InventoryMailEventHistoryMaxItems))
    }
    return $result
}

function Save-InventoryStateSnapshot {
    param(
        [string]$Path,
        [System.Collections.IDictionary]$State,
        [object[]]$PendingMails = @()
    )

    if ($DryRun) {
        return $true
    }

    $existingSchemaVersion = 0
    if ($State.Contains("schema_version")) {
        try { $existingSchemaVersion = [int]$State["schema_version"] } catch { $existingSchemaVersion = 0 }
    }
    if ($existingSchemaVersion -gt [int]$InventoryStateSchemaVersion) {
        Write-Log "State: сохранение заблокировано, файл использует будущую schema_version=$existingSchemaVersion, агент поддерживает $InventoryStateSchemaVersion."
        return $false
    }

    $queue = @($PendingMails)
    $State["schema_version"] = [int]$InventoryStateSchemaVersion
    $State["agent_version"] = $InventoryAgentVersion
    $State["last_agent_run_time"] = (Get-Date).ToString("o")
    $State["pending_mail"] = ($queue.Count -gt 0)
    $State["pending_mail_count"] = $queue.Count
    $State["pending_mails"] = [object[]]$queue
    return (Save-InventoryState -Path $Path -State ([PSCustomObject]$State))
}

function Get-StringSha256 {
    param([AllowNull()][string]$Value)

    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes([string]$Value)
        return (($sha.ComputeHash($bytes) | ForEach-Object { $_.ToString("x2") }) -join "")
    }
    finally {
        $sha.Dispose()
    }
}

function Get-BytesHmacSha256 {
    param(
        [Parameter(Mandatory=$true)][byte[]]$Bytes,
        [Parameter(Mandatory=$true)][string]$Secret
    )

    if ([string]::IsNullOrWhiteSpace($Secret)) {
        throw "Inventory relay HMAC secret is empty."
    }

    $hmac = New-Object System.Security.Cryptography.HMACSHA256
    try {
        $hmac.Key = [System.Text.Encoding]::UTF8.GetBytes($Secret)
        return (($hmac.ComputeHash($Bytes) | ForEach-Object { $_.ToString("x2") }) -join "")
    }
    finally {
        $hmac.Dispose()
    }
}

function New-SnipeRelayEnvelope {
    param(
        [Parameter(Mandatory=$true)][System.Collections.IDictionary]$Payload,
        [Parameter(Mandatory=$true)][string]$HmacSecret
    )

    $payloadJson = ([PSCustomObject]$Payload | ConvertTo-Json -Depth 15 -Compress)
    $payloadBytes = [System.Text.Encoding]::UTF8.GetBytes($payloadJson)
    $wrapper = [ordered]@{
        envelope_schema = "snipeit.inventory.relay/v1"
        schema_version  = 1
        payload_encoding = "base64-json-utf8"
        payload          = [Convert]::ToBase64String($payloadBytes)
        hmac_sha256      = Get-BytesHmacSha256 -Bytes $payloadBytes -Secret $HmacSecret
    }

    return [PSCustomObject]@{
        EventId     = [string]$Payload["event_id"]
        PayloadJson = $payloadJson
        EnvelopeJson = ([PSCustomObject]$wrapper | ConvertTo-Json -Depth 6 -Compress)
    }
}

function New-SnipeRelayMailEntry {
    param(
        [Parameter(Mandatory=$true)][System.Collections.IDictionary]$Payload
    )

    if (-not $InventoryRelayEnabled) { return $null }
    if ([string]::IsNullOrWhiteSpace($InventoryRelayMailTo)) {
        throw "Inventory relay is enabled, but InventoryRelayMailTo is empty."
    }
    if ([string]::IsNullOrWhiteSpace($InventoryRelayHmacSecret)) {
        throw "Inventory relay is enabled, but InventoryRelayHmacSecret and SmtpPass are empty."
    }

    $envelope = New-SnipeRelayEnvelope -Payload $Payload -HmacSecret $InventoryRelayHmacSecret
    $eventId = [string]$envelope.EventId
    $computerName = [string]$Payload["computer_name"]
    $shortEventId = if ($eventId.Length -gt 16) { $eventId.Substring(0, 16) } else { $eventId }

    return [PSCustomObject]@{
        id              = "relay-$eventId"
        event_key       = "relay:$eventId"
        created_at      = (Get-Date).ToString("o")
        reason          = "snipeit_relay"
        to              = $InventoryRelayMailTo
        subject         = "$InventoryRelaySubjectPrefix $computerName $shortEventId"
        body            = "<html><body><h2>SnipeIT Inventory Relay</h2><p><b>Computer:</b> $(Enc $computerName)</p><p><b>Event:</b> $(Enc $eventId)</p><p><b>snipeit_avail:</b> no</p></body></html>"
        attachment_name = "$computerName-$shortEventId.snipeit-relay.json"
        attachment_text = [string]$envelope.EnvelopeJson
        headers          = [PSCustomObject]@{
            "X-SnipeIT-Relay"    = "1"
            "X-SnipeIT-Avail"    = "no"
            "X-SnipeIT-Event-ID" = $eventId
        }
        attempt_count   = 0
        last_attempt_at = $null
        last_error      = ""
    }
}

function Limit-InventoryText {
    param(
        [AllowNull()][string]$Value,
        [int]$MaxLength = 2000
    )

    $text = [string]$Value
    if ($text.Length -le $MaxLength) { return $text }
    return ($text.Substring(0, $MaxLength) + "...")
}

function Initialize-SnipeHttps {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    if ($SnipeIgnoreSslCertificateErrors) {
        if (-not ("TrustAllCertsPolicy" -as [type])) {
            Add-Type @"
using System.Net;
using System.Security.Cryptography.X509Certificates;

public class TrustAllCertsPolicy : ICertificatePolicy
{
    public bool CheckValidationResult(
        ServicePoint srvPoint,
        X509Certificate certificate,
        WebRequest request,
        int certificateProblem)
    {
        return true;
    }
}
"@
        }

        [System.Net.ServicePointManager]::CertificatePolicy = New-Object TrustAllCertsPolicy
        Write-Log "Snipe-IT HTTPS: certificate validation disabled for this PowerShell process."
    }
}

function Get-EffectiveSnipeSshKeyPath {
    if ([string]::IsNullOrWhiteSpace($SnipeSshKeyPath)) { return $null }

    try {
        $effectiveKeyPath = [System.IO.Path]::GetFullPath(
            [Environment]::ExpandEnvironmentVariables([string]$SnipeSshKeyPath)
        )
    }
    catch {
        Write-Log "LDAP sync: некорректный путь SSH-ключа в закрытом конфиге."
        return $null
    }

    if (-not (Test-Path -LiteralPath $effectiveKeyPath -PathType Leaf)) {
        return $null
    }

    # До 1.3.3 агент создавал копию ключа в LOCALAPPDATA текущего контекста.
    # Новая схема использует только защищенный файл из ProgramData\...\Config.
    if (-not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
        $legacyLocalKey = Join-Path $env:LOCALAPPDATA "snipeit_auto\snipeit_ldap_sync_ed25519"
        if (-not $legacyLocalKey.Equals($effectiveKeyPath, [System.StringComparison]::OrdinalIgnoreCase) -and
            (Test-Path -LiteralPath $legacyLocalKey -PathType Leaf)) {
            try {
                Remove-Item -LiteralPath $legacyLocalKey -Force -ErrorAction Stop
                Write-Log "LDAP sync: удалена устаревшая локальная копия SSH-ключа."
            }
            catch {
                Write-Log "LDAP sync: не удалось удалить устаревшую локальную копию SSH-ключа."
            }
        }
    }

    try {
        $stream = [System.IO.File]::Open(
            $effectiveKeyPath,
            [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read,
            [System.IO.FileShare]::Read
        )
        $stream.Dispose()
    }
    catch {
        Write-Log "LDAP sync: защищенный SSH-ключ найден, но недоступен для чтения."
        return $null
    }

    return $effectiveKeyPath
}

function Enc {
    param([object]$Value)
    if ($null -eq $Value) { return "" }
    return [System.Net.WebUtility]::HtmlEncode([string]$Value)
}

function Get-ExceptionText {
    param($Exception)
    $items = @()
    $ex = $Exception
    while ($ex) {
        $items += "$($ex.GetType().FullName): $($ex.Message)"
        $ex = $ex.InnerException
    }
    return ($items -join "`r`n")
}

function Send-QueuedInventoryMail {
    param([Parameter(Mandatory=$true)][object]$Entry)

    if ($DryRun) {
        Write-DryRunAction -Action "send queued email id=$($Entry.id) subject='$($Entry.subject)'" -Reason ([string]$Entry.reason)
        return $true
    }

    $mail = $null
    $smtp = $null
    $attachment = $null
    $attachmentPath = $null

    try {
        $queueTempDir = Join-Path $TempRoot "SnipeIT Inventory\MailQueue"
        New-Item -ItemType Directory -Path $queueTempDir -Force -ErrorAction Stop | Out-Null
        $safeId = ([string]$Entry.id -replace '[^a-zA-Z0-9_-]', '_')
        $attachmentExtension = [System.IO.Path]::GetExtension([string]$Entry.attachment_name)
        if ($attachmentExtension -notin @(".txt", ".json")) { $attachmentExtension = ".txt" }
        $attachmentPath = Join-Path $queueTempDir "$safeId$attachmentExtension"
        Set-Content -LiteralPath $attachmentPath -Value ([string]$Entry.attachment_text) -Encoding UTF8 -ErrorAction Stop

        $securePass = ConvertTo-SecureString $SmtpPass -AsPlainText -Force
        $credential = New-Object System.Management.Automation.PSCredential ($SmtpUser, $securePass)

        $mail = New-Object System.Net.Mail.MailMessage
        $mail.From = New-Object -TypeName System.Net.Mail.MailAddress -ArgumentList $MailFrom
        $targetMailTo = if ($Entry.PSObject.Properties["to"] -and -not [string]::IsNullOrWhiteSpace([string]$Entry.to)) {
            [string]$Entry.to
        }
        else {
            $MailTo
        }
        $mail.To.Add($targetMailTo)
        $mail.Subject = [string]$Entry.subject
        $mail.SubjectEncoding = [System.Text.Encoding]::UTF8
        $mail.Body = [string]$Entry.body
        $mail.BodyEncoding = [System.Text.Encoding]::UTF8
        $mail.IsBodyHtml = $true

        if ($Entry.PSObject.Properties["headers"] -and $Entry.headers) {
            foreach ($header in $Entry.headers.PSObject.Properties) {
                if (-not [string]::IsNullOrWhiteSpace([string]$header.Name)) {
                    $mail.Headers.Add([string]$header.Name, [string]$header.Value)
                }
            }
        }

        $attachment = New-Object System.Net.Mail.Attachment($attachmentPath)
        if (-not [string]::IsNullOrWhiteSpace([string]$Entry.attachment_name)) {
            $attachment.Name = [string]$Entry.attachment_name
        }
        $mail.Attachments.Add($attachment) | Out-Null

        $smtp = New-Object System.Net.Mail.SmtpClient($SmtpServer, $SmtpPort)
        $smtp.EnableSsl = $UseSsl
        $smtp.Credentials = $credential
        $smtp.DeliveryMethod = [System.Net.Mail.SmtpDeliveryMethod]::Network
        $smtp.Timeout = 30000

        Write-Log "SMTP queue: отправляю id=$($Entry.id) reason=$($Entry.reason) на $targetMailTo через ${SmtpServer}:$SmtpPort"
        $smtp.Send($mail)
        Write-Log "SMTP queue: письмо id=$($Entry.id) отправлено"
        return $true
    }
    finally {
        if ($attachment) { $attachment.Dispose() }
        if ($mail) { $mail.Dispose() }
        if ($smtp) { $smtp.Dispose() }
        if ($attachmentPath) { Remove-Item -LiteralPath $attachmentPath -Force -ErrorAction SilentlyContinue }
    }
}

function Test-SnipeApiNeedsCurlFallback {
    param(
        $Exception,
        [string]$ResponseText
    )

    $text = @(
        (Get-ExceptionText $Exception),
        $ResponseText
    ) -join "`n"

    return ($text -match '(?i)\b499\b|forbidden by antivirus|антивирус')
}

function Get-SnipeApiMessageText {
    param([object]$Response)

    if ($null -eq $Response) { return "" }

    $messageValue = $null
    if ($Response.PSObject.Properties["messages"]) {
        $messageValue = $Response.PSObject.Properties["messages"].Value
    }
    elseif ($Response.PSObject.Properties["message"]) {
        $messageValue = $Response.PSObject.Properties["message"].Value
    }

    if ($null -eq $messageValue) { return "" }
    if ($messageValue -is [string]) { return $messageValue }

    try {
        return ($messageValue | ConvertTo-Json -Depth 10 -Compress)
    }
    catch {
        return ([string]$messageValue)
    }
}

function Assert-SnipeApiSuccess {
    param(
        [object]$Response,
        [string]$Operation
    )

    if ($null -eq $Response) { return $Response }

    $statusProperty = $Response.PSObject.Properties["status"]
    if ($statusProperty) {
        $status = [string]$statusProperty.Value
        if ($status -match '^(?i:error|fail|failed)$') {
            $messageText = Get-SnipeApiMessageText -Response $Response
            if ([string]::IsNullOrWhiteSpace($messageText)) {
                $messageText = ($Response | ConvertTo-Json -Depth 10 -Compress)
            }
            throw "Snipe API returned status=$status for ${Operation}: $messageText"
        }
    }

    return $Response
}

function ConvertTo-FormUrlEncoded {
    param([object]$Body)

    if ($null -eq $Body) { return "" }

    $pairs = @()
    foreach ($property in $Body.GetEnumerator()) {
        if ($null -eq $property.Value) { continue }
        $key = [System.Uri]::EscapeDataString([string]$property.Key)
        $value = [System.Uri]::EscapeDataString([string]$property.Value)
        $pairs += "$key=$value"
    }

    return ($pairs -join "&")
}

function Invoke-SnipeApiWithCurl {
    param(
        [Parameter(Mandatory=$true)][ValidateSet("GET","POST","PATCH","PUT","DELETE")][string]$Method,
        [Parameter(Mandatory=$true)][string]$Uri,
        [string]$RequestBody = $null,
        [string]$ContentType = "application/json"
    )

    $curl = Get-Command curl.exe -ErrorAction SilentlyContinue
    if (-not $curl) {
        throw "curl.exe не найден. Не могу обойти блокировку PowerShell web request антивирусом."
    }

    $responseFile = [System.IO.Path]::GetTempFileName()
    $bodyFile = $null

    try {
        $curlMethod = $Method
        $methodOverrideHeader = $null
        if ($Method -in @("PATCH", "PUT")) {
            $curlMethod = "POST"
            $methodOverrideHeader = "X-HTTP-Method-Override: $Method"
        }

        $args = @(
            "-sS",
            "-L",
            "-X", $curlMethod,
            $Uri,
            "-H", "Authorization: Bearer $SnipeToken",
            "-H", "Accept: application/json",
            "-H", "Content-Type: $ContentType",
            "-H", "User-Agent: $SnipeApiUserAgent",
            "--connect-timeout", "15",
            "--max-time", "120",
            "-o", $responseFile,
            "-w", "`nCURL_HTTP_STATUS:%{http_code}"
        )
        if ($methodOverrideHeader) {
            $args += @("-H", $methodOverrideHeader)
        }

        if ($SnipeIgnoreSslCertificateErrors) {
            $args = @("-k") + $args
        }

        if (-not [string]::IsNullOrWhiteSpace($RequestBody)) {
            $bodyFile = [System.IO.Path]::GetTempFileName()
            $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
            [System.IO.File]::WriteAllText($bodyFile, $RequestBody, $utf8NoBom)
            $args += @("--data-binary", "@$bodyFile")
        }

        $output = @(& $curl.Source @args 2>&1)
        $exitCode = $LASTEXITCODE
        $statusLine = $output | Where-Object { [string]$_ -match '^CURL_HTTP_STATUS:(\d{3})$' } | Select-Object -Last 1
        $statusCode = $null
        if ($statusLine -and ([string]$statusLine -match '^CURL_HTTP_STATUS:(\d{3})$')) {
            $statusCode = [int]$Matches[1]
        }

        $responseText = ""
        if (Test-Path -LiteralPath $responseFile) {
            $responseText = [System.IO.File]::ReadAllText($responseFile)
        }

        if ($exitCode -ne 0) {
            throw "curl.exe завершился с кодом $exitCode. $($output -join "`n")"
        }
        if ($null -eq $statusCode) {
            throw "curl.exe не вернул HTTP status. $($output -join "`n")"
        }
        if ($statusCode -lt 200 -or $statusCode -ge 300) {
            Write-Log "Snipe API curl response: $responseText"
            throw "Snipe API curl ERROR: HTTP $statusCode $Method $Uri"
        }
        if ([string]::IsNullOrWhiteSpace($responseText)) {
            return $null
        }

        return (Assert-SnipeApiSuccess -Response ($responseText | ConvertFrom-Json) -Operation "$Method $Uri")
    }
    finally {
        foreach ($path in @($responseFile, $bodyFile)) {
            if (-not [string]::IsNullOrWhiteSpace($path) -and (Test-Path -LiteralPath $path)) {
                Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
            }
        }
    }
}

function ConvertTo-ShellSingleQuoted {
    param([string]$Value)
    return "'" + ($Value -replace "'", "'\''") + "'"
}

function Invoke-SnipeApiWithSsh {
    param(
        [Parameter(Mandatory=$true)][ValidateSet("GET","POST","PATCH","PUT","DELETE")][string]$Method,
        [Parameter(Mandatory=$true)][string]$Path,
        [string]$RequestBody = $null,
        [string]$ContentType = "application/json"
    )

    $effectiveSshKeyPath = Get-EffectiveSnipeSshKeyPath
    if ([string]::IsNullOrWhiteSpace($effectiveSshKeyPath)) {
        throw "SSH fallback невозможен: SSH-ключ Snipe-IT не найден."
    }

    if ($Path -notmatch '^/') { $Path = "/$Path" }
    $lastSshError = $null

    foreach ($localBase in ($SnipeApiSshLocalUrls | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)) {
        $remoteUri = "$($localBase.TrimEnd('/'))$Path"
        Write-Log "Snipe API SSH fallback: $Method $remoteUri"

        $curlParts = @(
            "curl",
            "-k",
            "-sS",
            "-L",
            "--connect-timeout", "15",
            "--max-time", "120",
            "-X", (ConvertTo-ShellSingleQuoted $Method),
            (ConvertTo-ShellSingleQuoted $remoteUri),
            "-H", (ConvertTo-ShellSingleQuoted "Authorization: Bearer $SnipeToken"),
            "-H", (ConvertTo-ShellSingleQuoted "Accept: application/json"),
            "-H", (ConvertTo-ShellSingleQuoted "Content-Type: $ContentType"),
            "-H", (ConvertTo-ShellSingleQuoted "User-Agent: $SnipeApiUserAgent")
        )

        if (-not [string]::IsNullOrWhiteSpace($RequestBody)) {
            $curlParts += @("--data-binary", (ConvertTo-ShellSingleQuoted $RequestBody))
        }

        $curlParts += @("-w", (ConvertTo-ShellSingleQuoted "`nCURL_HTTP_STATUS:%{http_code}"))
        $remoteCommand = ($curlParts -join " ")

        $sshArgs = @(
            "-o", "StrictHostKeyChecking=no",
            "-o", "BatchMode=yes",
            "-i", $effectiveSshKeyPath,
            "$SnipeSshUser@$SnipeSshHost",
            $remoteCommand
        )

        try {
            $output = @(& ssh @sshArgs 2>&1)
            $exit = $LASTEXITCODE
            $statusLine = $output | Where-Object { [string]$_ -match '^CURL_HTTP_STATUS:(\d{3})$' } | Select-Object -Last 1

            if (-not $statusLine) {
                $text = ($output | ForEach-Object { [string]$_ }) -join "`n"
                Write-Log "Snipe API SSH fallback output: $text"
                throw "SSH fallback не запустил remote curl. Если выше виден LDAPSYNC/ldap-sync, значит SSH-ключ на сервере ограничен forced-command и API через SSH надо разрешить отдельным ключом."
            }

            if ([string]$statusLine -match '^CURL_HTTP_STATUS:(\d{3})$') {
                $statusCode = [int]$Matches[1]
            }
            else {
                throw "SSH fallback не смог прочитать HTTP status."
            }

            $bodyLines = @($output | Where-Object { [string]$_ -notmatch '^CURL_HTTP_STATUS:\d{3}$' })
            $responseText = ($bodyLines | ForEach-Object { [string]$_ }) -join "`n"

            if ($exit -ne 0) {
                throw "SSH curl завершился с кодом $exit. $responseText"
            }
            if ($statusCode -lt 200 -or $statusCode -ge 300) {
                Write-Log "Snipe API SSH response: $responseText"
                throw "Snipe API SSH ERROR: HTTP $statusCode $Method $remoteUri"
            }
            if ([string]::IsNullOrWhiteSpace($responseText)) {
                return $null
            }

            return (Assert-SnipeApiSuccess -Response ($responseText | ConvertFrom-Json) -Operation "$Method $remoteUri")
        }
        catch {
            $lastSshError = $_.Exception
            Write-Log "Snipe API SSH fallback failed: $(Get-ExceptionText $_.Exception)"
            if ($_.Exception.Message -match 'SSH fallback не запустил remote curl') {
                break
            }
        }
    }

    throw $lastSshError
}

function Repair-Utf8Mojibake {
    param([string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return $Text }
    if ($Text -notmatch 'Р.|С.|вЂ|в„|в•|[╨╤]') { return $Text }

    foreach ($codePage in @(1251, 866)) {
        try {
            $bytes = [System.Text.Encoding]::GetEncoding($codePage).GetBytes($Text)
            $repaired = [System.Text.Encoding]::UTF8.GetString($bytes)
            if ($repaired -and $repaired -notmatch '�' -and $repaired -match '[А-Яа-яЁё]' -and $repaired -notmatch 'Р.|С.|вЂ|в„|в•|[╨╤]') {
                return $repaired
            }
        }
        catch {}
    }

    return $Text
}

function Convert-SidToName {
    param([string]$Sid)
    try {
        $sidObj = New-Object System.Security.Principal.SecurityIdentifier($Sid)
        $translated = $sidObj.Translate([System.Security.Principal.NTAccount]).Value
        if (Test-InventoryAccountIdentifier -AccountName $translated) {
            return $translated
        }
    }
    catch {}

    return $null
}

function Get-LogonTypeName {
    param([string]$LogonType)
    switch ($LogonType) {
        "2"  { return "Interactive" }
        "7"  { return "Unlock" }
        "10" { return "RDP" }
        "11" { return "CachedInteractive" }
        default { return $LogonType }
    }
}

function Get-LastUsers {
    $result = @()
    try {
        Write-Log "Читаю Security log..."
        $events = Get-WinEvent -FilterHashtable @{ LogName = "Security"; Id = 4624 } -MaxEvents 5000 -ErrorAction Stop
        foreach ($event in $events) {
            $xml = [xml]$event.ToXml()
            $data = @{}
            foreach ($item in $xml.Event.EventData.Data) { $data[$item.Name] = $item.'#text' }
            $user      = $data["TargetUserName"]
            $domain    = $data["TargetDomainName"]
            $logonType = [string]$data["LogonType"]
            if ([string]::IsNullOrWhiteSpace($domain)) { $domain = $env:COMPUTERNAME }
            $accountName = "$domain\$user"
            if (
                $user -and
                (Test-InventoryAccountIdentifier -AccountName $accountName) -and
                @("2", "7", "10", "11") -contains $logonType
            ) {
                $result += [PSCustomObject]@{
                    User      = $accountName
                    LastLogon = $event.TimeCreated
                    Type      = Get-LogonTypeName $logonType
                    Source    = "Security 4624"
                }
            }
        }
        if ($result.Count -gt 0) {
            $final = $result |
                Group-Object User |
                ForEach-Object { $_.Group | Sort-Object LastLogon -Descending | Select-Object -First 1 } |
                Sort-Object LastLogon -Descending |
                Select-Object -First 3
            Write-Log "Security log OK. Найдено: $(@($final).Count)"
            return @($final)
        }
    }
    catch {
        Write-Log "Security log не прочитан:"
        Write-Log (Get-ExceptionText $_.Exception)
    }

    try {
        Write-Log "Читаю Win32_UserProfile..."
        $profiles = Get-CimInstance Win32_UserProfile -ErrorAction Stop |
            Where-Object { $_.Special -eq $false -and $_.LocalPath -like "C:\Users\*" -and $_.LastUseTime } |
            ForEach-Object {
                $translatedName = Convert-SidToName $_.SID
                if (Test-InventoryAccountIdentifier -AccountName $translatedName) {
                    [PSCustomObject]@{
                        User      = $translatedName
                        LastLogon = $_.LastUseTime
                        Type      = "Profile"
                        Source    = "Win32_UserProfile"
                    }
                }
            } |
            Sort-Object LastLogon -Descending |
            Select-Object -First 3
        Write-Log "Win32_UserProfile OK. Найдено: $(@($profiles).Count)"
        return @($profiles)
    }
    catch {
        Write-Log "Win32_UserProfile ошибка:"
        Write-Log (Get-ExceptionText $_.Exception)
        return @()
    }
}

function Get-InventoryUsername {
    param(
        [string]$CurrentUser,
        [array]$LastUsers
    )

    $candidates = @()
    $preferredDomainsLower = @($InventoryPreferredDomains | ForEach-Object { ([string]$_).ToLowerInvariant() })
    $currentUserIsPreferredDomain = $false

    if ($LastUsers -and $LastUsers.Count -gt 0) {
        $domainUsers = @($LastUsers | Where-Object {
            $userText = [string]$_.User
            if ($userText -notmatch '\\') {
                $false
            }
            else {
                $domain = ($userText -split '\\', 2)[0].ToLowerInvariant()
                $preferredDomainsLower -contains $domain
            }
        } | Select-Object -ExpandProperty User)

        $otherUsers = @($LastUsers | Where-Object {
            $userText = [string]$_.User
            if ($userText -notmatch '\\') {
                $true
            }
            else {
                $domain = ($userText -split '\\', 2)[0].ToLowerInvariant()
                $preferredDomainsLower -notcontains $domain
            }
        } | Select-Object -ExpandProperty User)
    }

    if ($CurrentUser -and $CurrentUser -match '\\') {
        $currentDomain = ($CurrentUser -split '\\', 2)[0].ToLowerInvariant()
        $currentUserIsPreferredDomain = ($preferredDomainsLower -contains $currentDomain)
        if ($currentUserIsPreferredDomain) {
            Write-Log "Username priority: сначала текущий интерактивный пользователь $CurrentUser."
            $candidates += $CurrentUser
        }
    }

    if ($LastUsers -and $LastUsers.Count -gt 0) {
        $candidates += $domainUsers
    }

    if ($LastUsers -and $LastUsers.Count -gt 0) {
        $candidates += $otherUsers
    }

    if ($CurrentUser -and $CurrentUser -match '\\' -and -not $currentUserIsPreferredDomain) {
        $candidates += $CurrentUser
    }

    foreach ($candidate in ($candidates | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)) {
        $login = ($candidate -split '\\')[-1]
        if (-not (Test-InventoryAccountIdentifier -AccountName $candidate)) {
            Write-Log "Username candidate '$candidate' пропущен: это SID, машинная или системная учетная запись."
            continue
        }

        $login = $login.Trim()
        $isExcluded = $false
        foreach ($pattern in $InventoryExcludedUsernamePatterns) {
            if ($login -match $pattern) {
                $isExcluded = $true
                Write-Log "Username '$login' пропущен как админский/служебный по шаблону '$pattern'."
                break
            }
        }

        if (-not $isExcluded) {
            return $login
        }
    }

    Write-Log "Не найден подходящий пользователь для инвентаризации после фильтра админских/служебных учеток."
    return $null
}

function Get-InventoryLoginName {
    param([AllowNull()][string]$AccountName)

    if ([string]::IsNullOrWhiteSpace($AccountName)) { return "" }
    return (($AccountName.Trim() -split '\\')[-1]).Trim()
}

function Test-InventoryAccountIdentifier {
    param([AllowNull()][string]$AccountName)

    if ([string]::IsNullOrWhiteSpace($AccountName)) { return $false }
    $login = (($AccountName.Trim() -split '\\')[-1]).Trim()
    if ([string]::IsNullOrWhiteSpace($login)) { return $false }

    if ($login -match '(?i)^S-\d+-\d+(?:-\d+)+$') { return $false }
    if ($login -match '(?i)^\{?[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\}?$') { return $false }
    if ($login -match '\$$') { return $false }
    if ($login -match '[\x00-\x1f]') { return $false }

    $systemAccounts = @(
        'SYSTEM', 'LOCAL SERVICE', 'NETWORK SERVICE', 'ANONYMOUS LOGON',
        'IUSR', 'LOCAL SYSTEM', 'FONT DRIVER HOST', 'WINDOW MANAGER',
        '.DEFAULT', 'DEFAULTACCOUNT', 'WDAGUTILITYACCOUNT', 'GUEST', 'ГОСТЬ'
    )
    if ($systemAccounts -contains $login.ToUpperInvariant()) { return $false }
    if ($login -match '(?i)^defaultuser\d*$') { return $false }
    if ($login -match '(?i)^(?:DWM|UMFD)-\d+$') { return $false }

    return $true
}

function Test-InventoryUsernameMatchesPatterns {
    param(
        [AllowNull()][string]$Username,
        [AllowNull()][array]$Patterns
    )

    $login = Get-InventoryLoginName -AccountName $Username
    if ([string]::IsNullOrWhiteSpace($login)) { return $false }

    foreach ($pattern in @($Patterns)) {
        if (-not [string]::IsNullOrWhiteSpace([string]$pattern) -and $login -match [string]$pattern) {
            return $true
        }
    }
    return $false
}

function Get-LatestObservedInventoryUser {
    param(
        [AllowNull()][string]$CurrentUser,
        [AllowNull()][array]$LastUsers
    )

    $preferredDomainsLower = @($InventoryPreferredDomains | ForEach-Object { ([string]$_).ToLowerInvariant() })
    if ((Test-InventoryAccountIdentifier -AccountName $CurrentUser) -and $CurrentUser -match '\\') {
        $currentDomain = ($CurrentUser -split '\\', 2)[0].ToLowerInvariant()
        if ($preferredDomainsLower -contains $currentDomain) {
            return [PSCustomObject]@{
                Account   = $CurrentUser
                Login     = Get-InventoryLoginName -AccountName $CurrentUser
                LastLogon = $null
                Source    = "Win32_ComputerSystem.UserName"
            }
        }
    }

    foreach ($entry in @($LastUsers | Sort-Object LastLogon -Descending)) {
        $account = [string]$entry.User
        if (-not (Test-InventoryAccountIdentifier -AccountName $account) -or $account -notmatch '\\') { continue }
        $domain = ($account -split '\\', 2)[0].ToLowerInvariant()
        if ($preferredDomainsLower -notcontains $domain) { continue }

        return [PSCustomObject]@{
            Account   = $account
            Login     = Get-InventoryLoginName -AccountName $account
            LastLogon = $entry.LastLogon
            Source    = [string]$entry.Source
        }
    }

    if (Test-InventoryAccountIdentifier -AccountName $CurrentUser) {
        return [PSCustomObject]@{
            Account   = $CurrentUser
            Login     = Get-InventoryLoginName -AccountName $CurrentUser
            LastLogon = $null
            Source    = "Win32_ComputerSystem.UserName"
        }
    }

    $fallback = @(
        $LastUsers |
            Where-Object { Test-InventoryAccountIdentifier -AccountName ([string]$_.User) } |
            Sort-Object LastLogon -Descending |
            Select-Object -First 1
    )
    if ($fallback.Count -gt 0) {
        return [PSCustomObject]@{
            Account   = [string]$fallback[0].User
            Login     = Get-InventoryLoginName -AccountName ([string]$fallback[0].User)
            LastLogon = $fallback[0].LastLogon
            Source    = [string]$fallback[0].Source
        }
    }

    return [PSCustomObject]@{ Account = ""; Login = ""; LastLogon = $null; Source = "none" }
}

function ConvertTo-LdapFilterValue {
    param([AllowNull()][string]$Value)

    if ($null -eq $Value) { return "" }
    return $Value.Replace('\', '\5c').Replace('*', '\2a').Replace('(', '\28').Replace(')', '\29').Replace([string][char]0, '\00')
}

function Get-AdInventoryTerminationEvaluation {
    param(
        [AllowNull()][string]$Description,
        [AllowNull()][string]$DistinguishedName,
        [int64]$UserAccountControl = 0
    )

    $disabled = (($UserAccountControl -band 2) -eq 2)
    $descriptionMatched = (
        -not [string]::IsNullOrWhiteSpace($InventoryTerminatedDescriptionPattern) -and
        [string]$Description -match $InventoryTerminatedDescriptionPattern
    )
    $ouMatched = $false
    foreach ($pattern in @($InventoryTerminatedOuPatterns)) {
        if (
            -not [string]::IsNullOrWhiteSpace([string]$pattern) -and
            -not [string]::IsNullOrWhiteSpace([string]$DistinguishedName) -and
            [string]$DistinguishedName -match [string]$pattern
        ) {
            $ouMatched = $true
            break
        }
    }
    # Disabled is authoritative. Description and OU are supporting audit signals only.
    $terminated = ($InventoryTreatDisabledAdUserAsTerminated -and $disabled)

    $reasons = @()
    if ($descriptionMatched) { $reasons += "ad_description_terminated" }
    if ($ouMatched) { $reasons += "ad_ou_terminated" }
    if ($InventoryTreatDisabledAdUserAsTerminated -and $disabled) { $reasons += "ad_account_disabled" }

    return [PSCustomObject]@{
        Disabled           = $disabled
        DescriptionMatched = $descriptionMatched
        OuMatched          = $ouMatched
        Terminated         = $terminated
        TerminationReason  = ($reasons -join "+")
    }
}

function Get-AdInventoryUserState {
    param([AllowNull()][array]$Usernames)

    $emptyResult = [ordered]@{
        LookupSucceeded    = $false
        Found              = $false
        Username           = ""
        Disabled           = $false
        DescriptionMatched = $false
        OuMatched          = $false
        Terminated         = $false
        TerminationReason  = ""
        DistinguishedName  = ""
        Error              = ""
    }

    if (-not $InventoryAdLookupEnabled) {
        $emptyResult.Error = "AD lookup disabled"
        return [PSCustomObject]$emptyResult
    }

    $candidates = @(
        $Usernames |
            ForEach-Object { Get-InventoryLoginName -AccountName ([string]$_) } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            Select-Object -Unique
    )
    if ($candidates.Count -eq 0) {
        $emptyResult.Error = "username is empty"
        return [PSCustomObject]$emptyResult
    }

    $rootDse = $null
    $searchRoot = $null
    $searcher = $null
    try {
        $rootDse = New-Object System.DirectoryServices.DirectoryEntry("LDAP://RootDSE")
        $namingContexts = $rootDse.Properties["defaultNamingContext"]
        if ($null -eq $namingContexts -or $namingContexts.Count -eq 0) {
            throw "RootDSE не вернул defaultNamingContext"
        }
        $defaultNamingContext = [string]$namingContexts[0]
        if ([string]::IsNullOrWhiteSpace($defaultNamingContext)) {
            throw "RootDSE не вернул defaultNamingContext"
        }

        $searchRoot = New-Object System.DirectoryServices.DirectoryEntry("LDAP://$defaultNamingContext")
        $searcher = New-Object System.DirectoryServices.DirectorySearcher($searchRoot)
        $loginFilters = @($candidates | ForEach-Object { "(sAMAccountName=$(ConvertTo-LdapFilterValue -Value $_))" })
        $searcher.Filter = "(&(objectCategory=person)(objectClass=user)(|$($loginFilters -join '')))"
        $searcher.SearchScope = [System.DirectoryServices.SearchScope]::Subtree
        $timeoutSeconds = [Math]::Max(1, [int]$InventoryAdLookupTimeoutSeconds)
        $searcher.ClientTimeout = [TimeSpan]::FromSeconds($timeoutSeconds)
        $searcher.ServerTimeLimit = [TimeSpan]::FromSeconds($timeoutSeconds)
        foreach ($propertyName in @("samaccountname", "description", "useraccountcontrol", "distinguishedname")) {
            [void]$searcher.PropertiesToLoad.Add($propertyName)
        }

        $result = $searcher.FindOne()
        $emptyResult.LookupSucceeded = $true
        if ($null -eq $result) {
            return [PSCustomObject]$emptyResult
        }

        $emptyResult.Found = $true
        if ($result.Properties["samaccountname"].Count -gt 0) {
            $emptyResult.Username = [string]$result.Properties["samaccountname"][0]
        }
        if ($result.Properties["distinguishedname"].Count -gt 0) {
            $emptyResult.DistinguishedName = [string]$result.Properties["distinguishedname"][0]
        }

        $description = ""
        if ($result.Properties["description"].Count -gt 0) {
            $description = [string]$result.Properties["description"][0]
        }
        $userAccountControl = 0
        if ($result.Properties["useraccountcontrol"].Count -gt 0) {
            $userAccountControl = [int64]$result.Properties["useraccountcontrol"][0]
        }

        $termination = Get-AdInventoryTerminationEvaluation `
            -Description $description `
            -DistinguishedName ([string]$emptyResult.DistinguishedName) `
            -UserAccountControl $userAccountControl
        $emptyResult.Disabled = $termination.Disabled
        $emptyResult.DescriptionMatched = $termination.DescriptionMatched
        $emptyResult.OuMatched = $termination.OuMatched
        $emptyResult.Terminated = $termination.Terminated
        $emptyResult.TerminationReason = $termination.TerminationReason
        return [PSCustomObject]$emptyResult
    }
    catch {
        $emptyResult.Error = Limit-InventoryText -Value (Get-ExceptionText $_.Exception) -MaxLength 1000
        return [PSCustomObject]$emptyResult
    }
    finally {
        if ($searcher) { try { $searcher.Dispose() } catch {} }
        if ($searchRoot) { try { $searchRoot.Dispose() } catch {} }
        if ($rootDse) { try { $rootDse.Dispose() } catch {} }
    }
}

function Invoke-SnipeApi {
    param(
        [Parameter(Mandatory=$true)][ValidateSet("GET","POST","PATCH","PUT","DELETE")][string]$Method,
        [Parameter(Mandatory=$true)][string]$Path,
        [object]$Body = $null,
        [ValidateSet("Json","Form")][string]$BodyFormat = "Json"
    )

    if ($DryRun -and $Method -ne "GET") {
        throw "DRY RUN SAFETY: blocked unexpected Snipe-IT mutation $Method $Path"
    }

    $contentType = "application/json"
    $headers = @{
        "Authorization" = "Bearer $SnipeToken"
        "Accept"        = "application/json"
    }

    if ($Path -notmatch '^/') { $Path = "/$Path" }
    $requestBody = $null
    if ($null -ne $Body) {
        if ($BodyFormat -eq "Form") {
            $contentType = "application/x-www-form-urlencoded"
            $requestBody = ConvertTo-FormUrlEncoded -Body $Body
        }
        else {
            $requestBody = $Body | ConvertTo-Json -Depth 15
        }
    }

    $candidateBases = @(
        (@($SnipeUrl) + @($SnipeFallbackUrls)) |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            ForEach-Object { $_.TrimEnd('/') } |
            Select-Object -Unique
    )
    $lastApiError = $null

    foreach ($base in $candidateBases) {
        $uri = "$base$Path"
        $params = @{
            Method      = $Method
            Uri         = $uri
            Headers     = $headers
            ErrorAction = "Stop"
            TimeoutSec  = 120
            UserAgent   = $SnipeApiUserAgent
            ContentType = $contentType
        }

        if ($null -ne $requestBody) {
            $params["Body"] = $requestBody
        }

        try {
            if ($base -ne $SnipeUrl.TrimEnd('/')) {
                Write-Log "Snipe API: пробую альтернативный URL $base"
            }
            return (Assert-SnipeApiSuccess -Response (Invoke-RestMethod @params) -Operation "$Method $uri")
        }
        catch {
            $lastApiError = $_.Exception
            $respText = ""
            Write-Log "Snipe API ERROR: $Method $uri"
            if ($_.Exception.Response) {
                try {
                    $stream = $_.Exception.Response.GetResponseStream()
                    $reader = New-Object System.IO.StreamReader($stream)
                    $respText = $reader.ReadToEnd()
                    Write-Log "Snipe API response: $respText"
                }
                catch {}
            }

            $isAntivirusBlock = Test-SnipeApiNeedsCurlFallback -Exception $_.Exception -ResponseText $respText
            $isTransportError = ($null -eq $_.Exception.Response)
            $isMethodBlocked = $false
            if ($Method -in @("PATCH", "PUT") -and $_.Exception.Response) {
                try {
                    $isMethodBlocked = ([int]$_.Exception.Response.StatusCode -eq 405)
                }
                catch {}
            }
            if (-not $isAntivirusBlock -and -not $isTransportError -and -not $isMethodBlocked) {
                throw
            }

            if ($SnipeApiFallbackToCurl) {
                try {
                    Write-Log "Snipe API: web request не прошел локально. Повторяю через curl.exe."
                    return Invoke-SnipeApiWithCurl -Method $Method -Uri $uri -RequestBody $requestBody -ContentType $contentType
                }
                catch {
                    $lastApiError = $_.Exception
                    Write-Log "Snipe API curl failed: $(Get-ExceptionText $_.Exception)"
                    if (-not (Test-SnipeApiNeedsCurlFallback -Exception $_.Exception -ResponseText "")) {
                        throw
                    }
                }
            }

            Write-Log "Snipe API: URL $base тоже заблокирован 499, пробую следующий вариант."
        }
    }

    if ($SnipeApiFallbackToSsh) {
        Write-Log "Snipe API: все локальные HTTP/HTTPS варианты заблокированы. Пробую API через SSH на сервере."
        return Invoke-SnipeApiWithSsh -Method $Method -Path $Path -RequestBody $requestBody -ContentType $contentType
    }

    throw $lastApiError
}

function Get-InventoryExceptionHttpStatusCode {
    param($Exception)

    $current = $Exception
    while ($current) {
        if ($current.Response) {
            try { return [int]$current.Response.StatusCode } catch {}
        }
        $current = $current.InnerException
    }
    return $null
}

function Test-SnipeUnavailableText {
    param([AllowNull()][string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) { return $false }
    if ($Text -match '(?i)\bHTTP\s+(400|401|403|404|405|409|410|422)\b|API token|не заполнен Snipe API token|returned status.+error') {
        return $false
    }

    return ($Text -match '(?i)timed?\s*out|timeout|name resolution|resolve host|remote name could not be resolved|could not resolve|unable to connect|connection (refused|failed|closed|reset)|no route|network is unreachable|network path was not found|(?:code|кодом)\s*(6|7|28)|CURL_HTTP_STATUS\s*:\s*000|\bHTTP\s+(408|429|499|5\d\d)\b|ssh fallback|connectex|подключени|сетевой путь|удаленное имя|\b499\b')
}

function Test-SnipeUnavailableException {
    param($Exception)

    $statusCode = Get-InventoryExceptionHttpStatusCode -Exception $Exception
    if ($null -ne $statusCode) {
        if ($statusCode -in @(408, 429, 499) -or $statusCode -ge 500) { return $true }
        if ($statusCode -ge 400 -and $statusCode -lt 500) { return $false }
    }

    return (Test-SnipeUnavailableText -Text (Get-ExceptionText $Exception))
}

function Test-IsLegacySnipeTransportErrorMail {
    param([AllowNull()][object]$Entry)

    if ($null -eq $Entry) { return $false }
    $reason = ([string]$Entry.reason).Trim().ToLowerInvariant()
    if ($reason -eq "snipeit_relay" -or $reason -eq "agent_error" -or $reason -notmatch '(^|,\s*)error($|,)') {
        return $false
    }

    $text = @(
        [string]$Entry.subject,
        [string]$Entry.body,
        [string]$Entry.attachment_text,
        [string]$Entry.last_error
    ) -join "`n"
    return (Test-SnipeUnavailableText -Text $text)
}

function Remove-LegacySnipeTransportErrorMails {
    param([AllowNull()][array]$Queue)

    return @($Queue | Where-Object {
        -not (Test-IsLegacySnipeTransportErrorMail -Entry $_)
    })
}

function Test-SnipeApiAvailability {
    try {
        Invoke-SnipeApi -Method GET -Path "/api/v1/hardware?limit=1" | Out-Null
        return [PSCustomObject]@{
            Available = $true
            Flag      = "yes"
            Error     = ""
        }
    }
    catch {
        if (-not (Test-SnipeUnavailableException -Exception $_.Exception)) {
            throw
        }
        return [PSCustomObject]@{
            Available = $false
            Flag      = "no"
            Error     = Limit-InventoryText -Value (Get-ExceptionText $_.Exception) -MaxLength 2000
        }
    }
}

function Get-SnipeRows {
    param([object]$Response)
    if ($null -eq $Response) { return @() }
    if ($Response -is [array]) { return @($Response) }
    if ($Response.PSObject.Properties["rows"] -and $null -ne $Response.rows) { return @($Response.rows) }
    return @($Response)
}

function Convert-LegacyUsernameToDotUsername {
    param([string]$Username)

    if (-not $InventoryEnableLegacyUsernameAliases) { return $null }
    if ([string]::IsNullOrWhiteSpace($Username)) { return $null }

    $login = (($Username.Trim() -split '\\')[-1]).Trim()
    if ($login.Length -lt 3) { return $null }
    if ($login -match '[\._@]') { return $null }
    if ($login -notmatch '^[A-Za-z][A-Za-z0-9-]*[A-Za-z]$') { return $null }

    $surname = $login.Substring(0, $login.Length - 1).ToLowerInvariant()
    $initial = $login.Substring($login.Length - 1, 1).ToLowerInvariant()
    if ($surname.Length -lt 2) { return $null }

    return "$initial.$surname"
}

function Get-LegacyInventoryUsernameCandidates {
    param([AllowNull()][array]$Usernames)

    return @(
        $Usernames |
            ForEach-Object {
                $login = Get-InventoryLoginName -AccountName ([string]$_)
                $legacy = Convert-LegacyUsernameToDotUsername -Username $login
                if (
                    -not [string]::IsNullOrWhiteSpace($legacy) -and
                    $legacy.Trim().ToLowerInvariant() -ne $login.Trim().ToLowerInvariant()
                ) {
                    $legacy.Trim()
                }
            } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            Select-Object -Unique
    )
}

function Get-ManualInventoryUsernameAlias {
    param([string]$Username)

    if ([string]::IsNullOrWhiteSpace($Username) -or $null -eq $InventoryUsernameAliases) { return $null }

    $login = (($Username.Trim() -split '\\')[-1]).Trim()
    $loginLower = $login.ToLowerInvariant()

    try {
        if ($InventoryUsernameAliases -is [System.Collections.IDictionary]) {
            foreach ($key in $InventoryUsernameAliases.Keys) {
                if ($null -ne $key -and $key.ToString().Trim().ToLowerInvariant() -eq $loginLower) {
                    $value = [string]$InventoryUsernameAliases[$key]
                    if (-not [string]::IsNullOrWhiteSpace($value)) { return $value.Trim() }
                }
            }
        }
        else {
            foreach ($property in $InventoryUsernameAliases.PSObject.Properties) {
                if ($property.Name.Trim().ToLowerInvariant() -eq $loginLower) {
                    $value = [string]$property.Value
                    if (-not [string]::IsNullOrWhiteSpace($value)) { return $value.Trim() }
                }
            }
        }
    }
    catch {
        Write-Log "Username aliases: не удалось прочитать InventoryUsernameAliases из конфига."
        Write-Log (Get-ExceptionText $_.Exception)
    }

    return $null
}

function Get-LearnedInventoryUsernameAlias {
    param(
        [string]$Username,
        [object]$State
    )

    if ([string]::IsNullOrWhiteSpace($Username) -or $null -eq $State) { return $null }
    if (-not $State.PSObject.Properties["learned_username_aliases"]) { return $null }

    $loginLower = (($Username.Trim() -split '\\')[-1]).Trim().ToLowerInvariant()
    $aliases = $State.learned_username_aliases
    if ($null -eq $aliases) { return $null }

    try {
        if ($aliases -is [System.Collections.IDictionary]) {
            foreach ($key in $aliases.Keys) {
                if ($null -ne $key -and $key.ToString().Trim().ToLowerInvariant() -eq $loginLower) {
                    $value = [string]$aliases[$key]
                    if (-not [string]::IsNullOrWhiteSpace($value)) { return $value.Trim() }
                }
            }
        }
        else {
            foreach ($property in $aliases.PSObject.Properties) {
                if ($property.Name.Trim().ToLowerInvariant() -eq $loginLower) {
                    $value = [string]$property.Value
                    if (-not [string]::IsNullOrWhiteSpace($value)) { return $value.Trim() }
                }
            }
        }
    }
    catch {
        Write-Log "Username aliases: не удалось прочитать learned_username_aliases из state."
        Write-Log (Get-ExceptionText $_.Exception)
    }

    return $null
}

function Test-InventoryUsernameMapsToCanonical {
    param(
        [string]$Username,
        [string]$CanonicalUsername
    )

    if (-not (Test-InventoryAccountIdentifier -AccountName $Username) -or
        -not (Test-InventoryAccountIdentifier -AccountName $CanonicalUsername)) { return $false }

    $login = (($Username.Trim() -split '\\')[-1]).Trim().ToLowerInvariant()
    $canonical = (($CanonicalUsername.Trim() -split '\\')[-1]).Trim().ToLowerInvariant()
    if ($login -eq $canonical) { return $true }

    $manualAlias = Get-ManualInventoryUsernameAlias -Username $login
    if (-not [string]::IsNullOrWhiteSpace($manualAlias) -and $manualAlias.Trim().ToLowerInvariant() -eq $canonical) {
        return $true
    }

    $legacyAlias = Convert-LegacyUsernameToDotUsername -Username $login
    if (-not [string]::IsNullOrWhiteSpace($legacyAlias) -and $legacyAlias.Trim().ToLowerInvariant() -eq $canonical) {
        return $true
    }

    if ($login -match '^[a-z][a-z0-9-]*$' -and $canonical -match ('^[a-z]\.' + [regex]::Escape($login) + '$')) {
        return $true
    }

    return $false
}

function Resolve-InventoryUsernameLocally {
    param(
        [string]$Username,
        [object]$State
    )

    if (-not (Test-InventoryAccountIdentifier -AccountName $Username)) { return $null }
    $login = (($Username.Trim() -split '\\')[-1]).Trim()

    $manualAlias = Get-ManualInventoryUsernameAlias -Username $login
    if (Test-InventoryAccountIdentifier -AccountName $manualAlias) { return $manualAlias.Trim() }

    $learnedAlias = Get-LearnedInventoryUsernameAlias -Username $login -State $State
    if (Test-InventoryAccountIdentifier -AccountName $learnedAlias) { return $learnedAlias.Trim() }

    if ($null -ne $State -and $State.PSObject.Properties["detected_username"]) {
        $stateCanonical = [string]$State.detected_username
        if ((Test-InventoryAccountIdentifier -AccountName $stateCanonical) -and
            (Test-InventoryUsernameMapsToCanonical -Username $login -CanonicalUsername $stateCanonical)) {
            return $stateCanonical.Trim()
        }
    }

    return $login
}

function Get-InventoryUsernameConfidence {
    param(
        [AllowNull()][string]$RawUsername,
        [AllowNull()][string]$ResolvedUsername,
        [AllowNull()][object]$State,
        [AllowNull()][string]$ObservedSource
    )

    $rawLogin = Get-InventoryLoginName -AccountName $RawUsername
    $resolvedLogin = Get-InventoryLoginName -AccountName $ResolvedUsername
    $method = "unresolved"
    $resolutionConfidence = 0

    if ((Test-InventoryAccountIdentifier -AccountName $rawLogin) -and
        (Test-InventoryAccountIdentifier -AccountName $resolvedLogin)) {
        $rawLower = $rawLogin.ToLowerInvariant()
        $resolvedLower = $resolvedLogin.ToLowerInvariant()
        $manualAlias = Get-ManualInventoryUsernameAlias -Username $rawLogin
        $learnedAlias = Get-LearnedInventoryUsernameAlias -Username $rawLogin -State $State
        $legacyAlias = Convert-LegacyUsernameToDotUsername -Username $rawLogin

        if (-not [string]::IsNullOrWhiteSpace($manualAlias) -and $manualAlias.Trim().ToLowerInvariant() -eq $resolvedLower) {
            $method = "json_alias"
            $resolutionConfidence = 100
        }
        elseif (-not [string]::IsNullOrWhiteSpace($learnedAlias) -and $learnedAlias.Trim().ToLowerInvariant() -eq $resolvedLower) {
            $method = "state_alias"
            $resolutionConfidence = 90
        }
        elseif (-not [string]::IsNullOrWhiteSpace($legacyAlias) -and $legacyAlias.Trim().ToLowerInvariant() -eq $resolvedLower) {
            $method = "old_format"
            $resolutionConfidence = 90
        }
        elseif ($rawLower -eq $resolvedLower) {
            $method = "exact_username"
            $resolutionConfidence = 95
        }
        elseif ($rawLower -match '^[a-z][a-z0-9-]*$' -and $resolvedLower -match ('^[a-z]\.' + [regex]::Escape($rawLower) + '$')) {
            $method = "wildcard_initial"
            $resolutionConfidence = 70
        }
        else {
            $method = "transformed_username"
            $resolutionConfidence = 60
        }
    }

    $sourceConfidence = switch -Regex ([string]$ObservedSource) {
        '^Win32_UserProfile$' { 40; break }
        '^Win32_ComputerSystem\.UserName$' { 100; break }
        '^Security 4624$' { 95; break }
        '^none$|^$' { 0; break }
        default { 70 }
    }

    $finalConfidence = if ($resolutionConfidence -le 0 -or $sourceConfidence -le 0) {
        0
    }
    else {
        [Math]::Min([int]$resolutionConfidence, [int]$sourceConfidence)
    }

    return [PSCustomObject]@{
        Confidence           = [int]$finalConfidence
        ResolutionConfidence = [int]$resolutionConfidence
        SourceConfidence     = [int]$sourceConfidence
        Method               = $method
        Source               = [string]$ObservedSource
        RawUsername          = $rawLogin
        ResolvedUsername     = $resolvedLogin
    }
}

function Add-LearnedInventoryUsernameAlias {
    param(
        [System.Collections.IDictionary]$State,
        [string]$RawUsername,
        [string]$CanonicalUsername
    )

    if ($null -eq $State -or
        -not (Test-InventoryAccountIdentifier -AccountName $RawUsername) -or
        -not (Test-InventoryAccountIdentifier -AccountName $CanonicalUsername)) { return }

    $rawLogin = (($RawUsername.Trim() -split '\\')[-1]).Trim().ToLowerInvariant()
    $canonicalLogin = (($CanonicalUsername.Trim() -split '\\')[-1]).Trim().ToLowerInvariant()
    if ($rawLogin -eq $canonicalLogin) { return }

    $aliasMap = [ordered]@{}
    $existingAliases = $State["learned_username_aliases"]
    if ($null -ne $existingAliases) {
        if ($existingAliases -is [System.Collections.IDictionary]) {
            foreach ($key in $existingAliases.Keys) {
                $aliasMap[[string]$key] = [string]$existingAliases[$key]
            }
        }
        else {
            foreach ($property in $existingAliases.PSObject.Properties) {
                $aliasMap[$property.Name] = [string]$property.Value
            }
        }
    }

    $aliasMap[$rawLogin] = $canonicalLogin
    $State["learned_username_aliases"] = [PSCustomObject]$aliasMap
}

function Get-SnipeUsernameCandidates {
    param([string]$Username)

    if (-not (Test-InventoryAccountIdentifier -AccountName $Username)) { return @() }

    $login = (($Username.Trim() -split '\\')[-1]).Trim()
    $candidates = @(
        $login,
        $login.ToLowerInvariant(),
        (Get-ManualInventoryUsernameAlias -Username $login),
        (Convert-LegacyUsernameToDotUsername -Username $login)
    )

    return @($candidates |
        Where-Object { Test-InventoryAccountIdentifier -AccountName ([string]$_) } |
        ForEach-Object { [string]$_ } |
        Select-Object -Unique)
}

function Find-UniqueCanonicalDotUser {
    param(
        [string]$LegacyUsername,
        [array]$Rows,
        [ref]$WasAmbiguous = $null
    )

    if ($null -ne $WasAmbiguous) { $WasAmbiguous.Value = $false }
    if ([string]::IsNullOrWhiteSpace($LegacyUsername) -or -not $Rows) { return $null }
    $login = (($LegacyUsername.Trim() -split '\\')[-1]).Trim().ToLowerInvariant()
    if ($login -match '[\._@]' -or $login -notmatch '^[a-z][a-z0-9-]*$') { return $null }

    $canonicalPattern = '^[a-z]\.' + [regex]::Escape($login) + '$'
    $matches = @($Rows | Where-Object {
        $candidateUsername = if ($_.username) { ([string]$_.username).Trim().ToLowerInvariant() } else { "" }
        $isActivated = (-not $_.PSObject.Properties["activated"]) -or [bool]$_.activated
        $isActivated -and $candidateUsername -match $canonicalPattern
    })

    if ($matches.Count -eq 1) {
        return $matches[0]
    }
    if ($matches.Count -gt 1) {
        if ($null -ne $WasAmbiguous) { $WasAmbiguous.Value = $true }
        $ambiguous = @($matches | ForEach-Object { [string]$_.username } | Select-Object -Unique)
        Write-Log "Snipe-IT: legacy username '$LegacyUsername' неоднозначен: $($ambiguous -join ', '). Автовыбор запрещен."
    }
    return $null
}

function Find-SnipeUserByUsername {
    param([string]$Username)
    if (-not (Test-InventoryAccountIdentifier -AccountName $Username)) {
        Write-Log "Snipe-IT user lookup skipped for invalid identity '$Username'."
        return $null
    }

    $originalNormalized = $Username.Trim().ToLowerInvariant()
    $usernameCandidates = @(Get-SnipeUsernameCandidates -Username $Username)
    if ($usernameCandidates.Count -eq 0) { return $null }

    if ($usernameCandidates.Count -gt 1) {
        Write-Log "Snipe-IT username candidates for '$Username': $($usernameCandidates -join ', ')"
    }

    $allCandidateNames = @()
    foreach ($usernameCandidate in $usernameCandidates) {
        $normalizedUsername = $usernameCandidate.Trim().ToLowerInvariant()
        if ($normalizedUsername -ne $originalNormalized) {
            Write-Log "Snipe-IT: пробую username alias '$usernameCandidate' для '$Username'"
        }

        $q = [uri]::EscapeDataString($usernameCandidate)
        $resp = Invoke-SnipeApi -Method GET -Path "/api/v1/users?search=$q&limit=50"
        $rows = Get-SnipeRows $resp

        $exact = $rows | Where-Object {
            $isActivated = (-not $_.PSObject.Properties["activated"]) -or [bool]$_.activated
            $isActivated -and (
                ($_.username -and $_.username.ToString().Trim().ToLowerInvariant() -eq $normalizedUsername) -or
                ($_.employee_num -and $_.employee_num.ToString().Trim().ToLowerInvariant() -eq $normalizedUsername)
            )
        } | Select-Object -First 1

        if ($exact) {
            if ($normalizedUsername -ne $originalNormalized) {
                Write-Log "Snipe-IT: пользователь найден по alias '$Username' -> '$usernameCandidate'."
            }
            return $exact
        }

        $canonicalMatchWasAmbiguous = $false
        $canonicalLegacyMatch = Find-UniqueCanonicalDotUser -LegacyUsername $usernameCandidate -Rows $rows -WasAmbiguous ([ref]$canonicalMatchWasAmbiguous)
        if ($canonicalLegacyMatch) {
            Write-Log "Snipe-IT: уникальный legacy alias '$Username' -> '$($canonicalLegacyMatch.username)'."
            return $canonicalLegacyMatch
        }
        if ($canonicalMatchWasAmbiguous) {
            Write-Log "Snipe-IT: поиск '$Username' остановлен, потому что фамильный alias '$usernameCandidate' неоднозначен. Добавь точное соответствие в InventoryUsernameAliases."
            return $null
        }

        $allCandidateNames += @($rows | ForEach-Object {
            $candidateUsername = if ($_.username) { [string]$_.username } else { "<no username>" }
            $candidateId = if ($_.id) { [string]$_.id } else { "<no id>" }
            "$candidateUsername/id=$candidateId"
        } | Select-Object -First 5)
    }

    $allCandidateNames = @($allCandidateNames | Select-Object -Unique | Select-Object -First 8)
    if ($allCandidateNames.Count -gt 0) {
        Write-Log "Snipe-IT: точного username для '$Username' нет. Похожие результаты проигнорированы: $($allCandidateNames -join ', ')"
    }
    else {
        Write-Log "Snipe-IT: username '$Username' не найден ни по одному варианту: $($usernameCandidates -join ', ')"
    }

    return $null
}

function Find-SnipeAsset {
    param(
        [string]$SerialNumber,
        [string]$ComputerName
    )

    if (-not [string]::IsNullOrWhiteSpace($SerialNumber)) {
        $q = [uri]::EscapeDataString($SerialNumber)
        $resp = Invoke-SnipeApi -Method GET -Path "/api/v1/hardware?search=$q&limit=50"
        $rows = Get-SnipeRows $resp
        $exact = $rows | Where-Object { $_.serial -and $_.serial.ToString().Trim().ToLower() -eq $SerialNumber.Trim().ToLower() } | Select-Object -First 1
        if ($exact) { return $exact }
    }

    if (-not [string]::IsNullOrWhiteSpace($ComputerName)) {
        $q = [uri]::EscapeDataString($ComputerName)
        $resp = Invoke-SnipeApi -Method GET -Path "/api/v1/hardware?search=$q&limit=50"
        $rows = Get-SnipeRows $resp
        $exact = $rows | Where-Object {
            ($_.name -and $_.name.ToString().Trim().ToLower() -eq $ComputerName.Trim().ToLower()) -or
            ($_.asset_tag -and $_.asset_tag.ToString().Trim().ToLower() -eq $ComputerName.Trim().ToLower())
        } | Select-Object -First 1
        if ($exact) { return $exact }
    }

    return $null
}

function Get-SnipeManufacturerId {
    param([string]$ManufacturerName)
    if ([string]::IsNullOrWhiteSpace($ManufacturerName)) { return $SnipeDefaultManufacturerId }

    $q = [uri]::EscapeDataString($ManufacturerName)
    $resp = Invoke-SnipeApi -Method GET -Path "/api/v1/manufacturers?search=$q&limit=50"
    $rows = Get-SnipeRows $resp
    $exact = $rows | Where-Object { $_.name -and $_.name.ToString().Trim().ToLower() -eq $ManufacturerName.Trim().ToLower() } | Select-Object -First 1
    if ($exact) { return [int]$exact.id }

    try {
        if ($DryRun) {
            Write-DryRunAction -Action "create Snipe-IT manufacturer '$ManufacturerName'" -Reason "manufacturer_not_found"
            return [int]$SnipeDefaultManufacturerId
        }
        Write-Log "Производитель не найден, создаю: $ManufacturerName"
        $body = @{ name = $ManufacturerName }
        $created = Invoke-SnipeApi -Method POST -Path "/api/v1/manufacturers" -Body $body
        if ($created.payload.id) { return [int]$created.payload.id }
        if ($created.id) { return [int]$created.id }
    }
    catch {
        Write-Log "Не удалось создать производителя, использую default manufacturer_id=$SnipeDefaultManufacturerId"
    }

    return $SnipeDefaultManufacturerId
}

function Ensure-SnipeModelFieldset {
    param(
        [int]$ModelId,
        [string]$ModelName
    )

    if ($SnipeDefaultFieldsetId -le 0) { return }

    if ($DryRun) {
        Write-DryRunAction -Action "set fieldset_id=$SnipeDefaultFieldsetId on model_id=$ModelId ('$ModelName')" -Reason "ensure_model_fieldset"
        return
    }

    try {
        Write-Log "Проверяю fieldset модели '$ModelName': model_id=$ModelId fieldset_id=$SnipeDefaultFieldsetId"
        Invoke-SnipeApi -Method PATCH -Path "/api/v1/models/$ModelId" -Body @{
            fieldset_id = [int]$SnipeDefaultFieldsetId
        } | Out-Null
    }
    catch {
        Write-Log "Не удалось обновить fieldset модели '$ModelName'. Custom fields могут не отображаться в вебе."
        Write-Log (Get-ExceptionText $_.Exception)
    }
}

function Get-OrCreateSnipeModelId {
    param(
        [string]$ModelName,
        [string]$ManufacturerName
    )

    if ([string]::IsNullOrWhiteSpace($ModelName)) { $ModelName = "Unknown model" }

    $q = [uri]::EscapeDataString($ModelName)
    $resp = Invoke-SnipeApi -Method GET -Path "/api/v1/models?search=$q&limit=50"
    $rows = Get-SnipeRows $resp

    $exact = $rows | Where-Object { $_.name -and $_.name.ToString().Trim().ToLower() -eq $ModelName.Trim().ToLower() } | Select-Object -First 1
    if ($exact) {
        Write-Log "Модель найдена в Snipe-IT: $ModelName / id=$($exact.id)"
        $modelId = [int]$exact.id
        Ensure-SnipeModelFieldset -ModelId $modelId -ModelName $ModelName
        return $modelId
    }

    if (-not $SnipeAutoCreateModel) {
        throw "Модель '$ModelName' не найдена в Snipe-IT, автосоздание выключено."
    }

    $manufacturerId = Get-SnipeManufacturerId -ManufacturerName $ManufacturerName

    if ($DryRun) {
        Write-DryRunAction -Action "create Snipe-IT model '$ModelName'" -Reason "model_not_found; manufacturer_id=$manufacturerId"
        return -1
    }

    Write-Log "Модель не найдена, создаю: $ModelName"
    $body = @{
        name            = $ModelName
        category_id     = [int]$SnipeDefaultCategoryId
        manufacturer_id = [int]$manufacturerId
        model_number    = $ModelName
        fieldset_id      = [int]$SnipeDefaultFieldsetId
    }

    $created = Invoke-SnipeApi -Method POST -Path "/api/v1/models" -Body $body
    if ($created.payload.id) {
        $modelId = [int]$created.payload.id
        Ensure-SnipeModelFieldset -ModelId $modelId -ModelName $ModelName
        return $modelId
    }
    if ($created.id) {
        $modelId = [int]$created.id
        Ensure-SnipeModelFieldset -ModelId $modelId -ModelName $ModelName
        return $modelId
    }

    throw "Не удалось получить id созданной модели '$ModelName'."
}

function Normalize-InventoryText {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return "" }
    return (($Text -replace '\s+', ' ').Trim())
}

function Normalize-SerialNumber {
    param([string]$SerialNumber)

    $serial = Normalize-InventoryText $SerialNumber
    if ([string]::IsNullOrWhiteSpace($serial)) { return "" }

    foreach ($pattern in $InventoryInvalidSerialNumberPatterns) {
        if ($serial -match $pattern) {
            Write-Log "Serial '$serial' пропущен как BIOS-заглушка по шаблону '$pattern'."
            return ""
        }
    }

    return $serial
}

function Get-CpuInventorySummary {
    param([object]$Cpu)

    if ($null -eq $Cpu) { return "" }

    $name = Normalize-InventoryText ([string]$Cpu.Name)
    $name = Normalize-InventoryText ($name -replace '\(R\)', '' -replace '\(TM\)', '')
    $cores = $Cpu.NumberOfCores
    $threads = $Cpu.NumberOfLogicalProcessors
    $clockMhz = $Cpu.MaxClockSpeed
    if (-not $clockMhz) { $clockMhz = $Cpu.CurrentClockSpeed }

    $clockText = ""
    if ($clockMhz -and [double]$clockMhz -gt 0) {
        $ghz = [math]::Round(([double]$clockMhz / 1000), 2)
        $clockText = " @ $ghz GHz"
    }

    if ($cores -and $threads) {
        return "$name$clockText (${cores}C/${threads}T)"
    }

    return "$name$clockText"
}

function Get-RamMemoryTypeName {
    param([object]$Module)

    if ($null -eq $Module) { return "RAM" }

    $typeCode = 0
    if ($Module.PSObject.Properties["SMBIOSMemoryType"] -and [int]$Module.SMBIOSMemoryType -gt 0) {
        $typeCode = [int]$Module.SMBIOSMemoryType
    }
    elseif ($Module.PSObject.Properties["MemoryType"] -and [int]$Module.MemoryType -gt 0) {
        $typeCode = [int]$Module.MemoryType
    }

    switch ($typeCode) {
        17 { return "SDRAM" }
        18 { return "SGRAM" }
        19 { return "RDRAM" }
        20 { return "DDR" }
        21 { return "DDR2" }
        22 { return "DDR2 FB-DIMM" }
        24 { return "DDR3" }
        25 { return "FBD2" }
        26 { return "DDR4" }
        27 { return "LPDDR" }
        28 { return "LPDDR2" }
        29 { return "LPDDR3" }
        30 { return "LPDDR4" }
        32 { return "HBM" }
        33 { return "HBM2" }
        34 { return "DDR5" }
        35 { return "LPDDR5" }
        36 { return "HBM3" }
        default { return "RAM" }
    }
}

function Get-RamFormFactorName {
    param([object]$Module)

    if ($null -eq $Module -or -not $Module.PSObject.Properties["FormFactor"]) { return "memory" }
    switch ([int]$Module.FormFactor) {
        8  { return "DIMM" }
        12 { return "SODIMM" }
        13 { return "SRIMM" }
        default { return "memory" }
    }
}

function Test-RamModuleOnboard {
    param([object]$Module)

    if ($null -eq $Module) { return $false }
    $typeName = Get-RamMemoryTypeName -Module $Module
    $formFactor = if ($Module.PSObject.Properties["FormFactor"]) { [int]$Module.FormFactor } else { 0 }
    $locator = "$(if ($Module.PSObject.Properties['DeviceLocator']) { $Module.DeviceLocator }) $(if ($Module.PSObject.Properties['BankLabel']) { $Module.BankLabel }) $(if ($Module.PSObject.Properties['PartNumber']) { $Module.PartNumber })"

    if ($locator -match '(?i)onboard|on-board|soldered|system board') { return $true }
    if ($formFactor -in @(14, 21, 22, 23)) { return $true }
    if ($typeName -like "LPDDR*" -and $locator -notmatch '(?i)CAMM') { return $true }
    return $false
}

function Format-RamCapacityGB {
    param([object]$Value)

    if ($null -eq $Value) { return "0" }
    return ([double]$Value).ToString("0.##", [System.Globalization.CultureInfo]::InvariantCulture)
}

function Get-RamDataRateDisplay {
    param([array]$DataRates)

    $rates = @($DataRates | Where-Object { $_ -and [double]$_ -gt 0 } | Sort-Object | Select-Object -Unique)
    if ($rates.Count -eq 0) { return "" }

    $rateText = ($rates | ForEach-Object { Format-RamCapacityGB -Value $_ }) -join "/"
    return "$rateText MT/s"
}

function Get-RamModuleInventoryDisplay {
    param([object]$Module)

    if ($null -eq $Module) { return "" }

    $parts = @()
    $locatorParts = @(
        Normalize-InventoryText ([string]$Module.DeviceLocator)
        Normalize-InventoryText ([string]$Module.BankLabel)
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique
    if ($locatorParts.Count -gt 0) { $parts += "slot=$($locatorParts -join '/')" }

    if ($Module.PSObject.Properties["Capacity"] -and [uint64]$Module.Capacity -gt 0) {
        $parts += "$(Format-RamCapacityGB -Value ([uint64]$Module.Capacity / 1GB)) GB"
    }

    $manufacturer = Normalize-InventoryText ([string]$Module.Manufacturer)
    if (-not [string]::IsNullOrWhiteSpace($manufacturer) -and $manufacturer -notmatch '^(Undefined|Unknown|Not Specified)$') {
        $parts += $manufacturer
    }

    $partNumber = Normalize-InventoryText ([string]$Module.PartNumber)
    if (-not [string]::IsNullOrWhiteSpace($partNumber) -and $partNumber -notmatch '^(Undefined|Unknown|Not Specified)$') {
        $parts += "PN=$partNumber"
    }

    $typeName = Get-RamMemoryTypeName -Module $Module
    if ($typeName -ne "RAM") { $parts += $typeName }

    $configured = if ($Module.PSObject.Properties["ConfiguredClockSpeed"] -and [int]$Module.ConfiguredClockSpeed -gt 0) {
        [int]$Module.ConfiguredClockSpeed
    }
    else { 0 }
    $moduleSpeed = if ($Module.PSObject.Properties["Speed"] -and [int]$Module.Speed -gt 0) {
        [int]$Module.Speed
    }
    else { 0 }

    if ($configured -gt 0 -and $moduleSpeed -gt 0 -and $configured -ne $moduleSpeed) {
        $parts += "configured=$configured MT/s"
        $parts += "module=$moduleSpeed MT/s"
    }
    elseif ($configured -gt 0) {
        $parts += "$configured MT/s"
    }
    elseif ($moduleSpeed -gt 0) {
        $parts += "module=$moduleSpeed MT/s"
    }

    return ($parts -join ", ")
}

function Get-RamInventoryDetails {
    param(
        [array]$RamModules,
        [object]$RamGB,
        [object]$FallbackSlotCount
    )

    $modules = @($RamModules | Where-Object {
        $null -ne $_ -and (
            -not $_.PSObject.Properties["Capacity"] -or
            [uint64]$_.Capacity -gt 0
        )
    })
    $ramGbText = Format-RamCapacityGB -Value $RamGB
    if ($modules.Count -eq 0) {
        return [PSCustomObject]@{
            Summary              = "$ramGbText GB"
            Layout               = "Unknown memory layout"
            IsOnboard            = $false
            InstalledDeviceCount = 0
            MemoryType           = "RAM"
            SpeedMTs             = ""
            RatedSpeedMTs        = ""
            ModuleDetails        = "Unavailable"
        }
    }

    $moduleDetails = @(
        $modules |
            ForEach-Object { Get-RamModuleInventoryDisplay -Module $_ } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    ) -join "; "

    $manufacturers = @(
        $modules |
            ForEach-Object { Normalize-InventoryText ([string]$_.Manufacturer) } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) -and $_ -notmatch '^(Undefined|Unknown|Not Specified)$' } |
            Select-Object -Unique
    )
    $manufacturerText = if ($manufacturers.Count -gt 0) { ($manufacturers -join "+") } else { "" }

    $memoryTypes = @(
        $modules |
            ForEach-Object { Get-RamMemoryTypeName -Module $_ } |
            Where-Object { $_ -ne "RAM" } |
            Select-Object -Unique
    )
    $memoryTypeText = if ($memoryTypes.Count -gt 0) { ($memoryTypes -join "/") } else { "RAM" }

    # SMBIOS reports memory speed as a transfer rate. Keep the firmware values verbatim.
    $configuredSpeeds = @(
        $modules |
            Where-Object { $_.PSObject.Properties["ConfiguredClockSpeed"] -and [int]$_.ConfiguredClockSpeed -gt 0 } |
            ForEach-Object { [int]$_.ConfiguredClockSpeed } |
            Where-Object { $_ -and [int]$_ -gt 0 } |
            Sort-Object |
            Select-Object -Unique
    )
    $ratedSpeeds = @(
        $modules |
            Where-Object { $_.PSObject.Properties["Speed"] -and [int]$_.Speed -gt 0 } |
            ForEach-Object { [int]$_.Speed } |
            Where-Object { $_ -and [int]$_ -gt 0 } |
            Sort-Object |
            Select-Object -Unique
    )
    $currentSpeeds = if ($configuredSpeeds.Count -gt 0) { @($configuredSpeeds) } else { @($ratedSpeeds) }
    $currentSpeedDisplay = Get-RamDataRateDisplay -DataRates $currentSpeeds
    $ratedSpeedDisplay = Get-RamDataRateDisplay -DataRates $ratedSpeeds
    $currentSpeedValueText = if ($currentSpeeds.Count -gt 0) { $currentSpeeds -join "/" } else { "" }
    $ratedSpeedValueText = if ($ratedSpeeds.Count -gt 0) { $ratedSpeeds -join "/" } else { "" }
    if ($currentSpeedDisplay -and $ratedSpeedDisplay -and $currentSpeedValueText -ne $ratedSpeedValueText) {
        $speedText = "configured $currentSpeedDisplay; module $ratedSpeedDisplay"
    }
    elseif ($configuredSpeeds.Count -gt 0 -and $currentSpeedDisplay) {
        $speedText = $currentSpeedDisplay
    }
    elseif ($ratedSpeedDisplay) {
        $speedText = "module $ratedSpeedDisplay"
    }
    else {
        $speedText = ""
    }

    $capacitiesGB = @(
        $modules | ForEach-Object {
            if ($_.PSObject.Properties["Capacity"] -and [uint64]$_.Capacity -gt 0) {
                [math]::Round(([uint64]$_.Capacity / 1GB), 2)
            }
        }
    )
    $uniqueCapacities = @($capacitiesGB | Select-Object -Unique)
    if ($capacitiesGB.Count -eq $modules.Count -and $uniqueCapacities.Count -eq 1) {
        $capacityLayout = "$($modules.Count) x $(Format-RamCapacityGB -Value $uniqueCapacities[0]) GB"
    }
    elseif ($capacitiesGB.Count -gt 0) {
        $capacityLayout = "$(($capacitiesGB | ForEach-Object { Format-RamCapacityGB -Value $_ }) -join ' + ') GB"
    }
    else {
        $capacityLayout = "$ramGbText GB"
    }

    $socketedModules = @($modules | Where-Object { $_.PSObject.Properties["FormFactor"] -and [int]$_.FormFactor -in @(8, 12, 13) })
    $onboardModules = @($modules | Where-Object { Test-RamModuleOnboard -Module $_ })
    $isOnboard = ($onboardModules.Count -eq $modules.Count)

    if ($isOnboard) {
        $layoutText = "Onboard/soldered; no user-replaceable DIMM/SODIMM slots"
        $layoutSummary = "onboard"
    }
    elseif ($socketedModules.Count -eq $modules.Count) {
        $slotCount = $modules.Count
        if ($FallbackSlotCount -and [int]$FallbackSlotCount -ge $modules.Count) {
            $slotCount = [int]$FallbackSlotCount
        }
        $formFactors = @($socketedModules | ForEach-Object { Get-RamFormFactorName -Module $_ } | Select-Object -Unique)
        $formFactorText = if ($formFactors.Count -eq 1) { $formFactors[0] } else { "DIMM/SODIMM" }
        $layoutText = "$capacityLayout; $($modules.Count)/$slotCount $formFactorText slots used"
        $layoutSummary = $layoutText
    }
    elseif ($socketedModules.Count -gt 0 -and $onboardModules.Count -gt 0) {
        $layoutText = "Mixed onboard and socketed memory; $capacityLayout; $($socketedModules.Count) socketed module(s)"
        $layoutSummary = "mixed onboard/socketed; $capacityLayout"
    }
    else {
        $layoutText = "$capacityLayout; $($modules.Count) SMBIOS memory device(s), physical slot count unavailable"
        $layoutSummary = $layoutText
    }

    $identityParts = @()
    if ($manufacturerText) { $identityParts += $manufacturerText }
    $identityParts += "$ramGbText GB"
    if ($memoryTypeText -ne "RAM") { $identityParts += $memoryTypeText }
    $summaryParts = @(($identityParts -join " "))
    if ($speedText) { $summaryParts += $speedText }
    if ($layoutSummary) { $summaryParts += $layoutSummary }
    $summary = $summaryParts -join "; "

    return [PSCustomObject]@{
        Summary              = $summary
        Layout               = $layoutText
        IsOnboard            = $isOnboard
        InstalledDeviceCount = $modules.Count
        MemoryType           = $memoryTypeText
        SpeedMTs             = $currentSpeedValueText
        RatedSpeedMTs        = $ratedSpeedValueText
        ModuleDetails        = $moduleDetails
    }
}

function Get-RamInventorySummary {
    param(
        [array]$RamModules,
        [object]$RamGB,
        [object]$FallbackSlotCount
    )

    return (Get-RamInventoryDetails -RamModules $RamModules -RamGB $RamGB -FallbackSlotCount $FallbackSlotCount).Summary
}

function Get-OsInventorySummary {
    param(
        [string]$OSName,
        [string]$OSBuild
    )

    $name = Normalize-InventoryText (Repair-Utf8Mojibake $OSName)
    $windowsIndex = $name.IndexOf("Windows")
    if ($windowsIndex -gt 0) {
        $name = $name.Substring($windowsIndex)
    }
    $name = Normalize-InventoryText ($name -replace '[^\x20-\x7E]', ' ' -replace '\?+', ' ')
    if ([string]::IsNullOrWhiteSpace($name)) {
        $name = "Windows"
    }

    if (-not [string]::IsNullOrWhiteSpace($OSBuild)) {
        return "$name (build $OSBuild)"
    }

    return $name
}

function Get-StorageInventorySummary {
    param([array]$Disks)

    $items = @()
    foreach ($disk in @($Disks)) {
        $name = Normalize-InventoryText ([string]$(if ($disk.FriendlyName) { $disk.FriendlyName } else { $disk.Model }))
        if ([string]::IsNullOrWhiteSpace($name)) { continue }

        $mediaType = Normalize-InventoryText ([string]$disk.MediaType)
        if ($mediaType -notmatch '^(SSD|HDD)$') {
            if ($name -match '(?i)\bSSD\b|NVMe|SN\d|SDE|MZ|KXG|KBG|PC SN') {
                $mediaType = "SSD"
            }
            else {
                $mediaType = "HDD"
            }
        }

        $size = $disk.Size
        if (-not $size) { $size = $disk.AllocatedSize }
        $sizeText = ""
        if ($size -and [double]$size -gt 0) {
            $sizeText = " $([math]::Round(([double]$size / 1GB), 0)) GB"
        }

        $items += "$mediaType $name$sizeText"
    }

    return ($items | Select-Object -Unique) -join "; "
}

function Get-SnipeAssetNotes {
    param(
        [string]$ComputerName,
        [string]$SerialNumber,
        [string]$Manufacturer,
        [string]$Model,
        [string]$CpuName,
        [object]$CpuCores,
        [object]$CpuThreads,
        [object]$RamGB,
        [string]$RamLayout,
        [string]$OSName,
        [string]$OSVersion,
        [string]$OSBuild,
        [object]$LastBoot,
        [string]$DetectedUsername,
        [string]$ReportDate,
        [string]$InventoryTimestamp
    )

    $notesTimestamp = Format-InventoryNotesTimestamp `
        -Timestamp $InventoryTimestamp `
        -Fallback $ReportDate
    $lastBootDisplay = ""
    if ($LastBoot) {
        try {
            $lastBootDisplay = ([datetime]$LastBoot).ToString(
                "dd.MM.yyyy HH:mm:ss",
                [System.Globalization.CultureInfo]::InvariantCulture
            )
        }
        catch {
            $lastBootDisplay = [string]$LastBoot
        }
    }

    $lines = @(
        "Auto inventory by SnipeIT Inventory Agent",
        "Updated: $notesTimestamp",
        "",
        "Computer: $ComputerName",
        "Serial: $SerialNumber",
        "Manufacturer: $Manufacturer",
        "Model: $Model",
        "CPU: $CpuName",
        "CPU cores/threads: $CpuCores / $CpuThreads",
        "RAM: $RamGB GB",
        "RAM layout: $RamLayout",
        "OS: $OSName",
        "OS version: $OSVersion",
        "OS build: $OSBuild",
        "Last boot: $lastBootDisplay",
        "Detected username: $DetectedUsername"
    )

    return ($lines -join "`r`n")
}

function Add-SnipeCustomFieldsToBody {
    param(
        [hashtable]$Body,
        [hashtable]$CustomFields
    )

    if ($null -eq $CustomFields) { return }

    foreach ($key in $CustomFields.Keys) {
        if ([string]::IsNullOrWhiteSpace($key)) { continue }
        $Body[$key] = $CustomFields[$key]
    }
}

function Update-SnipeAssetHealth {
    param(
        [int]$AssetId,
        [AllowNull()][string]$LastError,
        [AllowNull()][string]$LastSuccessfulInventory = $null,
        [switch]$ThrowOnError
    )

    if (-not $SnipeEnabled -or $AssetId -le 0) { return $false }

    if ($DryRun) {
        Write-DryRunAction -Action "update health fields on asset_id=$AssetId" -Reason "agent_version=$InventoryAgentVersion"
        return $true
    }

    $body = @{}
    if (-not [string]::IsNullOrWhiteSpace($SnipeCustomFieldAgentVersion)) {
        $body[$SnipeCustomFieldAgentVersion] = $InventoryAgentVersion
    }
    if (-not [string]::IsNullOrWhiteSpace($SnipeCustomFieldLastError)) {
        $body[$SnipeCustomFieldLastError] = Limit-InventoryText -Value $LastError -MaxLength 2000
    }
    if ($PSBoundParameters.ContainsKey("LastSuccessfulInventory") -and -not [string]::IsNullOrWhiteSpace($SnipeCustomFieldLastSuccess)) {
        $body[$SnipeCustomFieldLastSuccess] = Format-InventoryDisplayTimestamp -Timestamp $LastSuccessfulInventory
    }
    if ($body.Count -eq 0) { return $false }

    try {
        Invoke-SnipeApi -Method PATCH -Path "/api/v1/hardware/$AssetId" -Body $body | Out-Null
        Write-Log "Snipe health: asset_id=$AssetId LastError обновлен."
        return $true
    }
    catch {
        Write-Log "Snipe health: не удалось обновить LastError для asset_id=$AssetId"
        Write-Log (Get-ExceptionText $_.Exception)
        if ($ThrowOnError) { throw }
        return $false
    }
}

function New-SnipeAsset {
    param(
        [string]$ComputerName,
        [string]$SerialNumber,
        [int]$ModelId,
        [string]$Notes,
        [hashtable]$CustomFields = @{},
        [int]$StatusId = 0
    )

    $effectiveStatusId = if ($StatusId -gt 0) { $StatusId } else { [int]$SnipeDefaultStatusId }
    Write-Log "Создаю актив в Snipe-IT: name=$ComputerName serial=$SerialNumber model_id=$ModelId status_id=$effectiveStatusId; asset_tag назначает Snipe-IT"

    $body = @{
        name      = $ComputerName
        serial    = $SerialNumber
        model_id  = [int]$ModelId
        status_id = $effectiveStatusId
        notes     = $Notes
    }
    Add-SnipeCustomFieldsToBody -Body $body -CustomFields $CustomFields

    if ($DryRun) {
        Write-DryRunAction -Action "create asset name=$ComputerName serial=$SerialNumber model_id=$ModelId status_id=$effectiveStatusId; preserve Snipe-IT asset_tag" -Reason "asset_not_found"
        return [PSCustomObject]@{
            id         = -1
            name       = $ComputerName
            serial     = $SerialNumber
            status_id  = $effectiveStatusId
            dry_run    = $true
        }
    }

    $created = Invoke-SnipeApi -Method POST -Path "/api/v1/hardware" -Body $body
    if ($created.payload.id) { return $created.payload }
    if ($created.id) { return $created }
    throw "Актив создан, но API не вернул id/payload."
}

function Update-SnipeAsset {
    param(
        [int]$AssetId,
        [string]$ComputerName,
        [string]$SerialNumber,
        [int]$ModelId,
        [string]$Notes,
        [hashtable]$CustomFields = @{},
        [int]$StatusId = 0
    )

    Write-Log "Обновляю актив id=${AssetId}: name=$ComputerName serial=$SerialNumber model_id=$ModelId"
    $body = @{
        name      = $ComputerName
        serial    = $SerialNumber
        model_id  = [int]$ModelId
        notes     = $Notes
    }
    Add-SnipeCustomFieldsToBody -Body $body -CustomFields $CustomFields

    if ($StatusId -gt 0) {
        Write-Log "Дополнительно обновляю status_id=$StatusId"
        $body.status_id = [int]$StatusId
    }
    elseif ($SnipeSetDefaultStatusOnUpdate) {
        Write-Log "Дополнительно обновляю status_id=$SnipeDefaultStatusId"
        $body.status_id = [int]$SnipeDefaultStatusId
    }

    if ($DryRun) {
        $statusText = if ($body.ContainsKey("status_id")) { "; status_id=$($body.status_id)" } else { "" }
        Write-DryRunAction -Action "update asset_id=$AssetId name=$ComputerName serial=$SerialNumber model_id=$ModelId$statusText" -Reason "inventory_refresh"
        return [PSCustomObject]@{ status = "dry_run"; id = $AssetId }
    }
    return Invoke-SnipeApi -Method PUT -Path "/api/v1/hardware/$AssetId" -Body $body
}

function Get-AssignedUserIdFromAsset {
    param([object]$Asset)

    if ($null -eq $Asset) { return $null }
    if ($Asset.assigned_to -and $Asset.assigned_to.id) { return [int]$Asset.assigned_to.id }
    if ($Asset.assigned_user -and $Asset.assigned_user.id) { return [int]$Asset.assigned_user.id }
    if ($Asset.assigned_to_user -and $Asset.assigned_to_user.id) { return [int]$Asset.assigned_to_user.id }
    if ($Asset.user -and $Asset.user.id) { return [int]$Asset.user.id }
    if ($Asset.assigned_to_id) { return [int]$Asset.assigned_to_id }
    if ($Asset.assigned_user_id) { return [int]$Asset.assigned_user_id }
    return $null
}

function Get-AssignedUserLabelFromAsset {
    param([object]$Asset)

    if ($null -eq $Asset) { return "" }

    foreach ($propertyName in @("assigned_to", "assigned_user", "assigned_to_user", "user")) {
        $property = $Asset.PSObject.Properties[$propertyName]
        if (-not $property -or -not $property.Value) { continue }

        $assigned = $property.Value
        foreach ($nameProperty in @("username", "name", "full_name", "email")) {
            $valueProperty = $assigned.PSObject.Properties[$nameProperty]
            if ($valueProperty -and -not [string]::IsNullOrWhiteSpace([string]$valueProperty.Value)) {
                return ([string]$valueProperty.Value).Trim()
            }
        }
    }

    $assignedId = Get-AssignedUserIdFromAsset -Asset $Asset
    if ($assignedId) { return "user_id=$assignedId" }

    return ""
}

function Get-SnipeAssetById {
    param([int]$AssetId)
    $resp = Invoke-SnipeApi -Method GET -Path "/api/v1/hardware/$AssetId"
    if ($resp.payload) { return $resp.payload }
    return $resp
}

function Get-SnipeAssetStatusId {
    param([object]$Asset)

    if ($null -eq $Asset) { return $null }
    if ($Asset.status_label -and $Asset.status_label.id) { return [int]$Asset.status_label.id }
    if ($Asset.status -and $Asset.status.id) { return [int]$Asset.status.id }
    if ($Asset.status_id) { return [int]$Asset.status_id }
    return $null
}

function Set-SnipeAssetStatus {
    param(
        [int]$AssetId,
        [int]$StatusId
    )

    if ($AssetId -le 0 -or $StatusId -le 0) { return }
    if ($DryRun) {
        Write-DryRunAction -Action "set asset_id=$AssetId status_id=$StatusId" -Reason "status_update"
        return
    }
    Write-Log "Snipe status: asset_id=$AssetId -> status_id=$StatusId"
    Invoke-SnipeApi -Method PATCH -Path "/api/v1/hardware/$AssetId" -Body @{ status_id = $StatusId } | Out-Null
}

function Set-SnipeAssetCheckout {
    param(
        [int]$AssetId,
        [int]$UserId,
        [string]$Username,
        [string]$ComputerName,
        [object]$ExistingAsset = $null
    )

    $existingAssignedUserId = Get-AssignedUserIdFromAsset -Asset $ExistingAsset
    $existingAssignedUserLabel = Get-AssignedUserLabelFromAsset -Asset $ExistingAsset
    if ($existingAssignedUserId -eq $UserId) {
        Write-Log "Актив id=$AssetId уже был найден как привязанный к пользователю $Username (user_id=$UserId). Checkout не нужен."
        return [PSCustomObject]@{
            AssetId                = $AssetId
            CheckoutChanged        = $false
            PreviousAssignedUserId = $existingAssignedUserId
            PreviousAssignedUser   = $existingAssignedUserLabel
            CurrentAssignedUserId  = $UserId
            CurrentUsername        = $Username
            Action                 = "already_assigned"
        }
    }

    if ($DryRun) {
        if ($existingAssignedUserId -and $SnipeCheckinBeforeReassign) {
            Write-DryRunAction `
                -Action "check in asset_id=$AssetId from '$existingAssignedUserLabel' before reassignment" `
                -Reason "target_user=$Username" `
                -DetectedUsername $Username
        }
        Write-DryRunAction `
            -Action "checkout asset_id=$AssetId to user_id=$UserId ($Username)" `
            -Reason $(if ($existingAssignedUserId) { "reassignment" } else { "asset_unassigned" }) `
            -DetectedUsername $Username
        return [PSCustomObject]@{
            AssetId                = $AssetId
            CheckoutChanged        = $false
            WouldChange            = $true
            PreviousAssignedUserId = $existingAssignedUserId
            PreviousAssignedUser   = $existingAssignedUserLabel
            CurrentAssignedUserId  = $existingAssignedUserId
            CurrentUsername        = $existingAssignedUserLabel
            Action                 = $(if ($existingAssignedUserId) { "would_reassign" } else { "would_assign" })
        }
    }

    $assetFresh = Get-SnipeAssetById -AssetId $AssetId
    $assignedUserId = Get-AssignedUserIdFromAsset -Asset $assetFresh
    $assignedUserLabel = Get-AssignedUserLabelFromAsset -Asset $assetFresh

    if ($assignedUserId -eq $UserId) {
        Write-Log "Актив id=$AssetId уже привязан к пользователю $Username (user_id=$UserId). Checkout не нужен."
        return [PSCustomObject]@{
            AssetId                = $AssetId
            CheckoutChanged        = $false
            PreviousAssignedUserId = $assignedUserId
            PreviousAssignedUser   = $assignedUserLabel
            CurrentAssignedUserId  = $UserId
            CurrentUsername        = $Username
            Action                 = "already_assigned"
        }
    }

    if ($assignedUserId -and $SnipeCheckinBeforeReassign) {
        Write-Log "Актив id=$AssetId привязан к другому пользователю $assignedUserLabel (user_id=$assignedUserId). Делаю checkin."
        $checkinBody = @{
            note = "Automatic reassignment by SnipeIT Inventory Agent. New user: $Username. Computer: $ComputerName"
        }
        Invoke-SnipeApi -Method POST -Path "/api/v1/hardware/$AssetId/checkin" -Body $checkinBody | Out-Null
    }

    Write-Log "Делаю checkout: asset_id=$AssetId -> user_id=$UserId ($Username)"
    $checkoutNote = "Automatic checkout by SnipeIT Inventory Agent. Computer: $ComputerName. Detected user: $Username"
    $checkoutBody = [ordered]@{
        checkout_to_type = "user"
        assigned_user    = [string]$UserId
        note             = $checkoutNote
    }

    try {
        Write-Log "Checkout payload: checkout_to_type=user; assigned_user=$UserId"
        $checkoutResponse = Invoke-SnipeApi -Method POST -Path "/api/v1/hardware/$AssetId/checkout" -Body $checkoutBody -BodyFormat Form
        $checkoutMessage = Get-SnipeApiMessageText -Response $checkoutResponse
        if (-not [string]::IsNullOrWhiteSpace($checkoutMessage)) {
            Write-Log "Checkout response: $checkoutMessage"
        }

        Start-Sleep -Seconds 1
        $assetAfterCheckout = Get-SnipeAssetById -AssetId $AssetId
        $assignedAfterCheckout = Get-AssignedUserIdFromAsset -Asset $assetAfterCheckout
        if ($assignedAfterCheckout -eq $UserId) {
            Write-Log "Checkout подтвержден: asset_id=$AssetId -> user_id=$UserId ($Username)"
            return [PSCustomObject]@{
                AssetId                = $AssetId
                CheckoutChanged        = [bool]($assignedUserId -and $assignedUserId -ne $UserId)
                PreviousAssignedUserId = $assignedUserId
                PreviousAssignedUser   = $assignedUserLabel
                CurrentAssignedUserId  = $UserId
                CurrentUsername        = $Username
                Action                 = $(if ($assignedUserId) { "reassigned" } else { "assigned" })
            }
        }

        throw "Checkout не подтвердился: после GET assigned_user_id=$assignedAfterCheckout, ожидался $UserId"
    }
    catch {
        $assetAfterError = Get-SnipeAssetById -AssetId $AssetId
        $assignedAfterError = Get-AssignedUserIdFromAsset -Asset $assetAfterError
        if ($assignedAfterError -eq $UserId) {
            Write-Log "Checkout вернул ошибку, но актив id=$AssetId уже привязан к $Username (user_id=$UserId). Считаю OK."
            return [PSCustomObject]@{
                AssetId                = $AssetId
                CheckoutChanged        = [bool]($assignedUserId -and $assignedUserId -ne $UserId)
                PreviousAssignedUserId = $assignedUserId
                PreviousAssignedUser   = $assignedUserLabel
                CurrentAssignedUserId  = $UserId
                CurrentUsername        = $Username
                Action                 = $(if ($assignedUserId) { "reassigned_after_api_error" } else { "assigned_after_api_error" })
            }
        }

        throw "Checkout не подтвердился для asset_id=$AssetId -> user_id=$UserId ($Username). Ошибка: $(Get-ExceptionText $_.Exception)"
    }
}

function Set-SnipeAssetInStock {
    param(
        [int]$AssetId,
        [string]$ComputerName,
        [string]$Reason,
        [object]$ExistingAsset = $null
    )

    if ($DryRun) {
        $dryAssignedUserId = Get-AssignedUserIdFromAsset -Asset $ExistingAsset
        $dryAssignedUserLabel = Get-AssignedUserLabelFromAsset -Asset $ExistingAsset
        $dryPreviousStatusId = Get-SnipeAssetStatusId -Asset $ExistingAsset
        if ($dryAssignedUserId) {
            Write-DryRunAction `
                -Action "check in asset_id=$AssetId from '$dryAssignedUserLabel' to stock" `
                -Reason $Reason
        }
        if ($AssetId -gt 0 -and $dryPreviousStatusId -ne [int]$SnipeStockStatusId) {
            Write-DryRunAction -Action "set asset_id=$AssetId status_id=$SnipeStockStatusId (stock)" -Reason $Reason
        }
        elseif ($AssetId -le 0) {
            Write-DryRunAction -Action "leave new asset unassigned with status_id=$SnipeStockStatusId (stock)" -Reason $Reason
        }
        return [PSCustomObject]@{
            AssetId                = $AssetId
            CheckoutChanged        = $false
            WouldChange            = [bool]($dryAssignedUserId -or $dryPreviousStatusId -ne [int]$SnipeStockStatusId)
            PreviousAssignedUserId = $dryAssignedUserId
            PreviousAssignedUser   = $dryAssignedUserLabel
            CurrentAssignedUserId  = $dryAssignedUserId
            CurrentUsername        = $dryAssignedUserLabel
            PreviousStatusId       = $dryPreviousStatusId
            CurrentStatusId        = $dryPreviousStatusId
            Action                 = $(if ($dryAssignedUserId) { "would_check_in_to_stock" } elseif ($dryPreviousStatusId -ne [int]$SnipeStockStatusId) { "would_set_stock_status" } else { "already_in_stock" })
            Reason                 = $Reason
        }
    }

    $assetFresh = Get-SnipeAssetById -AssetId $AssetId
    $assignedUserId = Get-AssignedUserIdFromAsset -Asset $assetFresh
    $assignedUserLabel = Get-AssignedUserLabelFromAsset -Asset $assetFresh
    $previousStatusId = Get-SnipeAssetStatusId -Asset $assetFresh
    $checkinChanged = $false

    if ($assignedUserId) {
        Write-Log "Склад: asset_id=$AssetId привязан к '$assignedUserLabel' (user_id=$assignedUserId). Выполняю checkin. Причина: $Reason"
        $checkinBody = @{
            note = "Automatic stock checkin by SnipeIT Inventory Agent. Computer: $ComputerName. Reason: $Reason"
        }
        try {
            Invoke-SnipeApi -Method POST -Path "/api/v1/hardware/$AssetId/checkin" -Body $checkinBody | Out-Null
        }
        catch {
            $assetAfterError = Get-SnipeAssetById -AssetId $AssetId
            if (Get-AssignedUserIdFromAsset -Asset $assetAfterError) {
                throw "Checkin на склад не подтвердился для asset_id=$AssetId. Ошибка: $(Get-ExceptionText $_.Exception)"
            }
            Write-Log "Checkin вернул ошибку, но актив уже отвязан. Считаю checkin успешным."
        }
        $checkinChanged = $true
    }
    else {
        Write-Log "Склад: asset_id=$AssetId уже не привязан к пользователю."
    }

    Set-SnipeAssetStatus -AssetId $AssetId -StatusId ([int]$SnipeStockStatusId)
    Start-Sleep -Milliseconds 500
    $assetAfterStock = Get-SnipeAssetById -AssetId $AssetId
    $assignedAfterStock = Get-AssignedUserIdFromAsset -Asset $assetAfterStock
    if ($assignedAfterStock) {
        throw "Складской checkin не подтвердился: asset_id=$AssetId все еще assigned_to=$assignedAfterStock"
    }

    $statusAfterStock = Get-SnipeAssetStatusId -Asset $assetAfterStock
    if ($statusAfterStock -and $statusAfterStock -ne [int]$SnipeStockStatusId) {
        throw "Складской статус не подтвердился: asset_id=$AssetId status_id=$statusAfterStock, ожидался $SnipeStockStatusId"
    }

    return [PSCustomObject]@{
        AssetId                = $AssetId
        CheckoutChanged        = $checkinChanged
        PreviousAssignedUserId = $assignedUserId
        PreviousAssignedUser   = $assignedUserLabel
        CurrentAssignedUserId  = $null
        CurrentUsername        = ""
        PreviousStatusId       = $previousStatusId
        CurrentStatusId        = [int]$SnipeStockStatusId
        Action                 = $(if ($checkinChanged) { "checked_in_to_stock" } else { "stock_unassigned" })
        Reason                 = $Reason
    }
}

function Invoke-SnipeLdapSync {
    param(
        [switch]$Force
    )

    if (-not $Force -and -not $RunLdapSyncBeforeSnipeSearch) {
        Write-Log "LDAP sync перед поиском Snipe-IT выключен. Продолжаю через Snipe-IT API."
        return
    }

    if ($DryRun) {
        Write-DryRunAction -Action "run Snipe-IT LDAP sync over SSH" -Reason $(if ($Force) { "user_missing" } else { "configured_before_search" })
        return
    }

    try {
        Write-Log "Запускаю LDAP sync на Snipe-IT по SSH..."
        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
        [Console]::OutputEncoding = $utf8NoBom
        $script:OutputEncoding = $utf8NoBom

        $effectiveSshKeyPath = Get-EffectiveSnipeSshKeyPath
        if ([string]::IsNullOrWhiteSpace($effectiveSshKeyPath)) {
            Write-Log "LDAP sync пропущен: защищенный SSH-ключ не найден по пути $SnipeSshKeyPath. Продолжаю через Snipe-IT API."
            if (-not [string]::IsNullOrWhiteSpace($SnipeSshPassword)) {
                Write-Log "LDAP sync: пароль задан в настройках, но встроенный ssh.exe не принимает пароль из скрытого GPO-скрипта. Для GPO используется API без принудительного LDAP sync."
            }
            return
        }
        Write-Log "LDAP sync SSH key: $effectiveSshKeyPath"

        $sshArgs = @(
            "-o", "StrictHostKeyChecking=no",
            "-o", "BatchMode=yes",
            "-i", $effectiveSshKeyPath,
            "$SnipeSshUser@$SnipeSshHost",
            $SnipeLdapSyncCommand
        )
        $output = & ssh @sshArgs 2>&1

        $exit = $LASTEXITCODE
        foreach ($line in $output) {
            Write-Log "LDAPSYNC: $(Repair-Utf8Mojibake ([string]$line))"
        }

        if ($exit -ne 0) {
            Write-Log "LDAP sync завершился с кодом $exit. Продолжаю, но пользователь может не найтись."
        }
        elseif (-not $output -or @($output | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }).Count -eq 0) {
            Write-Log "LDAP sync OK (forced-command SSH key, вывод скрыт сервером)."
        }
        else {
            Write-Log "LDAP sync OK."
        }
    }
    catch {
        Write-Log "LDAP sync по SSH не выполнен: $(Get-ExceptionText $_.Exception)"
    }
}

function Resolve-InventoryRelayEventContext {
    param(
        [string]$RequestedDisposition,
        [string]$DetectedUsername,
        [string]$PreviousEventTarget,
        [int]$PreviousEventGeneration,
        [string]$PreviousEventType,
        [string]$PreviousEventDay,
        [string]$CurrentEventDay,
        [bool]$UserChanged,
        [bool]$DispositionChanged,
        [bool]$DeploymentRun,
        [string]$PreviousAgentVersion,
        [string]$CurrentAgentVersion
    )

    $normalizedDisposition = ([string]$RequestedDisposition).Trim().ToLowerInvariant()
    if ($normalizedDisposition -notin @("stock", "preserve")) {
        $normalizedDisposition = "assigned"
    }
    $normalizedUsername = if ($normalizedDisposition -in @("stock", "preserve")) {
        ""
    }
    else {
        ([string]$DetectedUsername).Trim().ToLowerInvariant()
    }
    $eventTarget = "$normalizedDisposition|$normalizedUsername"
    $previousTarget = ([string]$PreviousEventTarget).Trim().ToLowerInvariant()
    $targetInitialized = [string]::IsNullOrWhiteSpace($previousTarget)
    $targetChanged = (-not $targetInitialized -and $previousTarget -ne $eventTarget)

    $generation = [Math]::Max(1, [int]$PreviousEventGeneration)
    if ($targetChanged) {
        $generation++
    }

    if ($normalizedDisposition -eq "stock" -and ($targetInitialized -or $targetChanged -or $DispositionChanged)) {
        $eventType = "stock_checkin"
    }
    elseif ($normalizedDisposition -eq "assigned" -and ($UserChanged -or $targetChanged)) {
        $eventType = "owner_change"
    }
    elseif ($DeploymentRun -or [string]$PreviousAgentVersion -ne [string]$CurrentAgentVersion) {
        $eventType = "install_update"
    }
    else {
        $eventType = "daily_snapshot"
    }

    $sameDay = (
        -not [string]::IsNullOrWhiteSpace($PreviousEventDay) -and
        -not [string]::IsNullOrWhiteSpace($CurrentEventDay) -and
        $PreviousEventDay -eq $CurrentEventDay
    )
    $eventPriority = @{
        daily_snapshot = 1
        install_update = 2
        owner_change   = 3
        stock_checkin  = 3
    }
    $previousType = ([string]$PreviousEventType).Trim().ToLowerInvariant()
    if ($sameDay -and -not $targetChanged -and $eventPriority.ContainsKey($previousType)) {
        $previousPriority = [int]$eventPriority[$previousType]
        $currentPriority = [int]$eventPriority[$eventType]
        if ($previousPriority -gt $currentPriority) {
            $eventType = $previousType
        }
    }

    return [PSCustomObject]@{
        EventTarget    = $eventTarget
        EventGeneration = $generation
        EventType      = $eventType
        EventDay       = $CurrentEventDay
        TargetChanged  = $targetChanged
    }
}

function Test-InventoryErrorRequiresHumanMail {
    param(
        [bool]$InventoryHadError,
        [bool]$RelayAcceptedForDelivery
    )

    return ($InventoryHadError -and -not $RelayAcceptedForDelivery)
}

function New-SnipeRelayPayload {
    param(
        [string]$ComputerName,
        [string]$Domain,
        [string]$SerialNumber,
        [string]$Manufacturer,
        [string]$Model,
        [string]$RawDetectedUsername,
        [string]$DetectedUsername,
        [string]$PreviousUsername,
        [string]$LatestObservedAccount,
        [string]$UsernameSource,
        [int]$UsernameConfidence,
        [string]$UsernameResolutionMethod,
        [string]$CpuName,
        [object]$CpuCores,
        [object]$CpuThreads,
        [string]$CpuSummary,
        [object]$RamGB,
        [string]$RamLayout,
        [string]$RamSummary,
        [string]$OSName,
        [string]$OSVersion,
        [string]$OSBuild,
        [object]$LastBoot,
        [string]$OsSummary,
        [string]$StorageSummary,
        [string]$ObservedAt,
        [string]$ReportDate,
        [string]$RequestedDisposition,
        [string]$DispositionReason,
        [string]$EventType,
        [int]$EventGeneration,
        [int]$ConsecutiveFailureCount
    )

    $identity = [ordered]@{
        raw_username       = $RawDetectedUsername
        detected_username  = $DetectedUsername
        observed_account   = $LatestObservedAccount
        source             = $UsernameSource
        confidence         = $UsernameConfidence
        resolution_method  = $UsernameResolutionMethod
    }
    $hardware = [ordered]@{
        manufacturer    = $Manufacturer
        model           = $Model
        cpu_name        = $CpuName
        cpu_cores       = $CpuCores
        cpu_threads     = $CpuThreads
        cpu_summary     = $CpuSummary
        ram_gb          = $RamGB
        ram_layout      = $RamLayout
        ram_summary     = $RamSummary
        os_name         = $OSName
        os_version      = $OSVersion
        os_build        = $OSBuild
        os_summary      = $OsSummary
        storage_summary = $StorageSummary
        last_boot       = $(if ($LastBoot) { ([datetime]$LastBoot).ToString("o") } else { "" })
    }
    $disposition = [ordered]@{
        requested = $RequestedDisposition
        reason    = $DispositionReason
    }
    $eventDay = ""
    try {
        $eventDay = ([datetimeoffset]::Parse($ObservedAt)).ToString("yyyy-MM-dd")
    }
    catch {
        $eventDay = (Get-Date).ToString("yyyy-MM-dd")
    }
    $relayTargetUsername = if (([string]$RequestedDisposition).Trim().ToLowerInvariant() -eq "assigned") {
        ([string]$DetectedUsername).Trim().ToLowerInvariant()
    }
    else {
        ""
    }
    $fingerprint = [ordered]@{
        payload_schema    = "snipeit.inventory.payload/v1"
        computer_name     = ([string]$ComputerName).Trim().ToLowerInvariant()
        serial_number     = ([string]$SerialNumber).Trim().ToLowerInvariant()
        event_day         = $eventDay
        event_type        = ([string]$EventType).Trim().ToLowerInvariant()
        event_generation = $EventGeneration
        disposition       = ([string]$RequestedDisposition).Trim().ToLowerInvariant()
        target_username   = $relayTargetUsername
    }
    $eventId = Get-StringSha256 -Value ([PSCustomObject]$fingerprint | ConvertTo-Json -Depth 12 -Compress)

    return [ordered]@{
        payload_schema             = "snipeit.inventory.payload/v1"
        schema_version             = 1
        event_id                   = $eventId
        event_type                 = $EventType
        event_generation           = $EventGeneration
        event_day                  = $eventDay
        snipeit_avail              = "no"
        observed_at                = $ObservedAt
        report_date                = $ReportDate
        agent_version              = $InventoryAgentVersion
        consecutive_failure_count  = $ConsecutiveFailureCount
        source_snipe_url            = $SnipeUrl
        computer_name              = $ComputerName
        domain                     = $Domain
        serial_number              = $SerialNumber
        identity                   = $identity
        hardware                   = $hardware
        disposition                = $disposition
    }
}

function Sync-SnipeInventory {
    param(
        [string]$ComputerName,
        [string]$SerialNumber,
        [string]$Manufacturer,
        [string]$Model,
        [string]$DetectedUsername,
        [string]$CpuName,
        [object]$CpuCores,
        [object]$CpuThreads,
        [object]$RamGB,
        [string]$RamLayout,
        [string]$OSName,
        [string]$OSVersion,
        [string]$OSBuild,
        [object]$LastBoot,
        [string]$ReportDate,
        [string]$SuccessfulInventoryTime,
        [string]$CpuSummary,
        [string]$RamSummary,
        [string]$OsSummary,
        [string]$StorageSummary,
        [switch]$ForceStock,
        [switch]$PreserveAssignment,
        [string]$StockReason = ""
    )

    if (-not $SnipeEnabled) {
        Write-Log "Snipe-IT API выключен."
        return "Snipe-IT disabled"
    }

    if ([string]::IsNullOrWhiteSpace($SnipeToken) -or $SnipeToken -in @("ТУТ_API_TOKEN_SNIPEIT", "PUT_SNIPEIT_API_TOKEN_HERE")) {
        throw "Не заполнен Snipe API token."
    }

    $effectiveForceStock = [bool]$ForceStock
    $effectivePreserveAssignment = [bool]$PreserveAssignment
    $effectiveStockReason = [string]$StockReason
    $snipeUser = $null
    $ResolvedUsername = ""
    $warningText = ""
    $snipeUserMissing = $false

    if (-not $effectiveForceStock -and -not $effectivePreserveAssignment) {
        if ($RunLdapSyncBeforeSnipeSearch) {
            Invoke-SnipeLdapSync
        }

        if (-not [string]::IsNullOrWhiteSpace($DetectedUsername)) {
            Write-Log "Ищу пользователя Snipe-IT по username=$DetectedUsername"
            $snipeUser = Find-SnipeUserByUsername -Username $DetectedUsername

            if ((-not $snipeUser -or -not $snipeUser.id) -and $RunLdapSyncIfUserMissing) {
                Write-Log "Пользователь '$DetectedUsername' не найден после первого поиска. Повторяю LDAP sync и поиск через 5 секунд."
                Invoke-SnipeLdapSync -Force
                if (-not $DryRun) { Start-Sleep -Seconds 5 }
                $snipeUser = Find-SnipeUserByUsername -Username $DetectedUsername
            }
        }

        if (-not $snipeUser -or -not $snipeUser.id) {
            if (-not $InventoryCheckinIfSnipeUserMissing) {
                throw "Пользователь '$DetectedUsername' не найден в Snipe-IT даже после LDAP sync."
            }

            $snipeUserMissing = $true
            $effectiveForceStock = $true
            $missingLogin = if ([string]::IsNullOrWhiteSpace($DetectedUsername)) { "unknown" } else { $DetectedUsername }
            $effectiveStockReason = "snipe_user_missing:$missingLogin"
            $warningText = "Пользователь '$missingLogin' не найден в Snipe-IT после LDAP sync. Инвентаризация железа выполнена, актив оставлен без владельца на складе. Проверь членство пользователя в группе синхронизации Snipe-IT."
            Write-Log "Snipe user warning: $warningText"
        }
        else {
            Write-Log "Пользователь найден: id=$($snipeUser.id) username=$($snipeUser.username) name=$($snipeUser.name)"
            $ResolvedUsername = if (-not [string]::IsNullOrWhiteSpace([string]$snipeUser.username)) {
                ([string]$snipeUser.username).Trim()
            }
            else {
                $DetectedUsername
            }
            if ($ResolvedUsername.ToLowerInvariant() -ne $DetectedUsername.Trim().ToLowerInvariant()) {
                Write-Log "Username canonicalized: '$DetectedUsername' -> '$ResolvedUsername'."
            }
        }
    }
    elseif ($effectiveForceStock) {
        if ([string]::IsNullOrWhiteSpace($effectiveStockReason)) { $effectiveStockReason = "stock_requested" }
        Write-Log "Поиск пользователя Snipe-IT пропущен: актив должен быть возвращен на склад. Причина: $effectiveStockReason"
    }
    else {
        Write-Log "Поиск пользователя Snipe-IT пропущен: корректный пользователь не определен, текущее назначение актива будет сохранено."
    }

    $modelId = Get-OrCreateSnipeModelId -ModelName $Model -ManufacturerName $Manufacturer
    $assetUsernameForNotes = $ResolvedUsername
    if ($effectiveForceStock) {
        $stockLogin = if ([string]::IsNullOrWhiteSpace($DetectedUsername)) { "none" } else { $DetectedUsername }
        $assetUsernameForNotes = "UNASSIGNED ($stockLogin; $effectiveStockReason)"
    }
    elseif ($effectivePreserveAssignment) {
        $assetUsernameForNotes = "PRESERVE CURRENT ASSIGNMENT (identity unresolved)"
    }
    $assetNotes = Get-SnipeAssetNotes `
        -ComputerName $ComputerName `
        -SerialNumber $SerialNumber `
        -Manufacturer $Manufacturer `
        -Model $Model `
        -CpuName $CpuName `
        -CpuCores $CpuCores `
        -CpuThreads $CpuThreads `
        -RamGB $RamGB `
        -RamLayout $RamLayout `
        -OSName $OsSummary `
        -OSVersion $OSVersion `
        -OSBuild $OSBuild `
        -LastBoot $LastBoot `
        -DetectedUsername $assetUsernameForNotes `
        -ReportDate $ReportDate `
        -InventoryTimestamp $SuccessfulInventoryTime
    $assetCustomFields = @{
        $SnipeCustomFieldRam     = $RamSummary
        $SnipeCustomFieldCpu     = $CpuSummary
        $SnipeCustomFieldOs      = $OsSummary
        $SnipeCustomFieldStorage = $StorageSummary
        $SnipeCustomFieldAgentVersion = $InventoryAgentVersion
    }

    Write-Log "Ищу актив по SerialNumber=$SerialNumber, fallback ComputerName=$ComputerName"
    $asset = Find-SnipeAsset -SerialNumber $SerialNumber -ComputerName $ComputerName

    if ($asset -and $asset.id) {
        $assetId = [int]$asset.id
        Write-Log "Актив найден: id=$assetId asset_tag=$($asset.asset_tag) name=$($asset.name) serial=$($asset.serial)"
        Update-SnipeAsset -AssetId $assetId -ComputerName $ComputerName -SerialNumber $SerialNumber -ModelId $modelId -Notes $assetNotes -CustomFields $assetCustomFields | Out-Null
    }
    else {
        Write-Log "Актив не найден. Создаю новый."
        $newAssetStatusId = if ($effectiveForceStock -or $effectivePreserveAssignment) { [int]$SnipeStockStatusId } else { [int]$SnipeDefaultStatusId }
        $newAsset = New-SnipeAsset -ComputerName $ComputerName -SerialNumber $SerialNumber -ModelId $modelId -Notes $assetNotes -CustomFields $assetCustomFields -StatusId $newAssetStatusId
        $assetId = [int]$newAsset.id
        if ($DryRun) { Write-Log "DRY RUN: виртуальный asset_id=$assetId используется только для плана действий." }
        else { Write-Log "Новый актив создан: id=$assetId" }
    }

    $assignmentResult = $null
    if ($effectiveForceStock) {
        $assignmentResult = Set-SnipeAssetInStock -AssetId $assetId -ComputerName $ComputerName -Reason $effectiveStockReason -ExistingAsset $asset
    }
    elseif (-not $effectivePreserveAssignment -and $SnipeAutoCheckout) {
        $assignmentResult = Set-SnipeAssetCheckout -AssetId $assetId -UserId ([int]$snipeUser.id) -Username $ResolvedUsername -ComputerName $ComputerName -ExistingAsset $asset
        Set-SnipeAssetStatus -AssetId $assetId -StatusId ([int]$SnipeDefaultStatusId)
    }

    Update-SnipeAssetHealth `
        -AssetId $assetId `
        -LastError $warningText `
        -LastSuccessfulInventory $SuccessfulInventoryTime `
        -ThrowOnError | Out-Null

    $inventoryDisposition = if ($effectiveForceStock) { "stock" } elseif ($effectivePreserveAssignment) { "preserve" } elseif ($SnipeAutoCheckout) { "assigned" } else { "unassigned" }
    $resultText = if ($DryRun) {
        $plannedAction = if ($assignmentResult) { [string]$assignmentResult.Action } elseif ($effectiveForceStock) { "would_leave_in_stock" } else { "inventory_only" }
        "DRY RUN: asset_id=$assetId planned_action=$plannedAction disposition=$inventoryDisposition reason=$(if ($effectiveForceStock) { $effectiveStockReason } elseif ($effectivePreserveAssignment) { 'identity_unresolved_preserve_assignment' } else { 'user_checkout' })"
    }
    elseif (-not [string]::IsNullOrWhiteSpace($warningText)) {
        "WARNING: asset_id=$assetId disposition=$inventoryDisposition reason=$effectiveStockReason; $warningText"
    }
    elseif ($effectiveForceStock) {
        "OK: asset_id=$assetId disposition=stock reason=$effectiveStockReason"
    }
    elseif ($effectivePreserveAssignment) {
        "OK: asset_id=$assetId disposition=preserve reason=identity_unresolved_preserve_assignment"
    }
    else {
        "OK: asset_id=$assetId user=$ResolvedUsername disposition=$inventoryDisposition"
    }

    return [PSCustomObject]@{
        ResultText             = $resultText
        AssetId                = $assetId
        RequestedUsername       = $DetectedUsername
        ResolvedUsername        = $ResolvedUsername
        AssetUserChanged       = [bool]($assignmentResult -and $assignmentResult.CheckoutChanged)
        PreviousAssignedUserId = $(if ($assignmentResult) { $assignmentResult.PreviousAssignedUserId } else { $null })
        PreviousAssignedUser   = $(if ($assignmentResult) { $assignmentResult.PreviousAssignedUser } else { "" })
        CheckoutAction         = $(if ($assignmentResult) { $assignmentResult.Action } else { "checkout_disabled" })
        InventoryDisposition   = $inventoryDisposition
        DispositionReason      = $(if ($effectiveForceStock) { $effectiveStockReason } elseif ($effectivePreserveAssignment) { "identity_unresolved_preserve_assignment" } else { "user_checkout" })
        StockDisposition       = $effectiveForceStock
        StockCheckin           = [bool]($effectiveForceStock -and $assignmentResult -and $assignmentResult.CheckoutChanged)
        DryRun                 = [bool]$DryRun
        DryRunWouldChange      = [bool]($assignmentResult -and $assignmentResult.PSObject.Properties["WouldChange"] -and $assignmentResult.WouldChange)
        SnipeUserMissing       = $snipeUserMissing
        WarningText            = $warningText
    }
}

if ($LibraryMode) {
    return
}

$InventoryMutex = $null
$InventoryMutexAcquired = $false
try {
    $InventoryMutex = New-Object System.Threading.Mutex($false, "Global\SnipeITInventoryAgent")
    $InventoryMutexAcquired = $InventoryMutex.WaitOne(0)
    if (-not $InventoryMutexAcquired) {
        Write-Log "Другой экземпляр SnipeIT Inventory Agent уже выполняется. Текущий запуск пропущен."
        if ($InventoryMutex) { $InventoryMutex.Dispose() }
        return
    }
}
catch {
    Write-Log "Mutex недоступен, продолжаю без блокировки: $(Get-ExceptionText $_.Exception)"
}

$ProcessExitCode = 0
$StateFile = $null
$InventoryState = $null
$StateData = [ordered]@{}
$PendingMailQueue = @()
$MailEventHistory = @()
$KnownAssetId = 0

try {
    Write-Log "==== START ===="
    Write-Log "Agent version: $InventoryAgentVersion"
    Write-Log "State schema version: $InventoryStateSchemaVersion"
    if ($DryRun) {
        Write-Log "DRY RUN enabled: Snipe-IT reads and local report/log writes are allowed; API mutations, LDAP sync, SMTP and state persistence are blocked."
    }
    $StateFile = Get-StateFilePath
    $InventoryState = Get-InventoryState -Path $StateFile
    $StateData = ConvertTo-InventoryStateMap -State $InventoryState
    $PendingMailQueue = @(Get-PendingMailQueue -State $InventoryState)
    $pendingMailCountBeforeRetention = $PendingMailQueue.Count
    $PendingMailQueue = @(Limit-PendingInventoryMailQueue -Queue $PendingMailQueue)
    if ($pendingMailCountBeforeRetention -gt $PendingMailQueue.Count) {
        Write-Log "SMTP queue retention: удалено устаревших/лишних элементов: $($pendingMailCountBeforeRetention - $PendingMailQueue.Count); осталось=$($PendingMailQueue.Count)."
    }
    $MailEventHistory = @(Get-InventoryMailEventHistory -State $InventoryState)
    $StateData["mail_event_history"] = [object[]]$MailEventHistory
    if ($InventoryRelayEnabled -and $PendingMailQueue.Count -gt 0) {
        $migratedPendingMailQueue = @(Remove-LegacySnipeTransportErrorMails -Queue $PendingMailQueue)
        $legacyTransportErrorMailCount = $PendingMailQueue.Count - $migratedPendingMailQueue.Count
        if ($legacyTransportErrorMailCount -gt 0) {
            if ($DryRun) {
                Write-DryRunAction `
                    -Action "purge $legacyTransportErrorMailCount legacy Snipe transport error email(s) from the 1.2.x queue" `
                    -Reason "relay_replaces_client_dns_api_error"
            }
            else {
                $PendingMailQueue = $migratedPendingMailQueue
                $StateData["legacy_transport_error_mails_purged"] = [int]$legacyTransportErrorMailCount
                $StateData["legacy_transport_error_mails_purged_at"] = (Get-Date).ToString("o")
                Write-Log "SMTP migration: удалено старых transport-error писем 1.2.x: $legacyTransportErrorMailCount. Relay заменяет клиентские DNS/API alerts."
                Save-InventoryStateSnapshot -Path $StateFile -State $StateData -PendingMails $PendingMailQueue | Out-Null
            }
        }
    }
    if ($InventoryState -and $InventoryState.snipe_asset_id) {
        $KnownAssetId = [int]$InventoryState.snipe_asset_id
    }
    $LoadedStateSchemaVersion = 0
    if ($InventoryState -and $InventoryState.PSObject.Properties["schema_version"]) {
        try { $LoadedStateSchemaVersion = [int]$InventoryState.schema_version } catch { $LoadedStateSchemaVersion = 0 }
    }
    Write-Log "State loaded: schema_version=$LoadedStateSchemaVersion current_schema=$InventoryStateSchemaVersion pending_mail_count=$($PendingMailQueue.Count) mail_history_count=$($MailEventHistory.Count) known_asset_id=$KnownAssetId"
    if ($InventoryState -and $LoadedStateSchemaVersion -lt $InventoryStateSchemaVersion) {
        Write-Log "State schema upgrade: $LoadedStateSchemaVersion -> $InventoryStateSchemaVersion (backward-compatible)."
    }

    Initialize-SnipeHttps
    Write-Log "TLS 1.2 включен. Snipe-IT URL: $SnipeUrl"

    Write-Log "Собираю данные ПК..."
    $bios = Get-CimInstance Win32_BIOS -ErrorAction Stop
    $cs   = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop
    $os   = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
    $cpu  = Get-CimInstance Win32_Processor -ErrorAction Stop | Select-Object -First 1

    try {
        $ramModules = @(Get-CimInstance Win32_PhysicalMemory -ErrorAction Stop | Where-Object {
            -not $_.PSObject.Properties["Capacity"] -or [uint64]$_.Capacity -gt 0
        })
    }
    catch { $ramModules = @() }
    try {
        $memoryDeviceCount = (Get-CimInstance Win32_PhysicalMemoryArray -ErrorAction Stop |
            Where-Object { -not $_.Use -or [int]$_.Use -eq 3 } |
            Measure-Object -Property MemoryDevices -Sum).Sum
    }
    catch { $memoryDeviceCount = $null }

    try { $physicalDisks = @(Get-PhysicalDisk -ErrorAction Stop) }
    catch {
        try { $physicalDisks = @(Get-CimInstance Win32_DiskDrive -ErrorAction Stop) }
        catch { $physicalDisks = @() }
    }

    $ComputerName = $env:COMPUTERNAME
    $RawSerialNumber = Normalize-InventoryText ([string]$bios.SerialNumber)
    $SerialNumber = Normalize-SerialNumber $RawSerialNumber
    $Manufacturer = Normalize-InventoryText ([string]$cs.Manufacturer)
    $Model        = Normalize-InventoryText ([string]$cs.Model)
    $CurrentUser  = $cs.UserName
    $Domain       = $cs.Domain

    $OSName       = $os.Caption
    $OSVersion    = $os.Version
    $OSBuild      = $os.BuildNumber
    $LastBoot     = $os.LastBootUpTime
    $InventoryMoment = [datetimeoffset]::Now
    $ReportDate = $InventoryMoment.ToString(
        "dd.MM.yyyy HH:mm:ss",
        [System.Globalization.CultureInfo]::InvariantCulture
    )
    $InventoryTimestamp = $InventoryMoment.ToString("o")

    $CpuName    = $cpu.Name
    $CpuCores   = $cpu.NumberOfCores
    $CpuThreads = $cpu.NumberOfLogicalProcessors

    if ($ramModules.Count -gt 0) {
        $RamBytes = ($ramModules | Measure-Object -Property Capacity -Sum).Sum
    }
    else {
        $RamBytes = $cs.TotalPhysicalMemory
    }
    $RamGB = [math]::Round($RamBytes / 1GB, 2)

    $CpuSummary = Get-CpuInventorySummary -Cpu $cpu
    $RamDetails = Get-RamInventoryDetails -RamModules $ramModules -RamGB $RamGB -FallbackSlotCount $memoryDeviceCount
    $RamSummary = $RamDetails.Summary
    $RamLayout = $RamDetails.Layout
    $RamModuleDetails = $RamDetails.ModuleDetails
    $OsSummary = Get-OsInventorySummary -OSName $OSName -OSBuild $OSBuild
    $StorageSummary = Get-StorageInventorySummary -Disks $physicalDisks

    Write-Log "ПК: $ComputerName / $Manufacturer / $Model / SN: $SerialNumber"
    Write-Log "CPU: $CpuName / Cores: $CpuCores / Threads: $CpuThreads"
    Write-Log "RAM: $RamGB GB / Layout: $RamLayout"
    Write-Log "RAM modules: $RamModuleDetails"
    Write-Log "Inventory fields: RAM='$RamSummary'; CPU='$CpuSummary'; OS='$OsSummary'; Storage='$StorageSummary'"

    $lastUsers = Get-LastUsers
    $LatestObservedUser = Get-LatestObservedInventoryUser -CurrentUser $CurrentUser -LastUsers $lastUsers
    $LatestObservedAccount = [string]$LatestObservedUser.Account
    $LatestObservedUsername = [string]$LatestObservedUser.Login
    $RawDetectedUsername = Get-InventoryUsername -CurrentUser $CurrentUser -LastUsers $lastUsers
    $PreviousAppliedUsername = [string]$InventoryState.detected_username
    $PreviousSeenUsername = [string]$InventoryState.last_seen_username
    $PreviousStoredUsername = @($PreviousAppliedUsername, $PreviousSeenUsername) |
        Where-Object { Test-InventoryAccountIdentifier -AccountName ([string]$_) } |
        Select-Object -First 1
    if ($null -eq $PreviousStoredUsername) {
        $PreviousStoredUsername = ""
    }
    $PreviousUsername = Resolve-InventoryUsernameLocally -Username $PreviousStoredUsername -State $InventoryState
    $DetectedUsername = Resolve-InventoryUsernameLocally -Username $RawDetectedUsername -State $InventoryState
    $IdentityFallbackUsed = $false
    if (-not (Test-InventoryAccountIdentifier -AccountName $DetectedUsername) -and
        (Test-InventoryAccountIdentifier -AccountName $PreviousUsername)) {
        $DetectedUsername = $PreviousUsername
        $IdentityFallbackUsed = $true
        Write-Log "No valid current identity was found. Keeping previously confirmed username '$DetectedUsername'."
    }
    if (-not (Test-InventoryAccountIdentifier -AccountName $DetectedUsername)) {
        $DetectedUsername = ""
    }
    $LatestIsStockAccount = Test-InventoryUsernameMatchesPatterns -Username $LatestObservedUsername -Patterns $InventoryStockUsernamePatterns
    if (-not $IdentityFallbackUsed) {
        $UsernameConfidenceDetails = Get-InventoryUsernameConfidence `
            -RawUsername $RawDetectedUsername `
            -ResolvedUsername $DetectedUsername `
            -State $InventoryState `
            -ObservedSource ([string]$LatestObservedUser.Source)
    }
    if ($IdentityFallbackUsed) {
        $UsernameConfidenceDetails = [PSCustomObject]@{
            Confidence = 80; ResolutionConfidence = 80; SourceConfidence = 80
            Method = "state_previous_confirmed"; Source = "inventory-state"
            RawUsername = ""; ResolvedUsername = $DetectedUsername
        }
    }

    $AdUserState = [PSCustomObject]@{
        LookupSucceeded = $false; Found = $false; Username = ""; Disabled = $false
        DescriptionMatched = $false; OuMatched = $false; Terminated = $false; TerminationReason = ""
        DistinguishedName = ""; Error = "not_checked"
    }
    if (-not $LatestIsStockAccount -and -not [string]::IsNullOrWhiteSpace($DetectedUsername)) {
        $adExactCandidates = @(
            @($LatestObservedUsername, $RawDetectedUsername, $DetectedUsername) |
                Where-Object {
                    -not (Test-InventoryUsernameMatchesPatterns `
                        -Username ([string]$_) `
                        -Patterns $InventoryExcludedUsernamePatterns)
                } |
                Select-Object -Unique
        )
        $AdUserState = Get-AdInventoryUserState -Usernames $adExactCandidates
        if ($AdUserState.LookupSucceeded -and -not $AdUserState.Found) {
            $legacyAdCandidates = Get-LegacyInventoryUsernameCandidates -Usernames $adExactCandidates
            if ($legacyAdCandidates.Count -gt 0) {
                $legacyAdUserState = Get-AdInventoryUserState -Usernames $legacyAdCandidates
                if ($legacyAdUserState.LookupSucceeded -and $legacyAdUserState.Found) {
                    $AdUserState = $legacyAdUserState
                    if (Test-InventoryUsernameMapsToCanonical -Username $DetectedUsername -CanonicalUsername ([string]$AdUserState.Username)) {
                        Write-Log "AD username canonicalized after exact lookup miss: '$DetectedUsername' -> '$($AdUserState.Username)'."
                        $DetectedUsername = ([string]$AdUserState.Username).Trim()
                    }
                }
            }
        }
        if ($AdUserState.LookupSucceeded) {
            Write-Log "AD user state: found=$($AdUserState.Found) username='$($AdUserState.Username)' disabled=$($AdUserState.Disabled) description_terminated=$($AdUserState.DescriptionMatched) ou_terminated=$($AdUserState.OuMatched)."
        }
        else {
            Write-Log "AD user state недоступен; это не является основанием для checkin: $($AdUserState.Error)"
        }
    }

    $StockDispositionRequested = $false
    $StockDispositionReason = ""
    if ($LatestIsStockAccount) {
        $StockDispositionRequested = $true
        $StockDispositionReason = "last_login_stock_account:$LatestObservedUsername"
    }
    elseif ($AdUserState.LookupSucceeded -and $AdUserState.Found -and $AdUserState.Terminated) {
        $StockDispositionRequested = $true
        $StockDispositionReason = "$($AdUserState.TerminationReason):$($AdUserState.Username)"
    }

    $StateData["last_seen_raw_username"] = $(if (Test-InventoryAccountIdentifier -AccountName $RawDetectedUsername) { $RawDetectedUsername } else { "" })
    $StateData["last_seen_username"] = $DetectedUsername
    $StateData["last_seen_username_time"] = (Get-Date).ToString("o")
    $StateData["last_observed_account"] = $LatestObservedAccount
    $StateData["last_observed_username"] = $LatestObservedUsername
    $StateData["last_observed_source"] = [string]$LatestObservedUser.Source
    $StateData["identity_fallback_used"] = [bool]$IdentityFallbackUsed
    $StateData["username_confidence"] = [int]$UsernameConfidenceDetails.Confidence
    $StateData["username_resolution_confidence"] = [int]$UsernameConfidenceDetails.ResolutionConfidence
    $StateData["username_source_confidence"] = [int]$UsernameConfidenceDetails.SourceConfidence
    $StateData["username_resolution_method"] = [string]$UsernameConfidenceDetails.Method
    $StateData["ad_lookup_succeeded"] = [bool]$AdUserState.LookupSucceeded
    $StateData["ad_user_found"] = [bool]$AdUserState.Found
    $StateData["ad_user_disabled"] = [bool]$AdUserState.Disabled
    $StateData["ad_description_terminated"] = [bool]$AdUserState.DescriptionMatched
    $StateData["ad_ou_terminated"] = [bool]$AdUserState.OuMatched
    Write-Log "Username detection: latest='$LatestObservedAccount' source='$($LatestObservedUser.Source)'; raw='$RawDetectedUsername'; canonical='$DetectedUsername'; previous_stored='$PreviousStoredUsername'; previous_canonical='$PreviousUsername'."
    Write-Log "Username confidence: $($UsernameConfidenceDetails.Confidence) method=$($UsernameConfidenceDetails.Method) resolution=$($UsernameConfidenceDetails.ResolutionConfidence) source_confidence=$($UsernameConfidenceDetails.SourceConfidence) source='$($UsernameConfidenceDetails.Source)'."
    if ($StockDispositionRequested) {
        Write-Log "Stock disposition requested: $StockDispositionReason"
    }

    $LastInventoryTime = $null
    if ($InventoryState.last_inventory_time) {
        try { $LastInventoryTime = [datetime]$InventoryState.last_inventory_time }
        catch { $LastInventoryTime = $null }
    }

    $UserChanged = $false
    if (-not [string]::IsNullOrWhiteSpace($PreviousUsername) -and -not [string]::IsNullOrWhiteSpace($DetectedUsername)) {
        $UserChanged = ($PreviousUsername.Trim().ToLower() -ne $DetectedUsername.Trim().ToLower())
    }

    $PreviousDisposition = [string]$InventoryState.inventory_disposition
    if ([string]::IsNullOrWhiteSpace($PreviousDisposition) -and -not [string]::IsNullOrWhiteSpace($PreviousStoredUsername)) {
        $PreviousDisposition = "assigned"
    }
    $RequestedDisposition = if ($StockDispositionRequested) {
        "stock"
    }
    elseif (Test-InventoryAccountIdentifier -AccountName $DetectedUsername) {
        "assigned"
    }
    else {
        "preserve"
    }
    $DispositionChanged = (
        -not [string]::IsNullOrWhiteSpace($PreviousDisposition) -and
        $PreviousDisposition -ne $RequestedDisposition
    )
    if ($PreviousDisposition -eq "stock" -and -not $StockDispositionRequested -and -not [string]::IsNullOrWhiteSpace($DetectedUsername)) {
        $UserChanged = $true
    }

    $RelayEventDay = ([datetimeoffset]::Parse($InventoryTimestamp)).ToString("yyyy-MM-dd")
    $previousRelayEventGeneration = 0
    try { $previousRelayEventGeneration = [int]$InventoryState.relay_event_generation } catch { $previousRelayEventGeneration = 0 }
    $relayEventContext = Resolve-InventoryRelayEventContext `
        -RequestedDisposition $RequestedDisposition `
        -DetectedUsername $DetectedUsername `
        -PreviousEventTarget ([string]$InventoryState.relay_event_target) `
        -PreviousEventGeneration $previousRelayEventGeneration `
        -PreviousEventType ([string]$InventoryState.relay_event_type) `
        -PreviousEventDay ([string]$InventoryState.relay_event_day) `
        -CurrentEventDay $RelayEventDay `
        -UserChanged $UserChanged `
        -DispositionChanged $DispositionChanged `
        -DeploymentRun ([bool]$DeploymentRun) `
        -PreviousAgentVersion ([string]$InventoryState.agent_version) `
        -CurrentAgentVersion $InventoryAgentVersion
    $relayEventTarget = [string]$relayEventContext.EventTarget
    $RelayEventGeneration = [int]$relayEventContext.EventGeneration
    $RelayEventType = [string]$relayEventContext.EventType
    $relayTargetChanged = [bool]$relayEventContext.TargetChanged
    $StateData["relay_event_target"] = $relayEventTarget
    $StateData["relay_event_generation"] = $RelayEventGeneration
    $StateData["relay_event_type"] = $RelayEventType
    $StateData["relay_event_day"] = $RelayEventDay

    $NeverInventoried = ($null -eq $LastInventoryTime)
    $DueByInterval = $NeverInventoried -or (((Get-Date) - $LastInventoryTime).TotalDays -ge $InventoryIntervalDays)
    $ShouldRunInventory = $DryRun -or $ManualMode -or $ForceInventory -or $UserChanged -or $DispositionChanged -or $DueByInterval

    $RunReason = @()
    if ($ManualMode) { $RunReason += "manual" }
    if ($DryRun) { $RunReason += "dry_run" }
    if ($ForceInventory) { $RunReason += "force_inventory" }
    if ($UserChanged) { $RunReason += "user_changed:$PreviousUsername->$DetectedUsername" }
    if ($DispositionChanged) { $RunReason += "disposition_changed:$PreviousDisposition->$RequestedDisposition" }
    if ($StockDispositionRequested) { $RunReason += "stock:$StockDispositionReason" }
    if ($RequestedDisposition -eq "preserve") { $RunReason += "identity_unresolved_preserve_assignment" }
    if ($IdentityFallbackUsed) { $RunReason += "identity_fallback_previous_confirmed:$DetectedUsername" }
    if (-not [string]::IsNullOrWhiteSpace($RawDetectedUsername) -and -not [string]::IsNullOrWhiteSpace($DetectedUsername) -and
        $RawDetectedUsername.Trim().ToLowerInvariant() -ne $DetectedUsername.Trim().ToLowerInvariant()) {
        $RunReason += "username_alias:$RawDetectedUsername->$DetectedUsername"
    }
    if ($DueByInterval) { $RunReason += "interval_${InventoryIntervalDays}_days" }
    if ($RunReason.Count -eq 0) { $RunReason += "skip_not_due" }
    $RunReasonText = ($RunReason -join ", ")

    Write-Log "Auto inventory decision: ShouldRun=$ShouldRunInventory; DryRun=$DryRun; Reason=$RunReasonText; PreviousUser=$PreviousUsername; PreviousDisposition=$PreviousDisposition; LastInventory=$LastInventoryTime"

    $SnipeResult = "Snipe-IT не запускался"
    $SnipeResultText = $SnipeResult
    $SnipeAssetUserChanged = $false
    $SnipePreviousAssignedUser = ""
    $SnipeCheckoutAction = ""
    $SnipeAssetId = $KnownAssetId
    $InventoryDisposition = $RequestedDisposition
    $InventoryDispositionReason = $(if ($StockDispositionRequested) { $StockDispositionReason } elseif ($RequestedDisposition -eq "preserve") { "identity_unresolved_preserve_assignment" } else { "user_checkout" })
    $SnipeStockCheckin = $false
    $SnipeUserMissing = $false
    $SnipeWarningText = ""
    $SnipeDryRunWouldChange = $false
    $SnipeAvailabilityFlag = [string]$InventoryState.snipeit_avail
    if ([string]::IsNullOrWhiteSpace($SnipeAvailabilityFlag)) { $SnipeAvailabilityFlag = "unknown" }
    $SnipeConsecutiveFailures = 0
    if ($InventoryState -and $InventoryState.PSObject.Properties["snipe_consecutive_failures"]) {
        try { $SnipeConsecutiveFailures = [int]$InventoryState.snipe_consecutive_failures } catch { $SnipeConsecutiveFailures = 0 }
    }
    $SnipeRelayQueued = $false
    $SnipeRelayEventId = ""
    $SnipeRelayAcceptedForDelivery = $false
    if ($ShouldRunInventory) {
        try {
            if ($SnipeEnabled) {
                $SnipeAvailabilityFlag = "checking"
                $availability = Test-SnipeApiAvailability
                $SnipeAvailabilityFlag = [string]$availability.Flag
                $StateData["snipeit_avail"] = $SnipeAvailabilityFlag
                if (-not $availability.Available) {
                    throw "SNIPEIT_UNAVAILABLE: $($availability.Error)"
                }
            }
            else {
                $SnipeAvailabilityFlag = "disabled"
                $StateData["snipeit_avail"] = "disabled"
            }

            $SnipeSyncResult = Sync-SnipeInventory `
                -ComputerName $ComputerName `
                -SerialNumber $SerialNumber `
                -Manufacturer $Manufacturer `
                -Model $Model `
                -DetectedUsername $DetectedUsername `
                -CpuName $CpuName `
                -CpuCores $CpuCores `
                -CpuThreads $CpuThreads `
                -RamGB $RamGB `
                -RamLayout $RamLayout `
                -OSName $OSName `
                -OSVersion $OSVersion `
                -OSBuild $OSBuild `
                -LastBoot $LastBoot `
                -ReportDate $ReportDate `
                -SuccessfulInventoryTime $InventoryTimestamp `
                -CpuSummary $CpuSummary `
                -RamSummary $RamSummary `
                -OsSummary $OsSummary `
                -StorageSummary $StorageSummary `
                -ForceStock:$StockDispositionRequested `
                -PreserveAssignment:($RequestedDisposition -eq "preserve") `
                -StockReason $StockDispositionReason

            if ($SnipeSyncResult -and $SnipeSyncResult.PSObject.Properties["ResultText"]) {
                $SnipeResultText = [string]$SnipeSyncResult.ResultText
                $SnipeResult = $SnipeResultText
                $SnipeAssetUserChanged = [bool]$SnipeSyncResult.AssetUserChanged
                $SnipePreviousAssignedUser = [string]$SnipeSyncResult.PreviousAssignedUser
                $SnipeCheckoutAction = [string]$SnipeSyncResult.CheckoutAction
                $InventoryDisposition = [string]$SnipeSyncResult.InventoryDisposition
                $InventoryDispositionReason = [string]$SnipeSyncResult.DispositionReason
                $SnipeStockCheckin = [bool]$SnipeSyncResult.StockCheckin
                $SnipeUserMissing = [bool]$SnipeSyncResult.SnipeUserMissing
                $SnipeWarningText = [string]$SnipeSyncResult.WarningText
                if ($SnipeSyncResult.PSObject.Properties["DryRunWouldChange"]) {
                    $SnipeDryRunWouldChange = [bool]$SnipeSyncResult.DryRunWouldChange
                }
                if ($SnipeSyncResult.PSObject.Properties["ResolvedUsername"] -and
                    -not [string]::IsNullOrWhiteSpace([string]$SnipeSyncResult.ResolvedUsername)) {
                    $resolvedSnipeUsername = ([string]$SnipeSyncResult.ResolvedUsername).Trim()
                    if ($resolvedSnipeUsername.ToLowerInvariant() -ne $DetectedUsername.Trim().ToLowerInvariant()) {
                        Write-Log "Snipe-IT confirmed username: '$DetectedUsername' -> '$resolvedSnipeUsername'."
                    }
                    $DetectedUsername = $resolvedSnipeUsername
                    $finalRelayTargetUsername = if ($RequestedDisposition -in @("stock", "preserve")) {
                        ""
                    }
                    else {
                        ([string]$DetectedUsername).Trim().ToLowerInvariant()
                    }
                    $StateData["relay_event_target"] = "$($RequestedDisposition.ToLowerInvariant())|$finalRelayTargetUsername"

                    if (Test-InventoryUsernameMapsToCanonical -Username $PreviousUsername -CanonicalUsername $DetectedUsername) {
                        $PreviousUsername = $DetectedUsername
                    }

                    $UserChanged = $false
                    if (-not [string]::IsNullOrWhiteSpace($PreviousUsername)) {
                        $UserChanged = ($PreviousUsername.Trim().ToLowerInvariant() -ne $DetectedUsername.Trim().ToLowerInvariant())
                    }

                    $RunReason = @($RunReason | Where-Object { $_ -notlike "user_changed:*" -and $_ -notlike "username_alias:*" })
                    if ($UserChanged) { $RunReason += "user_changed:$PreviousUsername->$DetectedUsername" }
                    if (-not [string]::IsNullOrWhiteSpace($RawDetectedUsername) -and
                        $RawDetectedUsername.Trim().ToLowerInvariant() -ne $DetectedUsername.Trim().ToLowerInvariant()) {
                        $RunReason += "username_alias:$RawDetectedUsername->$DetectedUsername"
                    }
                    $RunReasonText = ($RunReason | Select-Object -Unique) -join ", "
                }
                if ($SnipeSyncResult.AssetId) {
                    $SnipeAssetId = [int]$SnipeSyncResult.AssetId
                    $KnownAssetId = $SnipeAssetId
                }

                if (-not [string]::IsNullOrWhiteSpace($InventoryDisposition)) {
                    $DispositionChanged = (
                        -not [string]::IsNullOrWhiteSpace($PreviousDisposition) -and
                        $PreviousDisposition -ne $InventoryDisposition
                    )
                    if ($DispositionChanged) {
                        $RunReason += "disposition_changed:$PreviousDisposition->$InventoryDisposition"
                    }
                    if ($InventoryDisposition -eq "stock") {
                        $RunReason += "stock:$InventoryDispositionReason"
                    }
                    $RunReasonText = ($RunReason | Select-Object -Unique) -join ", "
                }
            }
            else {
                $SnipeResultText = [string]$SnipeSyncResult
                $SnipeResult = $SnipeResultText
            }

            if ($SnipeAssetUserChanged) {
                $assignmentTarget = if ($InventoryDisposition -eq "stock") { "STOCK" } else { $DetectedUsername }
                $RunReason += "snipe_user_changed:$SnipePreviousAssignedUser->$assignmentTarget"
                $RunReasonText = ($RunReason | Select-Object -Unique) -join ", "
                Write-Log "Snipe-IT owner changed: previous='$SnipePreviousAssignedUser' current='$assignmentTarget' action=$SnipeCheckoutAction"
            }

            Write-Log "Snipe-IT result: $SnipeResultText"
            $SnipeConsecutiveFailures = 0
            $StateData["snipe_consecutive_failures"] = 0
            $StateData["snipe_last_direct_success_at"] = $InventoryTimestamp
            $StateData["snipe_last_direct_error"] = ""
            $StateData["snipe_relay_queued"] = $false
            $StateData["snipe_relay_error"] = ""
            $obsoleteRelayMails = @($PendingMailQueue | Where-Object { [string]$_.reason -eq "snipeit_relay" })
            if ($obsoleteRelayMails.Count -gt 0) {
                $PendingMailQueue = @($PendingMailQueue | Where-Object { [string]$_.reason -ne "snipeit_relay" })
                Write-Log "Snipe relay: удалено устаревших неотправленных payload после прямого успеха: $($obsoleteRelayMails.Count)."
            }

            $StateData["computer_name"] = $ComputerName
            $StateData["serial_number"] = $SerialNumber
            $StateData["raw_detected_username"] = $RawDetectedUsername
            $StateData["detected_username"] = $DetectedUsername
            $StateData["previous_username"] = $PreviousUsername
            $StateData["last_inventory_time"] = $InventoryTimestamp
            $StateData["last_successful_inventory"] = $InventoryTimestamp
            $StateData["last_run_reason"] = $RunReasonText
            $StateData["snipe_result"] = $SnipeResultText
            $StateData["snipe_asset_id"] = $SnipeAssetId
            $StateData["snipe_asset_user_changed"] = $SnipeAssetUserChanged
            $StateData["snipe_previous_assigned_user"] = $SnipePreviousAssignedUser
            $StateData["snipe_checkout_action"] = $SnipeCheckoutAction
            $StateData["inventory_disposition"] = $InventoryDisposition
            $StateData["inventory_disposition_reason"] = $InventoryDispositionReason
            $StateData["snipe_stock_checkin"] = $SnipeStockCheckin
            $StateData["snipe_user_missing"] = $SnipeUserMissing
            if (-not [string]::IsNullOrWhiteSpace($SnipeWarningText)) {
                $StateData["last_error"] = Limit-InventoryText -Value $SnipeWarningText -MaxLength 2000
                $StateData["last_error_source"] = "snipe_user_missing"
                $StateData["last_error_time"] = (Get-Date).ToString("o")
            }
            else {
                $StateData["last_error"] = ""
                $StateData["last_error_source"] = ""
                $StateData["last_error_time"] = $null
            }
            Add-LearnedInventoryUsernameAlias -State $StateData -RawUsername $RawDetectedUsername -CanonicalUsername $DetectedUsername
            Save-InventoryStateSnapshot -Path $StateFile -State $StateData -PendingMails $PendingMailQueue | Out-Null
        }
        catch {
            $snipeExceptionText = Get-ExceptionText $_.Exception
            $snipeUnavailable = ($SnipeAvailabilityFlag -eq "no") -or (Test-SnipeUnavailableException -Exception $_.Exception)
            if ($snipeUnavailable) {
                $SnipeAvailabilityFlag = "no"
                $SnipeConsecutiveFailures++
                $StateData["snipeit_avail"] = "no"
                $StateData["snipe_consecutive_failures"] = $SnipeConsecutiveFailures
                $StateData["snipe_last_direct_failure_at"] = (Get-Date).ToString("o")
                $StateData["snipe_last_direct_error"] = Limit-InventoryText -Value $snipeExceptionText -MaxLength 2000

                $relayThreshold = [Math]::Max(1, [int]$InventoryRelayFailureThreshold)
                if ($InventoryRelayEnabled -and $SnipeConsecutiveFailures -ge $relayThreshold -and -not $DryRun) {
                    try {
                        $relayPayload = New-SnipeRelayPayload `
                            -ComputerName $ComputerName `
                            -Domain $Domain `
                            -SerialNumber $SerialNumber `
                            -Manufacturer $Manufacturer `
                            -Model $Model `
                            -RawDetectedUsername $RawDetectedUsername `
                            -DetectedUsername $DetectedUsername `
                            -PreviousUsername $PreviousUsername `
                            -LatestObservedAccount $LatestObservedAccount `
                            -UsernameSource ([string]$LatestObservedUser.Source) `
                            -UsernameConfidence ([int]$UsernameConfidenceDetails.Confidence) `
                            -UsernameResolutionMethod ([string]$UsernameConfidenceDetails.Method) `
                            -CpuName $CpuName `
                            -CpuCores $CpuCores `
                            -CpuThreads $CpuThreads `
                            -CpuSummary $CpuSummary `
                            -RamGB $RamGB `
                            -RamLayout $RamLayout `
                            -RamSummary $RamSummary `
                            -OSName $OSName `
                            -OSVersion $OSVersion `
                            -OSBuild $OSBuild `
                            -LastBoot $LastBoot `
                            -OsSummary $OsSummary `
                            -StorageSummary $StorageSummary `
                            -ObservedAt $InventoryTimestamp `
                            -ReportDate $ReportDate `
                            -RequestedDisposition $RequestedDisposition `
                            -DispositionReason $InventoryDispositionReason `
                            -EventType $RelayEventType `
                            -EventGeneration $RelayEventGeneration `
                            -ConsecutiveFailureCount $SnipeConsecutiveFailures
                        $relayMail = New-SnipeRelayMailEntry -Payload $relayPayload
                        $SnipeRelayEventId = [string]$relayPayload["event_id"]
                        $existingRelay = $PendingMailQueue | Where-Object { [string]$_.event_key -eq [string]$relayMail.event_key } | Select-Object -First 1
                        $relaySuppressed = Test-InventoryMailEventSuppressed -History $MailEventHistory -EventKey ([string]$relayMail.event_key)
                        if (-not $existingRelay -and -not $relaySuppressed) {
                            $PendingMailQueue = @($relayMail) + @($PendingMailQueue)
                            $MailEventHistory = @(Update-InventoryMailEventHistory `
                                -History $MailEventHistory `
                                -EventKey ([string]$relayMail.event_key) `
                                -Subject ([string]$relayMail.subject) `
                                -Event queued)
                            $StateData["mail_event_history"] = [object[]]$MailEventHistory
                            $SnipeRelayQueued = $true
                            $SnipeRelayAcceptedForDelivery = $true
                            Write-Log "Snipe relay: JSON поставлен первым в SMTP queue. event_id=$SnipeRelayEventId failures=$SnipeConsecutiveFailures threshold=$relayThreshold"
                        }
                        elseif ($existingRelay) {
                            $SnipeRelayQueued = $true
                            $SnipeRelayAcceptedForDelivery = $true
                            Write-Log "Snipe relay: payload уже ожидает отправки. event_id=$SnipeRelayEventId"
                        }
                        else {
                            $SnipeRelayAcceptedForDelivery = $true
                            Write-Log "Snipe relay: payload уже был отправлен и подавлен дедупликацией. event_id=$SnipeRelayEventId"
                        }
                        $StateData["snipe_relay_event_id"] = $SnipeRelayEventId
                        $StateData["snipe_relay_queued"] = $SnipeRelayQueued
                    }
                    catch {
                        $relayBuildError = "SNIPE RELAY ERROR: $(Get-ExceptionText $_.Exception)"
                        $StateData["snipe_relay_error"] = Limit-InventoryText -Value $relayBuildError -MaxLength 2000
                        Write-Log $relayBuildError
                    }
                }
                elseif ($DryRun -and $InventoryRelayEnabled -and $SnipeConsecutiveFailures -ge $relayThreshold) {
                    Write-DryRunAction -Action "queue signed Snipe-IT relay JSON" -Reason "snipeit_avail=no; failures=$SnipeConsecutiveFailures"
                }
            }
            else {
                $SnipeAvailabilityFlag = "yes"
                $StateData["snipeit_avail"] = "yes"
                $StateData["snipe_consecutive_failures"] = 0
            }

            $SnipeResult = "ERROR: $snipeExceptionText"
            $SnipeResultText = $SnipeResult
            $SnipeErrorText = Limit-InventoryText -Value $SnipeResultText -MaxLength 2000
            $ProcessExitCode = [Math]::Max($ProcessExitCode, 1)
            Write-Log "Snipe-IT ERROR:"
            Write-Log $SnipeResultText

            $StateData["computer_name"] = $ComputerName
            $StateData["serial_number"] = $SerialNumber
            $StateData["last_attempted_username"] = $DetectedUsername
            $StateData["last_attempted_raw_username"] = $RawDetectedUsername
            $StateData["last_attempt_time"] = (Get-Date).ToString("o")
            $StateData["last_run_reason"] = $RunReasonText
            $StateData["snipe_result"] = $SnipeResultText
            $StateData["last_error"] = $SnipeErrorText
            $StateData["last_error_source"] = "snipe"
            $StateData["last_error_time"] = (Get-Date).ToString("o")
            Save-InventoryStateSnapshot -Path $StateFile -State $StateData -PendingMails $PendingMailQueue | Out-Null
            if ($KnownAssetId -gt 0 -and $SnipeAvailabilityFlag -eq "yes") {
                Update-SnipeAssetHealth -AssetId $KnownAssetId -LastError $SnipeErrorText | Out-Null
            }
        }
    }
    else {
        $SnipeResult = "SKIP: последняя инвентаризация была $LastInventoryTime; интервал $InventoryIntervalDays дней; пользователь не изменился ($DetectedUsername)"
        $SnipeResultText = $SnipeResult
        Write-Log $SnipeResultText
    }

    if (-not $IdentityFallbackUsed) {
        $UsernameConfidenceDetails = Get-InventoryUsernameConfidence `
            -RawUsername $RawDetectedUsername `
            -ResolvedUsername $DetectedUsername `
            -State $InventoryState `
            -ObservedSource ([string]$LatestObservedUser.Source)
    }
    $UsernameConfidence = [int]$UsernameConfidenceDetails.Confidence
    $UsernameResolutionMethod = [string]$UsernameConfidenceDetails.Method
    $UsernameResolutionConfidence = [int]$UsernameConfidenceDetails.ResolutionConfidence
    $UsernameSourceConfidence = [int]$UsernameConfidenceDetails.SourceConfidence
    $StateData["username_confidence"] = $UsernameConfidence
    $StateData["username_resolution_confidence"] = $UsernameResolutionConfidence
    $StateData["username_source_confidence"] = $UsernameSourceConfidence
    $StateData["username_resolution_method"] = $UsernameResolutionMethod
    $StateData["username_detection_source"] = [string]$LatestObservedUser.Source
    $StateData["dry_run"] = [bool]$DryRun
    Write-Log "Username confidence final: $UsernameConfidence method=$UsernameResolutionMethod resolution=$UsernameResolutionConfidence source_confidence=$UsernameSourceConfidence source='$($LatestObservedUser.Source)'."

    $EffectiveUserChangedForMail = $UserChanged -or $SnipeAssetUserChanged
    $InventoryHadError = ($SnipeResultText -like 'ERROR:*')
    $InventoryHadErrorForMail = Test-InventoryErrorRequiresHumanMail `
        -InventoryHadError $InventoryHadError `
        -RelayAcceptedForDelivery $SnipeRelayAcceptedForDelivery
    $InventoryHadWarning = ($SnipeResultText -like 'WARNING:*')
    $StockEventForMail = (
        $InventoryDisposition -eq "stock" -and
        ($DispositionChanged -or $SnipeStockCheckin -or $NeverInventoried -or [string]::IsNullOrWhiteSpace($PreviousDisposition))
    )
    $MailReasons = @()
    if ($ForceEmailReport) { $MailReasons += "force_email" }
    if ($SendEmailOnUserChange -and $UserChanged) { $MailReasons += "local_user_changed" }
    if ($SendEmailOnSnipeUserChange -and $SnipeAssetUserChanged) { $MailReasons += "snipe_user_changed" }
    if ($SendEmailOnStockCheckin -and $StockEventForMail) { $MailReasons += "stock_checkin" }
    if ($SendEmailOnWarning -and $InventoryHadWarning) { $MailReasons += "warning" }
    if ($SendEmailOnError -and $InventoryHadErrorForMail) { $MailReasons += "error" }
    if ($MailReasons.Count -eq 0) { $MailReasons += "not_required" }
    $MailReasonText = ($MailReasons -join ", ")

    # ==========================
    # HTML BODY
    # ==========================
    $userRows = @()
    foreach ($u in $lastUsers) {
        $userRows += "<tr><td>$(Enc $u.User)</td><td>$(Enc $u.LastLogon)</td><td>$(Enc $u.Type)</td><td>$(Enc $u.Source)</td></tr>"
    }
    if ($userRows.Count -eq 0) { $userRows += "<tr><td colspan='4'>Не удалось получить последних пользователей</td></tr>" }

    $bodyLines = @()
    $bodyLines += "<html><head><meta charset='UTF-8'><style>"
    $bodyLines += "body { font-family: Segoe UI, Arial, sans-serif; font-size: 14px; color: #222; }"
    $bodyLines += "h2 { margin-bottom: 5px; }"
    $bodyLines += "table { border-collapse: collapse; width: 100%; margin-bottom: 20px; }"
    $bodyLines += "td, th { border: 1px solid #ccc; padding: 8px; text-align: left; }"
    $bodyLines += "th { background: #f2f2f2; }"
    $bodyLines += ".small { color: #666; font-size: 12px; }"
    $bodyLines += ".ok { color: #0a7f00; font-weight: bold; } .err { color: #b00020; font-weight: bold; }"
    $bodyLines += "</style></head><body>"
    $bodyLines += "<h2>SnipeIT Inventory Report</h2>"
    $bodyLines += "<p class='small'>Generated: $(Enc $ReportDate)</p>"

    $bodyLines += "<table>"
    $bodyLines += "<tr><th>Параметр</th><th>Значение</th></tr>"
    $bodyLines += "<tr><td>Версия агента</td><td>$(Enc $InventoryAgentVersion)</td></tr>"
    $bodyLines += "<tr><td>Имя ПК</td><td>$(Enc $ComputerName)</td></tr>"
    $bodyLines += "<tr><td>Домен / Workgroup</td><td>$(Enc $Domain)</td></tr>"
    $bodyLines += "<tr><td>Производитель</td><td>$(Enc $Manufacturer)</td></tr>"
    $bodyLines += "<tr><td>Модель</td><td>$(Enc $Model)</td></tr>"
    $bodyLines += "<tr><td>Серийный номер</td><td>$(Enc $SerialNumber)</td></tr>"
    $bodyLines += "<tr><td>CPU</td><td>$(Enc $CpuName)</td></tr>"
    $bodyLines += "<tr><td>CPU ядра / потоки</td><td>$(Enc "$CpuCores / $CpuThreads")</td></tr>"
    $bodyLines += "<tr><td>ОЗУ</td><td>$(Enc "$RamGB GB")</td></tr>"
    $bodyLines += "<tr><td>Конфигурация ОЗУ</td><td>$(Enc $RamLayout)</td></tr>"
    $bodyLines += "<tr><td>Модули ОЗУ (SMBIOS)</td><td>$(Enc $RamModuleDetails)</td></tr>"
    $bodyLines += "<tr><td>Текущий пользователь</td><td>$(Enc $CurrentUser)</td></tr>"
    $bodyLines += "<tr><td>Последний фактический логин</td><td>$(Enc $LatestObservedAccount)</td></tr>"
    $bodyLines += "<tr><td>Источник последнего логина</td><td>$(Enc $LatestObservedUser.Source)</td></tr>"
    $bodyLines += "<tr><td>Исходный detected username</td><td>$(Enc $RawDetectedUsername)</td></tr>"
    $bodyLines += "<tr><td>Username для Snipe-IT</td><td>$(Enc $DetectedUsername)</td></tr>"
    $bodyLines += "<tr><td>Confidence</td><td>$(Enc $UsernameConfidence)</td></tr>"
    $bodyLines += "<tr><td>Метод определения username</td><td>$(Enc $UsernameResolutionMethod)</td></tr>"
    $bodyLines += "<tr><td>Confidence разрешения / источника</td><td>$(Enc "$UsernameResolutionConfidence / $UsernameSourceConfidence")</td></tr>"
    $bodyLines += "<tr><td>AD lookup / user found</td><td>$(Enc "$($AdUserState.LookupSucceeded) / $($AdUserState.Found)")</td></tr>"
    $bodyLines += "<tr><td>AD disabled / описание УВОЛ / OU Уволенные</td><td>$(Enc "$($AdUserState.Disabled) / $($AdUserState.DescriptionMatched) / $($AdUserState.OuMatched)")</td></tr>"
    $bodyLines += "<tr><td>Предыдущий username</td><td>$(Enc $PreviousUsername)</td></tr>"
    $bodyLines += "<tr><td>Предыдущий владелец Snipe-IT</td><td>$(Enc $SnipePreviousAssignedUser)</td></tr>"
    $bodyLines += "<tr><td>Смена владельца Snipe-IT</td><td>$(Enc $SnipeAssetUserChanged)</td></tr>"
    $bodyLines += "<tr><td>Действие checkin/checkout</td><td>$(Enc $SnipeCheckoutAction)</td></tr>"
    $bodyLines += "<tr><td>Dry Run / Would change</td><td>$(Enc "$DryRun / $SnipeDryRunWouldChange")</td></tr>"
    $bodyLines += "<tr><td>Размещение актива</td><td>$(Enc $InventoryDisposition)</td></tr>"
    $bodyLines += "<tr><td>Причина размещения</td><td>$(Enc $InventoryDispositionReason)</td></tr>"
    $bodyLines += "<tr><td>Пользователь отсутствует в Snipe-IT</td><td>$(Enc $SnipeUserMissing)</td></tr>"
    $bodyLines += "<tr><td>snipeit_avail</td><td>$(Enc $SnipeAvailabilityFlag)</td></tr>"
    $bodyLines += "<tr><td>Ошибок доступа подряд</td><td>$(Enc $SnipeConsecutiveFailures)</td></tr>"
    $bodyLines += "<tr><td>Relay event ID</td><td>$(Enc $SnipeRelayEventId)</td></tr>"
    $bodyLines += "<tr><td>Relay event type / generation</td><td>$(Enc "$RelayEventType / $RelayEventGeneration")</td></tr>"
    $bodyLines += "<tr><td>Relay в очереди</td><td>$(Enc $SnipeRelayQueued)</td></tr>"
    $bodyLines += "<tr><td>Причина запуска Snipe-IT</td><td>$(Enc $RunReasonText)</td></tr>"
    $bodyLines += "<tr><td>Причина SMTP</td><td>$(Enc $MailReasonText)</td></tr>"
    $bodyLines += "<tr><td>Писем в очереди до запуска</td><td>$(Enc $PendingMailQueue.Count)</td></tr>"
    $bodyLines += "<tr><td>ОС</td><td>$(Enc $OSName)</td></tr>"
    $bodyLines += "<tr><td>Версия ОС</td><td>$(Enc $OSVersion)</td></tr>"
    $bodyLines += "<tr><td>Build</td><td>$(Enc $OSBuild)</td></tr>"
    $bodyLines += "<tr><td>Последняя загрузка</td><td>$(Enc $LastBoot)</td></tr>"
    $bodyLines += "<tr><td>Snipe-IT</td><td>$(Enc $SnipeResultText)</td></tr>"
    $bodyLines += "</table>"

    $bodyLines += "<h3>Последние 3 пользователя</h3>"
    $bodyLines += "<table>"
    $bodyLines += "<tr><th>Пользователь</th><th>Последний вход</th><th>Тип</th><th>Источник</th></tr>"
    $bodyLines += $userRows
    $bodyLines += "</table>"
    $bodyLines += "</body></html>"

    $Body = $bodyLines -join "`r`n"
    if ($ForceEmailReport) {
        $Subject = "$InventoryReportSubjectPrefix FORCED: $ComputerName / $SerialNumber"
    }
    elseif ($InventoryHadErrorForMail) {
        $Subject = "$InventoryErrorSubjectPrefix $ComputerName / $SerialNumber"
    }
    elseif ($InventoryHadWarning) {
        $Subject = "$InventoryWarningSubjectPrefix $ComputerName / $SerialNumber"
    }
    elseif ($StockEventForMail) {
        $Subject = "$InventoryReportSubjectPrefix STOCK: $ComputerName / $SerialNumber"
    }
    elseif ($EffectiveUserChangedForMail) {
        $Subject = "$InventoryReportSubjectPrefix USER CHANGE: $ComputerName / $SerialNumber"
    }
    else {
        $Subject = "$InventoryReportSubjectPrefix $ComputerName / $SerialNumber"
    }

    # ==========================
    # TXT ATTACHMENT
    # ==========================
    $TxtPath = Join-Path $TempRoot "$ComputerName.txt"
    $txtLines = @()
    $txtLines += "SnipeIT Inventory Report"
    $txtLines += "Generated: $ReportDate"
    $txtLines += "Версия агента: $InventoryAgentVersion"
    $txtLines += ""
    $txtLines += "Имя ПК: $ComputerName"
    $txtLines += "Домен / Workgroup: $Domain"
    $txtLines += "Производитель: $Manufacturer"
    $txtLines += "Модель: $Model"
    $txtLines += "Серийный номер: $SerialNumber"
    $txtLines += "CPU: $CpuName"
    $txtLines += "CPU ядра / потоки: $CpuCores / $CpuThreads"
    $txtLines += "ОЗУ: $RamGB GB"
    $txtLines += "Конфигурация ОЗУ: $RamLayout"
    $txtLines += "Модули ОЗУ (SMBIOS): $RamModuleDetails"
    $txtLines += "Текущий пользователь: $CurrentUser"
    $txtLines += "Последний фактический логин: $LatestObservedAccount"
    $txtLines += "Источник последнего логина: $($LatestObservedUser.Source)"
    $txtLines += "Исходный detected username: $RawDetectedUsername"
    $txtLines += "Username для Snipe-IT: $DetectedUsername"
    $txtLines += "Confidence: $UsernameConfidence"
    $txtLines += "Метод определения username: $UsernameResolutionMethod"
    $txtLines += "Confidence разрешения / источника: $UsernameResolutionConfidence / $UsernameSourceConfidence"
    $txtLines += "AD lookup / user found: $($AdUserState.LookupSucceeded) / $($AdUserState.Found)"
    $txtLines += "AD disabled / описание УВОЛ / OU Уволенные: $($AdUserState.Disabled) / $($AdUserState.DescriptionMatched) / $($AdUserState.OuMatched)"
    $txtLines += "Предыдущий username: $PreviousUsername"
    $txtLines += "Предыдущий владелец Snipe-IT: $SnipePreviousAssignedUser"
    $txtLines += "Смена владельца Snipe-IT: $SnipeAssetUserChanged"
    $txtLines += "Действие checkin/checkout: $SnipeCheckoutAction"
    $txtLines += "Dry Run / Would change: $DryRun / $SnipeDryRunWouldChange"
    $txtLines += "Размещение актива: $InventoryDisposition"
    $txtLines += "Причина размещения: $InventoryDispositionReason"
    $txtLines += "Пользователь отсутствует в Snipe-IT: $SnipeUserMissing"
    $txtLines += "snipeit_avail: $SnipeAvailabilityFlag"
    $txtLines += "Ошибок доступа подряд: $SnipeConsecutiveFailures"
    $txtLines += "Relay event ID: $SnipeRelayEventId"
    $txtLines += "Relay event type / generation: $RelayEventType / $RelayEventGeneration"
    $txtLines += "Relay в очереди: $SnipeRelayQueued"
    $txtLines += "Причина запуска Snipe-IT: $RunReasonText"
    $txtLines += "Причина SMTP: $MailReasonText"
    $txtLines += "Писем в очереди до запуска: $($PendingMailQueue.Count)"
    $txtLines += "ОС: $OSName"
    $txtLines += "Версия ОС: $OSVersion"
    $txtLines += "Build: $OSBuild"
    $txtLines += "Последняя загрузка: $LastBoot"
    $txtLines += "Snipe-IT: $SnipeResultText"
    $txtLines += ""
    $txtLines += "Последние 3 пользователя:"
    $txtLines += "------------------------"
    if ($lastUsers.Count -gt 0) {
        foreach ($u in $lastUsers) {
            $txtLines += "Пользователь: $($u.User)"
            $txtLines += "Последний вход: $($u.LastLogon)"
            $txtLines += "Тип: $($u.Type)"
            $txtLines += "Источник: $($u.Source)"
            $txtLines += ""
        }
    }
    else { $txtLines += "Не удалось получить последних пользователей" }

    Set-Content -LiteralPath $TxtPath -Value $txtLines -Encoding UTF8
    Write-Log "TXT файл создан: $TxtPath"

    # ==========================
    # SMTP PERSISTENT QUEUE
    # ==========================
    $WouldQueueNewMail = $SendEmailReport -and (
        $ForceEmailReport -or
        ($SendEmailOnUserChange -and $UserChanged) -or
        ($SendEmailOnSnipeUserChange -and $SnipeAssetUserChanged) -or
        ($SendEmailOnStockCheckin -and $StockEventForMail) -or
        ($SendEmailOnWarning -and $InventoryHadWarning) -or
        ($SendEmailOnError -and $InventoryHadErrorForMail)
    )
    $NeedQueueNewMail = (-not $DryRun) -and $WouldQueueNewMail

    if ($DryRun -and $WouldQueueNewMail) {
        Write-DryRunAction -Action "queue and send inventory email subject='$Subject'" -Reason $MailReasonText -DetectedUsername $DetectedUsername
    }
    if ($DryRun -and $PendingMailQueue.Count -gt 0) {
        Write-DryRunAction -Action "retry $($PendingMailQueue.Count) queued email(s)" -Reason "pending_mail_queue"
    }

    if ($NeedQueueNewMail) {
        $attachmentText = $txtLines -join "`r`n"
        $eventKeySource = @(
            $ComputerName,
            $Subject,
            $MailReasonText,
            $PreviousUsername,
            $RawDetectedUsername,
            $DetectedUsername,
            $SnipePreviousAssignedUser,
            $InventoryDisposition,
            $InventoryDispositionReason,
            $SnipeResultText
        ) -join "|"
        $eventKey = Get-StringSha256 -Value $eventKeySource
        $alreadyQueued = $PendingMailQueue | Where-Object { [string]$_.event_key -eq $eventKey } | Select-Object -First 1
        $duplicateSuppressed = (-not $ForceEmailReport) -and (
            Test-InventoryMailEventSuppressed -History $MailEventHistory -EventKey $eventKey
        )

        if ($alreadyQueued) {
            Write-Log "SMTP queue: событие уже находится в очереди, duplicate не добавлен. id=$($alreadyQueued.id)"
        }
        elseif ($duplicateSuppressed) {
            Write-Log "SMTP anti-spam: одинаковое событие уже отправлялось/ставилось в очередь менее $InventoryMailDuplicateSuppressionHours ч назад. Новое письмо не создано."
        }
        else {
            if ($PendingMailQueue.Count -ge $InventoryMailQueueWarningItems) {
                Write-Log "SMTP queue warning: накоплено $($PendingMailQueue.Count) писем. Новое событие сохраняется без потери."
            }
            $newMail = [PSCustomObject]@{
                id              = [guid]::NewGuid().ToString("N")
                event_key       = $eventKey
                created_at      = (Get-Date).ToString("o")
                reason          = $MailReasonText
                subject         = $Subject
                body            = $Body
                attachment_name = "$ComputerName.txt"
                attachment_text = $attachmentText
                attempt_count   = 0
                last_attempt_at = $null
                last_error      = ""
            }
            $PendingMailQueue = @($PendingMailQueue) + $newMail
            $MailEventHistory = @(Update-InventoryMailEventHistory `
                -History $MailEventHistory `
                -EventKey $eventKey `
                -Subject $Subject `
                -Event queued)
            $StateData["mail_event_history"] = [object[]]$MailEventHistory
            Write-Log "SMTP queue: письмо добавлено. id=$($newMail.id) count=$($PendingMailQueue.Count)"
        }
        Save-InventoryStateSnapshot -Path $StateFile -State $StateData -PendingMails $PendingMailQueue | Out-Null
    }

    $SentMailCount = 0
    if (-not $DryRun -and $SendEmailReport -and $PendingMailQueue.Count -gt 0) {
        $mailBatch = @($PendingMailQueue |
            Sort-Object @{ Expression = { if ([string]$_.reason -eq "snipeit_relay") { 0 } else { 1 } } }, created_at |
            Select-Object -First $InventoryMailSendBatchSize)
        foreach ($queuedMail in $mailBatch) {
            try {
                Send-QueuedInventoryMail -Entry $queuedMail | Out-Null
                $PendingMailQueue = @($PendingMailQueue | Where-Object { [string]$_.id -ne [string]$queuedMail.id })
                $SentMailCount++
                $StateData["last_mail_success_time"] = (Get-Date).ToString("o")
                $StateData["last_mail_error"] = ""
                $MailEventHistory = @(Update-InventoryMailEventHistory `
                    -History $MailEventHistory `
                    -EventKey ([string]$queuedMail.event_key) `
                    -Subject ([string]$queuedMail.subject) `
                    -Event sent)
                $StateData["mail_event_history"] = [object[]]$MailEventHistory
                if ([string]$queuedMail.reason -eq "snipeit_relay") {
                    $StateData["snipe_relay_queued"] = $false
                    $StateData["snipe_relay_last_sent_at"] = (Get-Date).ToString("o")
                    $StateData["snipe_relay_error"] = ""
                }

                if ([string]($StateData["last_error_source"]) -in @("smtp", "smtp_queue")) {
                    $StateData["last_error"] = ""
                    $StateData["last_error_source"] = ""
                    $StateData["last_error_time"] = $null
                    if ($KnownAssetId -gt 0 -and $SnipeAvailabilityFlag -eq "yes") {
                        Update-SnipeAssetHealth -AssetId $KnownAssetId -LastError "" | Out-Null
                    }
                }
                Save-InventoryStateSnapshot -Path $StateFile -State $StateData -PendingMails $PendingMailQueue | Out-Null
            }
            catch {
                $smtpErrorText = "SMTP ERROR: $(Get-ExceptionText $_.Exception)"
                $queuedMail | Add-Member -NotePropertyName attempt_count -NotePropertyValue ([int]$queuedMail.attempt_count + 1) -Force
                $queuedMail | Add-Member -NotePropertyName last_attempt_at -NotePropertyValue ((Get-Date).ToString("o")) -Force
                $queuedMail | Add-Member -NotePropertyName last_error -NotePropertyValue (Limit-InventoryText -Value $smtpErrorText -MaxLength 2000) -Force
                $StateData["last_mail_error"] = Limit-InventoryText -Value $smtpErrorText -MaxLength 2000
                $StateData["last_error"] = $StateData["last_mail_error"]
                $StateData["last_error_source"] = "smtp"
                $StateData["last_error_time"] = (Get-Date).ToString("o")
                $ProcessExitCode = [Math]::Max($ProcessExitCode, 2)
                Write-Log $smtpErrorText
                Save-InventoryStateSnapshot -Path $StateFile -State $StateData -PendingMails $PendingMailQueue | Out-Null
                if ($KnownAssetId -gt 0 -and $SnipeAvailabilityFlag -eq "yes") {
                    Update-SnipeAssetHealth -AssetId $KnownAssetId -LastError $smtpErrorText | Out-Null
                }
                break
            }
        }
    }
    elseif ($DryRun) {
        Write-Log "DRY RUN: SMTP queue unchanged; no messages were queued or sent."
    }
    elseif (-not $SendEmailReport -and $PendingMailQueue.Count -gt 0) {
        Write-Log "SMTP queue: отправка выключена, в очереди остается $($PendingMailQueue.Count) писем."
    }
    else {
        Write-Log "SMTP: новых событий нет, очередь пуста."
    }

    if ($SnipeRelayAcceptedForDelivery -and $ProcessExitCode -eq 1 -and -not [string]::IsNullOrWhiteSpace($SnipeRelayEventId)) {
        $currentRelayEventKey = "relay:$SnipeRelayEventId"
        $currentRelayStillPending = $PendingMailQueue | Where-Object {
            [string]$_.event_key -eq $currentRelayEventKey
        } | Select-Object -First 1
        if (-not $currentRelayStillPending) {
            $ProcessExitCode = 0
            $StateData["last_error"] = ""
            $StateData["last_error_source"] = ""
            $StateData["last_error_time"] = $null
            Write-Log "Snipe relay: событие принято SMTP/уже передано; транспортная ошибка API считается обработанной."
        }
    }

    Save-InventoryStateSnapshot -Path $StateFile -State $StateData -PendingMails $PendingMailQueue | Out-Null
    if (-not $GpoMode) {
        if ($SentMailCount -gt 0) {
            Write-Host ""
            Write-Host "OK: отправлено писем: $SentMailCount; осталось в очереди: $($PendingMailQueue.Count)" -ForegroundColor Green
        }
        elseif ($PendingMailQueue.Count -gt 0) {
            Write-Host "SMTP: писем в очереди: $($PendingMailQueue.Count). Следующая попытка будет выполнена автоматически." -ForegroundColor Yellow
        }
        Write-Host "Snipe-IT: $SnipeResultText" -ForegroundColor Cyan
        Write-Host "TXT отчет: $TxtPath" -ForegroundColor Cyan
        Write-Host "Лог: $LogFile" -ForegroundColor Cyan
    }
}
catch {
    $fatalErrorText = "AGENT ERROR: $(Get-ExceptionText $_.Exception)"
    $ProcessExitCode = [Math]::Max($ProcessExitCode, 1)
    if (-not $GpoMode) {
        Write-Host ""
        Write-Host "ERROR:" -ForegroundColor Red
        Write-Host (Get-ExceptionText $_.Exception) -ForegroundColor Red
    }
    Write-Log "ERROR:"
    Write-Log (Get-ExceptionText $_.Exception)

    if ($DryRun -and $SendEmailReport -and $SendEmailOnError) {
        Write-DryRunAction -Action "queue and send fatal agent error email" -Reason $fatalErrorText
    }
    elseif ($SendEmailReport -and $SendEmailOnError) {
        $fatalComputerName = if ([string]::IsNullOrWhiteSpace([string]$ComputerName)) { $env:COMPUTERNAME } else { $ComputerName }
        $fatalSubject = "$InventoryErrorSubjectPrefix AGENT: $fatalComputerName"
        $fatalEventKey = Get-StringSha256 -Value "$fatalComputerName|$fatalSubject|$fatalErrorText"
        $fatalMail = $PendingMailQueue | Where-Object { [string]$_.event_key -eq $fatalEventKey } | Select-Object -First 1
        $fatalDuplicateSuppressed = (-not $ForceEmailReport) -and (
            Test-InventoryMailEventSuppressed -History $MailEventHistory -EventKey $fatalEventKey
        )
        if (-not $fatalMail -and -not $fatalDuplicateSuppressed) {
            $fatalMail = [PSCustomObject]@{
                id              = [guid]::NewGuid().ToString("N")
                event_key       = $fatalEventKey
                created_at      = (Get-Date).ToString("o")
                reason          = "agent_error"
                subject         = $fatalSubject
                body            = "<html><body><h2>SnipeIT Inventory Agent Error</h2><p><b>Computer:</b> $(Enc $fatalComputerName)</p><pre>$(Enc $fatalErrorText)</pre></body></html>"
                attachment_name = "$fatalComputerName-error.txt"
                attachment_text = "SnipeIT Inventory Agent Error`r`nComputer: $fatalComputerName`r`nTime: $((Get-Date).ToString("o"))`r`n`r`n$fatalErrorText"
                attempt_count   = 0
                last_attempt_at = $null
                last_error      = ""
            }
            $PendingMailQueue = @($PendingMailQueue) + $fatalMail
            $MailEventHistory = @(Update-InventoryMailEventHistory `
                -History $MailEventHistory `
                -EventKey $fatalEventKey `
                -Subject $fatalSubject `
                -Event queued)
            $StateData["mail_event_history"] = [object[]]$MailEventHistory
            Write-Log "SMTP queue: аварийный отчет добавлен. id=$($fatalMail.id)"
        }

        if ($fatalDuplicateSuppressed -and -not $fatalMail) {
            Write-Log "SMTP anti-spam: одинаковый аварийный отчет подавлен на $InventoryMailDuplicateSuppressionHours ч."
        }
        elseif ($fatalMail) {
            try {
                Send-QueuedInventoryMail -Entry $fatalMail | Out-Null
                $PendingMailQueue = @($PendingMailQueue | Where-Object { [string]$_.id -ne [string]$fatalMail.id })
                $StateData["last_mail_success_time"] = (Get-Date).ToString("o")
                $StateData["last_mail_error"] = ""
                $MailEventHistory = @(Update-InventoryMailEventHistory `
                    -History $MailEventHistory `
                    -EventKey $fatalEventKey `
                    -Subject $fatalSubject `
                    -Event sent)
                $StateData["mail_event_history"] = [object[]]$MailEventHistory
            }
            catch {
                $fatalSmtpError = "SMTP ERROR: $(Get-ExceptionText $_.Exception)"
                $fatalMail | Add-Member -NotePropertyName attempt_count -NotePropertyValue ([int]$fatalMail.attempt_count + 1) -Force
                $fatalMail | Add-Member -NotePropertyName last_attempt_at -NotePropertyValue ((Get-Date).ToString("o")) -Force
                $fatalMail | Add-Member -NotePropertyName last_error -NotePropertyValue (Limit-InventoryText -Value $fatalSmtpError -MaxLength 2000) -Force
                $StateData["last_mail_error"] = Limit-InventoryText -Value $fatalSmtpError -MaxLength 2000
                $ProcessExitCode = [Math]::Max($ProcessExitCode, 2)
                Write-Log $fatalSmtpError
            }
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($StateFile)) {
        $StateData["last_error"] = Limit-InventoryText -Value $fatalErrorText -MaxLength 2000
        $StateData["last_error_source"] = "agent"
        $StateData["last_error_time"] = (Get-Date).ToString("o")
        Save-InventoryStateSnapshot -Path $StateFile -State $StateData -PendingMails $PendingMailQueue | Out-Null
    }
    if ($KnownAssetId -gt 0) {
        Update-SnipeAssetHealth -AssetId $KnownAssetId -LastError $fatalErrorText | Out-Null
    }
    if (-not $GpoMode) {
        Write-Host ""
        Write-Host "Лог: $LogFile" -ForegroundColor Yellow
    }
}
finally {
    if ($InventoryMutexAcquired -and $InventoryMutex) {
        try { $InventoryMutex.ReleaseMutex() | Out-Null } catch {}
    }
    if ($InventoryMutex) { $InventoryMutex.Dispose() }
    Write-Log "==== END exit_code=$ProcessExitCode pending_mail_count=$($PendingMailQueue.Count) ===="
    $removedHistoryRuns = Invoke-InventoryHistoryLogRetention `
        -Path $ProgramDataHistoryLogFile `
        -RetentionDays ([int]$InventoryLogRetentionDays) `
        -MaxRuns ([int]$InventoryLogRetentionRuns)
    if ($removedHistoryRuns -gt 0 -and -not $GpoMode) {
        Write-Host "Log retention: удалено старых запусков: $removedHistoryRuns" -ForegroundColor DarkGray
    }
    if ($PauseAtEnd -eq $true) { Read-Host "Нажми Enter для выхода" }
}

exit $ProcessExitCode
