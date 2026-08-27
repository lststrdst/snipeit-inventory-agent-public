#requires -version 5.1

[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

$agentPath = Join-Path (Split-Path -Parent $PSScriptRoot) "snipeit_inventory.ps1"
$null = . $agentPath -LibraryMode -DryRun
$terminatedWord = -join @([char]0x0443, [char]0x0432, [char]0x043e, [char]0x043b)

$activeDescription = Get-AdInventoryTerminationEvaluation `
    -Description $terminatedWord `
    -DistinguishedName "CN=User,OU=EXAMPLE Users,DC=example,DC=internal" `
    -UserAccountControl 512
$activeTerminatedOu = Get-AdInventoryTerminationEvaluation `
    -Description "" `
    -DistinguishedName "CN=User,OU=$terminatedWord,DC=example,DC=internal" `
    -UserAccountControl 512
$disabled = Get-AdInventoryTerminationEvaluation `
    -Description "" `
    -DistinguishedName "CN=User,OU=EXAMPLE Users,DC=example,DC=internal" `
    -UserAccountControl 514

Assert-True (-not $activeDescription.Terminated) "Description alone must not offboard an active AD account."
Assert-True $activeDescription.DescriptionMatched "Terminated description audit flag was not detected."
Assert-True (-not $activeTerminatedOu.Terminated) "OU alone must not offboard an active AD account."
Assert-True $activeTerminatedOu.OuMatched "Terminated OU audit flag was not detected."
Assert-True $disabled.Terminated "Disabled AD account was not treated as terminated."
Assert-True (
    Test-InventoryUsernameMatchesPatterns `
        -Username "transcom" `
        -Patterns $InventoryExcludedUsernamePatterns
) "Shared transcom login is not excluded."
Assert-True (
    Test-InventoryUsernameMatchesPatterns `
        -Username "ad_rdv" `
        -Patterns $InventoryStockUsernamePatterns
) "ad_* login is not treated as a stock disposition signal."

foreach ($systemIdentity in @(
    'LAPTOP-010\defaultuser0',
    'LAPTOP-010\defaultuser1',
    'LAPTOP-010\DefaultAccount',
    'LAPTOP-010\WDAGUtilityAccount',
    'LAPTOP-010\Guest',
    'LAPTOP-010\DWM-1',
    'LAPTOP-010\UMFD-2'
)) {
    Assert-True (
        -not (Test-InventoryAccountIdentifier -AccountName $systemIdentity)
    ) "System identity '$systemIdentity' can still become an inventory owner."
}

$systemOnlyUsername = Get-InventoryUsername `
    -CurrentUser 'LAPTOP-010\defaultuser0' `
    -LastUsers @(
        [pscustomobject]@{ User='LAPTOP-010\defaultuser0'; LastLogon=(Get-Date); Source='Security 4624' },
        [pscustomobject]@{ User='LAPTOP-010\Admin'; LastLogon=(Get-Date).AddMinutes(-1); Source='Security 4624' }
    )
Assert-True ([string]::IsNullOrWhiteSpace($systemOnlyUsername)) "System-only logons produced owner '$systemOnlyUsername'."

$logPath = Join-Path $env:TEMP ("pcinventory-history-{0}.log" -f ([guid]::NewGuid().ToString("N")))
try {
    $blocks = [System.Collections.Generic.List[string]]::new()
    $blocks.Add("$((Get-Date).AddDays(-40).ToString('yyyy-MM-dd HH:mm:ss')) | ==== START ====`r`nold`r`n$((Get-Date).AddDays(-40).ToString('yyyy-MM-dd HH:mm:ss')) | ==== END ====`r`n")
    foreach ($index in 1..65) {
        $stamp = (Get-Date).AddMinutes(-$index).ToString('yyyy-MM-dd HH:mm:ss')
        $blocks.Add("$stamp | ==== START ====`r`nrun=$index`r`n$stamp | ==== END ====`r`n")
    }
    [System.IO.File]::WriteAllText(
        $logPath,
        ($blocks -join ''),
        (New-Object System.Text.UTF8Encoding($true))
    )
    $removed = Invoke-InventoryHistoryLogRetention -Path $logPath -RetentionDays 30 -MaxRuns 60
    $retained = [System.IO.File]::ReadAllText($logPath)
    $retainedRuns = ([regex]::Matches($retained, '==== START ====')).Count
    Assert-True ($removed -eq 6) "Expected six old/excess log runs to be removed, got $removed."
    Assert-True ($retainedRuns -eq 60) "Expected 60 retained log runs, got $retainedRuns."
    Assert-True (-not $retained.Contains('old')) "Expired log block was retained."
}
finally {
    Remove-Item -LiteralPath $logPath -Force -ErrorAction SilentlyContinue
}

$InventoryMailQueueRetentionDays = 30
$InventoryMailQueueMaxItems = 3
$now = Get-Date
$queue = @(
    [pscustomobject]@{ id='old'; created_at=$now.AddDays(-31).ToString('o'); reason='snipeit_relay' },
    [pscustomobject]@{ id='relay1'; created_at=$now.AddMinutes(-4).ToString('o'); reason='snipeit_relay' },
    [pscustomobject]@{ id='relay2'; created_at=$now.AddMinutes(-3).ToString('o'); reason='snipeit_relay' },
    [pscustomobject]@{ id='mail1'; created_at=$now.AddMinutes(-2).ToString('o'); reason='report' },
    [pscustomobject]@{ id='mail2'; created_at=$now.AddMinutes(-1).ToString('o'); reason='report' }
)
$limited = @(Limit-PendingInventoryMailQueue -Queue $queue -Now $now)
Assert-True ($limited.Count -eq 3) "Mail queue item cap was not applied."
Assert-True (-not ($limited.id -contains 'old')) "Expired mail queue item was retained."
Assert-True (($limited.id -contains 'relay1') -and ($limited.id -contains 'relay2')) "Relay events did not receive queue priority."

[pscustomobject]@{
    Assertions              = 21
    DisabledAuthoritative   = $disabled.Terminated
    ActiveDescriptionSafe   = -not $activeDescription.Terminated
    ActiveOuSafe            = -not $activeTerminatedOu.Terminated
    TranscomExcluded        = $true
    RetainedLogRuns         = $retainedRuns
    PendingMailQueueItems   = $limited.Count
}
