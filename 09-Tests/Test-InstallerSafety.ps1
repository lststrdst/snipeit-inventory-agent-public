#requires -version 5.1

[CmdletBinding()]
param(
    [string]$ProtectedConfigPath = ""
)

$ErrorActionPreference = "Stop"

function Assert-True {
    param(
        [bool]$Condition,
        [string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

$installerPath = Join-Path (Split-Path -Parent $PSScriptRoot) "install_snipeit_auto.ps1"
$bootstrapPath = Join-Path (Split-Path -Parent $PSScriptRoot) "install_snipeit_auto.vbs"
$agentPath = Join-Path (Split-Path -Parent $PSScriptRoot) "snipeit_inventory.ps1"
$agentLauncherPath = Join-Path (Split-Path -Parent $PSScriptRoot) "snipeit_auto.vbs"
$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile(
    $installerPath,
    [ref]$tokens,
    [ref]$parseErrors
)
if ($parseErrors.Count -gt 0) {
    throw "Installer parser failed: $($parseErrors.Message -join ' | ')"
}

$requiredFunctions = @(
    "Invoke-InstallLogRetention",
    "Invoke-IcaclsChecked",
    "Set-SnipeExactAcl",
    "Set-SnipeConfigAcl",
    "Remove-LegacySnipeSshKeyCopies",
    "Test-IsConfiguredSecret",
    "Test-IsPathInsideRoot",
    "Test-InventoryConfigSet"
)
$functionAsts = @($ast.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
    $requiredFunctions -contains $node.Name
}, $true))

Assert-True ($functionAsts.Count -eq $requiredFunctions.Count) "Installer safety functions were not found."
foreach ($functionAst in $functionAsts) {
    Invoke-Expression $functionAst.Extent.Text
}

$testPath = Join-Path $env:TEMP ("pcinventory-installer-config-{0}.json" -f ([guid]::NewGuid().ToString("N")))
$aclTestPath = Join-Path $env:TEMP ("pcinventory-installer-acl-{0}.txt" -f ([guid]::NewGuid().ToString("N")))
$installLogTestPath = Join-Path $env:TEMP ("pcinventory-install-log-{0}.log" -f ([guid]::NewGuid().ToString("N")))
$validConfig = [ordered]@{
    SnipeEnabled               = $true
    SnipeUrl                   = "https://snipeit.example.test"
    SnipeToken                 = "unit-test-api-token"
    SmtpServer                 = "smtp.example.test"
    SmtpUser                   = "inventory@example.test"
    SmtpPass                   = "unit-test-smtp-password"
    MailFrom                   = "inventory@example.test"
    MailTo                     = "it@example.test"
    InventoryRelayEnabled      = $true
    InventoryRelayMailTo       = "it@example.test"
    InventoryRelayHmacSecret   = "unit-test-dedicated-hmac"
    SnipeSshKeyPath            = "C:\ProgramData\snipeit_auto\Config\snipeit_ldap_sync_ed25519"
}

try {
    $oldStamp = (Get-Date).AddDays(-40).ToString('yyyy-MM-dd HH:mm:ss')
    $newStamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    [System.IO.File]::WriteAllText(
        $installLogTestPath,
        "$oldStamp | Install started.`r`nold`r`n$newStamp | Install started.`r`nnew`r`n",
        (New-Object System.Text.UTF8Encoding($true))
    )
    $installLogRemoved = Invoke-InstallLogRetention -Path $installLogTestPath -RetentionDays 30 -MaxRuns 60
    $installLogRetained = [System.IO.File]::ReadAllText($installLogTestPath)
    Assert-True ($installLogRemoved -eq 1) "Expired installer log run was not removed."
    Assert-True (-not $installLogRetained.Contains('old')) "Expired installer log text remains."

    "acl smoke test" | Set-Content -LiteralPath $aclTestPath -Encoding ASCII
    Invoke-IcaclsChecked -Arguments @($aclTestPath, "/verify") -Description "ACL smoke test"

    $aclFailureDetected = $false
    try {
        Invoke-IcaclsChecked `
            -Arguments @("$aclTestPath.missing", "/verify") `
            -Description "expected missing file"
    }
    catch {
        $aclFailureDetected = $true
    }
    Assert-True $aclFailureDetected "A failing icacls command was not rejected."

    $validConfig | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $testPath -Encoding UTF8
    Assert-True (Test-InventoryConfigSet -Paths @($testPath)) "Valid protected config was rejected."

    $validConfig.Remove("InventoryRelayEnabled")
    $validConfig | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $testPath -Encoding UTF8
    $missingRelayFlagRejected = $false
    try {
        Test-InventoryConfigSet -Paths @($testPath) | Out-Null
    }
    catch {
        $missingRelayFlagRejected = $true
    }
    Assert-True $missingRelayFlagRejected "Legacy config without InventoryRelayEnabled was accepted."
    $validConfig["InventoryRelayEnabled"] = $true

    $validConfig.SnipeToken = "PUT_SNIPEIT_API_TOKEN_HERE"
    $validConfig | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $testPath -Encoding UTF8
    $placeholderRejected = $false
    try {
        Test-InventoryConfigSet -Paths @($testPath) | Out-Null
    }
    catch {
        $placeholderRejected = $true
    }
    Assert-True $placeholderRejected "Placeholder API token was accepted."

    $validConfig.SnipeToken = "unit-test-api-token"
    $validConfig.InventoryRelayHmacSecret = $validConfig.SmtpPass
    $validConfig | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $testPath -Encoding UTF8
    $sharedSecretRejected = $false
    try {
        Test-InventoryConfigSet -Paths @($testPath) | Out-Null
    }
    catch {
        $sharedSecretRejected = $true
    }
    Assert-True $sharedSecretRejected "SMTP password was accepted as the relay HMAC secret."
    $validConfig.InventoryRelayHmacSecret = "unit-test-dedicated-hmac"

    $validConfig.SnipeSshKeyPath = "C:\ProgramData\snipeit_auto\snipeit_ldap_sync_ed25519"
    $validConfig | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $testPath -Encoding UTF8
    $legacyKeyPathRejected = $false
    try {
        Test-InventoryConfigSet `
            -Paths @($testPath) `
            -ExpectedSshKeyPath "C:\ProgramData\snipeit_auto\Config\snipeit_ldap_sync_ed25519" | Out-Null
    }
    catch {
        $legacyKeyPathRejected = $true
    }
    Assert-True $legacyKeyPathRejected "Legacy ProgramData-root SSH key path was accepted."
    $validConfig.SnipeSshKeyPath = "C:\ProgramData\snipeit_auto\Config\snipeit_ldap_sync_ed25519"

    Assert-True (
        Test-IsPathInsideRoot `
            -Path "\\AD-SERVER\snipeit_auto$\snipeit_inventory.local.json" `
            -Root "\\AD-SERVER\snipeit_auto$"
    ) "Bundled public-share config was not detected."
    Assert-True (
        -not (Test-IsPathInsideRoot `
            -Path "\\AD-SERVER\snipeit_auto_secure$\snipeit_inventory.local.json" `
            -Root "\\AD-SERVER\snipeit_auto$")
    ) "Separate secure-share config was incorrectly classified as bundled."

    $installerText = [System.IO.File]::ReadAllText($installerPath)
    Assert-True (
        $installerText.Contains('Set-SnipeConfigAcl -ConfigDir $ConfigDir')
    ) "Protected config ACL is not checked before config copy."
    Assert-True (
        $installerText.Contains('$acl.SetAccessRuleProtection($true, $false)') -and
        $installerText.Contains('$acl.RemoveAccessRuleSpecific($rule)')
    ) "Exact ACL replacement is not implemented."
    Assert-True (
        $installerText.Contains('"/setowner", "*S-1-5-32-544"')
    ) "Protected paths are not reassigned to the local Administrators owner."
    Assert-True (
        $installerText.Contains('Write-InstallLog "ACL configured and verified."') -and
        -not $installerText.Contains('ACL unchanged; refresh skipped.')
    ) "ACL repair is not enforced on every installer run."
    Assert-True (
        $installerText.Contains('-AllowAuthenticatedUsersRead') -and
        $installerText.Contains('Set-SnipeExactAcl -Path $KeyPath')
    ) "Public read-only and secret-only ACL paths are not separated."
    Assert-True (
        $installerText.Contains('Global\SnipeITInventoryInstaller') -and
        $installerText.Contains('Duplicate launch skipped')
    ) "Installer global mutex protection is missing."
    Assert-True (
        $installerText.Contains('Protected LDAP SSH key was not supplied') -and
        $installerText.Contains('$secureSourceDir')
    ) "Private SSH key is not sourced from the protected location."
    Assert-True (
        $installerText.Contains('$installedSshKeyPath = Join-Path $ConfigDir "snipeit_ldap_sync_ed25519"') -and
        -not $installerText.Contains('$installedSshKeyPath = Join-Path $InstallDir "snipeit_ldap_sync_ed25519"')
    ) "Private SSH key is not installed inside the protected Config directory."
    $aclVerifiedIndex = $installerText.IndexOf('Write-InstallLog "ACL configured and verified."', [System.StringComparison]::Ordinal)
    $legacyCleanupIndex = $installerText.IndexOf('$legacyKeyCleanupCount = Remove-LegacySnipeSshKeyCopies', [System.StringComparison]::Ordinal)
    Assert-True (
        $aclVerifiedIndex -ge 0 -and $legacyCleanupIndex -gt $aclVerifiedIndex
    ) "Legacy key copies may be removed before the protected replacement and ACL are verified."
    Assert-True (
        $installerText.Contains('Get-CimInstance Win32_UserProfile') -and
        $installerText.Contains('AppData\Local\snipeit_auto\snipeit_ldap_sync_ed25519')
    ) "Installer does not clean legacy private-key copies from local profiles."
    Assert-True (Test-Path -LiteralPath $bootstrapPath -PathType Leaf) "Hidden GPO bootstrap is missing."
    $bootstrapText = [System.IO.File]::ReadAllText($bootstrapPath)
    Assert-True (
        $bootstrapText.Contains('shell.Run(command, 0, True)') -and
        $bootstrapText.Contains('snipeit_auto_secure$')
    ) "GPO bootstrap is not hidden or does not use the secure share."
    Assert-True (Test-Path -LiteralPath $agentLauncherPath -PathType Leaf) "Hidden agent launcher is missing."
    $agentLauncherText = [System.IO.File]::ReadAllText($agentLauncherPath)
    Assert-True (
        $installerText.Contains('Start-Process -FilePath $wscript') -and
        -not $installerText.Contains('Start-Process -FilePath "powershell.exe"') -and
        $agentLauncherText.Contains('shell.Run(command, 0, True)')
    ) "Initial inventory can still open an interactive PowerShell window."
    Assert-True (
        -not (Test-Path -LiteralPath (Join-Path (Split-Path -Parent $PSScriptRoot) 'snipeit_ldap_sync_ed25519'))
    ) "Private SSH key leaked into the public package source."
    Assert-True (
        -not (Test-Path -LiteralPath (Join-Path (Split-Path -Parent $PSScriptRoot) 'snipeit_ldap_sync_ed25519.pub'))
    ) "SSH key material remains in the public package source."

    $agentText = [System.IO.File]::ReadAllText($agentPath)
    Assert-True (
        $agentText.Contains('C:\ProgramData\snipeit_auto\Config\snipeit_ldap_sync_ed25519') -and
        -not $agentText.Contains('(Join-Path $PSScriptRoot "snipeit_ldap_sync_ed25519")') -and
        -not $agentText.Contains('Copy-Item -LiteralPath $sourceKey -Destination $localUserKey')
    ) "Agent still falls back to or duplicates the private SSH key outside Config."

    $protectedConfigValidated = $false
    if (-not [string]::IsNullOrWhiteSpace($ProtectedConfigPath)) {
        $resolvedProtectedConfig = (Resolve-Path -LiteralPath $ProtectedConfigPath).Path
        Assert-True (
            Test-InventoryConfigSet `
                -Paths @($resolvedProtectedConfig) `
                -ExpectedSshKeyPath (Join-Path $env:ProgramData 'snipeit_auto\Config\snipeit_ldap_sync_ed25519')
        ) "Release protected config was rejected."
        $protectedConfigValidated = $true
    }

    [pscustomobject]@{
        Assertions             = $(if ($protectedConfigValidated) { 30 } else { 29 })
        ValidConfigAccepted    = $true
        MissingRelayRejected   = $missingRelayFlagRejected
        PlaceholderRejected    = $placeholderRejected
        SharedSecretRejected   = $sharedSecretRejected
        CheckedAclCallsPresent = $true
        IcalcsFailureDetected  = $aclFailureDetected
        ExactAclReplacement    = $true
        SecretOwnerProtected   = $true
        AclRepairAlwaysRuns    = $true
        InstallerMutexPresent  = $true
        HiddenBootstrapPresent = $true
        PrivateKeySeparated    = $true
        PrivateKeyMigrated     = $true
        LegacyKeyPathRejected  = $legacyKeyPathRejected
        InitialRunHidden       = $true
        InstallLogRetention    = $true
        ReleaseConfigValidated = $protectedConfigValidated
    }
}
finally {
    if (Test-Path -LiteralPath $testPath) {
        Remove-Item -LiteralPath $testPath -Force
    }
    if (Test-Path -LiteralPath $aclTestPath) {
        Remove-Item -LiteralPath $aclTestPath -Force
    }
    if (Test-Path -LiteralPath $installLogTestPath) {
        Remove-Item -LiteralPath $installLogTestPath -Force
    }
}
