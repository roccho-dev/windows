#requires -Version 7.0
[CmdletBinding()]
param([Parameter(Mandatory)][string]$ExpectedSource)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ($env:GITHUB_ACTIONS -ne 'true' -or $env:RUNNER_ENVIRONMENT -ne 'github-hosted') {
    throw 'Proof mutates disposable state and is restricted to GitHub-hosted runners.'
}
# win.ps1 runs as on a real host: a child Windows PowerShell 5.1 process with -File.
# Success is exit code 0, nothing on stderr and exactly one JSON object on stdout.
# A failure is rethrown with the child's error message, which 5.1 wraps at the
# console width: its lines are rejoined up to the "At <script>:<line> char:<n>" line, which is
# printed to the log (not added to the message, so negative controls keep their patterns).
# Every child also logs one timing line: its arguments, exit code, seconds and ledger record count.
$windowsPowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
function Win51([string[]]$Arguments) {
    $ErrorActionPreference = 'Continue'  # the child's stderr is data here, not an error of this process
    $PSNativeCommandUseErrorActionPreference = $false
    # One timing line per child, success or failure, to the log only: seconds and the effect ledger's record count.
    $clock, $code = [Diagnostics.Stopwatch]::StartNew(), 'none'
    try {
        $lines = @(& $windowsPowerShell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'win.ps1') @Arguments 2>&1)
        $code = $LASTEXITCODE
        $stdout = @($lines | Where-Object { $_ -isnot [Management.Automation.ErrorRecord] } | ForEach-Object { [string]$_ } | Where-Object { $_.Trim() })
        $stderr = @($lines | Where-Object { $_ -is [Management.Automation.ErrorRecord] } | ForEach-Object { $_.ToString() })
        if ($code -ne 0) {
            $message, $atPosition = '', $false
            foreach ($line in $stderr) {
                if ($line -match '^At .+ char:\d+\s*$' -and -not $atPosition) { $atPosition = $true; Write-Host "win.ps1 ($($Arguments -join ' ')) stopped: $($line.Trim())" }
                if (-not $atPosition) { $message += $line }
            }
            if (-not $message.Trim()) { $message = "win.ps1 exited $code without an error message: $($stderr -join ' ')" }
            throw [Management.Automation.RuntimeException]::new($message)
        }
        if ($stderr.Count) { throw "win.ps1 succeeded but wrote to stderr: $($stderr -join ' ')" }
        if ($stdout.Count -ne 1) { throw "win.ps1 printed $($stdout.Count) output lines instead of one JSON object." }
        try { $answer = $stdout[0] | ConvertFrom-Json } catch { throw "win.ps1 printed malformed JSON: $($stdout[0])" }
        if ($answer -isnot [Management.Automation.PSCustomObject]) { throw "win.ps1 printed JSON that is not one object: $($stdout[0])" }
        return $answer
    } finally {
        $ledger = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'windows-iac\ledger'
        $records = if (Test-Path -LiteralPath $ledger) { @(Get-ChildItem -LiteralPath $ledger -Filter '*.json').Count } else { 0 }
        Write-Host "win.ps1 $($Arguments -join ' ') exit $code $([Math]::Round($clock.Elapsed.TotalSeconds, 1)) s ledger $records"
    }
}
function Run([string]$Mode) { Win51 @('-Mode', $Mode) }
# A wrapped child message may gain or lose a space at a line break, so a pattern
# that fails exactly is compared once more with all whitespace removed.
function MustReject([scriptblock]$Action, [string]$Pattern) {
    try { $null = & $Action }
    catch {
        $message = $_.Exception.Message
        if ($message -notlike $Pattern -and ($message -replace '\s', '') -notlike ($Pattern -replace '\s', '')) { throw }
        return
    }
    throw 'Negative control unexpectedly passed.'
}
$validated = Run 'Validate'
if ($validated.source -ne $ExpectedSource -or $ExpectedSource -notmatch '^[0-9a-f]{40}$') { throw 'Source mismatch.' }
# An app appearance is optional: the same bundle validates with apps that have none, and with no apps at all. A copy of the
# listed files gets each variant's manifest.json (outside the inventory), run as the real one is (5.1, -File).
foreach ($variant in 'without appearance', 'without apps') {
    $copy = Join-Path $env:RUNNER_TEMP ('optional-apps-' + [guid]::NewGuid().ToString('N'))
    $variantManifest = Get-Content (Join-Path $PSScriptRoot 'manifest.json') -Raw -Encoding utf8 | ConvertFrom-Json
    foreach ($name in $variantManifest.files.PSObject.Properties.Name) {
        $target = Join-Path $copy $name
        $null = New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot $name) -Destination $target
    }
    $variantManifest.apps = if ($variant -ceq 'without apps') { @() } else { @($variantManifest.apps | ForEach-Object { $_.PSObject.Properties.Remove('appearance'); $_ }) }
    [IO.File]::WriteAllText((Join-Path $copy 'manifest.json'), ($variantManifest | ConvertTo-Json -Depth 20), [Text.UTF8Encoding]::new($false))
    $variantLines = @(& $windowsPowerShell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $copy 'win.ps1') -Mode Validate 2>&1)
    if ($LASTEXITCODE -ne 0) { throw "win.ps1 -Mode Validate fails $variant`: $($variantLines -join ' ')" }
    Write-Host "Validate $variant`: exit 0"
}
# The run identity is a record, not text (a [string] script parameter of the same name once flattened it).
if ($validated.identity.sid -notmatch '^S-1-' -or $validated.identity.elevated -isnot [bool]) { throw 'win.ps1 reported no run identity record.' }
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
    foreach ($name in 'view.ps1', 'view.json', 'view.json.partial') {
        $path = Join-Path $readerDir $name
        $item = Get-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
        if ($null -eq $item) { continue }
        if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw "Kept unexpected entry $path." }
        [IO.File]::Delete($path)
    }
    [IO.Directory]::Delete($readerDir, $false)
}
$handoffCases++
$manifest = Get-Content (Join-Path $PSScriptRoot 'manifest.json') -Raw -Encoding utf8 | ConvertFrom-Json

# The pure ledger classification (P1): the class of a reverted or never-effective
# attempt is the same before and after its closing record, for every kind.
$absent = @{ exists = $false }
function Sha([string]$Char) { $Char * 64 }
function PureRecord($Seq, $Phase, $Kind, $Target, $Prior, $Desired, $Observed, $Name) {
    $r = @{ ledger = 'effects'; schema = 1; seq = $Seq; phase = $Phase; id = 'x'; kind = $Kind; target = $Target
        prior = $Prior; desired = $Desired }
    if ($null -ne $Observed) { $r.observed = $Observed }
    if ($null -ne $Name) { $r.name = $Name }
    $r
}
$pureKinds = @(
    @('file-created', 'C:\u\f', $absent, @{ exists = $true; sha256 = (Sha a) }, $null),
    @('tree-extracted', 'C:\u\t', $absent, @{ exists = $true; files = @{ 'a.txt' = (Sha a) } }, $null),
    @('prefix-inserted', 'C:\u\p', @{ exists = $true; sha256 = (Sha b); backup = 'C:\u\p.bak' }, @{ exists = $true; sha256 = (Sha c); line = 'Include x' }, $null),
    @('file-replaced', 'C:\u\r', @{ exists = $true; sha256 = (Sha b); backup = 'C:\u\r.bak' }, @{ exists = $true; sha256 = (Sha c) }, $null),
    @('registry-value', 'HKCU\Software\W', $absent, @{ exists = $true; type = 'String'; data = 'new' }, 'v'),
    @('registry-value', 'HKCU\Software\W', @{ exists = $true; type = 'String'; data = 'old' }, @{ exists = $true; type = 'String'; data = 'new' }, 'v'),
    @('registry-key-created', 'HKCU\Software\Classes\CLSID\{W}', $absent, @{ exists = $true }, $null),
    @('ui-font-face', 'winmetrics:menu', @{ exists = $true; face = 'Segoe UI' }, @{ exists = $true; face = 'IBM Plex Sans JP' }, $null))
foreach ($case in $pureKinds) {
    $kind, $target, $prior, $desired, $name = $case
    $committed = @((PureRecord 1 intent $kind $target $prior $desired $null $name), (PureRecord 2 commit $kind $target $prior $desired $desired $name))
    $intent = @(PureRecord 1 intent $kind $target $prior $desired $null $name)
    foreach ($selection in @(@('', $null), @($kind, $desired), @($kind, $prior))) {
        foreach ($pair in @(@($committed, 'undone', 3), @($intent, 'void', 2))) {
            $before = Get-EffectClass $pair[0] $prior $selection[0] $selection[1]
            $after = Get-EffectClass ($pair[0] + @(PureRecord $pair[2] $pair[1] $kind $target $prior $desired $prior $name)) $prior $selection[0] $selection[1]
            if ($before.resolution -ne $pair[1] -or $after.resolution -or $before.class -cne $after.class -or
                $before.class -cnotin @('absent', 'preexisting-match', 'preexisting-drift')) {
                throw "Closing a $kind attempt with $($pair[1]) changes its class ($($before.class) -> $($after.class))."
            }
        }
    }
}
$plan = Get-UninstallPlan @((PureRecord 1 intent file-created 'C:\u\f' $absent @{ exists = $true; sha256 = (Sha a) } $null $null),
    (PureRecord 2 commit file-created 'C:\u\f' $absent @{ exists = $true; sha256 = (Sha a) } @{ exists = $true; sha256 = (Sha a) } $null)) @{ x = $absent }
if (-not $plan.ok -or @($plan.steps).Count -or ($plan.resolutions | ForEach-Object { $_.resolution }) -cne 'undone') {
    throw 'A reverted owned effect is not closed undone by the uninstall plan.'
}

# S-A1b pure rules (no executor uses them yet).
function Must([bool]$Holds, [string]$Rule) { if (-not $Holds) { throw "Pure ledger rule failed: $Rule" } }
function Owned($Seq, $Id, $Kind, $Target, $Desired, $Name) {
    foreach ($phase in 'intent', 'commit') {
        $r = PureRecord $Seq $phase $Kind $Target $absent $Desired $(if ($phase -ceq 'commit') { $Desired } else { $null }) $Name
        $r.id = $Id; $Seq++; $r
    }
}
function Actions($Plan) { @($Plan.steps | ForEach-Object { $_.action }) -join ',' }
$clsid = 'HKCU\Software\Classes\CLSID\{W}'
$exists, $data = @{ exists = $true }, @{ exists = $true; type = 'String'; data = 'x' }
# A created key may hold values and created subkeys whose intents came later; they are removed first.
$records = @(Owned 1 k registry-key-created $clsid $exists $null) + @(Owned 3 v registry-value "$clsid\LocalServer32" $data '') +
    @(Owned 5 s registry-key-created "$clsid\InprocServer32" $exists $null)
$plan = Get-UninstallPlan $records @{ k = $exists; v = $data; s = $exists }
Must ($plan.ok -and (Actions $plan) -ceq 'delete-empty-key,delete-registry-value,delete-empty-key') 'a created key is removed after what it holds'
Must (-not (Get-UninstallPlan (@(Owned 1 v registry-value "$clsid\LocalServer32" $data '') + @(Owned 3 k registry-key-created $clsid $exists $null)) @{ k = $exists; v = $data }).ok) 'a value owned before its key is refused'
Must (-not (Get-UninstallPlan (@(Owned 1 k registry-key-created $clsid $exists $null) + @(Owned 3 j registry-key-created $clsid.ToLowerInvariant() $exists $null)) @{ k = $exists; j = $exists }).ok) 'two claims on one key are refused'
# UI font faces: a slot always holds a face, so prior exists; face is the whole state, compared exactly; another
# face unowned is absent (taken, recording it as prior); the undo writes the prior face back only over the one written.
$segoe, $plex = @{ exists = $true; face = 'Segoe UI' }, @{ exists = $true; face = 'IBM Plex Sans JP' }
function UiRecord($Seq, $Phase, $Target, $Prior, $Desired, $Observed) { $r = PureRecord $Seq $Phase ui-font-face $Target $Prior $Desired $Observed $null; $r.id = "ui:$Target"; $r }
Must ($null -eq (Get-EffectRecordProblem (UiRecord 1 intent 'winmetrics:menu' $segoe $plex $null)) -and
    $null -eq (Get-EffectRecordProblem (UiRecord 2 commit 'winmetrics:icon' $segoe $plex $plex)) -and
    (Get-EffectRecordProblem (UiRecord 1 intent 'winmetrics:menu' $absent $plex $null)) -ceq 'prior must exist.' -and
    (Get-EffectRecordProblem (UiRecord 1 intent 'winmetrics:Menu' $segoe $plex $null)) -like 'target*' -and
    (Get-EffectRecordProblem (UiRecord 1 intent 'HKCU\Control Panel\Desktop\WindowMetrics' $segoe $plex $null)) -like 'target*' -and
    (Get-EffectRecordProblem (UiRecord 1 intent 'winmetrics:menu' $segoe @{ exists = $true; face = 'x' * 32 } $null)) -like 'desired.face*' -and
    (Get-EffectRecordProblem (UiRecord 1 intent 'winmetrics:menu' $segoe @{ exists = $true; face = "a`tb" } $null)) -like 'desired.face*' -and
    (Get-EffectRecordProblem (UiRecord 1 intent 'winmetrics:menu' $segoe @{ exists = $true; face = 'SEGOE UI' } $null)) -eq $null -and
    (Get-EffectRecordProblem (UiRecord 1 intent 'winmetrics:menu' $segoe $segoe $null)) -like 'desired equals prior*' -and
    (Get-EffectRecordProblem (UiRecord 2 commit 'winmetrics:menu' $segoe $plex $segoe)) -ceq 'observed differs from desired.' -and
    (Get-EffectRecordProblem ((UiRecord 1 intent 'winmetrics:menu' $segoe $plex $null) + @{ name = 'MenuFont' })) -ceq 'name belongs to registry-value and pref-value only.') 'ui-font-face records'
Must ((Get-UnownedClass ui-font-face $plex $segoe $null).class -ceq 'absent' -and (Get-UnownedClass ui-font-face $plex $plex $null).class -ceq 'preexisting-match' -and
    (Get-UnownedClass ui-font-face $plex @{ exists = $true; face = 'ibm plex sans jp' } $null).class -ceq 'absent' -and
    (Get-EffectClass @((UiRecord 1 intent 'winmetrics:menu' $segoe $plex $null), (UiRecord 2 commit 'winmetrics:menu' $segoe $plex $plex)) @{ exists = $true; face = 'Meiryo UI' } '' $null).class -ceq 'owned-drift' -and
    (Get-EffectClass @((UiRecord 1 intent 'winmetrics:menu' $segoe $plex $null)) $plex '' $null).resolution -ceq 'confirm') 'ui-font-face classes'
$uiPlan = Get-UninstallPlan @((UiRecord 1 intent 'winmetrics:menu' $segoe $plex $null), (UiRecord 2 commit 'winmetrics:menu' $segoe $plex $plex),
    (UiRecord 3 intent 'winmetrics:icon' $segoe $plex $null), (UiRecord 4 commit 'winmetrics:icon' $segoe $plex $plex)) @{ 'ui:winmetrics:menu' = $plex; 'ui:winmetrics:icon' = $plex }
Must ($uiPlan.ok -and (Actions $uiPlan) -ceq 'set-ui-font-face,set-ui-font-face' -and
    (@($uiPlan.steps | ForEach-Object { "$($_.slot):$($_.expectFace)>$($_.face)" }) -join '|') -ceq 'icon:IBM Plex Sans JP>Segoe UI|menu:IBM Plex Sans JP>Segoe UI' -and
    -not (Get-UninstallPlan @((UiRecord 1 intent 'winmetrics:menu' $segoe $plex $null), (UiRecord 2 commit 'winmetrics:menu' $segoe $plex $plex)) @{ 'ui:winmetrics:menu' = @{ exists = $true; face = 'Meiryo UI' } }).ok) 'ui-font-face undo writes the prior face over the written one only; a changed face is refused'
# The persisted LOGFONTW: only lfFaceName (bytes 28-91) changes; anything not a 92-byte font with a terminated valid
# face is refused.
$logFont = [byte[]]::new(92)
[BitConverter]::GetBytes([int]-12).CopyTo($logFont, 0); $logFont[16] = 0x90; $logFont[26] = 5
[Text.Encoding]::Unicode.GetBytes('Segoe UI').CopyTo($logFont, 28)
$logFont[60] = 0x41  # a stale byte after the terminator, as Windows can leave
$withPlex = Get-LogFontWithFace $logFont 'IBM Plex Sans JP'
$unterminated = [byte[]]$logFont.Clone(); for ($i = 28; $i -lt 92; $i += 2) { $unterminated[$i] = 0x41 }
$taller = [byte[]]$withPlex.Clone(); $taller[0] = 0xF0
$refusedFaces = @(@(@{ b = [byte[]]::new(91); f = 'x' }, @{ b = $unterminated; f = 'x' }, @{ b = $logFont; f = ('x' * 32) }, @{ b = $logFont; f = "a`tb" }) |
    Where-Object { try { $null = Get-LogFontWithFace $_.b $_.f; $false } catch { $true } })
Must ((Get-LogFontFace $logFont) -ceq 'Segoe UI' -and (Get-LogFontFace $withPlex) -ceq 'IBM Plex Sans JP' -and (Test-LogFontFaceOnly $logFont $withPlex) -and
    [BitConverter]::ToString($withPlex, 0, 28) -ceq [BitConverter]::ToString($logFont, 0, 28) -and $withPlex[28 + 2 * 'IBM Plex Sans JP'.Length] -eq 0 -and $withPlex[60] -eq 0 -and
    $null -eq (Get-LogFontFace $unterminated) -and $null -eq (Get-LogFontFace ([byte[]]::new(91))) -and $null -eq (Get-LogFontFace 'not bytes') -and
    -not (Test-LogFontFaceOnly $logFont $taller) -and $refusedFaces.Count -eq 4 -and (Get-LogFontFace (Get-LogFontWithFace $taller 'Segoe UI')) -ceq 'Segoe UI' -and
    (Get-LogFontWithFace $taller 'Segoe UI')[0] -eq 0xF0) 'LOGFONTW face-only edits: header bytes kept, face region rewritten, invalid input refused, a later height kept by the undo'
# Store apps: installed only when no package of that name exists; present only as exactly one of that publisher.
$app = @{ name = 'ChatGPT'; package = 'OpenAI.Codex'; publisherId = '2p2nqsd0c76g0' }
Must ((Get-AppAction @() $app) -ceq 'install' -and (Get-AppAction @(@{ name = 'Other.App'; publisherId = '2p2nqsd0c76g0' }) $app) -ceq 'install' -and
    (Get-AppAction @(@{ name = 'OpenAI.Codex'; publisherId = '2p2nqsd0c76g0'; version = '1.0' }) $app) -ceq 'present' -and
    (Get-AppAction @(@{ name = 'OpenAI.Codex'; publisherId = 'aaaaaaaaaaaaa' }) $app) -ceq 'refuse' -and
    (Get-AppAction @(@{ name = 'OpenAI.Codex'; publisherId = '2P2NQSD0C76G0' }) $app) -ceq 'refuse' -and
    (Get-AppAction @(@{ name = 'OpenAI.Codex'; publisherId = '2p2nqsd0c76g0' }, @{ name = 'OpenAI.Codex'; publisherId = '2p2nqsd0c76g0' }) $app) -ceq 'refuse') 'Get-AppAction'
# ChatGPT app theme fonts (app-theme-fonts): the manifest's defaults make complete themes and fonts alone do not; an
# existing theme gets its three font leaves and loses only the Faces it has; the undo removes a created theme only
# while nobody changed it, and otherwise restores each leaf, keeping a recoloured theme valid; everything else of the
# user config is compared, the font leaves aside.
$appearanceApp = @($manifest.apps) | Where-Object { $null -ne $_.PSObject.Properties['appearance'] } | Select-Object -First 1
if ($null -eq $appearanceApp) { throw 'The proof needs the ChatGPT app''s appearance in the manifest.' }
$appearance = $appearanceApp.appearance
$plexCss, $monoCss = '"IBM Plex Sans JP"', '"PlemolJP Console NF"'
$appFonts = [ordered]@{ ui = $plexCss; code = $monoCss; content = $plexCss }
Must ($appearance.fonts.ui -ceq $plexCss -and $appearance.fonts.content -ceq $plexCss -and $appearance.fonts.code -ceq $monoCss -and
    $null -eq (Get-AppThemeProblem (New-AppTheme $appearance.defaults.light $appFonts)) -and $null -eq (Get-AppThemeProblem (New-AppTheme $appearance.defaults.dark $appFonts)) -and
    (Get-AppThemeProblem @{ fonts = $appFonts }) -like 'accent*' -and
    (Get-AppThemeProblem (New-AppTheme $appearance.defaults.dark @{ ui = 1; code = $null; content = $null })) -like 'fonts.ui*') 'app themes: complete defaults, font-only refused'
$face = @{ family = 'Segoe UI'; fullName = 'Segoe UI'; postscriptName = 'SegoeUI' }
$dark = '{"accent":"#3a83f7","accentSource":"chatgpt","contrast":60,"ink":"#ffffff","opaqueWindows":false,"surface":"#181818","semanticColors":{"diffAdded":"#40c977","diffRemoved":"#fa423e","skill":"#ad7bf9"},"fonts":{"content":"\"Segoe UI\"","contentFace":{"family":"Segoe UI","fullName":"Segoe UI","postscriptName":"SegoeUI"}}}' | ConvertFrom-Json
$darkEdits = Get-AppFontEdits 'appearanceDarkChromeTheme' $dark $appFonts $appearance.defaults.dark
$darkAfter = Get-AppThemeAfter 'appearanceDarkChromeTheme' $dark $darkEdits
Must ((@($darkEdits | ForEach-Object { "$($_.keyPath)=$(ConvertTo-CanonicalJson $_.value)" }) -join '|') -ceq
        'desktop.appearanceDarkChromeTheme.fonts.ui="\"IBM Plex Sans JP\""|desktop.appearanceDarkChromeTheme.fonts.code="\"PlemolJP Console NF\""|desktop.appearanceDarkChromeTheme.fonts.content="\"IBM Plex Sans JP\""|desktop.appearanceDarkChromeTheme.fonts.contentFace=null' -and
    @($darkEdits | Where-Object { $_.mergeStrategy -cne 'replace' }).Count -eq 0 -and $null -eq (Get-AppThemeProblem $darkAfter) -and
    (ConvertTo-CanonicalJson (Get-AppFontsState $darkAfter.fonts)) -ceq (ConvertTo-CanonicalJson $appFonts) -and $darkAfter.accent -ceq '#3a83f7' -and $darkAfter.contrast -eq 60) 'app fonts of an existing theme: font leaves only, its Face removed, colors kept'
$lightEdits = Get-AppFontEdits 'appearanceLightChromeTheme' $null $appFonts $appearance.defaults.light
Must ($lightEdits.Count -eq 1 -and $lightEdits[0].keyPath -ceq 'desktop.appearanceLightChromeTheme' -and $null -eq (Get-AppThemeProblem $lightEdits[0].value) -and
    $lightEdits[0].value.accentSource -ceq 'chatgpt' -and $lightEdits[0].value.surface -ceq '#ffffff') 'app fonts of an absent theme: the whole default theme'
# Records, classes and the undo of a leaf change and of a created theme.
$priorDark = [ordered]@{ exists = $true; fonts = (Get-AppFontsState $dark.fonts) }
$wantFonts = [ordered]@{ exists = $true; fonts = $appFonts }
$created = New-AppTheme $appearance.defaults.light $appFonts
$wantCreated = [ordered]@{ exists = $true; fonts = $appFonts; theme = $created }
$empty = [ordered]@{ exists = $true; fonts = [ordered]@{} }
function AppRecord($Seq, $Phase, $Target, $Prior, $Desired, $Observed) { $r = PureRecord $Seq $Phase app-theme-fonts $Target $Prior $Desired $Observed $null; $r.id = "app:$Target"; $r }
$darkTarget, $lightTarget = 'codex-config:desktop.appearanceDarkChromeTheme', 'codex-config:desktop.appearanceLightChromeTheme'
Must ($null -eq (Get-EffectRecordProblem (AppRecord 1 intent $darkTarget $priorDark $wantFonts $null)) -and
    $null -eq (Get-EffectRecordProblem (AppRecord 2 commit $lightTarget $empty $wantCreated $wantFonts)) -and
    (Get-EffectRecordProblem (AppRecord 1 intent $lightTarget $priorDark $wantCreated $null)) -ceq 'a created theme needs an empty prior.' -and
    (Get-EffectRecordProblem (AppRecord 1 intent $lightTarget $empty ([ordered]@{ exists = $true; fonts = $appFonts; theme = @{ fonts = $appFonts } }) $null)) -like 'desired.theme: accent*' -and
    (Get-EffectRecordProblem (AppRecord 1 intent $darkTarget $priorDark ([ordered]@{ exists = $true; fonts = [ordered]@{ ui = $plexCss; code = $monoCss; content = $plexCss; uiFace = $face } }) $null)) -ceq 'desired.fonts is not ui, code and content.' -and
    (Get-EffectRecordProblem (AppRecord 1 intent 'codex-config:desktop.appearanceTheme' $priorDark $wantFonts $null)) -like 'target*' -and
    (Get-EffectRecordProblem (AppRecord 1 intent $darkTarget $absent $wantFonts $null)) -ceq 'prior must exist.' -and
    (Get-EffectRecordProblem (AppRecord 1 intent $darkTarget $wantFonts $wantFonts $null)) -like 'desired equals prior*') 'app-theme-fonts records'
$darkNow = [ordered]@{ exists = $true; fonts = (Get-AppFontsState $darkAfter.fonts) }
$userFonts = [ordered]@{ exists = $true; fonts = [ordered]@{ ui = '"Meiryo UI"'; code = $monoCss; content = $plexCss } }
Must ((Get-UnownedClass app-theme-fonts $wantFonts $priorDark $null).class -ceq 'absent' -and (Get-UnownedClass app-theme-fonts $wantFonts $darkNow $null).class -ceq 'preexisting-match' -and
    (Get-EffectClass @((AppRecord 1 intent $darkTarget $priorDark $wantFonts $null), (AppRecord 2 commit $darkTarget $priorDark $wantFonts $darkNow)) $userFonts '' $null).class -ceq 'owned-drift' -and
    (Get-EffectClass @((AppRecord 1 intent $darkTarget $priorDark $wantFonts $null)) $priorDark '' $null).resolution -ceq 'void') 'app-theme-fonts classes'
$darkUndo = @(Get-UndoSteps (AppRecord 1 intent $darkTarget $priorDark $wantFonts $null))[0]
$darkUndoEdits = Get-AppFontUndoEdits $darkUndo $darkAfter
$darkBack = Get-AppThemeAfter 'appearanceDarkChromeTheme' $darkAfter $darkUndoEdits
Must ($darkUndo.action -ceq 'set-app-theme-fonts' -and $darkUndo.theme -ceq 'appearanceDarkChromeTheme' -and
    (ConvertTo-CanonicalJson $darkBack) -ceq (ConvertTo-CanonicalJson $dark)) 'app fonts undo: the prior leaves and Face object back, nothing else'
$lightUndo = @(Get-UndoSteps (AppRecord 1 intent $lightTarget $empty $wantCreated $null))[0]
$recoloured = ($created | ConvertTo-Json -Depth 5 | ConvertFrom-Json)
$recoloured.accent = '#ff0000'
$recolouredBack = Get-AppThemeAfter 'appearanceLightChromeTheme' $recoloured (Get-AppFontUndoEdits $lightUndo $recoloured)
$unchangedUndo = Get-AppFontUndoEdits $lightUndo ($created | ConvertTo-Json -Depth 5 | ConvertFrom-Json)  # one array: the edits of one batch
$unchangedUndo = @($unchangedUndo | ForEach-Object { "$($_.keyPath)=$(ConvertTo-CanonicalJson $_.value)" }) -join '|'
Must ($unchangedUndo -ceq 'desktop.appearanceLightChromeTheme=null' -and
    $recolouredBack.accent -ceq '#ff0000' -and $null -eq (Get-AppThemeProblem $recolouredBack) -and @((Get-AppFontsState $recolouredBack.fonts).Keys).Count -eq 0) 'app fonts undo: a created theme goes whole only unchanged; recoloured, it keeps its colors, stays valid and loses the fonts'
# The rest of the user config: font leaves and a created theme aside, any other change shows; key order does not.
$config = '{"model":"m","desktop":{"appearanceTheme":"dark","codeFontSize":17,"appearanceDarkChromeTheme":{"accent":"#3a83f7","fonts":{"content":"x","other":"keep"}}},"z":{"b":1,"a":[1,"two"]}}' | ConvertFrom-Json
$keys = @(Get-AppThemeKeys)
$restBefore = Get-AppConfigRest $config $keys @()
$fontOnly = ($config | ConvertTo-Json -Depth 8 | ConvertFrom-Json); $fontOnly.desktop.appearanceDarkChromeTheme.fonts.content = 'y'
$fontOnly.desktop | Add-Member -NotePropertyName appearanceLightChromeTheme -NotePropertyValue ([pscustomobject]@{ accent = '#339cff' })
$reordered = '{"z":{"a":[1,"two"],"b":1},"desktop":{"codeFontSize":17,"appearanceTheme":"dark","appearanceDarkChromeTheme":{"fonts":{"other":"keep","content":"x"},"accent":"#3a83f7"}},"model":"m"}' | ConvertFrom-Json
$otherLeaf = ($config | ConvertTo-Json -Depth 8 | ConvertFrom-Json); $otherLeaf.desktop.appearanceDarkChromeTheme.fonts.other = 'changed'
$mode = ($config | ConvertTo-Json -Depth 8 | ConvertFrom-Json); $mode.desktop.appearanceTheme = 'light'
$caseKeys = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal); $caseKeys['b'] = 1; $caseKeys['A'] = 2; $caseKeys['a'] = 3  # TOML keys keep case
Must ((Get-AppConfigRest $fontOnly $keys @('appearanceLightChromeTheme')) -ceq $restBefore -and (Get-AppConfigRest $reordered $keys @()) -ceq $restBefore -and
    (Get-AppConfigRest $fontOnly $keys @()) -cne $restBefore -and (Get-AppConfigRest $otherLeaf $keys @()) -cne $restBefore -and (Get-AppConfigRest $mode $keys @()) -cne $restBefore -and
    (ConvertTo-CanonicalJson $caseKeys) -ceq '{"A":2,"a":3,"b":1}') 'app config rest: only the font leaves and a created theme are set aside'
# Numbers compare by kind and exact value: floats round-trip ('R', not G15), 60 is not 60.0, int64 max stays exact; the
# layers' serde numbers keep integer or float and their range.
function SerdeNumber([string]$Text) { ConvertFrom-LayerNumbers ('{"$serde_json::private::Number":"' + $Text + '"}' | ConvertFrom-Json) }
Must ((ConvertTo-CanonicalJson (0.1 + 0.2)) -cne (ConvertTo-CanonicalJson 0.3) -and (ConvertTo-CanonicalJson 60) -ceq '60' -and (ConvertTo-CanonicalJson 60.0) -ceq '60.0' -and
    (ConvertTo-CanonicalJson ([long]::MaxValue)) -ceq '9223372036854775807' -and (ConvertTo-CanonicalJson ([double][long]::MaxValue)) -cne '9223372036854775807' -and
    (ConvertTo-CanonicalJson (SerdeNumber '60')) -ceq '60' -and (ConvertTo-CanonicalJson (SerdeNumber '60.0')) -ceq '60.0' -and
    (ConvertTo-CanonicalJson (SerdeNumber '9223372036854775807')) -ceq '9223372036854775807' -and (ConvertTo-CanonicalJson (SerdeNumber '18446744073709551615')) -ceq '18446744073709551615' -and
    (ConvertTo-CanonicalJson (SerdeNumber '0.30000000000000004')) -ceq (ConvertTo-CanonicalJson (0.1 + 0.2)) -and (ConvertTo-CanonicalJson ([decimal]::Parse('60.0', [Globalization.CultureInfo]::InvariantCulture))) -ceq '60.0') 'canonical numbers keep kind and exact value'
# Chromium font preferences: the scan refuses what is not one plain JSON object or repeats a key (also through an escape);
# the edit inserts only the six leaves and its undo restores the exact bytes; pref-value records and overlaps.
$scanRefused = @('{"c":1,"\u0063":2}', '{"a":1,}', '{"a":[1,]}', '[1]', '{} {}', '{"a":01}', "{`"a`":`"x`ty`"}", '' | Where-Object { try { $null = Get-JsonScan $_; $false } catch { $true } })
$prefsText = '{ "n": [9223372036854775807, 1.7976931348623157e+308, 5e-324, 1e+05, 12345678901234567890], "C": 1, "c": 2, "a\"b": "caf\u00e9",' +
    ' "webkit": { "webprefs": { "fonts": { "standard": { "Zyyy": "x" } } } } }'
$prefsValues = [ordered]@{}
foreach ($leaf in Get-ChromiumFontLeaves) { if ($leaf -cne 'webkit.webprefs.fonts.standard.Zyyy') { $prefsValues[$leaf] = 'IBM Plex Sans JP' } }
$prefsEdit = Get-PrefsFontEdit $prefsText (Get-JsonScan $prefsText) $prefsValues
$prefsBack = $prefsEdit.text
foreach ($leaf in $prefsValues.Keys) { $prefsBack = Get-PrefsFontUndo $prefsBack $leaf $prefsEdit.created[$leaf] }
$prefsAt = Resolve-JsonPath (Get-JsonScan $prefsEdit.text) 'webkit.webprefs.fonts.fixed.Jpan'
Must ($scanRefused.Count -eq 8 -and $prefsBack -ceq $prefsText -and $prefsEdit.text.StartsWith($prefsText.Substring(0, $prefsText.IndexOf('"webkit"'))) -and
    (ConvertFrom-JsonString $prefsEdit.text.Substring($prefsAt.member.valueStart, $prefsAt.member.valueEnd - $prefsAt.member.valueStart)) -ceq 'IBM Plex Sans JP' -and
    (@($prefsEdit.created['webkit.webprefs.fonts.fixed.Jpan']) -join '|') -ceq 'webkit.webprefs.fonts.fixed' -and @($prefsEdit.created['webkit.webprefs.fonts.standard.Jpan']).Count -eq 0 -and
    (ConvertTo-JsonString "a`"b\c`n") -ceq '"a\"b\\c\u000a"') 'Chromium preferences: strict scan, six-leaf edit, exact undo'
$prefRecord = @{ ledger = 'effects'; schema = 1; seq = 1; phase = 'intent'; id = 'p'; kind = 'pref-value'; target = 'C:\u\User Data\Default\Preferences'; name = 'webkit.webprefs.fonts.fixed.Jpan'
    prior = $absent; desired = @{ exists = $true; value = 'PlemolJP Console NF'; created = @('webkit.webprefs.fonts.fixed') } }
function PrefVariant([hashtable]$Change) { $r = $prefRecord.Clone(); foreach ($k in $Change.Keys) { $r[$k] = $Change[$k] }; $r }
$otherLeaf = PrefVariant @{ name = 'webkit.webprefs.fonts.fixed.Zyyy' }
Must ($null -eq (Get-EffectRecordProblem $prefRecord) -and
    (Get-EffectRecordProblem (PrefVariant @{ name = 'webkit.webprefs.default_font_size' })) -ceq 'name is not a Chromium font leaf.' -and
    (Get-EffectRecordProblem (PrefVariant @{ prior = @{ exists = $true; value = 'x' } })) -ceq 'prior must be absent.' -and
    (Get-EffectRecordProblem (PrefVariant @{ desired = @{ exists = $true; value = 'x'; created = @('webkit.other') } })) -ceq 'desired.created is not a list of parents of name.' -and
    -not (Test-TargetOverlap $prefRecord $otherLeaf) -and (Test-TargetOverlap $prefRecord $prefRecord) -and
    (Get-UnownedClass pref-value $prefRecord.desired @{ exists = $true; value = 'Meiryo' } $null).class -ceq 'preexisting-drift')'pref-value records: six leaves only, prior absent, parents of the leaf; leaves of one file have separate owners'
Must ((@(Get-CssFamilies '"IBM Plex Sans JP", ''Segoe UI'' , monospace') -join '|') -ceq 'IBM Plex Sans JP|Segoe UI|monospace') 'CSS families of an app font'
# P1b-lite: the plan groups the ledger by id in one pass and validates each id once (Get-EffectAttempt), with the
# plan unchanged: interleaved attempts; a reverted and a voided id kept; a malformed id refused; ids that differ
# only in case refuse the whole plan before any validation.
function PlanRecord($Seq, $Id, $Phase, $Target, $Observed) {
    $r = PureRecord $Seq $Phase file-created $Target $absent @{ exists = $true; sha256 = (Sha a) } $Observed $null; $r.id = $Id; $r
}
$planMade = @{ exists = $true; sha256 = (Sha a) }
$planLedger = @((PlanRecord 1 f1 intent 'C:\u\a' $null), (PlanRecord 2 f2 intent 'C:\u\b' $null), (PlanRecord 3 f1 commit 'C:\u\a' $planMade),
    (PlanRecord 4 f2 commit 'C:\u\b' $planMade), (PlanRecord 5 f3 intent 'C:\u\c' $null), (PlanRecord 6 f3 void 'C:\u\c' $absent))
$planMalformed = @((PlanRecord 7 m intent 'C:\u\m' $null), (PlanRecord 8 m commit 'C:\u\m' $planMade), (PlanRecord 9 m void 'C:\u\m' $absent))
$planSeen = @{ f1 = $planMade; f2 = $absent; f3 = $absent; m = $absent }
$script:validateAttempt, $script:attemptsValidated = ${function:Get-EffectAttempt}, 0
try {
    ${function:Get-EffectAttempt} = { $script:attemptsValidated++; & $script:validateAttempt @args }
    $planOk = Get-UninstallPlan $planLedger $planSeen; $okValidated = $script:attemptsValidated; $script:attemptsValidated = 0
    $planBad = Get-UninstallPlan ($planLedger + $planMalformed) $planSeen; $badValidated = $script:attemptsValidated; $script:attemptsValidated = 0
    $planCased = Get-UninstallPlan ($planLedger + @(PlanRecord 10 F1 intent 'C:\u\z' $null)) $planSeen; $casedValidated = $script:attemptsValidated
} finally { ${function:Get-EffectAttempt} = $script:validateAttempt }
Must ($okValidated -eq 3 -and $badValidated -eq 4 -and $casedValidated -eq 0) "P1b-lite: one validation per id ($okValidated, $badValidated, $casedValidated)"
Must ($planOk.ok -and (Actions $planOk) -ceq 'delete-file' -and @($planOk.steps)[0].id -ceq 'f1' -and
    (@($planOk.resolutions | ForEach-Object { "$($_.id):$($_.resolution)" }) -join ',') -ceq 'f2:undone' -and
    (@($planOk.kept | ForEach-Object { $_.id } | Sort-Object) -join ',') -ceq 'f2,f3' -and
    -not $planBad.ok -and @($planBad.steps).Count -eq 0 -and (@($planBad.refused | ForEach-Object { "$($_.id):$($_.class)" }) -join ',') -ceq 'm:indeterminate' -and
    -not $planCased.ok -and @($planCased.refused)[0].reason -ceq 'Two ids differ only in case.') 'P1b-lite: the plan is unchanged'
# The temporary path an intent names: only <target>.<guid32>.tmp (file) or .staging (tree).
$guid = '0123456789abcdef' * 2
foreach ($case in @(@('file-created', 'C:\u\f.ttf', "C:\u\f.ttf.$guid.tmp", $true), @('tree-extracted', 'C:\u\t', "C:\u\t.$guid.staging", $true),
        @('file-created', 'C:\u\f.ttf', "C:\u\f.ttf.$guid.staging", $false), @('tree-extracted', 'C:\u\t', "C:\u\t.$guid.tmp", $false),
        @('tree-extracted', 'C:\u\t', "C:\v\t.$guid.staging", $false), @('tree-extracted', 'C:\u\t', "C:\u\t.$($guid.ToUpperInvariant()).staging", $false),
        @('registry-key-created', $clsid, "$clsid.$guid.tmp", $false))) {
    Must ($null -eq (Get-IntentTempProblem @{ kind = $case[0]; target = $case[1]; temp = $case[2] }) -eq $case[3]) "temp $($case[2]) for $($case[0])"
}
# Staging cleanup deletes only what the tree intent's inventory names, deepest directory first.
$treeIntent = PureRecord 1 intent tree-extracted 'C:\u\t' $absent @{ exists = $true; files = @{ 'a.txt' = (Sha a); 'd/b.txt' = (Sha b) } } $null $null
$treeIntent.temp = "C:\u\t.$guid.staging"
$cleanup = Get-StagingCleanupSteps $treeIntent @(@{ path = 'a.txt'; directory = $false }, @{ path = 'd'; directory = $true }, @{ path = 'd/b.txt'; directory = $false })
Must ($cleanup.ok -and (@($cleanup.steps | ForEach-Object { "$($_.action) $($_.path)" }) -join ';') -ceq
    "delete-file C:\u\t.$guid.staging\a.txt;delete-file C:\u\t.$guid.staging\d\b.txt;remove-empty-directory C:\u\t.$guid.staging\d;remove-empty-directory C:\u\t.$guid.staging") 'staging cleanup order'
Must ((Get-StagingCleanupSteps $treeIntent @(@{ path = 'a.txt'; directory = $false })).ok) 'a partial staging directory is cleaned'
foreach ($observed in @(@(@{ path = 'x.txt'; directory = $false }), @(@{ path = 'e'; directory = $true }), @(@{ path = '../a.txt'; directory = $false }))) {
    Must (-not (Get-StagingCleanupSteps $treeIntent $observed).ok) "staging entry $($observed[0].path) is not removed"
}
$committed = $treeIntent.Clone(); $committed.phase = 'commit'
$foreign = $treeIntent.Clone(); $foreign.temp = "C:\u\other.$guid.staging"
Must (-not (Get-StagingCleanupSteps $committed @()).ok -and -not (Get-StagingCleanupSteps $foreign @()).ok) 'only an intent-named staging directory is cleaned'
foreach ($files in @('not a map', @{})) {
    $bad = $treeIntent.Clone(); $bad.desired = @{ exists = $true; files = $files }
    Must (-not (Get-StagingCleanupSteps $bad @(@{ path = 'a.txt'; directory = $false })).ok) 'a malformed or empty inventory cleans nothing'
}
$twice = Get-StagingCleanupSteps $treeIntent @(@{ path = 'a.txt'; directory = $false }, @{ path = 'A.TXT'; directory = $false })
Must ($twice.ok -and @($twice.steps).Count -eq 2) 'an entry observed twice is removed once'
Must (-not (Get-StagingCleanupSteps $treeIntent @(@{ path = 'd'; directory = $true; reparse = $true })).ok) 'a reparse point stops staging cleanup'
# A record may name only the temporary path its intent could have made, and only on the intent.
$fileIntent = PureRecord 1 intent file-created 'C:\u\f.ttf' $absent @{ exists = $true; sha256 = (Sha a) } $null $null
$fileIntent.temp = "C:\u\f.ttf.$guid.tmp"
Must ($null -eq (Get-EffectRecordProblem $fileIntent) -and $null -eq (Get-EffectRecordProblem $treeIntent)) 'valid intent temps'
$fileIntent.Remove('temp')
Must ($null -eq (Get-EffectRecordProblem $fileIntent)) 'an intent without a temp'
$fileIntent.temp = 'C:\evil'
Must ($null -ne (Get-EffectRecordProblem $fileIntent)) 'a foreign temp path is a malformed intent'
$fileCommit = PureRecord 2 commit file-created 'C:\u\f.ttf' $absent @{ exists = $true; sha256 = (Sha a) } @{ exists = $true; sha256 = (Sha a) } $null
$fileCommit.temp = "C:\u\f.ttf.$guid.tmp"
$valueIntent = PureRecord 1 intent registry-value 'HKCU\Software\W' $absent @{ exists = $true; type = 'String'; data = 'x' } $null 'v'
$valueIntent.temp = "HKCU\Software\W.$guid.tmp"
Must ($null -ne (Get-EffectRecordProblem $fileCommit) -and $null -ne (Get-EffectRecordProblem $valueIntent)) 'a temp on a commit or a value intent'
# Legacy %%Startup rollback resumes an interruption in either direction, Terminal first.
function Legacy($PriorConsole, $PriorTerminal, $Selects) {
    @{ schema = 1; key = 'HKCU\Console\%%Startup'; priorDelegationConsole = $PriorConsole; priorDelegationTerminal = $PriorTerminal
        priorSelectsNoctty = $Selects; written = @{ DelegationConsole = $wtConsole; DelegationTerminal = $noctty } }
}
function LegacyPlan($Record, $Console, $Terminal) {
    $p = Get-LegacyTerminalPlan $Record @{ console = $Console; terminal = $Terminal }
    "$($p.action):$(@(if ($p.Contains('steps')) { $p.steps | ForEach-Object { $_.name } }) -join ',')"
}
$clean = Legacy $null $null $false
Must ((LegacyPlan $clean $wtConsole $noctty) -ceq 'restore:DelegationTerminal,DelegationConsole') 'both written'
Must ((LegacyPlan $clean $wtConsole $null) -ceq 'restore:DelegationConsole') 'console written, terminal already prior'
Must ((LegacyPlan $clean $null $noctty) -ceq 'restore:DelegationTerminal') 'terminal written, console already prior'
Must ((LegacyPlan $clean $null $null) -ceq 'none:') 'both prior'
Must ((LegacyPlan $clean $wtConsole $terminal) -ceq 'refuse:') 'a value that is neither prior nor written'
Must ((LegacyPlan (Legacy $wtConsole $null $false) $wtConsole $noctty) -ceq 'restore:DelegationTerminal') 'a prior equal to written counts as prior'
Must ((LegacyPlan (Legacy $wtConsole $noctty $true) $wtConsole $noctty) -ceq 'report:') 'original unknown'
foreach ($result in @((Get-LegacyTerminalPlan $clean @{ console = $null; terminal = $null }), (Get-LegacyTerminalPlan (Legacy $wtConsole $noctty $true) @{}),
        (Get-LegacyTerminalPlan @{ schema = 1 } @{}), (Get-LegacyTerminalPlan $clean @{ console = 1; terminal = $null }))) {
    Must (@($result.steps).Count -eq 0) "a $($result.action) plan still has (empty) steps"
}
# A machine-wide Noctty (either CLSID in either HKLM view, or an Uninstall name) is recognized.
Must ($null -ne (Get-MachineNocttyReason @("Registry32\SOFTWARE\Classes\CLSID\$noctty") @()) -and
    $null -ne (Get-MachineNocttyReason @() @('Noctty 1.3.131')) -and
    $null -eq (Get-MachineNocttyReason @('Registry64\SOFTWARE\Classes\CLSID\{00000000-0000-0000-0000-000000000000}') @('Windows Terminal'))) 'machine-wide Noctty'
# The built registration binds {install} and derives exactly the ten keys CI #58 created below the shared roots.
$install = 'C:\u\Programs\noctty-1'
$registration = Get-NocttyRegistration $manifest.noctty.registration $install $manifest.noctty.files
$proxyClsid = '{1D349824-21FB-46C7-ACF3-746EDC991D52}'
$tenKeys = @("Software\Classes\CLSID\$noctty", "Software\Classes\CLSID\$noctty\LocalServer32",
    "Software\Classes\CLSID\$proxyClsid", "Software\Classes\CLSID\$proxyClsid\InprocServer32") +
    @('{59D55CCE-FC8A-48B4-ACE8-0A9286C6557F}', '{6F23DA90-15C5-4203-9DB0-64E73F1B1B00}', '{AA6B364F-4A50-4176-9002-0AE755E7B5EF}' |
        ForEach-Object { "Software\Classes\Interface\$_"; "Software\Classes\Interface\$_\ProxyStubClsid32" })
Must ($null -eq $registration.problem -and @($registration.values).Count -eq 6 -and
    (@($registration.keys | Sort-Object) -join ';') -ceq (@($tenKeys | Sort-Object) -join ';')) 'six values and the ten derived keys'
$bound = @($registration.values | ForEach-Object { "$($_.key)|$($_.name)=$($_.data)" })
Must ($bound -ccontains "Software\Classes\CLSID\$noctty\LocalServer32|=`"$install\noctty\noctty.exe`"" -and
    $bound -ccontains "Software\Classes\CLSID\$proxyClsid\InprocServer32|=$install\noctty\noctty-terminal-handoff-proxy.dll" -and
    $bound -ccontains "Software\Classes\CLSID\$proxyClsid\InprocServer32|ThreadingModel=Both") '{install} bound, ThreadingModel kept'
# Malformed registrations are refused as a whole.
$row = @{ key = "Software\Classes\CLSID\$noctty\LocalServer32"; name = ''; data = '"{install}\noctty\noctty.exe"' }
$files = @{ 'noctty/noctty.exe' = (Sha a) }
function Variant([hashtable]$Change) { $r = $row.Clone(); foreach ($k in $Change.Keys) { if ($null -eq $Change[$k]) { $r.Remove($k) } else { $r[$k] = $Change[$k] } }; $r }
Must ($null -eq (Get-NocttyRegistration @($row) $install $files).problem) 'a valid row'
foreach ($case in @(@('empty', @()), @('duplicate', @($row, (Variant @{ key = $row.key.ToUpperInvariant().Replace('SOFTWARE\CLASSES\CLSID', 'Software\Classes\CLSID') }))),
        @('two spellings of one key', @($row, (Variant @{ key = "Software\Classes\CLSID\$noctty\localserver32\X"; data = 'x' }))),
        @('shared root', @(Variant @{ key = 'Software\Classes\CLSID' })), @('other root', @(Variant @{ key = "Software\Classes\AppID\$noctty" })),
        @('lowercase GUID', @(Variant @{ key = "Software\Classes\CLSID\$($noctty.ToLowerInvariant())" })),
        @('extra field', @(Variant @{ type = 'String' })), @('missing field', @(Variant @{ name = $null })), @('not a string', @(Variant @{ data = 1 })),
        @('install in key', @(Variant @{ key = "Software\Classes\CLSID\$noctty\{install}" })), @('install not first', @(Variant @{ data = 'x {install}\noctty\noctty.exe' })),
        @('not an inventory file', @(Variant @{ data = '{install}\noctty\noctty.com' })), @('unbalanced quote', @(Variant @{ data = '{install}\noctty\noctty.exe"' })),
        @('empty data', @(Variant @{ data = '' })))) {
    $refused = Get-NocttyRegistration $case[1] $install $files
    Must ($refused.problem -and -not @($refused.values).Count -and -not @($refused.keys).Count) "registration refuses: $($case[0])"
}
Must ([bool](Get-NocttyRegistration @($row) 'Programs\noctty-1' $files).problem) 'a relative install path is refused'
# An observed tree's other entries (reparse points, empty directories, unsafe names) make it differ.
$tree = @{ exists = $true; files = @{ 'a.txt' = (Sha a) } }
Must ((Test-EffectStateEqual tree-extracted $tree @{ exists = $true; files = @{ 'A.TXT' = (Sha a) }; other = @() }) -and
    -not (Test-EffectStateEqual tree-extracted $tree @{ exists = $true; files = @{ 'a.txt' = (Sha a) }; other = @('e/') }) -and
    (Get-UnownedClass tree-extracted $tree @{ exists = $true; files = $tree.files; other = @('j') } $null).class -ceq 'preexisting-drift') 'tree other entries'
Must ($null -ne (Get-EffectRecordProblem (PureRecord 1 intent tree-extracted 'C:\u\t' $absent @{ exists = $true; files = $tree.files; other = @('e/') } $null $null))) 'a desired tree has no other entries'
# D1: a partly removed owned tree resumes while its files are exact and only inventory directories
# are left empty; anything else is refused. The whole tree keeps its order.
$treeOwned = @{ kind = 'tree-extracted'; target = 'C:\u\t'; desired = @{ exists = $true; files = @{ 'a.txt' = (Sha a); 'd/b.txt' = (Sha b); 'd/e/c.txt' = (Sha c) } } }
function TreeSteps($Steps) { if ($null -eq $Steps) { 'refused' } else { @($Steps | ForEach-Object { $_.path.Replace('C:\u\t', 't') + $(if ($_.action -ceq 'delete-file') { '' } else { '/' }) }) -join ';' } }
function Resume($Files, $Other) { TreeSteps (Get-TreeUndoSteps $treeOwned @{ exists = $true; files = $Files; other = $Other }) }
Must ((TreeSteps @(Get-UndoSteps $treeOwned)) -ceq 't\a.txt;t\d\b.txt;t\d\e\c.txt;t\d\e/;t\d/;t/' -and
    (Resume @{ 'd/b.txt' = (Sha b) } @('d/e/')) -ceq 't\d\b.txt;t\d\e/;t\d/;t/' -and (Resume @{} @('d/', 'd/e/')) -ceq 't\d\e/;t\d/;t/' -and
    (Resume @{} @()) -ceq 't/') 'a partly removed tree resumes'
foreach ($case in @(@(@{ 'a.txt' = (Sha x) }, @()), @(@{ 'x.txt' = (Sha a) }, @()), @(@{}, @('j')), @(@{}, @('f/')), @(@{}, @('d/e')))) {
    Must ((Resume $case[0] $case[1]) -ceq 'refused') "a tree with $(@($case[0].Keys) + $case[1] -join ',') does not resume"
}
$treeRecords = @(Owned 1 t tree-extracted 'C:\u\t' $treeOwned.desired $null)
$plan = Get-UninstallPlan $treeRecords @{ t = @{ exists = $true; files = @{ 'd/b.txt' = (Sha b) }; other = @() } }
Must ($plan.ok -and ($plan.resumed -join ',') -ceq 't' -and @($plan.steps | Where-Object { $_.kind -ceq 'tree-extracted' -and $_.id -ceq 't' }).Count -eq 3 -and
    -not (Get-UninstallPlan $treeRecords @{ t = @{ exists = $true; files = @{ 'a.txt' = (Sha x) }; other = @() } }).ok) 'the plan resumes a partly removed tree only'
# D3: a COM server path the plan does not remove keeps the tree; unparseable data counts when it names the tree.
$comTree = "$env:SystemDrive\u\Programs\noctty-1"
function Guard($Data, $Removed) { [bool](Get-TreeReferenceProblem @(@{ label = 'HKCU\L'; id = 'v'; data = $Data }) $comTree $Removed) }
Must ((Guard "`"$comTree\noctty\noctty.exe`" -Embedding" @()) -and (Guard '%SystemDrive%\u\Programs\NOCTTY-1\noctty\x.dll' @()) -and
    -not (Guard "$comTree\noctty\x.dll" @('v')) -and -not (Guard "$($comTree)x\noctty.exe" @()) -and -not (Guard '{1D349824-21FB-46C7-ACF3-746EDC991D52}' @()) -and
    (Guard "$comTree\noctty.exe`0x" @()) -and -not (Guard "C:\other`0x" @())) 'COM references to the tree'
# F-1: font collection considers only font effects, never an owned Noctty tree, config or COM effect.
. ([scriptblock]::Create([Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'win.ps1'), [ref]$null, [ref]$null).Find(
    { param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq 'IsFontEffect' }, $false).Extent.Text))
& {
    $fontDirectory, $fontKey = 'C:\u\Fonts', 'HKCU\Software\Microsoft\Windows NT\CurrentVersion\Fonts'
    $font = @(@{ kind = 'file-created'; target = "C:\u\Fonts\$(Sha a).ttf" }, @{ kind = 'registry-value'; target = $fontKey; name = 'X (TrueType)' })
    $other = @(@{ kind = 'tree-extracted'; target = 'C:\u\Programs\noctty-1' }, @{ kind = 'file-created'; target = 'C:\u\noctty\config.ghostty' },
        @{ kind = 'registry-value'; target = "HKCU\Software\Classes\CLSID\$noctty\LocalServer32"; name = '' },
        @{ kind = 'registry-key-created'; target = "HKCU\Software\Classes\CLSID\$noctty" }, @{ kind = 'file-created'; target = 'C:\u\Fonts\sub\x.ttf' },
        @{ kind = 'registry-key-created'; target = $fontKey })
    Must (@($font | Where-Object { IsFontEffect $_ }).Count -eq 2 -and -not @($other | Where-Object { IsFontEffect $_ }).Count) 'font collection candidates'
}
# A3: a created key the plan removes may hold only what the plan, or the selection rollback, removes.
$a3Steps = @([ordered]@{ action = 'delete-registry-value'; key = 'HKCU\A\B'; name = '' }, [ordered]@{ action = 'delete-empty-key'; key = 'HKCU\A\B' },
    [ordered]@{ action = 'delete-empty-key'; key = 'HKCU\A' }, [ordered]@{ action = 'delete-empty-key'; key = 'HKCU\Console\%%Startup' })
$a3Clean = @{ 'HKCU\A\B' = @{ values = @(''); subkeys = @() }; 'HKCU\A' = @{ values = @(); subkeys = @('b') }
    'HKCU\Console\%%Startup' = @{ values = @('DelegationConsole'); subkeys = @() } }
$a3Dirty = @{ 'HKCU\A\B' = @{ values = @('', 'X'); subkeys = @() }; 'HKCU\A' = @{ values = @(); subkeys = @('B', 'C') }
    'HKCU\Console\%%Startup' = @{ values = @('DelegationConsole'); subkeys = @() } }
Must (-not @(Get-ForeignKeyContent $a3Steps $a3Clean @{ 'HKCU\Console\%%Startup' = @('DelegationConsole') }).Count -and
    @(Get-ForeignKeyContent $a3Steps $a3Dirty @{}).Count -eq 3) 'A3: foreign key content'
# A failed run's rollback: only what this run wrote, back to what it read just before (not the
# write-once record's older prior), Terminal first; a planned write that never landed is skipped
# (a failure between the two writes); a value changed by anyone else refuses it.
function Sel($Console, $Terminal) { @{ console = $Console; terminal = $Terminal } }
function Rollback($Before, $Written, $Current) {
    $r = Get-SelectionRollbackSteps $Before $Written $Current
    if (-not $r.ok) { 'refused' } else { @($r.steps | ForEach-Object { "$($_.name)=$($_.value)" }) -join ';' }
}
$both = @{ DelegationConsole = $wtConsole; DelegationTerminal = $noctty }
Must ((Rollback (Sel $wtConsole $terminal) @{ DelegationTerminal = $noctty } (Sel $wtConsole $noctty)) -ceq "DelegationTerminal=$terminal" -and  # the user's own choice
    (Rollback (Sel $null $null) $both (Sel $wtConsole $noctty)) -ceq 'DelegationTerminal=;DelegationConsole=' -and          # both landed
    (Rollback (Sel $null $null) $both (Sel $wtConsole $null)) -ceq 'DelegationConsole=' -and                              # only the first landed
    (Rollback (Sel $null $null) $both (Sel $null $null)) -ceq '' -and                                                     # neither landed
    (Rollback (Sel $null $null) $both (Sel $wtConsole $terminal)) -ceq 'refused' -and                                     # a foreign Terminal
    (Rollback (Sel $null $null) $both (Sel $terminal $noctty)) -ceq 'refused' -and                                       # a foreign Console
    (Rollback (Sel $wtConsole $noctty) @{} (Sel $wtConsole $noctty)) -ceq '') 'selection rollback of one run'
# S2-1 R1: protected data is ours only after a committed attempt whose intent names exactly this package (any version).
$pkgDesired = @{ exists = $true; files = @{ 'Chrome-bin/chrome.exe' = (Sha a); 'Chrome-bin/d/x.dll' = (Sha b) } }
function PackageRecords($Seq, [string]$Leaf, $Package, [string[]]$Phases, [string]$Parent = 'C:\u\Programs') {
    $target = "$Parent\$Leaf"
    foreach ($phase in $Phases) {
        $r = PureRecord $Seq $phase tree-extracted $target $absent $pkgDesired $(switch ($phase) { 'intent' { $null } 'commit' { $pkgDesired } default { $absent } }) $null
        $r.id = 'tree-extracted:' + $target.ToUpperInvariant()
        if ($phase -ceq 'intent' -and $Package) { $r.package = $Package }
        $Seq++; $r
    }
}
$programs = 'C:\u\Programs'
function Hist($Records, [string]$Package = 'Chromium', [string]$Within = $programs) { Test-PackageHistory $Records $Package $Within }
Must ((Hist @(PackageRecords 1 'chromium-153' 'Chromium' @('intent', 'commit', 'undone'))) -and                 # an older version, removed
    (Hist @(PackageRecords 1 'chromium-154' 'Chromium' @('intent', 'commit'))) -and                              # open
    (Hist (@(PackageRecords 1 'chromium-154' 'Chromium' @('intent', 'void')) + @(PackageRecords 3 'chromium-154' 'Chromium' @('intent', 'commit')))) -and
    (Hist @(PackageRecords 1 'chromium-153' 'Chromium' @('intent', 'commit', 'undone')) 'Chromium' "$programs\") -and   # a trailing '\' on Programs
    -not (Hist @(PackageRecords 1 'chromium-154' 'Chromium' @('intent', 'void'))) -and                          # void only
    -not (Hist @(PackageRecords 1 'chromium-extra-1' 'Chromium-extra' @('intent', 'commit'))) -and              # another package
    -not (Hist @(PackageRecords 1 'chromium-154' $null @('intent', 'commit'))) -and                               # no package field
    -not (Hist @(PackageRecords 1 'chromium-154' 'chromium' @('intent', 'commit'))) -and                          # not exactly the name
    -not (Hist (@(PackageRecords 1 'chromium-154' 'Other' @('intent', 'commit', 'undone')) + @(PackageRecords 4 'chromium-154' 'Chromium' @('intent', 'void')))) -and
    -not (Hist @(PackageRecords 1 'chromium-154' 'Chromium' @('intent', 'commit')) '')) 'R1 package history'
# The reader's own guard (R's reproduced false positives): a Chromium intent on another package's tree, the right
# name in the wrong folder, or no Programs at all proves nothing; a package field on a commit is a malformed record.
$onNoctty = @(PackageRecords 1 'noctty-1.3.131' 'Chromium' @('intent', 'commit'))
$onAutoHotkey = @(PackageRecords 1 'autohotkey-2.0.28' 'Chromium' @('intent', 'commit'))
$elsewhere = @(PackageRecords 1 'chromium-154.0.8037.58' 'Chromium' @('intent', 'commit') 'C:\elsewhere')
$packageOnCommit = @(PackageRecords 1 'chromium-154' 'Chromium' @('intent', 'commit')); $packageOnCommit[1].package = 'Chromium'
Must (-not (Hist $onNoctty) -and -not (Hist $onAutoHotkey) -and -not (Hist $elsewhere) -and -not (Hist $packageOnCommit) -and
    -not (Hist @(PackageRecords 1 'chromium-154' 'Chromium' @('intent', 'commit')) 'Chromium' '') -and
    $null -ne (Get-EffectRecordProblem $onNoctty[0]) -and $null -ne (Get-EffectRecordProblem $onAutoHotkey[0]) -and
    $null -eq (Get-EffectRecordProblem $elsewhere[0]) -and $null -ne (Get-EffectRecordProblem $packageOnCommit[1]) -and
    (Test-PackageTarget "$programs\chromium-154" 'Chromium' $programs) -and -not (Test-PackageTarget "$programs\x\chromium-154" 'Chromium' $programs) -and
    (Test-PackageTarget 'C:\elsewhere\chromium-154' 'Chromium') -and -not (Test-PackageTarget 'C:\elsewhere\chromium-154' 'Chromium' $programs) -and
    -not (Test-PackageTarget "$programs\chromium-154" 'Chromium' '') -and -not (Test-PackageTarget "$programs\chromium-154" 'Chromium' $null) -and
    -not (Test-PackageTarget "$programs\chromium-154" 1 $programs)) 'R1 reader guard'
# Only a valid history counts: a malformed closing record, a commit of another effect, or a repeated
# seq (within the id or across the ledger) makes a committed-looking attempt prove nothing.
$malformed = @(PackageRecords 1 'chromium-154' 'Chromium' @('intent', 'commit', 'undone')); $malformed[2].schema = 2
$changed = @(PackageRecords 1 'chromium-154' 'Chromium' @('intent', 'commit'))
$changed[1].desired = @{ exists = $true; files = @{ 'Chrome-bin/chrome.exe' = (Sha c) } }; $changed[1].observed = $changed[1].desired
$repeated = @(PackageRecords 1 'chromium-154' 'Chromium' @('intent', 'commit')); $repeated[1].seq = 1
$shared = @(PackageRecords 1 'chromium-154' 'Chromium' @('intent', 'commit')) + @(PackageRecords 2 'autohotkey-2.0.28' 'AutoHotkey' @('intent'))
Must (@($malformed, $changed, $repeated, $shared | Where-Object { Hist $_ }).Count -eq 0 -and
    (Hist $malformed[0..1])) 'R1 history must be valid as a whole'
# P3: only an id holding an intent that names the package is validated. Other packages' histories, trees without a
# package and invalid unrelated ids neither prove nor hide it; a seq shared with any record still voids the ledger.
$noise = @(PackageRecords 101 'autohotkey-2.0.28' 'AutoHotkey' @('intent', 'commit', 'undone')) +
    @(PackageRecords 104 'noctty-1.3.131' $null @('intent', 'commit')) + @(PackageRecords 106 'chromium-155' $null @('intent', 'commit')) +
    @(PackageRecords 108 'autohotkey-2.0.27' 'AutoHotkey' @('intent', 'commit', 'void'))   # void after commit: invalid
$chromium = @(PackageRecords 1 'chromium-154' 'Chromium' @('intent', 'commit'))
$retried = @(PackageRecords 1 'chromium-154' $null @('intent', 'void')) + @(PackageRecords 3 'chromium-154' 'Chromium' @('intent', 'commit'))
$collides = @($noise | ForEach-Object { $_.Clone() }); $collides[0].seq = 2
$script:validateAttempt, $script:attemptsValidated = ${function:Get-EffectAttempt}, 0
try {
    ${function:Get-EffectAttempt} = { $script:attemptsValidated++; & $script:validateAttempt @args }
    $withNoise = Hist ($noise + $chromium)
    $p3Validated = $script:attemptsValidated
    Must ($withNoise -and $p3Validated -eq 1 -and (Hist ($chromium + $noise)) -and (Hist ($noise + $retried)) -and -not (Hist $noise) -and
        -not (Hist ($noise + @(PackageRecords 1 'chromium-154' 'Chromium' @('intent', 'void')))) -and -not (Hist ($collides + $chromium)) -and
        (Hist $noise 'AutoHotkey') -and -not (Hist $noise[3..9] 'AutoHotkey')) "P3: R1 amid unrelated ledger noise ($p3Validated validated)"
    # The R1 guard it feeds: protected data (a synced profile) beside noise alone is foreign, never installed over.
    $guard = Get-PackageClass 'absent' 0 @() $true (Hist $noise)
    Must ($guard.class -ceq 'preexisting-drift' -and -not $guard.install -and (Get-PackageClass 'absent' 0 @() $true (Hist ($noise + $chromium))).install) 'P3: the R1 protected-data guard'
} finally { ${function:Get-EffectAttempt} = $script:validateAttempt }
# D-c: the asset file is derived from a valid package intent's staging directory, beside it, and nothing else.
function AssetIntent([string]$Target, $Package, [string]$Temp) {
    $r = PureRecord 1 intent tree-extracted $Target $absent $pkgDesired $null $null
    if ($null -ne $Package) { $r.package = $Package }
    if ($Temp) { $r.temp = $Temp }
    $r
}
$pkgTarget = 'C:\u\Programs\chromium-154.0.8037.58'
$pkgStaging = "$pkgTarget.$guid.staging"
Must ((Get-PackageAssetPath (AssetIntent $pkgTarget 'Chromium' $pkgStaging) 'C:\u\Programs') -ceq "$pkgStaging.asset" -and
    (Get-PackageAssetPath (AssetIntent $pkgTarget 'Chromium' $pkgStaging) 'C:\u\Programs\') -ceq "$pkgStaging.asset" -and
    (Get-PackageAssetPath (AssetIntent 'C:\u\Programs\autohotkey-2.0.28' 'AutoHotkey' "C:\u\Programs\autohotkey-2.0.28.$guid.staging") 'C:\u\Programs') -ceq
        "C:\u\Programs\autohotkey-2.0.28.$guid.staging.asset") 'a derived asset path'
foreach ($bad in @(@($pkgTarget, $null, $pkgStaging, 'C:\u\Programs'), @($pkgTarget, 'AutoHotkey', $pkgStaging, 'C:\u\Programs'),
        @($pkgTarget, 'Chromium', $null, 'C:\u\Programs'), @($pkgTarget, 'Chromium', "C:\u\Programs\other.$guid.staging", 'C:\u\Programs'),
        @($pkgTarget, 'Chromium', $pkgStaging, 'C:\u\Other'), @('C:\u\Programs\x\chromium-154', 'Chromium', "C:\u\Programs\x\chromium-154.$guid.staging", 'C:\u\Programs'),
        @('C:\u\Programs\chromium-', 'Chromium', "C:\u\Programs\chromium-.$guid.staging", 'C:\u\Programs'),
        @('C:\u\Programs\chromiumx-1', 'Chromium', "C:\u\Programs\chromiumx-1.$guid.staging", 'C:\u\Programs'), @($pkgTarget, '..\x', $pkgStaging, 'C:\u\Programs'),
        @('C:\u\Programs\chromium-extra-1', 'Chromium', "C:\u\Programs\chromium-extra-1.$guid.staging", 'C:\u\Programs'),
        @($pkgTarget, 'Chromium', $pkgStaging, ''))) {
    Must ($null -eq (Get-PackageAssetPath (AssetIntent $bad[0] $bad[1] $bad[2]) $bad[3])) "no asset path for $($bad -join ' | ')"
}
$committedIntent = AssetIntent $pkgTarget 'Chromium' $pkgStaging; $committedIntent.phase = 'commit'; $committedIntent.observed = $pkgDesired; $committedIntent.Remove('temp')
Must ($null -eq (Get-PackageAssetPath $committedIntent 'C:\u\Programs')) 'no asset path from a commit'
# C-1: a partly removed package tree resumes with steps only inside its own target; an unknown file refuses.
$pkgRecord = @{ kind = 'tree-extracted'; target = $pkgTarget; desired = $pkgDesired }
$resumed = Get-TreeUndoSteps $pkgRecord @{ exists = $true; files = @{ 'Chrome-bin/chrome.exe' = (Sha a) }; other = @('Chrome-bin/d/') }
Must ($null -ne $resumed -and @($resumed).Count -eq 4 -and -not @($resumed | Where-Object { $_.path -cne $pkgTarget -and -not $_.path.StartsWith("$pkgTarget\") }).Count -and
    $null -eq (Get-TreeUndoSteps $pkgRecord @{ exists = $true; files = @{ 'Chrome-bin/chrome.exe' = (Sha a); 'User Data/Default/Prefs' = (Sha c) }; other = @() })) 'C-1: package tree resume stays inside its target'

# The create and recovery primitives, loaded alone from win.ps1 (no mode creates a Noctty effect
# yet) and run against a scratch %LOCALAPPDATA% ($Scratch, never deleted), its own ledger and a
# fresh HKCU CLSID it removes again. Self-contained and 5.1-safe: the proof runs it here and in a
# Windows PowerShell 5.1 child, which alone (-Real) extracts the bundled Noctty, once.
function PrimitiveProof([string]$Root, [string]$Scratch, [switch]$Real) {
    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'
    . (Join-Path $Root 'handoff-evaluate.ps1')
    $names = 'WriteRecord', 'RecordsOf', 'OpenAttempt', 'IntentTemp', 'CleanStaging', 'ResolveAttempt', 'RecoverId', 'Recovering',
        'CreateOwnedFile', 'CreateOwnedValue', 'CreateOwnedKey', 'CreateOwnedTree', 'Observe', 'ObserveNoctty', 'ObserveTree',
        'ObserveKey', 'ObserveValue', 'ObserveFile', 'NocttyEffects', 'KeyEffect', 'ValueEffect', 'FileEffect',
        'OrderedSteps', 'UndoOwnedSteps', 'RemoveTarget', 'FontReferences', 'FontReferenceTable', 'NocttyReferences',
        'SelectNoctty', 'StartupPair', 'RecordPriorTerminal', 'TestNocttyRegistration', 'TestNocttyActivation', 'AssertActualSelection', 'RestoreLegacy',
        'StepText', 'IsPackageTree', 'RemovePackageAsset', 'IndexRecord', 'ReadLedger', 'LedgerIds', 'NewLedgerIndex', 'AttemptOf',
        'PackageEffect', 'SeedHazard', 'WriteSeed', 'AppPathEffects', 'IsAppPathEffect', 'MachineAppPath', 'EffectClass', 'AppPathState',
        'ConvergeAppPath', 'CollectAppPathGarbage', 'ConvergeEffect', 'Classify', 'UndoOwned', 'SharedKey', 'ObserveKeyContent'
    $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $Root 'win.ps1'), [ref]$null, [ref]$null)
    foreach ($definition in $ast.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -cin $names }, $false)) {
        . ([scriptblock]::Create($definition.Extent.Text))
    }
    function Must([bool]$Holds, [string]$Rule) { if (-not $Holds) { throw "Primitive proof failed: $Rule" } }
    function Refused([scriptblock]$Act, [string]$Like) {
        try { $null = & $Act } catch { if ($_.Exception.Message -like $Like) { return }; throw }
        throw "Primitive proof failed: not refused ($Like)"
    }
    function Sha([string]$Text) { -join ([Security.Cryptography.SHA256]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes($Text)) | ForEach-Object { $_.ToString('x2') }) }
    function Phases($Effect) { @(RecordsOf $Effect.id | ForEach-Object { $_.phase }) -join ',' }
    function Tree([string]$Name, $Files) {
        $target = Join-Path $Scratch "Programs\$Name"
        [ordered]@{ id = 'tree-extracted:' + $target.ToUpperInvariant(); kind = 'tree-extracted'; target = $target
            prior = @{ exists = $false }; desired = @{ exists = $true; files = $Files } }
    }
    function Staging($Effect) { $Effect.target + '.' + [guid]::NewGuid().ToString('N') + '.staging' }
    $manifest = [IO.File]::ReadAllText((Join-Path $Root 'manifest.json')) | ConvertFrom-Json
    $Mode, $localAppData, $ledgerDirectory, $zip = 'Apply', $Scratch, (Join-Path $Scratch 'ledger'), (Join-Path $Root 'payload\noctty.zip')
    $fontDirectory, $fontSubkey = (Join-Path $Scratch 'fonts'), 'Software\Microsoft\Windows NT\CurrentVersion\Fonts'
    $fontKey = 'HKCU\' + $fontSubkey
    $nocttyDirectory = Join-Path $Scratch ('Programs\noctty-' + $manifest.noctty.version)
    $nocttyConfig, $nocttyConfigText = (Join-Path $Scratch 'noctty\config.ghostty'), ('font-family = ' + $manifest.noctty.fontFamily + "`n")
    $clsid = '{' + [guid]::NewGuid().ToString().ToUpperInvariant() + '}'
    $nocttyRegistration = Get-NocttyRegistration @(@{ key = "Software\Classes\CLSID\$clsid\LocalServer32"; name = ''; data = 'proof' }) $nocttyDirectory $manifest.noctty.files
    $script:ledgerRecords, $script:nextSeq, $script:recordsWritten, $script:copied, $script:changed, $script:removed = @(), 1, 0, 0, 0, 0
    $script:ledgerById = NewLedgerIndex
    $null = New-Item -ItemType Directory -Path $ledgerDirectory, (Join-Path $Scratch 'Programs'), (Split-Path -Parent $nocttyConfig) -Force
    $selected = NocttyEffects

    # The whole entry list is checked before anything is written.
    $two = @{ 'noctty/a.txt' = (Sha 'a'); 'noctty/d/b.txt' = (Sha 'b') }
    Must ($null -eq (Get-ZipEntryProblem @('noctty/', 'noctty/a.txt', 'noctty/d/', 'noctty/d/b.txt') $two)) 'an exact entry list'
    foreach ($bad in @(@('noctty/a.txt', 'noctty/d/b.txt', 'noctty/x.txt'), @('noctty/a.txt'), @('noctty/a.txt', 'noctty/d/b.txt', 'NOCTTY/A.TXT'),
            @('noctty/a.txt', 'noctty/d/b.txt', 'noctty/e/'), @('noctty\a.txt', 'noctty/d/b.txt'), @('noctty/a.txt', 'noctty/d/b.txt', 'noctty/NUL'),
            @('Noctty/a.txt', 'noctty/d/b.txt'))) {
        Must ($null -ne (Get-ZipEntryProblem $bad $two)) "entry list $($bad -join ',') is refused"
    }
    $before = $script:nextSeq
    Refused { CreateOwnedTree (Tree 'noctty-wrong' $two) $zip } '*Not in the inventory*'
    Must ($script:nextSeq -eq $before -and -not (Test-Path (Join-Path $Scratch 'Programs\noctty-wrong*'))) 'a differing archive is refused before any intent or write'
    # The one relative-path regex agrees with Test-PathSegment (the specification), per segment, on every
    # real name in this bundle and on adversarial ones, in this edition.
    $pathNames = @($manifest.noctty.files.PSObject.Properties | ForEach-Object Name) + @($manifest.files.PSObject.Properties | ForEach-Object Name) +
        @($manifest.packages | ForEach-Object { $_.files.PSObject.Properties | ForEach-Object Name }) +
        @('', '.', '..', 'a/', '/a', 'a//b', 'a\b', 'C:x', 'a.', 'a ', ' a', 'a. ', 'a .', '.a', 'a..b', "a`n", "a`r`n", "a`r", "`na", "a`tb", "a$([char]0x7f)b",
          'CON', 'con', 'Con.txt', 'CON.', 'CON.tar.gz', 'CONX', 'XCON', 'COM1', 'com9.log', 'COM10', 'COM0', 'LPT1', 'lpt5.x', 'AUX', 'NUL', 'nul.', 'PRN.a',
          "COM$([char]0x0661)", "LPT$([char]0x0669).txt", "COM$([char]0xFF11)", 'd/CON', 'CON/d', 'd/nul.txt/e', "a$([char]0x00A0)", "a$([char]0x3000)",
          "$([char]0xD83D)$([char]0xDE00)", "a$([char]0xD83D)", "a/b`n", "a`n/b", 'a|b', 'a"b', 'a*b', 'a?b', 'a<b', 'a>b', 'a:b', [string][char]0x212A,
          [string][char]0x017F, [string][char]0x0131, [string][char]0x0130, 'Chrome-bin/154.0.8037.58/chrome.dll')
    $disagree = @($pathNames | Where-Object { (Test-RelativePath $_) -ne (-not @($_.Split('/') | Where-Object { -not (Test-PathSegment $_) }).Count) })
    Must (-not $disagree.Count) "the relative-path regex agrees with Test-PathSegment on $($pathNames.Count) names ($($disagree.Count) differ)"
    # ConvertTo-FileMap keeps the real inventory exactly; a trailing newline is no SHA-256 or staging path anywhere;
    # a key named Keys is an ordinary name; two names differing only in case are refused.
    $inventory = ConvertTo-FileMap $manifest.noctty.files
    $shaA = 'a' * 64
    $ordinal = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal); $ordinal['A/x'] = $shaA; $ordinal['a/x'] = $shaA
    Must ($inventory.Count -eq @($manifest.noctty.files.PSObject.Properties).Count -and
        -not @($manifest.noctty.files.PSObject.Properties | Where-Object { $inventory[$_.Name] -cne $_.Value }).Count -and
        $null -eq (ConvertTo-FileMap @{ 'a' = "$shaA`n" }) -and $null -ne (Get-EffectStateProblem 'file-created' @{ exists = $true; sha256 = "$shaA`n" } 'x') -and
        $null -ne (Get-IntentTempProblem @{ kind = 'tree-extracted'; target = 'C:\u\t'; temp = "C:\u\t.$('0123456789abcdef' * 2).staging`n" }) -and
        (ConvertTo-FileMap @{ 'Keys' = $shaA; 'b' = $shaA }).Count -eq 2 -and $null -eq (ConvertTo-FileMap $ordinal)) 'file maps and strict anchors'
    # R1 package history, in this edition: a valid committed attempt counts; with a malformed closing record it does not.
    $history = Tree 'chromium-1' $two
    $records = @(foreach ($r in @(@(1, 'intent', $null), @(2, 'commit', $history.desired), @(3, 'undone', @{ exists = $false }))) {
        $record = @{ ledger = 'effects'; schema = 1; seq = $r[0]; phase = $r[1] }
        foreach ($k in $history.Keys) { $record[$k] = $history[$k] }
        if ($null -ne $r[2]) { $record.observed = $r[2] }
        $record
    })
    $records[0].package = 'Chromium'; $records[2].schema = 2
    $programsHere = Join-Path $Scratch 'Programs'
    Must ((Test-PackageHistory $records[0..1] 'Chromium' $programsHere) -and -not (Test-PackageHistory $records 'Chromium' $programsHere) -and
        -not (Test-PackageHistory $records[0..1] 'Chromium' (Join-Path $Scratch 'Other')) -and -not (Test-PackageHistory $records[0..1] 'Chromium' '')) 'R1 package history in this edition'
    # P3 here too: a malformed record of another id is not validated; one sharing a seq still voids the ledger.
    $noise = @{ ledger = 'effects'; schema = 2; seq = 9; phase = 'intent'; id = 'noise'; package = 'AutoHotkey' }
    Must ((Test-PackageHistory (@($noise) + $records[0..1]) 'Chromium' $programsHere) -and
        -not (Test-PackageHistory (@($noise) + $records[0..1]) 'AutoHotkey' $programsHere) -and
        -not (Test-PackageHistory (@(@{ ledger = 'effects'; schema = 1; seq = 2; phase = 'intent'; id = 'noise' }) + $records[0..1]) 'Chromium' $programsHere)) 'P3 in this edition'
    # S2-2b1 package primitives. The class table: the ledger keeps ownership; an
    # external Uninstall entry is never taken over and beside an owned tree is a conflict; R1 for protected data.
    function PClass($Tree, $Entries = 0, $Problems = @(), $Protected = $false, $History = $false, $Changed = $false, $Hazard = $false) {
        $c = Get-PackageClass $Tree $Entries $Problems $Protected $History $Changed $Hazard
        "$($c.class)|$([int]$c.conflict)|$([int]$c.install)|$([int]$c.converged)"
    }
    # C1: an owned tree recorded for another inventory or seed is owned-drift. O1: a profile the seed would
    # overwrite blocks an install (preexisting-drift) and never lets an owned tree converge; it does not touch
    # classes the package does not own (an external or unrecorded install, R1's foreign profile).
    Must ((PClass 'owned-match' 0 @() $false $false $true) -ceq 'owned-drift|0|0|0' -and (PClass 'owned-drift' 0 @() $false $false $true) -ceq 'owned-drift|0|0|0' -and
        (PClass 'absent' 0 @() $false $false $true) -ceq 'absent|0|1|0' -and (PClass 'preexisting-match' 1 @() $false $false $true) -ceq 'preexisting-match|0|0|1' -and
        (PClass 'absent' 0 @() $true $true $false $true) -ceq 'preexisting-drift|0|0|0' -and (PClass 'owned-match' 0 @() $true $true $false $true) -ceq 'owned-match|0|0|0' -and
        (PClass 'absent' 1 @() $true $true $false $true) -ceq 'preexisting-match|0|0|1' -and (PClass 'absent' 0 @() $true $false $false $true) -ceq 'preexisting-drift|0|0|0' -and
        (Get-PackageClass 'owned-match' 0 @() $true $true $true $true).hazard -and (Get-PackageClass 'owned-match' 0 @() $false $false $true $false).changed -and
        -not (Get-PackageClass 'preexisting-match' 1 @() $true $true $false $true).hazard -and -not (Get-PackageClass 'owned-drift' 0 @() $false $false $true $false).changed) 'C1 and O1 in the class table'
    Must ((PClass 'owned-match') -ceq 'owned-match|0|0|1' -and (PClass 'owned-match' 1) -ceq 'owned-match|1|0|0' -and
        (PClass 'owned-drift' 1 @('x')) -ceq 'owned-drift|1|0|0' -and (PClass 'owned-drift') -ceq 'owned-drift|0|0|0' -and
        (PClass 'absent' 1) -ceq 'preexisting-match|0|0|1' -and (PClass 'absent' 2 @('DisplayVersion is 1')) -ceq 'preexisting-drift|0|0|0' -and
        (PClass 'preexisting-match' 1 @('x')) -ceq 'preexisting-drift|0|0|0' -and (PClass 'preexisting-match') -ceq 'preexisting-match|0|0|1' -and
        (PClass 'preexisting-drift') -ceq 'preexisting-drift|0|0|0' -and (PClass 'absent' 0 @() $true $false) -ceq 'preexisting-drift|0|0|0' -and
        (PClass 'absent' 0 @() $true $true) -ceq 'absent|0|1|0' -and (PClass 'absent') -ceq 'absent|0|1|0' -and
        (PClass 'absent' 1 @() $true $true) -ceq 'preexisting-match|0|0|1' -and (PClass 'indeterminate' 1) -ceq 'indeterminate|0|0|0' -and
        (PClass 'bogus') -ceq 'indeterminate|0|0|0') 'the package class table'
    # tar listings: directories with or without a trailing '/', CRLF, the end-of-listing blank line; anything else refused.
    $tarFiles = @{ 'Chrome-bin/chrome.exe' = $shaA; 'Chrome-bin/154.0.8037.58/chrome.dll' = $shaA; 'README' = $shaA }
    $tarGood = @(@('Chrome-bin/', 'Chrome-bin/154.0.8037.58/', 'Chrome-bin/154.0.8037.58/chrome.dll', 'Chrome-bin/chrome.exe', 'README', ''),
        @('Chrome-bin', 'Chrome-bin/154.0.8037.58', 'Chrome-bin/154.0.8037.58/chrome.dll', "Chrome-bin/chrome.exe`r", 'README'),
        @('README', 'Chrome-bin/chrome.exe', 'Chrome-bin/154.0.8037.58/chrome.dll'))
    $tarBad = @(@('README/', 'Chrome-bin/chrome.exe', 'Chrome-bin/154.0.8037.58/chrome.dll'), @('./README', 'Chrome-bin/chrome.exe', 'Chrome-bin/154.0.8037.58/chrome.dll'),
        @('chrome-bin/', 'README', 'Chrome-bin/chrome.exe', 'Chrome-bin/154.0.8037.58/chrome.dll'), @('README', 'Chrome-bin/chrome.exe'),
        @('README', 'Chrome-bin/chrome.exe', 'Chrome-bin/154.0.8037.58/chrome.dll', 'extra.txt'), @('README', 'Chrome-bin/chrome.exe', 'Chrome-bin/154.0.8037.58/chrome.dll', 'Chrome-bin/x/'),
        @('README', 'README', 'Chrome-bin/chrome.exe', 'Chrome-bin/154.0.8037.58/chrome.dll'), @('Chrome-bin\chrome.exe', 'README', 'Chrome-bin/154.0.8037.58/chrome.dll'))
    Must (-not @($tarGood | Where-Object { $null -ne (Get-ZipEntryProblem @(ConvertFrom-TarListing $_ $tarFiles) $tarFiles) }).Count -and
        -not @($tarBad | Where-Object { $null -eq (Get-ZipEntryProblem @(ConvertFrom-TarListing $_ $tarFiles) $tarFiles) }).Count) 'tar listings, strictly'
    # Native quoting, checked by Windows' own CommandLineToArgvW in this edition.
    if (-not ('W.ArgvProbe' -as [type])) {
        Add-Type -Namespace W -Name ArgvProbe -MemberDefinition @'
[DllImport("shell32.dll", SetLastError = true)] static extern System.IntPtr CommandLineToArgvW([MarshalAs(UnmanagedType.LPWStr)] string cmd, out int count);
[DllImport("kernel32.dll")] static extern System.IntPtr LocalFree(System.IntPtr mem);
public static string[] Split(string cmd) {
    int n; System.IntPtr p = CommandLineToArgvW(cmd, out n);
    try { var r = new string[n]; for (int i = 0; i < n; i++) { r[i] = Marshal.PtrToStringUni(Marshal.ReadIntPtr(p, i * System.IntPtr.Size)); } return r; }
    finally { LocalFree(p); }
}
'@
    }
    $tricky = @('plain', 'with space', 'C:\Users\John Smith\a.7z', 'trail\', 'trail space\', 'q"uote', 'back\"q', 'back\\"q', '', "tab`tx", '=https', '-o',
        '\\server\share\', 'a\\b', '"', '\"', 'https://github.com/a/b/releases/download/v1/chrome.7z')
    $split = @([W.ArgvProbe]::Split('x ' + (Join-NativeArguments $tricky)))
    Must ($split.Count -eq $tricky.Count + 1 -and -not @(0..($tricky.Count - 1) | Where-Object { $split[$_ + 1] -cne $tricky[$_] }).Count) 'native arguments round-trip'
    Refused { Join-NativeArguments @("a$([char]0)b") } '*NUL*'
    # Capacity and path bounds: size + unpackedSize + seed + 64 MiB; a file path below 260 and a directory below 248, under staging.
    $small = @{ size = 100; unpackedSize = 50; files = @{ 'bbbbbbbb.txt' = $shaA } }
    $need = [long]150 + 64MB
    $seeded = @{ size = 100; unpackedSize = 50; files = $small.files; seed = @{ path = 'initial_preferences'; size = 5 } }
    Must ($null -eq (Get-PackageSpaceProblem $small 'C:\p\x-1' $need) -and $null -ne (Get-PackageSpaceProblem $small 'C:\p\x-1' ($need - 1)) -and
        $null -eq (Get-PackageSpaceProblem $seeded 'C:\p\x-1' ($need + 5)) -and $null -ne (Get-PackageSpaceProblem $seeded 'C:\p\x-1' ($need + 4)) -and
        (Get-PackageSpaceNeed $seeded) -eq $need + 5 -and (Get-PackageSpaceNeed $small) -eq $need -and
        $null -eq (Get-PackageSpaceProblem @{ size = 1; unpackedSize = 1; files = @{ 'a' = $shaA }; seed = @{ path = 'd/f'; size = 1 } } ('C:\' + 'p' * 201) $need) -and
        $null -ne (Get-PackageSpaceProblem @{ size = 1; unpackedSize = 1; files = @{ 'a' = $shaA }; seed = @{ path = 'd/f'; size = 1 } } ('C:\' + 'p' * 202) $need) -and
        $null -eq (Get-PackageSpaceProblem $small ('C:\' + 'p' * 202) $need) -and $null -ne (Get-PackageSpaceProblem $small ('C:\' + 'p' * 203) $need) -and
        $null -eq (Get-PackageSpaceProblem @{ size = 1; unpackedSize = 1; files = @{ 'd/f' = $shaA } } ('C:\' + 'p' * 201) $need) -and
        $null -ne (Get-PackageSpaceProblem @{ size = 1; unpackedSize = 1; files = @{ 'd/f' = $shaA } } ('C:\' + 'p' * 202) $need)) 'capacity and path bounds'
    foreach ($bad in @(@{ size = $true; unpackedSize = 1; files = $small.files }, @{ size = 1; unpackedSize = [long]9007199254740992; files = $small.files },
            @{ size = 1.5; unpackedSize = 1; files = $small.files }, @{ size = 1; unpackedSize = 1; files = @{} }, @{ size = 1; unpackedSize = 1 })) {
        Must ($null -ne (Get-PackageSpaceProblem $bad 'C:\p\x-1' ([long]1TB))) 'an invalid package or free space is refused'
    }
    Must (-not @(@{ path = 'initial_preferences'; size = 0 }, @{ path = 'initial_preferences'; size = '5' }, @{ path = '../x'; size = 5 }, @{ size = 5 } | Where-Object {
            $null -eq (Get-PackageSpaceProblem @{ size = 100; unpackedSize = 50; files = $small.files; seed = $_ } 'C:\p\x-1' ([long]1TB)) }).Count -and
        $null -eq (Get-PackageSpaceNeed @{ size = 100; unpackedSize = 50; seed = @{ size = -1 } }) -and
        $null -ne (Get-PackageSpaceProblem $small 'C:\p\x-1' 1.0e12)) 'an invalid seed or free space is refused'
    # The asset: exact length, SHA-256 and (when locked) SHA-1; hashes compare as lowercase hex only.
    $abc = [Text.Encoding]::UTF8.GetBytes('abc')
    $abc256 = -join ([Security.Cryptography.SHA256]::Create().ComputeHash($abc) | ForEach-Object { $_.ToString('x2') })
    $abc1 = -join ([Security.Cryptography.SHA1]::Create().ComputeHash($abc) | ForEach-Object { $_.ToString('x2') })
    $assetLock = @{ size = 3; sha256 = $abc256; sha1 = $abc1 }
    $assetBad = @(@(4, $abc256, $abc1), @(3, $abc1, $abc1), @(3, $abc256, $abc256.Substring(0, 40).Replace('a', 'b')), @(3, "$abc256`n", $abc1),
        @('3', $abc256, $abc1), @(3, "0x$abc256", $abc1))
    Must ($null -eq (Get-AssetProblem $assetLock 3 $abc256.ToUpperInvariant() $abc1) -and $null -eq (Get-AssetProblem @{ size = 3; sha256 = $abc256 } ([long]3) $abc256 '') -and
        -not @($assetBad | Where-Object { $null -eq (Get-AssetProblem $assetLock $_[0] $_[1] $_[2]) }).Count -and
        (Get-AssetProblem @{ size = 3; sha256 = $abc256.ToUpperInvariant() } 3 $abc256 '') -ceq 'The lock is invalid.') 'exact asset checks'
    # Owned package trees (any version) are observed; only a tree intent names its package; recovery of an
    # interrupted package intent removes its one derived asset and its staging, and nothing beside them.
    Must ((IsPackageTree (Join-Path $Scratch 'Programs\autohotkey-2.0.28')) -and (IsPackageTree (Join-Path $Scratch 'Programs\chromium-153.0.1')) -and
        -not (IsPackageTree (Join-Path $Scratch 'Programs\chromium-extra-1')) -and -not (IsPackageTree (Join-Path $Scratch 'Programs\x\chromium-1')) -and
        -not (IsPackageTree (Join-Path $Scratch 'Programs\chromium-1.')) -and -not (IsPackageTree (Join-Path $Scratch 'Programs\noctty-1'))) 'package trees Observe reads'
    $pkgTree = Tree 'autohotkey-9.9' $two
    $pkgStage = Staging $pkgTree
    Refused { WriteRecord 'commit' $pkgTree $pkgTree.desired $null 'AutoHotkey' } 'Only a tree intent names its package.'
    # A package intent names exactly the locked package of its own tree and staging directory; nothing is written otherwise.
    $nocttyLike = Tree 'noctty-1' $two
    $before = $script:nextSeq
    foreach ($bad in @(@($pkgTree, 'Chromium', $pkgStage), @($pkgTree, 'autohotkey', $pkgStage), @($pkgTree, 'Noctty', $pkgStage),
            @($nocttyLike, 'AutoHotkey', (Staging $nocttyLike)), @($pkgTree, 'AutoHotkey', $null))) {
        Refused { WriteRecord 'intent' $bad[0] $null $bad[2] $bad[1] } 'Refusing*package*'
    }
    Must ($script:nextSeq -eq $before) 'refused package intents write nothing'
    WriteRecord 'intent' $pkgTree $null $pkgStage 'AutoHotkey'
    [IO.File]::WriteAllText("$pkgStage.asset", 'partial download')
    [IO.File]::WriteAllText("$pkgStage.asset.foreign", 'not derived')
    $null = New-Item -ItemType Directory -Path "$pkgStage\noctty"
    [IO.File]::WriteAllText("$pkgStage\noctty\a.txt", 'a')
    RecoverId $pkgTree.id
    Must ((Phases $pkgTree) -ceq 'intent,void' -and @(RecordsOf $pkgTree.id)[0].package -ceq 'AutoHotkey' -and -not (Test-Path -LiteralPath "$pkgStage.asset") -and
        -not (Test-Path -LiteralPath $pkgStage) -and (Test-Path -LiteralPath "$pkgStage.asset.foreign")) 'a package intent is recovered with its derived asset'
    # S2-3b, the Chromium seed. The built bundle's seed is the six font preferences of the manifest's roles, and
    # usable (Get-SeedProblem); every broken form is refused.
    $chromium = @($manifest.packages | Where-Object { $_.name -ceq 'Chromium' })[0]
    $seedSource = Join-Path $Root $chromium.seed.file.Replace('/', '\')
    $family = @{}; foreach ($font in $manifest.fonts) { $family[$font.role] = $font.family }
    $fontPrefs = ([IO.File]::ReadAllText($seedSource) | ConvertFrom-Json).webkit.webprefs.fonts
    Must ((Get-FileHash -LiteralPath $seedSource).Hash -eq $chromium.seed.sha256 -and (Get-Item -LiteralPath $seedSource).Length -eq $chromium.seed.size -and
        (@($fontPrefs.PSObject.Properties.Name | Sort-Object) -join ',') -ceq 'fixed,sansserif,standard' -and
        -not @('standard', 'sansserif', 'fixed' | Where-Object { (@($fontPrefs.$_.PSObject.Properties.Name | Sort-Object) -join ',') -cne 'Jpan,Zyyy' }).Count -and
        -not @('standard', 'sansserif' | ForEach-Object { $fontPrefs.$_.Zyyy, $fontPrefs.$_.Jpan } | Where-Object { $_ -cne $family['ui'] }).Count -and
        $fontPrefs.fixed.Zyyy -ceq $family['terminal'] -and $fontPrefs.fixed.Jpan -ceq $family['terminal'] -and
        $null -eq (Get-SeedProblem $chromium $manifest.files)) 'the bundled seed: six font preferences from the roles'
    function SeedVariant([hashtable]$Change, $Files = $chromium.files, $Protected = $chromium.protected) {
        $seed = @{ path = $chromium.seed.path; file = $chromium.seed.file; sha256 = $chromium.seed.sha256; size = $chromium.seed.size }
        foreach ($key in $Change.Keys) { $seed[$key] = $Change[$key] }
        @{ executable = $chromium.executable; files = $Files; protected = $Protected; seed = $seed }
    }
    function WithFile([string]$Name) { $files = @{ $Name = $shaA }; foreach ($p in $chromium.files.PSObject.Properties) { $files[$p.Name] = $p.Value }; $files }
    $seedBad = @((SeedVariant @{ path = 'Chrome-bin/Initial_Preferences' }), (SeedVariant @{ path = 'initial_preferences' }),
        (SeedVariant @{ path = 'Chrome-bin/master_preferences' }), (SeedVariant @{ sha256 = (Sha 'other') }), (SeedVariant @{ sha256 = $chromium.seed.sha256.ToUpperInvariant() }),
        (SeedVariant @{ size = 0 }), (SeedVariant @{ size = '1' }), (SeedVariant @{ file = 'payload/noctty.zip' }), (SeedVariant @{ file = '../x' }),
        (SeedVariant @{} (WithFile 'Chrome-bin/initial_preferences')), (SeedVariant @{} (WithFile 'chrome-bin/Master_Preferences')),
        (SeedVariant @{} (WithFile 'Chrome-bin/initial_preferences/x')), (SeedVariant @{} $chromium.files @()),
        (SeedVariant @{} $chromium.files @('Chromium/User Data', 'Chromium/Other')))
    $accepted = @($seedBad | Where-Object { $null -eq (Get-SeedProblem $_ $manifest.files) })
    Must ($accepted.Count -eq 0 -and $null -eq (Get-SeedProblem (SeedVariant @{}) $manifest.files)) "every broken seed is refused ($($accepted.Count) accepted)"
    # The owned tree is the inventory and the seed, so a tree recorded from the inventory alone is another selection (C1).
    $chromiumEffect = PackageEffect $chromium
    Must ($chromiumEffect.desired.files.Count -eq @($chromium.files.PSObject.Properties).Count + 1 -and
        $chromiumEffect.desired.files[$chromium.seed.path] -ceq $chromium.seed.sha256 -and
        -not (Test-EffectStateEqual 'tree-extracted' @{ exists = $true; files = $chromium.files } $chromiumEffect.desired)) 'the owned tree: the inventory and the seed'
    # A small seeded stand-in: the archive listing is checked against the inventory alone (a seed in the archive is
    # refused); staging is the owned tree only once WriteSeed has written the verified bundle bytes, as a new file.
    $mini = [pscustomobject]@{ name = 'Chromium'; version = '9.9'; directory = 'Programs/chromium-9.9'; executable = 'Chrome-bin/chrome.exe'
        files = [pscustomobject]@{ 'Chrome-bin/chrome.exe' = (Sha 'exe') }; protected = @('Chromium/User Data'); seed = $chromium.seed }
    $miniEffect = PackageEffect $mini
    $listing = @(ConvertFrom-TarListing @('Chrome-bin/', 'Chrome-bin/chrome.exe', '') $mini.files)
    Must ($null -eq (Get-ZipEntryProblem $listing $mini.files) -and $null -ne (Get-ZipEntryProblem $listing $miniEffect.desired.files) -and
        $null -ne (Get-ZipEntryProblem @($listing + 'Chrome-bin/initial_preferences') $mini.files)) 'the listing is the inventory alone'
    $miniStage = Staging $miniEffect
    $null = New-Item -ItemType Directory -Path "$miniStage\Chrome-bin"
    [IO.File]::WriteAllText("$miniStage\Chrome-bin\chrome.exe", 'exe')
    $forged = Join-Path $Scratch "forged-seed-$([guid]::NewGuid().ToString('N'))"
    [IO.File]::WriteAllText($forged, '{"webkit":{}}')
    Must (-not (Test-EffectStateEqual 'tree-extracted' $miniEffect.desired (ObserveTree $miniStage))) 'staging without its seed is not the owned tree'
    Refused { WriteSeed $chromium.seed $forged $miniStage } '*is not the manifest''s*'
    Must (-not (Test-Path -LiteralPath "$miniStage\Chrome-bin\initial_preferences")) 'a seed differing from the manifest writes nothing'
    WriteSeed $chromium.seed $seedSource $miniStage
    Must ((Test-EffectStateEqual 'tree-extracted' $miniEffect.desired (ObserveTree $miniStage)) -and
        (Get-FileHash -LiteralPath "$miniStage\Chrome-bin\initial_preferences").Hash -eq $chromium.seed.sha256) 'staging with its seed is exactly the owned tree'
    Refused { WriteSeed $chromium.seed $seedSource $miniStage } '*exists*'
    # Interrupted after the seed was written: recovery voids the intent and removes the seed with the staging.
    WriteRecord 'intent' $miniEffect $null $miniStage 'Chromium'
    RecoverId $miniEffect.id
    Must ((Phases $miniEffect) -ceq 'intent,void' -and -not (Test-Path -LiteralPath $miniStage)) 'an interrupted seeded install is voided, its seed removed with the staging'
    # O1, read-only, on a scratch profile: Default\Preferences without the First Run sentinel is found; an empty
    # profile, the sentinel, or a package without a seed is not; the profile is only read.
    $savedLocal = $localAppData
    try {
        $localAppData = Join-Path $Scratch "o1-$([guid]::NewGuid().ToString('N'))"
        $userData = Join-Path $localAppData 'Chromium\User Data'
        $null = New-Item -ItemType Directory -Path "$userData\Default"
        $empty = SeedHazard $chromium
        [IO.File]::WriteAllText("$userData\Default\Preferences", '{"proof":1}')
        $found, $unseeded = (SeedHazard $chromium), (SeedHazard ([pscustomobject]@{ protected = @('Chromium/User Data') }))
        [IO.File]::WriteAllText("$userData\First Run", '')
        $sentinel = SeedHazard $chromium
        Must ($null -eq $empty -and $found -ceq "$userData\Default\Preferences" -and $null -eq $unseeded -and $null -eq $sentinel -and
            [IO.File]::ReadAllText("$userData\Default\Preferences") -ceq '{"proof":1}') 'O1: Preferences without First Run is found, and only read'
    } finally { $localAppData = $savedLocal }
    # S2-2d-b, App Paths, on a unique name in this user's real HKCU App Paths (collected again below). The shape
    # (not the lock) makes an effect App Paths; only an owned or installed package without hazard or conflict is
    # selected; the K-rule: a foreign key, even with our exact data, is drift and never taken over; an HKLM entry
    # (either view) is a conflict, beside an owned key too, which is then only reported; create, read back and
    # re-point to a new version; the value names its tree (reference guard); A3 keeps a retired key holding
    # foreign content; a retired name is collected value then key, but not while a seed would overwrite a profile.
    $registryViews = @(@('HKCU', 'CurrentUser', 'Default'), @('HKLM', 'LocalMachine', 'Registry64'), @('HKLM32', 'LocalMachine', 'Registry32'))
    $appPathsSubkey = 'Software\Microsoft\Windows\CurrentVersion\App Paths'
    $script:packageDrift, $script:sharedCreated = @(), @()
    $appName = 'proof-' + [guid]::NewGuid().ToString('N') + '.exe'
    $appSubkey = "$appPathsSubkey\$appName"
    $appPackage = [pscustomobject]@{ name = 'Chromium'; version = '9.8'; directory = 'Programs/chromium-9.8'; executable = 'Chrome-bin/chrome.exe'
        files = [pscustomobject]@{ 'Chrome-bin/chrome.exe' = (Sha 'exe') }; protected = @('Chromium/User Data'); appPath = $appName }
    function AppState($Class = 'owned-match', $Install = $false, $Hazard = $false, $Conflict = $false) {
        [pscustomobject]@{ package = $appPackage; class = $Class; install = $Install; hazard = $Hazard; conflict = $Conflict }
    }
    $appEffects = AppPathEffects $appPackage
    $appExe = Join-Path $localAppData 'Programs\chromium-9.8\Chrome-bin\chrome.exe'
    Must ($appEffects.key.target -ceq "HKCU\$appSubkey" -and $appEffects.value.target -ceq "HKCU\$appSubkey" -and $appEffects.value.name -ceq '' -and
        $appEffects.value.desired.data -ceq $appExe -and (IsAppPathEffect $appEffects.key) -and (IsAppPathEffect $appEffects.value) -and
        (IsAppPathEffect @{ kind = 'registry-key-created'; target = "HKCU\$appPathsSubkey\retired.exe" }) -and
        -not (IsAppPathEffect @{ kind = 'registry-value'; target = "HKCU\$appSubkey"; name = 'Path' }) -and
        -not (IsAppPathEffect @{ kind = 'registry-key-created'; target = "HKCU\$appSubkey\sub" }) -and
        -not (IsAppPathEffect @{ kind = 'registry-key-created'; target = "HKCU\$appPathsSubkey\x.cmd" }) -and
        -not (IsAppPathEffect @{ kind = 'registry-key-created'; target = "HKCU\$appPathsSubkey\NUL.exe" })) 'App Paths effects and their shape'
    Must ($null -eq (AppPathState (AppState 'owned-match' $false $true)) -and $null -eq (AppPathState (AppState 'owned-match' $false $false $true)) -and
        $null -eq (AppPathState (AppState 'absent')) -and $null -eq (AppPathState (AppState 'owned-drift')) -and
        $null -eq (AppPathState ([pscustomobject]@{ package = [pscustomobject]@{ name = 'X' }; class = 'owned-match'; install = $false; hazard = $false; conflict = $false }))) 'App Paths only for an owned or installed package without hazard or conflict'
    $absentState = AppPathState (AppState)
    $foreign = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($appSubkey)
    try { $foreign.SetValue('', $appExe) } finally { $foreign.Close() }
    $foreignState = AppPathState (AppState)
    [Microsoft.Win32.Registry]::CurrentUser.DeleteSubKey($appSubkey)
    $machine = ${function:MachineAppPath}
    try { ${function:MachineAppPath} = { 'HKLM\stub' }; $machineState = AppPathState (AppState) } finally { ${function:MachineAppPath} = $machine }
    Must ($absentState.write -and -not $absentState.converged -and -not $absentState.reason -and
        -not $foreignState.write -and -not $foreignState.converged -and $foreignState.reason -like '*never taken over*' -and
        -not $machineState.write -and $machineState.reason -like 'HKLM\stub registers*' -and $machineState.reason -notlike '*Uninstall removes ours*') 'the App Paths K-rule and HKLM conflict before any write'
    ConvergeAppPath $absentState
    $read = ObserveValue '' $appSubkey
    $ownedState = AppPathState (AppState)
    try { ${function:MachineAppPath} = { 'HKLM\stub' }; $laterState = AppPathState (AppState) } finally { ${function:MachineAppPath} = $machine }
    Must ((Phases $appEffects.key) -ceq 'intent,commit' -and (Phases $appEffects.value) -ceq 'intent,commit' -and $read.type -ceq 'String' -and $read.data -ceq $appExe -and
        $ownedState.converged -and -not $ownedState.write -and -not $laterState.write -and $laterState.reason -like '*(Uninstall removes ours)*' -and
        (ObserveKey $appSubkey).exists) 'an App Paths name is created (key, then its default value) and an HKLM conflict beside it is only reported'
    $appPackage.version, $appPackage.directory = '9.9', 'Programs/chromium-9.9'
    $movedState = AppPathState (AppState)
    ConvergeAppPath $movedState
    $movedExe = Join-Path $localAppData 'Programs\chromium-9.9\Chrome-bin\chrome.exe'
    Must ($movedState.write -and (Phases $appEffects.value) -ceq 'intent,commit,undone,intent,commit' -and (Phases $appEffects.key) -ceq 'intent,commit' -and
        (ObserveValue '' $appSubkey).data -ceq $movedExe -and (AppPathState (AppState)).converged) 'a new version re-points the owned App Paths value'
    $reference = [pscustomobject]@{ label = "HKCU\$appSubkey"; data = $movedExe; id = $appEffects.value.id }
    Must ($null -ne (Get-TreeReferenceProblem @($reference) (Join-Path $localAppData 'Programs\chromium-9.9') @()) -and
        $null -eq (Get-TreeReferenceProblem @($reference) (Join-Path $localAppData 'Programs\chromium-9.9') @($appEffects.value.id)) -and
        $null -eq (Get-TreeReferenceProblem @($reference) (Join-Path $localAppData 'Programs\chromium-9.8') @())) 'an App Paths value keeps the tree it names unless the same plan removes it'
    CollectAppPathGarbage @(AppState 'owned-match' $false $true)
    Must ((ObserveKey $appSubkey).exists -and (Phases $appEffects.key) -ceq 'intent,commit') 'no App Paths collection while a seed would overwrite a profile'
    $held = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($appSubkey, $true)
    try { $held.SetValue('Path', 'foreign') } finally { $held.Close() }
    CollectAppPathGarbage @()  # the unique name is declared by no lock: retired
    $keptDrift = @($script:packageDrift)
    $held = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($appSubkey, $true)
    try { $held.DeleteValue('Path') } finally { $held.Close() }
    $script:packageDrift = @()
    CollectAppPathGarbage @()
    Must (@($keptDrift | Where-Object { $_ -like "*holds foreign content the plan does not remove: value 'Path'*" }).Count -and
        -not (ObserveKey $appSubkey).exists -and (Phases $appEffects.key) -ceq 'intent,commit,undone' -and
        (Phases $appEffects.value) -ceq 'intent,commit,undone,intent,commit,undone' -and -not $script:packageDrift.Count) 'A3 keeps a retired App Paths key with foreign content; without it the name is collected, value then key'
    # Interruptions: (a) part of the inventory staged -> cleaned and voided; (b) a file the inventory
    # does not name -> kept, and the intent stays open; (c) renamed but not committed -> confirmed.
    $a, $b, $c = (Tree 'noctty-crash-a' $two), (Tree 'noctty-crash-b' $two), (Tree 'noctty-crash-c' $two)
    $stageA, $stageB, $stageC = (Staging $a), (Staging $b), (Staging $c)
    WriteRecord 'intent' $a $null $stageA; WriteRecord 'intent' $b $null $stageB; WriteRecord 'intent' $c $null $stageC
    $null = New-Item -ItemType Directory -Path "$stageA\noctty", "$stageB\noctty", "$stageC\noctty\d"
    foreach ($file in "$stageA\noctty\a.txt", "$stageB\noctty\a.txt", "$stageC\noctty\a.txt") { [IO.File]::WriteAllText($file, 'a') }
    [IO.File]::WriteAllText("$stageB\foreign.txt", 'x')
    [IO.File]::WriteAllText("$stageC\noctty\d\b.txt", 'b')
    [IO.Directory]::Move($stageC, $c.target)
    RecoverId $a.id
    Refused { RecoverId $b.id } '*is kept*'
    RecoverId $c.id
    Must ((Phases $a) -ceq 'intent,void' -and -not (Test-Path -LiteralPath $stageA)) 'a partial staging directory is cleaned and voided'
    Must ((Phases $b) -ceq 'intent' -and (Test-Path -LiteralPath "$stageB\foreign.txt") -and (Test-Path -LiteralPath "$stageB\noctty\a.txt")) 'foreign staging content is kept'
    Must ((Phases $c) -ceq 'intent,commit') 'a renamed tree without its commit is confirmed'
    # Undo order by kind and key depth, stable within an id; then a tree partly removed by hand resumes to empty, undone once.
    $mixed = @{ steps = @(@{ id = 't'; kind = 'tree-extracted'; action = 'delete-file' }, @{ id = 't'; kind = 'tree-extracted'; action = 'remove-empty-directory' },
        @{ id = 'f'; kind = 'file-created'; action = 'delete-file' }, @{ id = 'k1'; kind = 'registry-key-created'; action = 'delete-empty-key'; key = 'HKCU\A' },
        @{ id = 'k2'; kind = 'registry-key-created'; action = 'delete-empty-key'; key = 'HKCU\A\B' }, @{ id = 'v'; kind = 'registry-value'; action = 'delete-registry-value' }) }
    Must ((@(OrderedSteps $mixed | ForEach-Object { "$($_.id):$($_.action)" }) -join ',') -ceq
        'v:delete-registry-value,k2:delete-empty-key,k1:delete-empty-key,f:delete-file,t:delete-file,t:remove-empty-directory') 'undo order'
    Refused { OrderedSteps @{ steps = @(@{ id = 'x'; kind = 'file-replaced'; action = 'restore-file' }) } } 'Unsupported undo step*'
    # The Uninstall answer names every step shape; a created key has neither path nor name (CI #67).
    Must (((@([ordered]@{ action = 'delete-file'; path = 'C:\u\f'; expectSha256 = (Sha 'a') }, [ordered]@{ action = 'remove-empty-directory'; path = 'C:\u\d' },
            [ordered]@{ action = 'delete-registry-value'; key = 'HKCU\A'; name = 'v' }, [ordered]@{ action = 'delete-empty-key'; key = 'HKCU\A' }) |
            ForEach-Object { StepText $_ }) -join ';') -ceq 'delete-file C:\u\f;remove-empty-directory C:\u\d;delete-registry-value HKCU\A\v;delete-empty-key HKCU\A') 'step text for every step shape'
    [IO.File]::Delete("$($c.target)\noctty\a.txt")
    $observed = @{}; $observed[$c.id] = Observe $c
    $plan = Get-UninstallPlan @(RecordsOf $c.id) $observed
    Must ($plan.ok -and ($plan.resumed -join ',') -ceq $c.id) 'a partly removed tree resumes'
    UndoOwnedSteps @(OrderedSteps $plan)
    Must ((Phases $c) -ceq 'intent,commit,undone' -and -not (Test-Path -LiteralPath $c.target)) 'the resumed tree is removed exactly, undone once'
    # Keys and values: a missing parent or an existing key is refused before any intent; replays void and confirm.
    $shared = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Software\Classes\CLSID')
    $sharedMade = $null -eq $shared
    if ($sharedMade) { $shared = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey('Software\Classes\CLSID') }  # shared: the caller's
    $shared.Close()
    $key, $server, $value = $selected.keys[0], $selected.keys[1], $selected.values[0]
    try {
        Refused { CreateOwnedKey $server } '*parent key is missing*'
        WriteRecord 'intent' $key $null $null; RecoverId $key.id
        WriteRecord 'intent' $key $null $null
        [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey(($key.target -replace '^HKCU\\', '')).Close()
        RecoverId $key.id
        Refused { CreateOwnedKey $key } '*it exists*'
        CreateOwnedKey $server
        WriteRecord 'intent' $value $null $null; RecoverId $value.id
        CreateOwnedValue $value
        Must ((Phases $key) -ceq 'intent,void,intent,commit' -and (Phases $server) -ceq 'intent,commit' -and
            (Phases $value) -ceq 'intent,void,intent,commit' -and (Observe $value).data -ceq 'proof') 'key and value creation and replay'
        # The COM reader names the owned value; the plan removing it frees the tree.
        $serverKey = $server.target -replace '^HKCU\\', ''
        $refs = @(NocttyReferences @(, @('HKCU', 'CurrentUser', 'Default')) @($serverKey))
        Must ($refs.Count -eq 1 -and $refs[0].id -ceq $value.id -and $refs[0].data -ceq 'proof' -and
            $null -eq (Get-TreeReferenceProblem $refs $nocttyDirectory @($value.id))) 'the COM reference reader'
        # A created key someone else wrote into is kept, and stays owned; the foreign value survives.
        $foreign = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($serverKey, $true)
        try { $foreign.SetValue('Foreign', 'x') } finally { $foreign.Close() }
        $observed = @{}; foreach ($e in $value, $server, $key) { $observed[$e.id] = Observe $e }
        $plan = Get-UninstallPlan (@(RecordsOf $value.id) + @(RecordsOf $server.id) + @(RecordsOf $key.id)) $observed
        Must ($plan.ok -and (@(OrderedSteps $plan | ForEach-Object { $_.action }) -join ',') -ceq 'delete-registry-value,delete-empty-key,delete-empty-key') 'value, then keys deepest first'
        Refused { UndoOwnedSteps @(OrderedSteps $plan) } '*holds foreign content*'
        Must ((Phases $value) -like '*,undone' -and (Phases $server) -ceq 'intent,commit' -and (ObserveValue 'Foreign' $serverKey).exists) 'a key holding foreign content is kept'
    } finally {
        # Only what this block made, deepest first, never recursively.
        $open = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey(($server.target -replace '^HKCU\\', ''), $true)
        if ($null -ne $open) { try { $open.DeleteValue('', $false) } finally { $open.Close() } }
        foreach ($made in @($server, $key)) { [Microsoft.Win32.Registry]::CurrentUser.DeleteSubKey(($made.target -replace '^HKCU\\', ''), $false) }
        $shared = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Software\Classes\CLSID')
        $empty = $shared.SubKeyCount + $shared.ValueCount -eq 0
        $shared.Close()
        if ($sharedMade -and $empty) { [Microsoft.Win32.Registry]::CurrentUser.DeleteSubKey('Software\Classes\CLSID', $false) }
    }
    # Restore's selection rollback, on the real %%Startup (put back afterwards): the check fails
    # because this scratch registration is absent. Only what the run wrote goes back to what it
    # read, even though the write-once record holds an older prior (nothing selected).
    $startupSubkey, $terminalStartup = 'Console\%%Startup', 'HKCU:\Console\%%Startup'
    $windowsTerminalConsole, $nocttyTerminal = '{2EACA947-7F5F-4CFA-BA87-8F7FBEEFBE69}', '{33368C6F-D328-410C-B225-26DC9F12C728}'
    $terminalProvenance, $userTerminal = (Join-Path $Scratch 'provenance\default-terminal.json'), '{E12CFF52-A866-4C77-9A90-F570A7AA2C6B}'
    $startup, $saved = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($startupSubkey), @{}
    foreach ($name in 'DelegationConsole', 'DelegationTerminal') {
        if ($startup.GetValueNames() -contains $name) { $saved[$name] = @($startup.GetValueKind($name), $startup.GetValue($name, $null, 'DoNotExpandEnvironmentNames')) }
    }
    try {
        RecordPriorTerminal $null $null
        $startup.SetValue('DelegationConsole', $windowsTerminalConsole, 'String')
        $startup.SetValue('DelegationTerminal', $userTerminal, 'String')
        Refused { SelectNoctty -Check } '*registration is incomplete*'
        Must ((StartupPair).console -ceq $windowsTerminalConsole -and (StartupPair).terminal -ceq $userTerminal) 'a failed check restores the selection this run found'
        $startup.DeleteValue('DelegationConsole'); $startup.DeleteValue('DelegationTerminal')
        Refused { SelectNoctty -Check } '*registration is incomplete*'
        Must ($null -eq (StartupPair).console -and $null -eq (StartupPair).terminal) 'both values this run wrote are removed again'
    } finally {
        foreach ($name in 'DelegationConsole', 'DelegationTerminal') {
            if ($saved.Contains($name)) { $startup.SetValue($name, $saved[$name][1], $saved[$name][0]) } else { $startup.DeleteValue($name, $false) }
        }
        $startup.Close()
    }
    CreateOwnedFile $selected.config ([Text.UTF8Encoding]::new($false).GetBytes($nocttyConfigText))
    Must ((Phases $selected.config) -ceq 'intent,commit') 'the config is created from bytes'
    if ($Real) {
        CreateOwnedTree $selected.tree $zip
        Must ((Phases $selected.tree) -ceq 'intent,commit' -and (Test-EffectStateEqual tree-extracted $selected.tree.desired (Observe $selected.tree)) -and
            -not (Test-Path ($selected.tree.target + '.*.staging'))) 'the bundled Noctty is extracted exactly, through staging'
        Refused { CreateOwnedTree $selected.tree $zip } '*it exists*'
    }
    # The ledger index answers exactly what a full scan of ledgerRecords answers (the same records, same order, same ids),
    # after this block's writes and again after ReadLedger rebuilds it from disk; ids that differ only in case stay apart.
    function ScanIds { @($script:ledgerRecords | ForEach-Object { [string](Get-Field $_ 'id') } | Sort-Object -Unique -CaseSensitive) }
    function IndexAgrees {
        $ids = @(ScanIds)
        (@(LedgerIds) -join '|') -ceq ($ids -join '|') -and -not @($ids | Where-Object {
            $id = $_
            $indexed, $scanned = @(RecordsOf $id), @($script:ledgerRecords | Where-Object { [string](Get-Field $_ 'id') -ceq $id })
            $indexed.Count -ne $scanned.Count -or @(for ($i = 0; $i -lt $indexed.Count; $i++) { if (-not [object]::ReferenceEquals($indexed[$i], $scanned[$i])) { $i } }).Count
        }).Count -and @(RecordsOf 'no such id').Count -eq 0
    }
    # The per-id attempt cache (read-only, in the index entry) equals a fresh Get-EffectAttempt for every id: the
    # same problem, closed flag and record objects; a second read returns the cached object itself; and
    # Get-EffectClass given it answers exactly as Get-EffectClass computing it from the records.
    function SameAttempt($Cached, $Fresh) {
        $a, $b = @($Cached.records), @($Fresh.records)
        [string]$Cached.problem -ceq [string]$Fresh.problem -and $Cached.closed -eq $Fresh.closed -and $a.Count -eq $b.Count -and
            -not @(for ($i = 0; $i -lt $a.Count; $i++) { if (-not [object]::ReferenceEquals($a[$i], $b[$i])) { $i } }).Count
    }
    function CacheAgrees {
        -not @(ScanIds | Where-Object {
            $cached = AttemptOf $_
            -not (SameAttempt $cached (Get-EffectAttempt (RecordsOf $_))) -or -not [object]::ReferenceEquals((AttemptOf $_), $cached)
        }).Count
    }
    function ClassAgrees {
        -not @(ScanIds | Where-Object {
            $current = Observe @(RecordsOf $_)[0]
            $with, $without = (Get-EffectClass $null $current '' $null (AttemptOf $_)), (Get-EffectClass (RecordsOf $_) $current)
            "$($with.class)|$($with.resolution)|$($with.reason)" -cne "$($without.class)|$($without.resolution)|$($without.reason)"
        }).Count
    }
    Must ((@(ScanIds).Count -ge 8) -and (IndexAgrees) -and (CacheAgrees) -and (ClassAgrees)) 'the ledger index and attempt cache equal a full scan'
    # A write drops that id's cached attempt (here a closed package tree id gains a new intent).
    $cachedBefore = AttemptOf $pkgTree.id
    WriteRecord 'intent' $pkgTree $null $null
    $cachedAfter = AttemptOf $pkgTree.id
    Must ($cachedBefore.closed -and -not $cachedAfter.closed -and @($cachedAfter.records).Count -eq 1 -and
        [object]::ReferenceEquals(@($cachedAfter.records)[0], @(RecordsOf $pkgTree.id)[-1]) -and (CacheAgrees)) 'a write drops that id''s cached attempt'
    $null = ReadLedger
    Must ((IndexAgrees) -and (CacheAgrees) -and (ClassAgrees) -and @($script:ledgerRecords).Count -eq $script:nextSeq - 1) 'index and cache equal a full scan after ReadLedger'
    $saved = $script:ledgerRecords, $script:ledgerById
    try {
        $script:ledgerRecords, $script:ledgerById = @(), (NewLedgerIndex)
        foreach ($id in 'case-A', 'CASE-a', 'case-A') { $record = [pscustomobject]@{ id = $id }; $script:ledgerRecords += $record; IndexRecord $record }
        Must (@(RecordsOf 'case-A').Count -eq 2 -and @(RecordsOf 'CASE-a').Count -eq 1 -and @(RecordsOf 'case-a').Count -eq 0) 'ids that differ only in case stay apart'
        Refused { LedgerIds } 'Two effect ledger ids differ only in case.'
        # A malformed record reaching an id whose valid attempt is already cached makes that id malformed at once.
        $cachedTree = Tree 'chromium-2' $two
        function CacheRecord($Seq, [string]$Phase, $Observed) {
            $record = @{ ledger = 'effects'; schema = 1; seq = $Seq; phase = $Phase }
            foreach ($k in $cachedTree.Keys) { $record[$k] = $cachedTree[$k] }
            if ($null -ne $Observed) { $record.observed = $Observed }
            $record
        }
        $badSchema = CacheRecord 3 'undone' @{ exists = $false }; $badSchema.schema = 2
        foreach ($case in @(@($badSchema, '*schema is not 1*'), @((CacheRecord 2 'undone' @{ exists = $false }), '*seq repeats*'),
                @((CacheRecord 3 'void' @{ exists = $false }), '*cannot be voided*'))) {
            $script:ledgerRecords, $script:ledgerById = @(), (NewLedgerIndex)
            foreach ($record in (CacheRecord 1 'intent' $null), (CacheRecord 2 'commit' $cachedTree.desired)) { $script:ledgerRecords += $record; IndexRecord $record }
            Must ($null -eq (AttemptOf $cachedTree.id).problem -and @(OpenAttempt $cachedTree.id).Count -eq 2) 'a valid attempt is cached'
            $script:ledgerRecords += $case[0]; IndexRecord $case[0]
            Must ((AttemptOf $cachedTree.id).problem -like $case[1]) "a cached id becomes malformed: $($case[1])"
            Refused { OpenAttempt $cachedTree.id } $case[1]
        }
    } finally { $script:ledgerRecords, $script:ledgerById = $saved }
    Must ((IndexAgrees) -and (CacheAgrees)) 'the saved index and cache are restored'
    # Get-Fields reads what Get-Field reads, for every shape (arrays kept as stored, compared as values);
    # a dictionary keeps its own key comparison; a scalar field stored as a one-element array is malformed.
    $fieldNames = @('a', 'b', 'c', 'd', 'e', 'f', 'missing', 'Length')
    foreach ($shape in @([pscustomobject]@{ a = 1; b = 'x'; c = @('m'); d = @(); e = $null; f = @{ g = 1 } },
            @{ a = 1; b = 'x'; c = @('m', 'n'); d = @(); e = $null; f = @{ g = 1 } }, [ordered]@{ A = 1; b = 'x'; c = @('m') }, $null, 'text', 42)) {
        $batch = Get-Fields $shape $fieldNames
        Must (@($batch.Keys).Count -eq $fieldNames.Count -and -not @($fieldNames | Where-Object {
            (ConvertTo-Json -Compress -Depth 3 -InputObject @($batch[$_])) -cne (ConvertTo-Json -Compress -Depth 3 -InputObject @(Get-Field $shape $_)) }).Count) 'Get-Fields equals Get-Field'
    }
    $ordinalFields = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal); $ordinalFields['Key'] = 1
    $oneElement = (Get-Fields ([pscustomobject]@{ c = @('m') }) @('c')).c
    Must ($null -eq (Get-Fields $ordinalFields @('key')).key -and (Get-Fields $ordinalFields @('Key')).Key -eq 1 -and $oneElement -is [array] -and $oneElement.Count -eq 1 -and
        (Get-EffectRecordProblem @{ ledger = 'effects'; schema = 1; seq = @(1); phase = 'intent'; kind = 'file-created'; id = 'x'; target = 'C:\u\f'
            prior = @{ exists = $false }; desired = @{ exists = $true; sha256 = ('a' * 64) } }) -ceq 'seq is not a positive integer.') 'Get-Fields keeps arrays and source key comparison'
    "PASS primitives in PowerShell $($PSVersionTable.PSVersion)"
}
function Primitive51([string]$Scratch) {
    $ErrorActionPreference = 'Continue'
    $PSNativeCommandUseErrorActionPreference = $false
    $load = "`$a = [Management.Automation.Language.Parser]::ParseFile('$(Join-Path $PSScriptRoot 'proof.ps1')', [ref]`$null, [ref]`$null); " +
        ". ([scriptblock]::Create(`$a.Find({ param(`$n) `$n -is [Management.Automation.Language.FunctionDefinitionAst] -and `$n.Name -ceq 'PrimitiveProof' }, `$true).Extent.Text)); " +
        "PrimitiveProof '$PSScriptRoot' '$Scratch' -Real"
    $out = @(& $windowsPowerShell -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command $load 2>&1 | ForEach-Object { [string]$_ })
    if ($LASTEXITCODE -ne 0 -or -not $out.Count -or $out[-1] -notlike 'PASS primitives*') { throw "The 5.1 primitive proof failed: $($out -join ' ')" }
    $out[-1]
}
$primitives7 = PrimitiveProof $PSScriptRoot (Join-Path $env:RUNNER_TEMP ('primitives-' + [guid]::NewGuid().ToString('N')))

# The Noctty effect descriptions and observers on synthetic targets: a fresh RUNNER_TEMP
# directory (never deleted), where the 5.1 child creates the tree and config, and a proof HKCU key.
$winFunctions = 'FileEffect', 'ValueEffect', 'KeyEffect', 'NocttyEffects', 'ObserveFile', 'ObserveValue', 'ObserveTree', 'ObserveKey', 'ObserveNoctty'
$winAst = [Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'win.ps1'), [ref]$null, [ref]$null)
foreach ($definition in $winAst.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -cin $winFunctions }, $false)) {
    . ([scriptblock]::Create($definition.Extent.Text))
}
$effectRoot = Join-Path $env:RUNNER_TEMP ('noctty-effects-' + [guid]::NewGuid().ToString('N'))
$localAppData = $effectRoot
$nocttyDirectory, $nocttyConfig = "$effectRoot\Programs\noctty-$($manifest.noctty.version)", "$effectRoot\noctty\config.ghostty"
$nocttyConfigText = 'font-family = ' + $manifest.noctty.fontFamily + "`n"
$nocttyRegistration = Get-NocttyRegistration $manifest.noctty.registration $nocttyDirectory $manifest.noctty.files
$selected = NocttyEffects
$all = @($selected.tree, $selected.config, $selected.startup) + $selected.keys + $selected.values
foreach ($effect in $all) {
    $record = @{ ledger = 'effects'; schema = 1; seq = 1; phase = 'intent' }
    foreach ($k in $effect.Keys) { $record[$k] = $effect[$k] }
    Must ($null -eq (Get-EffectRecordProblem $record)) "Noctty effect $($effect.id) is a well-formed owned intent"
}
$configBytes = [Text.UTF8Encoding]::new($false).GetBytes($nocttyConfigText)
Must (@($all | ForEach-Object { $_.id } | Sort-Object -Unique).Count -eq 19 -and $selected.startup.target -ceq 'HKCU\Console\%%Startup' -and
    (@($selected.keys | ForEach-Object { $_.target } | Sort-Object) -join ';') -ceq (@($tenKeys | ForEach-Object { "HKCU\$_" } | Sort-Object) -join ';') -and
    @($selected.values | Where-Object { $_.name -ceq 'ThreadingModel' -and $_.desired.data -ceq 'Both' }).Count -eq 1 -and
    $selected.tree.desired.files.Count -eq @($manifest.noctty.files.PSObject.Properties).Count -and
    $selected.config.desired.sha256 -ceq [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($configBytes)).ToLowerInvariant()) 'the 19 Noctty effects'
# Observation: absent, then the exact extracted inventory and config; every anomaly differs.
Must (-not $(ObserveNoctty $selected.tree).exists -and -not $(ObserveNoctty $selected.config).exists) 'absent Noctty targets'
$primitives51 = Primitive51 $effectRoot
$exact = { (Test-EffectStateEqual tree-extracted $selected.tree.desired (ObserveNoctty $selected.tree)) }
Must ((& $exact) -and (Test-EffectStateEqual file-created $selected.config.desired (ObserveNoctty $selected.config))) 'the extracted tree and config are exact'
$extraDir, $junction, $extraFile = "$nocttyDirectory\noctty\empty", "$nocttyDirectory\noctty\link", "$nocttyDirectory\noctty\extra.txt"
$null = New-Item -ItemType Directory -Path $extraDir
Must (-not (& $exact) -and @((ObserveNoctty $selected.tree).other) -ccontains 'noctty/empty/') 'an empty directory differs'
[IO.Directory]::Delete($extraDir, $false)
$null = New-Item -ItemType Junction -Path $junction -Target $effectRoot
Must (-not (& $exact) -and @((ObserveNoctty $selected.tree).other) -ccontains 'noctty/link') 'a junction differs and is not followed'
[IO.Directory]::Delete($junction, $false)
[IO.File]::WriteAllText($extraFile, 'proof')
Must (-not (& $exact)) 'an extra file differs'
[IO.File]::Delete($extraFile)
Must ((& $exact)) 'the tree is exact again'
MustReject { ObserveTree $nocttyConfig } 'Not a plain directory*'
# Registry: a proof key and value are observed exactly; a real selected key is only read.
$proofKey = 'Software\windows-iac-proof-' + [guid]::NewGuid().ToString('N')
Must (-not (ObserveKey $proofKey).exists) 'an absent key'
$created = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($proofKey)
try { $created.SetValue('', 'proof', [Microsoft.Win32.RegistryValueKind]::String) } finally { $created.Close() }
Must ((ObserveKey $proofKey).exists -and (Test-EffectStateEqual registry-value (ValueEffect '' 'proof' "HKCU\$proofKey").desired (ObserveValue '' $proofKey))) 'a present key and value'
$created = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($proofKey, $true)
try { $created.DeleteValue('') } finally { $created.Close() }
[Microsoft.Win32.Registry]::CurrentUser.DeleteSubKey($proofKey)
Must ((ObserveNoctty $selected.keys[0]).exists -is [bool] -and (ObserveNoctty $selected.values[0]).exists -is [bool]) 'selected registry targets are read'
# The tree of another Noctty version stays readable; nothing else beside or beneath it is.
Must (-not (ObserveNoctty @{ kind = 'tree-extracted'; target = "$effectRoot\Programs\noctty-0.9.1" }).exists) 'an older Noctty tree is observed'
foreach ($foreign in @("$effectRoot\Programs\nocttyx-1", "$effectRoot\Programs\noctty-", "$effectRoot\Programs\noctty-1.",
        "$effectRoot\Programs\noctty-1\sub", "$effectRoot\Other\noctty-1", "$effectRoot\Programs\x\..\noctty-1")) {
    MustReject { ObserveNoctty @{ kind = 'tree-extracted'; target = $foreign } } '*is not a selected Noctty effect.'
}
MustReject { ObserveNoctty (KeyEffect 'Software\Classes\CLSID') } '*is not a selected Noctty effect.'
MustReject { ObserveNoctty (ValueEffect 'Present' 'x' $selected.values[0].target) } '*is not a selected Noctty effect.'

# ---- Owned fonts through the effect ledger (native files and HKCU values) ----
$fonts = @($manifest.fonts)
if ($fonts.Count -lt 2) { throw 'The proof needs at least two selected fonts.' }
$fontDir = $validated.fontDirectory
$fontSubkey = 'Software\Microsoft\Windows NT\CurrentVersion\Fonts'
$ledgerDir = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'windows-iac\ledger'
function FontPath($Font) { Join-Path $fontDir $Font.file }
function ValueName($Font) { $Font.fullName + ' (TrueType)' }
function FontValue([string]$Name) {
    $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($fontSubkey)
    if ($null -eq $key) { return $null }
    try { $key.GetValue($Name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames) } finally { $key.Close() }
}
function SetFontValue([string]$Name, $Data) {
    $key = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($fontSubkey)
    try { if ($null -eq $Data) { $key.DeleteValue($Name, $false) } else { $key.SetValue($Name, $Data, [Microsoft.Win32.RegistryValueKind]::String) } }
    finally { $key.Close() }
}
function FileId([string]$Path) { 'file-created:' + $Path.ToUpperInvariant() }
function ValueId([string]$Name) { 'registry-value:' + ('HKCU\' + $fontSubkey + '|' + $Name).ToUpperInvariant() }
# Every record is read on every call; a parse is reused only for the same file name with exactly the same text
# (the proof itself rewrites and tears records), and files gone from the ledger leave the cache. Records are read-only.
$script:ledgerParsed = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
function Ledger {
    if (-not (Test-Path -LiteralPath $ledgerDir)) { $script:ledgerParsed.Clear(); return @() }
    $present = @{}
    $records = @(foreach ($file in @(Get-ChildItem -LiteralPath $ledgerDir -Filter '*.json' | Sort-Object Name)) {
        $text = [IO.File]::ReadAllText($file.FullName)
        $present[$file.Name] = $true
        if (-not $script:ledgerParsed.ContainsKey($file.Name) -or $script:ledgerParsed[$file.Name].text -cne $text) {
            $script:ledgerParsed[$file.Name] = [pscustomobject]@{ text = $text; record = ($text | ConvertFrom-Json) }
        }
        $script:ledgerParsed[$file.Name].record
    })
    foreach ($name in @($script:ledgerParsed.Keys | Where-Object { -not $present.ContainsKey($_) })) { $null = $script:ledgerParsed.Remove($name) }
    $records
}
function Phases([string]$Id) { @(Ledger | Where-Object { $_.id -ceq $Id } | ForEach-Object { $_.phase }) -join ',' }
# Apply now also converges Noctty, so font counts are taken over font records only.
function IsFontRecord($Record) {
    ($Record.kind -ceq 'file-created' -and [IO.Path]::GetDirectoryName($Record.target) -eq $fontDir) -or
        ($Record.kind -ceq 'registry-value' -and $Record.target -ceq ('HKCU\' + $fontSubkey))
}
# A record the proof writes itself, in the ledger's own format and next seq, to model an interrupted run.
function Craft([hashtable]$Fields) {
    $seq = 1 + [long](@(Ledger | ForEach-Object { [long]$_.seq }) + 0 | Measure-Object -Maximum).Maximum
    $entry = [ordered]@{ ledger = 'effects'; schema = 1; seq = $seq }
    foreach ($k in 'phase', 'id', 'kind', 'target', 'name', 'prior', 'desired', 'observed', 'temp', 'package') { if ($Fields.ContainsKey($k)) { $entry[$k] = $Fields[$k] } }
    $stream = [IO.FileStream]::new((Join-Path $ledgerDir ('{0:D8}.json' -f $seq)), [IO.FileMode]::CreateNew)
    try { $bytes = [Text.Encoding]::UTF8.GetBytes(($entry | ConvertTo-Json -Depth 8 -Compress)); $stream.Write($bytes, 0, $bytes.Length) }
    finally { $stream.Dispose() }
}
function CraftFile([string]$Path, [string]$Sha, [string[]]$Phases) {
    $desired = @{ exists = $true; sha256 = $Sha }
    foreach ($phase in $Phases) {
        $fields = @{ phase = $phase; id = (FileId $Path); kind = 'file-created'; target = $Path; prior = $absent; desired = $desired }
        if ($phase -ceq 'commit') { $fields.observed = $desired }
        Craft $fields
    }
}
function CraftValue([string]$Name, [string]$Data, [string[]]$Phases) {
    $desired = @{ exists = $true; type = 'String'; data = $Data }
    foreach ($phase in $Phases) {
        $fields = @{ phase = $phase; id = (ValueId $Name); kind = 'registry-value'; target = ('HKCU\' + $fontSubkey); name = $Name
            prior = $absent; desired = $desired }
        if ($phase -ceq 'commit') { $fields.observed = $desired }
        Craft $fields
    }
}
function Bytes([string]$Text) { [Text.Encoding]::UTF8.GetBytes($Text) }
function ShaOf([byte[]]$Bytes) { [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Bytes)).ToLowerInvariant() }
function RunUninstall([switch]$Apply) { Win51 @(@('-Mode', 'Uninstall') + @(if ($Apply) { '-Apply' })) }
function AssertEmpty {
    foreach ($font in $fonts) {
        if ((Test-Path -LiteralPath (FontPath $font)) -or $null -ne (FontValue (ValueName $font))) { throw "Uninstall left $($font.fullName)." }
    }
}
function Snapshot {
    [ordered]@{ ledger = @(Get-ChildItem -LiteralPath $ledgerDir -Force | ForEach-Object { "$($_.Name)=$((Get-FileHash -LiteralPath $_.FullName).Hash)" })
        files = @($fonts | ForEach-Object { if (Test-Path -LiteralPath (FontPath $_)) { (Get-FileHash -LiteralPath (FontPath $_)).Hash } else { '-' } })
        values = @($fonts | ForEach-Object { [string](FontValue (ValueName $_)) }) } | ConvertTo-Json -Compress
}
# ---- G4/G3 measurement and gate ----
# It runs before the font proof, so a later failure (e.g. a registered font Windows keeps
# open) cannot suppress this evidence; its gate fails the proof only at the end. The exact bundled Noctty registers itself for the
# default terminal on this disposable runner, and native RegistryKey snapshots show what it
# changed. Values under HKCU\Software\Classes and HKCU\Console are printed in full, with no
# noise subtracted: they are the evidence for the Nix list. Elsewhere only key, value name
# and change are printed, never data; Noctty mentions are checked on the raw delta and
# reported by token.
$g4 = [ordered]@{ status = 'not run' }
$sep = [char]1  # separates key and value name in snapshot entries; <key> marks the key itself
function Say([string]$Line) { Write-Host "G4 $Line" }
function ValueText([Microsoft.Win32.RegistryKey]$Key, [string]$Name) {
    $kind = [string]$Key.GetValueKind($Name)
    $value = $Key.GetValue($Name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
    $data = switch ($kind) {
        'DWord' { [string][BitConverter]::ToUInt32([BitConverter]::GetBytes([int]$value), 0) }
        'QWord' { [string][BitConverter]::ToUInt64([BitConverter]::GetBytes([long]$value), 0) }
        'MultiString' { @($value) -join [char]0 }
        { $_ -in @('String', 'ExpandString') } { [string]$value }
        default { if ($value -is [byte[]]) { [Convert]::ToHexString($value) } else { [string]$value } }
    }
    "${kind}:$data"
}
# key<SOH>name -> kind:data for every value, and key<SOH><key> for every key, beneath $Roots.
function RegistrySnapshot([string]$Hive, [string]$View, [string[]]$Roots) {
    $map = @{}
    $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey($Hive, $View)
    try {
        $pending = [Collections.Generic.Stack[string]]::new()
        foreach ($root in $Roots) { $pending.Push($root) }
        while ($pending.Count) {
            $path = $pending.Pop()
            try { $key = if ($path) { $base.OpenSubKey($path) } else { $base } } catch { $map["$path$sep<unreadable>"] = 'unreadable'; continue }
            if ($null -eq $key) { continue }
            try {
                $map["$path$sep<key>"] = 'key'
                foreach ($name in $key.GetValueNames()) { $map["$path$sep$name"] = ValueText $key $name }
                foreach ($sub in $key.GetSubKeyNames()) { $pending.Push($(if ($path) { "$path\$sub" } else { $sub })) }
            } catch { $map["$path$sep<unreadable>"] = 'unreadable' } finally { if ($path) { $key.Close() } }
        }
    } finally { $base.Close() }
    $map
}
function SnapshotDiff($Before, $After) {
    foreach ($entry in @(@($Before.Keys) + @($After.Keys) | Sort-Object -Unique)) {
        $old, $new = $Before[$entry], $After[$entry]
        if ($old -ceq $new) { continue }
        $key, $name = $entry.Split($sep, 2)
        [pscustomobject]@{ entry = $entry; key = $key; name = $name; before = $old; after = $new
            change = $(if ($null -eq $old) { 'added' } elseif ($null -eq $new) { 'removed' } else { 'changed' }) }
    }
}
# Every file (size and hash) and every directory, including the directory itself, so a
# created or removed empty directory shows too.
function FileSnapshot([string]$Directory) {
    $map = @{}
    if (Test-Path -LiteralPath $Directory) {
        $map[".$sep"] = 'directory'
        foreach ($item in @(Get-ChildItem -LiteralPath $Directory -Recurse -Force)) {
            $map[$item.FullName.Substring($Directory.Length + 1) + $sep] = $(if ($item.PSIsContainer) { 'directory' } else {
                "$($item.Length) bytes, sha256 $((Get-FileHash -LiteralPath $item.FullName).Hash)" })
        }
    }
    $map
}
# A vendor command with a deadline, so a window that stays open cannot hold the proof.
function Vendor([string]$Exe, [string]$Argument) {
    $info = [Diagnostics.ProcessStartInfo]::new($Exe, $Argument)
    $info.UseShellExecute, $info.RedirectStandardOutput, $info.RedirectStandardError, $info.CreateNoWindow = $false, $true, $true, $true
    $process = [Diagnostics.Process]::Start($info)
    $out, $err = $process.StandardOutput.ReadToEndAsync(), $process.StandardError.ReadToEndAsync()
    if (-not $process.WaitForExit(60000)) { $process.Kill($true); return [pscustomobject]@{ exit = 'timeout after 60 s'; output = '' } }
    $process.WaitForExit()
    [pscustomobject]@{ exit = $process.ExitCode; output = @(($out.Result + "`n" + $err.Result) -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -First 20) -join ' | ' }
}
function Region([string]$Key) { $Key -match '^(Software\\Classes|Console)(\\|$)' }
# The vendor registers only with HKCU\Console\%%Startup\DelegationConsole selecting
# Windows Terminal's OpenConsole, which Restore writes just before registering. That
# precondition is seeded before S0, so only the vendor's own changes are in the delta (a
# vendor rewrite of it still shows as changed), and the original key and both values are
# put back afterwards, the result read back and reported.
$startupPath = 'Console\%%Startup'
$startupSaved = $null  # the original state, once read; restoration runs only then
function StartupState {
    $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($startupPath)
    if ($null -eq $key) { return [ordered]@{ keyExisted = $false; values = @{} } }
    try {
        $values = @{}
        foreach ($name in 'DelegationConsole', 'DelegationTerminal') {
            if ($key.GetValueNames() -contains $name) {
                $values[$name] = [ordered]@{ kind = $key.GetValueKind($name)
                    data = $key.GetValue($name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames) }
            }
        }
        [ordered]@{ keyExisted = $true; values = $values }
    } finally { $key.Close() }
}
function StartupText($State) {
    "key $(if ($State.keyExisted) { 'present' } else { 'absent' })" + (@('DelegationConsole', 'DelegationTerminal' | ForEach-Object {
        $v = $State.values[$_]; "; $_ $(if ($v) { "$($v.kind):$($v.data)" } else { 'absent' })" }) -join '')
}
try {
    $PSNativeCommandUseErrorActionPreference = $false
    $noctty = '{33368C6F-D328-410C-B225-26DC9F12C728}'; $proxy = '{1D349824-21FB-46C7-ACF3-746EDC991D52}'
    $iids = @('{59D55CCE-FC8A-48B4-ACE8-0A9286C6557F}', '{AA6B364F-4A50-4176-9002-0AE755E7B5EF}', '{6F23DA90-15C5-4203-9DB0-64E73F1B1B00}')
    $g4Dir = Join-Path $env:RUNNER_TEMP ('noctty-g4-' + [guid]::NewGuid().ToString('N'))  # fresh, never deleted
    $null = New-Item -ItemType Directory -Path $g4Dir
    $ProgressPreference = 'SilentlyContinue'
    Expand-Archive -LiteralPath (Join-Path $PSScriptRoot 'payload/noctty.zip') -DestinationPath $g4Dir
    $install = Join-Path $g4Dir 'noctty'
    $wrong = @($manifest.noctty.files.PSObject.Properties | Where-Object {
        (Get-FileHash -LiteralPath (Join-Path $g4Dir $_.Name.Replace('/', '\'))).Hash -ne $_.Value })
    Say "bundled Noctty $($manifest.noctty.version) extracted to $install; files differing from the manifest: $($wrong.Count)"
    $userDir = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'noctty'
    $hklmRoots = @("SOFTWARE\Classes\CLSID\$noctty", "SOFTWARE\Classes\CLSID\$proxy") + @($iids | ForEach-Object { "SOFTWARE\Classes\Interface\$_" }) +
        @('SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall')
    function Machine { $m = @{}; foreach ($view in 'Registry64', 'Registry32') { $s = RegistrySnapshot 'LocalMachine' $view $hklmRoots; foreach ($k in $s.Keys) { $m["$view\$k"] = $s[$k] } }; $m }
    $startupSaved = StartupState
    $seed = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($startupPath)
    try { $seed.SetValue('DelegationConsole', $wtConsole, [Microsoft.Win32.RegistryValueKind]::String) } finally { $seed.Close() }
    $wtVersion = try {
        @(& $windowsPowerShell -NoProfile -NonInteractive -Command '(Get-AppxPackage -Name Microsoft.WindowsTerminal | Select-Object -First 1).Version' |
            Where-Object { "$_" -match '^\d+(\.\d+){1,3}$' }) -join ''
    } catch { "unreadable: $($_.Exception.Message)" }
    if (-not $wtVersion) { $wtVersion = 'absent' }
    Say "precondition before S0: $(StartupText $startupSaved) -> DelegationConsole String:$wtConsole; Windows Terminal package: $wtVersion"
    $s0 = RegistrySnapshot 'CurrentUser' 'Default' @('')
    Start-Sleep -Seconds 5  # bounded control interval: what changes on its own shows up between S0 and S1
    $s1 = RegistrySnapshot 'CurrentUser' 'Default' @('')
    $h1, $tree1, $user1 = (Machine), (FileSnapshot $install), (FileSnapshot $userDir)
    $register = Vendor (Join-Path $install 'noctty.com') '+register-default-terminal'
    $s2 = RegistrySnapshot 'CurrentUser' 'Default' @('')
    $h2, $tree2, $user2 = (Machine), (FileSnapshot $install), (FileSnapshot $userDir)
    Say "HKCU values and keys: S0 $($s0.Count), S1 $($s1.Count), S2 $($s2.Count); vendor +register-default-terminal exit $($register.exit): $($register.output)"

    $noise = @(SnapshotDiff $s0 $s1)
    $noiseEntries = @($noise | ForEach-Object { $_.entry })
    Say "control S0->S1 changed entries: $($noise.Count); under Classes/Console (not subtracted there): $(@($noise | Where-Object { Region $_.key }).Count)"
    $delta = @(SnapshotDiff $s1 $s2)
    $vendorRegion = @($delta | Where-Object { Region $_.key })
    foreach ($d in $vendorRegion) { Say "CLASSES/CONSOLE $($d.change) HKCU\$($d.key) [$($d.name)] $($d.before) -> $($d.after)" }
    $other = @($delta | Where-Object { -not (Region $_.key) -and $noiseEntries -notcontains $_.entry })
    Say "other HKCU changes after exact (key, name) noise filter: $($other.Count)"
    foreach ($d in @($other | Select-Object -First 200)) { Say "OTHER $($d.change) HKCU\$($d.key) [$($d.name)]" }
    $tokens = @($install, 'noctty', $noctty, $proxy) + $iids
    $mentions = @(foreach ($d in @($delta | Where-Object { -not (Region $_.key) })) {
        $hit = @($tokens | Where-Object { "$($d.key)$sep$($d.name)$sep$($d.after)$sep$($d.before)" -like "*$_*" })
        if ($hit.Count) { Say "MENTION $($d.change) HKCU\$($d.key) [$($d.name)] token $($hit[0])"; $d }
    })
    $machine = @(SnapshotDiff $h1 $h2)
    foreach ($d in $machine) { Say "HKLM $($d.change) $($d.key) [$($d.name)] $($d.before) -> $($d.after)" }
    $treeDiff = @(SnapshotDiff $tree1 $tree2)
    $userDiff = @(SnapshotDiff $user1 $user2)
    foreach ($d in @($treeDiff + $userDiff)) { Say "FILE $($d.change) $($d.key) $($d.before) -> $($d.after)" }

    # G3 on CI: a console entry point must not write into the install directory.
    $version = Vendor (Join-Path $install 'noctty.com') '--version'
    $tree3 = FileSnapshot $install
    Say "noctty.com --version exit $($version.exit): $($version.output); install directory changes: $(@(SnapshotDiff $tree2 $tree3).Count)"

    # The gate: the Classes/Console delta, less the vendor's own bookkeeping (the Noctty CLSID's
    # noctty.default-terminal subtree, the CLSID descriptions, DelegationTerminal, which the legacy
    # record owns, and the shared CLSID and Interface roots), is exactly manifest.noctty.registration
    # bound to this install plus the keys derived from it; nothing else changed.
    $wanted = @{}
    foreach ($value in @($manifest.noctty.registration)) {
        $parts = $value.key.Split('\')
        for ($i = 4; $i -le $parts.Count; $i++) { $wanted[(($parts[0..($i - 1)] -join '\') + "$sep<key>").ToUpperInvariant()] = 'key' }
        $wanted["$($value.key)$sep$($value.name)".ToUpperInvariant()] = 'String:' + $value.data.Replace('{install}', $g4Dir)
    }
    $bookkeeping = "SOFTWARE\CLASSES\CLSID\$noctty\NOCTTY.DEFAULT-TERMINAL"
    $measured = @{}
    foreach ($d in $vendorRegion) {
        $key = $d.key.ToUpperInvariant()
        if ($key -ceq $bookkeeping -or $key.StartsWith("$bookkeeping\") -or
            ($key -cin @('SOFTWARE\CLASSES\CLSID', 'SOFTWARE\CLASSES\INTERFACE') -and $d.name -ceq '<key>') -or
            ($key -cin @("SOFTWARE\CLASSES\CLSID\$noctty", "SOFTWARE\CLASSES\CLSID\$proxy") -and $d.name -ceq '') -or
            ($key -ceq 'CONSOLE\%%STARTUP' -and $d.name -ceq 'DelegationTerminal' -and $d.change -ceq 'added' -and
             $d.after -ceq "String:$noctty")) { continue }
        $measured[$d.entry.ToUpperInvariant()] = $(if ($d.change -ceq 'added') { $d.after } else { "$($d.change) $($d.before) -> $($d.after)" })
    }
    $gate = @(foreach ($entry in @(@($wanted.Keys) + @($measured.Keys) | Sort-Object -Unique)) {
        if ($measured[$entry] -cne $wanted[$entry]) { "HKCU\$($entry.Replace([string]$sep, ' ['))]: declared $($wanted[$entry]), measured $($measured[$entry])" }
    })
    if ($register.exit -ne 0) { $gate += "register exit $($register.exit)" }
    foreach ($count in @(@('other HKCU', $other.Count), @('Noctty mentions outside Classes/Console', $mentions.Count), @('HKLM', $machine.Count),
            @('install directory', $treeDiff.Count + @(SnapshotDiff $tree2 $tree3).Count), @('%LOCALAPPDATA%\noctty', $userDiff.Count))) {
        if ($count[1]) { $gate += "$($count[0]) changes: $($count[1])" }
    }
    foreach ($line in $gate) { Say "GATE $line" }
    Say "gate: $(@($wanted.Keys).Count) declared entries, $(@($measured.Keys).Count) measured after exclusions, $($gate.Count) problems"

    $unregister = Vendor (Join-Path $install 'noctty.com') '+unregister-default-terminal'
    $s3 = RegistrySnapshot 'CurrentUser' 'Default' @('')
    $remains = @(SnapshotDiff $s1 $s3 | Where-Object { Region $_.key })
    Say "vendor +unregister-default-terminal exit $($unregister.exit): $($unregister.output)"
    foreach ($d in $remains) { Say "REMAINS $($d.change) HKCU\$($d.key) [$($d.name)] $($d.before) -> $($d.after)" }
    $g4 = [ordered]@{ status = 'measured'; registerExit = $register.exit; versionExit = $version.exit; unregisterExit = $unregister.exit
        classesConsoleChanges = $vendorRegion.Count; otherHkcuChanges = $other.Count; mentions = $mentions.Count
        hklmChanges = $machine.Count; installFileChanges = $treeDiff.Count + @(SnapshotDiff $tree2 $tree3).Count
        userNocttyFileChanges = $userDiff.Count; remainingAfterUnregister = $remains.Count; controlNoise = $noise.Count
        windowsTerminal = $wtVersion; seededDelegationConsole = $true; startupKeyCreated = -not $startupSaved.keyExisted
        gate = $(if ($gate.Count) { $gate -join '; ' } else { 'pass' }) }
} catch {
    $g4 = [ordered]@{ status = "measurement error: $($_.Exception.Message)" }
    Say $g4.status
} finally {
    # Put back only the two values and, if the measurement created the key and it is empty
    # again, the key itself (never recursively); then read it back and report exactly.
    $restore = 'not seeded'
    if ($null -ne $startupSaved) {
        try {
            $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($startupPath, $true)
            $empty = $false
            if ($null -ne $key) {
                try {
                    foreach ($name in 'DelegationConsole', 'DelegationTerminal') {
                        $prior = $startupSaved.values[$name]
                        if ($prior) { $key.SetValue($name, $prior.data, $prior.kind) } else { $key.DeleteValue($name, $false) }
                    }
                    $empty = $key.ValueCount -eq 0 -and $key.SubKeyCount -eq 0
                } finally { $key.Close() }
            }
            if (-not $startupSaved.keyExisted -and $empty) { [Microsoft.Win32.Registry]::CurrentUser.DeleteSubKey($startupPath, $false) }
            $now = StartupText (StartupState)
            $restore = if ($now -ceq (StartupText $startupSaved)) { 'verified' } else { "differs from before G4: now $now" }
        } catch { $restore = "failed: $($_.Exception.Message)" }
    }
    $g4['startupRestore'] = $restore
    Say "HKCU\$startupPath restore: $restore"
}

# Helpers of the Chromium first-run observation (A29): a count with at most five names, the last lines of a
# native command's output, and a native command run through the Process API with a deadline.
function Few($Names) { $all = @($Names); "$($all.Count)$(if ($all.Count) { ' (' + ((@($all | Select-Object -First 5)) -join ', ') + $(if ($all.Count -gt 5) { ', ...' }) + ')' })" }
function Tail([string]$Text) { ((@($Text -split "`r?`n" | Where-Object { $_.Trim() }) | Select-Object -Last 3) -join ' | ') -replace '(.{300}).+', '$1...' }
# A native command with a deadline: exit code, seconds, sampled peak working set, and its output.
function Bounded([string]$Exe, [string[]]$Arguments, [int]$Seconds) {
    $info = [Diagnostics.ProcessStartInfo]::new($Exe)
    foreach ($argument in $Arguments) { $info.ArgumentList.Add($argument) }
    $info.UseShellExecute, $info.RedirectStandardOutput, $info.RedirectStandardError, $info.CreateNoWindow = $false, $true, $true, $true
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $process = [Diagnostics.Process]::Start($info)
    $out, $err = $process.StandardOutput.ReadToEndAsync(), $process.StandardError.ReadToEndAsync()
    $peak, $exit = 0L, $null
    while (-not $process.WaitForExit(250)) {
        try { $process.Refresh(); $peak = [Math]::Max($peak, $process.PeakWorkingSet64) } catch { }
        if ($clock.Elapsed.TotalSeconds -gt $Seconds) { $process.Kill($true); $process.WaitForExit(); $exit = "timeout after $Seconds s"; break }
    }
    if (-not $exit) { $process.WaitForExit(); $exit = $process.ExitCode }
    [pscustomobject]@{ exit = $exit; seconds = [Math]::Round($clock.Elapsed.TotalSeconds, 1)
        peakMB = $(if ($peak) { [Math]::Round($peak / 1MB) } else { 'n/a' }); stdout = $out.Result; stderr = $err.Result }
}

foreach ($font in $fonts) {
    if ((Test-Path -LiteralPath (FontPath $font)) -or $null -ne (FontValue (ValueName $font))) { throw 'Proof requires a fresh disposable font target.' }
}
if (Test-Path -LiteralPath $ledgerDir) { throw 'Proof requires no effect ledger yet.' }
# M-L1: from beneath a packaged app (here a copy of cmd.exe under a WindowsApps path starts win.ps1), every mode that
# writes refuses before its first write: no ledger directory appears. Read-only modes are unaffected.
$packagedLauncher = Join-Path $env:RUNNER_TEMP ('WindowsApps\guard-' + [guid]::NewGuid().ToString('N') + '\cmd.exe')
$null = New-Item -ItemType Directory -Path (Split-Path -Parent $packagedLauncher)
[IO.File]::Copy((Join-Path $env:SystemRoot 'System32\cmd.exe'), $packagedLauncher, $false)
function Packaged([string[]]$Arguments) {
    $ErrorActionPreference = 'Continue'
    $PSNativeCommandUseErrorActionPreference = $false
    # cmd.exe passes this PowerShell 7's PSModulePath on to the 5.1 child, which then cannot load its own modules
    # (Get-FileHash not recognized, CI 99); a direct 5.1 launch is spared that. Without the variable 5.1 builds its
    # default. Only this variable, only around this launch.
    $modulePath, $out, $code = $env:PSModulePath, @(), 'not started'
    try {
        [Environment]::SetEnvironmentVariable('PSModulePath', $null, 'Process')
        $out = @(& $packagedLauncher /d /c $windowsPowerShell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'win.ps1') @Arguments 2>&1 | ForEach-Object { [string]$_ })
        $code = $LASTEXITCODE
    } finally { [Environment]::SetEnvironmentVariable('PSModulePath', $modulePath, 'Process') }
    # As Win51 reads it: 5.1 wraps an error at the console width, also inside a path, so the lines are rejoined without
    # a separator up to the "At <script>:<line> char:<n>" line.
    $message, $at = '', $false
    foreach ($line in $out) { if ($line -match '^At .+ char:\d+\s*$') { $at = $true }; if (-not $at) { $message += $line } }
    [pscustomobject]@{ code = $code; text = $message; ledger = (Test-Path -LiteralPath $ledgerDir) }
}
# On a failure the exit code, the ledger's presence and the start of the synthetic run's message (no profile data) are logged.
function PackagedText($Run) { $text = [string]$Run.text -replace '\s+', ' '; "exit $($Run.code), ledger $($Run.ledger): $($text.Substring(0, [Math]::Min(600, $text.Length)))" }
foreach ($arguments in @(@('-Mode', 'Apply'), @('-Mode', 'Apply', '-AppFonts'), @('-Mode', 'Uninstall', '-Apply'))) {
    $run = Packaged $arguments
    $refused = $run.code -ne 0 -and -not $run.ledger -and ($run.text -replace '\s', '') -like '*refused,nothingwritten:itrunsbeneaththepackagedapp*\WindowsApps\*'
    if (-not $refused) { Write-Host "M-L1 $($arguments -join ' '): $(PackagedText $run)" }
    Must $refused "M-L1: $($arguments -join ' ') beneath a packaged app is refused for that reason before any ledger write"
}
foreach ($arguments in @(@('-Mode', 'Validate'), @('-Mode', 'Uninstall'))) {
    $run = Packaged $arguments
    if ($run.code -ne 0 -or $run.ledger) { Write-Host "M-L1 $($arguments -join ' '): $(PackagedText $run)" }
    Must ($run.code -eq 0 -and -not $run.ledger) "M-L1: $($arguments -join ' ') (read-only) still runs beneath a packaged app"
}
$n = $fonts.Count
$shortcut = Join-Path ([Environment]::GetFolderPath('StartMenu')) 'Programs\noctty.lnk'
$shortcutBefore = Test-Path -LiteralPath $shortcut
# A6 (owned): an Apply interrupted after committing fonts[0]'s file and before its value left
# that owned file unregistered, and its bytes were then damaged. Only an unregistered file can
# be damaged here: Windows keeps a registered per-user font file open without write sharing.
$null = New-Item -ItemType Directory -Path $fontDir, $ledgerDir -Force
CraftFile (FontPath $fonts[0]) $fonts[0].sha256.ToLowerInvariant() @('intent', 'commit')
[IO.File]::WriteAllText((FontPath $fonts[0]), 'negative-control')
MustReject { Run 'Test' } 'Installed bytes differ:*'

# A1: the first Apply reverts and owns fonts[0]'s damaged file again, then owns every other file
# and every value from no record at all (one intent and one commit each); a second Apply writes
# nothing. The same Apply creates the Noctty tree and configuration (the two other copies, A15).
$first = Run 'Apply'
if ($first.copied -ne $n + 2 -or $first.removed -ne 1 -or @(Ledger | Where-Object { IsFontRecord $_ }).Count -ne 4 * $n + 3 -or
    @($fonts | Where-Object { (Phases (ValueId (ValueName $_))) -cne 'intent,commit' }).Count -or
    (Get-FileHash -LiteralPath (FontPath $fonts[0])).Hash -ne $fonts[0].sha256 -or
    (Phases (FileId (FontPath $fonts[0]))) -cne 'intent,commit,undone,intent,commit') {
    throw 'The first Apply did not repair the owned damaged file and own each other font file and value exactly once.'
}
$second = Run 'Apply'
if ($second.copied -ne 0 -or $second.changedProperties -ne 0 -or $second.removed -ne 0 -or $second.recordsWritten -ne 0) { throw 'Second apply changed state.' }
MustNotClaimHandoff $first
MustNotClaimHandoff (Run 'Test')

# A2: independent readback from the selection (manifest.fonts), not from win.ps1.
foreach ($font in $fonts) {
    if ((Get-FileHash -LiteralPath (FontPath $font)).Hash -ne $font.sha256 -or (FontValue (ValueName $font)) -cne (FontPath $font)) {
        throw "Independent readback failed for $($font.fullName)."
    }
    $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($fontSubkey)
    try { if ([string]$key.GetValueKind((ValueName $font)) -cne 'String') { throw 'A font value is not REG_SZ.' } } finally { $key.Close() }
}

# ---- A15-A21: owned Noctty and the default-terminal selection, native (the vendor is not called) ----
# Checked independently from the manifest. Everything the proof itself writes (an unowned tree,
# configuration or COM values) it removes again one entry at a time, never recursively.
$realLocal = [Environment]::GetFolderPath('LocalApplicationData')
$realTree, $realConfig = (Join-Path $realLocal ('Programs\noctty-' + $manifest.noctty.version)), (Join-Path $realLocal 'noctty\config.ghostty')
$bound = Get-NocttyRegistration $manifest.noctty.registration $realTree $manifest.noctty.files
$treeId, $configId = ('tree-extracted:' + $realTree.ToUpperInvariant()), ('file-created:' + $realConfig.ToUpperInvariant())
$keyIds = @($bound.keys | ForEach-Object { 'registry-key-created:' + "HKCU\$_".ToUpperInvariant() })
$valueIds = @($bound.values | ForEach-Object { 'registry-value:' + "HKCU\$($_.key)|$($_.name)".ToUpperInvariant() })
function KeyExists([string]$Subkey) { $k = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($Subkey); if ($null -eq $k) { return $false }; $k.Close(); $true }
function ComValue($Row) {
    $k = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($Row.key)
    if ($null -eq $k) { return $null }
    try { if ($k.GetValueNames() -contains $Row.name) { "$($k.GetValueKind($Row.name)):$($k.GetValue($Row.name, $null, 'DoNotExpandEnvironmentNames'))" } } finally { $k.Close() }
}
function Selection { $k = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Console\%%Startup'); try { "$($k.GetValue('DelegationConsole'))|$($k.GetValue('DelegationTerminal'))" } finally { $k.Close() } }
function TreeExact {
    $files = @($manifest.noctty.files.PSObject.Properties)
    @(Get-ChildItem -LiteralPath $realTree -Recurse -Force -File).Count -eq $files.Count -and
        -not @($files | Where-Object { (Get-FileHash -LiteralPath (Join-Path $realTree $_.Name.Replace('/', '\'))).Hash -ne $_.Value }).Count
}
function LastSeq { [long](@(Ledger | ForEach-Object { [long]$_.seq }) + 0 | Measure-Object -Maximum).Maximum }
function NewRecords([long]$Since, $Ids) { @(Ledger | Where-Object { [long]$_.seq -gt $Since -and $Ids -ccontains $_.id }).Count }
# Unowned COM values the proof writes itself, creating missing keys parents first; it returns the keys it made.
function PutComValues($Rows) {
    foreach ($k in $bound.keys) {
        if (-not (KeyExists $k) -and @($Rows | Where-Object { $_.key -eq $k -or $_.key.StartsWith("$k\") }).Count) { [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($k).Close(); $k }
    }
    foreach ($row in $Rows) { $k = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($row.key, $true); try { $k.SetValue($row.name, $row.data, 'String') } finally { $k.Close() } }
}
function DropComValues($Rows, $Made) {
    foreach ($row in $Rows) { $k = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($row.key, $true); if ($k) { try { $k.DeleteValue($row.name, $false) } finally { $k.Close() } } }
    foreach ($k in @($Made | Sort-Object { $_.Length } -Descending)) { [Microsoft.Win32.Registry]::CurrentUser.DeleteSubKey($k, $false) }
}
function RemoveProofTree([string]$Path) {
    foreach ($file in @(Get-ChildItem -LiteralPath $Path -Recurse -Force -File)) { [IO.File]::Delete($file.FullName) }
    foreach ($dir in @(Get-ChildItem -LiteralPath $Path -Recurse -Force -Directory | Sort-Object { $_.FullName.Length } -Descending)) { [IO.Directory]::Delete($dir.FullName, $false) }
    [IO.Directory]::Delete($Path, $false)
}

# A15: the first Apply owned the tree, the configuration, each COM key it had to create (keys that
# existed, such as those the vendor left in G4, are never owned) and the six values, in that
# order, keys parents first; everything reads back exactly; the selection was written once, with
# its record; no shortcut was made; the second Apply wrote nothing (A4).
$owned = @($keyIds | Where-Object { (Phases $_) -ceq 'intent,commit' })
$order = @(@($treeId, $configId) + $owned + $valueIds | ForEach-Object { $id = $_; [long]@(Ledger | Where-Object { $_.id -ceq $id -and $_.phase -ceq 'intent' })[-1].seq })
Must ((Phases $treeId) -ceq 'intent,commit' -and (Phases $configId) -ceq 'intent,commit' -and $first.nocttyPlan.com -ceq 'converge' -and
    -not @($valueIds | Where-Object { (Phases $_) -cne 'intent,commit' }).Count -and
    -not @($keyIds | Where-Object { (Phases $_) -cnotin @('', 'intent,commit') }).Count -and
    -not @(1..($order.Count - 1) | Where-Object { $order[$_] -le $order[$_ - 1] }).Count) 'A15: owned Noctty effects, in order'
Must ((TreeExact) -and [IO.File]::ReadAllText($realConfig) -ceq ('font-family = ' + $manifest.noctty.fontFamily + "`n") -and
    -not @($bound.values | Where-Object { (ComValue $_) -cne "String:$($_.data)" }).Count -and -not @($bound.keys | Where-Object { -not (KeyExists $_) }).Count -and
    (Selection) -ceq "$wtConsole|$noctty" -and (Test-Path -LiteralPath (Join-Path $realLocal 'windows-iac\provenance\default-terminal.json')) -and
    (Test-Path -LiteralPath $shortcut) -eq $shortcutBefore -and $first.registrationState -ceq 'registered') 'A15: independent readback'

# A16: an owned tree that differs (a file removed) is never overwritten: Apply stops before any effect.
[IO.File]::Delete((Join-Path $realTree 'noctty\noctty.com'))
$count = @(Ledger).Count
MustReject { Run 'Apply' } '*differs from the pinned Noctty (owned-drift)*'
Must (@(Ledger).Count -eq $count) 'A16: a differing owned tree stops Apply before any effect'

# A17: Uninstall restores only the selection value still as written (Terminal already put back by
# hand: a half state), then resumes the partly removed tree; everything owned is gone.
$startupKey = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Console\%%Startup', $true)
try { $startupKey.DeleteValue('DelegationTerminal') } finally { $startupKey.Close() }
$gone = RunUninstall -Apply
Must ((@($gone.resumed) -join ',') -ceq $treeId -and $gone.defaultTerminal -ceq 'restore' -and (Selection) -ceq '|' -and $gone.ownedOpen -eq 0 -and
    $gone.changedAfterClose -eq 0 -and -not (Test-Path -LiteralPath $realTree) -and -not (Test-Path -LiteralPath $realConfig) -and
    -not @($bound.values | Where-Object { $null -ne (ComValue $_) }).Count -and -not @($owned | ForEach-Object { $_.Substring(26) } | Where-Object { KeyExists $_ }).Count) 'A17: selection half state and a resumed tree'
AssertEmpty

# A18: an extraction interrupted with part of the inventory staged is voided and its staging
# directory cleaned by the next Apply, which then extracts the tree exactly.
$files = @{}
foreach ($entry in $manifest.noctty.files.PSObject.Properties) { $files[$entry.Name] = ([string]$entry.Value).ToLowerInvariant() }
$staging = "$realTree.$([guid]::NewGuid().ToString('N')).staging"
Craft @{ phase = 'intent'; id = $treeId; kind = 'tree-extracted'; target = $realTree; prior = $absent; desired = @{ exists = $true; files = $files }; temp = $staging }
$null = New-Item -ItemType Directory -Path "$staging\noctty"
[IO.File]::WriteAllText("$staging\noctty\noctty.com", 'interrupted')
$null = Run 'Apply'
Must ((Phases $treeId) -clike '*,intent,void,intent,commit' -and -not (Test-Path -LiteralPath $staging) -and (TreeExact)) 'A18: crash recovery of the tree'

# A19: A3 - a created COM key holding a foreign value refuses Uninstall before any removal.
$ownedKeyId = @($keyIds | Where-Object { (Phases $_) -clike '*intent,commit' })[0]
$ownedKey = @(Ledger | Where-Object { $_.id -ceq $ownedKeyId })[0].target.Substring(5)
$foreign = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($ownedKey, $true)
try { $foreign.SetValue('ProofForeign', 'x') } finally { $foreign.Close() }
$count, $selected = @(Ledger).Count, (Selection)
MustReject { RunUninstall -Apply } '*holds foreign content*'
Must (@(Ledger).Count -eq $count -and (Selection) -ceq $selected -and -not @($bound.values | Where-Object { $null -eq (ComValue $_) }).Count -and (TreeExact)) 'A19: A3 refuses before any removal'
$foreign = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($ownedKey, $true)
try { $foreign.DeleteValue('ProofForeign') } finally { $foreign.Close() }
$null = RunUninstall -Apply
# K-rule: one of the six present (exact, then foreign) with the others absent stops Apply before any effect.
$threading = @($bound.values | Where-Object { $_.name -ceq 'ThreadingModel' })
$made = @(PutComValues $threading)
$count = @(Ledger).Count
MustReject { Run 'Apply' } '*partly foreign*'
$null = @(PutComValues @([ordered]@{ key = $threading[0].key; name = 'ThreadingModel'; data = 'Apartment' }))
MustReject { Run 'Apply' } '*partly foreign*'
Must (@(Ledger).Count -eq $count -and -not (Test-Path -LiteralPath $realTree)) 'A19: the K-rule stops a mixed or foreign registration'
DropComValues $threading $made
# A preexisting COM key holding someone else's value is never written into: Apply stops before any effect.
[Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($bound.keys[0]).Close()
$foreign = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($bound.keys[0], $true)
try { $foreign.SetValue('ProofForeign', 'x') } finally { $foreign.Close() }
MustReject { Run 'Apply' } '*holds foreign content*'
Must (@(Ledger).Count -eq $count -and -not (Test-Path -LiteralPath $realTree)) 'A19: a foreign preexisting COM key stops Apply'
$foreign = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($bound.keys[0], $true)
try { $foreign.DeleteValue('ProofForeign') } finally { $foreign.Close() }
[Microsoft.Win32.Registry]::CurrentUser.DeleteSubKey($bound.keys[0], $false)
# All six present and exact (unowned): nothing is written for them and the tree is owned; since
# they name the tree and the plan does not remove them, the COM->tree guard refuses Uninstall.
$made = @(PutComValues $bound.values)
$mark = LastSeq
$pre = Run 'Apply'
Must ($pre.nocttyPlan.com -ceq 'preexisting' -and (NewRecords $mark $valueIds) -eq 0 -and (NewRecords $mark @($treeId)) -eq 2) 'A19: an exact preexisting registration is left alone'
MustReject { RunUninstall -Apply } '*names*'
Must ((TreeExact) -and -not @($bound.values | Where-Object { $null -eq (ComValue $_) }).Count) 'A19: the COM->tree guard refuses before any removal'
DropComValues $bound.values $made
$null = RunUninstall -Apply

# A20: a user configuration that differs is never written or removed; Apply reports it as drift.
[IO.File]::WriteAllText($realConfig, "font-family = user`n")
MustReject { Run 'Apply' } 'Noctty drift:*'
$null = RunUninstall -Apply
Must ([IO.File]::ReadAllText($realConfig) -ceq "font-family = user`n") 'A20: a differing unowned configuration is kept'
[IO.File]::Delete($realConfig)

# A21: A2 - an unrecorded tree exactly the inventory is preexisting-match, left alone and kept by
# Uninstall; one that differs stops Apply before any effect.
Expand-Archive -LiteralPath (Join-Path $PSScriptRoot 'payload/noctty.zip') -DestinationPath $realTree
$mark = LastSeq
$pre = Run 'Apply'
Must ($pre.nocttyPlan.tree -ceq 'preexisting-match' -and (NewRecords $mark @($treeId)) -eq 0) 'A21: an exact unowned tree is not owned'
$null = RunUninstall -Apply
[IO.File]::AppendAllText((Join-Path $realTree 'noctty\noctty.com'), 'x')
$count = @(Ledger).Count
MustReject { Run 'Apply' } '*differs from the pinned Noctty (preexisting-drift)*'
Must ((Test-Path -LiteralPath $realTree) -and @(Ledger).Count -eq $count) 'A21: a differing unowned tree is never overwritten'
RemoveProofTree $realTree
# A22: the font proof below runs with Noctty owned again, converged by the same Apply.
$null = Run 'Apply'

# Owned value drift is repaired by reverting and owning again (registry only; damaged bytes are A6 above).
SetFontValue (ValueName $fonts[0]) 'negative-control'
MustReject { Run 'Test' } 'Registry drift:*'
# The value was owned (last record commit) before this Apply, whose only records are this id's
# undone, intent and commit; the full history also holds the A15-A21 Uninstall/Apply cycles.
$mark, $valueId = (LastSeq), (ValueId (ValueName $fonts[0]))
$fixed = Run 'Apply'
if ($fixed.changedProperties -ne 1 -or $fixed.removed -ne 1 -or (FontValue (ValueName $fonts[0])) -cne (FontPath $fonts[0])) { throw 'Owned value drift was not repaired.' }
$history = @(Ledger | Where-Object { $_.id -ceq $valueId })
$earlier = @($history | Where-Object { [long]$_.seq -le $mark })
$repair = @($history | Where-Object { [long]$_.seq -gt $mark } | ForEach-Object { $_.phase }) -join ','
$added = @(Ledger | Where-Object { [long]$_.seq -gt $mark }).Count
if (-not $earlier.Count -or $earlier[-1].phase -cne 'commit' -or $repair -cne 'undone,intent,commit' -or $added -ne 3) {
    throw "The value repair is not recorded as undone then owned again: before '$(@($earlier | ForEach-Object { $_.phase }) -join ',')', repair '$repair', $added new records."
}
$null = Run 'Test'

# Valid JSON with altered bytes still fails the inventory before effects.
$bundleFont = Join-Path $PSScriptRoot "share/fonts/truetype/$($fonts[0].file)"
$original = [IO.File]::ReadAllBytes($bundleFont)
try {
    [IO.File]::AppendAllText($bundleFont, "`n")
    MustReject { Run 'Validate' } 'Bundle content mismatch:*'
}
finally { [IO.File]::WriteAllBytes($bundleFont, $original) }
$null = Run 'Test'

# A7/A12/A13: recovery of interrupted attempts, using only what an intent named.
# A value intent that never took effect is voided.
CraftValue 'Proof Void (TrueType)' 'C:\proof\void.ttf' @('intent')
# A file intent whose file appeared is committed, then collected (unselected).
$confirmBytes = Bytes 'proof: interrupted file that took effect'
$confirmPath = Join-Path $fontDir ((ShaOf $confirmBytes) + '.ttf')
CraftFile $confirmPath (ShaOf $confirmBytes) @('intent')
[IO.File]::WriteAllBytes($confirmPath, $confirmBytes)
# A file intent that crashed after writing its named temporary file: the temp is deleted and the intent voided.
$tempBytes = Bytes 'proof: interrupted before rename'
$tempTarget = Join-Path $fontDir ((ShaOf $tempBytes) + '.ttf')
$namedTemp = $tempTarget + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
Craft @{ phase = 'intent'; id = (FileId $tempTarget); kind = 'file-created'; target = $tempTarget; prior = $absent
    desired = @{ exists = $true; sha256 = (ShaOf $tempBytes) }; temp = $namedTemp }
[IO.File]::WriteAllBytes($namedTemp, $tempBytes[0..3])
# A value intent that took effect is committed, then collected (unselected).
CraftValue 'Proof Confirm (TrueType)' 'C:\proof\confirm.ttf' @('intent')
SetFontValue 'Proof Confirm (TrueType)' 'C:\proof\confirm.ttf'
# An owned value removed before its undone record (a crash inside Uninstall) is closed undone, then owned again.
SetFontValue (ValueName $fonts[1]) $null
# A temporary file no intent names is never touched (A13).
$foreignTemp = (FontPath $fonts[0]) + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
[IO.File]::WriteAllText($foreignTemp, 'proof: not named by any intent')
$mark = LastSeq  # after the crafted records: fonts[1]'s value must gain exactly undone, intent, commit from this Apply
$recovered = Run 'Apply'
$fontValueNew = @(Ledger | Where-Object { $_.id -ceq (ValueId (ValueName $fonts[1])) -and [long]$_.seq -gt $mark } | ForEach-Object { $_.phase }) -join ','
if ((Phases (ValueId 'Proof Void (TrueType)')) -cne 'intent,void' -or
    (Phases (FileId $confirmPath)) -cne 'intent,commit,undone' -or (Test-Path -LiteralPath $confirmPath) -or
    (Phases (FileId $tempTarget)) -cne 'intent,void' -or (Test-Path -LiteralPath $namedTemp) -or
    (Phases (ValueId 'Proof Confirm (TrueType)')) -cne 'intent,commit,undone' -or $null -ne (FontValue 'Proof Confirm (TrueType)') -or
    $fontValueNew -cne 'undone,intent,commit' -or (FontValue (ValueName $fonts[1])) -cne (FontPath $fonts[1]) -or
    -not (Test-Path -LiteralPath $foreignTemp)) {
    throw ("Interrupted attempts were not recovered exactly as recorded: " +
        ((@((ValueId 'Proof Void (TrueType)'), (FileId $confirmPath), (FileId $tempTarget), (ValueId 'Proof Confirm (TrueType)')) |
            ForEach-Object { "$_ = $(Phases $_)" }) -join '; ') + "; $(ValueId (ValueName $fonts[1])) new since seq $mark = '$fontValueNew'")
}
$null = Run 'Test'
# A second writer and a torn highest record stop every writer before any effect.
$lock = [IO.FileStream]::new((Join-Path $ledgerDir '.lock'), [IO.FileMode]::CreateNew, [IO.FileAccess]::Write,
    [IO.FileShare]::None, 1, [IO.FileOptions]::DeleteOnClose)
try { MustReject { Run 'Apply' } 'Another run holds the effect ledger lock*'; MustReject { RunUninstall -Apply } 'Another run holds the effect ledger lock*' }
finally { $lock.Dispose() }
$torn = Join-Path $ledgerDir ('{0:D8}.json' -f (1 + @(Ledger).Count))
[IO.File]::WriteAllText($torn, '{"ledger":"effe')
MustReject { Run 'Apply' } 'Torn or unreadable ledger record*'
[IO.File]::Delete($torn)  # the documented manual step: only the highest record, only when it does not parse
# The proof's Ledger cache (P4) reuses a parse only for identical text: a rewrite of the same length and with the old
# timestamp is read again, and so is a same-length torn record (it no longer parses); the exact bytes then return.
# The edited field is schema (1 -> 2), which every record has, whether win.ps1 or Craft wrote it.
$p4Record = Join-Path $ledgerDir '00000001.json'
$p4Bytes, $p4Stamp = [IO.File]::ReadAllBytes($p4Record), [IO.File]::GetLastWriteTimeUtc($p4Record)
$p4Text, $p4Schema = [Text.Encoding]::UTF8.GetString($p4Bytes), @(Ledger)[0].schema
$rewrite = [regex]::new('"schema":1(?=[,}])').Replace($p4Text, '"schema":2', 1)
try {
    [IO.File]::WriteAllText($p4Record, $rewrite); [IO.File]::SetLastWriteTimeUtc($p4Record, $p4Stamp)
    $rewrittenSchema = @(Ledger)[0].schema
    [IO.File]::WriteAllText($p4Record, '{' + ('x' * ($p4Text.Length - 1))); [IO.File]::SetLastWriteTimeUtc($p4Record, $p4Stamp)
    $tornReread = $false
    try { $null = Ledger } catch { $tornReread = $true }
} finally { [IO.File]::WriteAllBytes($p4Record, $p4Bytes); [IO.File]::SetLastWriteTimeUtc($p4Record, $p4Stamp) }
Must ($p4Schema -eq 1 -and $rewrite -cne $p4Text -and $rewrite.Length -eq $p4Text.Length -and $rewrittenSchema -eq 2 -and $tornReread -and
    @(Ledger)[0].schema -eq 1 -and [IO.File]::ReadAllText($p4Record) -ceq $p4Text) 'P4: the proof ledger rereads a same-length rewrite or tear'

# A14: a foreign value naming an owned file keeps it: Uninstall refuses as a whole, GC keeps it open.
SetFontValue 'Proof Foreign (TrueType)' (FontPath $fonts[0])
$before = Snapshot
MustReject { RunUninstall -Apply } '*referenced by HKCU Fonts\Proof Foreign (TrueType)*'
if ((Snapshot) -cne $before) { throw 'A refused Uninstall changed state.' }
SetFontValue 'Proof Foreign (TrueType)' $null
$oldBytes = Bytes 'proof: owned file of an older selection'
$oldPath = Join-Path $fontDir ((ShaOf $oldBytes) + '.ttf')
[IO.File]::WriteAllBytes($oldPath, $oldBytes)
CraftFile $oldPath (ShaOf $oldBytes) @('intent', 'commit')
SetFontValue 'Proof Foreign (TrueType)' $oldPath
$kept = Run 'Apply'
if (@($kept.gcKeptReferenced) -notcontains $oldPath -or -not (Test-Path -LiteralPath $oldPath)) { throw 'GC removed a file a foreign value names.' }
SetFontValue 'Proof Foreign (TrueType)' $null
$collected = Run 'Apply'
if ((Test-Path -LiteralPath $oldPath) -or (Phases (FileId $oldPath)) -cne 'intent,commit,undone') { throw 'GC did not collect the unreferenced old file.' }

# A3: a dry run lists every owned file and value and changes nothing.
$before = Snapshot
$dry = RunUninstall
$fontPlanned = @($dry.planned | Where-Object { $_ -like "* $fontDir\*" -or $_ -like "* HKCU\$fontSubkey\*" })
if ($fontPlanned.Count -ne 2 * $n -or @($dry.refused).Count -or $dry.apply -or (Snapshot) -cne $before) { throw 'The Uninstall dry run is wrong or changed state.' }

# A8: a locked file fails Uninstall after the values; it stays owned and nothing is deferred.
$handle = [IO.File]::Open((FontPath $fonts[0]), [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
try { MustReject { RunUninstall -Apply } 'Could not remove*' } finally { $handle.Dispose() }
if (-not (Test-Path -LiteralPath (FontPath $fonts[0])) -or (Phases (FileId (FontPath $fonts[0]))) -notlike '*,commit') { throw 'The locked file was not kept owned.' }

# A4: Uninstall empties the owned range; everything closed reads back as its prior; a second Uninstall does nothing.
$uninstalled = RunUninstall -Apply
if ($uninstalled.ownedOpen -ne 0 -or $uninstalled.changedAfterClose -ne 0 -or -not $uninstalled.ledgerFound -or
    $uninstalled.identity.sid -notmatch '^S-1-' -or $uninstalled.siloCheck -cne 'notPerformed') { throw 'Uninstall did not empty the owned range.' }
AssertEmpty
$again = RunUninstall -Apply
if (@($again.planned).Count -or $again.removed -or $again.recordsWritten) { throw 'A second Uninstall changed state.' }

# A5: unowned values are never written or removed; a differing one fails Apply as drift.
SetFontValue (ValueName $fonts[0]) 'C:\proof\foreign.ttf'
SetFontValue (ValueName $fonts[1]) (FontPath $fonts[1])
MustReject { Run 'Apply' } 'Font drift:*'
if ((FontValue (ValueName $fonts[0])) -cne 'C:\proof\foreign.ttf') { throw 'A differing unowned value was written.' }
if ((Phases (ValueId (ValueName $fonts[1]))) -notlike '*,undone') { throw 'An identical unowned value was recorded as owned.' }
MustReject { RunUninstall -Apply } '*referenced by HKCU Fonts*'
if ((FontValue (ValueName $fonts[1])) -cne (FontPath $fonts[1])) { throw 'An identical unowned value changed.' }
SetFontValue (ValueName $fonts[0]) $null
SetFontValue (ValueName $fonts[1]) $null
$null = Run 'Apply'
$null = Run 'Test'
$null = RunUninstall -Apply
AssertEmpty

# A10: an owned value recorded for an older selection is reverted and owned again; the old file is collected.
$oldBytes = Bytes 'proof: font bytes of the previous release'
$oldPath = Join-Path $fontDir ((ShaOf $oldBytes) + '.ttf')
[IO.File]::WriteAllBytes($oldPath, $oldBytes)
CraftFile $oldPath (ShaOf $oldBytes) @('intent', 'commit')
CraftValue (ValueName $fonts[0]) $oldPath @('intent', 'commit')
SetFontValue (ValueName $fonts[0]) $oldPath
$updated = Run 'Apply'
if ((FontValue (ValueName $fonts[0])) -cne (FontPath $fonts[0]) -or (Test-Path -LiteralPath $oldPath) -or
    (Phases (ValueId (ValueName $fonts[0]))) -notlike '*,intent,commit,undone,intent,commit' -or
    (Phases (FileId $oldPath)) -cne 'intent,commit,undone') { throw 'The owned value was not moved to the new selection.' }
$null = Run 'Test'
$final = RunUninstall -Apply
if ($final.ownedOpen -ne 0 -or $final.changedAfterClose -ne 0) { throw 'Uninstall after an update did not return to the original prior.' }
AssertEmpty
if (-not (Test-Path -LiteralPath $foreignTemp)) { throw 'A temporary file no intent named was removed.' }
[IO.File]::Delete($foreignTemp)

# ---- A23-A29: locked packages through the effect ledger. AutoHotkey (3 MB ZIP) is downloaded once, and
# Chromium (7z) once, in A29 after every stand-in of A24-A28 is gone. The proof's own stand-ins
# (an Uninstall entry, a profile, crafted records) are removed again one entry at a time.
$ahk = @($manifest.packages | Where-Object { $_.name -ceq 'AutoHotkey' })[0]
$chromium = @($manifest.packages | Where-Object { $_.name -ceq 'Chromium' })[0]
$programsDir = Join-Path $realLocal 'Programs'
$ahkTree, $chromiumTree = (Join-Path $realLocal $ahk.directory.Replace('/', '\')), (Join-Path $realLocal $chromium.directory.Replace('/', '\'))
$ahkId, $chromiumId = ('tree-extracted:' + $ahkTree.ToUpperInvariant()), ('tree-extracted:' + $chromiumTree.ToUpperInvariant())
$ahkKey = 'Software\Microsoft\Windows\CurrentVersion\Uninstall\' + $ahk.existing.uninstallKey
$chromiumProfile = Join-Path $realLocal $chromium.protected[0].Replace('/', '\')
function ApplyPackages([string]$Names) { Win51 @('-Mode', 'Apply', '-Packages', $Names) }
function AhkExact {
    $files = @($ahk.files.PSObject.Properties)
    (Test-Path -LiteralPath $ahkTree) -and @(Get-ChildItem -LiteralPath $ahkTree -Recurse -Force -File).Count -eq $files.Count -and
        -not @($files | Where-Object { (Get-FileHash -LiteralPath (Join-Path $ahkTree $_.Name.Replace('/', '\'))).Hash -ne $_.Value }).Count
}
function ExternalEntry {  # an AutoHotkey Uninstall entry the proof owns, whose executable is missing
    $key = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($ahkKey)
    try { foreach ($pair in @(@('DisplayName', $ahk.existing.displayName), @('Publisher', $ahk.existing.publisher), @('DisplayVersion', $ahk.version),
            @('InstallLocation', (Join-Path $realLocal 'proof-external-autohotkey')))) { $key.SetValue($pair[0], $pair[1]) } } finally { $key.Close() }
}
if ((Test-Path -LiteralPath $ahkTree) -or (Test-Path -LiteralPath $chromiumTree) -or (KeyExists $ahkKey) -or (Test-Path -LiteralPath (Split-Path -Parent $chromiumProfile))) {
    throw 'Proof requires no AutoHotkey or Chromium on this runner yet.'
}
# A29/A30 own App Paths\<appPath>: any existing entry, in HKCU or either HKLM view, would make them fail as drift.
$runnerAppPaths = @(foreach ($view in @(@('HKCU', 'CurrentUser', 'Default'), @('HKLM', 'LocalMachine', 'Registry64'), @('HKLM32', 'LocalMachine', 'Registry32'))) {
    $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey($view[1], $view[2])
    try {
        $key = $base.OpenSubKey("Software\Microsoft\Windows\CurrentVersion\App Paths\$($chromium.appPath)")
        if ($null -ne $key) { $key.Close(); "$($view[0])\Software\Microsoft\Windows\CurrentVersion\App Paths\$($chromium.appPath)" }
    } finally { $base.Close() }
})
if ($runnerAppPaths.Count) { throw "Proof requires no App Paths entry for $($chromium.appPath) on this runner yet: $($runnerAppPaths -join ', ')" }
# A24: -Packages is Apply-only and names locks exactly, once each; a profile without this package's history
# is someone else's (R1).
MustReject { Win51 @('-Mode', 'Test', '-Packages', 'AutoHotkey') } '-Packages is only for -Mode Apply*'
foreach ($bad in 'autohotkey', 'AutoHotkey,AutoHotkey', 'Nope') { MustReject { ApplyPackages $bad } 'Unknown or repeated package*' }
$null = New-Item -ItemType Directory -Path $chromiumProfile -Force
[IO.File]::WriteAllText("$chromiumProfile\proof.txt", 'someone else''s profile')
$mark = LastSeq
MustReject { ApplyPackages 'Chromium' } '*Chromium preexisting-drift*protected data*'
Must ((NewRecords $mark @($chromiumId)) -eq 0 -and -not (Test-Path -LiteralPath $chromiumTree)) 'A24: a profile without history blocks Chromium (R1)'
# An external AutoHotkey entry is never taken over: nothing is installed.
ExternalEntry
$mark = LastSeq
MustReject { ApplyPackages 'AutoHotkey' } '*AutoHotkey preexisting-drift*'
Must ((NewRecords $mark @($ahkId)) -eq 0 -and -not (Test-Path -LiteralPath $ahkTree)) 'A24: an external AutoHotkey install is never taken over'
[Microsoft.Win32.Registry]::CurrentUser.DeleteSubKey($ahkKey, $false)
# A23: a clean AutoHotkey install: one intent naming the package, one commit, the tree exactly the pinned
# inventory, no asset or staging left; a second Apply writes nothing for it.
$mark = LastSeq
$installed = ApplyPackages 'AutoHotkey'
$ahkRecords = @(Ledger | Where-Object { $_.id -ceq $ahkId -and [long]$_.seq -gt $mark })
Must (@($installed.packages | Where-Object { $_.name -ceq 'AutoHotkey' })[0].class -ceq 'owned-match' -and (@($ahkRecords | ForEach-Object { $_.phase }) -join ',') -ceq 'intent,commit' -and
    $ahkRecords[0].package -ceq 'AutoHotkey' -and (AhkExact) -and
    -not @(Get-ChildItem -LiteralPath $programsDir -Force | Where-Object { $_.Name -like "$(Split-Path -Leaf $ahkTree).*" }).Count) 'A23: AutoHotkey is installed and owned exactly'
$mark = LastSeq
$null = ApplyPackages 'AutoHotkey'
Must ((NewRecords $mark @($ahkId)) -eq 0) 'A23: a second Apply writes nothing for AutoHotkey'
# An external entry appearing beside the owned tree is a conflict: reported, nothing written or removed.
ExternalEntry
$mark = LastSeq
MustReject { ApplyPackages 'AutoHotkey' } '*AutoHotkey owned-match*external install*'
Must ((NewRecords $mark @($ahkId)) -eq 0 -and (AhkExact)) 'A24: an external entry beside the owned tree is a conflict'
[Microsoft.Win32.Registry]::CurrentUser.DeleteSubKey($ahkKey, $false)
# A26: an owned older version is collected once the selected version is owned and exact.
$oldTree = Join-Path $programsDir 'autohotkey-2.0.1'
$null = New-Item -ItemType Directory -Path $oldTree
[IO.File]::WriteAllText("$oldTree\old.txt", 'an older version')
$oldId, $oldDesired = ('tree-extracted:' + $oldTree.ToUpperInvariant()), @{ exists = $true; files = @{ 'old.txt' = (Get-FileHash -LiteralPath "$oldTree\old.txt").Hash.ToLowerInvariant() } }
Craft @{ phase = 'intent'; id = $oldId; kind = 'tree-extracted'; target = $oldTree; prior = $absent; desired = $oldDesired; package = 'AutoHotkey' }
Craft @{ phase = 'commit'; id = $oldId; kind = 'tree-extracted'; target = $oldTree; prior = $absent; desired = $oldDesired; observed = $oldDesired }
$null = ApplyPackages 'AutoHotkey'
Must ((Phases $oldId) -ceq 'intent,commit,undone' -and -not (Test-Path -LiteralPath $oldTree) -and (AhkExact)) 'A26: an owned older version is collected'
# A31: the desktop UI font faces (ui-font-face): only lfFaceName of the six persisted WindowMetrics fonts, through the
# registry, in effect at the next sign-in (which CI cannot do). The runner's WindowMetrics are the baseline.
$uiFace = $manifest.typography.face
$uiSlots = @('caption', 'smCaption', 'menu', 'status', 'message', 'icon')
$uiValues = @{ caption = 'CaptionFont'; smCaption = 'SmCaptionFont'; menu = 'MenuFont'; status = 'StatusFont'; message = 'MessageFont'; icon = 'IconFont' }
$ahkExe, $uiScript = (Join-Path $ahkTree $ahk.executable.Replace('/', '\')), (Join-Path $PSScriptRoot 'ui-font.ahk')
function UiId([string]$Slot) { "ui-font-face:WINMETRICS:$($Slot.ToUpperInvariant())" }
function Metrics {  # every HKCU WindowMetrics value, name -> kind:data (binary as hex)
    $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Control Panel\Desktop\WindowMetrics')
    try {
        $all = [ordered]@{}
        foreach ($name in @($key.GetValueNames() | Sort-Object)) {
            $value = $key.GetValue($name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
            $all[$name] = "$($key.GetValueKind($name)):" + $(if ($value -is [byte[]]) { [Convert]::ToHexString($value) } else { [string]$value })
        }
        $all
    } finally { $key.Close() }
}
function MetricsText($Metrics) { @($Metrics.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ';' }
function SlotHex($Metrics, [string]$Slot) { ([string]$Metrics[$uiValues[$Slot]]).Substring('Binary:'.Length) }
function HexFace([string]$Hex) { Get-LogFontFace ([Convert]::FromHexString($Hex)) }
function HexRest([string]$Hex) { $Hex.Substring(0, 56) }  # the 28 bytes before lfFaceName, which ends the struct
function UiRun([string[]]$Arguments) { Bounded $ahkExe (@('/ErrorStdOut', $uiScript) + $Arguments) 60 }
function SetSlotValue([string]$Slot, $Value, [Microsoft.Win32.RegistryValueKind]$Kind = 'Binary') {  # proof fixtures only
    $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Control Panel\Desktop\WindowMetrics', $true)
    try { $key.SetValue($uiValues[$Slot], $Value, $Kind) } finally { $key.Close() }
}
function SetSlotFace([string]$Slot, [string]$Face) { SetSlotValue $Slot (Get-LogFontWithFace ([Convert]::FromHexString((SlotHex (Metrics) $Slot))) $Face) }
# Everything but the named slots' faces equals $Before (CaptionWidth and every other value included); those faces are $Face.
function UiOnlyFaces($Before, [string[]]$Slots, [string]$Face) {
    $now = Metrics
    foreach ($slot in $uiSlots) {
        $was, $is = (SlotHex $Before $slot), (SlotHex $now $slot)
        if ((HexRest $is) -cne (HexRest $was) -or (HexFace $is) -cne $(if ($Slots -ccontains $slot) { $Face } else { HexFace $was })) { return $false }
    }
    foreach ($name in @($Before.Keys) + @($now.Keys)) { if (@($uiValues.Values) -notcontains $name -and $Before[$name] -cne $now[$name]) { return $false } }
    return $true
}
function OthersSame($A, $B, [string]$Except) { -not @(@($A.Keys) + @($B.Keys) | Where-Object { $_ -cne $Except -and $A[$_] -cne $B[$_] }).Count }
function UiNoRecords { (NewRecords $mark @($uiSlots | ForEach-Object { UiId $_ })) -eq 0 }
$uiBefore = Metrics
$uiGet = UiRun @('get')
$uiLive = if ($uiGet.exit -eq 0) { $uiGet.stdout | ConvertFrom-Json } else { $null }
function LiveKept {  # the live fonts (SPI GET) exactly as before: nothing here changes a running session
    $now = UiRun @('get')
    $now.exit -eq 0 -and -not @($uiSlots | Where-Object { (($now.stdout | ConvertFrom-Json).slots.$_.live) -cne $uiLive.slots.$_.live }).Count
}
Write-Host "A31 baseline: $(@($uiSlots | ForEach-Object { "$_='$(HexFace (SlotHex $uiBefore $_))'" }) -join ', '); get exit $($uiGet.exit) $(Tail $uiGet.stderr)"
Must ($null -ne $uiLive -and -not @($uiSlots | Where-Object { $uiLive.slots.$_.persisted -cne (SlotHex $uiBefore $_) }).Count) 'A31: ui-font.ahk get reads the live fonts and the persisted values'
$uiBase = @{}
foreach ($slot in $uiSlots) { $uiBase[$slot] = HexFace (SlotHex $uiBefore $slot) }
if (@($uiBase.Values) -ccontains $uiFace) { throw "Proof requires no UI font slot naming $uiFace on this runner yet." }
MustReject { Win51 @('-Mode', 'Validate', '-Typography') } '-Typography is only for -Mode Apply*'
MustReject { Win51 @('-Mode', 'Apply', '-Typography', '-Packages', 'AutoHotkey') } '-Typography is only for -Mode Apply*'
MustReject { Win51 @('-Mode', 'Apply', '-AppFonts', '-Typography') } '-AppFonts is only for -Mode Apply*'
# -AppFonts alone touches only a present app's fonts: here (no app) nothing at all.
$mark = LastSeq
$appOnly = Win51 @('-Mode', 'Apply', '-AppFonts')
Must ((LastSeq) -eq $mark -and $appOnly.appFonts -ceq 'appAbsent' -and $appOnly.nocttyPlan -ceq 'notEvaluated' -and $appOnly.uiFont -ceq 'notEvaluated' -and (MetricsText (Metrics)) -ceq (MetricsText $uiBefore)) 'A31: -AppFonts leaves OS fonts, Noctty and packages alone'
# A value that is not a 92-byte REG_BINARY LOGFONTW stops the run before any face is written.
$captionBytes = [Convert]::FromHexString((SlotHex $uiBefore 'caption'))
foreach ($wrong in @(@{ value = [byte[]]$captionBytes[0..90]; kind = 'Binary' }, @{ value = (SlotHex $uiBefore 'caption'); kind = 'String' })) {
    SetSlotValue 'caption' $wrong.value $wrong.kind
    $mark = LastSeq
    MustReject { Win51 @('-Mode', 'Apply', '-Typography') } '*CaptionFont is not a 92-byte REG_BINARY LOGFONTW*'
    $refusedMetrics = Metrics
    SetSlotValue 'caption' $captionBytes
    Must ((UiNoRecords) -and (OthersSame $refusedMetrics $uiBefore 'CaptionFont') -and $refusedMetrics['CaptionFont'] -clike "$($wrong.kind):*") "A31: a $($wrong.kind) value of the wrong shape is refused, nothing written"
}
Must ((MetricsText (Metrics)) -ceq (MetricsText $uiBefore)) 'A31: the shape fixtures are gone'
# A crash after three slots were written: six intents, three faces already in place. Recovery commits those three and
# voids the others, which are then written anew; only the six faces change, the live fonts not at all (pendingLogon).
$mark = LastSeq
foreach ($slot in $uiSlots) {
    Craft @{ phase = 'intent'; id = (UiId $slot); kind = 'ui-font-face'; target = "winmetrics:$slot"
        prior = @{ exists = $true; face = $uiBase[$slot] }; desired = @{ exists = $true; face = $uiFace } }
}
$written = @('caption', 'smCaption', 'menu')
foreach ($slot in $written) { SetSlotFace $slot $uiFace }
$typographyRun = Win51 @('-Mode', 'Apply', '-Typography')
Must ($typographyRun.nocttyPlan -ceq 'notEvaluated' -and
    -not @($uiSlots | Where-Object { (Phases (UiId $_)) -cne $(if ($written -ccontains $_) { 'intent,commit' } else { 'intent,void,intent,commit' }) }).Count -and
    (UiOnlyFaces $uiBefore $uiSlots $uiFace) -and (LiveKept)) 'A31: Apply -Typography recovers the interrupted run and writes the rest; only the six faces changed (CaptionWidth and all other values kept), the live fonts untouched'
Must ($typographyRun.uiFont.face -ceq $uiFace -and (@($typographyRun.uiFont.slots | ForEach-Object { "$($_.slot)=$($_.state)" }) -join ',') -ceq
    (@($uiSlots | ForEach-Object { "$_=pendingLogon" }) -join ',')) 'A31: every slot reports pendingLogon (persisted, not yet in use)'
$mark = LastSeq
$null = Win51 @('-Mode', 'Apply', '-Typography')
Must (UiNoRecords) 'A31: a second Apply -Typography writes nothing'
# A face changed after this wrote it to a third face (neither the prior nor the selected one) is owned-drift: Apply reports
# it and writes nothing, Uninstall refuses.
$thirdFace = 'Arial'
if ($thirdFace -ceq $uiBase.menu -or $thirdFace -ceq $uiFace) { throw "Proof requires the runner's menu face not to be $thirdFace." }
SetSlotFace 'menu' $thirdFace
$mark = LastSeq
MustReject { Win51 @('-Mode', 'Apply', '-Typography') } "*UI font drift*winmetrics:menu is '$thirdFace'*"
$driftText = MetricsText (Metrics)
MustReject { RunUninstall -Apply } '*Uninstall refused*owned target differs*'
Must ((UiNoRecords) -and (MetricsText (Metrics)) -ceq $driftText) 'A31: a third face is drift, not written; Uninstall refuses it'
# Exactly the prior face again is the generic recovery boundary: a committed attempt whose target equals its prior is
# closed undone (as after an undo that stopped before its record), so the slot is unowned again and an explicit
# Apply -Typography takes it once more: undone, intent, commit; only the menu face changes.
SetSlotFace 'menu' $uiBase.menu
$beforePrior = Metrics
$mark = LastSeq
$null = Win51 @('-Mode', 'Apply', '-Typography')
$menuPhases = (Phases (UiId 'menu')).Split(',')
Must ((NewRecords $mark @($uiSlots | ForEach-Object { UiId $_ })) -eq 3 -and ($menuPhases[-3..-1] -join ',') -ceq 'undone,intent,commit' -and
    (UiOnlyFaces $beforePrior @('menu') $uiFace)) 'A31: the exact prior face again counts as undone; the explicit Apply takes the slot again (3 records), changing only that face'
# A size the user changes later is not this effect's: the undo (A27) puts back the face and keeps the new height.
$tallCaption = [Convert]::FromHexString((SlotHex (Metrics) 'caption'))
[BitConverter]::GetBytes([int]-40).CopyTo($tallCaption, 0)
SetSlotValue 'caption' $tallCaption
# A25: interrupted package attempts: recovery removes the derived asset and a partial staging and voids the
# intent; a file the inventory does not name keeps the staging directory and the intent open until it is gone.
function CrashIntent([string]$Leaf, [string]$Foreign) {
    $target = Join-Path $programsDir $Leaf
    $staging = "$target.$([guid]::NewGuid().ToString('N')).staging"
    $id = 'tree-extracted:' + $target.ToUpperInvariant()
    Craft @{ phase = 'intent'; id = $id; kind = 'tree-extracted'; target = $target; prior = $absent; temp = $staging; package = 'AutoHotkey'
        desired = @{ exists = $true; files = @{ 'AutoHotkey64.exe' = ('a' * 64) } } }
    [IO.File]::WriteAllText("$staging.asset", 'a partial download')
    $null = New-Item -ItemType Directory -Path $staging
    [IO.File]::WriteAllText("$staging\AutoHotkey64.exe", 'partial')
    if ($Foreign) { [IO.File]::WriteAllText("$staging\$Foreign", 'not in the inventory') }
    [pscustomobject]@{ id = $id; staging = $staging }
}
$crash = CrashIntent 'autohotkey-9.9'
$null = Run 'Apply'
Must ((Phases $crash.id) -ceq 'intent,void' -and -not (Test-Path -LiteralPath "$($crash.staging).asset") -and -not (Test-Path -LiteralPath $crash.staging)) 'A25: an interrupted install is voided with its asset and staging'
$crash = CrashIntent 'autohotkey-9.8' 'foreign.txt'
MustReject { Run 'Apply' } '*is kept*'
Must ((Phases $crash.id) -ceq 'intent' -and (Test-Path -LiteralPath "$($crash.staging)\foreign.txt") -and -not (Test-Path -LiteralPath "$($crash.staging).asset")) 'A25: foreign staging content is kept'
[IO.File]::Delete("$($crash.staging)\foreign.txt")
$null = Run 'Apply'
Must ((Phases $crash.id) -ceq 'intent,void' -and -not (Test-Path -LiteralPath $crash.staging)) 'A25: recovery completes once the foreign file is gone'

# A28 (S2-3b; the profile is only read). Before an install: with this package's
# history (a closed attempt of an older version), a restored profile its seed would overwrite (O1:
# Default\Preferences without First Run) keeps Chromium from installing, reported as package drift after the
# other effects, which are converged already, so nothing at all is written. With First Run beside it Chromium
# installs: that is A29, after A27, where the stand-in below is gone.
$olderTree = Join-Path $programsDir 'chromium-153.0.1'
$olderId, $olderDesired = ('tree-extracted:' + $olderTree.ToUpperInvariant()), @{ exists = $true; files = @{ 'Chrome-bin/chrome.exe' = ('a' * 64) } }
Craft @{ phase = 'intent'; id = $olderId; kind = 'tree-extracted'; target = $olderTree; prior = $absent; desired = $olderDesired; package = 'Chromium' }
Craft @{ phase = 'commit'; id = $olderId; kind = 'tree-extracted'; target = $olderTree; prior = $absent; desired = $olderDesired; observed = $olderDesired }
Craft @{ phase = 'undone'; id = $olderId; kind = 'tree-extracted'; target = $olderTree; prior = $absent; desired = $olderDesired; observed = $absent }
$preferences, $sentinel = (Join-Path $chromiumProfile 'Default\Preferences'), (Join-Path $chromiumProfile 'First Run')
$restored = '{"proof":"a profile restored by hand"}'
$null = New-Item -ItemType Directory -Path (Split-Path -Parent $preferences)
[IO.File]::WriteAllText($preferences, $restored)
$mark = LastSeq
MustReject { ApplyPackages 'Chromium' } '*Package drift: Chromium preexisting-drift*without its First Run sentinel*nothing is installed*'
[IO.File]::WriteAllText($sentinel, '')
Must ((LastSeq) -eq $mark -and -not (Test-Path -LiteralPath $chromiumTree) -and [IO.File]::ReadAllText($preferences) -ceq $restored) 'A28: O1 before an install, nothing written'
# An owned Chromium tree recorded for another selection (a stand-in holding only a stand-in executable, as if
# written before the seed) is owned-drift (C1), which stops the run before any effect; the O1 reason comes first.
$standIn = Join-Path $chromiumTree $chromium.executable.Replace('/', '\')
$null = New-Item -ItemType Directory -Path (Split-Path -Parent $standIn)
[IO.File]::WriteAllText($standIn, 'a stand-in, not Chromium')
$standInDesired = @{ exists = $true; files = @{ $chromium.executable = (Get-FileHash -LiteralPath $standIn).Hash.ToLowerInvariant() } }
Craft @{ phase = 'intent'; id = $chromiumId; kind = 'tree-extracted'; target = $chromiumTree; prior = $absent; desired = $standInDesired; package = 'Chromium' }
Craft @{ phase = 'commit'; id = $chromiumId; kind = 'tree-extracted'; target = $chromiumTree; prior = $absent; desired = $standInDesired; observed = $standInDesired }
$mark = LastSeq
MustReject { ApplyPackages 'Chromium' } '*Packages stop the run before any effect: Chromium 154*installed for another inventory or seed*'
[IO.File]::Delete($sentinel)
MustReject { ApplyPackages 'Chromium' } '*Packages stop the run before any effect: Chromium 154*without its First Run sentinel*do not start this Chromium*'
Must ((LastSeq) -eq $mark -and (Phases $chromiumId) -ceq 'intent,commit' -and (Test-Path -LiteralPath $standIn) -and
    [IO.File]::ReadAllText($preferences) -ceq $restored) 'A28: C1 stops an owned Chromium before any effect; the profile is only read'
# A27: Uninstall leaves everything alone while a package executable is in use; closed, it removes every owned
# effect, the package tree too, and never the protected profile.
$count = @(Ledger).Count
$handle = [IO.File]::Open((Join-Path $ahkTree $ahk.executable.Replace('/', '\')), 'Open', 'Read', 'Read')
try { MustReject { RunUninstall -Apply } '*is in use*' } finally { $handle.Dispose() }
Must (@(Ledger).Count -eq $count -and (AhkExact)) 'A27: an in-use package stops Uninstall before any removal'
$gone = RunUninstall -Apply
Must ($gone.ownedOpen -eq 0 -and -not (Test-Path -LiteralPath $ahkTree) -and -not (Test-Path -LiteralPath $chromiumTree) -and
    (Test-Path -LiteralPath "$chromiumProfile\proof.txt") -and [IO.File]::ReadAllText($preferences) -ceq $restored) 'A27: Uninstall removes the package trees, never the profile'
AssertEmpty
# A31 after Uninstall: each face is back, every other byte and value as it was, the later caption height kept.
$uiAfter = Metrics
$expectCaption = [byte[]](Get-LogFontWithFace $tallCaption $uiBase.caption)
Must ((SlotHex $uiAfter 'caption') -ceq [Convert]::ToHexString($expectCaption) -and (OthersSame $uiAfter $uiBefore 'CaptionFont') -and
    -not @($uiSlots | Where-Object { (Phases (UiId $_)) -cnotlike '*,undone' }).Count) 'A31: Uninstall restores each face only, byte-exact elsewhere, keeping the later caption height'
SetSlotValue 'caption' $captionBytes
Must ((MetricsText (Metrics)) -ceq (MetricsText $uiBefore)) 'A31: the runner''s WindowMetrics are its own again'

# ---- A29 (b3b): the locked Chromium, installed for real (downloaded once), owned, first run, and removed ----
# Here A27 has removed the stand-in 154 tree and every owned effect; the proof's stand-in profile keeps its restored
# Default\Preferences, and First Run is written beside it, so R1 (the history of 153 and of the closed stand-in 154)
# and O1 (a sentinel is present) both let Chromium install over an existing profile, which is never written.
[IO.File]::WriteAllText($sentinel, '')
function ProfileKept { (Test-Path -LiteralPath "$chromiumProfile\proof.txt") -and (Test-Path -LiteralPath $sentinel) -and [IO.File]::ReadAllText($preferences) -ceq $restored }
function ChromiumExact {  # exactly the pinned inventory and the seed, by SHA-256
    $want = @{}
    foreach ($entry in $chromium.files.PSObject.Properties) { $want[$entry.Name] = $entry.Value }
    $want[$chromium.seed.path] = $chromium.seed.sha256
    (Test-Path -LiteralPath $chromiumTree) -and @(Get-ChildItem -LiteralPath $chromiumTree -Recurse -Force -File).Count -eq $want.Count -and
        -not @($want.Keys | Where-Object { $path = Join-Path $chromiumTree $_.Replace('/', '\')
            -not (Test-Path -LiteralPath $path -PathType Leaf) -or (Get-FileHash -LiteralPath $path).Hash -ne $want[$_] }).Count
}
$mark = LastSeq
$chromiumInstalled = ApplyPackages 'Chromium'
$chromiumRecords = @(Ledger | Where-Object { $_.id -ceq $chromiumId -and [long]$_.seq -gt $mark })
Must (@($chromiumInstalled.packages | Where-Object { $_.name -ceq 'Chromium' })[0].class -ceq 'owned-match' -and
    (@($chromiumRecords | ForEach-Object { $_.phase }) -join ',') -ceq 'intent,commit' -and $chromiumRecords[0].package -ceq 'Chromium' -and (ChromiumExact) -and
    -not @(Get-ChildItem -LiteralPath $programsDir -Force | Where-Object { $_.Name -like "$(Split-Path -Leaf $chromiumTree).*" }).Count -and
    (ProfileKept)) 'A29: Chromium is installed and owned exactly (inventory and seed), no asset or staging left, the profile unchanged'
# Its first run, observed on the owned tree (the former b3a, now failing on its stop conditions): Chromium starts only
# from that tree, only with fresh scratch --user-data-dir directories in RUNNER_TEMP, never with --no-first-run,
# --no-sandbox or any other flag that changes a first run; the baseline (tree, default %LOCALAPPDATA%\Chromium, HKCU)
# is taken after the install and just before the first launch. Observed: First Run and the six seed preferences after
# a first GUI run; the tree still exactly the inventory and the seed (names, sizes, write times); every chrome.exe in
# four classes (tree, descendant, outside, unknown; B3aPoll), its windows closed one by one and 45 s for ours to end,
# the H1/H2/H3 decision on positive evidence, and only ours ever killed; Local State's background_mode.enabled;
# nothing new under the default %LOCALAPPDATA%\Chromium (anything new is moved aside, never deleted); HKCU names in
# fixed places before and after (C9); the fonts a headless PDF of the same profile embeds; and which existing
# Preferences a first run over a profile without First Run overwrites. One 120-second budget: a step that cannot get
# its minimum is skipped and says so. Record only: an unreadable PDF, the names added elsewhere than App Paths and
# Uninstall, Software\Chromium; everything else listed at the end fails the proof.
$b3a = [ordered]@{ status = 'not run' }
$b3aBudget, $b3aClock = 120, [Diagnostics.Stopwatch]::StartNew()
function B3a([string]$Line) { Write-Host "b3a $Line" }
function B3aLeft([int]$Least, [string]$Step) {
    $left = [int]($b3aBudget - $b3aClock.Elapsed.TotalSeconds)
    if ($left -lt $Least) { throw "$Step skipped: $left s of the $b3aBudget s budget left, $Least s needed" }
    $left
}
function InTree([string]$Path) { $Path -and $Path.StartsWith($b3aTree + '\', [StringComparison]::OrdinalIgnoreCase) }
# Every chrome.exe that appears after b3a starts, keyed by (PID, creation time) so a reused PID is never confused, in
# four classes: tree (its path, read by CIM or retried through Get-Process, is in the tree); outside (its readable
# path is elsewhere); descendant (its path is unreadable, as a sandboxed child's may be, and its parent is our launched
# browser or a known descendant created no later and still seen running at or after the child's creation, so a PID the
# parent left behind and another process reused never counts; the child itself created after the launch); unknown
# (anything else: never counted as ours, never killed, never a pass). Returns the observations of the processes running
# now; each carries lastSeen, the UTC time just before the poll that last saw it running.
function B3aPoll {
    $live, $polled = [Collections.Generic.List[object]]::new(), [DateTime]::UtcNow
    foreach ($process in @(Get-CimInstance Win32_Process -Filter "Name = 'chrome.exe'")) {
        $created = $process.CreationDate.ToUniversalTime()
        $key = "$($process.ProcessId)|$($created.Ticks)"
        if ($b3aBaseline -contains $key) { continue }
        if (-not $script:b3aSeen.ContainsKey($key)) {
            $path = [string]$process.ExecutablePath
            if (-not $path) { try { $path = [string](Get-Process -Id $process.ProcessId -ErrorAction Stop).Path } catch { $path = '' } }
            $type = if ($null -eq $process.CommandLine) { '?' } elseif ($process.CommandLine -match '--type=(\S+)') { $Matches[1] } else { 'browser' }
            $script:b3aSeen[$key] = [pscustomobject]@{ id = [int]$process.ProcessId; created = $created; parent = [int]$process.ParentProcessId
                type = $type; path = $path; class = 'unknown'; lastSeen = $polled }
        }
        $script:b3aSeen[$key].lastSeen = $polled
        $live.Add($script:b3aSeen[$key])
    }
    do {  # a child listed before its parent is traced on the next pass
        $changed = $false
        foreach ($seen in @($script:b3aSeen.Values | Where-Object { $_.class -ceq 'unknown' })) {
            $class = if ($seen.path) { $(if (InTree $seen.path) { 'tree' } else { 'outside' }) }
                elseif ($seen.created -ge $b3aLaunched -and @($script:b3aSeen.Values | Where-Object {
                    $_.id -eq $seen.parent -and $_.class -cin @('tree', 'descendant') -and $_.created -le $seen.created -and
                    $_.lastSeen -ge $seen.created }).Count) { 'descendant' }
                else { 'unknown' }
            if ($class -cne $seen.class) { $seen.class = $class; $changed = $true }
        }
    } while ($changed)
    , $live
}
function Ours($Observations) { @($Observations | Where-Object { $_.class -cin @('tree', 'descendant') }) }
# Waits up to $Seconds for every tree and descendant process to end (noting when $Browser, the launched process, ended);
# then kills only those, once, and checks for 5 s that they are gone. Unknown ones are never killed, only reported.
function SettleChromium([int]$Seconds, $Browser) {
    $clock, $browserEnded = [Diagnostics.Stopwatch]::StartNew(), $null
    do {
        $live = B3aPoll
        if ($Browser -and $null -eq $browserEnded -and $Browser.HasExited) { $browserEnded = [Math]::Round($clock.Elapsed.TotalSeconds, 1) }
        if (-not @(Ours $live).Count) { break }
        Start-Sleep -Milliseconds 500
    } while ($clock.Elapsed.TotalSeconds -lt $Seconds)
    $settle = [pscustomobject]@{ endedAll = -not @(Ours $live).Count; seconds = [Math]::Round($clock.Elapsed.TotalSeconds, 1)
        watched = $null -ne $Browser; browserEnded = $browserEnded; killed = @(); survivors = @(); unknown = @() }
    if (-not $settle.endedAll) {
        $settle.killed = @(Ours $live | ForEach-Object { "$($_.type)[$($_.id)<$($_.parent)]" })
        foreach ($process in (Ours $live)) { try { Stop-Process -Id $process.id -Force -ErrorAction Stop } catch { } }
        $check = [Diagnostics.Stopwatch]::StartNew()
        do { Start-Sleep -Milliseconds 500; $live = B3aPoll } while (@(Ours $live).Count -and $check.Elapsed.TotalSeconds -lt 5)
        $settle.survivors = @(Ours $live | ForEach-Object { "$($_.type)[$($_.id)]" })
    }
    $settle.unknown = @($live | Where-Object { $_.class -ceq 'unknown' } | ForEach-Object { "$($_.type)[$($_.id)<$($_.parent)]" })
    $settle
}
function SettleText($Settle) {
    $(if ($Settle.endedAll) { "all ours ended in $($Settle.seconds) s" } else { "KILLED $($Settle.killed.Count) after $($Settle.seconds) s: $(Few $Settle.killed)" }) +
        $(if ($Settle.watched) { "; browser $(if ($null -ne $Settle.browserEnded) { "ended after $($Settle.browserEnded) s" } else { 'did not end by itself' })" }) +
        $(if ($Settle.survivors.Count) { "; SURVIVED the kill: $(Few $Settle.survivors)" }) + $(if ($Settle.unknown.Count) { "; UNKNOWN still running: $(Few $Settle.unknown)" })
}
# Closes the browser's windows as a user would, one at a time: while it has a main window, CloseMainWindow, then waits
# up to 2 s for that window to go; at most five windows. Returns their titles.
function CloseWindows($Browser) {
    $titles = @()
    for ($i = 0; $i -lt 5; $i++) {
        try {
            $Browser.Refresh()
            if ($Browser.HasExited -or $Browser.MainWindowHandle -eq [IntPtr]::Zero) { break }
            $handle = $Browser.MainWindowHandle
            $titles += [string]$Browser.MainWindowTitle
            $null = $Browser.CloseMainWindow()
            $wait = [Diagnostics.Stopwatch]::StartNew()
            do { Start-Sleep -Milliseconds 250; $Browser.Refresh() } while (-not $Browser.HasExited -and $Browser.MainWindowHandle -eq $handle -and $wait.Elapsed.TotalSeconds -lt 2)
        } catch { break }
    }
    , $titles
}
function StartChromium([string[]]$Arguments) {
    $info = [Diagnostics.ProcessStartInfo]::new($b3aExe)
    foreach ($argument in $Arguments) { $info.ArgumentList.Add($argument) }
    $info.UseShellExecute = $false
    [Diagnostics.Process]::Start($info)
}
# Polls $Done every half second for up to $Seconds; the seconds it took, or $null.
function WaitFor([scriptblock]$Done, [int]$Seconds) {
    $clock = [Diagnostics.Stopwatch]::StartNew()
    while ($clock.Elapsed.TotalSeconds -lt $Seconds) {
        $null = B3aPoll  # observe first, so a fast first run still records its processes
        if (& $Done) { return [Math]::Round($clock.Elapsed.TotalSeconds, 1) }
        Start-Sleep -Milliseconds 500
    }
    $null
}
# Relative path -> 'dir' or 'length|write ticks' for every entry beneath $Path (none when it is absent).
function EntryStamps([string]$Path) {
    $map = @{}
    if (Test-Path -LiteralPath $Path) {
        foreach ($item in @(Get-ChildItem -LiteralPath $Path -Recurse -Force)) {
            $map[$item.FullName.Substring($Path.Length)] = $(if ($item.PSIsContainer) { 'dir' } else { "$($item.Length)|$($item.LastWriteTimeUtc.Ticks)" })
        }
    }
    $map
}
# True when $Path's full path lies strictly beneath $Root and neither $Root, $Path nor any directory between them is a
# reparse point, so a move never renames a link or reaches through one.
function SafeBeneath([string]$Path, [string]$Root) {
    $full, $base = [IO.Path]::GetFullPath($Path), [IO.Path]::GetFullPath($Root).TrimEnd('\')
    if (-not $full.StartsWith($base + '\', [StringComparison]::OrdinalIgnoreCase)) { return $false }
    for ($at = $full; $at.Length -ge $base.Length; $at = [IO.Path]::GetDirectoryName($at)) {
        if ((Get-Item -LiteralPath $at -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { return $false }
    }
    $true
}
function StampDiff($Before, $After) {
    @(@($After.Keys | Where-Object { -not $Before.ContainsKey($_) } | Sort-Object | ForEach-Object { "+$_" }) +
        @($Before.Keys | Where-Object { -not $After.ContainsKey($_) } | Sort-Object | ForEach-Object { "-$_" }) +
        @($After.Keys | Where-Object { $Before.ContainsKey($_) -and $After[$_] -ne 'dir' -and $Before[$_] -ne $After[$_] } | Sort-Object | ForEach-Object { "~$_" }))
}
# C9: HKCU key and value names in fixed places only (App Paths, Uninstall, Software\Chromium in depth, the browser
# registrations, the names directly under Software\Classes and the web types' OpenWithProgids), read-only.
$b3aPlaces = @(@('Software\Microsoft\Windows\CurrentVersion\App Paths', $false), @('Software\Microsoft\Windows\CurrentVersion\Uninstall', $false),
    @('Software\Chromium', $true), @('Software\Clients\StartMenuInternet', $false), @('Software\RegisteredApplications', $false),
    @('Software\Classes', $false)) + @('.htm', '.html', '.pdf', '.svg', '.webp', '.xht', '.xhtml', 'http', 'https' | ForEach-Object { , @("Software\Classes\$_\OpenWithProgids", $false) })
function HkcuNames {
    $names = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $walk = {
        param([string]$Path, [bool]$Deep)
        $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($Path)
        if ($null -eq $key) { return }
        try {
            foreach ($value in $key.GetValueNames()) { $null = $names.Add("$Path|$value") }
            foreach ($sub in $key.GetSubKeyNames()) { $null = $names.Add("$Path\$sub"); if ($Deep) { & $walk "$Path\$sub" $true } }
        } finally { $key.Close() }
    }
    foreach ($place in $b3aPlaces) { & $walk $place[0] $place[1] }
    , $names
}
# The six seed preferences in a profile's Preferences against the bundled seed.
function SeedPreferences([string]$Preferences) {
    if (-not (Test-Path -LiteralPath $Preferences)) { return 'no Preferences' }
    try {
        $json = [IO.File]::ReadAllText($Preferences)
        $document = try { $json | ConvertFrom-Json -AsHashtable } catch { $json | ConvertFrom-Json }
        $found = Get-Field (Get-Field (Get-Field $document 'webkit') 'webprefs') 'fonts'
    } catch { return "unreadable: $($_.Exception.Message -replace '(.{200}).+', '$1...')" }
    $wrong = @(foreach ($generic in 'standard', 'sansserif', 'fixed') {
        foreach ($code in 'Zyyy', 'Jpan') {
            $want, $have = (Get-Field (Get-Field $b3aSeedFonts $generic) $code), (Get-Field (Get-Field $found $generic) $code)
            if ([string]$have -cne [string]$want) { "$generic.$code=$(if ($null -eq $have) { 'absent' } else { $have })" }
        }
    })
    if ($wrong.Count) { "DIFFER: $($wrong -join ', ')" } else { 'all six equal the seed' }
}
$b3aStops = [Collections.Generic.List[string]]::new()
try {
    $b3aPackage, $b3aTree = $chromium, $chromiumTree
    $b3aExe = Join-Path $b3aTree $b3aPackage.executable.Replace('/', '\')
    $b3aDir = Join-Path $env:RUNNER_TEMP ('b3a-' + [guid]::NewGuid().ToString('N'))  # fresh, never deleted
    $null = New-Item -ItemType Directory -Path $b3aDir
    $seedSource = Join-Path $PSScriptRoot $b3aPackage.seed.file.Replace('/', '\')
    if ((Get-FileHash -LiteralPath $seedSource).Hash -ne $b3aPackage.seed.sha256) { throw 'the bundled seed is not the manifest''s; nothing started' }
    $b3aSeedFonts = Get-Field (Get-Field (Get-Field ([IO.File]::ReadAllText($seedSource) | ConvertFrom-Json) 'webkit') 'webprefs') 'fonts'
    $b3a.seed = "written by win.ps1 beside $($b3aPackage.executable) in the owned tree"
    $page = Join-Path $b3aDir 'page.html'
    [IO.File]::WriteAllText($page, '<!doctype html><html><head><meta charset="utf-8"><title>b3a</title></head><body>' +
        '<p lang="ja">&#x65E5;&#x672C;&#x8A9E;&#x306E;&#x672C;&#x6587; default</p><p>Latin default text</p>' +
        '<p lang="ja" style="font-family:sans-serif">&#x65E5;&#x672C;&#x8A9E; sans-serif</p><p style="font-family:monospace">monospace 0O1lI</p>' +
        '<p lang="ja" style="font-family:monospace">&#x65E5;&#x672C;&#x8A9E; monospace</p></body></html>')
    $pageUrl = ([Uri]$page).AbsoluteUri
    $defaultData = Join-Path $realLocal 'Chromium'
    $b3aBaseline = @(Get-CimInstance Win32_Process -Filter "Name = 'chrome.exe'" | ForEach-Object { "$($_.ProcessId)|$($_.CreationDate.ToUniversalTime().Ticks)" })
    $script:b3aSeen = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
    $b3aLaunched = [DateTime]::UtcNow.AddSeconds(-1)
    $treeBefore, $defaultBefore, $hkcuBefore = (EntryStamps $b3aTree), (EntryStamps $defaultData), (HkcuNames)
    $b3a.status = 'started'
    # (1) The first GUI run on an empty profile: First Run, then the six preferences once it has closed. Its windows are
    # closed one by one as a user would; ours then get 45 s to end by themselves. Which of H1 (the browser and all ours
    # end), H2 (the browser stays for an observed reason: background mode, or a window left after closing) or H3 (a chrome.exe
    # from outside the tree) holds is decided on positive evidence only; anything else fails the proof.
    $userData = Join-Path $b3aDir 'user-data'
    try {
        $wait = [Math]::Min(10, (B3aLeft 72 'first run') - 62)
        $browser = StartChromium @("--user-data-dir=$userData", $pageUrl)
        $seconds = WaitFor { (Test-Path -LiteralPath (Join-Path $userData 'First Run')) -and (Test-Path -LiteralPath (Join-Path $userData 'Default\Preferences')) } $wait
        Start-Sleep -Seconds 2  # the page renders with the profile's fonts
        $windows = CloseWindows $browser
        # A window still there after the closing (one that did not close, or a sixth) is an observed reason to stay.
        $windowLeft = try { $browser.Refresh(); -not $browser.HasExited -and $browser.MainWindowHandle -ne [IntPtr]::Zero } catch { $false }
        $settle = SettleChromium 45 $browser
        $b3a.firstRun = "First Run and Default\Preferences $(if ($null -ne $seconds) { "after $seconds s" } else { "NOT BOTH within $wait s" }); sent $($windows.Count) close request(s) to windows $(Few @($windows | ForEach-Object { "'$_'" })); $(if ($windowLeft) { 'a WINDOW IS LEFT' } else { 'no window left' }); $(SettleText $settle)"
        $b3a.firstRunSentinel = $(if (Test-Path -LiteralPath (Join-Path $userData 'First Run')) { 'present' } else { 'ABSENT' })
        $b3a.firstRunPreferences = SeedPreferences (Join-Path $userData 'Default\Preferences')
        $background = try { Get-Field (Get-Field ([IO.File]::ReadAllText((Join-Path $userData 'Local State')) | ConvertFrom-Json -AsHashtable) 'background_mode') 'enabled' } catch { 'unreadable' }
        $b3a.backgroundMode = $(if ($null -eq $background) { 'background_mode.enabled absent' } else { "background_mode.enabled $background" })
        if ($b3a.firstRunSentinel -ne 'present') { $b3aStops.Add('no First Run after a first run') }
        if ($b3a.firstRunPreferences -ne 'all six equal the seed') { $b3aStops.Add("seed preferences: $($b3a.firstRunPreferences)") }
        $outside = @($script:b3aSeen.Values | Where-Object { $_.class -ceq 'outside' })
        $b3a.decision = if ($outside.Count) { "H3: chrome.exe from outside the tree $(Few @($outside | ForEach-Object { $_.path }))" }
            elseif (-not $windows.Count) { 'unproven: no main window to close (the runner''s GUI)' }
            elseif ($settle.unknown.Count) { 'unproven: unknown processes still running' }
            elseif ($settle.endedAll -and $null -ne $settle.browserEnded -and @($script:b3aSeen.Values | Where-Object { $_.class -ceq 'tree' }).Count) {
                'H1: the browser and every process of ours ended by themselves'
            }
            elseif ($null -eq $settle.browserEnded -and ($background -eq $true -or $windowLeft)) {
                "H2: the browser stayed; $($b3a.backgroundMode)$(if ($windowLeft) { ', a window left after closing' })"
            }
            else { 'undecided: ours did not end and no reason was observed' }
        if ($b3a.decision -like 'H3*') { $b3aStops.Add('H3: a process started from outside the tree') }
        elseif ($b3a.decision -notlike 'H[12]*') { $b3aStops.Add("process behaviour $($b3a.decision)") }
    } catch { $b3a.firstRun = "not observed: $($_.Exception.Message -replace '(.{300}).+', '$1...')"; $b3aStops.Add('first run unproven') }
    # (2) A first run over existing Preferences without First Run: which markers survive (O1's premise and range).
    try {
        $wait = [Math]::Min(8, (B3aLeft 35 'overwrite') - 27)
        $b3aRestored = Join-Path $b3aDir 'restored'
        $null = New-Item -ItemType Directory -Path (Join-Path $b3aRestored 'Default'), (Join-Path $b3aRestored 'Profile 1')
        foreach ($name in 'Default', 'Profile 1') { [IO.File]::WriteAllText((Join-Path $b3aRestored "$name\Preferences"), "{`"b3a_marker`":`"$name`"}") }
        $browser = StartChromium @("--user-data-dir=$b3aRestored", $pageUrl)
        $seconds = WaitFor { Test-Path -LiteralPath (Join-Path $b3aRestored 'First Run') } $wait
        Start-Sleep -Seconds 2
        $windows = CloseWindows $browser
        $settled = SettleText (SettleChromium 10 $browser)
        $marks = @(foreach ($name in 'Default', 'Profile 1') {
            $file = Join-Path $b3aRestored "$name\Preferences"
            $kept = (Test-Path -LiteralPath $file) -and [IO.File]::ReadAllText($file).Contains('"b3a_marker"')
            "$name $(if ($kept) { 'kept' } else { 'OVERWRITTEN' }) ($(SeedPreferences $file))"
        })
        $b3a.overwrite = "First Run $(if ($null -ne $seconds) { "after $seconds s" } else { "NOT within $wait s" }); $($marks -join '; '); sent $($windows.Count) close request(s); $settled"
        if ($marks[1] -like '*OVERWRITTEN*') { $b3aStops.Add('Profile 1 is overwritten too, while SeedHazard reads only Default') }
    } catch {
        $b3a.overwrite = "not observed: $($_.Exception.Message -replace '(.{300}).+', '$1...')"
        $b3aStops.Add('the overwrite range (Default and Profile 1) was not observed')
    }
    # (3) The first profile printed headless: the fonts the PDF embeds (unproven when no /BaseFont is readable).
    try {
        $pdf = Join-Path $b3aDir 'page.pdf'
        $print = Bounded $b3aExe @('--headless=new', "--user-data-dir=$userData", "--print-to-pdf=$pdf", $pageUrl) ([Math]::Min(30, (B3aLeft 20 'headless PDF') - 10))
        $settled = SettleText (SettleChromium 8 $null)
        if (-not (Test-Path -LiteralPath $pdf)) { throw "no PDF (exit $($print.exit), $($print.seconds) s; $(Tail $print.stderr)); $settled" }
        $embedded = @([regex]::Matches([Text.Encoding]::Latin1.GetString([IO.File]::ReadAllBytes($pdf)), '/BaseFont\s*/(?:[A-Z]{6}\+)?([^\s/\[\]<>()]+)') |
            ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
        if (-not $embedded.Count) { $b3a.pdf = "unproven: no readable /BaseFont (exit $($print.exit), $($print.seconds) s); $settled" }
        else {
            $plex, $plemol = [bool]@($embedded | Where-Object { $_ -like 'IBMPlexSansJP*' }).Count, [bool]@($embedded | Where-Object { $_ -like 'PlemolJPConsoleNF*' }).Count
            $b3a.pdf = "embeds $($embedded -join ', '); IBM Plex Sans JP $(if ($plex) { 'yes' } else { 'NO' }), PlemolJP Console NF $(if ($plemol) { 'yes' } else { 'NO' }); $settled"
            if (-not ($plex -and $plemol)) { $b3aStops.Add('the PDF lacks a seeded font') }
        }
    } catch { $b3a.pdf = "not observed: $($_.Exception.Message -replace '(.{300}).+', '$1...')" }
    # After every run: the tree, the processes, the default profile location and HKCU (C9).
    $treeChanges = @(StampDiff $treeBefore (EntryStamps $b3aTree))
    $b3a.tree = $(if ($treeChanges.Count) { "CHANGED: $(Few $treeChanges)" } else { 'still exactly the inventory and the seed' })
    if ($treeChanges.Count) { $b3aStops.Add('the tree changed') }
    # Every chrome.exe seen in any run, by class; parent and type for the ones not in the tree.
    $seenAll = @($script:b3aSeen.Values)
    $b3a.processes = (@('tree', 'descendant', 'outside', 'unknown' | ForEach-Object { $class = $_; "$class $(@($seenAll | Where-Object { $_.class -ceq $class }).Count)" }) -join ', ') +
        "; not in the tree: $(Few @($seenAll | Where-Object { $_.class -cne 'tree' } | ForEach-Object { "$($_.class) $($_.type)[$($_.id)<$($_.parent)]$(if ($_.path) { ' ' + $_.path })" }))"
    if (@($seenAll | Where-Object { $_.class -ceq 'outside' }).Count -and -not $b3aStops.Contains('H3: a process started from outside the tree')) {
        $b3aStops.Add('H3: a process started from outside the tree')
    }
    # C9 before any move aside, so a failed move cannot lose it: every added name where registration matters (at most 100
    # each), only the count and first names under Software\Chromium, Chromium's own state.
    $hkcuAfter = HkcuNames
    $added = @($hkcuAfter | Where-Object { -not $hkcuBefore.Contains($_) } | Sort-Object)
    $removed = @($hkcuBefore | Where-Object { -not $hkcuAfter.Contains($_) } | Sort-Object)
    $b3aGroups = [ordered]@{ 'App Paths' = 'Software\Microsoft\Windows\CurrentVersion\App Paths'; Uninstall = 'Software\Microsoft\Windows\CurrentVersion\Uninstall'
        StartMenuInternet = 'Software\Clients\StartMenuInternet'; RegisteredApplications = 'Software\RegisteredApplications'; 'Classes (names directly under it and OpenWithProgids)' = 'Software\Classes' }
    foreach ($group in $b3aGroups.GetEnumerator()) {
        $names = @($added | Where-Object { $_.StartsWith($group.Value + '\', [StringComparison]::OrdinalIgnoreCase) -or $_.StartsWith($group.Value + '|', [StringComparison]::OrdinalIgnoreCase) })
        $b3a["hkcu $($group.Key)"] = "added $($names.Count)$(if ($names.Count) { ': ' + (@($names | Select-Object -First 100) -join ', ') + $(if ($names.Count -gt 100) { ', ...' }) })"
    }
    $b3a['hkcu Software\Chromium'] = "added $(Few @($added | Where-Object { $_.StartsWith('Software\Chromium', [StringComparison]::OrdinalIgnoreCase) }))"
    $b3a.hkcuRemoved = "removed $(Few $removed)"
    if (@($added | Where-Object { $_ -like 'Software\Microsoft\Windows\CurrentVersion\App Paths*' -or $_ -like 'Software\Microsoft\Windows\CurrentVersion\Uninstall*' }).Count) {
        $b3aStops.Add('App Paths or Uninstall gained an entry')
    }
    $defaultChanges = @(StampDiff $defaultBefore (EntryStamps $defaultData))
    $b3a.defaultProfile = $(if ($defaultChanges.Count) { "CHANGED: $(Few $defaultChanges)" } else { "nothing new under $defaultData" })
    if ($defaultChanges.Count) {
        $b3aStops.Add('the default profile location changed')
        # Move what is new aside (never delete it), top-most entries only, so A28 and the proof's cleanup of its stand-in
        # hold: each source strictly beneath the default location with no reparse point on the way, each target in a
        # fresh directory beside it. Anything not moved is a stop condition, as is a failed move.
        try {
            $aside = Join-Path $realLocal ('b3a-aside-' + [guid]::NewGuid().ToString('N'))
            if (Test-Path -LiteralPath $aside) { throw "$aside already exists" }
            $null = New-Item -ItemType Directory -Path $aside
            $asideFull = [IO.Path]::GetFullPath($aside)
            $new = @($defaultChanges | Where-Object { $_.StartsWith('+') } | ForEach-Object { $_.Substring(1) } | Sort-Object Length)
            $moved, $unsafe = 0, @()
            foreach ($relative in $new) {
                if (@($new | Where-Object { $relative.StartsWith($_ + '\') }).Count) { continue }
                $source, $target = ($defaultData + $relative), (Join-Path $aside ([string]$moved))
                if (-not (SafeBeneath $source $defaultData) -or -not [IO.Path]::GetFullPath($target).StartsWith($asideFull + '\', [StringComparison]::OrdinalIgnoreCase)) {
                    $unsafe += $relative; continue
                }
                if (Test-Path -LiteralPath $source -PathType Container) { [IO.Directory]::Move($source, $target) } else { [IO.File]::Move($source, $target) }
                $moved++
            }
            $b3a.defaultProfile += "; moved $moved new entries aside to $aside"
            if ($unsafe.Count) {
                $b3a.defaultProfile += "; NOT moved (outside it or a reparse point): $(Few $unsafe)"
                $b3aStops.Add('a new default-profile entry was not moved aside: A28 and the cleanup may fail')
            }
        } catch {
            $b3a.defaultProfile += "; could NOT move aside: $($_.Exception.Message -replace '(.{200}).+', '$1...')"
            $b3aStops.Add('a new default-profile entry was not moved aside: A28 and the cleanup may fail')
        }
    }
    $b3a.status = "observed in $([Math]::Round($b3aClock.Elapsed.TotalSeconds)) s of the $b3aBudget s budget"
} catch {
    $b3a.status = "not observed: $($_.Exception.Message -replace '(.{300}).+', '$1...')"
    $b3aStops.Add('the first-run observation did not complete')
} finally {
    try {
        if (Get-Variable -Name b3aSeen -Scope Script -ErrorAction SilentlyContinue) {
            $b3aFinal = SettleChromium 5 $null
            $b3a.finalSettle = SettleText $b3aFinal
            if ($b3aFinal.survivors.Count -or $b3aFinal.unknown.Count) { $b3aStops.Add('processes remain after the observation: unproven') }
        }
    } catch { $b3a.finalSettle = "not settled: $($_.Exception.Message -replace '(.{200}).+', '$1...')" }
}
foreach ($entry in $b3a.GetEnumerator()) { B3a "$($entry.Key): $($entry.Value)" }
B3a "stop conditions: $(if ($b3aStops.Count) { $b3aStops -join '; ' } else { 'none observed' })"
Must (-not $b3aStops.Count) "A29: Chromium's first run on the owned tree: $($b3aStops -join '; ')"
# After its first run a second Apply writes nothing for Chromium, which is still exactly owned (win.ps1's own reading).
$mark = LastSeq
$chromiumAgain = ApplyPackages 'Chromium'
Must ((NewRecords $mark @($chromiumId)) -eq 0 -and @($chromiumAgain.packages | Where-Object { $_.name -ceq 'Chromium' })[0].class -ceq 'owned-match' -and
    (ProfileKept)) 'A29: after its first run a second Apply writes nothing for Chromium, still owned exactly'
# A30 (S2-2d-b), within A29 so Chromium is downloaded once: A29's install also owned HKCU App Paths\<appPath> (key,
# then its default REG_SZ naming the owned chrome.exe) and its second Apply wrote nothing for them; ShellExecute
# (Win+R's API), from an empty directory and with chromium on no PATH, starts the owned chrome.exe by that name
# (appPathsLaunch 'proven'), or on this elevated runner none of the names tried here (chromium, chromium.exe,
# same-name probe in two spellings) resolved using this ShellExecute method ('unproven');
# a value this distribution does not own in the key stops Uninstall before any removal (A3). Foreign keys, HKLM and
# retired names are proven by the primitives on a throwaway name; Win+R itself only on the VM (S7), before #7 is
# complete and before this build is used on a real host.
$appSubkey = "Software\Microsoft\Windows\CurrentVersion\App Paths\$($chromium.appPath)"
$appKeyId, $appValueId = ('registry-key-created:' + "HKCU\$appSubkey".ToUpperInvariant()), ('registry-value:' + "HKCU\$appSubkey|".ToUpperInvariant())
$chromiumExe = Join-Path $chromiumTree $chromium.executable.Replace('/', '\')
function AppPathKeyNow {
    $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($appSubkey)
    if ($null -eq $key) { return $null }
    try {
        $names = @($key.GetValueNames())
        [pscustomobject]@{ values = $names; subkeys = @($key.GetSubKeyNames()); kind = $(if ($names -contains '') { [string]$key.GetValueKind('') })
            data = [string]$key.GetValue('', $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames) }
    } finally { $key.Close() }
}
$shellDir = Join-Path $env:RUNNER_TEMP ('a30-' + [guid]::NewGuid().ToString('N'))  # empty, never deleted
$null = New-Item -ItemType Directory -Path $shellDir
# ShellExecuteEx, as Win+R: the name alone, resolved by Windows. WorkingDirectory stays unset: with UseShellExecute
# it names where the executable is (the .NET documentation), which bypasses App Paths. Only around the start is this
# process's current directory the empty $shellDir (restored in finally), so nothing there can answer the name.
function ShellStart([string]$Name, [string]$Arguments) {
    $info = [Diagnostics.ProcessStartInfo]::new($Name)
    $info.UseShellExecute, $info.Arguments = $true, $Arguments
    $saved = [IO.Directory]::GetCurrentDirectory()
    try { [IO.Directory]::SetCurrentDirectory($shellDir); [Diagnostics.Process]::Start($info) } finally { [IO.Directory]::SetCurrentDirectory($saved) }
}
# The executable path of a started process, read by CIM for up to $Seconds; '' when it cannot be read.
function StartedPath($Process, [int]$Seconds) {
    $path, $clock = '', [Diagnostics.Stopwatch]::StartNew()
    while ($null -ne $Process -and -not $path -and $clock.Elapsed.TotalSeconds -lt $Seconds) {
        $path = [string](Get-CimInstance Win32_Process -Filter "ProcessId = $($Process.Id)").ExecutablePath
        if (-not $path) { Start-Sleep -Milliseconds 250 }
    }
    $path
}
# One ShellStart by $Name: { name; process; path (CIM, '' when unread); code (the Win32 error when it raised one, else
# $null); error (the failure's message) }. Nothing started only when code is set and process is $null.
function A30Try([string]$Name, [string]$Arguments, [int]$Seconds) {
    $try = [pscustomobject]@{ name = $Name; process = $null; path = ''; code = $null; error = '' }
    try { $try.process = ShellStart $Name $Arguments; $try.path = StartedPath $try.process $Seconds }
    catch {
        $failure = $_.Exception.GetBaseException()
        $try.error = $failure.Message
        if ($failure -is [ComponentModel.Win32Exception]) { $try.code = $failure.NativeErrorCode }
    }
    $try
}
function A30Text($Try) {
    "$($Try.name) -> $(if ($null -ne $Try.code) { "Win32 $($Try.code) ($($Try.error))" } elseif ($Try.error) { "failed: $($Try.error)" } elseif ($Try.path) { "started $($Try.path)" } else { 'started, path unread' })"
}
function A30NotFound($Try) { $Try.code -eq 2 -and $null -eq $Try.process -and -not $Try.path }
$a30ChromiumArguments = "--headless=new `"--user-data-dir=$shellDir\profile`" about:blank"
$appNow = AppPathKeyNow
Must ((Phases $appKeyId) -ceq 'intent,commit' -and (Phases $appValueId) -ceq 'intent,commit' -and (NewRecords $mark @($appKeyId, $appValueId)) -eq 0 -and
    $null -ne $appNow -and $appNow.values.Count -eq 1 -and $appNow.values[0] -ceq '' -and -not $appNow.subkeys.Count -and $appNow.kind -ceq 'String' -and
    $appNow.data -ceq $chromiumExe) 'A30: the install owns App Paths\chromium.exe, one REG_SZ default value naming the owned chrome.exe; a second Apply writes nothing'
Must ($null -eq (Get-Command chromium -ErrorAction SilentlyContinue) -and $null -eq (Get-Command chromium.exe -ErrorAction SilentlyContinue) -and
    -not @(Get-ChildItem -LiteralPath $shellDir -Force -Filter 'chromium*').Count) 'A30: chromium and chromium.exe are on no PATH nor in the empty start directory, so only App Paths can resolve them'
# appPathsLaunch: 'proven' when ShellExecute starts exactly the owned chrome.exe by the name chromium (then the same
# launch must fail with Win32 error 2 after Uninstall); otherwise chromium.exe and a same-name HKCU probe (a copy of
# PING.EXE named proof-<guid>.exe, in its own scratch directory, never the empty start directory, under the key of that
# very name, removed again in finally, only its own PID waited for or killed) are tried in both spellings, and
# 'unproven' only when all four fail with Win32 error 2 (file not found) and this process is elevated: then none of the
# names tried here (chromium, chromium.exe, same-name probe in two spellings) resolved using this ShellExecute method,
# and only the VM (S7) can prove the launch. Anything else fails A30.
$a30Launch = A30Try 'chromium' $a30ChromiumArguments 15
$a30Lines = [Collections.Generic.List[string]]::new()
$a30Lines.Add("$(A30Text $a30Launch); $(if ($null -ne $a30Launch.process) { SettleText (SettleChromium 15 $a30Launch.process) })")
$appPathsLaunch = if ($a30Launch.path -eq $chromiumExe) { 'proven' } else { $null }
if (-not $appPathsLaunch) {
    $a30Explicit = A30Try 'chromium.exe' $a30ChromiumArguments 10
    $a30Lines.Add("$(A30Text $a30Explicit); $(if ($null -ne $a30Explicit.process) { SettleText (SettleChromium 10 $a30Explicit.process) })")
    $a30ProbeName = 'proof-' + [guid]::NewGuid().ToString('N')
    $a30ProbeDir = Join-Path $env:RUNNER_TEMP ('a30-probe-' + [guid]::NewGuid().ToString('N'))  # never deleted
    $null = New-Item -ItemType Directory -Path $a30ProbeDir
    $a30ProbeExe = Join-Path $a30ProbeDir "$a30ProbeName.exe"
    [IO.File]::Copy((Join-Path $env:SystemRoot 'System32\PING.EXE'), $a30ProbeExe, $false)
    $a30ProbeKey = "Software\Microsoft\Windows\CurrentVersion\App Paths\$a30ProbeName.exe"
    $a30Probes = @()
    $a30Created = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($a30ProbeKey)
    try {
        try { $a30Created.SetValue('', $a30ProbeExe, [Microsoft.Win32.RegistryValueKind]::String) } finally { $a30Created.Close() }
        foreach ($a30Form in $a30ProbeName, "$a30ProbeName.exe") {
            $a30Probe = A30Try $a30Form '-n 3 127.0.0.1' 5
            if ($null -ne $a30Probe.process -and -not $a30Probe.process.WaitForExit(8000)) { try { $a30Probe.process.Kill() } catch { } }
            $a30Probes += $a30Probe
            $a30Lines.Add("$(A30Text $a30Probe) (same-name HKCU probe, expected $a30ProbeExe)")
        }
    } finally { [Microsoft.Win32.Registry]::CurrentUser.DeleteSubKey($a30ProbeKey, $false) }
    $a30Elevated = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    $a30Policy = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey('SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System')
    $a30Lua = if ($null -eq $a30Policy) { 'absent' } else { try { [string]$a30Policy.GetValue('EnableLUA', 'absent') } finally { $a30Policy.Close() } }
    $a30Lines.Add("elevated (Administrators role): $a30Elevated; EnableLUA: $a30Lua")
    if ($a30Elevated -and -not @(@($a30Launch, $a30Explicit) + $a30Probes | Where-Object { -not (A30NotFound $_) }).Count) { $appPathsLaunch = 'unproven' }
}
foreach ($a30Line in $a30Lines) { Write-Host "A30 launch: $a30Line" }
Write-Host "A30 appPathsLaunch: $(if ($appPathsLaunch) { $appPathsLaunch } else { 'failed' })"
Must ($null -ne $appPathsLaunch) "A30: ShellExecute neither starts the owned chrome.exe by the name chromium nor fails, on this elevated runner, with none of the names tried here (chromium, chromium.exe, same-name probe in two spellings) resolved using this ShellExecute method ($($a30Lines -join '; '))"
$held = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($appSubkey, $true)
try { $held.SetValue('Path', $shellDir) } finally { $held.Close() }
$count = @(Ledger).Count
MustReject { RunUninstall -Apply } "*holds foreign content the plan does not remove: value 'Path'*"
Must (@(Ledger).Count -eq $count -and (ChromiumExact) -and (AppPathKeyNow).data -ceq $chromiumExe) 'A30: foreign content in the owned App Paths key stops Uninstall before any removal'
$held = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($appSubkey, $true)
try { $held.DeleteValue('Path') } finally { $held.Close() }
# Uninstall removes the tree file by file, its seed too, and never the profile or the scratch profiles.
$chromiumGone = RunUninstall -Apply
Must ($chromiumGone.ownedOpen -eq 0 -and -not (Test-Path -LiteralPath $chromiumTree) -and (ProfileKept) -and
    (Test-Path -LiteralPath (Join-Path $userData 'First Run'))) 'A29: Uninstall removes the Chromium tree with its seed, never a profile'
AssertEmpty
# A30 after Uninstall: the value, then the key, are gone and closed undone (always); and, only when the launch was
# proven, the same launch by the same name now fails with Win32 error 2 (file not found) and nothing else.
Must ($null -eq (AppPathKeyNow) -and (Phases $appKeyId) -ceq 'intent,commit,undone' -and (Phases $appValueId) -ceq 'intent,commit,undone') 'A30: Uninstall removes the App Paths value, then the key'
if ($appPathsLaunch -ceq 'proven') {
    $a30Gone = A30Try 'chromium' $a30ChromiumArguments 5
    if ($null -ne $a30Gone.process) { $null = SettleChromium 5 $a30Gone.process }
    Must (A30NotFound $a30Gone) "A30: after Uninstall ShellExecute no longer finds chromium ($(A30Text $a30Gone))"
}
# ---- A32: the six Chromium font preferences written into existing profiles (Apply -ChromiumFonts) and removed again ----
# On the proof's stand-in User Data only: its Default (the restored text) and a synthetic Profile 2 with every numeric,
# key and escape edge; Local State lists both (and a System Profile, never written). Fonts are converged first (Apply);
# -ChromiumFonts only asserts them.
$null = Run 'Apply'
$localState, $profile2 = (Join-Path $chromiumProfile 'Local State'), (Join-Path $chromiumProfile 'Profile 2')
if ((Test-Path -LiteralPath $localState) -or (Test-Path -LiteralPath $profile2)) { throw 'A32 requires no Local State or Profile 2 in the stand-in User Data yet.' }
[IO.File]::WriteAllText($localState, '{"profile":{"info_cache":{"Default":{"name":"a"},"Profile 2":{"name":"b"},"System Profile":{}}}}')
$null = New-Item -ItemType Directory -Path $profile2
$seedFonts = [IO.File]::ReadAllText((Join-Path $PSScriptRoot $chromium.seed.file)) | ConvertFrom-Json
function SeedFont([string]$Leaf) { $v = $seedFonts; foreach ($k in $Leaf.Split('.')) { $v = $v.$k }; [string]$v }
$leaves = @(Get-ChromiumFontLeaves)
$p2Prefs, $defaultPrefs = (Join-Path $profile2 'Preferences'), $preferences
$p2Original = @"
{
  "big": [9223372036854775807, -9223372036854775808, 1.7976931348623157e+308, 5e-324, 1e+05, 1.5e-05, 12345678901234567890],
  "C": 1, "c": 2, "a\"b": "café caf$([char]0x00e9)",
  "webkit": { "webprefs": { "default_font_size": 16, "fonts": { "standard": { "Zyyy": "$(SeedFont 'webkit.webprefs.fonts.standard.Zyyy')" } } } }
}
"@
[IO.File]::WriteAllText($p2Prefs, $p2Original, [Text.UTF8Encoding]::new($false))
function PrefId([string]$Prefs, [string]$Leaf) { 'pref-value:' + ($Prefs + '|' + $Leaf).ToUpperInvariant() }
function PrefIds { foreach ($prefs in $defaultPrefs, $p2Prefs) { foreach ($leaf in $leaves) { PrefId $prefs $leaf } } }
function ChromiumFonts { Win51 @('-Mode', 'Apply', '-ChromiumFonts') }
function Untouched { [IO.File]::ReadAllText($defaultPrefs) -ceq $restored -and [IO.File]::ReadAllText($p2Prefs) -ceq $p2Original -and (NewRecords $mark @(PrefIds)) -eq 0 }
$mark = LastSeq
MustReject { Win51 @('-Mode', 'Apply', '-ChromiumFonts', '-Typography') } '-ChromiumFonts is only for -Mode Apply*'
# Closed means closed: a lockfile (never removed here), or a chrome.exe running from this install, stops every profile.
[IO.File]::WriteAllText((Join-Path $chromiumProfile 'lockfile'), '')
MustReject { ChromiumFonts } '*Chromium font drift:*lockfile exists*'
Must ((Untouched) -and (Test-Path -LiteralPath (Join-Path $chromiumProfile 'lockfile'))) 'A32: a lockfile stops the write and stays'
[IO.File]::Delete((Join-Path $chromiumProfile 'lockfile'))
$fakeTree = Join-Path $programsDir 'chromium-proof'
$null = New-Item -ItemType Directory -Path $fakeTree
[IO.File]::Copy((Join-Path $env:SystemRoot 'System32\PING.EXE'), (Join-Path $fakeTree 'chrome.exe'), $false)
$fake = Start-Process -FilePath (Join-Path $fakeTree 'chrome.exe') -ArgumentList '-n', '120', '127.0.0.1' -WindowStyle Hidden -PassThru
try { MustReject { ChromiumFonts } '*Chromium is running*' } finally { $fake.Kill(); $fake.WaitForExit() }
[IO.File]::Delete((Join-Path $fakeTree 'chrome.exe')); [IO.Directory]::Delete($fakeTree, $false)
Must (Untouched) 'A32: a chrome.exe of this install stops the write'
# A key repeated through an escape makes a profile unreadable for edits: nothing is written anywhere (Default comes first).
[IO.File]::WriteAllText($defaultPrefs, '{"c":1,"c":2}')
MustReject { ChromiumFonts } '*repeats a key*'
[IO.File]::WriteAllText($defaultPrefs, $restored)
Must (Untouched) 'A32: an escaped duplicate key is refused'
# The write: Default gets all six; Profile 2 the five it lacks (its standard.Zyyy already holds the seed value:
# preexisting-match, never owned); every other byte of both stays.
$applied = ChromiumFonts
$p2Now = [IO.File]::ReadAllText($p2Prefs)
$p2Parsed, $defaultParsed = ($p2Now | ConvertFrom-Json), ([IO.File]::ReadAllText($defaultPrefs) | ConvertFrom-Json)
function FontOf($Doc, [string]$Leaf) { $v = $Doc; foreach ($k in $Leaf.Split('.')) { if ($null -eq $v -or $null -eq $v.PSObject.Properties[$k]) { return $null }; $v = $v.$k }; [string]$v }
Must ((@($applied.chromiumFonts | ForEach-Object { "$($_.profile)=$($_.written)" }) -join ',') -ceq 'Default=6,Profile 2=5' -and
    -not @($leaves | Where-Object { (FontOf $defaultParsed $_) -cne (SeedFont $_) -or (FontOf $p2Parsed $_) -cne (SeedFont $_) }).Count -and
    $defaultParsed.proof -ceq 'a profile restored by hand' -and (Phases (PrefId $p2Prefs 'webkit.webprefs.fonts.standard.Zyyy')) -ceq '' -and
    -not @($leaves | Where-Object { $_ -cne 'webkit.webprefs.fonts.standard.Zyyy' -and (Phases (PrefId $p2Prefs $_)) -cne 'intent,commit' }).Count) 'A32: the six leaves are the seed''s in both profiles; a matching one is not owned'
Must ($p2Now.Contains('[9223372036854775807, -9223372036854775808, 1.7976931348623157e+308, 5e-324, 1e+05, 1.5e-05, 12345678901234567890]') -and
    $p2Now.Contains('"C": 1, "c": 2, "a\"b": "café caf') -and $p2Now.Contains('"default_font_size": 16') -and
    -not (Test-Path -LiteralPath (Join-Path $profile2 'Preferences.*.tmp'))) 'A32: numbers, case-only keys and escapes keep their exact bytes; no temporary file left'
$mark = LastSeq
$again = ChromiumFonts
Must ((NewRecords $mark @(PrefIds)) -eq 0 -and (@($again.chromiumFonts | ForEach-Object { $_.written }) -join ',') -ceq '0,0') 'A32: a second run writes nothing'
# A font changed after this wrote it is owned-drift: reported, never written.
$owned = [IO.File]::ReadAllText($defaultPrefs)
$fixedJpan = '"Jpan":"' + (SeedFont 'webkit.webprefs.fonts.fixed.Jpan') + '"'
[IO.File]::WriteAllText($defaultPrefs, $owned.Remove($owned.LastIndexOf($fixedJpan), $fixedJpan.Length).Insert($owned.LastIndexOf($fixedJpan), '"Jpan":"Consolas"'))
MustReject { ChromiumFonts } '*Default webkit.webprefs.fonts.fixed.Jpan: changed after this wrote it*'
Must ((NewRecords $mark @(PrefIds)) -eq 0) 'A32: a changed owned font is drift and not written'
[IO.File]::WriteAllText($defaultPrefs, $owned)
# Chromium rewrites Preferences in its own form; Uninstall then removes exactly the owned leaves and the parents they made.
function Compact([string]$Text) { (@([regex]::Matches($Text, '"(?:[^"\\]|\\.)*"|[^\s"]+') | ForEach-Object { $_.Value }) -join '') }
[IO.File]::WriteAllText($p2Prefs, (Compact $p2Now))
$gone = RunUninstall -Apply
Must ($gone.ownedOpen -eq 0 -and [IO.File]::ReadAllText($defaultPrefs) -ceq $restored -and [IO.File]::ReadAllText($p2Prefs) -ceq (Compact $p2Original) -and
    -not @(PrefIds | Where-Object { (Phases $_) -cnotin @('', 'intent,commit,undone') }).Count) 'A32: Uninstall leaves both profiles as they were (Profile 2 in Chromium''s form), every owned leaf undone'
AssertEmpty
[IO.File]::Delete($p2Prefs); [IO.Directory]::Delete($profile2, $false); [IO.File]::Delete($localState)

[IO.File]::Delete($sentinel)
[IO.File]::Delete($preferences)
[IO.Directory]::Delete((Split-Path -Parent $preferences), $false)
[IO.File]::Delete("$chromiumProfile\proof.txt")
[IO.Directory]::Delete($chromiumProfile, $false)
[IO.Directory]::Delete((Split-Path -Parent $chromiumProfile), $false)

# A malformed attempt (void after commit) is reported by the dry run and refused by -Apply; nothing changes.
$badBytes = Bytes 'proof: malformed attempt'
$badPath = Join-Path $fontDir ((ShaOf $badBytes) + '.ttf')
$firstBad = 1 + @(Ledger).Count
CraftFile $badPath (ShaOf $badBytes) @('intent', 'commit')
Craft @{ phase = 'void'; id = (FileId $badPath); kind = 'file-created'; target = $badPath; prior = $absent
    desired = @{ exists = $true; sha256 = (ShaOf $badBytes) }; observed = $absent }
$before = Snapshot
MustReject { RunUninstall } 'Uninstall refused; nothing was removed:*A committed attempt cannot be voided*'
MustReject { RunUninstall -Apply } 'Uninstall refused for S-1-*A committed attempt cannot be voided*'
if ((Snapshot) -cne $before) { throw 'Uninstall changed state while refusing a malformed ledger.' }
foreach ($seq in $firstBad..($firstBad + 2)) { [IO.File]::Delete((Join-Path $ledgerDir ('{0:D8}.json' -f $seq))) }  # the proof's own crafted records

# A11: an id this version does not handle stops Uninstall (reporting who ran it) and Apply.
$strangerPath = Join-Path $env:RUNNER_TEMP 'proof-unhandled.bin'
[IO.File]::WriteAllText($strangerPath, 'proof')
$strangerSha = (Get-FileHash -LiteralPath $strangerPath).Hash.ToLowerInvariant()
Craft @{ phase = 'intent'; id = (FileId $strangerPath); kind = 'file-created'; target = $strangerPath; prior = $absent; desired = @{ exists = $true; sha256 = $strangerSha } }
Craft @{ phase = 'commit'; id = (FileId $strangerPath); kind = 'file-created'; target = $strangerPath; prior = $absent
    desired = @{ exists = $true; sha256 = $strangerSha }; observed = @{ exists = $true; sha256 = $strangerSha } }
MustReject { RunUninstall -Apply } 'Uninstall refused for S-1-*does not handle*'
MustReject { Run 'Apply' } '*does not handle*'

# Rent SSH client, bound explicitly with synthetic values (a live binding comes from envs and the rent's own host key).
# It proves the pinned client, the generated OpenSSH configuration and the Include handling; it never connects.
$bind = @{ Hostname = 'rent.example.invalid'; HostKey = 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGNpLXN5bnRoZXRpYy1ob3N0LWtleS1ub3QtcmVhbA=='
    Identity = (Join-Path $env:RUNNER_TEMP 'rent-ci-identity') }
[IO.File]::WriteAllText($bind.Identity, 'synthetic identity path; never used to connect')
function RunSsh([string]$Mode, [hashtable]$With = $bind) {
    Win51 @(@('-Mode', $Mode) + @($With.Keys | Sort-Object | ForEach-Object { "-$_"; [string]$With[$_] }))
}
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

# The G4 gate, after every other proof has printed its evidence.
if ($g4.status -cne 'measured' -or (Get-Field $g4 'gate') -cne 'pass' -or $g4.startupRestore -cne 'verified') {
    throw "G4 gate failed: status $($g4.status); gate $(Get-Field $g4 'gate'); startup restore $($g4.startupRestore)"
}

[ordered]@{ source = $ExpectedSource; proof = 'PASS'; fonts = $first.fonts;
    secondApplyChanges = 0; ownedDriftRepaired = $true; unownedDriftRefused = $true; corruptionRejected = $true
    ledger = 'intent/commit per owned font file and value; crash recovery, lock, torn record, GC, update, Uninstall (dry run, locked file, references) proven on synthetic state'
    uninstallEmptiedOwnedFonts = $true;
    rentSsh = "cloudflared $($manifest.cloudflared.version) client, strict config, Include preserved and idempotent, drift repaired"
    winReportsHandoffUnproven = $true; handoffProbeRefusedOnRunner = $true; handoffEvaluatorCases = $handoffCases;
    g4Measurement = $g4;
    noctty = 'native owned tree, configuration, COM keys and values and the default-terminal selection through Apply and Uninstall (A15-A21)'
    appPathsLaunch = $appPathsLaunch
    scope = 'current-user owned fonts, Noctty, SSH client and locked packages (AutoHotkey ZIP and Chromium 7z with its font seed: install, ownership, its App Paths registration' + $(if ($appPathsLaunch -ceq 'proven') { ' and its resolution by ShellExecute' } else { '; App Paths launch unproven on this elevated runner, VM S7 required' }) + ', first run on scratch profiles, Uninstall) on an elevated Windows Server runner with Windows Terminal 1.23; not Restore (activation, package view, rollback), a clean unelevated Windows 11 user, Chromium on the default profile or started from Win+R itself, default-terminal handoff, real-host UX or a Cloudflare connection' } | ConvertTo-Json
