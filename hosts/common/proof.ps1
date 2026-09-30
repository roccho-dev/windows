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
# No win.ps1 mode may claim a real default-terminal handoff, and the host-only
# handoff proof must refuse to run on a runner.
function MustNotClaimHandoff($Answer) {
    if ($Answer.handoffProof -ne 'unproven' -or $Answer.registrationState -notin @('registered', 'unregistered')) {
        throw 'win.ps1 claimed or omitted default-terminal handoff state.'
    }
}
MustNotClaimHandoff $validated
MustReject { & (Join-Path $PSScriptRoot 'handoff-proof.ps1') -Phase Probe } 'Handoff proof is host-only*'

# The handoff evaluator is pure, so synthetic evidence exercises each verdict.
# A synthetic 'proven' tests the rule only; it is not an observed handoff.
. (Join-Path $PSScriptRoot 'handoff-evaluate.ps1')
$noctty = '{33368C6F-D328-410C-B225-26DC9F12C728}'
$terminal = '{E12CFF52-A866-4C77-9A90-F570A7AA2C6B}'
$start = [DateTime]::UtcNow
$at = $start.AddSeconds(3)
$handoffCases = 0
function ProbeRecord([hashtable]$Change = @{}) {
    $record = [ordered]@{ startedUtc = $start.ToString('o'); endedUtc = $start.AddSeconds(10).ToString('o')
        registrationState = 'registered'; windowOwnedByNoctty = $true; newTerminalHosts = @()
        failures = @(); gaps = @(); handoffProof = 'unproven' }
    foreach ($key in $Change.Keys) { $record[$key] = $Change[$key] }
    [pscustomobject]$record
}
function Row([string]$Name, [DateTime]$Time, [string]$Clsid, [string]$Stamp) {
    # tracerpt-style XML; ETW timestamps may carry nine fractional digits.
    if (-not $Stamp) { $Stamp = $Time.ToString("yyyy-MM-dd'T'HH:mm:ss.fffffff", [Globalization.CultureInfo]::InvariantCulture) + '00Z' }
    "<Event><System><TimeCreated SystemTime=`"$Stamp`"/></System><RenderingInfo><Task>$Name</Task></RenderingInfo>" +
        "<EventData><Data Name=`"TerminalClsid`">$Clsid</Data></EventData></Event>"
}
function MustJudge([string]$Expected, $Record, [string[]]$Rows, [TimeZoneInfo]$Zone = [TimeZoneInfo]::Local) {
    $document = [xml]('<Events>' + ($Rows -join '') + '</Events>')
    $verdict = Get-HandoffVerdict $Record @(Get-HandoffEvents $document $Zone) $noctty
    if ($verdict.handoffProof -ne $Expected) { throw "Handoff evaluator returned $($verdict.handoffProof), expected $Expected." }
    $script:handoffCases++
}
MustJudge 'proven' (ProbeRecord) @((Row 'SrvInit_ReceiveHandoff' $at $noctty), (Row 'SrvInit_ReceiveHandoff_OpenedPipes' $at $terminal))
MustJudge 'failed' (ProbeRecord) @(Row 'SrvInit_ReceiveHandoff' $at $terminal)
MustJudge 'unproven' (ProbeRecord) @()
MustJudge 'unproven' (ProbeRecord) @((Row 'SrvInit_ReceiveHandoff' $at $noctty), (Row 'SrvInit_ReceiveHandoff' $at $noctty))
MustJudge 'unproven' (ProbeRecord) @(Row 'SrvInit_ReceiveHandoff' ($start.AddMinutes(-5)) $noctty)
MustJudge 'unproven' (ProbeRecord) @(Row 'SrvInit_ReceiveHandoff' $at $noctty 'not-a-time')
MustJudge 'unproven' (ProbeRecord @{ windowOwnedByNoctty = $false }) @(Row 'SrvInit_ReceiveHandoff' $at $noctty)
MustJudge 'unproven' (ProbeRecord @{ registrationState = 'unregistered' }) @(Row 'SrvInit_ReceiveHandoff' $at $noctty)
MustJudge 'failed' (ProbeRecord @{ newTerminalHosts = @(@{ pid = 1 }) }) @(Row 'SrvInit_ReceiveHandoff' $at $noctty)
MustJudge 'failed' (ProbeRecord @{ failures = @('Probe window is owned by WindowsTerminal.exe.'); handoffProof = 'failed' }) @(
    Row 'SrvInit_ReceiveHandoff' $at $noctty)
# A probe gap such as an unanswered package view keeps the verdict unproven;
# only the probe's own ETW placeholder is resolved by the trace.
MustJudge 'unproven' (ProbeRecord @{ gaps = @('The Windows Terminal package view did not answer in time.') }) @(
    Row 'SrvInit_ReceiveHandoff' $at $noctty)
MustJudge 'proven' (ProbeRecord @{ gaps = @('Console host ETW has not been evaluated; run -Phase Finalize.') }) @(
    Row 'SrvInit_ReceiveHandoff' $at $noctty)

# tracerpt prints the local wall clock with an untrustworthy numeric offset
# (observed: 14:38:39.792622000+08:59 in Asia/Tokyo for 05:38:39.792622Z).
$tokyo = [TimeZoneInfo]::FindSystemTimeZoneById('Tokyo Standard Time')
$expected = [DateTime]::SpecifyKind([DateTime]::new(2026, 9, 29, 5, 38, 39).AddTicks(7926220), [DateTimeKind]::Utc)
if ((ConvertFrom-TracerptTime '2026-09-29T14:38:39.792622000+08:59' $tokyo) -ne $expected -or
    (ConvertFrom-TracerptTime '2026-09-29T05:38:39.7926220Z' $tokyo) -ne $expected -or
    $null -ne (ConvertFrom-TracerptTime '2026-09-29T14:38:39.792622000' $tokyo)) {
    throw 'tracerpt timestamps are not converted as local wall clock (offset) or UTC (Z).'
}
$handoffCases++
# The same shape built from this runner's local wall clock, with a wrong offset,
# must still land inside the probe window.
$localStamp = [TimeZoneInfo]::ConvertTimeFromUtc($at, [TimeZoneInfo]::Local).ToString(
    "yyyy-MM-dd'T'HH:mm:ss.fffffff", [Globalization.CultureInfo]::InvariantCulture) + '00+08:59'
MustJudge 'proven' (ProbeRecord) @(Row 'SrvInit_ReceiveHandoff' $at $noctty $localStamp)
# Finalize reads the stamp in the probe's recorded zone, not the evaluator's:
# a Tokyo wall clock is proven in Tokyo and misplaced by nine hours in UTC.
$tokyoStamp = [TimeZoneInfo]::ConvertTimeFromUtc($at, $tokyo).ToString(
    "yyyy-MM-dd'T'HH:mm:ss.fffffff", [Globalization.CultureInfo]::InvariantCulture) + '00+08:59'
MustJudge 'proven' (ProbeRecord) @(Row 'SrvInit_ReceiveHandoff' $at $noctty $tokyoStamp) $tokyo
MustJudge 'unproven' (ProbeRecord) @(Row 'SrvInit_ReceiveHandoff' $at $noctty $tokyoStamp) ([TimeZoneInfo]::Utc)

# The HKCU and Windows Terminal package views of the selection.
$pair = { param($Console, $Terminal) [pscustomobject]@{ console = $Console; terminal = $Terminal } }
$wtConsole = '{2EACA947-7F5F-4CFA-BA87-8F7FBEEFBE69}'
function MustCompare([string]$Expected, $Hkcu, $Package, [string]$Note) {
    $result = Compare-TerminalSelection $Hkcu $Package $Note
    $contrary = [bool]$result.failure
    if ($result.state -ne $Expected -or $contrary -ne ($Expected -eq 'mismatch') -or
        [bool]$result.gap -ne ($Expected -in @('invalid', 'unavailable'))) {
        throw "Selection comparison returned $($result.state), expected $Expected."
    }
    $script:handoffCases++
}
MustCompare 'match' (& $pair $wtConsole $noctty) (& $pair $wtConsole.ToLowerInvariant() $noctty.ToLowerInvariant()) ''
MustCompare 'mismatch' (& $pair $wtConsole $noctty) (& $pair $wtConsole $terminal) ''
MustCompare 'invalid' (& $pair $wtConsole $noctty) (& $pair $wtConsole $null) ''
MustCompare 'invalid' (& $pair $wtConsole $noctty) (& $pair $wtConsole 'not-a-guid') ''
MustCompare 'invalid' (& $pair $wtConsole $noctty) $null ''
MustCompare 'unavailable' (& $pair $wtConsole $noctty) $null 'The Windows Terminal package view did not answer in time.'
# A mismatch names the likely cause observed on a real host: this process's own
# HKCU virtualized by an app's registry silo.
if ((Compare-TerminalSelection (& $pair $wtConsole $noctty) (& $pair $wtConsole $terminal) '').failure -notlike '*may be virtualized*') {
    throw 'Selection mismatch does not name a virtualized local HKCU.'
}
$handoffCases++
# Package pins: Restore skips the WinGet `set` only when PackagesSatisfied. The
# base answer is the shape the Microsoft.WinGet/Package test returned on the
# development host; each variation must make it unsatisfied.
$observed = '{"hadErrors":false,"results":[{"name":"Chromium","result":{"inDesiredState":true,' +
    '"desiredState":{"acceptAgreements":true,"id":"Hibbiki.Chromium","installMode":"silent","source":"winget","version":"154.0.8037.58"},' +
    '"actualState":{"_exist":true,"_inDesiredState":true,"id":"Hibbiki.Chromium","source":"winget","useLatest":true,"version":"154.0.8037.58"},' +
    '"differingProperties":[]}},{"name":"AutoHotkey","result":{"inDesiredState":true,' +
    '"desiredState":{"id":"AutoHotkey.AutoHotkey","version":"2.0.28"},' +
    '"actualState":{"_exist":true,"id":"AutoHotkey.AutoHotkey","version":"2.0.28"},"differingProperties":[]}}]}'
function MustPin([bool]$Expected, [string]$Case, [scriptblock]$Change) {
    $answer = $observed | ConvertFrom-Json
    if ($Change) { & $Change $answer }
    if ((PackagesSatisfied $answer) -ne $Expected) { throw "PackagesSatisfied is wrong for: $Case" }
    $script:handoffCases++
}
MustPin $true 'observed pinned packages' $null
MustPin $false 'newer installed version' { param($a) $a.results[0].result.actualState.version = '155.0.8100.10' }
MustPin $false 'test not in desired state' { param($a) $a.results[1].result.inDesiredState = $false }
MustPin $false 'differing property listed' { param($a) $a.results[0].result.differingProperties = @('version') }
MustPin $false 'package absent' { param($a) $a.results[1].result.actualState._exist = $false }
MustPin $false 'no installed version reported' { param($a) $a.results[0].result.actualState.PSObject.Properties.Remove('version') }
MustPin $false 'no pinned version' { param($a) $a.results[0].result.desiredState.PSObject.Properties.Remove('version') }
MustPin $false 'DSC reported errors' { param($a) $a.hadErrors = $true }
MustPin $false 'no results' { param($a) $a.results = @() }

# The package-context reader is shared by win.ps1; loading it only defines functions.
. (Join-Path $PSScriptRoot 'package-view.ps1')
foreach ($name in 'Get-HkcuTerminalSelection', 'Test-PackageTerminalSelection', 'Get-PackageReaderScript') {
    if (-not (Get-Command $name -CommandType Function -ErrorAction SilentlyContinue)) { throw "package-view.ps1 lacks $name." }
}
$handoffCases++
# The generated reader parses, and on this runner (outside any package) writes
# exactly one complete {console, terminal} answer; it only reads the registry.
$readerErrors = $null
$null = [Management.Automation.Language.Parser]::ParseInput((Get-PackageReaderScript), [ref]$null, [ref]$readerErrors)
if (@($readerErrors).Count) { throw 'The generated package reader does not parse.' }
$readerDir = Join-Path ([IO.Path]::GetTempPath()) ('reader-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $readerDir
try {
    $readerScript = Join-Path $readerDir 'view.ps1'
    $readerAnswer = Join-Path $readerDir 'view.json'
    [IO.File]::WriteAllText($readerScript, (Get-PackageReaderScript), [Text.UTF8Encoding]::new($true))
    & (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') -NoProfile -NonInteractive `
        -ExecutionPolicy Bypass -File $readerScript -Out $readerAnswer
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $readerAnswer) -or (Test-Path -LiteralPath "$readerAnswer.partial")) {
        throw 'The generated package reader did not write one complete answer.'
    }
    $read = Get-Content -LiteralPath $readerAnswer -Raw | ConvertFrom-Json
    if ((@($read.PSObject.Properties.Name) -join ',') -ne 'console,terminal') { throw 'The package reader answer has the wrong shape.' }
} finally {
    # Exactly the reader's known files, then the directory itself, never recursively: anything else keeps it and fails.
    foreach ($name in 'view.ps1', 'view.json', 'view.json.partial') { [IO.File]::Delete((Join-Path $readerDir $name)) }
    [IO.Directory]::Delete($readerDir, $false)
}
$handoffCases++
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
MustNotClaimHandoff $first
MustNotClaimHandoff (Run 'Test')

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

# Rent SSH client, bound explicitly with synthetic values (a live binding comes from envs and the rent's own host key).
# It proves the pinned client, the generated OpenSSH configuration and the Include handling; it never connects.
$bind = @{ Hostname = 'rent.example.invalid'; HostKey = 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGNpLXN5bnRoZXRpYy1ob3N0LWtleS1ub3QtcmVhbA=='
    Identity = (Join-Path $env:RUNNER_TEMP 'rent-ci-identity') }
[IO.File]::WriteAllText($bind.Identity, 'synthetic identity path; never used to connect')
function RunSsh([string]$Mode, [hashtable]$With = $bind) { (& (Join-Path $PSScriptRoot 'win.ps1') -Mode $Mode @With) | ConvertFrom-Json }
$sshDir = Join-Path $env:USERPROFILE '.ssh'
$userConfig = Join-Path $sshDir 'config'
if (Test-Path -LiteralPath (Join-Path $sshDir 'windows-rent')) { throw 'Proof requires a fresh disposable SSH profile.' }
# A prior user configuration whose exact bytes must survive, below the one added line and in the one backup.
$null = New-Item -ItemType Directory -Path $sshDir -Force
if (-not (Test-Path -LiteralPath $userConfig)) { [IO.File]::WriteAllText($userConfig, "Host prior`r`n  User prior`r`n") }
$prior = [IO.File]::ReadAllBytes($userConfig)
MustReject { RunSsh 'RentSshTest' } 'RentSsh drift:*'
foreach ($bad in @(@{ Hostname = 'bad host' }, @{ HostKey = 'ssh-rsa AAAA' }, @{ Identity = 'C:\missing\key' }, @{ Alias = 'Bad Alias' })) {
    $with = $bind.Clone(); foreach ($k in $bad.Keys) { $with[$k] = $bad[$k] }
    MustReject { RunSsh 'RentSsh' $with } 'Invalid*'
}
if ([Convert]::ToBase64String([IO.File]::ReadAllBytes($userConfig)) -ne [Convert]::ToBase64String($prior)) { throw 'A refused binding wrote the user config.' }
# A stale backup is refused before any write: no client, no rent files, both user files byte-identical.
$clientDir = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) ('Programs\cloudflared-' + $manifest.cloudflared.version)
if (Test-Path -LiteralPath $clientDir) { throw 'Proof requires no installed client yet.' }
$backup = Join-Path $sshDir 'config.before-windows-rent'
[IO.File]::WriteAllText($backup, "stale backup`n")
$stale = [IO.File]::ReadAllBytes($backup)
MustReject { RunSsh 'RentSsh' } '*config.before-windows-rent already exists; not overwriting it.'
if ((Test-Path -LiteralPath $clientDir) -or (Test-Path -LiteralPath (Join-Path $sshDir 'windows-rent'))) { throw 'A refused binding installed files.' }
if ([Convert]::ToBase64String([IO.File]::ReadAllBytes($userConfig)) -ne [Convert]::ToBase64String($prior) -or
    [Convert]::ToBase64String([IO.File]::ReadAllBytes($backup)) -ne [Convert]::ToBase64String($stale)) { throw 'A refused binding changed the user config or backup.' }
Remove-Item -LiteralPath $backup
$ssh = RunSsh 'RentSsh'
$expected = [Text.Encoding]::UTF8.GetBytes("Include windows-rent/config`n") + $prior
foreach ($pass in 1, 2) {
    if ([Convert]::ToBase64String([IO.File]::ReadAllBytes($userConfig)) -ne [Convert]::ToBase64String([byte[]]$expected)) { throw "User config is not the Include line plus its exact prior bytes (pass $pass)." }
    if ([Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $sshDir 'config.before-windows-rent'))) -ne [Convert]::ToBase64String($prior)) { throw 'Backup differs from the prior bytes.' }
    $null = RunSsh 'RentSsh'
}
$null = RunSsh 'RentSshTest'
if ((Get-FileHash -LiteralPath $ssh.client -Algorithm SHA256).Hash -ne $manifest.cloudflared.sha256) { throw 'Installed client differs from the manifest.' }
$version = (& $ssh.client --version) -join "`n"
if ($version -notmatch ('^cloudflared version ' + [regex]::Escape($manifest.cloudflared.version) + '( |$)')) { throw "Unexpected client version: $version" }
# What Windows OpenSSH (as Codex Remote SSH uses it) resolves for the alias, from the user's own config.
$resolved = @(& ssh.exe -G windows-rent) | ForEach-Object { $_.ToLowerInvariant() }
foreach ($line in @('hostname rent.example.invalid', 'user dev', 'hostkeyalias windows-rent', 'stricthostkeychecking true',
        ('proxycommand "' + $ssh.client.ToLowerInvariant() + '" access ssh --hostname %h'))) {
    if ($resolved -cnotcontains $line) { throw "ssh -G lacks: $line" }
}
if (-not ($resolved | Where-Object { $_ -like 'userknownhostsfile *windows-rent*known_hosts*' })) { throw 'ssh -G lacks the pinned known_hosts.' }
# Drift is reported and repaired by the same explicit mode.
[IO.File]::AppendAllText($ssh.config, "  StrictHostKeyChecking no`n")
MustReject { RunSsh 'RentSshTest' } 'RentSsh drift:*'
$null = RunSsh 'RentSsh'
$null = RunSsh 'RentSshTest'

[ordered]@{ source = $ExpectedSource; proof = 'PASS'; fonts = $first.fonts;
    secondApplyChanges = 0; preexistingCorruptionRepaired = $true;
    registryDriftRejected = $true; corruptionRejected = $true;
    rentSsh = "cloudflared $($manifest.cloudflared.version) client, strict config, Include preserved and idempotent, drift repaired"
    winReportsHandoffUnproven = $true; handoffProbeRefusedOnRunner = $true; handoffEvaluatorCases = $handoffCases;
    scope = 'current-user file, registry and SSH-client convergence; not rendering, default-terminal handoff, real-host UX or a Cloudflare connection' } | ConvertTo-Json
