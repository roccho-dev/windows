# Pure evaluation of default-terminal handoff evidence: no environment checks
# and no effects, so proof.ps1 can exercise it with synthetic records on CI.
# A 'proven' verdict is only as good as the host observations passed in; CI
# never supplies real ones, so CI never claims an actual handoff.

# SrvInit_ReceiveHandoff events from a tracerpt XML report, each with its UTC
# time ($null when unparseable) and the TerminalClsid values it carries.
function Get-HandoffEvents([Xml.XmlDocument]$Document) {
    foreach ($event in $Document.GetElementsByTagName('Event')) {
        $text = $event.OuterXml
        # Exactly the OpenConsole receive event, not SrvInit_ReceiveHandoff_OpenedPipes and similar.
        if ($text -notmatch '(?<![A-Za-z_])SrvInit_ReceiveHandoff(?![A-Za-z_])') { continue }
        $created = @($event.GetElementsByTagName('TimeCreated'))
        $stamp = if ($created.Count) { $created[0].GetAttribute('SystemTime') } else { '' }
        $stamp = $stamp -replace '(\.\d{7})\d+', '$1'  # ETW may carry more than .NET's 7 digits
        $time = [DateTime]::MinValue
        $dated = [DateTime]::TryParse($stamp, [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::AdjustToUniversal, [ref]$time)
        [pscustomobject]@{
            time = $(if ($dated) { $time } else { $null })
            clsids = @([regex]::Matches($text, 'TerminalClsid[^{]{0,200}(\{[0-9A-Fa-f-]{36}\})') |
                ForEach-Object { $_.Groups[1].Value.ToUpperInvariant() })
        }
    }
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
    $gaps = @()
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
