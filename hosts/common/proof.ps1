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
    @('registry-value', 'HKCU\Software\W', @{ exists = $true; type = 'String'; data = 'old' }, @{ exists = $true; type = 'String'; data = 'new' }, 'v'))
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
foreach ($font in $fonts) {
    if ((Test-Path -LiteralPath (FontPath $font)) -or $null -ne (FontValue (ValueName $font))) { throw 'Proof requires a fresh disposable font target.' }
}
if (Test-Path -LiteralPath $ledgerDir) { throw 'Proof requires no effect ledger yet.' }
$n = $fonts.Count
MustReject { Run 'Test' } 'Installed bytes differ:*'

# A1: one intent and one commit per owned file and value; a second Apply writes nothing.
$first = Run 'Apply'
if ($first.copied -ne $n -or $first.changedProperties -ne $n -or $first.recordsWritten -ne 4 * $n -or @(Ledger).Count -ne 4 * $n) {
    throw 'The first Apply did not own each font file and value exactly once.'
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

# Owned drift is repaired by reverting and owning again: a changed value, then damaged bytes (A6, owned).
SetFontValue (ValueName $fonts[0]) 'negative-control'
MustReject { Run 'Test' } 'Registry drift:*'
$fixed = Run 'Apply'
if ($fixed.changedProperties -ne 1 -or $fixed.removed -ne 1 -or (FontValue (ValueName $fonts[0])) -cne (FontPath $fonts[0])) { throw 'Owned value drift was not repaired.' }
if ((Phases (ValueId (ValueName $fonts[0]))) -cne 'intent,commit,undone,intent,commit') { throw 'The value repair is not recorded as undone then owned again.' }
[IO.File]::WriteAllText((FontPath $fonts[0]), 'negative-control')
MustReject { Run 'Test' } 'Installed bytes differ:*'
$fixed = Run 'Apply'
if ($fixed.copied -ne 1 -or (Get-FileHash -LiteralPath (FontPath $fonts[0])).Hash -ne $fonts[0].sha256) { throw 'Owned damaged bytes were not repaired.' }
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
    scope = 'current-user owned fonts, registry and SSH-client convergence; not Restore/Uninstall of Noctty, the default terminal or packages, rendering, default-terminal handoff, real-host UX or a Cloudflare connection' } | ConvertTo-Json
