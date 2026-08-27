#requires -version 5.1

[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

$agentPath = Join-Path (Split-Path -Parent $PSScriptRoot) "snipeit_inventory.ps1"
$null = . $agentPath -LibraryMode -DryRun

$testPath = Join-Path $env:TEMP ("pcinventory-state-{0}.json" -f ([guid]::NewGuid().ToString("N")))
$state = [ordered]@{
    detected_username = "test.user"
    marker            = "unchanged"
}

try {
    $dryResult = Save-InventoryStateSnapshot `
        -Path $testPath `
        -State $state `
        -PendingMails @([pscustomobject]@{ event_key = "test" })

    $dryRunPassed = (
        $dryResult -eq $true -and
        -not (Test-Path -LiteralPath $testPath) -and
        -not $state.Contains("schema_version") -and
        $state.marker -eq "unchanged"
    )

    $DryRun = $false
    $saveResult = Save-InventoryStateSnapshot -Path $testPath -State $state -PendingMails @()
    $savedState = Get-Content -LiteralPath $testPath -Raw | ConvertFrom-Json
    $normalSavePassed = (
        $saveResult -eq $true -and
        $savedState.schema_version -eq 3 -and
        $savedState.agent_version -eq "1.3.3"
    )

    [pscustomobject]@{
        DryRunStateIsolation = $dryRunPassed
        NormalStateSave      = $normalSavePassed
        Version              = $savedState.agent_version
        Schema               = $savedState.schema_version
    }

    if (-not ($dryRunPassed -and $normalSavePassed)) {
        throw "Agent state smoke test failed."
    }
}
finally {
    if (Test-Path -LiteralPath $testPath) {
        Remove-Item -LiteralPath $testPath -Force
    }
}
