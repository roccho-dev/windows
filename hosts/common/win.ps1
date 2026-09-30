#requires -Version 5.1
[CmdletBinding()]
param(
    [ValidateSet('Validate', 'Test', 'Apply', 'Restore', 'RestoreTest', 'Uninstall', 'RentSsh', 'RentSshTest')][string]$Mode = 'Validate',
    # RentSsh/RentSshTest only: the live binding, known only after envs and the first rent start. Nothing is guessed.
    [string]$Alias = 'windows-rent',
    [string]$Hostname,
    [string]$HostKey,
    [string]$Identity,
    # Uninstall only: without it Uninstall is a dry run that reads and writes nothing.
    [switch]$Apply
)

# The native Windows activation adapter. Product selection belongs to the built distribution (Nix).
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ($env:OS -ne 'Windows_NT') { throw 'This activation adapter requires Windows.' }
$root = [IO.Path]::GetFullPath($PSScriptRoot) + [IO.Path]::DirectorySeparatorChar
$manifest = Get-Content -LiteralPath (Join-Path $root 'manifest.json') -Raw -Encoding utf8 | ConvertFrom-Json
if ($manifest.schemaVersion -ne 3 -or @($manifest.fonts).Count -eq 0 -or
    @($manifest.packages).Count -eq 0 -or -not $manifest.noctty.version) {
    throw 'Invalid or empty distribution.'
}

function BundlePath([string]$Relative) {
    if ($Relative -match '(^/|\\|:|(^|/)\.\.(/|$))') { throw "Unsafe bundle path: $Relative" }
    $path = [IO.Path]::GetFullPath((Join-Path $root $Relative))
    if (-not $path.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) { throw 'Path escapes bundle.' }
    return $path
}

# The caller verifies the archive checksum before extraction. This inventory
# detects corruption after extraction; it is not a signature or a trust root.
$inventory = @{}
foreach ($entry in $manifest.files.PSObject.Properties) {
    $path = BundlePath $entry.Name
    if ($inventory.ContainsKey($entry.Name)) { throw 'Duplicate bundle path.' }
    $inventory[$entry.Name] = $true
    if (-not (Test-Path -LiteralPath $path -PathType Leaf) -or
        (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ne $entry.Value) {
        throw "Bundle content mismatch: $($entry.Name)"
    }
}
foreach ($file in Get-ChildItem -LiteralPath $root -Recurse -Force) {
    if ($file.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Bundle cannot contain reparse points.' }
    if ($file.PSIsContainer) { continue }
    $relative = $file.FullName.Substring($root.Length).Replace('\', '/')
    if ($relative -ne 'manifest.json' -and -not $inventory.ContainsKey($relative)) { throw "Unlisted bundle file: $relative" }
}
# Function definitions only: the pure evaluators (selection comparison, path
# segments, effect classes) and the package-context reader.
. (BundlePath 'handoff-evaluate.ps1')
. (BundlePath 'package-view.ps1')
$localAppData = [Environment]::GetFolderPath('LocalApplicationData')

# ---- Pinned release-asset packages (manifest schema 3) ----------------------
# nix.nix owns each lock and pack.py validates all of it at build. Here only the
# shape this script reads is checked; it is not a defence, since manifest.json is
# outside the bundle inventory. Paths are relative to %LOCALAPPDATA% with '/'.

function TestWindowsRelative($Path) {
    if ($Path -isnot [string] -or $Path -eq '') { return $false }
    foreach ($segment in $Path.Split('/')) { if (-not (Test-PathSegment $segment)) { return $false } }
    return $true
}

# True when one relative path equals or contains the other, per segment, ignoring case.
function PathsOverlap([string]$One, [string]$Other) {
    $a = $One.ToUpperInvariant().Split('/')
    $b = $Other.ToUpperInvariant().Split('/')
    for ($i = 0; $i -lt [Math]::Min($a.Count, $b.Count); $i++) { if ($a[$i] -cne $b[$i]) { return $false } }
    return $true
}

# What this script reads of one package: name and version (which form the owned
# directory Programs/<name>-<version>), the executable in the pinned inventory,
# the five existing-install identity strings, and the protected paths, all as
# Windows paths; the owned directory may not overlap an unowned path.
function AssertPackageShape($Package) {
    $name, $version, $existing = (Get-Field $Package 'name'), (Get-Field $Package 'version'), (Get-Field $Package 'existing')
    $executable, $files = (Get-Field $Package 'executable'), (ConvertTo-FileMap (Get-Field $Package 'files'))
    $protected = $null  # assigned directly: a function or if-expression would unroll a one-element array
    if ($null -ne $Package.PSObject.Properties['protected']) { $protected = $Package.PSObject.Properties['protected'].Value }
    if ($name -isnot [string] -or $name -cnotmatch '^[A-Za-z0-9][A-Za-z0-9.-]*$' -or
        $version -isnot [string] -or $version -cnotmatch '^[A-Za-z0-9][A-Za-z0-9.-]*$' -or
        (Get-Field $Package 'directory') -cne ('Programs/' + $name.ToLowerInvariant() + '-' + $version) -or
        -not (TestWindowsRelative $executable) -or $null -eq $files -or -not $files.ContainsKey($executable) -or
        @('uninstallKey', 'displayName', 'publisher', 'installLocation', 'executable' |
            Where-Object { (Get-Field $existing $_) -isnot [string] -or (Get-Field $existing $_) -eq '' }).Count -gt 0 -or
        $existing.uninstallKey.Contains('\') -or -not (TestWindowsRelative $existing.installLocation) -or
        -not (TestWindowsRelative $existing.executable) -or $protected -isnot [array] -or
        @($protected | Where-Object { -not (TestWindowsRelative $_) }).Count -gt 0) {
        throw "Invalid package in manifest: $name"
    }
    foreach ($foreign in @($existing.installLocation) + @($protected)) {
        if (PathsOverlap $Package.directory $foreign) { throw "Package directory overlaps an unowned path: $name" }
    }
}

foreach ($package in $manifest.packages) { AssertPackageShape $package }
$packageDirectories = @($manifest.packages | ForEach-Object { $_.directory })
if (@($packageDirectories | Sort-Object -Unique).Count -ne $packageDirectories.Count) { throw 'Duplicate package directory.' }
$protectedPaths = @($manifest.packages | ForEach-Object { @($_.protected) })
# Every current-user location any mode writes stays clear of declared protected
# runtime data (e.g. the synced browser profile), which no mode owns, writes or removes.
foreach ($written in @('Microsoft/Windows/Fonts', 'noctty', ('Programs/noctty-' + $manifest.noctty.version), 'windows-iac') +
        $packageDirectories) {
    foreach ($protected in $protectedPaths) {
        if (PathsOverlap $written $protected) { throw "A written location overlaps protected ${protected}: $written" }
    }
}

# Every Uninstall entry that may be this product, read-only: the declared key name,
# or any key with the declared DisplayName and Publisher, in HKCU and both HKLM
# views. A machine-wide entry counts wherever its InstallLocation points. In an
# app's registry silo (e.g. an agent sandbox) HKCU may be virtualized, as README
# notes for %%Startup; run from an Explorer-launched shell.
function FindUninstallEntries($Existing) {
    $subkey = 'SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'
    foreach ($view in @(@('HKCU', 'CurrentUser', 'Default'), @('HKLM', 'LocalMachine', 'Registry64'),
                        @('HKLM32', 'LocalMachine', 'Registry32'))) {
        $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey($view[1], $view[2])
        try {
            $uninstall = $base.OpenSubKey($subkey)
            if ($null -eq $uninstall) { continue }
            try {
                foreach ($key in $uninstall.GetSubKeyNames()) {
                    $entry = $uninstall.OpenSubKey($key)
                    if ($null -eq $entry) { continue }
                    try {
                        $displayName, $publisher = $entry.GetValue('DisplayName'), $entry.GetValue('Publisher')
                        if ($key -eq $Existing.uninstallKey -or
                            ($displayName -ceq $Existing.displayName -and $publisher -ceq $Existing.publisher)) {
                            [pscustomobject]@{ view = $view[0]; key = $key; displayName = $displayName; publisher = $publisher
                                displayVersion = $entry.GetValue('DisplayVersion'); installLocation = $entry.GetValue('InstallLocation') }
                        }
                    } finally { $entry.Close() }
                }
            } finally { $uninstall.Close() }
        } finally { $base.Close() }
    }
}

# Why one Uninstall entry is not exactly the locked version of this product; none when it is.
# The version is read from the entry's own InstallLocation, not from the lock.
function ExistingProblems($Entry, $Package) {
    $existing = $Package.existing
    if ($Entry.key -ne $existing.uninstallKey) { "key is not $($existing.uninstallKey)" }
    if ($Entry.displayName -cne $existing.displayName) { "DisplayName is '$($Entry.displayName)'" }
    if ($Entry.publisher -cne $existing.publisher) { "Publisher is '$($Entry.publisher)'" }
    if ($Entry.displayVersion -cne $Package.version) { "DisplayVersion is '$($Entry.displayVersion)'" }
    $location = if ($Entry.installLocation -is [string]) {
        [Environment]::ExpandEnvironmentVariables($Entry.installLocation.Trim().Trim('"'))
    } else { '' }
    if (-not $location -or -not [IO.Path]::IsPathRooted($location)) { return 'InstallLocation is missing or not absolute' }
    $executable = Join-Path $location $existing.executable.Replace('/', '\')
    if (-not (Test-Path -LiteralPath $executable -PathType Leaf)) { return "$executable is missing" }
    $productVersion = [string](Get-Item -LiteralPath $executable).VersionInfo.ProductVersion
    if ($productVersion.Trim() -cne $Package.version) { "$executable ProductVersion is '$productVersion'" }
}

# Read-only class of one package: preexisting-match or preexisting-drift whenever
# an Uninstall entry may be this product (never absent then, and nothing is
# written); indeterminate when the owned directory exists without one, since only
# the effect ledger can show who made it; preexisting-drift when any declared
# protected data exists without one (e.g. a profile left by a portable or removed
# install, which an installed build would open); otherwise absent.
function ClassifyPackage($Package) {
    $entries = @(FindUninstallEntries $Package.existing)
    if ($entries.Count) {
        $problems = @(foreach ($entry in $entries) {
            foreach ($problem in @(ExistingProblems $entry $Package)) { "$($entry.view)\$($entry.key): $problem" }
        })
        if ($problems.Count) { return New-EffectClass 'preexisting-drift' $null ($problems -join '; ') }
        return New-EffectClass 'preexisting-match' $null $null
    }
    $target = Join-Path $localAppData $Package.directory.Replace('/', '\')
    if (Test-Path -LiteralPath $target) {
        return New-EffectClass 'indeterminate' $null "$target exists without an Uninstall entry; its owner is unknown without the effect ledger."
    }
    $present = @(@($Package.protected) | Where-Object { Test-Path -LiteralPath (Join-Path $localAppData $_.Replace('/', '\')) })
    if ($present.Count) {
        return New-EffectClass 'preexisting-drift' $null "protected data exists without an Uninstall entry: $($present -join ', ')"
    }
    return New-EffectClass 'absent' $null $null
}

# The clean-install gate. Installing creates an owned tree that only the effect
# ledger can later prove ownership of and remove without recursive deletion, and
# the fetch and extraction path awaits native adapter evidence; neither exists yet.
# So an absent package stops Restore before any download or other effect.
function InstallPackages($Packages) {
    $names = @($Packages | ForEach-Object { "$($_.name) $($_.version)" }) -join ', '
    throw ("Clean install of $names is disabled until the effect ledger is integrated; nothing was downloaded " +
        'or changed. Install it by hand, or wait for the ledger slice.')
}
# Restore is per-user. An elevated token may belong to another account, and
# elevated COM ignores per-user classes, so its activation check could start a
# machine-wide Noctty instead of this user's registration.
if ($Mode -eq 'Restore' -and
    ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run Restore unelevated, from an Explorer-launched shell of the user being restored.'
}
$fontDirectory = Join-Path $localAppData 'Microsoft\Windows\Fonts'
$nocttyDirectory = Join-Path $localAppData ('Programs\noctty-' + $manifest.noctty.version)
$nocttyConfig = Join-Path $localAppData 'noctty\config.ghostty'
# Never created, written or removed; Uninstall only reports whether one exists.
$nocttyShortcut = Join-Path ([Environment]::GetFolderPath('StartMenu')) 'Programs\noctty.lnk'
$nocttyConfigText = 'font-family = ' + $manifest.noctty.fontFamily + "`n"
$terminalStartup = 'HKCU:\Console\%%Startup'
$startupSubkey = 'Console\%%Startup'
$registryViews = @(@('HKCU', 'CurrentUser', 'Default'), @('HKLM', 'LocalMachine', 'Registry64'), @('HKLM32', 'LocalMachine', 'Registry32'))
$windowsTerminalConsole = '{2EACA947-7F5F-4CFA-BA87-8F7FBEEFBE69}'
$nocttyTerminal = '{33368C6F-D328-410C-B225-26DC9F12C728}'
# The six HKCU COM values the handoff needs, from Nix, with {install} bound to this user's directory.
$nocttyRegistration = Get-NocttyRegistration (Get-Field $manifest.noctty 'registration') $nocttyDirectory $manifest.noctty.files
if ($nocttyRegistration.problem) { throw "Invalid Noctty registration in manifest: $($nocttyRegistration.problem)" }
$terminalProvenance = Join-Path $localAppData 'windows-iac\provenance\default-terminal.json'
$packageStates = @()

if ($Mode -eq 'RentSsh' -or $Mode -eq 'RentSshTest') {
    # Windows OpenSSH to the rent through Cloudflare Access: the pinned client as ProxyCommand, strict host checking
    # against the explicitly bound rent host key. Only RentSsh writes; Restore never touches SSH configuration.
    if ($Alias -notmatch '^[a-z0-9][a-z0-9-]*$') { throw 'Invalid alias.' }
    if ($Hostname -notmatch '^(?=.{1,253}$)[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+$') { throw 'Invalid hostname.' }
    if ($HostKey -notmatch '^ssh-ed25519 [A-Za-z0-9+/]+={0,2}$') { throw 'Invalid host key: one ssh-ed25519 public key is required.' }
    if (-not $Identity -or $Identity -match '["\r\n]' -or -not (Test-Path -LiteralPath $Identity -PathType Leaf)) { throw 'Invalid identity: an existing key file is required.' }
    $client = $manifest.cloudflared
    if ($client.version -notmatch '^[0-9.]+$' -or $client.file -ne 'payload/cloudflared.exe' -or
        -not $inventory.ContainsKey($client.file) -or $manifest.files.($client.file) -ne $client.sha256) {
        throw 'Invalid cloudflared payload.'
    }
    $clientDirectory = Join-Path $localAppData ('Programs\cloudflared-' + $client.version)
    $clientExe = Join-Path $clientDirectory 'cloudflared.exe'
    $sshDirectory = Join-Path $env:USERPROFILE '.ssh'
    $rentDirectory = Join-Path $sshDirectory 'windows-rent'
    $rentConfig = Join-Path $rentDirectory 'config'
    $rentKnownHosts = Join-Path $rentDirectory 'known_hosts'
    $userConfig = Join-Path $sshDirectory 'config'
    $userBackup = Join-Path $sshDirectory 'config.before-windows-rent'
    $include = 'Include windows-rent/config'
    $utf8 = [Text.UTF8Encoding]::new($false)
    $configText = (@(
        "Host $Alias",
        "  HostName $Hostname",
        '  User dev',
        "  ProxyCommand `"$clientExe`" access ssh --hostname %h",
        "  IdentityFile `"$Identity`"",
        '  IdentitiesOnly yes',
        "  HostKeyAlias $Alias",
        '  StrictHostKeyChecking yes',
        "  UserKnownHostsFile `"$rentKnownHosts`"",
        '  UpdateHostKeys no') -join "`n") + "`n"
    $knownText = "$Alias $HostKey`n"
    function ClientOk {
        (Test-Path -LiteralPath $clientExe -PathType Leaf) -and (Get-FileHash -LiteralPath $clientExe -Algorithm SHA256).Hash -eq $client.sha256
    }
    function TextIs([string]$Path, [string]$Text) {
        (Test-Path -LiteralPath $Path -PathType Leaf) -and [IO.File]::ReadAllText($Path) -ceq $Text
    }
    # The Include must be the first line: an Include after a Host block would only apply inside that block.
    function IncludeState {
        if (-not (Test-Path -LiteralPath $userConfig -PathType Leaf)) { return 'absent' }
        $bytes = [IO.File]::ReadAllBytes($userConfig)
        if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) { return 'bom' }
        $lines = @([IO.File]::ReadAllText($userConfig) -split "`r?`n")
        if ($lines[0] -ceq $include) { return 'first' }
        if (@($lines | Where-Object { $_.Trim() -ceq $include }).Count) { return 'elsewhere' }
        return 'missing'
    }
    if ($Mode -eq 'RentSsh') {
        $state = IncludeState
        if ($state -eq 'bom') { throw "$userConfig starts with a byte order mark; not editing it." }
        if ($state -eq 'elsewhere') { throw "$userConfig has '$include' below its first line; move it to the top by hand." }
        # Every refusal comes before the first write: a stale backup must not leave a half-installed client behind.
        if ($state -eq 'missing' -and (Test-Path -LiteralPath $userBackup)) { throw "$userBackup already exists; not overwriting it." }
        if (-not (ClientOk)) {
            $null = New-Item -ItemType Directory -Path $clientDirectory -Force
            Copy-Item -LiteralPath (BundlePath $client.file) -Destination $clientExe -Force
            if (-not (ClientOk)) { throw 'cloudflared.exe differs after copy.' }
        }
        $null = New-Item -ItemType Directory -Path $rentDirectory -Force
        if (-not (TextIs $rentConfig $configText)) { [IO.File]::WriteAllText($rentConfig, $configText, $utf8) }
        if (-not (TextIs $rentKnownHosts $knownText)) { [IO.File]::WriteAllText($rentKnownHosts, $knownText, $utf8) }
        if ($state -ne 'first') {
            # One line before the exact prior bytes; the prior bytes are kept once, beside it, and never overwritten.
            $prior = if ($state -eq 'missing') { [IO.File]::ReadAllBytes($userConfig) } else { [byte[]]@() }
            if ($state -eq 'missing') { [IO.File]::WriteAllBytes($userBackup, $prior) }
            $null = New-Item -ItemType Directory -Path $sshDirectory -Force
            [IO.File]::WriteAllBytes($userConfig, [byte[]]($utf8.GetBytes($include + "`n") + $prior))
        }
    }
    $drift = @()
    if (-not (ClientOk)) { $drift += 'cloudflared.exe' }
    if (-not (TextIs $rentConfig $configText)) { $drift += $rentConfig }
    if (-not (TextIs $rentKnownHosts $knownText)) { $drift += $rentKnownHosts }
    if ((IncludeState) -ne 'first') { $drift += "$userConfig first line" }
    if ($drift) { throw "RentSsh drift: $($drift -join ', ')" }
    [ordered]@{ mode = $Mode; source = $manifest.source; alias = $Alias; hostname = $Hostname; cloudflared = $client.version;
        client = $clientExe; config = $rentConfig; knownHosts = $rentKnownHosts; userConfig = $userConfig;
        inDesiredState = $true } | ConvertTo-Json -Compress
    return
}

# Registration only: the registry state that selects Noctty. It is not evidence
# that a new console is handed off to Noctty; only handoff-proof.ps1 on a real
# interactive host can produce that evidence.
function TestNocttyRegistration {
    $startup = Get-Item -LiteralPath $terminalStartup -ErrorAction SilentlyContinue
    if ($null -eq $startup -or
        $startup.GetValue('DelegationConsole') -ne $windowsTerminalConsole -or
        $startup.GetValue('DelegationTerminal') -ne $nocttyTerminal) { return $false }
    # Each manifest value as a REG_SZ; data compares ignoring case, as Windows paths and COM do.
    foreach ($value in $nocttyRegistration.values) {
        $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($value.key)
        if ($null -eq $key) { return $false }
        try {
            if ($key.GetValueNames() -notcontains $value.name -or [string]$key.GetValueKind($value.name) -cne 'String' -or
                $key.GetValue($value.name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames) -ne $value.data) {
                return $false
            }
        } finally { $key.Close() }
    }
    return $true
}

# Windows Terminal is OS/Store-owned and not installed here; its OpenConsole is
# Noctty's console half, so only a minimum version is asserted.
function TestTerminalPackage {
    $terminal = Get-AppxPackage -Name Microsoft.WindowsTerminal | Select-Object -First 1
    return $null -ne $terminal -and [version]$terminal.Version -ge [version]'1.24.0.0'
}

# Write-once record of the terminal selection before this distribution first
# changed it, for a later rollback. An existing record is never replaced, and an
# unreadable one stops Restore rather than risk losing the original selection.
function RecordPriorTerminal([object]$Console, [object]$Terminal) {
    if (Test-Path -LiteralPath $terminalProvenance) {
        try { $prior = Get-Content -LiteralPath $terminalProvenance -Raw -Encoding utf8 | ConvertFrom-Json }
        catch { $prior = $null }
        if ($null -eq $prior -or $prior.schema -ne 1 -or $prior.key -ne 'HKCU\Console\%%Startup') {
            throw "Unreadable default-terminal provenance: $terminalProvenance"
        }
        return
    }
    $json = [ordered]@{ schema = 1; key = 'HKCU\Console\%%Startup'; recordedUtc = [DateTime]::UtcNow.ToString('o')
        source = $manifest.source; priorDelegationConsole = $Console; priorDelegationTerminal = $Terminal
        # True when Noctty was already selected, so the true original is unknown.
        priorSelectsNoctty = ($Terminal -eq $nocttyTerminal)
        written = [ordered]@{ DelegationConsole = $windowsTerminalConsole; DelegationTerminal = $nocttyTerminal } } |
        ConvertTo-Json
    $null = New-Item -ItemType Directory -Path (Split-Path -Parent $terminalProvenance) -Force
    $temporary = $terminalProvenance + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
    try {
        [IO.File]::WriteAllText($temporary, $json, [Text.UTF8Encoding]::new($false))
        [IO.File]::Move($temporary, $terminalProvenance)  # fails rather than overwrite
    } finally { Remove-Item -LiteralPath $temporary -ErrorAction SilentlyContinue }
}

# OpenConsole reads the selection inside the Windows Terminal package. A process
# in an app's registry silo (e.g. an agent sandbox) can see and write a local
# HKCU that the package, and so the handoff, never sees. Unavailable or differing
# views fail; nothing here writes the registry.
function AssertActualSelection {
    $view = Test-PackageTerminalSelection
    if ($view.state -ne 'match') {
        throw ("The default-terminal selection is not confirmed from the Windows Terminal package ($($view.state)): " +
            "$($view.failure)$($view.gap) Scratch cleanup: $($view.cleanup)")
    }
}

# Starts the Noctty COM server, so only Restore calls it, right after registering,
# to reject an unusable registration. Activation still does not prove handoff.
function TestNocttyActivation {
    try {
        $class = [type]::GetTypeFromCLSID([guid]$nocttyTerminal, $true)
        $instance = [Activator]::CreateInstance($class)
        $null = [Runtime.InteropServices.Marshal]::ReleaseComObject($instance)
        return $true
    } catch { return $false }
}

# ---- Effect ledger: owned fonts --------------------------------------------
# Each record is one file, windows-iac\ledger\<seq:D8>.json, created with
# CreateNew + WriteThrough + Flush(true) while ledger\.lock is held (CreateNew, no
# sharing, deleted when its handle closes). An intent is flushed before its effect
# and a commit or closing record after it, so the only record a crash can tear is
# the highest seq, and every mode that reads the ledger stops on it (README). The
# ledger and provenance directories are retained state, not effects. This version
# owns only what it created (the prior is always absent): font files beneath the
# user font directory and their HKCU Fonts values, and the Noctty tree, configuration,
# %%Startup key and COM keys and values. The %%Startup selection values belong to the
# older default-terminal record (RecordPriorTerminal), not to the ledger.
$ledgerDirectory = Join-Path $localAppData 'windows-iac\ledger'
$fontSubkey = 'Software\Microsoft\Windows NT\CurrentVersion\Fonts'
$fontKey = 'HKCU\' + $fontSubkey
$script:ledgerRecords, $script:nextSeq, $script:ledgerLock = @(), 1, $null
$script:copied, $script:changed, $script:removed, $script:recordsWritten = 0, 0, 0, 0
$script:fontDrift, $script:sharedCreated, $script:gcKeptReferenced, $script:nocttyDrift = @(), @(), @(), @()

function ReadLedger {
    $script:ledgerRecords, $script:nextSeq = @(), 1
    if (-not (Test-Path -LiteralPath $ledgerDirectory -PathType Container)) { return $false }
    foreach ($item in @(Get-ChildItem -LiteralPath $ledgerDirectory -Force)) {
        if ($item.Name -ceq '.lock' -and -not $item.PSIsContainer) { continue }
        if ($item.PSIsContainer -or $item.Name -cnotmatch '^[0-9]{8}\.json$') { throw "Unexpected entry in the effect ledger: $($item.FullName)" }
        $seq = [long]$item.Name.Substring(0, 8)
        $record = $null
        try { $record = [IO.File]::ReadAllText($item.FullName) | ConvertFrom-Json } catch { $record = $null }
        if ($null -eq $record -or (Get-Field $record 'seq') -ne $seq) {
            throw "Torn or unreadable ledger record $($item.FullName). Only the highest-seq record, and only if it does not parse as JSON, may be removed by hand (README)."
        }
        $script:ledgerRecords += $record
        if ($seq -ge $script:nextSeq) { $script:nextSeq = $seq + 1 }
    }
    return $true
}

function LockLedger {
    $null = New-Item -ItemType Directory -Path $ledgerDirectory -Force
    $lock = Join-Path $ledgerDirectory '.lock'
    try {
        $script:ledgerLock = [IO.FileStream]::new($lock, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write,
            [IO.FileShare]::None, 1, [IO.FileOptions]::DeleteOnClose)
    } catch {
        throw "Another run holds the effect ledger lock $lock (a power loss can leave it; remove it by hand only when no run is active)."
    }
}

# Appends one record for an effect: intent (with the temporary path it will use,
# named before that file exists), commit, void or undone (with the observed state).
# The pure checks refuse a malformed record, including an observation that is not
# the desired (commit) or prior (void, undone) state.
function WriteRecord([string]$Phase, $Effect, $Observed, [string]$Temp) {
    $entry = [ordered]@{ ledger = 'effects'; schema = 1; seq = $script:nextSeq; phase = $Phase
        id = Get-Field $Effect 'id'; kind = Get-Field $Effect 'kind'; target = Get-Field $Effect 'target' }
    if ($entry.kind -ceq 'registry-value') { $entry.name = Get-Field $Effect 'name' }
    $entry.prior, $entry.desired = (Get-Field $Effect 'prior'), (Get-Field $Effect 'desired')
    if ($Phase -cne 'intent') { $entry.observed = $Observed }
    if ($Temp) { $entry.temp = $Temp }
    $entry.utc, $entry.source, $entry.mode = [DateTime]::UtcNow.ToString('o'), $manifest.source, $Mode
    $problem = Get-EffectRecordProblem $entry
    if ($problem) { throw "Refusing to write a malformed ledger record for $($entry.id): $problem" }
    $json = $entry | ConvertTo-Json -Depth 8 -Compress
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes($json)
    $path = Join-Path $ledgerDirectory ('{0:D8}.json' -f $script:nextSeq)
    $stream = [IO.FileStream]::new($path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None,
        4096, [IO.FileOptions]::WriteThrough)
    try { $stream.Write($bytes, 0, $bytes.Length); $stream.Flush($true) } finally { $stream.Dispose() }
    $script:ledgerRecords += ($json | ConvertFrom-Json)
    $script:nextSeq++
    $script:recordsWritten++
}

function FileEffect([string]$Path, [string]$Sha) {
    [ordered]@{ id = 'file-created:' + $Path.ToUpperInvariant(); kind = 'file-created'; target = $Path
        prior = [ordered]@{ exists = $false }; desired = [ordered]@{ exists = $true; sha256 = $Sha.ToLowerInvariant() } }
}

function ValueEffect([string]$Name, [string]$Data, [string]$Key = $fontKey) {
    [ordered]@{ id = 'registry-value:' + ($Key + '|' + $Name).ToUpperInvariant(); kind = 'registry-value'
        target = $Key; name = $Name
        prior = [ordered]@{ exists = $false }; desired = [ordered]@{ exists = $true; type = 'String'; data = $Data } }
}

function ObserveFile([string]$Path) {
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if ($null -eq $item) { return [ordered]@{ exists = $false } }
    if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw "Not a regular file: $Path" }
    [ordered]@{ exists = $true; sha256 = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }
}

# A value exactly as stored: its kind and its data without environment expansion.
function ObserveValue([string]$Name, [string]$Subkey = $fontSubkey) {
    $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($Subkey)
    if ($null -eq $key) { return [ordered]@{ exists = $false } }
    try {
        if ($key.GetValueNames() -notcontains $Name) { return [ordered]@{ exists = $false } }
        return [ordered]@{ exists = $true; type = [string]$key.GetValueKind($Name)
            data = $key.GetValue($Name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames) }
    } finally { $key.Close() }
}

# ---- Owned Noctty effects (E1, E2, E4-E6): built and observed here, converged by PlanNoctty/ApplyNoctty ----
function KeyEffect([string]$Subkey) {
    $target = 'HKCU\' + $Subkey
    [ordered]@{ id = 'registry-key-created:' + $target.ToUpperInvariant(); kind = 'registry-key-created'; target = $target
        prior = [ordered]@{ exists = $false }; desired = [ordered]@{ exists = $true } }
}

# The versioned tree with its exact inventory, the font configuration, the %%Startup key, the
# keys derived from the registration (parents first; never the shared CLSID and Interface
# roots) and its six values. Which of them this user owns is decided when they are classified.
function NocttyEffects {
    $files = @{}
    foreach ($entry in $manifest.noctty.files.PSObject.Properties) { $files[$entry.Name] = ([string]$entry.Value).ToLowerInvariant() }
    $config = [Security.Cryptography.SHA256]::Create().ComputeHash([Text.UTF8Encoding]::new($false).GetBytes($nocttyConfigText))
    [ordered]@{
        tree = [ordered]@{ id = 'tree-extracted:' + $nocttyDirectory.ToUpperInvariant(); kind = 'tree-extracted'; target = $nocttyDirectory
            prior = [ordered]@{ exists = $false }; desired = [ordered]@{ exists = $true; files = $files } }
        config = FileEffect $nocttyConfig (-join ($config | ForEach-Object { $_.ToString('x2') }))
        startup = KeyEffect 'Console\%%Startup'
        keys = @($nocttyRegistration.keys | ForEach-Object { KeyEffect $_ })
        values = @($nocttyRegistration.values | ForEach-Object { ValueEffect $_.name $_.data ('HKCU\' + $_.key) })
    }
}

# A tree exactly as it is, never following a reparse point: files maps each regular file's
# '/'-path to its sha256, and other lists every reparse point, unsafe or case-repeated name and
# directory with no file beneath it, so any of them makes the tree differ from an inventory.
# -Entries lists every entry instead, as { path; directory; reparse } (Get-StagingCleanupSteps).
function ObserveTree([string]$Path, [switch]$Entries) {
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if ($null -eq $item) { if ($Entries) { return } else { return [ordered]@{ exists = $false } } }
    if (-not $item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw "Not a plain directory: $Path" }
    $files, $other, $directories, $parents, $listed = @{}, @(), @(), @{}, @()
    $pending = [Collections.Generic.Stack[IO.DirectoryInfo]]::new()
    $pending.Push($item)
    while ($pending.Count) {
        foreach ($entry in $pending.Pop().GetFileSystemInfos()) {
            $relative = $entry.FullName.Substring($item.FullName.Length + 1).Replace('\', '/')
            $listed += [ordered]@{ path = $relative; directory = $entry -is [IO.DirectoryInfo]
                reparse = [bool]($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) }
            if (($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $files.ContainsKey($relative) -or
                @($relative.Split('/') | Where-Object { -not (Test-PathSegment $_) }).Count) { $other += $relative }
            elseif ($entry -is [IO.DirectoryInfo]) { $directories += $relative; $pending.Push($entry) }
            else {
                $files[$relative] = (Get-FileHash -LiteralPath $entry.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
                $parts = $relative.Split('/')
                for ($i = 1; $i -lt $parts.Count; $i++) { $parents[$parts[0..($i - 1)] -join '/'] = $true }
            }
        }
    }
    if ($Entries) { return $listed }
    $other += @($directories | Where-Object { -not $parents.ContainsKey($_) } | ForEach-Object { "$_/" })
    [ordered]@{ exists = $true; files = $files; other = $other }
}

function ObserveKey([string]$Subkey) {
    $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($Subkey)
    if ($null -eq $key) { return [ordered]@{ exists = $false } }
    $key.Close()
    [ordered]@{ exists = $true }
}

# The current state of one selected Noctty effect, or of the tree of any Noctty version (an
# owned older one must stay readable for collection and Uninstall); anything else stops the run.
function ObserveNoctty($Effect) {
    $kind, $target, $name = [string](Get-Field $Effect 'kind'), [string](Get-Field $Effect 'target'), (Get-Field $Effect 'name')
    $selected = NocttyEffects
    $subkey = $target -replace '^HKCU\\', ''
    $leaf = [IO.Path]::GetFileName($target)
    if ($kind -ceq 'tree-extracted' -and [IO.Path]::GetDirectoryName($target) -eq (Join-Path $localAppData 'Programs') -and
        $leaf -cmatch '^noctty-[A-Za-z0-9][A-Za-z0-9.-]*$' -and (Test-PathSegment $leaf)) { return ObserveTree $target }
    if ($kind -ceq 'file-created' -and $target -eq $selected.config.target) { return ObserveFile $target }
    if ($kind -ceq 'registry-key-created' -and @(@($selected.startup) + $selected.keys | Where-Object { $_.target -eq $target }).Count) {
        return ObserveKey $subkey
    }
    if ($kind -ceq 'registry-value' -and @($selected.values | Where-Object { $_.target -eq $target -and $_.name -eq $name }).Count) {
        return ObserveValue $name $subkey
    }
    throw "$kind $target is not a selected Noctty effect."
}

# The COM server paths that may name a Noctty tree, for Get-TreeReferenceProblem: the default
# value of each of $Subkeys (the LocalServer32 and InprocServer32 keys) in each of $Views
# (@(label, hive, view)), as { label; id; data }; in HKCU, id is the owning value effect's.
function NocttyReferences($Views, [string[]]$Subkeys) {
    foreach ($view in @($Views)) {
        $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey($view[1], $view[2])
        try {
            foreach ($subkey in $Subkeys) {
                $key = $base.OpenSubKey($subkey)
                if ($null -eq $key) { continue }
                try {
                    if ($key.GetValueNames() -notcontains '') { continue }
                    [pscustomobject]@{ label = "$($view[0])\$subkey"; data = [string]$key.GetValue('', $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
                        id = $(if ($view[0] -ceq 'HKCU') { 'registry-value:' + "HKCU\$subkey|".ToUpperInvariant() } else { $null }) }
                } finally { $key.Close() }
            }
        } finally { $base.Close() }
    }
}

# The current state of a recorded or selected effect: an owned font file or HKCU Fonts value,
# or a Noctty effect (ObserveNoctty). Anything else is outside this version and stops the run.
function Observe($Effect) {
    $kind, $target = [string](Get-Field $Effect 'kind'), [string](Get-Field $Effect 'target')
    if ($kind -ceq 'file-created' -and [IO.Path]::GetDirectoryName($target) -eq $fontDirectory -and
        [IO.Path]::GetFileName($target) -match '^[0-9a-f]{64}\.ttf$') { return ObserveFile $target }
    if ($kind -ceq 'registry-value' -and $target -eq $fontKey) { return ObserveValue ([string](Get-Field $Effect 'name')) }
    if ($kind -cne 'file-created' -or $target -eq $nocttyConfig) { return ObserveNoctty $Effect }
    throw "The effect ledger holds $kind $target, which this version (owned fonts only) does not handle."
}

function LedgerIds {
    $ids = @($script:ledgerRecords | ForEach-Object { [string](Get-Field $_ 'id') } | Sort-Object -Unique -CaseSensitive)
    if (@($ids | Sort-Object -Unique).Count -ne $ids.Count) { throw 'Two effect ledger ids differ only in case.' }
    return $ids
}

function RecordsOf([string]$Id) { @($script:ledgerRecords | Where-Object { [string](Get-Field $_ 'id') -ceq $Id }) }

# The open attempt of an id (its records), or an empty list.
function OpenAttempt([string]$Id) {
    $attempt = Get-EffectAttempt (RecordsOf $Id)
    if ($attempt.problem) { throw "Effect ledger id ${Id}: $($attempt.problem)" }
    if ($attempt.closed) { return @() }
    $open = @($attempt.records)
    if ($open.Count -and (Get-Field (Get-Field $open[0] 'prior') 'exists')) {
        throw "Effect ledger id $Id owns a target that existed before; this version owns only what it created."
    }
    return $open
}

# The temporary path an intent named before creating it, beside its target as
# <target>.<guid32>.tmp (a file) or .staging (a tree); only such a path is ever removed.
function IntentTemp($Record) {
    $problem = Get-IntentTempProblem $Record
    if ($problem) { throw "A ledger intent names an invalid temporary path: $problem" }
    return Get-Field $Record 'temp'
}

# Removes what an interrupted tree intent left in its own staging directory, one file or empty
# directory at a time, only while every entry there belongs to its inventory; otherwise it stops.
function CleanStaging($Intent) {
    $staging = [string](IntentTemp $Intent)
    $cleanup = Get-StagingCleanupSteps $Intent @(ObserveTree $staging -Entries)
    if (-not $cleanup.ok) { throw "Staging directory $staging is kept: $($cleanup.reason)" }
    foreach ($step in $cleanup.steps) {
        if ($step.action -ceq 'delete-file') { [IO.File]::Delete($step.path) } else { [IO.Directory]::Delete($step.path, $false) }
    }
}

# Closes or confirms an open attempt: first the temporary files or staging directories its
# own intents named, then a commit, void or undone record carrying the observed state.
function ResolveAttempt($Open, [string]$Phase) {
    foreach ($intent in @($Open | Where-Object { (Get-Field $_ 'phase') -ceq 'intent' })) {
        $temp = IntentTemp $intent
        if (-not $temp -or -not (Test-Path -LiteralPath $temp)) { continue }
        if ((Get-Field $intent 'kind') -ceq 'tree-extracted') { CleanStaging $intent }
        elseif (Test-Path -LiteralPath $temp -PathType Leaf) { [IO.File]::Delete($temp) }
    }
    WriteRecord $Phase $Open[0] (Observe $Open[0])
}

# Recovery of one id: an interrupted intent that took effect is committed, one
# that did not is voided, and a committed effect found reverted is closed undone.
# An attempt left in neither state stops the run.
function RecoverId([string]$Id) {
    $open = @(OpenAttempt $Id)
    if (-not $open.Count) { return }
    $class = Get-EffectClass (RecordsOf $Id) (Observe $open[0])
    if ($class.class -ceq 'indeterminate') { throw "Effect ledger id $Id is indeterminate: $($class.reason)" }
    if ($class.resolution) { ResolveAttempt $open ($(if ($class.resolution -ceq 'confirm') { 'commit' } else { $class.resolution })) }
}

function RecoverLedger { foreach ($id in @(LedgerIds)) { RecoverId $id } }

# Every Fonts value that names a file, in HKCU and both HKLM views, resolved to a
# full path (a bare file name is under %WINDIR%\Fonts). $Excluded are HKCU value
# names about to be removed, which no longer count.
function FontReferenceTable($Excluded) {
    $windowsFonts = Join-Path $env:SystemRoot 'Fonts'
    foreach ($view in @(@('HKCU', 'CurrentUser', 'Default'), @('HKLM', 'LocalMachine', 'Registry64'),
                        @('HKLM32', 'LocalMachine', 'Registry32'))) {
        $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey($view[1], $view[2])
        try {
            $key = $base.OpenSubKey($fontSubkey)
            if ($null -eq $key) { continue }
            try {
                foreach ($name in $key.GetValueNames()) {
                    if ($view[0] -ceq 'HKCU' -and @($Excluded) -contains $name) { continue }
                    $data = $key.GetValue($name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
                    if ($data -isnot [string] -or -not $data.Trim()) { continue }
                    $path = [Environment]::ExpandEnvironmentVariables($data.Trim().Trim('"'))
                    try {
                        if (-not [IO.Path]::IsPathRooted($path)) { $path = Join-Path $windowsFonts $path }
                        $path = [IO.Path]::GetFullPath($path)
                    } catch { continue }
                    [pscustomobject]@{ label = "$($view[0]) Fonts\$name"; path = $path }
                }
            } finally { $key.Close() }
        } finally { $base.Close() }
    }
}

# The values that refer to a font file: by path (case-insensitive), or through any
# other name for the same bytes (8.3 name, junction, hard link, copy), seen as an
# existing file of the same length and SHA-256. Content-addressed names make the
# second test err only towards keeping a file.
function FontReferences($Table, [string]$Path, [string]$Sha) {
    $length = (Get-Item -LiteralPath $Path -Force).Length
    foreach ($reference in @($Table)) {
        if ($reference.path -eq $Path) { $reference.label; continue }
        $item = Get-Item -LiteralPath $reference.path -Force -ErrorAction SilentlyContinue
        if ($null -ne $item -and -not $item.PSIsContainer -and $item.Length -eq $length -and
            (Get-FileHash -LiteralPath $reference.path -Algorithm SHA256).Hash -eq $Sha) { $reference.label }
    }
}

# Removes one owned file, value or created key only while it is exactly $Expect, and
# (unless the same path is about to be recreated, -Replacing) a file only while no Fonts
# value refers to it; a key only while it holds nothing (plan-time A3 decides first; this
# is the backstop). Never recursively, never deferred.
function RemoveTarget($Effect, $Expect, [switch]$Replacing) {
    $kind, $target = [string](Get-Field $Effect 'kind'), [string](Get-Field $Effect 'target')
    $current = Observe $Effect
    if (-not (Test-EffectStateEqual $kind $Expect $current)) { throw "Refusing to remove $(Get-Field $Effect 'id'): it changed since it was read." }
    $subkey = $target -replace '^HKCU\\', ''
    if ($kind -ceq 'registry-key-created') {
        $split = $subkey.LastIndexOf('\')
        $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($subkey)
        if ($null -eq $key) { throw "Refusing to remove ${target}: it disappeared since it was read." }
        try { if ($key.ValueCount + $key.SubKeyCount) { throw "Refusing to remove ${target}: it holds foreign content." } } finally { $key.Close() }
        $parent = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($subkey.Substring(0, $split), $true)
        try { $parent.DeleteSubKey($subkey.Substring($split + 1), $false) } finally { $parent.Close() }
    } elseif ($kind -ceq 'file-created') {
        if (-not $Replacing) {
            $references = @(FontReferences @(FontReferenceTable @()) $target $current.sha256)
            if ($references.Count) { throw "Refusing to remove ${target}: referenced by $($references -join ', ')." }
        }
        try { [IO.File]::Delete($target) } catch { throw "Could not remove $target (in use?): $($_.Exception.Message)" }
    } else {
        $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($subkey, $true)
        try { $key.DeleteValue([string](Get-Field $Effect 'name')) } finally { $key.Close() }
    }
    $script:removed++
}

# Reverts an owned effect (its open attempt) from the state $Expect and closes it.
# A crash between the two leaves a committed attempt whose target equals its
# prior, which recovery closes undone.
function UndoOwned($Open, $Expect, [switch]$Replacing) {
    RemoveTarget $Open[0] $Expect -Replacing:$Replacing
    WriteRecord 'undone' $Open[0] (Observe $Open[0])
}

# Runs the effect of an intent just written; on failure the id is recovered at once when it can be.
function Recovering($Effect, [scriptblock]$Act) {
    try { & $Act } catch {
        $failure = $_
        try { RecoverId $Effect.id } catch { Write-Warning "Recovery of $($Effect.id) deferred: $($_.Exception.Message)" }
        throw $failure
    }
}

# Creates an absent file from a path or bytes: intent (naming its temporary file), a new
# temporary file written through and flushed, a rename that fails if the target exists, and the commit.
function CreateOwnedFile($Effect, $Source) {
    $temp = $Effect.target + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
    WriteRecord 'intent' $Effect $null $temp
    Recovering $Effect {
        $in = if ($Source -is [byte[]]) { [IO.MemoryStream]::new($Source) } else { [IO.File]::OpenRead($Source) }
        try {
            $out = [IO.FileStream]::new($temp, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None,
                65536, [IO.FileOptions]::WriteThrough)
            try { $in.CopyTo($out); $out.Flush($true) } finally { $out.Dispose() }
        } finally { $in.Dispose() }
        [IO.File]::Move($temp, $Effect.target)
        WriteRecord 'commit' $Effect (ObserveFile $Effect.target)
        $script:copied++
    }
}

# Writes a String value into its existing HKCU key (the effect's target).
function CreateOwnedValue($Effect) {
    $subkey = $Effect.target -replace '^HKCU\\', ''
    WriteRecord 'intent' $Effect $null $null
    Recovering $Effect {
        $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($subkey, $true)
        if ($null -eq $key) { throw "Key $($Effect.target) is missing." }
        try { $key.SetValue($Effect.name, $Effect.desired.data, [Microsoft.Win32.RegistryValueKind]::String) } finally { $key.Close() }
        WriteRecord 'commit' $Effect (ObserveValue $Effect.name $subkey)
        $script:changed++
    }
}

# Creates one absent HKCU key beneath an existing parent. The parent is opened, never created,
# so no shared parent is made implicitly; both are checked before the intent.
function CreateOwnedKey($Effect) {
    $subkey = $Effect.target -replace '^HKCU\\', ''
    $split = $subkey.LastIndexOf('\')
    $parent = if ($split -gt 0) { [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($subkey.Substring(0, $split), $true) }
    if ($null -eq $parent) { throw "Refusing to create $($Effect.target): its parent key is missing." }
    try {
        if ((ObserveKey $subkey).exists) { throw "Refusing to create $($Effect.target): it exists." }
        WriteRecord 'intent' $Effect $null $null
        Recovering $Effect {
            $parent.CreateSubKey($subkey.Substring($split + 1)).Close()
            WriteRecord 'commit' $Effect (ObserveKey $subkey)
            $script:changed++
        }
    } finally { $parent.Close() }
}

# Creates an absent tree beneath an existing parent from a ZIP archive. Every entry name is
# checked against the inventory before anything is written; the files go into a new staging
# directory the intent names, which must then hold exactly the inventory, and one rename on the
# same volume (failing if the target exists) makes it the target before the commit.
function CreateOwnedTree($Effect, [string]$Zip) {
    Add-Type -AssemblyName System.IO.Compression
    $target = $Effect.target
    if (-not (Test-Path -LiteralPath (Split-Path -Parent $target) -PathType Container)) { throw "Refusing to create ${target}: its parent is missing." }
    if ((ObserveTree $target).exists) { throw "Refusing to create ${target}: it exists." }
    $stream = [IO.File]::OpenRead($Zip)
    try {
        $archive = [IO.Compression.ZipArchive]::new($stream, [IO.Compression.ZipArchiveMode]::Read)
        try {
            $problem = Get-ZipEntryProblem @($archive.Entries | ForEach-Object { $_.FullName }) $Effect.desired.files
            if ($problem) { throw "Refusing to extract ${Zip}: $problem" }
            $staging = $target + '.' + [guid]::NewGuid().ToString('N') + '.staging'
            WriteRecord 'intent' $Effect $null $staging
            Recovering $Effect {
                $null = [IO.Directory]::CreateDirectory($staging)
                foreach ($entry in $archive.Entries) {
                    $path = Join-Path $staging $entry.FullName.TrimEnd('/').Replace('/', '\')
                    if ($entry.FullName.EndsWith('/')) { $null = [IO.Directory]::CreateDirectory($path); continue }
                    $null = [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($path))
                    $in = $entry.Open()
                    try {
                        $out = [IO.FileStream]::new($path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
                        try { $in.CopyTo($out); $out.Flush($true) } finally { $out.Dispose() }
                    } finally { $in.Dispose() }
                }
                if (-not (Test-EffectStateEqual 'tree-extracted' $Effect.desired (ObserveTree $staging))) { throw "Staged $staging differs from the inventory." }
                [IO.Directory]::Move($staging, $target)
                WriteRecord 'commit' $Effect (ObserveTree $target)
                $script:copied++
            }
        } finally { $archive.Dispose() }
    } finally { $stream.Dispose() }
}

# The selected font effects: each content-addressed file, and its HKCU value
# '<full name> (TrueType)' naming that file.
function FontEffects {
    foreach ($font in $manifest.fonts) {
        if ($font.file -cnotmatch '^[0-9a-f]{64}\.ttf$' -or $font.file -cne ($font.sha256 + '.ttf') -or
            $font.fullName -isnot [string] -or $font.fullName -match '[\x00-\x1f]' -or -not $font.fullName.Trim()) {
            throw "Invalid font entry in manifest: $($font.fullName)"
        }
        $path = Join-Path $fontDirectory $font.file
        [pscustomobject]@{ font = $font; file = (FileEffect $path $font.sha256)
            value = (ValueEffect ($font.fullName + ' (TrueType)') $path) }
    }
}

# Class of a selected effect against the ledger and the machine, plus the desired
# state its open attempt recorded (for a changed selection).
function Classify($Effect) {
    $open = @(OpenAttempt $Effect.id)
    $class = Get-EffectClass (RecordsOf $Effect.id) (Observe $Effect) $Effect.kind $Effect.desired
    if ($class.resolution) { throw "Effect ledger id $($Effect.id) was not recovered." }
    [pscustomobject]@{ class = $class.class; reason = $class.reason; open = $open
        recorded = $(if ($open.Count) { Get-Field $open[0] 'desired' } else { $null }) }
}

# Converges one selected effect: absent is created; owned but drifted, or owned
# with a desired state the selection has changed, is reverted and created again;
# a matching owned or preexisting target is left alone; preexisting drift is
# never written and is reported.
function ConvergeEffect($Effect, [string]$Label, [scriptblock]$Create) {
    $state = Classify $Effect
    switch ($state.class) {
        'absent' { & $Create }
        'owned-match' {
            if (-not (Test-EffectStateEqual $Effect.kind $state.recorded $Effect.desired)) {
                UndoOwned $state.open (Observe $Effect) -Replacing
                & $Create
            }
        }
        'owned-drift' { UndoOwned $state.open (Observe $Effect) -Replacing; & $Create }
        'preexisting-match' { }
        'preexisting-drift' { $script:fontDrift += "$Label exists and differs, and is not owned; not written" }
        default { throw "$Label is $($state.class): $($state.reason)" }
    }
}

# The undo steps of a plan in execution order, by the kind of their effect: values, created
# keys deepest first, files, then trees. The sort is stable, so each id's steps stay together
# and in their own order (a tree's files, its directories, its root). No value the plan removes
# still names a file when that file goes, and a key has lost what the plan owns in it before it
# goes. (The plan orders ids by their latest attempt.) Any other step stops the run.
function OrderedSteps($Plan) {
    $rank = @{ 'registry-value' = 0; 'registry-key-created' = 1; 'file-created' = 2; 'tree-extracted' = 3 }
    $steps, $order = @($Plan.steps), 0
    foreach ($step in $steps) {
        if ($step.action -cnotin @('delete-registry-value', 'delete-empty-key', 'delete-file', 'remove-empty-directory') -or
            -not $rank.ContainsKey([string]$step.kind)) { throw "Unsupported undo step $($step.action)." }
    }
    @($steps | ForEach-Object { [pscustomobject]@{ step = $_; rank = $rank[[string]$_.kind]; order = $order++
            depth = $(if ($_.action -ceq 'delete-empty-key') { -$_.key.Split('\').Count } else { 0 }) } } |
        Sort-Object rank, depth, order | ForEach-Object { $_.step })
}

# Runs ordered undo steps, each id's consecutive steps together, then writes that id's one
# undone record. A tree's files are read back just before removal and its directories go only
# when empty (already gone: skipped, as in a resumed plan); nothing is removed recursively.
function UndoOwnedSteps($Steps) {
    $run = @()
    foreach ($step in @($Steps) + @($null)) {
        if ($run.Count -and ($null -eq $step -or $step.id -cne $run[0].id)) {
            $open = @(OpenAttempt $run[0].id)
            foreach ($one in $run) {
                switch -CaseSensitive ($one.action) {
                    'delete-registry-value' { RemoveTarget $open[0] ([ordered]@{ exists = $true; type = $one.expectType; data = $one.expectData }) }
                    'delete-empty-key' { RemoveTarget $open[0] ([ordered]@{ exists = $true }) }
                    'remove-empty-directory' { if (Test-Path -LiteralPath $one.path -PathType Container) { [IO.Directory]::Delete($one.path, $false) } }
                    'delete-file' {
                        if ($one.kind -cne 'tree-extracted') { RemoveTarget $open[0] ([ordered]@{ exists = $true; sha256 = $one.expectSha256 }); break }
                        if (-not (Test-EffectStateEqual 'file-created' ([ordered]@{ exists = $true; sha256 = $one.expectSha256 }) (ObserveFile $one.path))) {
                            throw "Refusing to remove $($one.path): it changed since it was read."
                        }
                        try { [IO.File]::Delete($one.path) } catch { throw "Could not remove $($one.path) (in use?): $($_.Exception.Message)" }
                        $script:removed++
                    }
                }
            }
            WriteRecord 'undone' $open[0] (Observe $open[0])
            $run = @()
        }
        if ($null -ne $step) { $run += $step }
    }
}

# True for a record of a font effect, by its kind and target: a file in the font directory or
# an HKCU Fonts value. Font collection considers only these, never another owned effect.
function IsFontEffect($Record) {
    $kind, $target = [string](Get-Field $Record 'kind'), [string](Get-Field $Record 'target')
    ($kind -ceq 'file-created' -and [IO.Path]::GetDirectoryName($target) -eq $fontDirectory) -or ($kind -ceq 'registry-value' -and $target -eq $fontKey)
}

# What of a plan takes part in the Fonts reference checks: HKCU Fonts value names, and files in the font directory.
function FontValueNames($Steps) { @($Steps | Where-Object { $_.action -ceq 'delete-registry-value' -and $_.key -eq $fontKey } | ForEach-Object { $_.name }) }
function IsFontFile($Step) { $Step.action -ceq 'delete-file' -and $Step.kind -ceq 'file-created' -and [IO.Path]::GetDirectoryName($Step.path) -eq $fontDirectory }

# Owned font effects no longer selected, reverted by the same plan as Uninstall:
# values first, then files. A file some Fonts value still names is kept open and
# reported; a refused plan or a locked file fails the run.
function CollectFontGarbage($Selected) {
    $ids = @(LedgerIds | Where-Object { $Selected -notcontains $_ -and (IsFontEffect @(RecordsOf $_)[0]) -and @(OpenAttempt $_).Count })
    if (-not $ids.Count) { return }
    $records = @($ids | ForEach-Object { RecordsOf $_ })
    $observations = @{}
    foreach ($id in $ids) { $observations[$id] = Observe @(RecordsOf $id)[0] }
    $plan = Get-UninstallPlan $records $observations
    if (-not $plan.ok) {
        $script:fontDrift += "unselected owned fonts cannot be collected: $(@($plan.refused | ForEach-Object { "$($_.id): $($_.reason)" }) -join '; ')"
        return
    }
    $steps = @(OrderedSteps $plan)
    $table = @(FontReferenceTable (FontValueNames $steps))
    $keep = @($steps | Where-Object { (IsFontFile $_) -and @(FontReferences $table $_.path $_.expectSha256).Count })
    $script:gcKeptReferenced += @($keep | ForEach-Object { $_.path })
    UndoOwnedSteps @($steps | Where-Object { @($keep | ForEach-Object { $_.id }) -cnotcontains $_.id })
}

# Apply and Restore, after recovery and PlanNoctty: classify every font effect before the
# first effect, then create or re-own each file and, once its file is exactly the
# selection, its value; then collect unselected owned fonts.
function ConvergeFonts {
    $effects = @(FontEffects)
    foreach ($effect in $effects) {
        foreach ($item in @($effect.file, $effect.value)) {
            $state = Classify $item
            if ($state.class -cnotin @('absent', 'owned-match', 'owned-drift', 'preexisting-match', 'preexisting-drift')) {
                throw "Font effect $($item.id) is $($state.class): $($state.reason)"
            }
        }
    }
    if (-not (Test-Path -LiteralPath $fontDirectory -PathType Container)) {
        $null = New-Item -ItemType Directory -Path $fontDirectory
        $script:sharedCreated += $fontDirectory
    }
    $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($fontSubkey)
    if ($null -eq $key) {
        $key = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($fontSubkey)
        $script:sharedCreated += $fontKey
    }
    $key.Close()
    foreach ($effect in $effects) {
        $file, $value = $effect.file, $effect.value
        $source = BundlePath "share/fonts/truetype/$($effect.font.file)"
        ConvergeEffect $file $file.target { CreateOwnedFile $file $source }
        if (Test-EffectStateEqual 'file-created' $file.desired (ObserveFile $file.target)) {
            ConvergeEffect $value "$fontKey\$($value.name)" { CreateOwnedValue $value }
        } else {
            $script:fontDrift += "$fontKey\$($value.name) not registered: its file is not the selected bytes"
        }
    }
    CollectFontGarbage @($effects | ForEach-Object { $_.file.id; $_.value.id })
}

# Read-only: every selected font file and value is exactly the selection.
function AssertFonts {
    foreach ($effect in @(FontEffects)) {
        if (-not (Test-EffectStateEqual 'file-created' $effect.file.desired (ObserveFile $effect.file.target))) {
            throw "Installed bytes differ: $($effect.font.fullName)"
        }
        if (-not (Test-EffectStateEqual 'registry-value' $effect.value.desired (ObserveValue $effect.value.name))) {
            throw "Registry drift: $($effect.value.name)"
        }
    }
}

# ---- Noctty and the default-terminal selection -------------------------------
function SharedDirectory([string]$Path) {
    if (Test-Path -LiteralPath $Path -PathType Container) { return }
    $null = New-Item -ItemType Directory -Path $Path
    $script:sharedCreated += $Path
}

function SharedKey([string]$Subkey) {
    $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($Subkey)
    if ($null -eq $key) { $key = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($Subkey); $script:sharedCreated += "HKCU\$Subkey" }
    $key.Close()
}

# The %%Startup selection as { console; terminal }, $null for an absent value.
function StartupPair {
    $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($startupSubkey)
    if ($null -eq $key) { return [ordered]@{ console = $null; terminal = $null } }
    try { [ordered]@{ console = $key.GetValue('DelegationConsole'); terminal = $key.GetValue('DelegationTerminal') } } finally { $key.Close() }
}

# The rollback of the selection this distribution wrote (Get-LegacyTerminalPlan); 'none' without
# a record, and an unreadable record reads as malformed, which is refused.
function LegacyPlan {
    if (-not (Test-Path -LiteralPath $terminalProvenance)) {
        return [ordered]@{ action = 'none'; reason = 'There is no default-terminal record.'; steps = @() }
    }
    $record = try { Get-Content -LiteralPath $terminalProvenance -Raw -Encoding utf8 | ConvertFrom-Json } catch { @{} }
    Get-LegacyTerminalPlan $record (StartupPair)
}

# Restores the values a plan names (the record's 'restore', or one run's rollback), Terminal
# first, each only while it still holds what was written.
function RestoreLegacy($Plan) {
    $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($startupSubkey, $true)
    try {
        foreach ($step in $Plan.steps) {
            if ($key.GetValue($step.name) -ne $step.expect) { throw "Refusing to restore $($step.name): it changed since it was read." }
            if ($null -eq $step.value) { $key.DeleteValue($step.name, $false) }
            else { $key.SetValue($step.name, $step.value, [Microsoft.Win32.RegistryValueKind]::String) }
            $script:changed++
        }
    } finally { $key.Close() }
}

# Why a machine-wide Noctty is present (Get-MachineNocttyReason), from both HKLM views: the
# registration's CLSID keys and every Uninstall DisplayName. Read-only.
function MachineNocttyReason {
    $clsids, $names = @(), @()
    foreach ($view in 'Registry64', 'Registry32') {
        $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey('LocalMachine', $view)
        try {
            foreach ($clsid in @($nocttyRegistration.keys | Where-Object { $_ -match '^Software\\Classes\\CLSID\\[^\\]+$' })) {
                $key = $base.OpenSubKey($clsid)
                if ($null -ne $key) { $key.Close(); $clsids += "$view\$clsid" }
            }
            $uninstall = $base.OpenSubKey('SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall')
            if ($null -eq $uninstall) { continue }
            try {
                foreach ($name in $uninstall.GetSubKeyNames()) {
                    $entry = $uninstall.OpenSubKey($name)
                    if ($null -eq $entry) { continue }
                    try { $names += [string]$entry.GetValue('DisplayName') } finally { $entry.Close() }
                }
            } finally { $uninstall.Close() }
        } finally { $base.Close() }
    }
    Get-MachineNocttyReason $clsids $names
}

# Apply and Restore, before any effect: every owned Noctty effect is classified, and the run
# stops on a machine-wide Noctty, a malformed default-terminal record, an indeterminate target,
# a tree that differs from the pinned inventory (owned or not; it is never overwritten), or a
# COM registration (the six values, the K-rule) that is neither entirely preexisting and exact
# nor entirely absent or owned, or, when it will be written, a COM key holding anything else.
# Restore also stops on Windows Terminal older than 1.24 and on a
# package view that contradicts this process's HKCU (only 'mismatch'; a gap is not fatal).
function PlanNoctty([switch]$Restore) {
    $machine = MachineNocttyReason
    if ($machine) { throw "A machine-wide Noctty is present ($machine); nothing was changed." }
    if ((LegacyPlan).reason -ceq 'Malformed default-terminal record.') { throw "Unreadable default-terminal provenance: $terminalProvenance" }
    $effects, $classes = (NocttyEffects), @{}
    foreach ($effect in @($effects.tree, $effects.config, $effects.startup) + $effects.keys + $effects.values) {
        $state = Classify $effect
        if ($state.class -ceq 'indeterminate') { throw "Noctty effect $($effect.id) is indeterminate: $($state.reason)" }
        $classes[$effect.id] = $state
    }
    $tree = $classes[$effects.tree.id]
    if ($tree.class -cin @('owned-drift', 'preexisting-drift') -or
        ($tree.class -ceq 'owned-match' -and -not (Test-EffectStateEqual 'tree-extracted' $tree.recorded $effects.tree.desired))) {
        throw "$nocttyDirectory differs from the pinned Noctty ($($tree.class)) and is never overwritten; nothing was changed."
    }
    $values = @($effects.values | ForEach-Object { $classes[$_.id].class })
    $com = if (-not @($values | Where-Object { $_ -cne 'preexisting-match' }).Count) { 'preexisting' }
        elseif (-not @($values | Where-Object { $_ -cnotin @('absent', 'owned-match', 'owned-drift') }).Count) { 'converge' }
        else { throw "The Noctty COM registration is partly foreign or differs ($($values -join ', ')); nothing was changed." }
    # A COM key this run may write into, owned or not, holds only the declared values and keys
    # (the same rule as A3), so no value of ours joins someone else's registration.
    if ($com -ceq 'converge') {
        $declared = @($nocttyRegistration.keys | ForEach-Object { [ordered]@{ action = 'delete-empty-key'; key = "HKCU\$_" } }) +
            @($nocttyRegistration.values | ForEach-Object { [ordered]@{ action = 'delete-registry-value'; key = "HKCU\$($_.key)"; name = $_.name } })
        $contents = @{}
        foreach ($key in $nocttyRegistration.keys) { $contents["HKCU\$key"] = ObserveKeyContent $key }
        $foreign = @(Get-ForeignKeyContent $declared $contents @{})
        if ($foreign.Count) { throw "$($foreign -join '; '); nothing was changed." }
    }
    if ($Restore) {
        if (-not (TestTerminalPackage)) { throw 'Noctty default-terminal handoff requires Windows Terminal 1.24 or newer; nothing was changed.' }
        $view = Test-PackageTerminalSelection
        if ($view.state -eq 'mismatch') { throw "$($view.failure) Nothing was changed." }
    }
    [pscustomobject]@{ effects = $effects; classes = $classes; com = $com }
}

# Creates what the plan found absent, in order: the tree, the configuration, the %%Startup key,
# then, unless the registration is entirely preexisting, the COM keys top-down and the six
# values. A configuration that differs from the selection is reported and never written. Shared
# parents (Programs, %LOCALAPPDATA%\noctty, the CLSID and Interface roots) are created as needed
# and listed, never owned.
function ApplyNoctty($Plan) {
    $effects, $classes = $Plan.effects, $Plan.classes
    if ($classes[$effects.tree.id].class -ceq 'absent') {
        SharedDirectory (Split-Path -Parent $effects.tree.target)
        CreateOwnedTree $effects.tree (BundlePath 'payload/noctty.zip')
    }
    $config, $bytes = $classes[$effects.config.id], [Text.UTF8Encoding]::new($false).GetBytes($nocttyConfigText)
    switch ($config.class) {
        'absent' { SharedDirectory (Split-Path -Parent $nocttyConfig); CreateOwnedFile $effects.config $bytes }
        'owned-match' {
            if (-not (Test-EffectStateEqual 'file-created' $config.recorded $effects.config.desired)) {
                UndoOwned $config.open (Observe $effects.config) -Replacing
                CreateOwnedFile $effects.config $bytes
            }
        }
        'preexisting-match' { }
        default { $script:nocttyDrift += "$nocttyConfig differs from the selection ($($config.class)); not written" }
    }
    if ($classes[$effects.startup.id].class -ceq 'absent') { CreateOwnedKey $effects.startup }
    if ($Plan.com -ceq 'converge') {
        SharedKey 'Software\Classes\CLSID'
        SharedKey 'Software\Classes\Interface'
        foreach ($key in $effects.keys) { if ($classes[$key.id].class -ceq 'absent') { CreateOwnedKey $key } }
        foreach ($value in $effects.values) { ConvergeEffect $value "$($value.target)\$($value.name)" { CreateOwnedValue $value } }
    }
}

# Selects Noctty in %%Startup, DelegationConsole then DelegationTerminal, writing only a value
# that differs (A4), after the write-once record of the prior selection. With -Check (Restore)
# the registration, COM activation and the package view must then confirm it. If a write or a
# check fails, only the values this run wrote go back to what this run read just before
# (Get-SelectionRollbackSteps), Terminal first, and only while they still hold what it wrote; the
# write-once record's older prior is Uninstall's, not this rollback's.
function SelectNoctty([switch]$Check) {
    $pair = StartupPair
    $wanted = [ordered]@{ DelegationConsole = @($pair.console, $windowsTerminalConsole); DelegationTerminal = @($pair.terminal, $nocttyTerminal) }
    $writes = @($wanted.Keys | Where-Object { $wanted[$_][0] -ne $wanted[$_][1] })
    if ($writes.Count) { RecordPriorTerminal $pair.console $pair.terminal }
    try {
        if ($writes.Count) {
            $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($startupSubkey, $true)
            try { foreach ($name in $writes) { $key.SetValue($name, $wanted[$name][1], [Microsoft.Win32.RegistryValueKind]::String); $script:changed++ } }
            finally { $key.Close() }
        }
        if ($Check) {
            if (-not (TestNocttyRegistration)) { throw 'The Noctty default-terminal registration is incomplete.' }
            if (-not (TestNocttyActivation)) { throw 'Noctty COM activation failed.' }
            AssertActualSelection
        }
    } catch {
        $failure = $_
        if ($writes.Count) {
            $written = @{}
            foreach ($name in $writes) { $written[$name] = $wanted[$name][1] }
            $rollback = Get-SelectionRollbackSteps $pair $written (StartupPair)
            if (-not $rollback.ok) { throw "$($failure.Exception.Message) The selection was not restored: $($rollback.reason)" }
            RestoreLegacy $rollback
        }
        throw $failure
    }
}

# The tree, exactly the pinned inventory, and the configuration, exactly its text; a Start-menu
# shortcut is neither created nor checked.
function TestNoctty {
    $effects = NocttyEffects
    (Test-EffectStateEqual 'tree-extracted' $effects.tree.desired (ObserveTree $nocttyDirectory)) -and
        (Test-EffectStateEqual 'file-created' $effects.config.desired (ObserveFile $nocttyConfig))
}

# Value and subkey names of an HKCU key now (empty when it is absent), for A3.
function ObserveKeyContent([string]$Subkey) {
    $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($Subkey)
    if ($null -eq $key) { return [ordered]@{ values = @(); subkeys = @() } }
    try { [ordered]@{ values = @($key.GetValueNames()); subkeys = @($key.GetSubKeyNames()) } } finally { $key.Close() }
}

# The COM->tree guard for the owned trees a plan removes: no Noctty server path in HKCU or either
# HKLM view that the plan does not remove may name one (Get-TreeReferenceProblem).
function TreeReferenceProblems($Steps) {
    $trees = @($Steps | Where-Object { $_.kind -ceq 'tree-extracted' } | ForEach-Object { $_.id } | Sort-Object -Unique -CaseSensitive)
    if (-not $trees.Count) { return }
    $servers = @($nocttyRegistration.values | ForEach-Object { $_.key } | Where-Object { $_ -match '\\(LocalServer32|InprocServer32)$' } | Sort-Object -Unique)
    $references = @(NocttyReferences $registryViews $servers)
    $removed = @($Steps | Where-Object { $_.action -ceq 'delete-registry-value' } | ForEach-Object { $_.id })
    foreach ($id in $trees) {
        $problem = Get-TreeReferenceProblem $references ([string](Get-Field @(RecordsOf $id)[0] 'target')) $removed
        if ($problem) { "${id}: $problem" }
    }
}

# Not $Identity: that is the RentSsh key-file parameter, a [string] in the same
# script scope (variable names ignore case), which would flatten this record.
function RunIdentity {
    $current = [Security.Principal.WindowsIdentity]::GetCurrent()
    [ordered]@{ sid = $current.User.Value; profile = $env:USERPROFILE
        elevated = ([Security.Principal.WindowsPrincipal]$current).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) }
}

# Uninstall: every recorded id must be an owned effect this version handles. Everything is
# planned before any step, and anything refused means nothing runs: the ledger plan; the
# rollback of the default-terminal selection; while owned COM values would go, a rollback that
# can restore and leaves Noctty unselected; A3 (a created key the plan removes may hold nothing
# the plan does not remove); the COM->tree guard; and the Fonts reference preflight. -Apply then
# restores the selection (Terminal first), reads it again and stops if Noctty is still selected,
# undoes values, keys and files, checks the guard again, and removes owned trees last.
function Uninstall {
    $found = Test-Path -LiteralPath $ledgerDirectory -PathType Container
    if ($Apply -and $found) { LockLedger }
    $null = ReadLedger
    $observations = @{}
    try {
        if ($Apply -and $found) { RecoverLedger }
        foreach ($id in @(LedgerIds)) { $observations[$id] = Observe @(RecordsOf $id)[0] }
    } catch {
        throw "Uninstall refused for $($script:runIdentity.sid) (elevated: $($script:runIdentity.elevated)): $($_.Exception.Message)"
    }
    $plan = Get-UninstallPlan $script:ledgerRecords $observations
    $refused = @($plan.refused | ForEach-Object { "$($_.id): $($_.reason)" })
    $steps, $com, $legacy = @(), @(), (LegacyPlan)
    if ($plan.ok) {
        $steps = @(OrderedSteps $plan)
        $table = @(FontReferenceTable (FontValueNames $steps))
        foreach ($step in @($steps | Where-Object { IsFontFile $_ })) {
            $references = @(FontReferences $table $step.path $step.expectSha256)
            if ($references.Count) { $refused += "$($step.id): referenced by $($references -join ', ')" }
        }
        $com = @($steps | Where-Object { $_.action -ceq 'delete-registry-value' -and $_.key -ne $fontKey })
        if ($com.Count) {
            if ($legacy.action -cin @('refuse', 'report')) { $refused += "default-terminal record: $($legacy.reason)" }
            $terminal = @(@($legacy.steps | Where-Object { $_.name -ceq 'DelegationTerminal' } | ForEach-Object { $_.value }) + @((StartupPair).terminal))[0]
            if ($terminal -eq $nocttyTerminal) { $refused += 'Noctty stays the selected default terminal, so its COM registration is kept.' }
        }
        $contents, $alsoRemoved = @{}, @{ ('HKCU\' + $startupSubkey) = @($legacy.steps | Where-Object { $null -eq $_.value } | ForEach-Object { $_.name }) }
        foreach ($step in @($steps | Where-Object { $_.action -ceq 'delete-empty-key' })) { $contents[$step.key] = ObserveKeyContent ($step.key -replace '^HKCU\\', '') }
        $refused += @(Get-ForeignKeyContent $steps $contents $alsoRemoved) + @(TreeReferenceProblems $steps)
    }
    if ($Apply -and -not $refused.Count) {
        if ($legacy.action -ceq 'restore') { RestoreLegacy $legacy }
        if ($com.Count -and (StartupPair).terminal -eq $nocttyTerminal) { throw 'Noctty is still the selected default terminal; its COM registration and tree are kept.' }
        UndoOwnedSteps @($steps | Where-Object { $_.kind -cne 'tree-extracted' })
        $late = @(TreeReferenceProblems $steps)
        if ($late.Count) { throw "Owned Noctty trees are kept: $($late -join '; ')" }
        UndoOwnedSteps @($steps | Where-Object { $_.kind -ceq 'tree-extracted' })
    }
    $open, $changedAfterClose = @(), @()
    foreach ($id in @(LedgerIds)) {
        $attempt = Get-EffectAttempt (RecordsOf $id)
        # A malformed id has no attempt records; it stays open (the plan already refused it).
        if ($attempt.problem -or (-not $attempt.closed -and @($attempt.records).Count)) { $open += $id; continue }
        $first = @($attempt.records)[0]
        if (-not (Test-EffectStateEqual ([string](Get-Field $first 'kind')) (Get-Field $first 'prior') (Observe $first))) { $changedAfterClose += $id }
    }
    $answer = [ordered]@{ mode = $Mode; apply = [bool]$Apply; source = $manifest.source; identity = $script:runIdentity
        ledgerFound = $found; siloCheck = 'notPerformed'
        scope = 'owned fonts and Noctty effects visible to this process, and the default-terminal selection this distribution wrote; packages and RentSsh are not in the ledger yet'
        planned = @($steps | ForEach-Object { "$($_.action) $(if ($_.Contains('path')) { $_.path } else { "$($_.key)\$($_.name)" })" })
        resolutions = @($plan.resolutions | ForEach-Object { "$($_.id): $($_.resolution)" }); resumed = @($plan.resumed)
        defaultTerminal = $legacy.action
        refused = $refused; removed = $script:removed; recordsWritten = $script:recordsWritten
        ownedOpen = $open.Count; changedAfterClose = $changedAfterClose.Count
        retained = @($ledgerDirectory, (Split-Path -Parent $terminalProvenance))
        notInLedger = [ordered]@{ nocttyShortcut = (Test-Path -LiteralPath $nocttyShortcut)
            defaultTerminalRecord = (Test-Path -LiteralPath $terminalProvenance)
            rentSsh = (Test-Path -LiteralPath (Join-Path $env:USERPROFILE '.ssh\windows-rent')) }
        registrationState = $(if (TestNocttyRegistration) { 'registered' } else { 'unregistered' }); handoffProof = 'unproven' }
    $answer | ConvertTo-Json -Compress -Depth 4
    if ($refused.Count) { throw "Uninstall refused; nothing was removed: $($refused -join '; ')" }
}

$script:runIdentity = RunIdentity
try {
    if ($Mode -eq 'Uninstall') { Uninstall; return }
    # Packages are read, never downloaded or extracted, outside Restore; Validate,
    # Test and Apply do not read the machine for them at all.
    if ($Mode -eq 'Restore' -or $Mode -eq 'RestoreTest') {
        $packageStates = @(foreach ($package in $manifest.packages) {
            [pscustomobject]@{ package = $package; state = (ClassifyPackage $package) }
        })
    }
    if ($Mode -eq 'Restore') {
        # Before any Restore effect: an unknown package owner stops.
        $unknown = @($packageStates | Where-Object { $_.state.class -ceq 'indeterminate' })
        if ($unknown.Count) { throw "Package state unknown: $(@($unknown | ForEach-Object { $_.state.reason }) -join '; ')" }
    }
    $ledgerFound, $nocttyPlan = $false, $null
    if ($Mode -eq 'Apply' -or $Mode -eq 'Restore') {
        # Owned fonts and Noctty through the effect ledger (native files, trees and HKCU keys and
        # values): recovery, then every Noctty and font effect is classified before the first
        # one; fonts, then Noctty (tree, configuration, keys, values), then the selection.
        $ledgerFound = Test-Path -LiteralPath $ledgerDirectory -PathType Container
        LockLedger
        $null = ReadLedger
        RecoverLedger
        $nocttyPlan = PlanNoctty -Restore:($Mode -eq 'Restore')
        # Packages only after every refusal the plan can make: a clean install (fetch and verify
        # every asset, then extract) runs here or not at all; it is disabled until S-A2.
        $absent = @($packageStates | Where-Object { $_.state.class -ceq 'absent' } | ForEach-Object { $_.package })
        if ($absent.Count) { InstallPackages $absent }
        ConvergeFonts
        if ($script:fontDrift.Count) { throw "Font drift: $($script:fontDrift -join '; ')" }
        ApplyNoctty $nocttyPlan
        SelectNoctty -Check:($Mode -eq 'Restore')
        if ($script:nocttyDrift.Count) { throw "Noctty drift: $($script:nocttyDrift -join '; ')" }
    }
    if ($Mode -ne 'Validate') { AssertFonts }
    if ($Mode -eq 'Restore' -or $Mode -eq 'RestoreTest') {
        if (-not (TestNoctty)) { throw 'Noctty files or font configuration drift.' }
        if (-not (TestTerminalPackage)) { throw 'Windows Terminal 1.24 or newer is missing.' }
        if (-not (TestNocttyRegistration)) { throw 'Noctty default-terminal registration drift.' }
        if ($Mode -eq 'RestoreTest') { AssertActualSelection }  # Restore checked it before success
        # A preexisting install is never written; one that is not exactly the locked
        # version fails as that package's drift, after Restore's other effects.
        $drift = @($packageStates | Where-Object { $_.state.class -cne 'preexisting-match' } |
            ForEach-Object { "$($_.package.name) $($_.state.class): $($_.state.reason)" })
        if ($drift.Count) { throw "Package drift: $($drift -join '; ')" }
    }
    # inDesiredState covers the declared state this mode tested. Handoff is never
    # part of it: this script does not launch or observe a console.
    [ordered]@{ mode = $Mode; source = $manifest.source; fontDirectory = $fontDirectory; identity = $script:runIdentity
        fonts = @($manifest.fonts).Count; copied = $script:copied; changedProperties = $script:changed
        removed = $script:removed; recordsWritten = $script:recordsWritten; ledgerFound = $ledgerFound
        sharedCreated = @($script:sharedCreated); gcKeptReferenced = @($script:gcKeptReferenced)
        noctty = $manifest.noctty.version
        nocttyPlan = $(if ($nocttyPlan) { [ordered]@{ tree = $nocttyPlan.classes[$nocttyPlan.effects.tree.id].class
            config = $nocttyPlan.classes[$nocttyPlan.effects.config.id].class; com = $nocttyPlan.com } } else { 'notEvaluated' })
        packages = @($manifest.packages | ForEach-Object {
            $name = $_.name
            $state = @($packageStates | Where-Object { $_.package.name -ceq $name })
            [ordered]@{ name = $name; version = $_.version
                class = $(if ($state.Count) { $state[0].state.class } else { 'notEvaluated' }) } });
        inDesiredState = ($Mode -ne 'Validate');
        registrationState = $(if (TestNocttyRegistration) { 'registered' } else { 'unregistered' });
        handoffProof = 'unproven' } | ConvertTo-Json -Compress -Depth 4
}
finally {
    if ($script:ledgerLock) { $script:ledgerLock.Dispose() }
}
