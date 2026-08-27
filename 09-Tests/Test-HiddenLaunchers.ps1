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

$sourceRoot = Split-Path -Parent $PSScriptRoot
$tempRoot = Join-Path $env:TEMP ("pcinventory-vbs-test-{0}" -f [guid]::NewGuid().ToString("N"))
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

try {
    New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $sourceRoot "snipeit_auto.vbs") -Destination $tempRoot
    Copy-Item -LiteralPath (Join-Path $sourceRoot "install_snipeit_auto.vbs") -Destination $tempRoot

    $agentStub = @'
param(
    [switch]$GpoMode,
    [switch]$DeploymentRun,
    [switch]$ForceInventory,
    [switch]$ForceEmailReport
)
if (-not ($GpoMode -and $DeploymentRun -and $ForceInventory -and $ForceEmailReport)) {
    exit 23
}
exit 0
'@
    [System.IO.File]::WriteAllText(
        (Join-Path $tempRoot "snipeit_inventory.ps1"),
        $agentStub,
        $utf8NoBom
    )

    $installerStub = @'
param(
    [string]$ConfigSourcePath,
    [string]$SshKeySourcePath
)
if ([string]::IsNullOrWhiteSpace($ConfigSourcePath) -or
    [string]::IsNullOrWhiteSpace($SshKeySourcePath)) {
    exit 24
}
exit 0
'@
    [System.IO.File]::WriteAllText(
        (Join-Path $tempRoot "install_snipeit_auto.ps1"),
        $installerStub,
        $utf8NoBom
    )

    $cscript = Join-Path $env:SystemRoot "System32\cscript.exe"
    & $cscript //nologo (Join-Path $tempRoot "snipeit_auto.vbs") `
        -DeploymentRun -ForceInventory -ForceEmailReport
    $agentExitCode = $LASTEXITCODE
    Assert-True ($agentExitCode -eq 0) "Hidden agent launcher failed with exit code $agentExitCode."

    & $cscript //nologo (Join-Path $tempRoot "install_snipeit_auto.vbs")
    $installerExitCode = $LASTEXITCODE
    Assert-True ($installerExitCode -eq 0) "Hidden installer launcher failed with exit code $installerExitCode."

    $agentLauncherText = [System.IO.File]::ReadAllText((Join-Path $sourceRoot "snipeit_auto.vbs"))
    $installerLauncherText = [System.IO.File]::ReadAllText((Join-Path $sourceRoot "install_snipeit_auto.vbs"))
    Assert-True (
        $agentLauncherText.Contains('shell.Run(command, 0, True)') -and
        $installerLauncherText.Contains('shell.Run(command, 0, True)')
    ) "A VBS launcher is not configured for a hidden window."

    [pscustomobject]@{
        Assertions          = 3
        AgentWrapperExit    = $agentExitCode
        InstallerWrapperExit = $installerExitCode
        HiddenWindowStyle   = $true
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
