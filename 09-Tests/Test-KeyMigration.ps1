#requires -version 5.1

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

function Write-InstallLog {
    param([string]$Message)
}

$installerPath = Join-Path (Split-Path -Parent $PSScriptRoot) "install_snipeit_auto.ps1"
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

$migrationAst = $ast.Find({
    param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
    $node.Name -eq "Remove-LegacySnipeSshKeyCopies"
}, $true)
Assert-True ($null -ne $migrationAst) "Key migration function was not found."
Invoke-Expression $migrationAst.Extent.Text

$tempRoot = Join-Path $env:TEMP ("pcinventory-key-migration-{0}" -f [guid]::NewGuid().ToString("N"))
$installDir = Join-Path $tempRoot "ProgramData\snipeit_auto"
$configDir = Join-Path $installDir "Config"
$localAppData = Join-Path $tempRoot "Users\test\AppData\Local"
$currentKey = Join-Path $configDir "snipeit_ldap_sync_ed25519"
$legacyRootKey = Join-Path $installDir "snipeit_ldap_sync_ed25519"
$legacyPublicKey = Join-Path $installDir "snipeit_ldap_sync_ed25519.pub"
$legacyProfileKey = Join-Path $localAppData "snipeit_auto\snipeit_ldap_sync_ed25519"

try {
    foreach ($directory in @($configDir, (Split-Path -Parent $legacyProfileKey))) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }
    foreach ($path in @($currentKey, $legacyRootKey, $legacyPublicKey, $legacyProfileKey)) {
        [System.IO.File]::WriteAllText($path, "test-key")
    }

    $removed = Remove-LegacySnipeSshKeyCopies `
        -InstallDir $installDir `
        -CurrentKeyPath $currentKey `
        -LegacyLocalAppDataRoots @($localAppData) `
        -SkipProfileDiscovery

    Assert-True ($removed -eq 3) "Expected three legacy key artifacts to be removed; got $removed."
    Assert-True (Test-Path -LiteralPath $currentKey -PathType Leaf) "Protected replacement key was removed."
    Assert-True (-not (Test-Path -LiteralPath $legacyRootKey)) "Legacy ProgramData-root private key remains."
    Assert-True (-not (Test-Path -LiteralPath $legacyPublicKey)) "Legacy ProgramData-root public key remains."
    Assert-True (-not (Test-Path -LiteralPath $legacyProfileKey)) "Legacy profile private key remains."

    Remove-Item -LiteralPath $currentKey -Force
    [System.IO.File]::WriteAllText($legacyRootKey, "test-key")
    $missingReplacementRejected = $false
    try {
        Remove-LegacySnipeSshKeyCopies `
            -InstallDir $installDir `
            -CurrentKeyPath $currentKey `
            -SkipProfileDiscovery | Out-Null
    }
    catch {
        $missingReplacementRejected = $true
    }
    Assert-True (
        $missingReplacementRejected -and (Test-Path -LiteralPath $legacyRootKey)
    ) "Legacy key was removed without a protected replacement."

    [pscustomobject]@{
        Assertions                = 6
        RemovedLegacyArtifacts    = $removed
        ProtectedKeyPreserved     = $true
        MissingReplacementBlocked = $missingReplacementRejected
    }
}
finally {
    if (Test-Path -LiteralPath $tempRoot) {
        $resolvedTempRoot = [System.IO.Path]::GetFullPath($tempRoot)
        $resolvedTempBase = [System.IO.Path]::GetFullPath($env:TEMP).TrimEnd('\') + '\'
        if ($resolvedTempRoot.StartsWith($resolvedTempBase, [System.StringComparison]::OrdinalIgnoreCase)) {
            Remove-Item -LiteralPath $resolvedTempRoot -Recurse -Force
        }
    }
}
