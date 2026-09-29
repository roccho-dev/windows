#requires -Version 5.1
[CmdletBinding()]
param(
    [ValidateSet('Probe', 'Finalize')][string]$Phase = 'Probe',
    [ValidateSet('ShellExecute', 'Manual')][string]$Launcher = 'ShellExecute',
    [string]$Evidence,
    [string]$TraceFile,
    [ValidateRange(5, 300)][int]$TimeoutSeconds = 30
)

# Host-only evidence that a newly launched console is handed off to Noctty.
# It never registers, unregisters, or repairs anything. Any missing, ambiguous,
# or contrary observation yields 'unproven' or 'failed', never 'proven'.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ($env:OS -ne 'Windows_NT' -or $env:GITHUB_ACTIONS -eq 'true') {
    throw 'Handoff proof is host-only: it needs an interactive Windows desktop.'
}
$nocttyTerminal = '{33368C6F-D328-410C-B225-26DC9F12C728}'
$manifest = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'manifest.json') -Raw -Encoding utf8 | ConvertFrom-Json
$nocttyExe = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) (
    'Programs\noctty-' + $manifest.noctty.version + '\noctty\noctty.exe')

function Emit($Record, [string]$Path) {
    if (Test-Path -LiteralPath $Path) { throw "Evidence already exists: $Path" }
    $json = $Record | ConvertTo-Json -Depth 5
    [IO.File]::WriteAllText($Path, $json, [Text.UTF8Encoding]::new($false))
    $json
}

if ($Phase -eq 'Probe') {
    $principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    if ($principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Run the probe unelevated: an elevated console is not the handoff under test.'
    }
    if (-not [Environment]::UserInteractive) { throw 'The probe needs an interactive desktop session.' }
    # Declared state first; RestoreTest throws on any drift and never launches a console.
    $state = (& (Join-Path $PSScriptRoot 'win.ps1') -Mode RestoreTest) | ConvertFrom-Json
    if ($state.source -ne $manifest.source -or $state.registrationState -ne 'registered') {
        throw 'Noctty is not registered as the default terminal by this distribution.'
    }

    $uia = $true
    try { Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes } catch { $uia = $false }
    function WindowOwner([string]$Title) {
        if ($uia) {
            foreach ($element in [Windows.Automation.AutomationElement]::RootElement.FindAll(
                    [Windows.Automation.TreeScope]::Children, [Windows.Automation.Condition]::TrueCondition)) {
                $name = $element.Current.Name
                if ($name -and $name.Contains($Title)) { return $element.Current.ProcessId }
            }
            return $null
        }
        $process = Get-Process | Where-Object { $_.MainWindowTitle -and $_.MainWindowTitle.Contains($Title) } |
            Select-Object -First 1
        if ($null -ne $process) { return $process.Id }
        return $null
    }

    $nonce = [guid]::NewGuid().ToString('N')
    $title = 'noctty-probe-' + $nonce
    $before = @(Get-CimInstance Win32_Process -Filter "Name = 'WindowsTerminal.exe'" | ForEach-Object { $_.ProcessId })
    $started = [DateTime]::UtcNow
    if ($Launcher -eq 'ShellExecute') {
        (New-Object -ComObject Shell.Application).ShellExecute('cmd.exe', "/d /k title $title", '', 'open', 1)
    } else {
        Write-Host "Within $TimeoutSeconds seconds, press Win+R and run: cmd /d /k title $title"
    }

    $probe, $ownerId = $null, $null
    $deadline = $started.AddSeconds($TimeoutSeconds)
    while ([DateTime]::UtcNow -lt $deadline -and $null -eq $ownerId) {
        Start-Sleep -Milliseconds 500
        if ($null -eq $probe) {
            $probe = Get-CimInstance Win32_Process -Filter "Name = 'cmd.exe'" |
                Where-Object { $_.CommandLine -and $_.CommandLine.Contains($nonce) } | Select-Object -First 1
        }
        if ($null -ne $probe) { $ownerId = WindowOwner $title }
    }
    Start-Sleep -Seconds 2  # let a late terminal host appear before it is counted
    $owner = $null
    if ($null -ne $ownerId) {
        $process = Get-CimInstance Win32_Process -Filter "ProcessId = $ownerId"
        if ($null -ne $process) {
            $owner = [ordered]@{ pid = [int]$ownerId; name = $process.Name; path = $process.ExecutablePath }
        }
    }
    $newHosts = @(Get-CimInstance Win32_Process -Filter "Name = 'WindowsTerminal.exe'" |
        Where-Object { $before -notcontains $_.ProcessId } |
        ForEach-Object { [ordered]@{ pid = [int]$_.ProcessId; commandLine = $_.CommandLine } })
    if ($null -ne $probe) { Stop-Process -Id $probe.ProcessId -ErrorAction SilentlyContinue }

    $ownedByNoctty = $null -ne $owner -and $null -ne $owner.path -and
        [string]::Equals($owner.path, $nocttyExe, [StringComparison]::OrdinalIgnoreCase)
    $failures, $gaps = @(), @()
    if ($null -ne $owner -and $null -ne $owner.path -and -not $ownedByNoctty) {
        $failures += "Probe window is owned by $($owner.name) at $($owner.path)."
    }
    if ($newHosts.Count -gt 0) { $failures += 'A new Windows Terminal host started for the probe.' }
    if ($null -eq $probe) { $gaps += 'The probe cmd.exe was not observed.' }
    elseif ($null -eq $owner) { $gaps += 'No top-level window carrying the probe title was found.' }
    elseif ($null -eq $owner.path) { $gaps += "The path of window owner $($owner.name) is unreadable." }
    $gaps += 'Console host ETW has not been evaluated; run -Phase Finalize.'
    if (-not $Evidence) { $Evidence = Join-Path ([IO.Path]::GetTempPath()) "noctty-handoff-$nonce.json" }
    Emit ([ordered]@{ schema = 1; phase = 'Probe'; source = $manifest.source; launcher = $Launcher
        nonce = $nonce; title = $title; startedUtc = $started.ToString('o'); endedUtc = [DateTime]::UtcNow.ToString('o')
        registrationState = $state.registrationState; windowDetection = $(if ($uia) { 'UIAutomation' } else { 'MainWindowTitle' })
        probePid = $(if ($null -ne $probe) { [int]$probe.ProcessId } else { $null })
        expectedNoctty = $nocttyExe; windowOwner = $owner; windowOwnedByNoctty = $ownedByNoctty
        newTerminalHosts = $newHosts; failures = $failures; gaps = $gaps
        handoffProof = $(if ($failures.Count) { 'failed' } else { 'unproven' }) }) $Evidence
    return
}

# Finalize: combine one probe record with a stopped Microsoft.Windows.Console.Host trace.
if (-not $Evidence -or -not $TraceFile) { throw 'Finalize needs -Evidence and -TraceFile.' }
$record = Get-Content -LiteralPath $Evidence -Raw -Encoding utf8 | ConvertFrom-Json
if ($record.schema -ne 1 -or $record.phase -ne 'Probe') { throw 'Not a probe evidence record.' }
if ($record.source -ne $manifest.source) { throw 'Evidence was produced by a different distribution.' }
$xml = Join-Path ([IO.Path]::GetTempPath()) "noctty-handoff-$($record.nonce).xml"
$null = & tracerpt.exe $TraceFile -o $xml -of XML -y
if ($LASTEXITCODE -ne 0) { throw "tracerpt failed: $LASTEXITCODE" }
$document = New-Object Xml.XmlDocument
$document.Load($xml)
. (Join-Path $PSScriptRoot 'handoff-evaluate.ps1')
$verdict = Get-HandoffVerdict $record @(Get-HandoffEvents $document) $nocttyTerminal
Emit ([ordered]@{ schema = 1; phase = 'Finalize'; source = $manifest.source; nonce = $record.nonce
    launcher = $record.launcher; probe = $Evidence; trace = $TraceFile; terminalClsids = $verdict.terminalClsids
    windowOwner = $record.windowOwner; failures = $verdict.failures; gaps = $verdict.gaps
    handoffProof = $verdict.handoffProof }) ([IO.Path]::ChangeExtension($Evidence, '.final.json'))
