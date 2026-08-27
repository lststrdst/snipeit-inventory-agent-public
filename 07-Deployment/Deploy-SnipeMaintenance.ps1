#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]$Server = "192.0.2.10",
    [string]$User = "snipeit",
    [string]$PackagePath = "",
    [string]$KeyPath = "",
    [string]$RemoteDirectory = "/home/snipeit/snipeit-maintenance-v1.3.3",
    [switch]$ValidateOnly
)

$ErrorActionPreference = "Stop"
if ([string]::IsNullOrWhiteSpace($PackagePath)) {
    $PackagePath = $PSScriptRoot
}
$packageFullPath = [System.IO.Path]::GetFullPath($PackagePath)
$requiredFiles = @(
    "snipeit_maintenance.py",
    "list_terminated_users.php",
    "test_snipeit_maintenance.py",
    "config.example.json",
    "install_server_maintenance.sh",
    "snipeit-maintenance.service",
    "snipeit-maintenance.timer",
    "snipeit-maintenance.logrotate"
)
$uploadFiles = foreach ($name in $requiredFiles) {
    $path = Join-Path $packageFullPath $name
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Package file not found: $path"
    }
    (Resolve-Path -LiteralPath $path).Path
}

$config = Get-Content -LiteralPath (Join-Path $packageFullPath "config.example.json") -Raw -Encoding UTF8 | ConvertFrom-Json
if ([string]$config.ldap_search_base -ne "DC=example,DC=internal") {
    throw "Unexpected ldap_search_base in maintenance config."
}

if ($ValidateOnly) {
    Write-Host "Maintenance package 1.3.3 is valid." -ForegroundColor Green
    return
}

$connectionOptions = @("-o", "ConnectTimeout=10", "-o", "StrictHostKeyChecking=accept-new")
if (-not [string]::IsNullOrWhiteSpace($KeyPath)) {
    $connectionOptions += @("-i", (Resolve-Path -LiteralPath $KeyPath).Path)
}
$target = "$User@$Server"

& ssh.exe @connectionOptions $target "install -d -m 700 '$RemoteDirectory'"
if ($LASTEXITCODE -ne 0) { throw "SSH staging directory creation failed." }

& scp.exe @connectionOptions @uploadFiles "${target}:$RemoteDirectory/"
if ($LASTEXITCODE -ne 0) { throw "SCP upload failed." }

& ssh.exe @connectionOptions $target "chmod 700 '$RemoteDirectory/install_server_maintenance.sh'; chmod 700 '$RemoteDirectory'"
if ($LASTEXITCODE -ne 0) { throw "Remote permission setup failed." }

Write-Host "Maintenance package uploaded." -ForegroundColor Green
Write-Host "Finish as root:"
Write-Host "  ssh -t $target"
Write-Host "  su -"
Write-Host "  cd $RemoteDirectory"
Write-Host "  ./install_server_maintenance.sh"
