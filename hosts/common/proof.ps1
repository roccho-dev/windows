#requires -Version 7.0
[CmdletBinding()]
param([Parameter(Mandatory)][string]$ExpectedSource)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ($env:GITHUB_ACTIONS -ne 'true' -or $env:RUNNER_ENVIRONMENT -ne 'github-hosted') {
    throw 'Proof mutates disposable state and is restricted to GitHub-hosted runners.'
}
function Run([string]$Mode) {
    (& (Join-Path $PSScriptRoot 'win.ps1') -Mode $Mode) | ConvertFrom-Json
}
function MustReject([scriptblock]$Action, [string]$Pattern) {
    try { $null = & $Action }
    catch {
        if ($_.Exception.Message -notlike $Pattern) { throw }
        return
    }
    throw 'Negative control unexpectedly passed.'
}
$validated = Run 'Validate'
if ($validated.source -ne $ExpectedSource -or $ExpectedSource -notmatch '^[0-9a-f]{40}$') { throw 'Source mismatch.' }
$manifest = Get-Content (Join-Path $PSScriptRoot 'manifest.json') -Raw -Encoding utf8 | ConvertFrom-Json
$config = Get-Content (Join-Path $PSScriptRoot 'configuration.dsc.json') -Raw -Encoding utf8 | ConvertFrom-Json

# Seed damaged bytes BEFORE registration: Windows may lock registered fonts.
# This models an interrupted first installation, without stopping OS services.
$installed = Join-Path $validated.fontDirectory $manifest.fonts[0].file
if (Test-Path -LiteralPath $installed) { throw 'Proof requires a fresh disposable font target.' }
$null = New-Item -ItemType Directory -Path $validated.fontDirectory -Force
[IO.File]::WriteAllText($installed, 'negative-control')
MustReject { Run 'Test' } 'Installed bytes differ:*'
$first = Run 'Apply'
if ($first.copied -lt 1) { throw 'Preexisting corruption was not repaired.' }
$second = Run 'Apply'
if ($second.copied -ne 0 -or $second.changedProperties -ne 0) { throw 'Second apply changed state.' }
$null = Run 'Test'

# Independent provider readback uses the generated declaration, not a second Spec.
for ($i = 0; $i -lt $manifest.fonts.Count; $i++) {
    $resource = $config.resources[$i].properties
    $path = 'Registry::' + ($resource.keyPath -replace '^HKCU\\', 'HKEY_CURRENT_USER\')
    $actual = Get-ItemPropertyValue -LiteralPath $path -Name $resource.valueName
    if ($actual -ne (Join-Path $first.fontDirectory $manifest.fonts[$i].file)) { throw 'Independent registry readback failed.' }
}

# Drift must fail specifically because DSC reports nonconvergence, not any error.
$resource = $config.resources[0].properties
$key = 'Registry::' + ($resource.keyPath -replace '^HKCU\\', 'HKEY_CURRENT_USER\')
Set-ItemProperty -LiteralPath $key -Name $resource.valueName -Value 'negative-control'
MustReject { Run 'Test' } 'Registry drift:*'
$null = Run 'Apply'
$null = Run 'Test'

# Valid JSON with altered bytes still fails the inventory before effects.
$path = Join-Path $PSScriptRoot 'configuration.dsc.json'
$original = [IO.File]::ReadAllBytes($path)
try {
    [IO.File]::AppendAllText($path, "`n")
    MustReject { Run 'Validate' } 'Bundle content mismatch:*'
}
finally { [IO.File]::WriteAllBytes($path, $original) }
$null = Run 'Test'
[ordered]@{ source = $ExpectedSource; proof = 'PASS'; fonts = $first.fonts;
    secondApplyChanges = 0; preexistingCorruptionRepaired = $true;
    registryDriftRejected = $true; corruptionRejected = $true;
    scope = 'current-user file and registry convergence; not rendering or real-host UX' } | ConvertTo-Json
