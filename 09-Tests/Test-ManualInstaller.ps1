$ErrorActionPreference = "Stop"

$packageRoot = Split-Path -Parent $PSScriptRoot
$scriptPath = Join-Path $packageRoot "install_snipeit_manual.ps1"
$cmdPath = Join-Path $packageRoot "install_snipeit_manual.cmd"
$content = Get-Content -LiteralPath $scriptPath -Raw
$cmd = Get-Content -LiteralPath $cmdPath -Raw
$assertions = 0

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
    $script:assertions++
}

Assert-True (Test-Path -LiteralPath $scriptPath -PathType Leaf) "Manual installer PowerShell file is missing."
Assert-True (Test-Path -LiteralPath $cmdPath -PathType Leaf) "Manual installer CMD file is missing."
Assert-True ($content -match 'Start-Process[\s\S]+-Verb RunAs') "Manual installer does not request UAC elevation."
Assert-True ($content -match 'New-ScheduledTaskPrincipal -UserId "SYSTEM"') "Bootstrap is not configured for SYSTEM."
Assert-True ($content -match '-WindowStyle Hidden') "SYSTEM bootstrap PowerShell is not hidden."
Assert-True ($content -match '\\\\AD-SERVER\\snipeit_auto_secure\$') "Protected share is not used."
Assert-True ($content -match 'snipeit_ldap_sync_ed25519') "Protected LDAP SSH key is not supplied."
Assert-True ($content -match 'Unregister-ScheduledTask -TaskName \$BootstrapTaskName') "One-time task is not removed."
Assert-True ($content -match '\$hasStarted') "Task-start race is not handled."
Assert-True ($content -match '\\SnipeIT Inventory\\') "Canonical permanent task path is not verified."
Assert-True ($cmd -match 'install_snipeit_manual\.ps1') "CMD does not start the manual installer."

[pscustomobject]@{
    Assertions        = $assertions
    RunsAsSystem      = $true
    UsesProtectedShare = $true
    CleansBootstrap   = $true
}
