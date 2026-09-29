# Effectful helper shared by win.ps1 and handoff-proof.ps1; dot-sourcing it only
# defines functions. It reads the default-terminal selection from inside the
# Windows Terminal package, where OpenConsole runs. That context has been
# observed (ETW) to read the durable user hive, while a process in an app's
# registry silo (e.g. an agent sandbox) can see a different local HKCU. It
# writes only its own scratch directory; the script it runs only reads the
# registry and creates no console. Requires Windows PowerShell 5.1 (Appx
# module), Windows Terminal, and Windows Script Host. Compare-TerminalSelection
# comes from handoff-evaluate.ps1.

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
        $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
        while ($null -eq $packagePair -and [DateTime]::UtcNow -lt $deadline) {
            Start-Sleep -Milliseconds 250
            if ([IO.File]::Exists($answer)) { $packagePair = Get-Content -LiteralPath $answer -Raw | ConvertFrom-Json }
        }
        if ($null -eq $packagePair) { $note = 'The Windows Terminal package view did not answer in time.' }
    } catch {
        $note = "The Windows Terminal package view is unavailable: $($_.Exception.Message)"
    } finally {
        # A late script host may still write; clean up only once none is running for this directory.
        $hostDeadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
        while ((ScriptHosts).Count -gt 0 -and [DateTime]::UtcNow -lt $hostDeadline) { Start-Sleep -Milliseconds 250 }
        $cleanup = if ((ScriptHosts).Count -gt 0) { "kept: wscript.exe still running for $scratchName" } else { RemoveScratch }
        # With no answer, the script host may simply not have started yet; it then
        # finds no directory and cannot write. Say so rather than imply a clean finish.
        if ($null -eq $packagePair) { $cleanup += '; no answer, so a script host may still start later' }
    }
    $after = Get-HkcuTerminalSelection
    if (-not $note -and ($after.console -ne $local.console -or $after.terminal -ne $local.terminal)) {
        $note = 'The HKCU selection changed while the Windows Terminal package view was read.'
    }
    $comparison = Compare-TerminalSelection $local $packagePair $note
    [ordered]@{ local = $local; localAfter = $after; package = $packagePair; state = $comparison.state
        failure = $comparison.failure; gap = $comparison.gap; scratch = $scratch; cleanup = $cleanup }
}
