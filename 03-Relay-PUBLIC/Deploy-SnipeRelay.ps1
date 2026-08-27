#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]$Server = "192.0.2.10",
    [string]$User = "snipeit",
    [string]$PackagePath = "",
    [Parameter(Mandatory=$true)][string]$ConfigPath,
    [string]$KeyPath = "",
    [string]$RemoteDirectory = "/home/snipeit/snipeit-mail-relay-v1.3.3",
    [switch]$ValidateOnly
)

$ErrorActionPreference = "Stop"
if ([string]::IsNullOrWhiteSpace($PackagePath)) {
    $PackagePath = $PSScriptRoot
}
$packageFullPath = [System.IO.Path]::GetFullPath($PackagePath)
$configFullPath = [System.IO.Path]::GetFullPath($ConfigPath)
if (-not (Test-Path -LiteralPath $configFullPath -PathType Leaf)) {
    throw "Server config not found: $configFullPath"
}
$serverConfig = Get-Content -LiteralPath $configFullPath -Raw -Encoding UTF8 | ConvertFrom-Json
foreach ($required in @("imap_host", "imap_user", "imap_password", "hmac_secret", "snipe_url", "snipe_token")) {
    $value = [string]$serverConfig.PSObject.Properties[$required].Value
    if ([string]::IsNullOrWhiteSpace($value) -or $value -match 'PUT_|HERE') {
        throw "Server config property '$required' is not configured."
    }
}

$requiredFiles = @(
    "snipeit_mail_relay.py",
    "test_snipeit_mail_relay.py",
    "config.example.json",
    "install_server_relay.sh",
    "finish_server_install.sh",
    "configure_snipeit_timezone.sh",
    "snipeit-mail-relay.service",
    "snipeit-mail-relay.timer",
    "snipeit-mail-relay.logrotate"
)
$uploadFiles = @()
foreach ($name in $requiredFiles) {
    $path = Join-Path $packageFullPath $name
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Package file not found: $path"
    }
    $uploadFiles += (Resolve-Path -LiteralPath $path).Path
}
$uploadFiles += $configFullPath

if ($ValidateOnly) {
    Write-Host "Deployment package and protected config are valid." -ForegroundColor Green
    Write-Host "Files ready for upload: $($uploadFiles.Count)"
    return
}

$connectionOptions = @(
    "-o", "ConnectTimeout=10",
    "-o", "StrictHostKeyChecking=accept-new"
)
if (-not [string]::IsNullOrWhiteSpace($KeyPath)) {
    $resolvedKey = (Resolve-Path -LiteralPath $KeyPath).Path
    $connectionOptions += @("-i", $resolvedKey)
}

$target = "$User@$Server"
Write-Host "Creating protected staging directory on $target..."
& ssh.exe @connectionOptions $target "install -d -m 700 '$RemoteDirectory'"
if ($LASTEXITCODE -ne 0) {
    throw "SSH staging directory creation failed."
}

Write-Host "Uploading relay 1.3.3 and protected config..."
& scp.exe @connectionOptions @uploadFiles "${target}:$RemoteDirectory/"
if ($LASTEXITCODE -ne 0) {
    throw "SCP upload failed."
}

$configLeaf = Split-Path -Leaf $configFullPath
& ssh.exe @connectionOptions $target "mv '$RemoteDirectory/$configLeaf' '$RemoteDirectory/config.json' 2>/dev/null || true; chmod 700 '$RemoteDirectory'; chmod 600 '$RemoteDirectory/config.json'; chmod 700 '$RemoteDirectory/finish_server_install.sh'"
if ($LASTEXITCODE -ne 0) {
    throw "Remote permission setup failed."
}

Write-Host ""
Write-Host "Upload completed." -ForegroundColor Green
Write-Host "Run the final root install:" -ForegroundColor Cyan
Write-Host "  ssh -t $target"
Write-Host "  su -"
Write-Host "  cd $RemoteDirectory"
Write-Host "  ./finish_server_install.sh"
