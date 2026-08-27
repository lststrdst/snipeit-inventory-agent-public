#requires -version 5.1

[CmdletBinding()]
param(
    [string]$PythonPath = "",
    [switch]$SkipPython
)

$ErrorActionPreference = "Stop"
$packageRoot = Split-Path -Parent $PSScriptRoot
$agentRoot = Join-Path $packageRoot "01-Agent-PUBLIC"
$protectedConfig = Join-Path $packageRoot "02-Agent-SECURE\snipeit_inventory.local.json"
$relayRoot = Join-Path $packageRoot "03-Relay-PUBLIC"
$maintenanceRoot = Join-Path $packageRoot "05-Maintenance-PUBLIC"
$stageRoot = Join-Path $env:TEMP ("SnipeIT-Inventory-tests-{0}" -f [guid]::NewGuid().ToString("N"))
$stageTests = Join-Path $stageRoot "tests"

function Invoke-Checked {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [Parameter(Mandatory = $true)][string]$Description
    )

    Write-Host "`n=== $Description ===" -ForegroundColor Cyan
    & $FilePath @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "$Description failed with exit code $LASTEXITCODE."
    }
}

try {
    Write-Host "Validating package syntax..." -ForegroundColor Cyan
    foreach ($file in Get-ChildItem -LiteralPath $packageRoot -Recurse -File -Filter "*.ps1") {
        $tokens = $null
        $errors = $null
        [void][Management.Automation.Language.Parser]::ParseFile(
            $file.FullName,
            [ref]$tokens,
            [ref]$errors
        )
        if ($errors.Count -gt 0) {
            throw "PowerShell parse failed for '$($file.FullName)': $($errors.Message -join ' | ')"
        }
    }

    foreach ($file in Get-ChildItem -LiteralPath $packageRoot -Recurse -File -Filter "*.json") {
        Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8 | ConvertFrom-Json | Out-Null
    }

    New-Item -ItemType Directory -Path $stageTests -Force | Out-Null
    Copy-Item -Path (Join-Path $agentRoot "*") -Destination $stageRoot -Recurse -Force
    Get-ChildItem -LiteralPath $PSScriptRoot -File -Filter "Test-*.ps1" | ForEach-Object {
        Copy-Item -LiteralPath $_.FullName -Destination $stageTests -Force
    }

    foreach ($test in Get-ChildItem -LiteralPath $stageTests -File -Filter "Test-*.ps1" | Sort-Object Name) {
        $arguments = @(
            "-NoProfile",
            "-ExecutionPolicy", "Bypass",
            "-File", $test.FullName
        )
        if ($test.Name -eq "Test-InstallerSafety.ps1") {
            $arguments += @("-ProtectedConfigPath", $protectedConfig)
        }
        Invoke-Checked -FilePath "powershell.exe" -Arguments $arguments -Description $test.Name
    }

    if (-not $SkipPython) {
        if ([string]::IsNullOrWhiteSpace($PythonPath)) {
            $command = Get-Command "python.exe" -ErrorAction SilentlyContinue
            if ($null -eq $command) {
                throw "Python was not found. Pass -PythonPath or use -SkipPython."
            }
            $PythonPath = $command.Source
        }

        Push-Location $relayRoot
        try {
            Invoke-Checked -FilePath $PythonPath -Arguments @(
                "-m", "unittest", "-v", "test_snipeit_mail_relay.py"
            ) -Description "Relay Python tests"
        }
        finally {
            Pop-Location
        }

        Push-Location $maintenanceRoot
        try {
            Invoke-Checked -FilePath $PythonPath -Arguments @(
                "-m", "unittest", "-v", "test_snipeit_maintenance.py"
            ) -Description "Maintenance Python tests"
        }
        finally {
            Pop-Location
        }
    }

    Write-Host "`nAll requested checks passed." -ForegroundColor Green
}
finally {
    Remove-Item -LiteralPath $stageRoot -Recurse -Force -ErrorAction SilentlyContinue
}
