# Syntax and manifest checks; intentionally never invokes either installation entry point.
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$psFiles = @(Get-ChildItem -LiteralPath $repoRoot -Filter *.ps1) +
    @(Get-ChildItem -LiteralPath "$repoRoot\docker-ce", "$repoRoot\scripts", "$repoRoot\tests" -Filter *.ps1)
$errors = @()
foreach ($file in $psFiles) {
    $tokens = $null
    $parseErrors = $null
    $null = [Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$parseErrors)
    $errors += @($parseErrors | ForEach-Object { "$($file.Name): $($_.Message)" })
}
Write-Host "Parsed $($psFiles.Count) PowerShell files; $($errors.Count) errors."
if ($errors.Count) { throw ($errors -join "`n") }
$jsonFiles = @(Get-ChildItem -LiteralPath $repoRoot -Filter *.json) + @(Get-ChildItem -LiteralPath "$repoRoot\docker-ce" -Filter *.json)
foreach ($file in $jsonFiles) { $null = Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json }
Write-Host "Parsed $($jsonFiles.Count) JSON files."
foreach ($file in Get-ChildItem -LiteralPath $repoRoot -Filter 'packages-*.json') {
    $manifest = Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json
    if (-not $manifest.winget) { throw "$($file.Name): expected a nonempty winget array." }
    foreach ($package in $manifest.winget) {
        if (-not $package.id -or -not $package.source) { throw "$($file.Name): package missing id/source." }
    }
    foreach ($module in $manifest.powershellModule) {
        if (-not $module.name) { throw "$($file.Name): module missing name." }
    }
}
Write-Host 'Manifest schema checks passed.'
& "$repoRoot\tests\setup-regression.ps1"
