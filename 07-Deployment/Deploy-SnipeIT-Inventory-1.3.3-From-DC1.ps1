#Requires -Version 5.1
#Requires -RunAsAdministrator

[CmdletBinding()]
param(
    [string]$SearchBase = "OU=Workstations,OU=EXAMPLE Computers,OU=EXAMPLE,DC=example,DC=internal",
    [string]$ExpectedVersion = "1.3.3",
    [string]$PublicShare = "\\AD-SERVER\snipeit_auto$",
    [string]$SecureShare = "\\AD-SERVER\snipeit_auto_secure$",
    [string]$TaskName = "\SnipeIT Inventory Bootstrap",
    [string[]]$LegacyTaskNames = @("\SnipeIT Agent Bootstrap", "\SnipeIT Deploy 1.2.3"),
    [ValidateRange(1, 64)]
    [int]$ThrottleLimit = 32,
    [ValidateRange(250, 10000)]
    [int]$RpcProbeTimeoutMs = 1500,
    [ValidateRange(5, 120)]
    [int]$SchtasksTimeoutSeconds = 25,
    [switch]$Yes
)

$ErrorActionPreference = "Stop"
Import-Module ActiveDirectory -ErrorAction Stop

$installer = Join-Path $PublicShare "install_snipeit_auto.ps1"
$agent = Join-Path $PublicShare "snipeit_inventory.ps1"
$config = Join-Path $SecureShare "snipeit_inventory.local.json"
$privateKey = Join-Path $SecureShare "snipeit_ldap_sync_ed25519"
$publicKey = Join-Path $SecureShare "snipeit_ldap_sync_ed25519.pub"

foreach ($path in @($installer, $agent, $config, $privateKey, $publicKey)) {
    if (-not (Test-Path -LiteralPath $path)) {
        throw "Required deployment file was not found: $path"
    }
    if ($path -match "\s") {
        throw "Deployment UNC paths must not contain spaces: $path"
    }
}

$agentText = Get-Content -LiteralPath $agent -Raw
$versionMatch = [regex]::Match(
    $agentText,
    '\$InventoryAgentVersion\s*=\s*"([^"]+)"'
)
if (-not $versionMatch.Success) {
    throw "InventoryAgentVersion was not found in $agent"
}

$shareVersion = $versionMatch.Groups[1].Value
if ($shareVersion -ne $ExpectedVersion) {
    throw "STOPPED: share version is '$shareVersion'; expected '$ExpectedVersion'."
}

$configText = Get-Content -LiteralPath $config -Raw
$configObject = $configText | ConvertFrom-Json
$requiredConfigFields = @(
    "SnipeUrl",
    "SnipeToken",
    "SmtpServer",
    "SmtpUser",
    "SmtpPass",
    "InventoryRelayEnabled",
    "InventoryRelayHmacSecret",
    "InventoryRelayMailTo",
    "SnipeSshKeyPath"
)
foreach ($field in $requiredConfigFields) {
    $property = $configObject.PSObject.Properties[$field]
    if (-not $property -or [string]::IsNullOrWhiteSpace([string]$property.Value)) {
        throw "Protected config field is missing or empty: $field"
    }
}
if ($configText -match '(?i)PUT_[A-Z0-9_]+|CHANGEME|REPLACE_ME') {
    throw "Protected config contains a placeholder value."
}
$expectedClientKeyPath = "C:\ProgramData\snipeit_auto\Config\snipeit_ldap_sync_ed25519"
if (-not ([string]$configObject.SnipeSshKeyPath).Equals(
    $expectedClientKeyPath,
    [System.StringComparison]::OrdinalIgnoreCase
)) {
    throw "Protected config SnipeSshKeyPath must be '$expectedClientKeyPath'."
}
if (Test-Path -LiteralPath (Join-Path $PublicShare "snipeit_ldap_sync_ed25519")) {
    throw "Private SSH key was found on the public share. Remove it before deployment."
}

try {
    Get-ADOrganizationalUnit -Identity $SearchBase -ErrorAction Stop | Out-Null
}
catch {
    throw "SearchBase does not exist: $SearchBase"
}

$computers = @(
    Get-ADComputer `
        -SearchBase $SearchBase `
        -SearchScope Subtree `
        -Filter 'Enabled -eq $true' `
        -Properties DNSHostName |
    Sort-Object Name
)

if ($computers.Count -eq 0) {
    throw "No enabled computers were found under $SearchBase"
}

$bootstrap = Join-Path $PublicShare "install_snipeit_auto.vbs"
if (-not (Test-Path -LiteralPath $bootstrap)) {
    throw "Required deployment file was not found: $bootstrap"
}
$action = "wscript.exe `"$bootstrap`""

Write-Host "Share version: $shareVersion" -ForegroundColor Green
Write-Host "Enabled computers: $($computers.Count)" -ForegroundColor Cyan
Write-Host "Parallel workers: $ThrottleLimit" -ForegroundColor Cyan
Write-Host "Remote task: $TaskName" -ForegroundColor Cyan
Write-Host "The task starts now and retries two minutes after future boots." -ForegroundColor DarkCyan

if (-not $Yes) {
    $confirmation = Read-Host "Type YES to start"
    if ($confirmation -cne "YES") {
        Write-Host "Cancelled."
        return
    }
}

$worker = {
    param(
        [string]$RemoteHost,
        [string]$ComputerName,
        [string]$RemoteTaskName,
        [string[]]$OldTaskNames,
        [string]$RemoteAction,
        [int]$ProbeTimeoutMs,
        [int]$CommandTimeoutSeconds
    )

    function Test-RpcEndpoint {
        param([string]$Name, [int]$TimeoutMs)

        $client = [System.Net.Sockets.TcpClient]::new()
        try {
            $connect = $client.BeginConnect($Name, 135, $null, $null)
            if (-not $connect.AsyncWaitHandle.WaitOne($TimeoutMs, $false)) {
                return $false
            }
            $client.EndConnect($connect)
            return $true
        }
        catch {
            return $false
        }
        finally {
            $client.Dispose()
        }
    }

    function Invoke-SchtasksTimed {
        param([string]$Arguments, [int]$TimeoutSeconds)

        $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
        $startInfo.FileName = "$env:SystemRoot\System32\schtasks.exe"
        $startInfo.Arguments = $Arguments
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $true
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true

        $process = [System.Diagnostics.Process]::new()
        $process.StartInfo = $startInfo
        try {
            if (-not $process.Start()) {
                return [pscustomobject]@{ ExitCode = -1; TimedOut = $false; Message = "schtasks did not start" }
            }

            $stdoutTask = $process.StandardOutput.ReadToEndAsync()
            $stderrTask = $process.StandardError.ReadToEndAsync()

            if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
                try { $process.Kill() } catch {}
                return [pscustomobject]@{ ExitCode = -1; TimedOut = $true; Message = "schtasks timeout" }
            }

            $process.WaitForExit()
            $message = (($stdoutTask.GetAwaiter().GetResult() + " " + $stderrTask.GetAwaiter().GetResult()) -replace '\s+', ' ').Trim()
            if ($message.Length -gt 500) {
                $message = $message.Substring(0, 500)
            }

            return [pscustomobject]@{
                ExitCode = $process.ExitCode
                TimedOut = $false
                Message = $message
            }
        }
        catch {
            return [pscustomobject]@{ ExitCode = -1; TimedOut = $false; Message = $_.Exception.Message }
        }
        finally {
            $process.Dispose()
        }
    }

    if (-not (Test-RpcEndpoint -Name $RemoteHost -TimeoutMs $ProbeTimeoutMs)) {
        return [pscustomobject]@{
            Computer = $ComputerName
            Status = "OfflineOrRpcBlocked"
            Message = "TCP/135 is unavailable"
        }
    }

    $createArgs = '/Create /S {0} /TN "{1}" /SC ONSTART /DELAY 0002:00 /RU SYSTEM /RL HIGHEST /TR "{2}" /F' -f `
        $RemoteHost, $RemoteTaskName, $RemoteAction
    $create = Invoke-SchtasksTimed -Arguments $createArgs -TimeoutSeconds $CommandTimeoutSeconds

    if ($create.TimedOut) {
        return [pscustomobject]@{ Computer = $ComputerName; Status = "CreateTimeout"; Message = $create.Message }
    }
    if ($create.ExitCode -ne 0) {
        return [pscustomobject]@{ Computer = $ComputerName; Status = "CreateFailed"; Message = $create.Message }
    }

    $runArgs = '/Run /S {0} /TN "{1}"' -f $RemoteHost, $RemoteTaskName
    $run = Invoke-SchtasksTimed -Arguments $runArgs -TimeoutSeconds $CommandTimeoutSeconds

    if ($run.TimedOut) {
        return [pscustomobject]@{ Computer = $ComputerName; Status = "RunTimeout"; Message = $run.Message }
    }
    $runStatus = ""
    if ($run.ExitCode -eq 0) {
        $runStatus = "Started"
    }
    elseif ($run.Message -match '(?i)already.*run|already.*start|already running|уже выполня|уже запущ') {
        $runStatus = "AlreadyRunning"
    }

    if ($runStatus) {
        foreach ($oldTaskName in @($OldTaskNames)) {
            if ([string]::IsNullOrWhiteSpace($oldTaskName) -or $oldTaskName -eq $RemoteTaskName) {
                continue
            }
            $deleteArgs = '/Delete /S {0} /TN "{1}" /F' -f $RemoteHost, $oldTaskName
            [void](Invoke-SchtasksTimed -Arguments $deleteArgs -TimeoutSeconds 10)
        }
        return [pscustomobject]@{ Computer = $ComputerName; Status = $runStatus; Message = $run.Message }
    }

    return [pscustomobject]@{ Computer = $ComputerName; Status = "RunFailed"; Message = $run.Message }
}

$pool = [runspacefactory]::CreateRunspacePool(1, $ThrottleLimit)
$pool.Open()
$jobs = [System.Collections.Generic.List[object]]::new()
$results = [System.Collections.Generic.List[object]]::new()

try {
    foreach ($computer in $computers) {
        $remoteHost = if ([string]::IsNullOrWhiteSpace([string]$computer.DNSHostName)) {
            $computer.Name
        }
        else {
            [string]$computer.DNSHostName
        }
        $powershell = [powershell]::Create()
        $powershell.RunspacePool = $pool
        [void]$powershell.AddScript($worker)
        [void]$powershell.AddArgument($remoteHost)
        [void]$powershell.AddArgument($computer.Name)
        [void]$powershell.AddArgument($TaskName)
        [void]$powershell.AddArgument($LegacyTaskNames)
        [void]$powershell.AddArgument($action)
        [void]$powershell.AddArgument($RpcProbeTimeoutMs)
        [void]$powershell.AddArgument($SchtasksTimeoutSeconds)

        $jobs.Add([pscustomobject]@{
            Computer = $computer.Name
            PowerShell = $powershell
            Handle = $powershell.BeginInvoke()
            Completed = $false
        }) | Out-Null
    }

    $completedCount = 0
    while ($completedCount -lt $jobs.Count) {
        foreach ($job in $jobs) {
            if ($job.Completed -or -not $job.Handle.IsCompleted) {
                continue
            }

            try {
                $output = @($job.PowerShell.EndInvoke($job.Handle))
                if ($output.Count -gt 0) {
                    $result = $output[-1]
                }
                else {
                    $message = ($job.PowerShell.Streams.Error | Out-String).Trim()
                    $result = [pscustomobject]@{
                        Computer = $job.Computer
                        Status = "WorkerFailed"
                        Message = $message
                    }
                }
            }
            catch {
                $result = [pscustomobject]@{
                    Computer = $job.Computer
                    Status = "WorkerFailed"
                    Message = $_.Exception.Message
                }
            }
            finally {
                $job.PowerShell.Dispose()
                $job.Completed = $true
            }

            $results.Add($result) | Out-Null
            $completedCount++
            $percent = [math]::Floor(($completedCount / $jobs.Count) * 100)
            Write-Progress `
                -Activity "Deploying SnipeIT Inventory $ExpectedVersion" `
                -Status "[$completedCount/$($jobs.Count)] $($result.Computer): $($result.Status)" `
                -PercentComplete $percent

            $color = switch ($result.Status) {
                "Started" { "Green" }
                "AlreadyRunning" { "DarkGreen" }
                "OfflineOrRpcBlocked" { "DarkYellow" }
                default { "Yellow" }
            }
            Write-Host ("[{0}/{1}] {2,-20} {3}" -f $completedCount, $jobs.Count, $result.Computer, $result.Status) -ForegroundColor $color
        }
        Start-Sleep -Milliseconds 100
    }
}
finally {
    foreach ($job in $jobs) {
        if (-not $job.Completed) {
            try { $job.PowerShell.Stop() } catch {}
            $job.PowerShell.Dispose()
        }
    }
    $pool.Close()
    $pool.Dispose()
    Write-Progress -Activity "Deploying SnipeIT Inventory $ExpectedVersion" -Completed
}

Write-Host ""
Write-Host "Summary" -ForegroundColor Cyan
$results |
    Group-Object Status |
    Sort-Object Name |
    Select-Object Name, Count |
    Format-Table -AutoSize

$notStarted = @($results | Where-Object { $_.Status -notin @("Started", "AlreadyRunning") })
if ($notStarted.Count -gt 0) {
    Write-Host "Not started ($($notStarted.Count)); rerun the same script later:" -ForegroundColor Yellow
    $notStarted |
        Sort-Object Computer |
        Select-Object Computer, Status, Message |
        Format-Table -Wrap -AutoSize
}
else {
Write-Host "Installer was started on every reachable computer." -ForegroundColor Green
}

Write-Host "No CSV was created. Repeated execution is safe because the installer compares SHA-256." -ForegroundColor DarkCyan
