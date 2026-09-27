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
function MustReject([scriptblock]$Action) {
    $rejected = $false
    try { $null = & $Action } catch { $rejected = $true }
    if (-not $rejected) { throw 'Negative control unexpectedly passed.' }
}
$validated = Run 'Validate'
if ($validated.source -ne $ExpectedSource -or $ExpectedSource -notmatch '^[0-9a-f]{40}$') { throw 'Source mismatch.' }
$first = Run 'Apply'
$second = Run 'Apply'
if ($second.copied -ne 0 -or $second.changedProperties -ne 0) { throw 'Second apply changed state.' }
$null = Run 'Test'

# Independent provider readback, using the generated declaration rather than
# another product list. Read actual registry values and installed file hashes.
$manifest = Get-Content (Join-Path $PSScriptRoot 'manifest.json') -Raw -Encoding utf8 | ConvertFrom-Json
$config = Get-Content (Join-Path $PSScriptRoot 'configuration.dsc.json') -Raw -Encoding utf8 | ConvertFrom-Json
for ($i = 0; $i -lt $manifest.fonts.Count; $i++) {
    $resource = $config.resources[$i].properties
    $path = 'Registry::' + ($resource.keyPath -replace '^HKCU\\', 'HKEY_CURRENT_USER\')
    $actual = Get-ItemPropertyValue -LiteralPath $path -Name $resource.valueName
    if ($actual -ne (Join-Path $first.fontDirectory $manifest.fonts[$i].file)) { throw 'Independent registry readback failed.' }
}

# Installed-byte drift must fail Test and be repaired by the same artifact.
$installed = Join-Path $first.fontDirectory $manifest.fonts[0].file
[IO.File]::WriteAllText($installed, 'negative-control')
MustReject { Run 'Test' }
$repair = Run 'Apply'
if ($repair.copied -ne 1) { throw 'Expected one repaired file.' }
$null = Run 'Test'

# Valid JSON with altered bytes still fails the package inventory before effects.
$path = Join-Path $PSScriptRoot 'configuration.dsc.json'
$original = [IO.File]::ReadAllBytes($path)
try {
    [IO.File]::AppendAllText($path, "`n")
    MustReject { Run 'Validate' }
}
finally { [IO.File]::WriteAllBytes($path, $original) }
$null = Run 'Test'
[ordered]@{ source = $ExpectedSource; proof = 'PASS'; fonts = $first.fonts;
    secondApplyChanges = 0; installedDriftRejected = $true; corruptionRejected = $true;
    scope = 'current-user file and registry convergence; not rendering or real-host UX' } | ConvertTo-Json
