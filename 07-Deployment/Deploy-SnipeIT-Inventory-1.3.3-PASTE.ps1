Import-Module ActiveDirectory

$searchBase = "OU=Workstations,OU=EXAMPLE Computers,OU=EXAMPLE,DC=example,DC=internal"
$expectedVersion = "1.3.3"
$installer = "\\AD-SERVER\snipeit_auto$\install_snipeit_auto.ps1"
$agent = "\\AD-SERVER\snipeit_auto$\snipeit_inventory.ps1"
$config = "\\AD-SERVER\snipeit_auto_secure$\snipeit_inventory.local.json"
$privateKey = "\\AD-SERVER\snipeit_auto_secure$\snipeit_ldap_sync_ed25519"
$publicKey = "\\AD-SERVER\snipeit_auto_secure$\snipeit_ldap_sync_ed25519.pub"
$bootstrap = "\\AD-SERVER\snipeit_auto$\install_snipeit_auto.vbs"
$taskName = "\SnipeIT Inventory Bootstrap"
$throttle = 32

foreach ($path in @($installer, $agent, $config, $privateKey, $publicKey, $bootstrap)) {
    if (-not (Test-Path -LiteralPath $path)) { throw "Не найден файл: $path" }
}
$agentText = Get-Content -LiteralPath $agent -Raw
$versionMatch = [regex]::Match($agentText, '\$InventoryAgentVersion\s*=\s*"([^"]+)"')
if (-not $versionMatch.Success) { throw "В файле агента не найдена версия" }
$shareVersion = $versionMatch.Groups[1].Value
if ($shareVersion -ne $expectedVersion) {
    throw "ОСТАНОВЛЕНО: на шаре версия '$shareVersion', ожидалась '$expectedVersion'"
}

$configText = Get-Content -LiteralPath $config -Raw
$configObject = $configText | ConvertFrom-Json
foreach ($field in @("SnipeToken", "SmtpPass", "InventoryRelayHmacSecret", "InventoryRelayMailTo", "SnipeSshKeyPath")) {
    if (-not $configObject.PSObject.Properties[$field] -or
        [string]::IsNullOrWhiteSpace([string]$configObject.$field)) {
        throw "В закрытом конфиге не заполнено поле: $field"
    }
}
if ($configText -match '(?i)PUT_[A-Z0-9_]+|CHANGEME|REPLACE_ME') {
    throw "В закрытом конфиге остался placeholder"
}
$expectedClientKeyPath = "C:\ProgramData\snipeit_auto\Config\snipeit_ldap_sync_ed25519"
if (-not ([string]$configObject.SnipeSshKeyPath).Equals(
    $expectedClientKeyPath,
    [System.StringComparison]::OrdinalIgnoreCase
)) {
    throw "SnipeSshKeyPath должен быть '$expectedClientKeyPath'"
}
if (Test-Path -LiteralPath "\\AD-SERVER\snipeit_auto$\snipeit_ldap_sync_ed25519") {
    throw "Приватный SSH-ключ найден на публичной шаре"
}

Get-ADOrganizationalUnit -Identity $searchBase -ErrorAction Stop | Out-Null
$computers = @(
    Get-ADComputer -SearchBase $searchBase -SearchScope Subtree `
        -Filter 'Enabled -eq $true' -Properties DNSHostName |
    Sort-Object Name
)
if ($computers.Count -eq 0) { throw "В OU нет включённых компьютеров" }

Write-Host "На шаре проверена версия: $shareVersion" -ForegroundColor Green
Write-Host "Компьютеров: $($computers.Count), параллельно: $throttle" -ForegroundColor Cyan
if ((Read-Host "Для запуска напиши ДА") -cne "ДА") { Write-Host "Отменено"; return }

$action = "wscript.exe `"$bootstrap`""
$worker = {
    param($computerName, $remoteHost, $taskName, $action)
    try {
        $tcp = [System.Net.Sockets.TcpClient]::new()
        try {
            $connect = $tcp.BeginConnect($remoteHost, 135, $null, $null)
            if (-not $connect.AsyncWaitHandle.WaitOne(1500, $false)) {
                return [pscustomobject]@{Computer=$computerName;Status="OfflineOrRpcBlocked";Message="TCP/135 недоступен"}
            }
            $tcp.EndConnect($connect)
        }
        catch {
            return [pscustomobject]@{Computer=$computerName;Status="OfflineOrRpcBlocked";Message=$_.Exception.Message}
        }
        finally { $tcp.Dispose() }

        $createOutput = & schtasks.exe /Create /S $remoteHost /TN $taskName `
            /SC ONSTART /DELAY 0002:00 /RU SYSTEM /RL HIGHEST /TR $action /F 2>&1
        $createCode = $LASTEXITCODE
        if ($createCode -ne 0) {
            return [pscustomobject]@{Computer=$computerName;Status="CreateFailed";Message=($createOutput -join " ")}
        }

        $runOutput = & schtasks.exe /Run /S $remoteHost /TN $taskName 2>&1
        $runCode = $LASTEXITCODE
        $runMessage = $runOutput -join " "
        if ($runCode -eq 0 -or $runMessage -match '(?i)already.*run|already.*start|уже выполня|уже запущ') {
            & schtasks.exe /Delete /S $remoteHost /TN "\SnipeIT Agent Bootstrap" /F 2>&1 | Out-Null
            & schtasks.exe /Delete /S $remoteHost /TN "\SnipeIT Deploy 1.2.3" /F 2>&1 | Out-Null
            $status = if ($runCode -eq 0) { "Started" } else { "AlreadyRunning" }
            return [pscustomobject]@{Computer=$computerName;Status=$status;Message=$runMessage}
        }

        return [pscustomobject]@{Computer=$computerName;Status="RunFailed";Message=$runMessage}
    }
    catch {
        return [pscustomobject]@{Computer=$computerName;Status="WorkerFailed";Message=$_.Exception.Message}
    }
}

$queue = [System.Collections.Generic.Queue[object]]::new()
foreach ($computer in $computers) { $queue.Enqueue($computer) }
$running = @{}
$results = [System.Collections.Generic.List[object]]::new()
$completed = 0

while ($queue.Count -gt 0 -or $running.Count -gt 0) {
    while ($queue.Count -gt 0 -and $running.Count -lt $throttle) {
        $computer = $queue.Dequeue()
        $remoteHost = if ($computer.DNSHostName) { $computer.DNSHostName } else { $computer.Name }
        $job = Start-Job -ScriptBlock $worker -ArgumentList $computer.Name,$remoteHost,$taskName,$action
        $running[$job.Id] = $job
    }

    $done = Wait-Job -Job @($running.Values) -Any
    $result = @(Receive-Job -Job $done)[-1]
    Remove-Job -Job $done
    $running.Remove($done.Id)
    $results.Add($result) | Out-Null
    $completed++

    $percent = [math]::Floor(($completed / $computers.Count) * 100)
    Write-Progress -Activity "Развёртывание SnipeIT Inventory $expectedVersion" `
        -Status "[$completed/$($computers.Count)] $($result.Computer): $($result.Status)" `
        -PercentComplete $percent
    $color = if ($result.Status -in @("Started", "AlreadyRunning")) { "Green" } else { "Yellow" }
    Write-Host "[$completed/$($computers.Count)] $($result.Computer) - $($result.Status)" -ForegroundColor $color
}

Write-Progress -Activity "Развёртывание SnipeIT Inventory $expectedVersion" -Completed
Write-Host "`nИТОГ:" -ForegroundColor Cyan
$results | Group-Object Status | Sort-Object Name | Select-Object Name,Count | Format-Table -AutoSize

$failed = @($results | Where-Object Status -notin @("Started", "AlreadyRunning"))
if ($failed.Count -gt 0) {
    Write-Host "Не запустились; этот же блок можно повторить позже:" -ForegroundColor Yellow
    $failed | Sort-Object Computer | Select-Object Computer,Status,Message | Format-Table -Wrap -AutoSize
}
