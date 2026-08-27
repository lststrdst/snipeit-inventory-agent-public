#requires -version 5.1

[CmdletBinding()]
param()

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

$agentPath = Join-Path (Split-Path -Parent $PSScriptRoot) "snipeit_inventory.ps1"
$null = . $agentPath -LibraryMode

$ownerChange = Resolve-InventoryRelayEventContext `
    -RequestedDisposition "assigned" `
    -DetectedUsername "i.ivanov" `
    -PreviousEventTarget "assigned|u.user" `
    -PreviousEventGeneration 2 `
    -PreviousEventType "daily_snapshot" `
    -PreviousEventDay "2026-07-27" `
    -CurrentEventDay "2026-07-27" `
    -UserChanged $true `
    -DispositionChanged $false `
    -DeploymentRun $false `
    -PreviousAgentVersion "1.3.2" `
    -CurrentAgentVersion "1.3.2"

Assert-True ($ownerChange.EventType -eq "owner_change") "Owner change event type was not selected."
Assert-True ($ownerChange.EventGeneration -eq 3) "Owner change did not increment generation."

$sameDayReplay = Resolve-InventoryRelayEventContext `
    -RequestedDisposition "assigned" `
    -DetectedUsername "i.ivanov" `
    -PreviousEventTarget "assigned|i.ivanov" `
    -PreviousEventGeneration 3 `
    -PreviousEventType "owner_change" `
    -PreviousEventDay "2026-07-27" `
    -CurrentEventDay "2026-07-27" `
    -UserChanged $false `
    -DispositionChanged $false `
    -DeploymentRun $false `
    -PreviousAgentVersion "1.3.2" `
    -CurrentAgentVersion "1.3.2"

Assert-True ($sameDayReplay.EventType -eq "owner_change") "Same-day replay lost the significant event type."
Assert-True ($sameDayReplay.EventGeneration -eq 3) "Same-day replay changed generation."

$nextDay = Resolve-InventoryRelayEventContext `
    -RequestedDisposition "assigned" `
    -DetectedUsername "i.ivanov" `
    -PreviousEventTarget "assigned|i.ivanov" `
    -PreviousEventGeneration 3 `
    -PreviousEventType "owner_change" `
    -PreviousEventDay "2026-07-27" `
    -CurrentEventDay "2026-07-28" `
    -UserChanged $false `
    -DispositionChanged $false `
    -DeploymentRun $false `
    -PreviousAgentVersion "1.3.2" `
    -CurrentAgentVersion "1.3.2"

Assert-True ($nextDay.EventType -eq "daily_snapshot") "Next-day run did not become a daily snapshot."

$stockChange = Resolve-InventoryRelayEventContext `
    -RequestedDisposition "stock" `
    -DetectedUsername "ad_rdv" `
    -PreviousEventTarget "assigned|i.ivanov" `
    -PreviousEventGeneration 3 `
    -PreviousEventType "daily_snapshot" `
    -PreviousEventDay "2026-07-27" `
    -CurrentEventDay "2026-07-27" `
    -UserChanged $false `
    -DispositionChanged $true `
    -DeploymentRun $false `
    -PreviousAgentVersion "1.3.2" `
    -CurrentAgentVersion "1.3.2"

Assert-True ($stockChange.EventType -eq "stock_checkin") "Stock transition event type was not selected."
Assert-True ($stockChange.EventGeneration -eq 4) "Stock transition did not increment generation."
Assert-True ($stockChange.EventTarget -eq "stock|") "Stock event retained a username."

$preserveIdentity = Resolve-InventoryRelayEventContext `
    -RequestedDisposition "preserve" `
    -DetectedUsername "S-1-5-21-695948987-2019328260-3510634645-2110" `
    -PreviousEventTarget "assigned|m.example" `
    -PreviousEventGeneration 4 `
    -PreviousEventType "daily_snapshot" `
    -PreviousEventDay "2026-08-12" `
    -CurrentEventDay "2026-08-12" `
    -UserChanged $false `
    -DispositionChanged $true `
    -DeploymentRun $false `
    -PreviousAgentVersion "1.3.3" `
    -CurrentAgentVersion "1.3.3"

Assert-True ($preserveIdentity.EventTarget -eq "preserve|") "Preserve event retained an invalid identity."
Assert-True ($preserveIdentity.EventType -ne "owner_change") "Preserve event was classified as owner change."
Assert-True (-not (Test-InventoryAccountIdentifier -AccountName "S-1-5-21-1-2-3-1001")) "SID was accepted as a username."
Assert-True (-not (Test-InventoryAccountIdentifier -AccountName "EXAMPLE\LAPTOP-001$")) "Machine account was accepted as a username."
Assert-True (-not (Test-InventoryAccountIdentifier -AccountName "NT AUTHORITY\SYSTEM")) "SYSTEM was accepted as a username."
Assert-True (Test-InventoryAccountIdentifier -AccountName "EXAMPLE\m.example") "A valid domain username was rejected."
Assert-True ([string]::IsNullOrWhiteSpace((Resolve-InventoryUsernameLocally -Username "S-1-5-21-1-2-3-1001" -State $null))) "SID survived local username resolution."

$agentUpgrade = Resolve-InventoryRelayEventContext `
    -RequestedDisposition "assigned" `
    -DetectedUsername "i.ivanov" `
    -PreviousEventTarget "assigned|i.ivanov" `
    -PreviousEventGeneration 4 `
    -PreviousEventType "daily_snapshot" `
    -PreviousEventDay "2026-07-29" `
    -CurrentEventDay "2026-07-29" `
    -UserChanged $false `
    -DispositionChanged $false `
    -DeploymentRun $true `
    -PreviousAgentVersion "1.3.1" `
    -CurrentAgentVersion "1.3.2"

Assert-True ($agentUpgrade.EventType -eq "install_update") "Agent upgrade was not classified as install_update."
Assert-True ($agentUpgrade.EventGeneration -eq 4) "Agent upgrade changed assignment generation."

$legacyAdCandidates = @(
    Get-LegacyInventoryUsernameCandidates -Usernames @(
        "EXAMPLE\LegacyUserK",
        "LegacyUserK",
        "EXAMPLE\k.exampleuser"
    )
)
Assert-True ($legacyAdCandidates.Count -eq 1) "Legacy AD fallback produced duplicate or unexpected candidates."
Assert-True ($legacyAdCandidates[0] -eq "k.exampleuser") "Legacy AD fallback did not convert surname+initial format."

$displayTimestamp = Format-InventoryDisplayTimestamp -Timestamp "2026-07-27T16:54:38.1950637+03:00"
Assert-True ($displayTimestamp -eq "16:54 27.07.2026") "Snipe timestamp was not formatted as one compact human-readable line."
Assert-True (
    $displayTimestamp -notmatch "T\d{2}:" -and
    $displayTimestamp -notmatch "[+-]\d{2}:\d{2}$" -and
    $displayTimestamp -notmatch ":\d{2}\.\d+"
) "Snipe timestamp still contains ISO noise."

$notesTimestamp = Format-InventoryNotesTimestamp -Timestamp "2026-07-27T16:54:38.1950637+03:00"
Assert-True ($notesTimestamp -eq "27.07.2026 16:54:38") "Asset notes timestamp was not formatted for humans."

$osSummary = Get-OsInventorySummary `
    -OSName "?????????? Windows 11 Pro ??? ??????? ????????" `
    -OSBuild "26200"
Assert-True ($osSummary -eq "Windows 11 Pro (build 26200)") "Localized OS caption was not normalized."

$assetNotes = Get-SnipeAssetNotes `
    -ComputerName "LAPTOP-001" `
    -SerialNumber "SERIAL-001" `
    -Manufacturer "LENOVO" `
    -Model "21DH" `
    -CpuName "CPU" `
    -CpuCores 12 `
    -CpuThreads 16 `
    -RamGB 16 `
    -RamLayout "2 x 8 GB" `
    -OSName $osSummary `
    -OSVersion "10.0.26200" `
    -OSBuild "26200" `
    -LastBoot ([datetime]"2026-07-28T12:12:45") `
    -DetectedUsername "o.kokoreva" `
    -ReportDate "fallback" `
    -InventoryTimestamp "2026-07-27T16:54:38.1950637+03:00"
Assert-True ($assetNotes -match 'Updated: 27\.07\.2026 16:54:38') "Asset notes contain a non-human timestamp."
Assert-True ($assetNotes -match 'OS: Windows 11 Pro \(build 26200\)') "Asset notes contain a localized OS caption."
Assert-True ($assetNotes -match 'Last boot: 28\.07\.2026 12:12:45') "Asset notes contain a non-human last boot timestamp."
Assert-True ($assetNotes -notmatch '\?{2,}|T16:54:38|\+03:00') "Asset notes still contain broken text or ISO noise."
Assert-True ($assetNotes -match '^Auto inventory by SnipeIT Inventory Agent') "Asset notes still use a legacy product name."
Assert-True ($InventoryRelaySubjectPrefix -eq '[SNIPEIT-INVENTORY] RELAY:') "Relay subject prefix is not canonical."

$newAssetFunction = (Get-Command New-SnipeAsset -CommandType Function).Definition
$updateAssetFunction = (Get-Command Update-SnipeAsset -CommandType Function).Definition
Assert-True ($newAssetFunction -notmatch '(?m)^\s*asset_tag\s*=') "Asset creation still writes asset_tag."
Assert-True ($updateAssetFunction -notmatch '(?m)^\s*asset_tag\s*=') "Asset update still writes asset_tag."

$basePayloadArgs = @{
    ComputerName             = "LAPTOP-045"
    Domain                   = "ad.example.internal"
    SerialNumber             = "SERIAL-045"
    RawDetectedUsername      = "i.ivanov"
    DetectedUsername         = "i.ivanov"
    RequestedDisposition     = "assigned"
    DispositionReason        = "user_checkout"
    EventType                = "owner_change"
    EventGeneration          = 3
    ConsecutiveFailureCount  = 10
    ReportDate               = "2026-07-27 10:00:00 +03:00"
}

$payloadA = New-SnipeRelayPayload @basePayloadArgs `
    -Manufacturer "Lenovo" `
    -Model "Model A" `
    -CpuName "CPU A" `
    -RamGB 16 `
    -ObservedAt "2026-07-27T10:00:00+03:00"

$payloadB = New-SnipeRelayPayload @basePayloadArgs `
    -Manufacturer "Lenovo" `
    -Model "Model B" `
    -CpuName "CPU B" `
    -RamGB 32 `
    -ObservedAt "2026-07-27T18:00:00+03:00"

$payloadNextDay = New-SnipeRelayPayload @basePayloadArgs `
    -Manufacturer "Lenovo" `
    -Model "Model B" `
    -CpuName "CPU B" `
    -RamGB 32 `
    -ObservedAt "2026-07-28T10:00:00+03:00"

Assert-True ($payloadA.event_id -eq $payloadB.event_id) "Mutable report details changed the event ID."
Assert-True ($payloadA.event_id -ne $payloadNextDay.event_id) "A new day did not create a new event ID."
Assert-True (
    -not (Test-InventoryErrorRequiresHumanMail `
        -InventoryHadError $true `
        -RelayAcceptedForDelivery $true)
) "Accepted relay still requested a human error email."
Assert-True (
    Test-InventoryErrorRequiresHumanMail `
        -InventoryHadError $true `
        -RelayAcceptedForDelivery $false
) "Unrelayed inventory error did not request a human error email."
Assert-True (
    -not (Test-InventoryErrorRequiresHumanMail `
        -InventoryHadError $false `
        -RelayAcceptedForDelivery $false)
) "Successful inventory requested a human error email."

$legacyDnsError = [pscustomobject]@{
    id              = "legacy-dns"
    reason          = "error"
    subject         = "PC Inventory ERROR: LAPTOP-077"
    attachment_text = "curl.exe exited with code 6. Could not resolve host: snipeit.example.internal"
}
$legacyForcedDnsError = [pscustomobject]@{
    id              = "legacy-forced-dns"
    reason          = "force_email, error"
    subject         = "PC Inventory FORCED: LAPTOP-077"
    attachment_text = "CURL_HTTP_STATUS:000; Could not resolve host"
}
$agentError = [pscustomobject]@{
    id              = "agent-error"
    reason          = "agent_error"
    subject         = "PC Inventory AGENT ERROR"
    attachment_text = "Could not resolve host while loading an unrelated dependency"
}
$semanticError = [pscustomobject]@{
    id              = "semantic-error"
    reason          = "error"
    subject         = "PC Inventory ERROR"
    attachment_text = "User was not found in Snipe-IT after LDAP sync"
}
$relayEntry = [pscustomobject]@{
    id              = "relay-event"
    reason          = "snipeit_relay"
    subject         = "[SNIPEIT-RELAY] LAPTOP-077"
    attachment_text = "Could not resolve host"
}
Assert-True (
    Test-IsLegacySnipeTransportErrorMail -Entry $legacyDnsError
) "Legacy DNS error was not selected for migration."
Assert-True (
    Test-IsLegacySnipeTransportErrorMail -Entry $legacyForcedDnsError
) "Legacy forced DNS error was not selected for migration."
Assert-True (
    -not (Test-IsLegacySnipeTransportErrorMail -Entry $agentError)
) "Agent error was incorrectly selected for migration."
Assert-True (
    -not (Test-IsLegacySnipeTransportErrorMail -Entry $semanticError)
) "Semantic Snipe error was incorrectly selected for migration."
$migratedQueue = @(Remove-LegacySnipeTransportErrorMails -Queue @(
    $legacyDnsError,
    $legacyForcedDnsError,
    $agentError,
    $semanticError,
    $relayEntry
))
Assert-True ($migratedQueue.Count -eq 3) "Legacy transport queue migration removed the wrong number of entries."
Assert-True (
    @($migratedQueue.id) -contains "agent-error" -and
    @($migratedQueue.id) -contains "semantic-error" -and
    @($migratedQueue.id) -contains "relay-event"
) "Legacy transport queue migration removed a protected event."

[pscustomobject]@{
    Assertions       = 34
    OwnerGeneration  = $ownerChange.EventGeneration
    StockGeneration  = $stockChange.EventGeneration
    LegacyAdFallback = $legacyAdCandidates[0]
    StableEventId    = ($payloadA.event_id -eq $payloadB.event_id)
    NextDayEventId   = ($payloadA.event_id -ne $payloadNextDay.event_id)
    RelaySuppressesHumanError = $true
    LegacyTransportMailMigration = $true
}
