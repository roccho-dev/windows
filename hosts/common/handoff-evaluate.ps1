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

# Several properties at once, read as Get-Field reads each ($null when absent; a dictionary by its own
# key comparison, anything else by its PowerShell properties), in one call: a hashtable name -> value.
# Unlike Get-Field's return, a value is kept exactly as stored: an array stays an array, even with one
# element or none. Validation reads records through this; one function call per field dominated its cost.
function Get-Fields($Object, [string[]]$Names) {
    $values = @{}
    foreach ($name in $Names) { $values[$name] = $null }
    if ($null -eq $Object) { return $values }
    if ($Object -is [Collections.IDictionary]) {
        foreach ($name in $Names) { $values[$name] = $Object[$name] }
        return $values
    }
    $properties = $Object.PSObject.Properties
    foreach ($name in $Names) {
        $property = $properties[$name]
        if ($null -ne $property) { $values[$name] = $property.Value }
    }
    return $values
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
#   kind      file-created | file-replaced | prefix-inserted | registry-value |
#             registry-key-created | tree-extracted
#   target    absolute file or directory path (drive, backslashes, no . or ..),
#             or an HKCU\ key for the registry kinds; never HKLM
#   name      registry-value only: the value name ('' is the default value)
#   prior     the state before the effect
#   desired   the state the effect writes; never equal to prior, so an already
#             matching target is preexisting-match and gets no intent
#   observed  absent on an intent; the readback, equal to desired on a commit
#             and to prior on a void or undone
#   temp      intent only, optional: the temporary path it names before creating
#             it (Get-IntentTempProblem)
# A state is { exists = [bool] } plus, when exists is true:
#   file kinds      sha256; prior of file-replaced and prefix-inserted also has
#                   backup, an absolute path holding the prior bytes; desired of
#                   prefix-inserted also has line, the single inserted line
#   registry-value  type (String, ExpandString, MultiString, DWord, QWord, Binary), data.
#                   DWord and QWord data are the unsigned value on both sides:
#                   observers convert the signed Int32/Int64 PowerShell reads
#                   (e.g. -1 is 4294967295); a differing representation is drift.
#   tree-extracted  files, a map of '/'-separated relative path -> sha256; an observed
#                   tree may add other, the entries that are not such a file (reparse
#                   points, directories without a file, unsafe names), empty in desired
#   registry-key-created  nothing more: the key exists
# Per kind, prior and desired must be:
#   file-created, tree-extracted,
#   registry-key-created             prior absent, desired present
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

# True when $Target is a tree of locked package $Package: its leaf is <package, lowercase>-<version>
# (a digit first, no '-', so chromium-extra-1 is not Chromium's), and, when $Programs is passed,
# it lies directly in $Programs (an empty or $null $Programs is false). It calls nothing that
# validates records, so Get-EffectRecordProblem and Get-PackageAssetPath can both use it.
function Test-PackageTarget([string]$Target, $Package, [string]$Programs) {
    $Package -is [string] -and $Package -cmatch '^[A-Za-z0-9][A-Za-z0-9.-]*\z' -and
        [IO.Path]::GetFileName($Target) -cmatch ('^' + [regex]::Escape($Package.ToLowerInvariant()) + '-[0-9][A-Za-z0-9.]*\z') -and
        (-not $PSBoundParameters.ContainsKey('Programs') -or ($Programs -and [IO.Path]::GetDirectoryName($Target) -eq $Programs.TrimEnd('\')))
}

# True for an absolute file path, or an HKCU key when $Kind is a registry kind.
function Test-EffectPath([string]$Kind, $Target) {
    $registry = $Kind -cin @('registry-value', 'registry-key-created')
    $root = if ($registry) { '^HKCU\\' } else { '^[A-Za-z]:\\' }
    if ($Target -isnot [string] -or $Target -notmatch $root) { return $false }
    foreach ($segment in ($Target -replace $root, '').Split('\')) {
        if ($registry) { if ($segment -in @('', '.', '..')) { return $false } }
        elseif (-not (Test-PathSegment $segment)) { return $false }
    }
    return $true
}

# One relative path of '/'-separated segments, each exactly as Test-PathSegment allows (that
# function is the specification; proof.ps1 checks they agree), as one regex, so a whole
# inventory is checked without a function call per name or segment.
function Get-RelativePathRegex {
    $segment = '(?!(?:CON|PRN|AUX|NUL|COM\d|LPT\d)(?:\.[^/]*)?(?:/|\z))[^\\/:*?"<>|\x00-\x1f]*[^\\/:*?"<>|\x00-\x1f. ]'
    [regex]::new("^$segment(?:/$segment)*\z", [Text.RegularExpressions.RegexOptions]'IgnoreCase, CultureInvariant')
}

function Test-RelativePath([string]$Name) { (Get-RelativePathRegex).IsMatch($Name) }

# A '/'-path -> sha256 map as a case-insensitive hashtable, or $null when it is
# not a map, a path is not a safe relative path, a hash is malformed, or two
# paths differ only in case. One pass over the name/value pairs (a dictionary key
# named Keys is an ordinary name), with the path regex built once per map.
function ConvertTo-FileMap($Files) {
    if ($Files -is [Collections.IDictionary]) { $pairs = @(foreach ($entry in $Files.GetEnumerator()) { , @($entry.Key, $entry.Value) }) }
    elseif ($Files -is [Management.Automation.PSCustomObject]) { $pairs = @(foreach ($property in $Files.PSObject.Properties) { , @($property.Name, $property.Value) }) }
    else { return $null }
    $path, $map = (Get-RelativePathRegex), @{}
    foreach ($pair in $pairs) {
        $name, $sha = $pair[0], $pair[1]
        if ($name -isnot [string] -or $sha -isnot [string] -or $sha -notmatch '^[0-9A-Fa-f]{64}\z' -or
            $map.ContainsKey($name) -or -not $path.IsMatch($name)) { return $null }
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
            if (@(Get-Field $State 'other' | Where-Object { $null -ne $_ -and $_ -isnot [string] }).Count) { return "$Role.other is not a list of paths." }
        }
        'registry-key-created' { }
        default {
            $sha = Get-Field $State 'sha256'
            if ($sha -isnot [string] -or $sha -notmatch '^[0-9A-Fa-f]{64}\z') { return "$Role.sha256 is not a SHA-256." }
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
            $want, $have = (Get-Fields $Expected @('type', 'data')), (Get-Fields $Actual @('type', 'data'))
            return ([string]$want.type -ceq [string]$have.type -and
                (ConvertTo-Json -Compress -InputObject @($want.data)) -ceq (ConvertTo-Json -Compress -InputObject @($have.data)))
        }
        'tree-extracted' {
            $want, $have = (ConvertTo-FileMap (Get-Field $Expected 'files')), (ConvertTo-FileMap (Get-Field $Actual 'files'))
            if ($null -eq $want -or $null -eq $have -or $want.Count -ne $have.Count) { return $false }
            foreach ($path in $want.Keys) {
                if (-not $have.ContainsKey($path) -or $have[$path] -ne $want[$path]) { return $false }
            }
            return (@(Get-Field $Expected 'other' | Where-Object { $null -ne $_ } | Sort-Object) -join '|') -eq
                (@(Get-Field $Actual 'other' | Where-Object { $null -ne $_ } | Sort-Object) -join '|')
        }
        'registry-key-created' { return $true }
        default {
            $sha = [string](Get-Field $Expected 'sha256')
            return ($sha -ne '' -and $sha -eq [string](Get-Field $Actual 'sha256'))
        }
    }
}

# The first problem with one ledger record, or $null when it is well formed.
function Get-EffectRecordProblem($Record) {
    $fields = Get-Fields $Record @('ledger', 'schema', 'seq', 'phase', 'kind', 'id', 'target', 'name', 'package', 'prior', 'desired', 'observed', 'temp')
    if ($fields.ledger -isnot [string] -or $fields.ledger -cne 'effects') { return "ledger is not 'effects'." }
    $schema = $fields.schema
    if (($schema -isnot [int] -and $schema -isnot [long]) -or $schema -ne 1) { return 'schema is not 1.' }
    $seq = $fields.seq
    if (($seq -isnot [int] -and $seq -isnot [long]) -or $seq -lt 1) { return 'seq is not a positive integer.' }
    $phase = $fields.phase
    if ($phase -isnot [string] -or $phase -cnotin @('intent', 'commit', 'void', 'undone')) { return 'phase is not intent, commit, void or undone.' }
    $kind = $fields.kind
    if ($kind -isnot [string] -or $kind -cnotin @('file-created', 'file-replaced', 'prefix-inserted', 'registry-value', 'registry-key-created', 'tree-extracted')) {
        return 'kind is not an effect kind.'
    }
    $id = $fields.id
    if ($id -isnot [string] -or $id -eq '') { return 'id is empty.' }
    $target = $fields.target
    if (-not (Test-EffectPath $kind $target)) { return 'target is not an absolute path or HKCU key.' }
    $name = $fields.name
    if ($kind -eq 'registry-value' -and $name -isnot [string]) { return 'name is missing.' }
    if ($kind -ne 'registry-value' -and $null -ne $name) { return 'name belongs to registry-value only.' }
    # R1 reads package from intents; only a tree intent of that package's own tree may carry it.
    $package = $fields.package
    if ($null -ne $package -and ($phase -cne 'intent' -or $kind -cne 'tree-extracted' -or -not (Test-PackageTarget $target $package))) {
        return 'package names no tree of that package.'
    }
    $prior, $desired = $fields.prior, $fields.desired
    foreach ($problem in @((Get-EffectStateProblem $kind $prior 'prior'), (Get-EffectStateProblem $kind $desired 'desired'))) {
        if ($problem) { return $problem }
    }
    if (-not (Get-Field $desired 'exists')) { return 'desired must exist.' }
    if (Test-EffectStateEqual $kind $prior $desired) { return 'desired equals prior; there is no effect to own.' }
    if ($kind -in @('file-created', 'tree-extracted', 'registry-key-created') -and (Get-Field $prior 'exists')) { return 'prior must be absent.' }
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
    if ($kind -eq 'tree-extracted' -and @(Get-Field $desired 'other' | Where-Object { $null -ne $_ }).Count) { return 'desired.other is not empty.' }
    $observed = $fields.observed
    if ($phase -ceq 'intent') {
        if ($null -ne $observed) { return 'an intent has no observed state.' }
        return Get-IntentTempProblem $Record
    }
    if ($null -ne $fields.temp) { return 'only an intent names a temporary path.' }
    $problem = Get-EffectStateProblem $kind $observed 'observed'
    if ($problem) { return $problem }
    $expected, $label = if ($phase -ceq 'commit') { $desired, 'desired' } else { $prior, 'prior' }
    if (-not (Test-EffectStateEqual $kind $expected $observed)) { return "observed differs from $label." }
    return $null
}

# True when two well-formed records describe the same effect.
function Test-SameEffect($First, $Other) {
    $names = @('id', 'kind', 'target', 'name', 'prior', 'desired')
    $one, $two = (Get-Fields $First $names), (Get-Fields $Other $names)
    $kind = [string]$one.kind
    $fp, $op, $fd, $od = $one.prior, $two.prior, $one.desired, $two.desired
    return ([string]$one.id -ceq [string]$two.id -and $kind -ceq [string]$two.kind -and
        [string]$one.target -eq [string]$two.target -and [string]$one.name -ceq [string]$two.name -and
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

# Class of a target nothing owns: absent when $Current does not exist, else
# preexisting-match or preexisting-drift against $Desired; indeterminate when the
# kind or a state is malformed. $Resolution is passed through.
function Get-UnownedClass([string]$Kind, $Desired, $Current, $Resolution) {
    $problem = if ($Kind -cnotin @('file-created', 'file-replaced', 'prefix-inserted', 'registry-value', 'registry-key-created', 'tree-extracted')) {
        'The selection kind is not an effect kind.'
    } else { Get-EffectStateProblem $Kind $Desired 'desired' }
    if (-not $problem) { $problem = Get-EffectStateProblem $Kind $Current 'current' }
    if ($problem) { return New-EffectClass 'indeterminate' $null $problem }
    if (-not (Get-Field $Current 'exists')) { return New-EffectClass 'absent' $Resolution $null }
    if (Test-EffectStateEqual $Kind $Desired $Current) { return New-EffectClass 'preexisting-match' $Resolution $null }
    return New-EffectClass 'preexisting-drift' $Resolution $null
}

# Class of one effect target: absent, owned-match, owned-drift, preexisting-match,
# preexisting-drift or indeterminate, plus a resolution that closes an open attempt.
#   $Records  this id's ledger records, any order (empty when unrecorded)
#   $Current  the observed state now, in the kind's state shape
#   $Kind, $Desired  the selection. Wherever the target is unowned they decide,
#     and when omitted the latest attempt's kind and desired stand in. With an
#     open attempt the recorded effect decides ownership, and a given $Kind must match.
# With nothing open, nothing is owned (Get-UnownedClass). An open attempt whose
# $Current equals desired is owned-match, with resolution 'confirm' when it has
# no commit (an interrupted intent that took effect). One whose $Current equals
# prior is unowned, classed exactly as if closed, with resolution 'undone' when
# it has a commit (the effect was reverted) or 'void' when not (it never took
# effect); so the class is the same before and after that closing record is
# written. Otherwise a committed attempt is owned-drift and an uncommitted one
# indeterminate. Malformed or inconsistent records and a malformed $Current are
# indeterminate.
function Get-EffectClass($Records, $Current, [string]$Kind, $Desired, $Attempt) {
    # $Attempt: Get-EffectAttempt of these records when the caller already holds it (win.ps1's per-run
    # cache); then $Records is not read. (It is the same variable as $attempt below: names ignore case.)
    if ($null -eq $Attempt) { $Attempt = Get-EffectAttempt $Records }
    if ($attempt.problem) { return New-EffectClass 'indeterminate' $null $attempt.problem }
    $records = @($attempt.records)
    if ($records.Count -and -not $Kind) {
        $Kind, $Desired = [string](Get-Field $records[0] 'kind'), (Get-Field $records[0] 'desired')
    }
    if ($records.Count -eq 0 -or $attempt.closed) { return Get-UnownedClass $Kind $Desired $Current $null }
    $recorded = [string](Get-Field $records[0] 'kind')
    if ($Kind -cne $recorded) { return New-EffectClass 'indeterminate' $null "Recorded kind $recorded is not $Kind." }
    $problem = Get-EffectStateProblem $recorded $Current 'current'
    if ($problem) { return New-EffectClass 'indeterminate' $null $problem }
    # Not $desired: PowerShell variable names ignore case, so it would overwrite $Desired.
    $recordedPrior, $recordedDesired = (Get-Field $records[0] 'prior'), (Get-Field $records[0] 'desired')
    $committed = @($records | Where-Object { (Get-Field $_ 'phase') -ceq 'commit' }).Count -gt 0
    if (Test-EffectStateEqual $recorded $recordedDesired $Current) {
        return New-EffectClass 'owned-match' $(if ($committed) { $null } else { 'confirm' }) $null
    }
    if (Test-EffectStateEqual $recorded $recordedPrior $Current) {
        return Get-UnownedClass $Kind $Desired $Current $(if ($committed) { 'undone' } else { 'void' })
    }
    if ($committed) { return New-EffectClass 'owned-drift' $null 'The owned target differs from what was written.' }
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
        # Removed only while it holds no value and no subkey; never recursively.
        'registry-key-created' { [ordered]@{ action = 'delete-empty-key'; key = $target } }
        'tree-extracted' { $tree = Get-TreeUndoSteps $Record $null; $tree }
    }
}

# The undo steps of an owned tree: each file still present, with the sha256 to read back
# first, then each inventory directory still present, deepest first, then the root; every
# removal non-recursive. $Current $null means the whole inventory. A partly removed tree
# ($Current, as observed) resumes only while each file is an inventory file with its recorded
# sha256 and each other entry an inventory directory left empty ('<dir>/'); otherwise $null.
function Get-TreeUndoSteps($Record, $Current) {
    $target = [string](Get-Field $Record 'target')
    $files = ConvertTo-FileMap (Get-Field (Get-Field $Record 'desired') 'files')
    $present = if ($null -eq $Current) { $files } else { ConvertTo-FileMap (Get-Field $Current 'files') }
    if ($null -eq $files -or $null -eq $present -or ($null -ne $Current -and (Get-Field $Current 'exists') -ne $true)) { return $null }
    $implied, $directories = @{}, @{}
    foreach ($relative in $files.Keys) {
        $parts = $relative.Split('/')
        for ($i = 1; $i -lt $parts.Count; $i++) { $implied[$parts[0..($i - 1)] -join '\'] = $true }
    }
    foreach ($relative in $present.Keys) {
        if (-not $files.ContainsKey($relative) -or $present[$relative] -ne $files[$relative]) { return $null }
        $parts = $relative.Split('/')
        for ($i = 1; $i -lt $parts.Count; $i++) { $directories[$parts[0..($i - 1)] -join '\'] = $true }
    }
    foreach ($entry in @(Get-Field $Current 'other' | Where-Object { $null -ne $_ })) {
        $directory = ([string]$entry).TrimEnd('/').Replace('/', '\')
        if (-not ([string]$entry).EndsWith('/') -or -not $implied.ContainsKey($directory)) { return $null }
        $directories[$directory] = $true
    }
    $paths, $names = [string[]]@($present.Keys), [string[]]@($directories.Keys)
    [Array]::Sort($paths, [StringComparer]::OrdinalIgnoreCase)
    [Array]::Sort($names, [StringComparer]::OrdinalIgnoreCase)
    [Array]::Reverse($names)  # descending puts every directory before its parent
    $steps = @($paths | ForEach-Object { [ordered]@{ action = 'delete-file'; path = $target + '\' + $_.Replace('/', '\'); expectSha256 = $files[$_] } }) +
        @($names | ForEach-Object { [ordered]@{ action = 'remove-empty-directory'; path = $target + '\' + $_ } }) +
        @([ordered]@{ action = 'remove-empty-directory'; path = $target })
    return ,$steps
}

# A3, at plan time: one reason for each created key an uninstall plan removes ($Steps) that
# would still hold a value or subkey the plan does not remove. $Contents maps each such key
# ('HKCU\...') to its { values; subkeys } names now; $AlsoRemoved maps a key to value names
# another plan removes first (the default-terminal rollback). Names compare ignoring case.
function Get-ForeignKeyContent($Steps, $Contents, $AlsoRemoved) {
    $keys = @($Steps | Where-Object { $_.action -ceq 'delete-empty-key' } | ForEach-Object { [string]$_.key })
    foreach ($key in $keys) {
        $removedValues = @($Steps | Where-Object { $_.action -ceq 'delete-registry-value' -and [string]$_.key -eq $key } | ForEach-Object { [string]$_.name }) +
            @(Get-Field $AlsoRemoved $key | Where-Object { $null -ne $_ })
        $removedKeys = @($keys | Where-Object { $_.StartsWith($key + '\', [StringComparison]::OrdinalIgnoreCase) } |
            ForEach-Object { $_.Substring($key.Length + 1) } | Where-Object { -not $_.Contains('\') })
        $content = Get-Field $Contents $key
        $foreign = @(@(Get-Field $content 'values' | Where-Object { $null -ne $_ -and $removedValues -notcontains $_ } | ForEach-Object { "value '$_'" }) +
            @(Get-Field $content 'subkeys' | Where-Object { $null -ne $_ -and $removedKeys -notcontains $_ } | ForEach-Object { "subkey $_" }))
        if ($foreign.Count) { "$key holds foreign content the plan does not remove: $($foreign -join ', ')" }
    }
}

# Why an owned tree may not be removed, or $null: a reference ($References, each { label; id;
# data }, such as a COM server path) the plan does not remove ($RemovedIds) names $Tree or a
# path beneath it. data is read as Windows reads it: environment variables expanded, a leading
# quote taking the path to the closing quote, the full path compared per segment ignoring case.
# Data that is not a path counts when it contains $Tree at all, ignoring case.
function Get-TreeReferenceProblem($References, [string]$Tree, $RemovedIds) {
    $root = $Tree.TrimEnd('\').ToUpperInvariant()
    foreach ($reference in @($References | Where-Object { $null -ne $_ })) {
        if (@($RemovedIds) -ccontains [string](Get-Field $reference 'id')) { continue }
        $data = [Environment]::ExpandEnvironmentVariables([string](Get-Field $reference 'data')).Trim()
        $path = if ($data.StartsWith('"')) { $data.Substring(1).Split('"')[0] } else { $data }
        try { $full = [IO.Path]::GetFullPath($path).ToUpperInvariant() } catch { $full = $null }
        $hit = if ($null -eq $full) { $data.ToUpperInvariant().Contains($root) } else { $full -ceq $root -or $full.StartsWith($root + '\', [StringComparison]::Ordinal) }
        if ($hit) { return "$(Get-Field $reference 'label') names ${Tree}: $data" }
    }
    return $null
}

# True when two records' targets cannot have separate owners: the same registry
# value (key and name, ignoring case), or file-system targets where one equals or
# contains the other per '\' segment, ignoring case (a file inside an extracted
# tree, or a nested tree). Registry and file-system targets never overlap. A
# created key and a value in it or beneath it, or a created key beneath it, have
# separate owners only when the key's intent came first (lower seq), so reverse
# order removes what it holds before the key; two claims on one key overlap.
function Test-TargetOverlap($First, $Other) {
    $firstKind, $otherKind = [string](Get-Field $First 'kind'), [string](Get-Field $Other 'kind')
    $a = ([string](Get-Field $First 'target')).ToUpperInvariant()
    $b = ([string](Get-Field $Other 'target')).ToUpperInvariant()
    $registry = @('registry-value', 'registry-key-created')
    if (($firstKind -cin $registry) -ne ($otherKind -cin $registry)) { return $false }
    if ($firstKind -ceq 'registry-value' -and $otherKind -ceq 'registry-value') {
        return ($a -ceq $b -and ([string](Get-Field $First 'name')).ToUpperInvariant() -ceq
            ([string](Get-Field $Other 'name')).ToUpperInvariant())
    }
    if ($firstKind -notin $registry) {
        return ($a -ceq $b -or $a.StartsWith($b + '\', [StringComparison]::Ordinal) -or
            $b.StartsWith($a + '\', [StringComparison]::Ordinal))
    }
    foreach ($pair in @(@($First, $a, $Other, $b, $otherKind), @($Other, $b, $First, $a, $firstKind))) {
        $key, $keyPath, $held, $heldPath, $heldKind = $pair
        if ([string](Get-Field $key 'kind') -cne 'registry-key-created') { continue }
        if ($heldPath -ceq $keyPath -and $heldKind -ceq 'registry-key-created') { return $true }
        if ($heldPath -ceq $keyPath -or $heldPath.StartsWith($keyPath + '\', [StringComparison]::Ordinal)) {
            return -not ([long](Get-Field $key 'seq') -lt [long](Get-Field $held 'seq'))
        }
    }
    return $false
}

# Why the temporary path an intent names (field temp, named before it exists) is not
# one only that intent could have made, or $null when it is absent or valid: exactly
# <target>.<guid32>.tmp for a file-created file, or <target>.<guid32>.staging for a
# tree-extracted extraction directory, beside its target. Other kinds name none.
function Get-IntentTempProblem($Record) {
    $temp, $target = (Get-Field $Record 'temp'), [string](Get-Field $Record 'target')
    if ($null -eq $temp) { return $null }
    $suffix = switch -CaseSensitive ([string](Get-Field $Record 'kind')) { 'file-created' { 'tmp' } 'tree-extracted' { 'staging' } }
    if (-not $suffix) { return "A $(Get-Field $Record 'kind') intent names no temporary path." }
    if ($temp -isnot [string] -or $temp -cnotmatch ('^' + [regex]::Escape($target) + '\.[0-9a-f]{32}\.' + $suffix + '\z')) {
        return "The temporary path is not $target.<guid32>.$suffix."
    }
    return $null
}

# Why the entry names of an archive ($Names, '/'-separated as stored) are not exactly the
# inventory $Files, or $null; checked before anything is extracted. Each name, less the
# trailing '/' of a directory entry, is an inventory file or a directory above one, spelled
# exactly, with safe segments and no '\'; no two names are equal ignoring case; every
# inventory file is named.
function Get-ZipEntryProblem($Names, $Files) {
    $inventory = ConvertTo-FileMap $Files
    if ($null -eq $inventory -or $inventory.Count -eq 0) { return 'The inventory is invalid.' }
    $parents, $seen = @(), @{}
    foreach ($file in $inventory.Keys) { $parts = $file.Split('/'); for ($i = 1; $i -lt $parts.Count; $i++) { $parents += $parts[0..($i - 1)] -join '/' } }
    foreach ($entry in @($Names)) {
        if ($entry -isnot [string]) { return 'An entry name is not a string.' }
        $directory = $entry.EndsWith('/')
        $name = if ($directory) { $entry.Substring(0, $entry.Length - 1) } else { $entry }
        if ($name.Contains('\') -or @($name.Split('/') | Where-Object { -not (Test-PathSegment $_) }).Count) { return "Unsafe entry: $entry" }
        if ($seen.ContainsKey($name)) { return "Entries repeat ignoring case: $entry" }
        $seen[$name] = $true
        if (($directory -and $parents -cnotcontains $name) -or (-not $directory -and @($inventory.Keys) -cnotcontains $name)) {
            return "Not in the inventory: $entry"
        }
    }
    $missing = @($inventory.Keys | Where-Object { -not $seen.ContainsKey($_) })
    if ($missing.Count) { return "Inventory files the archive lacks: $($missing -join ', ')" }
    return $null
}

# Cleanup of the staging directory an interrupted tree-extracted intent named, from
# $Observed: every entry now beneath it as { path = '/'-relative; directory = bool;
# reparse = bool }. Only an open intent's own valid staging path with a valid inventory
# qualifies, and only when no entry is a reparse point and every entry is a file of that
# inventory (bytes ignored: a crash may have truncated it) or a directory holding one.
# Steps, each path once: those files, then those directories deepest first, then the
# staging directory; each directory removal is non-recursive. Otherwise ok is false.
function Get-StagingCleanupSteps($Record, $Observed) {
    $staging = Get-Field $Record 'temp'
    $refuse = { param($Reason) [ordered]@{ ok = $false; reason = $Reason; steps = @() } }
    if ((Get-Field $Record 'kind') -cne 'tree-extracted' -or (Get-Field $Record 'phase') -cne 'intent' -or
        $staging -isnot [string] -or (Get-IntentTempProblem $Record)) {
        return & $refuse 'No tree intent names this staging directory.'
    }
    $files = ConvertTo-FileMap (Get-Field (Get-Field $Record 'desired') 'files')
    if ($null -eq $files -or $files.Count -eq 0) { return & $refuse 'The intent has no valid inventory.' }
    $parents = @{}
    foreach ($name in $files.Keys) {
        $parts = $name.Split('/')
        for ($i = 1; $i -lt $parts.Count; $i++) { $parents[$parts[0..($i - 1)] -join '/'] = $true }
    }
    $fileSteps, $directories, $unknown, $seen = @(), @(), @(), @{}
    foreach ($entry in @($Observed)) {
        $path = [string](Get-Field $entry 'path')
        if ((Get-Field $entry 'reparse') -eq $true) { return & $refuse "A reparse point is in the staging directory: $path" }
        if ($seen.ContainsKey($path)) { continue }
        $seen[$path] = $true
        if ((Get-Field $entry 'directory') -eq $true) {
            if ($parents.ContainsKey($path)) { $directories += $path } else { $unknown += $path }
        } elseif ($files.ContainsKey($path)) {
            $fileSteps += [ordered]@{ action = 'delete-file'; path = $staging + '\' + $path.Replace('/', '\') }
        } else { $unknown += $path }
    }
    if ($unknown.Count) { return & $refuse "Not in the inventory, so not removed: $($unknown -join ', ')" }
    $names = [string[]]$directories
    [Array]::Sort($names, [StringComparer]::OrdinalIgnoreCase)
    [Array]::Reverse($names)  # descending puts every directory before its parent
    $steps = $fileSteps + @($names | ForEach-Object { [ordered]@{ action = 'remove-empty-directory'; path = $staging + '\' + $_.Replace('/', '\') } }) +
        @([ordered]@{ action = 'remove-empty-directory'; path = $staging })
    [ordered]@{ ok = $true; reason = $null; steps = $steps }
}

# R1: true when the ledger ($Records) proves this code once installed package $Package: some
# tree-extracted attempt whose intent carries package = $Package (exactly, case-sensitive), for a
# tree of that package directly in $Programs (Test-PackageTarget; any version), has a commit,
# whether or not a later record closed it. No $Programs proves nothing. A void-only attempt (nothing was ever
# extracted), another package's attempt (even a name that starts the same), an intent without
# the field prove nothing, and neither does an id whose records together are not a valid history
# (Get-EffectAttempt: a malformed record, a repeated seq, a commit describing another effect, a
# void after a commit), nor any ledger in which two records share a seq. Only then is protected
# data (a browser profile) taken as ours; the first install happens only while it is absent.
# One pass groups the records by id (ordinal); only an id holding an intent that names $Package
# can prove it, so only those ids are validated, however much else the ledger holds.
function Test-PackageHistory($Records, [string]$Package, [string]$Programs) {
    if (-not $Package -or -not $Programs) { return $false }
    $all = @($Records | Where-Object { $null -ne $_ })
    $seqs = @($all | ForEach-Object { [string](Get-Field $_ 'seq') })
    if (@($seqs | Sort-Object -Unique).Count -ne $seqs.Count) { return $false }
    $groups = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
    $candidates = [Collections.Generic.List[string]]::new()
    foreach ($record in $all) {
        $id, $named = [string](Get-Field $record 'id'), (Get-Field $record 'package')
        if (-not $groups.ContainsKey($id)) { $groups[$id] = [Collections.Generic.List[object]]::new() }
        $groups[$id].Add($record)
        if ((Get-Field $record 'phase') -ceq 'intent' -and $named -is [string] -and $named -ceq $Package -and -not $candidates.Contains($id)) {
            $candidates.Add($id)
        }
    }
    foreach ($id in $candidates) {
        $group = @($groups[$id])
        if ((Get-EffectAttempt $group).problem) { continue }
        # Valid as a whole, so every attempt starts with an intent and its commits describe that intent's effect.
        $intent = $null
        foreach ($record in @($group | Sort-Object { [long](Get-Field $_ 'seq') })) {
            switch -CaseSensitive (Get-Field $record 'phase') {
                'intent' { $intent = $record }
                'commit' {
                    if ($null -ne $intent -and (Get-Field $intent 'kind') -ceq 'tree-extracted' -and (Get-Field $intent 'package') -ceq $Package -and
                        (Test-PackageTarget ([string](Get-Field $intent 'target')) $Package $Programs)) { return $true }
                }
                default { $intent = $null }  # void or undone closes the attempt
            }
        }
    }
    return $false
}

# D-c: the one download file a package tree intent may use, '<staging>.asset' beside the staging
# directory it names; derived, never free. Only for a well-formed tree-extracted intent whose
# package is a lock name and whose target is exactly $Programs\<package, lowercase>-<version>,
# the version starting with a digit and holding no '-' (so chromium-extra-1 is not Chromium's), so
# the file lies beside that package's own staging directory; otherwise $null.
function Get-PackageAssetPath($Record, [string]$Programs) {
    $package, $target, $temp = (Get-Field $Record 'package'), [string](Get-Field $Record 'target'), (Get-Field $Record 'temp')
    if ((Get-Field $Record 'kind') -cne 'tree-extracted' -or (Get-Field $Record 'phase') -cne 'intent' -or $temp -isnot [string] -or
        $null -ne (Get-EffectRecordProblem $Record) -or -not (Test-PackageTarget $target $package $Programs)) {
        return $null
    }
    return $temp + '.asset'
}

# The class of one locked package, from what was read before any effect:
#   $TreeClass  Get-EffectClass of its owned tree id against the observed target (after
#               recovery): absent, owned-*, preexisting-* (an unrecorded tree, A2) or indeterminate
#   $Entries    how many HKCU/HKLM Uninstall entries may be this product (FindUninstallEntries),
#               and $Problems their ExistingProblems (none when every entry is exactly the lock)
#   $Protected  whether declared protected data exists; $History, Test-PackageHistory
#   $Changed    the owned tree's recorded desired state is not this selection's (C1: same version,
#               another inventory or seed)
#   $Hazard     O1: the package's seed would overwrite a profile's Preferences on Chromium's next start
# The ledger decides ownership: an owned tree stays owned-match or owned-drift, removable by
# Uninstall, whatever else appears; one written for another selection is owned-drift. An external
# entry is never taken over and marks the package external: beside an owned tree it is a conflict
# (two installs share one profile), reported as drift after the other effects, with nothing new
# written. Without an owned tree, an entry makes it preexisting-match or -drift; then an unrecorded
# tree decides (A2); then protected data without history is foreign (R1); otherwise it is absent,
# the only class that installs. A hazard beside an owned or absent tree is never converged, and an
# absent one becomes preexisting-drift: nothing is installed.
function Get-PackageClass([string]$TreeClass, [int]$Entries, [string[]]$Problems, [bool]$Protected, [bool]$History, [bool]$Changed, [bool]$Hazard) {
    $external = $Entries -gt 0
    $class = if ($TreeClass -cin @('owned-match', 'owned-drift', 'indeterminate')) { $TreeClass }
        elseif ($external) { $(if (@($Problems | Where-Object { $_ }).Count) { 'preexisting-drift' } else { 'preexisting-match' }) }
        elseif ($TreeClass -cin @('preexisting-match', 'preexisting-drift')) { $TreeClass }
        elseif ($TreeClass -ceq 'absent') { $(if ($Protected -and -not $History) { 'preexisting-drift' } else { 'absent' }) }
        else { 'indeterminate' }
    $changed = $Changed -and $class -ceq 'owned-match'
    if ($changed) { $class = 'owned-drift' }
    $hazard = $Hazard -and $class -cin @('absent', 'owned-match', 'owned-drift')
    if ($hazard -and $class -ceq 'absent') { $class = 'preexisting-drift' }
    $conflict = $external -and $class -cin @('owned-match', 'owned-drift')
    [ordered]@{ class = $class; external = $external; conflict = $conflict; changed = $changed; hazard = $hazard
        install = ($class -ceq 'absent')
        converged = ($class -cin @('owned-match', 'preexisting-match') -and -not $conflict -and -not $hazard) }
}

# Why a package's seed (pack.py: Chromium's initial_preferences, added to its owned tree) cannot be
# used, or $null when it has none or it can: its path is initial_preferences in the executable's
# directory, where the inventory holds neither it nor the legacy master_preferences, and holds nothing
# beneath it; file is a bundle file ($BundleFiles, manifest.files) with exactly its SHA-256; size is a
# byte count; and the package declares exactly one protected path, the profile directory O1 reads.
function Get-SeedProblem($Package, $BundleFiles) {
    $seed = Get-Field $Package 'seed'
    if ($null -eq $seed) { return $null }
    $f = Get-Fields $seed @('path', 'file', 'sha256', 'size')
    $executable, $files = [string](Get-Field $Package 'executable'), (ConvertTo-FileMap (Get-Field $Package 'files'))
    if ($f.path -isnot [string] -or -not (Test-RelativePath $f.path) -or $f.file -isnot [string] -or -not (Test-RelativePath $f.file) -or
        $f.sha256 -isnot [string] -or $f.sha256 -cnotmatch '^[0-9a-f]{64}\z' -or -not (Test-ByteCount $f.size) -or $null -eq $files) {
        return 'The seed is not {path, file, sha256, size}.'
    }
    $directory = { param($Path) if ($Path.Contains('/')) { $Path.Substring(0, $Path.LastIndexOf('/') + 1) } else { '' } }
    if ($f.path -cne ((& $directory $executable) + 'initial_preferences')) { return "The seed is not initial_preferences beside $executable." }
    $legacy = (& $directory $executable) + 'master_preferences'
    if (@($files.Keys | Where-Object { $_ -eq $f.path -or $_ -eq $legacy -or $_.StartsWith($f.path + '/', [StringComparison]::OrdinalIgnoreCase) }).Count) {
        return 'The inventory holds the seed, its legacy name or a path beneath it.'
    }
    $bundled = Get-Field $BundleFiles $f.file
    if ($bundled -isnot [string] -or $bundled -cne $f.sha256) { return "The seed file $($f.file) is not a bundle file with that SHA-256." }
    if (@(Get-Field $Package 'protected').Count -ne 1) { return 'A seeded package declares exactly one protected profile directory.' }
    return $null
}

# The archive entry names of a `tar -tf` listing ($Lines), normalized for Get-ZipEntryProblem:
# a name that is a directory above an inventory file ($Files, exact case) becomes '<name>/'
# whether or not tar marked it with one trailing '/'; a marked name that is not such a directory
# keeps its '/', so it is refused; empty lines (the listing's end) are dropped. Anything else
# stays as listed and is judged by Get-ZipEntryProblem.
function ConvertFrom-TarListing($Lines, $Files) {
    $inventory = ConvertTo-FileMap $Files
    $parents = @{}
    if ($null -ne $inventory) {
        foreach ($file in $inventory.Keys) { $parts = $file.Split('/'); for ($i = 1; $i -lt $parts.Count; $i++) { $parents[$parts[0..($i - 1)] -join '/'] = $true } }
    }
    foreach ($line in @($Lines)) {
        $name = ([string]$line).TrimEnd("`r")
        if ($name -eq '') { continue }
        $marked = $name.EndsWith('/')
        if ($marked) { $name = $name.Substring(0, $name.Length - 1) }
        # Case-sensitive: Get-ZipEntryProblem refuses a parent spelled in another case.
        if ($marked -or @($parents.Keys) -ccontains $name) { "$name/" } else { $name }
    }
}

# One command line for a native Windows program (CommandLineToArgvW / MSVC argv rules), since
# Windows PowerShell 5.1 has no ProcessStartInfo.ArgumentList: an argument that is empty or holds
# white space or '"' is quoted, a '"' is escaped, and backslashes before a '"' or the closing
# quote are doubled. A NUL cannot be passed and stops the run.
function Join-NativeArguments([string[]]$Arguments) {
    @(foreach ($value in @($Arguments)) {
        $argument = [string]$value
        if ($argument.Contains([string][char]0)) { throw 'A native argument holds a NUL.' }
        if ($argument -ne '' -and $argument -notmatch '[\s"]') { $argument; continue }
        '"' + ($argument -replace '(\\*)"', '$1$1\"' -replace '(\\+)\z', '$1$1') + '"'
    }) -join ' '
}

# A byte count as win.ps1 reads it from JSON: a positive integer no larger than 2^53 - 1.
function Test-ByteCount($Value) { ($Value -is [int] -or $Value -is [long]) -and $Value -gt 0 -and $Value -le 9007199254740991 }

# The bytes one install needs on its volume: the asset, the unpacked inventory, its seed (if it has
# one) and 64 MiB of ledger headroom; $null when a count is invalid.
function Get-PackageSpaceNeed($Package) {
    $size, $unpacked, $seed = (Get-Field $Package 'size'), (Get-Field $Package 'unpackedSize'), (Get-Field $Package 'seed')
    $seedSize = Get-Field $seed 'size'
    if (-not (Test-ByteCount $size) -or -not (Test-ByteCount $unpacked) -or ($null -ne $seed -and -not (Test-ByteCount $seedSize))) { return $null }
    return [long]$size + [long]$unpacked + [long]$(if ($null -ne $seed) { $seedSize } else { 0 }) + 64MB
}

# Why one package cannot be installed at $Target with $Free bytes free on its volume, or $null:
# Get-PackageSpaceNeed must fit, and every path the install creates (its inventory and seed) must
# stay below the Windows PowerShell 5.1 limits (a file path below 260 characters, a directory below
# 248), measured under the staging directory (<target>.<guid32>.staging, the longest form) and for
# its asset file.
function Get-PackageSpaceProblem($Package, [string]$Target, $Free) {
    $need, $files, $seed = (Get-PackageSpaceNeed $Package), (ConvertTo-FileMap (Get-Field $Package 'files')), (Get-Field $Package 'seed')
    if ($null -eq $need -or -not ($Free -is [int] -or $Free -is [long]) -or $null -eq $files -or $files.Count -eq 0 -or -not $Target -or
        ($null -ne $seed -and -not (Test-RelativePath ([string](Get-Field $seed 'path'))))) {
        return 'The package size, inventory, seed, target or free space is invalid.'
    }
    if ([long]$Free -lt $need) { return "Needs $need bytes free on the volume of $Target; $Free are." }
    $staging = $Target + '.' + ('0' * 32) + '.staging'
    $directories = @{ $staging = $true }
    $longest = "$staging.asset"
    foreach ($name in @($files.Keys) + @(if ($null -ne $seed) { [string](Get-Field $seed 'path') })) {
        $path = $staging + '\' + $name.Replace('/', '\')
        if ($path.Length -gt $longest.Length) { $longest = $path }
        $parent = [IO.Path]::GetDirectoryName($path)
        while ($parent.Length -gt $staging.Length) { $directories[$parent] = $true; $parent = [IO.Path]::GetDirectoryName($parent) }
    }
    if ($longest.Length -ge 260) { return "A path would be $($longest.Length) characters (limit 259): $longest" }
    $deepest = @($directories.Keys | Sort-Object Length -Descending)[0]
    if ($deepest.Length -ge 248) { return "A directory path would be $($deepest.Length) characters (limit 247): $deepest" }
    return $null
}

# Why a downloaded asset is not exactly the lock, or $null: its length ($Length) and its
# SHA-256 ($Sha256) and, when the lock names one, SHA-1 ($Sha1), computed from the bytes read
# under a handle that denies writers; hashes compare as lowercase hex, so '0x…' or a trailing
# newline never matches.
function Get-AssetProblem($Package, $Length, [string]$Sha256, [string]$Sha1) {
    $size, $sha256Lock, $sha1Lock = (Get-Field $Package 'size'), (Get-Field $Package 'sha256'), (Get-Field $Package 'sha1')
    if (-not (Test-ByteCount $size) -or $sha256Lock -isnot [string] -or $sha256Lock -cnotmatch '^[0-9a-f]{64}\z' -or
        ($null -ne $sha1Lock -and ($sha1Lock -isnot [string] -or $sha1Lock -cnotmatch '^[0-9a-f]{40}\z'))) { return 'The lock is invalid.' }
    if (-not ($Length -is [int] -or $Length -is [long]) -or [long]$Length -ne [long]$size) { return "The asset is $Length bytes, not $size." }
    if ($Sha256 -cnotmatch '^[0-9A-Fa-f]{64}\z' -or $Sha256.ToLowerInvariant() -cne $sha256Lock) { return 'The asset SHA-256 differs from the lock.' }
    if ($null -ne $sha1Lock -and ($Sha1 -cnotmatch '^[0-9A-Fa-f]{40}\z' -or $Sha1.ToLowerInvariant() -cne $sha1Lock)) { return 'The asset SHA-1 differs from the lock.' }
    return $null
}

# Why a machine-wide Noctty is present, or $null: any HKLM (either view) key for the
# Noctty terminal or proxy CLSID in $ClsidKeys, or an HKLM Uninstall DisplayName in
# $DisplayNames that names Noctty. Restore and Apply then stop before any effect.
function Get-MachineNocttyReason($ClsidKeys, $DisplayNames) {
    $classes = @('{33368C6F-D328-410C-B225-26DC9F12C728}', '{1D349824-21FB-46C7-ACF3-746EDC991D52}')
    foreach ($key in @($ClsidKeys)) {
        foreach ($clsid in $classes) { if ([string]$key -like "*\CLSID\$clsid") { return "HKLM registers Noctty: $key" } }
    }
    foreach ($name in @($DisplayNames)) { if ([string]$name -like '*noctty*') { return "HKLM Uninstall lists $name" } }
    return $null
}

# The Noctty default-terminal registration from manifest.noctty.registration: $Rows, each
# exactly { key; name; data } strings, under the same rules as pack.py noctty_registration.
# A key is a CLSID or Interface {GUID} key under Software\Classes or beneath it; {install}
# opens data, optionally quoted, names a file of $Files (the Noctty inventory) and is bound
# to $Install, the absolute versioned Noctty directory. values are the rows with data bound;
# keys are every key from the {GUID} key down to each value's key, parents first, each once,
# so the shared CLSID and Interface roots are never among them. A key spelled in two cases,
# or a key and name repeated ignoring case, is a problem; with a problem both lists are empty.
function Get-NocttyRegistration($Rows, [string]$Install, $Files) {
    $refuse = { param($Reason) [ordered]@{ problem = $Reason; values = @(); keys = @() } }
    $inventory = ConvertTo-FileMap $Files
    if ($null -eq $inventory -or -not (Test-EffectPath 'file' $Install)) { return & $refuse 'The inventory or install path is invalid.' }
    $root = '^Software\\Classes\\(CLSID|Interface)\\\{[0-9A-F]{8}(-[0-9A-F]{4}){3}-[0-9A-F]{12}\}(\\[^\\\x00-\x1f]+)*$'
    $values, $keys, $seen, $spelled = @(), @(), @{}, @{}
    foreach ($row in @($Rows)) {
        $fields = if ($row -is [Collections.IDictionary]) { @($row.Keys) } elseif ($row -is [Management.Automation.PSCustomObject]) { @($row.PSObject.Properties.Name) } else { @() }
        $key, $name, $data = (Get-Field $row 'key'), (Get-Field $row 'name'), (Get-Field $row 'data')
        if ((@($fields | Sort-Object) -join ',') -cne 'data,key,name' -or $key -isnot [string] -or $name -isnot [string] -or $data -isnot [string]) {
            return & $refuse 'A registration row is not exactly { key; name; data } strings.'
        }
        if ($key -cnotmatch $root -or $data -eq '' -or ($name + $data) -match '[\x00-\x1f]' -or ($key + $name).Contains('{install}')) {
            return & $refuse "Invalid registration value: $key [$name]"
        }
        if ($data.Contains('{install}')) {
            if ($data -cnotmatch '^("?)\{install\}\\([^"]+)\1$' -or -not $inventory.ContainsKey($Matches[2].Replace('\', '/'))) {
                return & $refuse "Registration data does not name a Noctty file: $key [$name]"
            }
            $data = $data.Replace('{install}', $Install)
        }
        $id = ($key + '|' + $name).ToUpperInvariant()
        if ($seen.ContainsKey($id)) { return & $refuse "Duplicate registration value: $key [$name]" }
        $seen[$id] = $true
        $values += [ordered]@{ key = $key; name = $name; data = $data }
        $parts = $key.Split('\')
        for ($i = 4; $i -le $parts.Count; $i++) {
            $path = $parts[0..($i - 1)] -join '\'
            $upper = $path.ToUpperInvariant()
            if (-not $spelled.ContainsKey($upper)) { $spelled[$upper] = $path; $keys += $path }
            elseif ($spelled[$upper] -cne $path) { return & $refuse "A registration key is spelled in two cases: $path" }
        }
    }
    if (-not $values.Count) { return & $refuse 'The registration is empty.' }
    [ordered]@{ problem = $null; values = $values; keys = $keys }
}

# The uninstall plan for all ledger records ($Records, any order) and
# $Observations, a map id -> current state; a missing observation is indeterminate.
# Ids are visited by the seq of their open attempt's intent, latest first. Only
# owned-match, and a partly removed tree that can resume (listed in resumed), produce
# steps, each tagged with its id and kind so the executor writes that id's `undone`
# after its steps; other owned-drift and indeterminate are refused;
# unowned targets (absent, preexisting-*, closed or voided attempts) are kept
# untouched and listed. Also refused: a repeated seq or ids differing only in case
# (the whole plan); open attempts whose targets overlap (Test-TargetOverlap); an
# open registry-value on HKCU\Console\%%Startup, which the older default-terminal
# record owns (Get-LegacyTerminalPlan); and a file-replaced or prefix-inserted
# effect without exactly one owned-match file-created backup of its own, with an
# earlier intent, whose target is prior.backup and whose desired sha256 is
# prior.sha256. ok is false when anything is refused, and then steps is empty.
# resolutions lists the closing records the executor writes before acting:
# 'confirm' (commit), 'void' or 'undone'; an id resolved 'void' or 'undone' is
# unowned, so it is kept and never undone again.
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
    # One pass groups the records by id (ordinal, in ledger order), and each id is validated once:
    # Get-EffectClass is given that attempt instead of validating the same records again.
    $groups = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
    foreach ($record in $all) {
        $id = [string](Get-Field $record 'id')
        if (-not $groups.ContainsKey($id)) { $groups[$id] = [Collections.Generic.List[object]]::new() }
        $groups[$id].Add($record)
    }
    $entries = @()
    foreach ($id in $ids) {
        $attempt = Get-EffectAttempt @($groups[$id])
        $open = @(if (-not $attempt.closed) { $attempt.records })
        $entries += [pscustomobject]@{ id = $id; class = (Get-EffectClass $null (Get-Field $Observations $id) '' $null $attempt)
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
    $resumed = @()
    foreach ($entry in @($entries | Sort-Object @{ Expression = 'start'; Descending = $true }, id -CaseSensitive)) {
        $class = $entry.class
        if ($class.resolution) { $resolutions += [ordered]@{ id = $entry.id; resolution = $class.resolution } }
        # A partly removed owned tree (owned-drift) resumes when Get-TreeUndoSteps allows it.
        $resume = $null
        if ($class.class -ceq 'owned-drift' -and (Get-Field $entry.record 'kind') -ceq 'tree-extracted') {
            $resume = Get-TreeUndoSteps $entry.record (Get-Field $Observations $entry.id)
        }
        if ($entry.refusal) {
            $refused += [ordered]@{ id = $entry.id; class = 'indeterminate'; reason = $entry.refusal }
        } elseif ($class.class -ceq 'owned-match' -or $null -ne $resume) {
            if ($null -ne $resume) { $resumed += $entry.id } else { $resume = @(Get-UndoSteps $entry.record) }
            foreach ($step in $resume) { $step['id'] = $entry.id; $step['kind'] = [string](Get-Field $entry.record 'kind'); $steps += $step }
        } elseif ($class.class -cin @('owned-drift', 'indeterminate')) {
            $refused += [ordered]@{ id = $entry.id; class = $class.class; reason = $class.reason }
        } else { $kept += [ordered]@{ id = $entry.id; class = $class.class } }
    }
    if ($refused.Count) { $steps = @() }
    [ordered]@{ ok = ($refused.Count -eq 0); steps = $steps; refused = $refused; kept = $kept; resolutions = $resolutions; resumed = $resumed }
}

# Rollback of the %%Startup values one run wrote, when that same run then fails. $Before is the
# pair it read just before writing ({ console; terminal }, $null for an absent value), $Written
# maps each value name it planned to write (DelegationConsole, DelegationTerminal) to that value,
# and $Current is the pair now. A planned value that now holds what was written goes back to
# $Before, DelegationTerminal first ($null deletes it); one that still holds $Before is skipped
# (its write never landed); any other value refuses the whole rollback (ok false, no steps), so
# nothing written by anyone else is overwritten, and values not planned are never touched. This
# is not the write-once record, whose prior is from before the first change (Uninstall restores it).
function Get-SelectionRollbackSteps($Before, $Written, $Current) {
    $steps = @()
    foreach ($value in @(@('DelegationTerminal', 'terminal'), @('DelegationConsole', 'console'))) {
        $name, $field = $value
        $wrote, $now, $was = (Get-Field $Written $name), (Get-Field $Current $field), (Get-Field $Before $field)
        if ($null -eq $wrote) { continue }
        if ($now -is [string] -and $now -eq $wrote) { $steps += [ordered]@{ name = $name; expect = $wrote; value = $was } }
        elseif (($null -eq $now -and $null -eq $was) -or ($now -is [string] -and $was -is [string] -and $now -eq $was)) { continue }
        else { return [ordered]@{ ok = $false; reason = "$name changed after this run wrote it."; steps = @() } }
    }
    [ordered]@{ ok = $true; reason = $null; steps = $steps }
}

# Rollback plan from the older default-terminal record win.ps1 writes once to
# provenance\default-terminal.json: its own schema 1 with key, priorDelegationConsole,
# priorDelegationTerminal (each $null when the value was absent), priorSelectsNoctty
# and written, and no `ledger` field. $Current is the pair read now as
# { console; terminal }, $null for an absent value. A record is well formed only
# as win.ps1 writes it: written is exactly the Windows Terminal console and Noctty
# terminal, and priorSelectsNoctty is true exactly when the prior terminal is Noctty.
# action is 'report' when the original selection is unknown (priorSelectsNoctty).
# Otherwise each current value is its prior ($null matching $null; a prior equal to
# what was written counts as prior), what Restore wrote, or other: any other is
# 'refuse'; both prior is 'none', so a repeated rollback succeeds without an effect;
# else 'restore' with steps for only the values still as written, DelegationTerminal
# first (a $null value deletes it). An interruption between the two writes, in either
# direction, so resumes with the value left to restore. Every result has steps (empty
# unless 'restore'), so strict callers can always read it.
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
        return [ordered]@{ action = 'refuse'; reason = 'Malformed default-terminal record.'; steps = @() }
    }
    if ($selects) {
        return [ordered]@{ action = 'report'; reason = 'Noctty was already selected when recorded; the original selection is unknown.'; steps = @() }
    }
    $cc, $ct = (Get-Field $Current 'console'), (Get-Field $Current 'terminal')
    if (($null -ne $cc -and $cc -isnot [string]) -or ($null -ne $ct -and $ct -isnot [string])) {
        return [ordered]@{ action = 'refuse'; reason = 'The current selection is not readable as two values.'; steps = @() }
    }
    $steps = @()
    foreach ($value in @(@('DelegationTerminal', $ct, $pt, $wt), @('DelegationConsole', $cc, $pc, $wc))) {
        $name, $now, $prior, $wrote = $value
        if ($now -eq $prior) { continue }
        if ($now -isnot [string] -or $now -ne $wrote) {
            return [ordered]@{ action = 'refuse'; reason = "$name is neither its recorded prior value nor the one Restore wrote."; steps = @() }
        }
        $steps += [ordered]@{ name = $name; expect = $wrote; value = $prior }
    }
    if (-not $steps.Count) {
        return [ordered]@{ action = 'none'; reason = 'Already restored: the current selection equals the recorded prior one.'; steps = @() }
    }
    [ordered]@{ action = 'restore'; key = $key; steps = $steps; reason = $null }
}
