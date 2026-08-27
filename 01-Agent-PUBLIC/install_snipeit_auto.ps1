#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]$SourceRoot = $PSScriptRoot,
    [string]$InstallDir = (Join-Path $env:ProgramData "snipeit_auto"),
    [string]$TaskPath = "\SnipeIT Inventory\",
    [string]$TaskName = "Inventory Agent",
    [string]$ConfigSourcePath = "",
    [string]$SshKeySourcePath = "",
    [int]$InstallLogRetentionDays = 30,
    [int]$InstallLogRetentionRuns = 60,
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

function Invoke-InstallLogRetention {
    param(
        [string]$Path,
        [int]$RetentionDays,
        [int]$MaxRuns
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return 0 }
    try {
        $content = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
        $blocks = @([regex]::Split(
            $content,
            '(?m)(?=^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2} \| Install started\.)'
        ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        if ($blocks.Count -eq 0) { return 0 }

        $cutoff = (Get-Date).AddDays(-[Math]::Max(1, $RetentionDays))
        $kept = @($blocks | Where-Object {
            $line = ([string]$_ -split "`r?`n", 2)[0]
            $timestamp = [datetime]::MinValue
            if ($line.Length -ge 19) {
                [void][datetime]::TryParseExact(
                    $line.Substring(0, 19),
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
        return $removed
    }
    catch {
        return 0
    }
}

function Invoke-IcaclsChecked {
    param(
        [Parameter(Mandatory=$true)][string[]]$Arguments,
        [Parameter(Mandatory=$true)][string]$Description
    )

    $output = @(& icacls.exe @Arguments 2>&1)
    if ($LASTEXITCODE -ne 0) {
        $details = ($output | ForEach-Object { [string]$_ }) -join " "
        throw "ACL configuration failed for ${Description}: icacls exit code $LASTEXITCODE. $details"
    }
}

function Set-SnipeExactAcl {
    param(
        [Parameter(Mandatory=$true)][string]$Path,
        [switch]$Container,
        [switch]$AllowAuthenticatedUsersRead
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "ACL target not found: $Path"
    }

    $acl = Get-Acl -LiteralPath $Path -ErrorAction Stop
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($rule in @($acl.Access)) {
        [void]$acl.RemoveAccessRuleSpecific($rule)
    }

    $inheritance = if ($Container) {
        [System.Security.AccessControl.InheritanceFlags]::ContainerInherit -bor
            [System.Security.AccessControl.InheritanceFlags]::ObjectInherit
    }
    else {
        [System.Security.AccessControl.InheritanceFlags]::None
    }
    $propagation = [System.Security.AccessControl.PropagationFlags]::None
    $allow = [System.Security.AccessControl.AccessControlType]::Allow
    $fullControl = [System.Security.AccessControl.FileSystemRights]::FullControl
    $readAndExecute = [System.Security.AccessControl.FileSystemRights]::ReadAndExecute

    foreach ($sidValue in @("S-1-5-18", "S-1-5-32-544")) {
        $sid = New-Object System.Security.Principal.SecurityIdentifier($sidValue)
        $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
            $sid,
            $fullControl,
            $inheritance,
            $propagation,
            $allow
        )
        [void]$acl.AddAccessRule($rule)
    }

    if ($AllowAuthenticatedUsersRead) {
        $authenticatedUsers = New-Object System.Security.Principal.SecurityIdentifier("S-1-5-11")
        $readRule = New-Object System.Security.AccessControl.FileSystemAccessRule(
            $authenticatedUsers,
            $readAndExecute,
            $inheritance,
            $propagation,
            $allow
        )
        [void]$acl.AddAccessRule($readRule)
    }

    Set-Acl -LiteralPath $Path -AclObject $acl -ErrorAction Stop
    Invoke-IcaclsChecked -Description "$Path owner" -Arguments @(
        $Path,
        "/setowner", "*S-1-5-32-544"
    )
}

function Set-SnipeConfigAcl {
    param([Parameter(Mandatory=$true)][string]$ConfigDir)

    $children = @(
        Get-ChildItem -LiteralPath $ConfigDir -Force -Recurse -ErrorAction Stop |
            Sort-Object { $_.FullName.Length } -Descending
    )
    foreach ($child in $children) {
        Set-SnipeExactAcl -Path $child.FullName -Container:$child.PSIsContainer
    }
    Set-SnipeExactAcl -Path $ConfigDir -Container
}

function Set-SnipeAutoAcl {
    param(
        [string]$Root,
        [string]$ConfigDir,
        [string]$LogsDir,
        [string]$StateDir,
        [string]$KeyPath
    )

    $configPrefix = "$($ConfigDir.TrimEnd('\'))\"
    $publicChildren = @(
        Get-ChildItem -LiteralPath $Root -Force -Recurse -ErrorAction Stop |
            Where-Object {
                $_.FullName -ne $KeyPath -and
                $_.FullName -ne $ConfigDir -and
                -not $_.FullName.StartsWith($configPrefix, [System.StringComparison]::OrdinalIgnoreCase)
            } |
            Sort-Object { $_.FullName.Length } -Descending
    )
    foreach ($child in $publicChildren) {
        Set-SnipeExactAcl `
            -Path $child.FullName `
            -Container:$child.PSIsContainer `
            -AllowAuthenticatedUsersRead
    }
    Set-SnipeExactAcl -Path $Root -Container -AllowAuthenticatedUsersRead

    if (Test-Path -LiteralPath $KeyPath) {
        Set-SnipeExactAcl -Path $KeyPath
    }
    Set-SnipeConfigAcl -ConfigDir $ConfigDir
}

function Remove-LegacySnipeSshKeyCopies {
    param(
        [Parameter(Mandatory=$true)][string]$InstallDir,
        [Parameter(Mandatory=$true)][string]$CurrentKeyPath,
        [string[]]$LegacyLocalAppDataRoots = @(),
        [switch]$SkipProfileDiscovery
    )

    if (-not (Test-Path -LiteralPath $CurrentKeyPath -PathType Leaf)) {
        throw "Protected LDAP SSH key is missing after ACL configuration: $CurrentKeyPath"
    }

    $legacyPaths = [System.Collections.Generic.List[string]]::new()
    $legacyPaths.Add((Join-Path $InstallDir "snipeit_ldap_sync_ed25519"))
    $legacyPaths.Add((Join-Path $InstallDir "snipeit_ldap_sync_ed25519.pub"))

    foreach ($localAppDataRoot in @($LegacyLocalAppDataRoots)) {
        if ([string]::IsNullOrWhiteSpace($localAppDataRoot)) { continue }
        $legacyPaths.Add((Join-Path $localAppDataRoot "snipeit_auto\snipeit_ldap_sync_ed25519"))
        $legacyPaths.Add((Join-Path $localAppDataRoot "snipeit_auto\snipeit_ldap_sync_ed25519.pub"))
    }

    if (-not $SkipProfileDiscovery) {
        if (-not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
            $legacyPaths.Add((Join-Path $env:LOCALAPPDATA "snipeit_auto\snipeit_ldap_sync_ed25519"))
            $legacyPaths.Add((Join-Path $env:LOCALAPPDATA "snipeit_auto\snipeit_ldap_sync_ed25519.pub"))
        }

        try {
            foreach ($profile in @(Get-CimInstance Win32_UserProfile -ErrorAction Stop)) {
                if ([string]::IsNullOrWhiteSpace([string]$profile.LocalPath)) { continue }
                $legacyPaths.Add((Join-Path ([string]$profile.LocalPath) "AppData\Local\snipeit_auto\snipeit_ldap_sync_ed25519"))
                $legacyPaths.Add((Join-Path ([string]$profile.LocalPath) "AppData\Local\snipeit_auto\snipeit_ldap_sync_ed25519.pub"))
            }
        }
        catch {
            Write-InstallLog "Legacy key cleanup: Win32_UserProfile enumeration unavailable; known paths will still be cleaned."
        }
    }

    $removed = 0
    foreach ($candidate in @($legacyPaths | Select-Object -Unique)) {
        try {
            $fullCandidate = [System.IO.Path]::GetFullPath($candidate)
            if ($fullCandidate.Equals($CurrentKeyPath, [System.StringComparison]::OrdinalIgnoreCase)) { continue }
            if (-not (Test-Path -LiteralPath $fullCandidate -PathType Leaf)) { continue }

            Remove-Item -LiteralPath $fullCandidate -Force -ErrorAction Stop
            $removed++
            Write-InstallLog "Removed legacy LDAP SSH key artifact: $fullCandidate"
        }
        catch {
            throw "Cannot remove legacy LDAP SSH key artifact '$candidate': $($_.Exception.Message)"
        }
    }

    return $removed
}

function Remove-LegacySnipeScheduledTask {
    param(
        [string]$CurrentTaskPath,
        [string]$CurrentTaskName
    )

    $legacyPath = "\SnipeIT\"
    $legacyName = "Auto Inventory"
    if ($CurrentTaskPath -eq $legacyPath -and $CurrentTaskName -eq $legacyName) {
        return $false
    }

    try {
        Get-ScheduledTask -TaskPath $legacyPath -TaskName $legacyName -ErrorAction Stop | Out-Null
        Unregister-ScheduledTask -TaskPath $legacyPath -TaskName $legacyName -Confirm:$false -ErrorAction Stop
        Write-InstallLog "Removed legacy scheduled task: $legacyPath$legacyName"
        return $true
    }
    catch {
        if ($_.Exception.Message -notmatch '(?i)cannot find|не удается найти|не найден') {
            Write-InstallLog "Legacy scheduled task cleanup skipped: $($_.Exception.Message)"
        }
        return $false
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
    $startupTrigger = New-ScheduledTaskTrigger -AtStartup
    $logonTrigger = New-ScheduledTaskTrigger -AtLogOn
    $dailyTriggers = @(
        New-ScheduledTaskTrigger -Daily -At "08:00"
        New-ScheduledTaskTrigger -Daily -At "14:00"
        New-ScheduledTaskTrigger -Daily -At "20:00"
    )

    try { $startupTrigger.Delay = "PT5M" } catch {}
    try { $logonTrigger.Delay = "PT2M" } catch {}
    foreach ($trigger in $dailyTriggers) {
        try { $trigger.RandomDelay = "PT1H" } catch {}
    }
    $allTriggers = @($startupTrigger, $logonTrigger) + @($dailyTriggers)

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
        -Trigger $allTriggers `
        -Principal $principal `
        -Settings $settings `
        -Description "SnipeIT Inventory Agent. Runs at startup, user logon, and three randomized times daily."

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

    $launcher = Join-Path $InstallDir "snipeit_auto.vbs"
    if (-not (Test-Path -LiteralPath $launcher)) {
        Write-InstallLog "Initial inventory skipped: hidden launcher not found: $launcher"
        return
    }

    $arguments = @(
        "`"$launcher`"",
        "-DeploymentRun",
        "-ForceInventory",
        "-ForceEmailReport"
    )

    $wscript = Join-Path $env:SystemRoot "System32\wscript.exe"
    Start-Process -FilePath $wscript -ArgumentList $arguments -WindowStyle Hidden
    Write-InstallLog "Initial inventory and forced email report started after install/update."
}

function Test-IsLikelyPublicGpoPath {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    $normalized = $Path.TrimEnd('\')
    return ($normalized -match '(?i)\\(NETLOGON|SYSVOL)(\\|$)')
}

function Test-IsPathInsideRoot {
    param(
        [string]$Path,
        [string]$Root
    )

    if ([string]::IsNullOrWhiteSpace($Path) -or [string]::IsNullOrWhiteSpace($Root)) {
        return $false
    }

    $fullPath = [System.IO.Path]::GetFullPath($Path).TrimEnd('\')
    $fullRoot = [System.IO.Path]::GetFullPath($Root).TrimEnd('\')
    return (
        $fullPath.Equals($fullRoot, [System.StringComparison]::OrdinalIgnoreCase) -or
        $fullPath.StartsWith("$fullRoot\", [System.StringComparison]::OrdinalIgnoreCase)
    )
}

function Test-IsConfiguredSecret {
    param([AllowNull()][object]$Value)

    $text = [string]$Value
    return (
        -not [string]::IsNullOrWhiteSpace($text) -and
        $text -notmatch '(?i)PUT_|CHANGEME|_HERE$'
    )
}

function Test-InventoryConfigSet {
    param(
        [Parameter(Mandatory=$true)][string[]]$Paths,
        [string]$ExpectedSshKeyPath = ""
    )

    $merged = @{}
    foreach ($path in $Paths) {
        try {
            $config = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
        }
        catch {
            throw "Protected config is not valid JSON: $path. $($_.Exception.Message)"
        }

        foreach ($property in $config.PSObject.Properties) {
            $merged[$property.Name] = $property.Value
        }
    }

    if ($merged.ContainsKey("SnipeEnabled") -and [bool]$merged["SnipeEnabled"]) {
        foreach ($name in @("SnipeUrl", "SnipeToken")) {
            if (-not (Test-IsConfiguredSecret -Value $merged[$name])) {
                throw "Protected config property '$name' is missing or contains a placeholder."
            }
        }
    }

    foreach ($name in @("SmtpServer", "SmtpUser", "SmtpPass", "MailFrom", "MailTo")) {
        if (-not (Test-IsConfiguredSecret -Value $merged[$name])) {
            throw "Protected config property '$name' is missing or contains a placeholder."
        }
    }

    if (-not $merged.ContainsKey("InventoryRelayEnabled")) {
        throw "Protected config must explicitly define InventoryRelayEnabled for agent 1.3.3."
    }

    if ([bool]$merged["InventoryRelayEnabled"]) {
        foreach ($name in @("InventoryRelayMailTo", "InventoryRelayHmacSecret")) {
            if (-not (Test-IsConfiguredSecret -Value $merged[$name])) {
                throw "Protected config property '$name' is missing or contains a placeholder."
            }
        }
        if ([string]$merged["InventoryRelayHmacSecret"] -eq [string]$merged["SmtpPass"]) {
            throw "InventoryRelayHmacSecret must be different from SmtpPass."
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($ExpectedSshKeyPath)) {
        if (-not (Test-IsConfiguredSecret -Value $merged["SnipeSshKeyPath"])) {
            throw "Protected config property 'SnipeSshKeyPath' is missing or contains a placeholder."
        }

        try {
            $configuredKeyPath = [System.IO.Path]::GetFullPath(
                [Environment]::ExpandEnvironmentVariables([string]$merged["SnipeSshKeyPath"])
            )
            $expectedKeyPath = [System.IO.Path]::GetFullPath($ExpectedSshKeyPath)
        }
        catch {
            throw "Protected config property 'SnipeSshKeyPath' is not a valid local path."
        }

        if (-not $configuredKeyPath.Equals($expectedKeyPath, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "Protected config property 'SnipeSshKeyPath' must point to '$expectedKeyPath'."
        }
    }

    return $true
}

function Copy-InventoryConfigFiles {
    param(
        [string]$SourceRoot,
        [string]$ConfigSourcePath,
        [string]$ConfigDir,
        [string]$ExpectedSshKeyPath,
        [switch]$AllowInsecureSourceConfig
    )

    $configSources = @()

    if (-not [string]::IsNullOrWhiteSpace($ConfigSourcePath)) {
        $resolvedConfigSource = [System.IO.Path]::GetFullPath($ConfigSourcePath)
        if (-not (Test-Path -LiteralPath $resolvedConfigSource)) {
            throw "ConfigSourcePath not found: $resolvedConfigSource"
        }
        $configIsBundledWithSource = Test-IsPathInsideRoot -Path $resolvedConfigSource -Root $SourceRoot
        if (((Test-IsLikelyPublicGpoPath -Path $resolvedConfigSource) -or $configIsBundledWithSource) -and -not $AllowInsecureSourceConfig) {
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

        if ($configSources.Count -gt 0 -and -not $AllowInsecureSourceConfig) {
            throw "Secret config found in public GPO path '$SourceRoot'. Move it to a secured share readable by Domain Computers and pass -ConfigSourcePath, or use -AllowInsecureSourceConfig explicitly."
        }
    }

    if ($configSources.Count -eq 0) {
        $existingConfigPaths = @(
            "snipeit_inventory.config.json",
            "snipeit_inventory.local.json"
        ) | ForEach-Object {
            Join-Path $ConfigDir $_
        } | Where-Object {
            Test-Path -LiteralPath $_ -PathType Leaf
        }

        if ($existingConfigPaths.Count -eq 0) {
            throw "Protected inventory config was not supplied and no installed config exists in '$ConfigDir'."
        }
        Test-InventoryConfigSet -Paths $existingConfigPaths -ExpectedSshKeyPath $ExpectedSshKeyPath | Out-Null
        Write-InstallLog "Existing protected config validated."
        return $false
    }

    Test-InventoryConfigSet -Paths $configSources -ExpectedSshKeyPath $ExpectedSshKeyPath | Out-Null

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

$InstallerMutex = $null
$InstallerMutexAcquired = $false
try {
    $InstallerMutex = New-Object System.Threading.Mutex($false, "Global\SnipeITInventoryInstaller")
    try {
        $InstallerMutexAcquired = $InstallerMutex.WaitOne(0, $false)
    }
    catch [System.Threading.AbandonedMutexException] {
        $InstallerMutexAcquired = $true
    }
}
catch {
    throw "Cannot create installer mutex: $($_.Exception.Message)"
}

if (-not $InstallerMutexAcquired) {
    Write-InstallLog "Another Snipe-IT installer instance is already running. Duplicate launch skipped."
    if ($InstallerMutex) { $InstallerMutex.Dispose() }
    exit 0
}

try {
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
$installedSshKeyPath = Join-Path $ConfigDir "snipeit_ldap_sync_ed25519"
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
Set-SnipeConfigAcl -ConfigDir $ConfigDir
Write-InstallLog "Protected config ACL prepared before config copy."

$requiredFiles = @(
    "snipeit_inventory.ps1",
    "snipeit_auto.vbs",
    "snipeit_manual.cmd",
    "snipeit_dry_run.cmd",
    "install_snipeit_auto.ps1"
)

$optionalFiles = @(
    "README-GPO.txt",
    "install_snipeit_auto.vbs"
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
$ConfigChanged = Copy-InventoryConfigFiles `
    -SourceRoot $SourceRoot `
    -ConfigSourcePath $ConfigSourcePath `
    -ConfigDir $ConfigDir `
    -ExpectedSshKeyPath $installedSshKeyPath `
    -AllowInsecureSourceConfig:$AllowInsecureSourceConfig
if ($ConfigChanged) {
    $DeploymentChanged = $true
}

$resolvedSshKeySource = ""
if (-not [string]::IsNullOrWhiteSpace($SshKeySourcePath)) {
    $resolvedSshKeySource = [System.IO.Path]::GetFullPath($SshKeySourcePath)
}
elseif (-not [string]::IsNullOrWhiteSpace($ConfigSourcePath)) {
    $resolvedConfigItem = Get-Item -LiteralPath ([System.IO.Path]::GetFullPath($ConfigSourcePath)) -ErrorAction Stop
    $secureSourceDir = if ($resolvedConfigItem.PSIsContainer) {
        $resolvedConfigItem.FullName
    }
    else {
        Split-Path -Parent $resolvedConfigItem.FullName
    }
    $candidateKey = Join-Path $secureSourceDir "snipeit_ldap_sync_ed25519"
    if (Test-Path -LiteralPath $candidateKey -PathType Leaf) {
        $resolvedSshKeySource = $candidateKey
    }
}

if (-not [string]::IsNullOrWhiteSpace($resolvedSshKeySource)) {
    if (-not (Test-Path -LiteralPath $resolvedSshKeySource -PathType Leaf)) {
        throw "SshKeySourcePath not found: $resolvedSshKeySource"
    }
    if ((Test-IsPathInsideRoot -Path $resolvedSshKeySource -Root $SourceRoot) -and -not $AllowInsecureSourceConfig) {
        throw "Private SSH key must not be stored in public source '$SourceRoot'. Put it beside the protected JSON or pass -SshKeySourcePath."
    }
    if (Test-DeploymentFileChanged -Source $resolvedSshKeySource -Destination $installedSshKeyPath) {
        Copy-Item -LiteralPath $resolvedSshKeySource -Destination $installedSshKeyPath -Force
        $DeploymentChanged = $true
        $UpdatedFileCount++
        Write-InstallLog "Updated protected LDAP SSH key."
    }
    else {
        $UnchangedFileCount++
    }
}
elseif (-not (Test-Path -LiteralPath $installedSshKeyPath -PathType Leaf)) {
    throw "Protected LDAP SSH key was not supplied. Put snipeit_ldap_sync_ed25519 beside the protected JSON or pass -SshKeySourcePath."
}
Write-InstallLog "Deployment file check: updated=$UpdatedFileCount unchanged=$UnchangedFileCount"

Test-PowerShellScriptSyntax -Path (Join-Path $InstallDir "snipeit_inventory.ps1")
Write-InstallLog "PowerShell syntax OK."

Set-SnipeAutoAcl `
    -Root $InstallDir `
    -ConfigDir $ConfigDir `
    -LogsDir $LogsDir `
    -StateDir $StateDir `
    -KeyPath $installedSshKeyPath
Write-InstallLog "ACL configured and verified."

$legacyKeyCleanupCount = Remove-LegacySnipeSshKeyCopies `
    -InstallDir $InstallDir `
    -CurrentKeyPath $installedSshKeyPath
if ($legacyKeyCleanupCount -gt 0) {
    $DeploymentChanged = $true
    Write-InstallLog "Legacy LDAP SSH key cleanup completed: removed=$legacyKeyCleanupCount"
}

$LocalDeploymentRefreshNeeded = $DeploymentChanged -or $StateMissingBeforeInstall

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
    [void](Remove-LegacySnipeScheduledTask -CurrentTaskPath $TaskPath -CurrentTaskName $TaskName)
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
}
catch {
    Write-InstallLog "Install failed: $($_.Exception.Message)"
    throw
}
finally {
    $installLogPath = Join-Path $InstallDir "install.log"
    [void](Invoke-InstallLogRetention `
        -Path $installLogPath `
        -RetentionDays ([int]$InstallLogRetentionDays) `
        -MaxRuns ([int]$InstallLogRetentionRuns))
    if ($InstallerMutexAcquired -and $InstallerMutex) {
        try { $InstallerMutex.ReleaseMutex() | Out-Null } catch {}
    }
    if ($InstallerMutex) { $InstallerMutex.Dispose() }
}
