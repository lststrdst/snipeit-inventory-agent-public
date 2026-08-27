#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]$SourceRoot = $PSScriptRoot,
    [string]$InstallDir = (Join-Path $env:ProgramData "snipeit_auto"),
    [string]$TaskPath = "\SnipeIT\",
    [string]$TaskName = "Auto Inventory",
    [string]$ConfigSourcePath = "",
    [switch]$AllowInsecureSourceConfig,
    [switch]$SkipInitialInventoryRun,
    [switch]$SkipScheduledTask
)

$ErrorActionPreference = "Stop"

function Write-InstallLog {
    param([string]$Message)

    $line = "{0} | {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Message
    Write-Host $line

    try {
        New-Item -ItemType Directory -Path $InstallDir -Force -ErrorAction Stop | Out-Null
        Add-Content -LiteralPath (Join-Path $InstallDir "install.log") -Value $line -Encoding UTF8 -ErrorAction Stop
    }
    catch {}
}

function Set-SnipeAutoAcl {
    param(
        [string]$Root,
        [string]$ConfigDir,
        [string]$LogsDir,
        [string]$StateDir,
        [string]$KeyPath
    )

    & icacls.exe $Root /inheritance:e `
        /grant:r "*S-1-5-18:(OI)(CI)F" `
        /grant:r "*S-1-5-32-544:(OI)(CI)F" `
        /grant:r "*S-1-5-11:(OI)(CI)RX" | Out-Null

    & icacls.exe $StateDir /inheritance:r `
        /grant:r "*S-1-5-18:(OI)(CI)F" `
        /grant:r "*S-1-5-32-544:(OI)(CI)F" `
        /grant:r "*S-1-5-11:(OI)(CI)RX" | Out-Null

    & icacls.exe $LogsDir /inheritance:r `
        /grant:r "*S-1-5-18:(OI)(CI)F" `
        /grant:r "*S-1-5-32-544:(OI)(CI)F" `
        /grant:r "*S-1-5-11:(OI)(CI)RX" | Out-Null

    & icacls.exe $ConfigDir /inheritance:r `
        /grant:r "*S-1-5-18:(OI)(CI)F" `
        /grant:r "*S-1-5-32-544:(OI)(CI)F" | Out-Null

    if (Test-Path -LiteralPath $KeyPath) {
        & icacls.exe $KeyPath /inheritance:r `
            /grant:r "*S-1-5-18:F" `
            /grant:r "*S-1-5-32-544:F" | Out-Null
    }
}

function Register-SnipeAutoTask {
    param(
        [string]$ScriptDir,
        [string]$Path,
        [string]$Name
    )

    $launcher = Join-Path $ScriptDir "snipeit_auto.vbs"
    if (-not (Test-Path -LiteralPath $launcher)) {
        throw "Launcher not found: $launcher"
    }

    $action = New-ScheduledTaskAction -Execute "wscript.exe" -Argument "`"$launcher`""
    $logonTrigger = New-ScheduledTaskTrigger -AtLogOn
    $dailyTrigger = New-ScheduledTaskTrigger -Daily -At "12:00"

    try { $logonTrigger.Delay = "PT2M" } catch {}
    try { $dailyTrigger.RandomDelay = "PT30M" } catch {}

    $principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet `
        -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries `
        -StartWhenAvailable `
        -MultipleInstances IgnoreNew `
        -RestartCount 6 `
        -RestartInterval (New-TimeSpan -Hours 1) `
        -ExecutionTimeLimit (New-TimeSpan -Minutes 30)

    $task = New-ScheduledTask `
        -Action $action `
        -Trigger @($logonTrigger, $dailyTrigger) `
        -Principal $principal `
        -Settings $settings `
        -Description "Snipe-IT automatic PC inventory. Runs at user logon and once daily."

    try { $task.Settings.Hidden = $true } catch {}

    Register-ScheduledTask -TaskPath $Path -TaskName $Name -InputObject $task -Force | Out-Null
}

function Test-PowerShellScriptSyntax {
    param([string]$Path)

    $tokens = $null
    $errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors) | Out-Null
    if ($errors.Count -gt 0) {
        $text = ($errors | ForEach-Object { "Line $($_.Extent.StartLineNumber): $($_.Message)" }) -join "; "
        throw "PowerShell syntax check failed for ${Path}: $text"
    }
}

function Test-DeploymentFileChanged {
    param(
        [string]$Source,
        [string]$Destination
    )

    if (-not (Test-Path -LiteralPath $Destination)) { return $true }

    try {
        $sourceHash = (Get-FileHash -LiteralPath $Source -Algorithm SHA256 -ErrorAction Stop).Hash
        $destinationHash = (Get-FileHash -LiteralPath $Destination -Algorithm SHA256 -ErrorAction Stop).Hash
        return ($sourceHash -ne $destinationHash)
    }
    catch {
        return $true
    }
}

function Start-InitialInventoryRun {
    param(
        [string]$InstallDir
    )

    $inventoryScript = Join-Path $InstallDir "snipeit_inventory.ps1"
    if (-not (Test-Path -LiteralPath $inventoryScript)) {
        Write-InstallLog "Initial inventory skipped: script not found: $inventoryScript"
        return
    }

    $arguments = @(
        "-NoProfile",
        "-NonInteractive",
        "-WindowStyle", "Hidden",
        "-ExecutionPolicy", "Bypass",
        "-File", "`"$inventoryScript`"",
        "-GpoMode",
        "-ForceInventory",
        "-ForceEmailReport"
    )

    Start-Process -FilePath "powershell.exe" -ArgumentList $arguments -WindowStyle Hidden
    Write-InstallLog "Initial inventory and forced email report started after install/update."
}

function Test-IsLikelyPublicGpoPath {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    $normalized = $Path.TrimEnd('\')
    return ($normalized -match '(?i)\\(NETLOGON|SYSVOL)(\\|$)')
}

function Copy-InventoryConfigFiles {
    param(
        [string]$SourceRoot,
        [string]$ConfigSourcePath,
        [string]$ConfigDir,
        [switch]$AllowInsecureSourceConfig
    )

    $configSources = @()

    if (-not [string]::IsNullOrWhiteSpace($ConfigSourcePath)) {
        $resolvedConfigSource = [System.IO.Path]::GetFullPath($ConfigSourcePath)
        if (-not (Test-Path -LiteralPath $resolvedConfigSource)) {
            throw "ConfigSourcePath not found: $resolvedConfigSource"
        }
        if ((Test-IsLikelyPublicGpoPath -Path $resolvedConfigSource) -and -not $AllowInsecureSourceConfig) {
            throw "ConfigSourcePath points to public GPO path '$resolvedConfigSource'. Move secrets to a secured share readable by Domain Computers, or use -AllowInsecureSourceConfig explicitly."
        }

        $item = Get-Item -LiteralPath $resolvedConfigSource
        if ($item.PSIsContainer) {
            foreach ($name in @("snipeit_inventory.config.json", "snipeit_inventory.local.json")) {
                $candidate = Join-Path $resolvedConfigSource $name
                if (Test-Path -LiteralPath $candidate) {
                    $configSources += $candidate
                }
            }
        }
        else {
            $configSources += $resolvedConfigSource
        }
    }
    else {
        foreach ($name in @("snipeit_inventory.config.json", "snipeit_inventory.local.json")) {
            $candidate = Join-Path $SourceRoot $name
            if (Test-Path -LiteralPath $candidate) {
                $configSources += $candidate
            }
        }

        if ($configSources.Count -gt 0 -and (Test-IsLikelyPublicGpoPath -Path $SourceRoot) -and -not $AllowInsecureSourceConfig) {
            throw "Secret config found in public GPO path '$SourceRoot'. Move it to a secured share readable by Domain Computers and pass -ConfigSourcePath, or use -AllowInsecureSourceConfig explicitly."
        }
    }

    $changed = $false
    foreach ($source in ($configSources | Select-Object -Unique)) {
        $destination = Join-Path $ConfigDir (Split-Path -Leaf $source)
        if (Test-DeploymentFileChanged -Source $source -Destination $destination) {
            $changed = $true
            Copy-Item -LiteralPath $source -Destination $destination -Force
            Write-InstallLog "Updated protected config $(Split-Path -Leaf $source)"
        }
    }

    return $changed
}

if ([string]::IsNullOrWhiteSpace($SourceRoot)) {
    if (-not [string]::IsNullOrWhiteSpace($PSScriptRoot)) {
        $SourceRoot = $PSScriptRoot
    }
    else {
        $SourceRoot = Split-Path -Parent $PSCommandPath
    }
}
if ([string]::IsNullOrWhiteSpace($InstallDir)) {
    $InstallDir = Join-Path $env:ProgramData "snipeit_auto"
}

$SourceRoot = [System.IO.Path]::GetFullPath($SourceRoot)
$InstallDir = [System.IO.Path]::GetFullPath($InstallDir)
$ConfigDir = Join-Path $InstallDir "Config"
$LogsDir = Join-Path $InstallDir "Logs"
$StateDir = Join-Path $InstallDir "State"
$StateFile = Join-Path $StateDir "inventory-state.json"
$StateMissingBeforeInstall = -not (Test-Path -LiteralPath $StateFile)
$DeploymentChanged = $false

Write-InstallLog "Install started. Source=$SourceRoot InstallDir=$InstallDir"

if (-not (Test-Path -LiteralPath $SourceRoot)) {
    throw "SourceRoot not found: $SourceRoot"
}

New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
New-Item -ItemType Directory -Path $ConfigDir -Force | Out-Null
New-Item -ItemType Directory -Path $LogsDir -Force | Out-Null
New-Item -ItemType Directory -Path $StateDir -Force | Out-Null

$requiredFiles = @(
    "snipeit_inventory.ps1",
    "snipeit_auto.vbs",
    "snipeit_manual.cmd",
    "snipeit_dry_run.cmd",
    "snipeit_ldap_sync_ed25519",
    "snipeit_ldap_sync_ed25519.pub",
    "install_snipeit_auto.ps1"
)

$optionalFiles = @(
    "README-GPO.txt"
)

$UpdatedFileCount = 0
$UnchangedFileCount = 0
foreach ($file in $requiredFiles) {
    $source = Join-Path $SourceRoot $file
    if (-not (Test-Path -LiteralPath $source)) {
        throw "Required file missing: $source"
    }

    $destination = Join-Path $InstallDir $file
    if (Test-DeploymentFileChanged -Source $source -Destination $destination) {
        $DeploymentChanged = $true
        $UpdatedFileCount++
        Copy-Item -LiteralPath $source -Destination $destination -Force
        Write-InstallLog "Updated $file"
    }
    else {
        $UnchangedFileCount++
    }
}

foreach ($file in $optionalFiles) {
    $source = Join-Path $SourceRoot $file
    if (Test-Path -LiteralPath $source) {
        $destination = Join-Path $InstallDir $file
        if (Test-DeploymentFileChanged -Source $source -Destination $destination) {
            $DeploymentChanged = $true
            $UpdatedFileCount++
            Copy-Item -LiteralPath $source -Destination $destination -Force
            Write-InstallLog "Updated optional $file"
        }
        else {
            $UnchangedFileCount++
        }
    }
}
Write-InstallLog "Deployment file check: updated=$UpdatedFileCount unchanged=$UnchangedFileCount"

$ConfigChanged = Copy-InventoryConfigFiles `
    -SourceRoot $SourceRoot `
    -ConfigSourcePath $ConfigSourcePath `
    -ConfigDir $ConfigDir `
    -AllowInsecureSourceConfig:$AllowInsecureSourceConfig
if ($ConfigChanged) {
    $DeploymentChanged = $true
}

Test-PowerShellScriptSyntax -Path (Join-Path $InstallDir "snipeit_inventory.ps1")
Write-InstallLog "PowerShell syntax OK."

$LocalDeploymentRefreshNeeded = $DeploymentChanged -or $StateMissingBeforeInstall
if ($LocalDeploymentRefreshNeeded) {
    Set-SnipeAutoAcl `
        -Root $InstallDir `
        -ConfigDir $ConfigDir `
        -LogsDir $LogsDir `
        -StateDir $StateDir `
        -KeyPath (Join-Path $InstallDir "snipeit_ldap_sync_ed25519")
    Write-InstallLog "ACL configured."
}
else {
    Write-InstallLog "ACL unchanged; refresh skipped."
}

if (-not $SkipScheduledTask) {
    $taskExists = $false
    try {
        Get-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName -ErrorAction Stop | Out-Null
        $taskExists = $true
    }
    catch {}

    if ($LocalDeploymentRefreshNeeded -or -not $taskExists) {
        Register-SnipeAutoTask -ScriptDir $InstallDir -Path $TaskPath -Name $TaskName
        Write-InstallLog "Scheduled task registered: $TaskPath$TaskName"
    }
    else {
        Write-InstallLog "Scheduled task unchanged: $TaskPath$TaskName"
    }
}
else {
    Write-InstallLog "Scheduled task registration skipped."
}

if (-not $SkipInitialInventoryRun -and -not $SkipScheduledTask) {
    if ($DeploymentChanged -or $StateMissingBeforeInstall) {
        Start-InitialInventoryRun -InstallDir $InstallDir
    }
    else {
        Write-InstallLog "Initial inventory skipped: deployment has not changed and state exists."
    }
}

Write-InstallLog "Install completed."
