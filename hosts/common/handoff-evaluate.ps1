# Pure evaluation: default-terminal handoff evidence, typography evidence, the
# package lock, and ownership of recorded effects. No environment checks and no
# effects, so proof.ps1 can exercise every judgment with synthetic records on CI.
# The effectful callers (win.ps1, handoff-proof.ps1) observe the machine and pass
# plain values in; they never decide ownership or verdicts themselves.
# A 'proven' verdict is only as good as the host observations passed in; CI
# never supplies real ones, so CI never claims an actual handoff.

# A property of a hashtable or a deserialized JSON object, $null when absent
# (strict mode would otherwise throw on a missing property).
function Get-Field($Object, [string]$Name) {
    if ($null -eq $Object) { return $null }
    if ($Object -is [Collections.IDictionary]) { return $Object[$Name] }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

# UTC time of a tracerpt TimeCreated/SystemTime, or $null when unparseable.
# A trailing Z is UTC. A numeric offset is not trusted: tracerpt has printed the
# local wall clock with a wrong offset (14:38:39.792622000+08:59 in Asia/Tokyo
# for 05:38:39Z), so the wall clock is converted from $Zone and the offset dropped.
# A stamp with neither is ambiguous and yields $null.
function ConvertFrom-TracerptTime([string]$Stamp, [TimeZoneInfo]$Zone = [TimeZoneInfo]::Local) {
    if ($Stamp -notmatch '^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})(\.\d+)?(Z|[+-]\d{2}:\d{2})$') { return $null }
    $fraction = if ($Matches[2]) { ($Matches[2] + '0000000').Substring(0, 8) } else { '.0000000' }
    $wall = [DateTime]::MinValue
    if (-not [DateTime]::TryParseExact($Matches[1] + $fraction, "yyyy-MM-dd'T'HH:mm:ss.fffffff",
            [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$wall)) {
        return $null
    }
    if ($Matches[3] -eq 'Z') { return [DateTime]::SpecifyKind($wall, [DateTimeKind]::Utc) }
    try { return [TimeZoneInfo]::ConvertTimeToUtc([DateTime]::SpecifyKind($wall, [DateTimeKind]::Unspecified), $Zone) }
    catch { return $null }  # a wall clock skipped by a daylight-saving change
}

# SrvInit_ReceiveHandoff events from a tracerpt XML report, each with its UTC
# time ($null when unparseable) and the TerminalClsid values it carries.
function Get-HandoffEvents([Xml.XmlDocument]$Document, [TimeZoneInfo]$Zone = [TimeZoneInfo]::Local) {
    foreach ($event in $Document.GetElementsByTagName('Event')) {
        $text = $event.OuterXml
        # Exactly the OpenConsole receive event, not SrvInit_ReceiveHandoff_OpenedPipes and similar.
        if ($text -notmatch '(?<![A-Za-z_])SrvInit_ReceiveHandoff(?![A-Za-z_])') { continue }
        $created = @($event.GetElementsByTagName('TimeCreated'))
        $stamp = if ($created.Count) { $created[0].GetAttribute('SystemTime') } else { '' }
        $time = ConvertFrom-TracerptTime $stamp $Zone
        [pscustomobject]@{
            time = $time
            clsids = @([regex]::Matches($text, 'TerminalClsid[^{]{0,200}(\{[0-9A-Fa-f-]{36}\})') |
                ForEach-Object { $_.Groups[1].Value.ToUpperInvariant() })
        }
    }
}

# Compares the HKCU default-terminal pair with the pair read inside the Windows
# Terminal package, where OpenConsole runs. $Note is set when the package view
# could not be read, or HKCU changed around it. A valid, differing package pair
# is contrary evidence; anything unread or malformed is only a gap. Where a
# differing package value comes from is not determined here.
function Compare-TerminalSelection($Hkcu, $Package, [string]$Note) {
    $guid = '^\{[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\}$'
    if ($Note) { return [ordered]@{ state = 'unavailable'; failure = $null; gap = $Note } }
    $read = {
        param($Pair, [string]$Name)
        if ($null -eq $Pair) { return '' }
        if ($Pair -is [Collections.IDictionary]) { return [string]$Pair[$Name] }
        $property = $Pair.PSObject.Properties[$Name]
        if ($null -eq $property) { return '' }
        return [string]$property.Value
    }
    $hc, $ht = (& $read $Hkcu 'console'), (& $read $Hkcu 'terminal')
    $pc, $pt = (& $read $Package 'console'), (& $read $Package 'terminal')
    if ($hc -notmatch $guid -or $ht -notmatch $guid -or $pc -notmatch $guid -or $pt -notmatch $guid) {
        return [ordered]@{ state = 'invalid'; failure = $null
            gap = 'The HKCU or Windows Terminal package view of the terminal selection is incomplete.' }
    }
    if ($pc -ne $hc -or $pt -ne $ht) {  # GUID text; -ne is case-insensitive
        return [ordered]@{ state = 'mismatch'; gap = $null
            failure = ("Inside the Windows Terminal package the selection reads $pc/$pt, not this process's HKCU $hc/$ht; " +
                "this process's HKCU may be virtualized (e.g. an app's registry silo such as an agent sandbox). " +
                'Run from an Explorer-launched, unelevated shell.') }
    }
    [ordered]@{ state = 'match'; failure = $null; gap = $null }
}

# True only when a DSC `config test` answer for packages.dsc.json shows every
# package installed at exactly its pinned version: inDesiredState, _exist, an
# actualState.version equal to the desired version, and no differing properties.
# Restore skips the WinGet `set` only then, so no installer runs. Missing
# properties read as $null (strict mode would otherwise throw) and fail the check.
function PackagesSatisfied($Answer) {
    $read = { param($Object, [string]$Name)
        if ($null -eq $Object) { return $null }
        $property = $Object.PSObject.Properties[$Name]
        if ($null -eq $property) { return $null }
        return $property.Value }
    if ((& $read $Answer 'hadErrors') -ne $false) { return $false }
    $results = @(& $read $Answer 'results' | Where-Object { $null -ne $_ })
    foreach ($item in $results) {
        $result = & $read $item 'result'
        $actual, $desired = (& $read $result 'actualState'), (& $read $result 'desiredState')
        if ((& $read $result 'inDesiredState') -ne $true -or (& $read $actual '_exist') -ne $true -or
            -not (& $read $desired 'version') -or
            [string](& $read $actual 'version') -ne [string](& $read $desired 'version') -or
            @(& $read $result 'differingProperties' | Where-Object { $_ }).Count -gt 0) { return $false }
    }
    return $results.Count -gt 0
}

# Verdict for one probe record and the events of a trace spanning it. Contrary
# evidence is 'failed'; missing or ambiguous evidence is 'unproven'.
function Get-HandoffVerdict($Record, $Events, [string]$ExpectedTerminal) {
    $from = ([DateTime]$Record.startedUtc).ToUniversalTime().AddSeconds(-5)
    $to = ([DateTime]$Record.endedUtc).ToUniversalTime().AddSeconds(5)
    $clsids, $undated = @(), 0
    foreach ($event in @($Events)) {
        if ($null -eq $event) { continue }
        if ($null -eq $event.time) { $undated++; continue }
        if ($event.time -lt $from -or $event.time -gt $to) { continue }
        $clsids += @($event.clsids)
    }
    $failures = @($Record.failures | Where-Object { $_ })
    # Probe gaps (window, package view) stay gaps; only its ETW placeholder is resolved here.
    $gaps = @($Record.gaps | Where-Object { $_ -and $_ -notlike 'Console host ETW has not been evaluated*' })
    if ($Record.handoffProof -ne 'unproven' -and $failures.Count -eq 0) { $failures += 'The probe did not end unproven.' }
    if ($Record.registrationState -ne 'registered') { $gaps += 'Noctty was not registered at probe time.' }
    if ($Record.windowOwnedByNoctty -ne $true) { $gaps += 'The probe window was not observed in the bundled Noctty.' }
    if (@($Record.newTerminalHosts | Where-Object { $_ }).Count -gt 0 -and $failures.Count -eq 0) {
        $failures += 'A new Windows Terminal host started for the probe.'
    }
    if ($undated -gt 0) { $gaps += 'Some SrvInit_ReceiveHandoff events had no parseable time.' }
    if ($clsids.Count -eq 0) { $gaps += 'No SrvInit_ReceiveHandoff TerminalClsid was recorded during the probe.' }
    elseif ($clsids.Count -gt 1) { $gaps += 'More than one handoff was recorded; launch no other console during the trace.' }
    elseif ($clsids[0] -ne $ExpectedTerminal.ToUpperInvariant()) {
        $failures += "OpenConsole handed off to $($clsids[0]), not Noctty."
    }
    [ordered]@{ terminalClsids = $clsids; failures = $failures; gaps = $gaps
        handoffProof = $(if ($failures.Count) { 'failed' } elseif ($gaps.Count) { 'unproven' } else { 'proven' }) }
}

# ---- Effect ledger: ledger 'effects', schema 1 ------------------------------
# Distinct from the older default-terminal record (see Get-LegacyTerminalPlan),
# which also says schema 1 but has no `ledger` field.
# win.ps1 writes each record as its own file with CreateNew + flush, never
# overwriting one; `seq` orders them. The functions below only judge records.
# Per id, an attempt is an `intent` written before acting, `commit`s carrying the
# readback after it, and at most one closing record: `void` (the interrupted
# intent had no effect) or `undone` (the effect was reverted). After a close, only
# a new `intent` may follow, starting a new attempt that may describe a new effect.
# A record:
#   ledger    'effects'
#   schema    1
#   seq       positive integer, unique across the ledger
#   phase     'intent' | 'commit' | 'void' | 'undone'
#   id        opaque effect key, stable for one target
#   kind      file-created | file-replaced | prefix-inserted | registry-value | tree-extracted
#   target    absolute file or directory path (drive, backslashes, no . or ..),
#             or an HKCU\ key for registry-value; never HKLM
#   name      registry-value only: the value name ('' is the default value)
#   prior     the state before the effect
#   desired   the state the effect writes; never equal to prior, so an already
#             matching target is preexisting-match and gets no intent
#   observed  absent on an intent; the readback, equal to desired on a commit
#             and to prior on a void or undone
# A state is { exists = [bool] } plus, when exists is true:
#   file kinds      sha256; prior of file-replaced and prefix-inserted also has
#                   backup, an absolute path holding the prior bytes; desired of
#                   prefix-inserted also has line, the single inserted line
#   registry-value  type (String, ExpandString, MultiString, DWord, QWord, Binary), data.
#                   DWord and QWord data are the unsigned value on both sides:
#                   observers convert the signed Int32/Int64 PowerShell reads
#                   (e.g. -1 is 4294967295); a differing representation is drift.
#   tree-extracted  files, a map of '/'-separated relative path -> sha256
# Per kind, prior and desired must be:
#   file-created, tree-extracted     prior absent, desired present
#   file-replaced, prefix-inserted   prior present with backup, desired present
#   registry-value                   prior either, desired present
# A backup file is its own file-created effect with an earlier seq, so reverse
# order restores from it before deleting it; Get-UninstallPlan enforces the pairing.

# True for one conservative Windows path segment: no separator, wildcard or
# control character, no trailing dot or space, and no reserved device name.
function Test-PathSegment([string]$Segment) {
    return -not ($Segment -in @('', '.', '..') -or $Segment -match '[\\/:*?"<>|\x00-\x1f]' -or
        $Segment -match '[. ]$' -or $Segment -match '^(CON|PRN|AUX|NUL|COM\d|LPT\d)(\..*)?$')
}

# True for an absolute file path, or an HKCU key when $Kind is registry-value.
function Test-EffectPath([string]$Kind, $Target) {
    $root = if ($Kind -eq 'registry-value') { '^HKCU\\' } else { '^[A-Za-z]:\\' }
    if ($Target -isnot [string] -or $Target -notmatch $root) { return $false }
    foreach ($segment in ($Target -replace $root, '').Split('\')) {
        if ($Kind -eq 'registry-value') { if ($segment -in @('', '.', '..')) { return $false } }
        elseif (-not (Test-PathSegment $segment)) { return $false }
    }
    return $true
}

# A '/'-path -> sha256 map as a case-insensitive hashtable, or $null when it is
# not a map, a path is not a safe relative path, a hash is malformed, or two
# paths differ only in case.
function ConvertTo-FileMap($Files) {
    if ($Files -is [Collections.IDictionary]) { $names = @($Files.Keys) }
    elseif ($Files -is [Management.Automation.PSCustomObject]) { $names = @($Files.PSObject.Properties | ForEach-Object Name) }
    else { return $null }
    $map = @{}
    foreach ($name in $names) {
        $sha = Get-Field $Files $name
        if ($name -isnot [string] -or $sha -isnot [string] -or $sha -notmatch '^[0-9A-Fa-f]{64}$' -or
            $map.ContainsKey($name)) { return $null }
        foreach ($segment in $name.Split('/')) {
            if (-not (Test-PathSegment $segment)) { return $null }
        }
        $map[$name] = $sha
    }
    return $map
}

# The first problem with one state of $Kind, or $null when it is well formed.
function Get-EffectStateProblem([string]$Kind, $State, [string]$Role) {
    $exists = Get-Field $State 'exists'
    if ($exists -isnot [bool]) { return "$Role.exists is not a boolean." }
    if (-not $exists) { return $null }
    switch ($Kind) {
        'registry-value' {
            if ((Get-Field $State 'type') -cnotin @('String', 'ExpandString', 'MultiString', 'DWord', 'QWord', 'Binary')) {
                return "$Role.type is not a registry value type."
            }
            if ($null -eq (Get-Field $State 'data')) { return "$Role.data is missing." }
        }
        'tree-extracted' {
            if ($null -eq (ConvertTo-FileMap (Get-Field $State 'files'))) { return "$Role.files is not a safe path -> sha256 map." }
        }
        default {
            $sha = Get-Field $State 'sha256'
            if ($sha -isnot [string] -or $sha -notmatch '^[0-9A-Fa-f]{64}$') { return "$Role.sha256 is not a SHA-256." }
        }
    }
    return $null
}

# True when two states of $Kind are the same observable state. Files compare by
# sha256 only (backup and line are not state); registry values by type and the
# case-sensitive JSON of data; trees by the exact file set, so an extra file differs.
function Test-EffectStateEqual([string]$Kind, $Expected, $Actual) {
    $e, $a = (Get-Field $Expected 'exists'), (Get-Field $Actual 'exists')
    if ($e -isnot [bool] -or $a -isnot [bool] -or $e -ne $a) { return $false }
    if (-not $e) { return $true }
    switch ($Kind) {
        'registry-value' {
            return ([string](Get-Field $Expected 'type') -ceq [string](Get-Field $Actual 'type') -and
                (ConvertTo-Json -Compress -InputObject @(Get-Field $Expected 'data')) -ceq
                (ConvertTo-Json -Compress -InputObject @(Get-Field $Actual 'data')))
        }
        'tree-extracted' {
            $want, $have = (ConvertTo-FileMap (Get-Field $Expected 'files')), (ConvertTo-FileMap (Get-Field $Actual 'files'))
            if ($null -eq $want -or $null -eq $have -or $want.Count -ne $have.Count) { return $false }
            foreach ($path in $want.Keys) {
                if (-not $have.ContainsKey($path) -or $have[$path] -ne $want[$path]) { return $false }
            }
            return $true
        }
        default {
            $sha = [string](Get-Field $Expected 'sha256')
            return ($sha -ne '' -and $sha -eq [string](Get-Field $Actual 'sha256'))
        }
    }
}

# The first problem with one ledger record, or $null when it is well formed.
function Get-EffectRecordProblem($Record) {
    if ((Get-Field $Record 'ledger') -cne 'effects') { return "ledger is not 'effects'." }
    $schema = Get-Field $Record 'schema'
    if (($schema -isnot [int] -and $schema -isnot [long]) -or $schema -ne 1) { return 'schema is not 1.' }
    $seq = Get-Field $Record 'seq'
    if (($seq -isnot [int] -and $seq -isnot [long]) -or $seq -lt 1) { return 'seq is not a positive integer.' }
    $phase = Get-Field $Record 'phase'
    if ($phase -cnotin @('intent', 'commit', 'void', 'undone')) { return 'phase is not intent, commit, void or undone.' }
    $kind = Get-Field $Record 'kind'
    if ($kind -cnotin @('file-created', 'file-replaced', 'prefix-inserted', 'registry-value', 'tree-extracted')) {
        return 'kind is not an effect kind.'
    }
    $id = Get-Field $Record 'id'
    if ($id -isnot [string] -or $id -eq '') { return 'id is empty.' }
    $target = Get-Field $Record 'target'
    if (-not (Test-EffectPath $kind $target)) { return 'target is not an absolute path or HKCU key.' }
    $name = Get-Field $Record 'name'
    if ($kind -eq 'registry-value' -and $name -isnot [string]) { return 'name is missing.' }
    if ($kind -ne 'registry-value' -and $null -ne $name) { return 'name belongs to registry-value only.' }
    $prior, $desired = (Get-Field $Record 'prior'), (Get-Field $Record 'desired')
    foreach ($problem in @((Get-EffectStateProblem $kind $prior 'prior'), (Get-EffectStateProblem $kind $desired 'desired'))) {
        if ($problem) { return $problem }
    }
    if (-not (Get-Field $desired 'exists')) { return 'desired must exist.' }
    if (Test-EffectStateEqual $kind $prior $desired) { return 'desired equals prior; there is no effect to own.' }
    if ($kind -in @('file-created', 'tree-extracted') -and (Get-Field $prior 'exists')) { return 'prior must be absent.' }
    if ($kind -in @('file-replaced', 'prefix-inserted')) {
        $backup = Get-Field $prior 'backup'
        if (-not (Get-Field $prior 'exists')) { return 'prior must exist.' }
        if (-not (Test-EffectPath 'file' $backup) -or $backup -eq $target) { return 'prior.backup is not a separate absolute path.' }
    }
    if ($kind -eq 'prefix-inserted') {
        $line = Get-Field $desired 'line'
        if ($line -isnot [string] -or $line -eq '' -or $line -match '[\r\n]') { return 'desired.line is not one line.' }
    }
    if ($kind -eq 'tree-extracted' -and (ConvertTo-FileMap (Get-Field $desired 'files')).Count -eq 0) {
        return 'desired.files is empty.'
    }
    $observed = Get-Field $Record 'observed'
    if ($phase -ceq 'intent') {
        if ($null -ne $observed) { return 'an intent has no observed state.' }
        return $null
    }
    $problem = Get-EffectStateProblem $kind $observed 'observed'
    if ($problem) { return $problem }
    $expected, $label = if ($phase -ceq 'commit') { $desired, 'desired' } else { $prior, 'prior' }
    if (-not (Test-EffectStateEqual $kind $expected $observed)) { return "observed differs from $label." }
    return $null
}

# True when two well-formed records describe the same effect.
function Test-SameEffect($First, $Other) {
    $kind = [string](Get-Field $First 'kind')
    $fp, $op = (Get-Field $First 'prior'), (Get-Field $Other 'prior')
    $fd, $od = (Get-Field $First 'desired'), (Get-Field $Other 'desired')
    return ([string](Get-Field $First 'id') -ceq [string](Get-Field $Other 'id') -and
        $kind -ceq [string](Get-Field $Other 'kind') -and
        [string](Get-Field $First 'target') -eq [string](Get-Field $Other 'target') -and
        [string](Get-Field $First 'name') -ceq [string](Get-Field $Other 'name') -and
        (Test-EffectStateEqual $kind $fp $op) -and (Test-EffectStateEqual $kind $fd $od) -and
        [string](Get-Field $fp 'backup') -eq [string](Get-Field $op 'backup') -and
        [string](Get-Field $fd 'line') -ceq [string](Get-Field $od 'line'))
}

function New-EffectClass([string]$Class, $Resolution, [string]$Reason) {
    [ordered]@{ class = $Class; resolution = $Resolution; reason = $Reason }
}

# The latest attempt of one id: its records ordered by seq, whether a void or
# undone closed it, and the first problem found (then records is empty).
# Every record must be well formed; each attempt starts with an intent, its
# records describe one effect, a void may not follow a commit, and nothing but a
# new intent may follow a close.
function Get-EffectAttempt($Records) {
    $attempt, $closed, $last = @(), $false, 0
    $order = { $seq = Get-Field $_ 'seq'; if ($seq -is [int] -or $seq -is [long]) { [long]$seq } else { [long]0 } }
    foreach ($record in @($Records | Where-Object { $null -ne $_ } | Sort-Object $order)) {
        $problem = Get-EffectRecordProblem $record
        if (-not $problem -and (Get-Field $record 'seq') -eq $last) { $problem = 'seq repeats.' }
        if ($problem) { return [ordered]@{ problem = "Malformed record: $problem"; records = @(); closed = $false } }
        $last = Get-Field $record 'seq'
        $phase = Get-Field $record 'phase'
        if ($attempt.Count -eq 0 -or $closed) {
            if ($phase -cne 'intent') {
                return [ordered]@{ problem = "A $phase record does not follow an open intent."; records = @(); closed = $false }
            }
            $attempt = @($record)
            $closed = $false
            continue
        }
        if (-not (Test-SameEffect $attempt[0] $record)) {
            return [ordered]@{ problem = 'Records of one attempt describe different effects.'; records = @(); closed = $false }
        }
        if ($phase -ceq 'void' -and @($attempt | Where-Object { (Get-Field $_ 'phase') -ceq 'commit' }).Count -gt 0) {
            return [ordered]@{ problem = 'A committed attempt cannot be voided.'; records = @(); closed = $false }
        }
        $attempt += $record
        $closed = $phase -cin @('void', 'undone')
    }
    [ordered]@{ problem = $null; records = $attempt; closed = $closed }
}

# Class of one effect target: absent, owned-match, owned-drift, preexisting-match,
# preexisting-drift or indeterminate, plus a resolution for an interrupted intent.
#   $Records  this id's ledger records, any order (empty when unrecorded)
#   $Current  the observed state now, in the kind's state shape
#   $Kind, $Desired  the selection. They decide when nothing is open for the id;
#     when omitted after a closed attempt, that attempt's kind and desired stand in.
#     With an open attempt the recorded effect decides, and a given $Kind must match.
# With nothing open nothing is owned: absent when $Current does not exist, else
# preexisting-match or preexisting-drift against $Desired. An open attempt with a
# commit is owned: owned-match or owned-drift against the recorded desired. An
# open attempt of intents only (interrupted) is owned-match with resolution
# 'confirm' when $Current equals desired; with resolution 'void' and classed as
# unowned when it equals prior; otherwise indeterminate. Malformed or inconsistent
# records and a malformed $Current are indeterminate.
function Get-EffectClass($Records, $Current, [string]$Kind, $Desired) {
    $attempt = Get-EffectAttempt $Records
    if ($attempt.problem) { return New-EffectClass 'indeterminate' $null $attempt.problem }
    $records = @($attempt.records)
    if ($records.Count -eq 0 -or $attempt.closed) {
        if (-not $Kind -and $records.Count) {
            $Kind, $Desired = [string](Get-Field $records[0] 'kind'), (Get-Field $records[0] 'desired')
        }
        $problem = if ($Kind -cnotin @('file-created', 'file-replaced', 'prefix-inserted', 'registry-value', 'tree-extracted')) {
            'The selection kind is not an effect kind.'
        } else { Get-EffectStateProblem $Kind $Desired 'desired' }
        if (-not $problem) { $problem = Get-EffectStateProblem $Kind $Current 'current' }
        if ($problem) { return New-EffectClass 'indeterminate' $null $problem }
        if (-not (Get-Field $Current 'exists')) { return New-EffectClass 'absent' $null $null }
        if (Test-EffectStateEqual $Kind $Desired $Current) { return New-EffectClass 'preexisting-match' $null $null }
        return New-EffectClass 'preexisting-drift' $null $null
    }
    $recorded = [string](Get-Field $records[0] 'kind')
    if ($Kind -and $Kind -cne $recorded) { return New-EffectClass 'indeterminate' $null "Recorded kind $recorded is not $Kind." }
    $problem = Get-EffectStateProblem $recorded $Current 'current'
    if ($problem) { return New-EffectClass 'indeterminate' $null $problem }
    $prior, $desired = (Get-Field $records[0] 'prior'), (Get-Field $records[0] 'desired')
    $written = Test-EffectStateEqual $recorded $desired $Current
    if (@($records | Where-Object { (Get-Field $_ 'phase') -ceq 'commit' }).Count -gt 0) {
        if ($written) { return New-EffectClass 'owned-match' $null $null }
        return New-EffectClass 'owned-drift' $null 'The owned target differs from what was written.'
    }
    if ($written) { return New-EffectClass 'owned-match' 'confirm' $null }
    if (Test-EffectStateEqual $recorded $prior $Current) {
        if (-not (Get-Field $Current 'exists')) { return New-EffectClass 'absent' 'void' $null }
        return New-EffectClass 'preexisting-drift' 'void' $null
    }
    return New-EffectClass 'indeterminate' $null 'An interrupted intent left the target in neither the prior nor the desired state.'
}

# Registry data of a state; MultiString and Binary stay arrays even with one element.
function Get-RegistryData($State) {
    $data = Get-Field $State 'data'
    if ((Get-Field $State 'type') -cin @('MultiString', 'Binary')) { return ,@($data) }
    return $data
}

# The undo steps of one owned effect. Each step names the state the executor
# must read back immediately before acting (expect*), and no step is recursive.
function Get-UndoSteps($Record) {
    $kind, $target = [string](Get-Field $Record 'kind'), [string](Get-Field $Record 'target')
    $prior, $desired = (Get-Field $Record 'prior'), (Get-Field $Record 'desired')
    switch ($kind) {
        'file-created' {
            [ordered]@{ action = 'delete-file'; path = $target; expectSha256 = (Get-Field $desired 'sha256') }
        }
        { $_ -in @('file-replaced', 'prefix-inserted') } {
            [ordered]@{ action = 'restore-file'; path = $target; expectSha256 = (Get-Field $desired 'sha256')
                backup = (Get-Field $prior 'backup'); backupSha256 = (Get-Field $prior 'sha256') }
        }
        'registry-value' {
            $step = [ordered]@{ action = 'delete-registry-value'; key = $target; name = [string](Get-Field $Record 'name')
                expectType = (Get-Field $desired 'type'); expectData = (Get-RegistryData $desired) }
            if (Get-Field $prior 'exists') {
                $step.action = 'set-registry-value'
                $step.type = Get-Field $prior 'type'
                $step.data = Get-RegistryData $prior
            }
            $step
        }
        'tree-extracted' {
            $files = ConvertTo-FileMap (Get-Field $desired 'files')
            $paths = [string[]]@($files.Keys)
            [Array]::Sort($paths, [StringComparer]::OrdinalIgnoreCase)
            $directories = @{}
            foreach ($relative in $paths) {
                [ordered]@{ action = 'delete-file'; path = $target + '\' + $relative.Replace('/', '\'); expectSha256 = $files[$relative] }
                $parts = $relative.Split('/')
                for ($i = 1; $i -lt $parts.Count; $i++) { $directories[$parts[0..($i - 1)] -join '\'] = $true }
            }
            # Descending order puts every directory before its parent.
            $names = [string[]]@($directories.Keys)
            [Array]::Sort($names, [StringComparer]::OrdinalIgnoreCase)
            [Array]::Reverse($names)
            foreach ($directory in $names) {
                [ordered]@{ action = 'remove-empty-directory'; path = $target + '\' + $directory }
            }
            [ordered]@{ action = 'remove-empty-directory'; path = $target }
        }
    }
}

# True when two records' targets cannot have separate owners: the same registry
# value (key and name, ignoring case), or file-system targets where one equals or
# contains the other per '\' segment, ignoring case (a file inside an extracted
# tree, or a nested tree). Registry and file-system targets never overlap.
function Test-TargetOverlap($First, $Other) {
    $firstKind, $otherKind = [string](Get-Field $First 'kind'), [string](Get-Field $Other 'kind')
    $a = ([string](Get-Field $First 'target')).ToUpperInvariant()
    $b = ([string](Get-Field $Other 'target')).ToUpperInvariant()
    if (($firstKind -ceq 'registry-value') -ne ($otherKind -ceq 'registry-value')) { return $false }
    if ($firstKind -ceq 'registry-value') {
        return ($a -ceq $b -and ([string](Get-Field $First 'name')).ToUpperInvariant() -ceq
            ([string](Get-Field $Other 'name')).ToUpperInvariant())
    }
    return ($a -ceq $b -or $a.StartsWith($b + '\', [StringComparison]::Ordinal) -or
        $b.StartsWith($a + '\', [StringComparison]::Ordinal))
}

# The uninstall plan for all ledger records ($Records, any order) and
# $Observations, a map id -> current state; a missing observation is indeterminate.
# Ids are visited by the seq of their open attempt's intent, latest first. Only
# owned-match produces steps, each tagged with its id so the executor writes that
# id's `undone` after its steps; owned-drift and indeterminate are refused;
# unowned targets (absent, preexisting-*, closed or voided attempts) are kept
# untouched and listed. Also refused: a repeated seq or ids differing only in case
# (the whole plan); open attempts whose targets overlap (Test-TargetOverlap); an
# open registry-value on HKCU\Console\%%Startup, which the older default-terminal
# record owns (Get-LegacyTerminalPlan); and a file-replaced or prefix-inserted
# effect without exactly one owned-match file-created backup of its own, with an
# earlier intent, whose target is prior.backup and whose desired sha256 is
# prior.sha256. ok is false when anything is refused, and then steps is empty.
# resolutions lists interrupted intents to close as 'confirm' or 'void'.
function Get-UninstallPlan($Records, $Observations) {
    $steps, $refused, $kept, $resolutions = @(), @(), @(), @()
    $all = @($Records | Where-Object { $null -ne $_ })
    $seqs = @($all | ForEach-Object { [string](Get-Field $_ 'seq') })
    if (@($seqs | Sort-Object -Unique).Count -ne $seqs.Count) {
        $refused += [ordered]@{ id = $null; class = 'indeterminate'; reason = 'Two ledger records share a seq.' }
        return [ordered]@{ ok = $false; steps = $steps; refused = $refused; kept = $kept; resolutions = $resolutions }
    }
    $ids = @($all | ForEach-Object { [string](Get-Field $_ 'id') } | Sort-Object -Unique -CaseSensitive)
    if (@($ids | Sort-Object -Unique).Count -ne $ids.Count) {
        # $Observations may be a case-insensitive map, so such ids could read each other's state.
        $refused += [ordered]@{ id = $null; class = 'indeterminate'; reason = 'Two ids differ only in case.' }
        return [ordered]@{ ok = $false; steps = $steps; refused = $refused; kept = $kept; resolutions = $resolutions }
    }
    $entries = @()
    foreach ($id in $ids) {
        $records = @($all | Where-Object { [string](Get-Field $_ 'id') -ceq $id })
        $attempt = Get-EffectAttempt $records
        $open = @(if (-not $attempt.closed) { $attempt.records })
        $entries += [pscustomobject]@{ id = $id; class = (Get-EffectClass $records (Get-Field $Observations $id))
            record = $(if ($open.Count) { $open[0] } else { $null })
            start = $(if ($open.Count) { [long](Get-Field $open[0] 'seq') } else { 0 }); refusal = $null }
    }
    $live = @($entries | Where-Object { $null -ne $_.record })
    foreach ($entry in $live) {
        $record = $entry.record
        if (@($live | Where-Object { Test-TargetOverlap $record $_.record }).Count -gt 1) {
            $entry.refusal = 'Another open attempt owns the same, an enclosing or an enclosed target.'
        }
        if ((Get-Field $record 'kind') -ceq 'registry-value' -and [string](Get-Field $record 'target') -eq 'HKCU\Console\%%Startup') {
            $entry.refusal = 'HKCU\Console\%%Startup belongs to the default-terminal record, not the effect ledger.'
        }
    }
    $binders = @{}
    foreach ($entry in $live) {
        if ($entry.class.class -cne 'owned-match' -or
            (Get-Field $entry.record 'kind') -cnotin @('file-replaced', 'prefix-inserted')) { continue }
        $prior = Get-Field $entry.record 'prior'
        $backups = @($live | Where-Object {
            (Get-Field $_.record 'kind') -ceq 'file-created' -and $_.class.class -ceq 'owned-match' -and
            $_.start -lt $entry.start -and [string](Get-Field $_.record 'target') -eq [string](Get-Field $prior 'backup') -and
            [string](Get-Field (Get-Field $_.record 'desired') 'sha256') -eq [string](Get-Field $prior 'sha256') })
        if ($backups.Count -ne 1) { $entry.refusal = 'No single earlier owned backup holds the prior bytes.'; continue }
        if (-not $binders.ContainsKey($backups[0].id)) { $binders[$backups[0].id] = @() }
        $binders[$backups[0].id] += $entry
    }
    foreach ($backup in @($binders.Keys)) {
        if ($binders[$backup].Count -gt 1) {
            foreach ($entry in $binders[$backup]) { $entry.refusal = 'Its backup also serves another effect.' }
        }
    }
    foreach ($entry in @($entries | Sort-Object @{ Expression = 'start'; Descending = $true }, id -CaseSensitive)) {
        $class = $entry.class
        if ($class.resolution) { $resolutions += [ordered]@{ id = $entry.id; resolution = $class.resolution } }
        if ($entry.refusal) {
            $refused += [ordered]@{ id = $entry.id; class = 'indeterminate'; reason = $entry.refusal }
        } elseif ($class.class -ceq 'owned-match') {
            foreach ($step in @(Get-UndoSteps $entry.record)) { $step['id'] = $entry.id; $steps += $step }
        } elseif ($class.class -cin @('owned-drift', 'indeterminate')) {
            $refused += [ordered]@{ id = $entry.id; class = $class.class; reason = $class.reason }
        } else { $kept += [ordered]@{ id = $entry.id; class = $class.class } }
    }
    if ($refused.Count) { $steps = @() }
    [ordered]@{ ok = ($refused.Count -eq 0); steps = $steps; refused = $refused; kept = $kept; resolutions = $resolutions }
}

# Rollback plan from the older default-terminal record win.ps1 writes once to
# provenance\default-terminal.json: its own schema 1 with key, priorDelegationConsole,
# priorDelegationTerminal (each $null when the value was absent), priorSelectsNoctty
# and written, and no `ledger` field. $Current is the pair read now as
# { console; terminal }, $null for an absent value. A record is well formed only
# as win.ps1 writes it: written is exactly the Windows Terminal console and Noctty
# terminal, and priorSelectsNoctty is true exactly when the prior terminal is Noctty.
# action is 'report' when the original selection is unknown (priorSelectsNoctty);
# 'none' when the current pair already equals the prior pair ($null matching
# $null), so a repeated rollback succeeds without an effect; 'restore' (set the
# prior pair, deleting a $null value) when the current pair still equals written;
# otherwise 'refuse'.
function Get-LegacyTerminalPlan($Record, $Current) {
    $windowsTerminalConsole = '{2EACA947-7F5F-4CFA-BA87-8F7FBEEFBE69}'
    $nocttyTerminal = '{33368C6F-D328-410C-B225-26DC9F12C728}'
    $key = 'HKCU\Console\%%Startup'
    $written = Get-Field $Record 'written'
    $wc, $wt = (Get-Field $written 'DelegationConsole'), (Get-Field $written 'DelegationTerminal')
    $pc, $pt = (Get-Field $Record 'priorDelegationConsole'), (Get-Field $Record 'priorDelegationTerminal')
    $schema = Get-Field $Record 'schema'
    $selects = Get-Field $Record 'priorSelectsNoctty'
    if (($schema -isnot [int] -and $schema -isnot [long]) -or $schema -ne 1 -or (Get-Field $Record 'key') -cne $key -or
        $null -ne (Get-Field $Record 'ledger') -or $selects -isnot [bool] -or
        $wc -isnot [string] -or $wc -ne $windowsTerminalConsole -or $wt -isnot [string] -or $wt -ne $nocttyTerminal -or
        ($null -ne $pc -and $pc -isnot [string]) -or ($null -ne $pt -and $pt -isnot [string]) -or
        $selects -ne ($pt -eq $nocttyTerminal)) {
        return [ordered]@{ action = 'refuse'; reason = 'Malformed default-terminal record.' }
    }
    if ($selects) {
        return [ordered]@{ action = 'report'; reason = 'Noctty was already selected when recorded; the original selection is unknown.' }
    }
    $cc, $ct = (Get-Field $Current 'console'), (Get-Field $Current 'terminal')
    if (($null -ne $cc -and $cc -isnot [string]) -or ($null -ne $ct -and $ct -isnot [string])) {
        return [ordered]@{ action = 'refuse'; reason = 'The current selection is not readable as two values.' }
    }
    if ($cc -eq $pc -and $ct -eq $pt) {
        return [ordered]@{ action = 'none'; reason = 'Already restored: the current selection equals the recorded prior one.' }
    }
    if ($cc -isnot [string] -or $ct -isnot [string] -or $cc -ne $wc -or $ct -ne $wt) {
        return [ordered]@{ action = 'refuse'; reason = 'The current selection is not the one Restore wrote.' }
    }
    [ordered]@{ action = 'restore'; key = $key; expectConsole = $wc; expectTerminal = $wt
        console = $pc; terminal = $pt; reason = $null }
}
