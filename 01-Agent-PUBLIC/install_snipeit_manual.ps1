[CmdletBinding()]
param(
    [switch]$Elevated,
    [switch]$RunInstaller
)

$ErrorActionPreference = "Stop"
$PublicRoot = "\\AD-SERVER\snipeit_auto$"
$SecureRoot = "\\AD-SERVER\snipeit_auto_secure$"
$InstallerPath = Join-Path $PublicRoot "install_snipeit_auto.ps1"
$ConfigPath = Join-Path $SecureRoot "snipeit_inventory.local.json"
$SshKeyPath = Join-Path $SecureRoot "snipeit_ldap_sync_ed25519"
$InstallRoot = Join-Path $env:ProgramData "snipeit_auto"
$LogDir = Join-Path $InstallRoot "Logs"
$LogPath = Join-Path $LogDir "manual-install.log"
$BootstrapDir = Join-Path $InstallRoot "Bootstrap"
$BootstrapPath = Join-Path $BootstrapDir "install_snipeit_manual.ps1"
$BootstrapTaskName = "SnipeIT Inventory Manual Installer"
$AgentTaskPath = "\SnipeIT Inventory\"
$AgentTaskName = "Inventory Agent"

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Write-ManualLog {
    param([string]$Message)

    New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
    $line = "{0} {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Message
    [IO.File]::AppendAllText($LogPath, $line + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
}

if ($RunInstaller) {
    try {
        Write-ManualLog "SYSTEM bootstrap started."
        if (-not (Test-Path -LiteralPath $InstallerPath -PathType Leaf)) {
            throw "Public installer is unavailable: $InstallerPath"
        }
        if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
            throw "Protected config is unavailable to SYSTEM: $ConfigPath"
        }
        if (-not (Test-Path -LiteralPath $SshKeyPath -PathType Leaf)) {
            throw "Protected LDAP SSH key is unavailable to SYSTEM: $SshKeyPath"
        }

        & $InstallerPath `
            -SourceRoot $PublicRoot `
            -ConfigSourcePath $ConfigPath `
            -SshKeySourcePath $SshKeyPath *>> $LogPath

        Write-ManualLog "SYSTEM bootstrap completed successfully."
        exit 0
    }
    catch {
        Write-ManualLog "SYSTEM bootstrap failed: $($_.Exception.Message)"
        exit 1
    }
}

if (-not (Test-IsAdministrator)) {
    $arguments = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -Elevated' -f $PSCommandPath
    try {
        $process = Start-Process `
            -FilePath "powershell.exe" `
            -ArgumentList $arguments `
            -Verb RunAs `
            -Wait `
            -PassThru
        exit $process.ExitCode
    }
    catch {
        Write-Host "Administrator elevation was cancelled or failed." -ForegroundColor Red
        exit 1
    }
}

$task = $null
try {
    Write-Host "SnipeIT Inventory manual installation" -ForegroundColor Cyan
    Write-Host "The installer will run silently as SYSTEM." -ForegroundColor Gray

    New-Item -ItemType Directory -Path $BootstrapDir -Force | Out-Null
    Copy-Item -LiteralPath $PSCommandPath -Destination $BootstrapPath -Force
    & icacls.exe $BootstrapDir /inheritance:r /grant:r `
        "*S-1-5-18:(OI)(CI)F" `
        "*S-1-5-32-544:(OI)(CI)F" | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "Could not secure the local bootstrap directory."
    }

    $actionArguments = '-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}" -RunInstaller' -f $BootstrapPath
    $action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument $actionArguments
    $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(5)
    $principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet `
        -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries `
        -ExecutionTimeLimit (New-TimeSpan -Minutes 15)
    $task = New-ScheduledTask `
        -Action $action `
        -Trigger $trigger `
        -Principal $principal `
        -Settings $settings `
        -Description "One-time SYSTEM bootstrap for SnipeIT Inventory"

    Unregister-ScheduledTask -TaskName $BootstrapTaskName -Confirm:$false -ErrorAction SilentlyContinue
    Register-ScheduledTask -TaskName $BootstrapTaskName -InputObject $task -Force | Out-Null
    $startedAfter = (Get-Date).AddSeconds(-2)
    Start-ScheduledTask -TaskName $BootstrapTaskName
    Write-Host "Installation started..." -ForegroundColor Yellow

    $deadline = (Get-Date).AddMinutes(15)
    $hasStarted = $false
    do {
        Start-Sleep -Seconds 2
        $state = (Get-ScheduledTask -TaskName $BootstrapTaskName -ErrorAction Stop).State
        $info = Get-ScheduledTaskInfo -TaskName $BootstrapTaskName -ErrorAction Stop
        $hasStarted = $info.LastRunTime -ge $startedAfter
    } while ((-not $hasStarted -or $state -eq "Running") -and (Get-Date) -lt $deadline)

    if (-not $hasStarted) {
        throw "The SYSTEM installation task did not start within 15 minutes."
    }
    if ($state -eq "Running") {
        throw "Installation did not finish within 15 minutes."
    }

    $result = $info.LastTaskResult
    if ($result -ne 0) {
        throw "SYSTEM installer failed with task result $result. See $LogPath"
    }

    Get-ScheduledTask -TaskPath $AgentTaskPath -TaskName $AgentTaskName -ErrorAction Stop | Out-Null
    Write-Host "Installed successfully." -ForegroundColor Green
    Write-Host "Permanent task: $AgentTaskPath$AgentTaskName" -ForegroundColor Green
    Write-Host "Log: $LogPath" -ForegroundColor Gray
}
catch {
    Write-Host "Installation failed: $($_.Exception.Message)" -ForegroundColor Red
    if (Test-Path -LiteralPath $LogPath) {
        Write-Host "Last log lines:" -ForegroundColor Yellow
        Get-Content -LiteralPath $LogPath -Tail 20
    }
    exit 1
}
finally {
    Unregister-ScheduledTask -TaskName $BootstrapTaskName -Confirm:$false -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $BootstrapDir -Recurse -Force -ErrorAction SilentlyContinue
}

exit 0
