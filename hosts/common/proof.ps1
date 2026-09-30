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
# console width: its lines are rejoined up to the "At <script>:<line> char:<n>" line.
$windowsPowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
function Win51([string[]]$Arguments) {
    $ErrorActionPreference = 'Continue'  # the child's stderr is data here, not an error of this process
    $PSNativeCommandUseErrorActionPreference = $false
    $lines = @(& $windowsPowerShell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'win.ps1') @Arguments 2>&1)
    $code = $LASTEXITCODE
    $stdout = @($lines | Where-Object { $_ -isnot [Management.Automation.ErrorRecord] } | ForEach-Object { [string]$_ } | Where-Object { $_.Trim() })
    $stderr = @($lines | Where-Object { $_ -is [Management.Automation.ErrorRecord] } | ForEach-Object { $_.ToString() })
    if ($code -ne 0) {
        $message, $atPosition = '', $false
        foreach ($line in $stderr) {
            if ($line -match '^At .+ char:\d+\s*$') { $atPosition = $true }
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
    @('registry-key-created', 'HKCU\Software\Classes\CLSID\{W}', $absent, @{ exists = $true }, $null))
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
function Ledger {
    if (-not (Test-Path -LiteralPath $ledgerDir)) { return @() }
    @(Get-ChildItem -LiteralPath $ledgerDir -Filter '*.json' | Sort-Object Name | ForEach-Object { [IO.File]::ReadAllText($_.FullName) | ConvertFrom-Json })
}
function Phases([string]$Id) { @(Ledger | Where-Object { $_.id -ceq $Id } | ForEach-Object { $_.phase }) -join ',' }
# A record the proof writes itself, in the ledger's own format and next seq, to model an interrupted run.
function Craft([hashtable]$Fields) {
    $seq = 1 + [long](@(Ledger | ForEach-Object { [long]$_.seq }) + 0 | Measure-Object -Maximum).Maximum
    $entry = [ordered]@{ ledger = 'effects'; schema = 1; seq = $seq }
    foreach ($k in 'phase', 'id', 'kind', 'target', 'name', 'prior', 'desired', 'observed', 'temp') { if ($Fields.ContainsKey($k)) { $entry[$k] = $Fields[$k] } }
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
# ---- G4/G3 measurement: printed evidence only; nothing here fails the proof ----
# It runs before the font proof, so a later failure (e.g. a registered font Windows keeps
# open) cannot suppress this evidence. The exact bundled Noctty registers itself for the
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

    $unregister = Vendor (Join-Path $install 'noctty.com') '+unregister-default-terminal'
    $s3 = RegistrySnapshot 'CurrentUser' 'Default' @('')
    $remains = @(SnapshotDiff $s1 $s3 | Where-Object { Region $_.key })
    Say "vendor +unregister-default-terminal exit $($unregister.exit): $($unregister.output)"
    foreach ($d in $remains) { Say "REMAINS $($d.change) HKCU\$($d.key) [$($d.name)] $($d.before) -> $($d.after)" }
    $g4 = [ordered]@{ status = 'measured'; registerExit = $register.exit; versionExit = $version.exit; unregisterExit = $unregister.exit
        classesConsoleChanges = $vendorRegion.Count; otherHkcuChanges = $other.Count; mentions = $mentions.Count
        hklmChanges = $machine.Count; installFileChanges = $treeDiff.Count + @(SnapshotDiff $tree2 $tree3).Count
        userNocttyFileChanges = $userDiff.Count; remainingAfterUnregister = $remains.Count; controlNoise = $noise.Count
        windowsTerminal = $wtVersion; seededDelegationConsole = $true; startupKeyCreated = -not $startupSaved.keyExisted }
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

foreach ($font in $fonts) {
    if ((Test-Path -LiteralPath (FontPath $font)) -or $null -ne (FontValue (ValueName $font))) { throw 'Proof requires a fresh disposable font target.' }
}
if (Test-Path -LiteralPath $ledgerDir) { throw 'Proof requires no effect ledger yet.' }
$n = $fonts.Count
# A6 (owned): an Apply interrupted after committing fonts[0]'s file and before its value left
# that owned file unregistered, and its bytes were then damaged. Only an unregistered file can
# be damaged here: Windows keeps a registered per-user font file open without write sharing.
$null = New-Item -ItemType Directory -Path $fontDir, $ledgerDir -Force
CraftFile (FontPath $fonts[0]) $fonts[0].sha256.ToLowerInvariant() @('intent', 'commit')
[IO.File]::WriteAllText((FontPath $fonts[0]), 'negative-control')
MustReject { Run 'Test' } 'Installed bytes differ:*'

# A1: the first Apply reverts and owns fonts[0]'s damaged file again, then owns every other file
# and every value from no record at all (one intent and one commit each); a second Apply writes nothing.
$first = Run 'Apply'
if ($first.copied -ne $n -or $first.changedProperties -ne $n -or $first.removed -ne 1 -or $first.recordsWritten -ne 4 * $n + 1 -or
    @(Ledger).Count -ne 4 * $n + 3 -or (Get-FileHash -LiteralPath (FontPath $fonts[0])).Hash -ne $fonts[0].sha256 -or
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

# Owned value drift is repaired by reverting and owning again (registry only; damaged bytes are A6 above).
SetFontValue (ValueName $fonts[0]) 'negative-control'
MustReject { Run 'Test' } 'Registry drift:*'
$fixed = Run 'Apply'
if ($fixed.changedProperties -ne 1 -or $fixed.removed -ne 1 -or (FontValue (ValueName $fonts[0])) -cne (FontPath $fonts[0])) { throw 'Owned value drift was not repaired.' }
if ((Phases (ValueId (ValueName $fonts[0]))) -cne 'intent,commit,undone,intent,commit') { throw 'The value repair is not recorded as undone then owned again.' }
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
$recovered = Run 'Apply'
if ((Phases (ValueId 'Proof Void (TrueType)')) -cne 'intent,void' -or
    (Phases (FileId $confirmPath)) -cne 'intent,commit,undone' -or (Test-Path -LiteralPath $confirmPath) -or
    (Phases (FileId $tempTarget)) -cne 'intent,void' -or (Test-Path -LiteralPath $namedTemp) -or
    (Phases (ValueId 'Proof Confirm (TrueType)')) -cne 'intent,commit,undone' -or $null -ne (FontValue 'Proof Confirm (TrueType)') -or
    (Phases (ValueId (ValueName $fonts[1]))) -cne 'intent,commit,undone,intent,commit' -or (FontValue (ValueName $fonts[1])) -cne (FontPath $fonts[1]) -or
    -not (Test-Path -LiteralPath $foreignTemp)) {
    throw 'Interrupted attempts were not recovered exactly as recorded.'
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
if (@($dry.planned).Count -ne 2 * $n -or @($dry.refused).Count -or $dry.apply -or (Snapshot) -cne $before) { throw 'The Uninstall dry run is wrong or changed state.' }

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

[ordered]@{ source = $ExpectedSource; proof = 'PASS'; fonts = $first.fonts;
    secondApplyChanges = 0; ownedDriftRepaired = $true; unownedDriftRefused = $true; corruptionRejected = $true
    ledger = 'intent/commit per owned font file and value; crash recovery, lock, torn record, GC, update, Uninstall (dry run, locked file, references) proven on synthetic state'
    uninstallEmptiedOwnedFonts = $true;
    rentSsh = "cloudflared $($manifest.cloudflared.version) client, strict config, Include preserved and idempotent, drift repaired"
    winReportsHandoffUnproven = $true; handoffProbeRefusedOnRunner = $true; handoffEvaluatorCases = $handoffCases;
    g4Measurement = $g4;
    scope = 'current-user owned fonts, registry and SSH-client convergence; not Restore/Uninstall of Noctty, the default terminal or packages, rendering, default-terminal handoff, real-host UX or a Cloudflare connection' } | ConvertTo-Json
