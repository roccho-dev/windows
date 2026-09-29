# Effectful helper shared by win.ps1 and handoff-proof.ps1; dot-sourcing it only
# defines functions. It reads the default-terminal selection from inside the
# Windows Terminal package, where OpenConsole runs. That context has been
# observed (ETW) to read the durable user hive, while a process in an app's
# registry silo (e.g. an agent sandbox) can see a different local HKCU. It
# writes only its own scratch directory; the script it runs there only reads
# the registry. The reader is Windows PowerShell 5.1 hosted by an explicit
# `conhost.exe --headless`: a console started directly under PowerShell is
# handed off to the default terminal (ETW: ConsoleHandoffSessionStarted and a
# Windows Terminal SrvInit_ReceiveHandoff), whereas the headless conhost is its
# own console server, with no window and no handoff (ETW: none of those events).
# Windows Script Host is not used: it may have no script engine. Requires
# Windows PowerShell 5.1 (Appx module) and Windows Terminal.
# Compare-TerminalSelection comes from handoff-evaluate.ps1.

# The reader run inside the package: writes {console, terminal} JSON to -Out,
# via a .partial file renamed into place, so a partial answer is never read.
function Get-PackageReaderScript {
    @'
param([Parameter(Mandatory)][string]$Out)
$ErrorActionPreference = 'Stop'
$key = Get-Item -LiteralPath 'HKCU:\Console\%%Startup' -ErrorAction SilentlyContinue
$pair = [ordered]@{
    console = $(if ($key) { $key.GetValue('DelegationConsole') } else { $null })
    terminal = $(if ($key) { $key.GetValue('DelegationTerminal') } else { $null }) }
[IO.File]::WriteAllText($Out + '.partial', ($pair | ConvertTo-Json -Compress), (New-Object Text.UTF8Encoding $false))
[IO.File]::Move($Out + '.partial', $Out)
'@
}

function Get-HkcuTerminalSelection {
    $key = Get-Item -LiteralPath 'HKCU:\Console\%%Startup' -ErrorAction SilentlyContinue
    [ordered]@{ console = $(if ($key) { $key.GetValue('DelegationConsole') } else { $null })
        terminal = $(if ($key) { $key.GetValue('DelegationTerminal') } else { $null }) }
}

# Reads HKCU, then the package view, then HKCU again, and compares them. A
# change of HKCU in between makes the comparison unavailable.
function Test-PackageTerminalSelection([int]$TimeoutSeconds = 30) {
    $terminalPackage = 'Microsoft.WindowsTerminal_8wekyb3d8bbwe'
    $local = Get-HkcuTerminalSelection
    $packagePair, $note = $null, $null
    # One unique scratch directory directly under the profile: outside AppData
    # (which a package may redirect), OneDrive, and this bundle.
    $userHome = [IO.Path]::GetFullPath($env:USERPROFILE).TrimEnd('\')
    if ((Get-Item -LiteralPath $userHome -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) {
        throw 'The user profile directory is a reparse point.'
    }
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
    $script = Join-Path $scratch 'view.ps1'
    $answer = Join-Path $scratch 'view.json'
    $consoleHost = Join-Path $env:SystemRoot 'System32\conhost.exe'
    $reader = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    # The headless conhost and its PowerShell child both carry the scratch path.
    function ScriptHosts {
        @(Get-CimInstance Win32_Process -Filter "Name = 'conhost.exe' OR Name = 'powershell.exe'" |
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
        $known = @('view.ps1', 'view.json', 'view.json.partial')
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
        [IO.File]::WriteAllText($script, (Get-PackageReaderScript), [Text.UTF8Encoding]::new($true))
        # -ExecutionPolicy applies to this process only; no setting is changed.
        Invoke-CommandInDesktopPackage -PackageFamilyName $terminalPackage -AppId App -Command $consoleHost `
            -Args "--headless `"$reader`" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$script`" -Out `"$answer`""
        # The command returns before the packaged process finishes; wait for its complete file.
        $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
        while ($null -eq $packagePair -and [DateTime]::UtcNow -lt $deadline) {
            Start-Sleep -Milliseconds 250
            if ([IO.File]::Exists($answer)) { $packagePair = Get-Content -LiteralPath $answer -Raw | ConvertFrom-Json }
        }
        if ($null -eq $packagePair) { $note = 'The Windows Terminal package view did not answer in time.' }
    } catch {
        $note = "The Windows Terminal package view is unavailable: $($_.Exception.Message)"
    } finally {
        # A late reader may still write; clean up only once none is running for this directory.
        $hostDeadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
        # @(...) because an empty result unrolls to $null, whose .Count fails under strict mode in 5.1.
        try {
            while (@(ScriptHosts).Count -gt 0 -and [DateTime]::UtcNow -lt $hostDeadline) { Start-Sleep -Milliseconds 250 }
            $cleanup = if (@(ScriptHosts).Count -gt 0) { "kept: reader conhost/powershell still running for $scratchName" } else { RemoveScratch }
        } catch {
            # Without a process listing a late writer cannot be ruled out, so keep the directory.
            $cleanup = "kept: reader processes could not be listed: $($_.Exception.Message)"
        }
        # With no answer, the reader may simply not have started yet; it then
        # finds no directory and cannot write. Say so rather than imply a clean finish.
        if ($null -eq $packagePair) { $cleanup += '; no answer, so a reader may still start later' }
    }
    $after = Get-HkcuTerminalSelection
    if (-not $note -and ($after.console -ne $local.console -or $after.terminal -ne $local.terminal)) {
        $note = 'The HKCU selection changed while the Windows Terminal package view was read.'
    }
    $comparison = Compare-TerminalSelection $local $packagePair $note
    [ordered]@{ local = $local; localAfter = $after; package = $packagePair; state = $comparison.state
        failure = $comparison.failure; gap = $comparison.gap; scratch = $scratch; cleanup = $cleanup }
}
