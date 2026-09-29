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
. (Join-Path $PSScriptRoot 'handoff-evaluate.ps1')

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

    # OpenConsole runs inside the Windows Terminal package, and a process there has
    # been observed to read a different pair than HKCU shows (source unverified).
    # Read the pair from that context with a GUI-subsystem script host, so no
    # console (and no handoff) is created; the script only reads the registry.
    $terminalPackage = 'Microsoft.WindowsTerminal_8wekyb3d8bbwe'
    function HkcuPair {
        $key = Get-Item -LiteralPath 'HKCU:\Console\%%Startup' -ErrorAction SilentlyContinue
        [ordered]@{ console = $(if ($key) { $key.GetValue('DelegationConsole') } else { $null })
            terminal = $(if ($key) { $key.GetValue('DelegationTerminal') } else { $null }) }
    }
    $hkcuPair = HkcuPair  # compare with a second read after the package view
    $packagePair, $packageNote = $null, $null
    # One unique scratch directory directly under the profile: outside AppData
    # (which the package may redirect), OneDrive, and this bundle.
    $userHome = [IO.Path]::GetFullPath($env:USERPROFILE).TrimEnd('\')
    $homeItem = Get-Item -LiteralPath $userHome -Force
    if ($homeItem.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'The user profile directory is a reparse point.' }
    $scratchName = 'noctty-package-view-' + [guid]::NewGuid().ToString('N')
    $scratch = Join-Path $userHome $scratchName
    foreach ($excluded in @([Environment]::GetFolderPath('ApplicationData'), [Environment]::GetFolderPath('LocalApplicationData'),
            $env:OneDrive, $env:OneDriveConsumer, $env:OneDriveCommercial, $PSScriptRoot)) {
        if (-not $excluded) { continue }
        $prefix = [IO.Path]::GetFullPath($excluded).TrimEnd('\') + '\'
        if (($scratch + '\').StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
            throw "The scratch directory would fall under $excluded."
        }
    }
    $null = New-Item -ItemType Directory -Path $scratch  # fails if it already exists
    $script = Join-Path $scratch 'view.js'
    $answer = Join-Path $scratch 'view.json'
    function ScriptHosts {
        @(Get-CimInstance Win32_Process -Filter "Name = 'wscript.exe'" |
            Where-Object { $_.CommandLine -and $_.CommandLine.Contains($scratchName) })
    }
    # Removes this exact directory and only its known files, never recursively.
    function RemoveScratch {
        $item = Get-Item -LiteralPath $scratch -Force -ErrorAction SilentlyContinue
        if ($null -eq $item) { return 'absent' }
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -or -not $item.PSIsContainer -or
            -not [string]::Equals($item.FullName.TrimEnd('\'), $scratch, [StringComparison]::OrdinalIgnoreCase) -or
            -not [string]::Equals($item.Parent.FullName.TrimEnd('\'), $userHome, [StringComparison]::OrdinalIgnoreCase) -or
            $item.Name -cnotmatch '^noctty-package-view-[0-9a-f]{32}$') { return 'kept: not the expected directory' }
        $known = @('view.js', 'view.json', 'view.json.partial')
        foreach ($child in @(Get-ChildItem -LiteralPath $scratch -Force)) {
            if ($child.PSIsContainer -or ($child.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $known -notcontains $child.Name) {
                return "kept: unexpected entry $($child.Name)"
            }
        }
        try {
            foreach ($name in $known) {
                $path = Join-Path $scratch $name
                if ([IO.File]::Exists($path)) { [IO.File]::Delete($path) }
            }
            [IO.Directory]::Delete($scratch, $false)  # non-recursive: fails if anything remains
        } catch { return "kept: $($_.Exception.Message)" }
        return 'removed'
    }
    $cleanup = 'not attempted'
    try {
    [IO.File]::WriteAllText($script, @'
var shell = new ActiveXObject('WScript.Shell'), files = new ActiveXObject('Scripting.FileSystemObject');
function read(name) { try { return shell.RegRead('HKCU\\Console\\%%Startup\\' + name); } catch (e) { return null; } }
function quote(value) { return value === null ? 'null' : '"' + String(value).replace(/[^0-9A-Za-z{}-]/g, '') + '"'; }
var out = WScript.Arguments(0), stream = files.CreateTextFile(out + '.partial', true);
stream.Write('{"console":' + quote(read('DelegationConsole')) + ',"terminal":' + quote(read('DelegationTerminal')) + '}');
stream.Close();
files.MoveFile(out + '.partial', out);
'@, [Text.UTF8Encoding]::new($false))
        Invoke-CommandInDesktopPackage -PackageFamilyName $terminalPackage -AppId App `
            -Command (Join-Path $env:SystemRoot 'System32\wscript.exe') -Args "//B //NoLogo `"$script`" `"$answer`""
        # The command returns before the packaged process finishes; wait for its complete file.
        $viewDeadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
        while ($null -eq $packagePair -and [DateTime]::UtcNow -lt $viewDeadline) {
            Start-Sleep -Milliseconds 250
            if ([IO.File]::Exists($answer)) { $packagePair = Get-Content -LiteralPath $answer -Raw | ConvertFrom-Json }
        }
        if ($null -eq $packagePair) { $packageNote = 'The Windows Terminal package view did not answer in time.' }
    } catch {
        $packageNote = "The Windows Terminal package view is unavailable: $($_.Exception.Message)"
    } finally {
        # A late script host may still write; clean up only once none is running for this directory.
        $hostDeadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
        while ((ScriptHosts).Count -gt 0 -and [DateTime]::UtcNow -lt $hostDeadline) { Start-Sleep -Milliseconds 250 }
        $cleanup = if ((ScriptHosts).Count -gt 0) { "kept: wscript.exe still running for $scratchName" } else { RemoveScratch }
        # With no answer, the script host may simply not have started yet; it then
        # finds no directory and cannot write. Say so rather than imply a clean finish.
        if ($null -eq $packagePair) { $cleanup += '; no answer, so a script host may still start later' }
    }
    $hkcuAfter = HkcuPair
    if (-not $packageNote -and ($hkcuAfter.console -ne $hkcuPair.console -or $hkcuAfter.terminal -ne $hkcuPair.terminal)) {
        $packageNote = 'The HKCU selection changed while the Windows Terminal package view was read.'
    }
    $selection = Compare-TerminalSelection $hkcuPair $packagePair $packageNote

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
    if ($selection.failure) { $failures += $selection.failure }
    if ($selection.gap) { $gaps += $selection.gap }
    if ($null -eq $probe) { $gaps += 'The probe cmd.exe was not observed.' }
    elseif ($null -eq $owner) { $gaps += 'No top-level window carrying the probe title was found.' }
    elseif ($null -eq $owner.path) { $gaps += "The path of window owner $($owner.name) is unreadable." }
    $gaps += 'Console host ETW has not been evaluated; run -Phase Finalize.'
    if (-not $Evidence) { $Evidence = Join-Path ([IO.Path]::GetTempPath()) "noctty-handoff-$nonce.json" }
    Emit ([ordered]@{ schema = 3; phase = 'Probe'; source = $manifest.source; launcher = $Launcher
        timeZone = [TimeZoneInfo]::Local.Id; hkcuSelection = $hkcuPair; hkcuSelectionAfter = $hkcuAfter
        packageSelection = $packagePair
        packageView = [ordered]@{ state = $selection.state; scratch = $scratch; cleanup = $cleanup }
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
if ($record.schema -ne 3 -or $record.phase -ne 'Probe') { throw 'Not a current probe evidence record.' }
# tracerpt prints the wall clock of the probing host, so read it in the probe's zone.
try { $zone = [TimeZoneInfo]::FindSystemTimeZoneById([string]$record.timeZone) }
catch { throw "The probe time zone '$($record.timeZone)' is unknown here." }
if ($record.source -ne $manifest.source) { throw 'Evidence was produced by a different distribution.' }
$xml = Join-Path ([IO.Path]::GetTempPath()) "noctty-handoff-$($record.nonce).xml"
$null = & tracerpt.exe $TraceFile -o $xml -of XML -y
if ($LASTEXITCODE -ne 0) { throw "tracerpt failed: $LASTEXITCODE" }
$document = New-Object Xml.XmlDocument
$document.Load($xml)
$verdict = Get-HandoffVerdict $record @(Get-HandoffEvents $document $zone) $nocttyTerminal
Emit ([ordered]@{ schema = 3; phase = 'Finalize'; source = $manifest.source; nonce = $record.nonce
    launcher = $record.launcher; probe = $Evidence; trace = $TraceFile; terminalClsids = $verdict.terminalClsids
    windowOwner = $record.windowOwner; failures = $verdict.failures; gaps = $verdict.gaps
    handoffProof = $verdict.handoffProof }) ([IO.Path]::ChangeExtension($Evidence, '.final.json'))
