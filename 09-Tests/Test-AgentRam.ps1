#requires -version 5.1

$ErrorActionPreference = "Stop"

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

$agentPath = Join-Path (Split-Path -Parent $PSScriptRoot) "snipeit_inventory.ps1"
$null = . $agentPath -LibraryMode

$mixedSpeedModules = @(
    [pscustomobject]@{
        Capacity = 8GB; Manufacturer = "Micron Technology"; PartNumber = "LPDDR5-TEST"
        SMBIOSMemoryType = 35; FormFactor = 14; DeviceLocator = "Onboard"
        BankLabel = "BANK 0"; ConfiguredClockSpeed = 5200; Speed = 6400
    },
    [pscustomobject]@{
        Capacity = 8GB; Manufacturer = "Micron Technology"; PartNumber = "LPDDR5-TEST"
        SMBIOSMemoryType = 35; FormFactor = 14; DeviceLocator = "Onboard"
        BankLabel = "BANK 1"; ConfiguredClockSpeed = 5200; Speed = 6400
    }
)
$mixed = Get-RamInventoryDetails -RamModules $mixedSpeedModules -RamGB 16 -FallbackSlotCount 8
Assert-True ($mixed.Summary -match 'configured 5200 MT/s; module 6400 MT/s') "Direct SMBIOS rates were not preserved."
Assert-True ($mixed.Summary -notmatch 'MHz|2600|3200') "A derived memory clock is still displayed."
Assert-True ($mixed.Layout -eq 'Onboard/soldered; no user-replaceable DIMM/SODIMM slots') "Onboard memory was reported as physical slots."
Assert-True ($mixed.ModuleDetails -match 'PN=LPDDR5-TEST') "SMBIOS part number is missing from module details."

$socketedModules = @(
    [pscustomobject]@{
        Capacity = 16GB; Manufacturer = "Samsung"; PartNumber = "DDR5-5600-A"
        SMBIOSMemoryType = 34; FormFactor = 12; DeviceLocator = "ChannelA-DIMM0"
        BankLabel = "BANK 0"; ConfiguredClockSpeed = 5600; Speed = 5600
    },
    [pscustomobject]@{
        Capacity = 16GB; Manufacturer = "Micron"; PartNumber = "DDR5-5600-B"
        SMBIOSMemoryType = 34; FormFactor = 12; DeviceLocator = "ChannelB-DIMM0"
        BankLabel = "BANK 1"; ConfiguredClockSpeed = 5600; Speed = 5600
    }
)
$socketed = Get-RamInventoryDetails -RamModules $socketedModules -RamGB 32 -FallbackSlotCount 2
Assert-True ($socketed.Summary -match '5600 MT/s') "Configured SMBIOS rate is missing."
Assert-True ($socketed.Summary -notmatch 'MHz|2800') "DDR5 data rate was incorrectly divided by two."
Assert-True ($socketed.Layout -eq '2 x 16 GB; 2/2 SODIMM slots used') "Socketed layout is incorrect."
Assert-True ($socketed.ModuleDetails -match 'slot=ChannelA-DIMM0/BANK 0') "SMBIOS module locator is missing."

$liveModules = @(Get-CimInstance Win32_PhysicalMemory -ErrorAction Stop)
$liveArrayCount = (Get-CimInstance Win32_PhysicalMemoryArray -ErrorAction SilentlyContinue |
    Measure-Object -Property MemoryDevices -Sum).Sum
$liveRamGB = [math]::Round((($liveModules | Measure-Object Capacity -Sum).Sum / 1GB), 2)
$live = Get-RamInventoryDetails -RamModules $liveModules -RamGB $liveRamGB -FallbackSlotCount $liveArrayCount
Assert-True ($live.Summary -notmatch 'MHz clock') "Live RAM summary still contains a derived clock."

[pscustomobject]@{
    Assertions = 9
    SyntheticMixedSpeed = $mixed.Summary
    SyntheticSocketed = $socketed.Summary
    LiveComputer = $env:COMPUTERNAME
    LiveSummary = $live.Summary
    LiveLayout = $live.Layout
    LiveModules = $live.ModuleDetails
}
