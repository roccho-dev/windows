# Pure evaluation of default-terminal handoff evidence and of package pins: no
# environment checks and no effects, so proof.ps1 can exercise it with synthetic
# records on CI.
# A 'proven' verdict is only as good as the host observations passed in; CI
# never supplies real ones, so CI never claims an actual handoff.

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
