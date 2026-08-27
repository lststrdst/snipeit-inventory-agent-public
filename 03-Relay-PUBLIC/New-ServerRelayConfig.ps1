#Requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$ClientConfig,
    [string]$ImapUser = "it@example.com",
    [Security.SecureString]$ImapPassword,
    [string]$ImapParentFolder = "SnipeIT Inventory",
    [string]$TemplatePath = (Join-Path $PSScriptRoot "config.example.json"),
    [string]$OutputPath = (Join-Path $PSScriptRoot "config.json"),
    [string]$ClientOutputPath = ""
)

$ErrorActionPreference = "Stop"
$client = Get-Content -LiteralPath $ClientConfig -Raw -Encoding UTF8 | ConvertFrom-Json
$server = Get-Content -LiteralPath $TemplatePath -Raw -Encoding UTF8 | ConvertFrom-Json

if ($null -eq $ImapPassword) {
    $ImapPassword = Read-Host "IMAP/SMTP app password for $ImapUser" -AsSecureString
}
$passwordPointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($ImapPassword)
try {
    $plainImapPassword = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($passwordPointer)
}
finally {
    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($passwordPointer)
}
if ([string]::IsNullOrWhiteSpace($plainImapPassword)) {
    throw "IMAP password is empty."
}

foreach ($required in @("SmtpUser", "SmtpPass", "MailFrom", "SnipeToken")) {
    $value = [string]$client.PSObject.Properties[$required].Value
    if ([string]::IsNullOrWhiteSpace($value) -or $value -match 'PUT_|HERE') {
        throw "Client config property '$required' is not configured."
    }
}

$relaySecret = [string]$client.InventoryRelayHmacSecret
if ([string]::IsNullOrWhiteSpace($relaySecret) -or $relaySecret -match 'PUT_|HERE') {
    $randomBytes = New-Object byte[] 32
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        $rng.GetBytes($randomBytes)
        $relaySecret = [Convert]::ToBase64String($randomBytes)
    }
    finally {
        $rng.Dispose()
    }
}

$client | Add-Member -NotePropertyName InventoryRelayEnabled -NotePropertyValue $true -Force
$client | Add-Member -NotePropertyName InventoryRelayFailureThreshold -NotePropertyValue 1 -Force
$client | Add-Member -NotePropertyName InventoryRelayMailTo -NotePropertyValue $ImapUser -Force
$client | Add-Member -NotePropertyName InventoryRelayHmacSecret -NotePropertyValue $relaySecret -Force
$client | Add-Member -NotePropertyName InventoryRelaySubjectPrefix -NotePropertyValue "[SNIPEIT-INVENTORY] RELAY:" -Force

$server.imap_user = $ImapUser
$server.imap_password = $plainImapPassword
$server.imap_parent_folder = $ImapParentFolder
$server.allowed_from = @([string]$client.MailFrom)
$server.report_allowed_from = @([string]$client.MailFrom, $ImapUser) | Select-Object -Unique
$server.hmac_secret = $relaySecret
$server.snipe_token = [string]$client.SnipeToken
$server.smtp_host = [string]$client.SmtpServer
$server.smtp_port = [int]$client.SmtpPort
$server.smtp_user = $ImapUser
$server.smtp_password = $plainImapPassword
$server.smtp_starttls = [bool]$client.UseSsl
$server.smtp_ssl = $false
$server.alert_mail_to = $ImapUser

$clientToServer = @{
    SnipeDefaultStatusId       = "default_status_id"
    SnipeStockStatusId         = "stock_status_id"
    SnipeDefaultCategoryId     = "default_category_id"
    SnipeDefaultManufacturerId = "default_manufacturer_id"
    SnipeDefaultFieldsetId     = "default_fieldset_id"
}
foreach ($clientName in $clientToServer.Keys) {
    $property = $client.PSObject.Properties[$clientName]
    if ($property -and $null -ne $property.Value -and -not [string]::IsNullOrWhiteSpace([string]$property.Value)) {
        $server.PSObject.Properties[$clientToServer[$clientName]].Value = $property.Value
    }
}

$customFieldMap = @{
    SnipeCustomFieldRam         = "ram"
    SnipeCustomFieldCpu         = "cpu"
    SnipeCustomFieldOs          = "os"
    SnipeCustomFieldStorage     = "storage"
    SnipeCustomFieldAgentVersion = "agent_version"
    SnipeCustomFieldLastSuccess = "last_success"
    SnipeCustomFieldLastError   = "last_error"
}
foreach ($clientName in $customFieldMap.Keys) {
    $property = $client.PSObject.Properties[$clientName]
    if ($property -and -not [string]::IsNullOrWhiteSpace([string]$property.Value)) {
        $server.custom_fields.PSObject.Properties[$customFieldMap[$clientName]].Value = [string]$property.Value
    }
}

$outputFullPath = [System.IO.Path]::GetFullPath($OutputPath)
$outputDir = Split-Path -Parent $outputFullPath
if (-not [string]::IsNullOrWhiteSpace($outputDir)) {
    New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
}
$server | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $outputFullPath -Encoding UTF8

if ([string]::IsNullOrWhiteSpace($ClientOutputPath)) {
    $clientDirectory = Split-Path -Parent ([System.IO.Path]::GetFullPath($ClientConfig))
    $ClientOutputPath = Join-Path $clientDirectory "snipeit_inventory.local.v1.3.3.json"
}
$clientOutputFullPath = [System.IO.Path]::GetFullPath($ClientOutputPath)
$clientOutputDir = Split-Path -Parent $clientOutputFullPath
if (-not [string]::IsNullOrWhiteSpace($clientOutputDir)) {
    New-Item -ItemType Directory -Path $clientOutputDir -Force | Out-Null
}
$client | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $clientOutputFullPath -Encoding UTF8

Write-Output "Server relay config created: $outputFullPath"
Write-Output "Protected client config created: $clientOutputFullPath"
Write-Warning "Both generated files contain secrets. Do not place either one on the public GPO share."
