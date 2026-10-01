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
    [switch]$Apply,
    # Apply only: the locked packages (exact names) to converge; Apply converges none without it,
    # Restore always all. With -File, pass them as one comma-separated argument.
    [string[]]$Packages,
    # Apply only: converge the owned fonts, the desktop UI font faces and the fonts of an app already present,
    # alone (no Noctty, package or app install), for a machine where Restore stops elsewhere (e.g. a machine-wide Noctty).
    [switch]$Typography,
    # Apply only: write the bundled seed's six font preferences into each existing normal Chromium profile, alone (no
    # other effect), while Chromium is closed. Restore never edits an existing profile (a new one gets the seed).
    [switch]$ChromiumFonts,
    # Apply only: write the fonts of the app already present (its preconfiguration), alone: no install, no OS font, no other effect.
    [switch]$AppFonts
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
    if ($name -isnot [string] -or $name -cnotmatch '^[A-Za-z0-9][A-Za-z0-9.-]*\z' -or
        $version -isnot [string] -or $version -cnotmatch '^[0-9][A-Za-z0-9.]*\z' -or
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
    # A seed goes into the owned tree beside the executable, from a bundle file of its exact hash.
    $problem = Get-SeedProblem $Package $manifest.files
    if ($problem) { throw "Invalid package seed in manifest: ${name}: $problem" }
    # An App Paths name (not written yet): one segment ending in lowercase .exe, as pack.py checks.
    $appPath = Get-Field $Package 'appPath'
    if ($null -ne $appPath -and ($appPath -isnot [string] -or $appPath -cnotmatch '^[A-Za-z0-9][A-Za-z0-9._-]*\.exe\z' -or -not (Test-PathSegment $appPath))) {
        throw "Invalid package appPath in manifest: $name"
    }
}

foreach ($package in $manifest.packages) { AssertPackageShape $package }
$appPaths = @($manifest.packages | ForEach-Object { Get-Field $_ 'appPath' } | Where-Object { $null -ne $_ })
if (@($appPaths | Sort-Object -Unique).Count -ne $appPaths.Count) { throw 'Two packages share an App Paths name.' }  # ignoring case
$packageNames = @($Packages | ForEach-Object { ([string]$_).Split(',') } | ForEach-Object { $_.Trim() })
if ($PSBoundParameters.ContainsKey('Packages')) {
    if ($Mode -ne 'Apply') { throw '-Packages is only for -Mode Apply; Restore converges every locked package.' }
    $locked = @($manifest.packages | ForEach-Object { $_.name })
    if (-not $packageNames.Count -or @($packageNames | Sort-Object -Unique -CaseSensitive).Count -ne $packageNames.Count -or
        @($packageNames | Where-Object { $locked -cnotcontains $_ }).Count) {
        throw "Unknown or repeated package in -Packages: $($packageNames -join ', ') (locked: $($locked -join ', '))"
    }
}
if ($Typography -and ($Mode -ne 'Apply' -or $PSBoundParameters.ContainsKey('Packages'))) { throw '-Typography is only for -Mode Apply, without -Packages.' }
if ($ChromiumFonts -and ($Mode -ne 'Apply' -or $Typography -or $AppFonts -or $PSBoundParameters.ContainsKey('Packages'))) { throw '-ChromiumFonts is only for -Mode Apply, without -Packages, -Typography or -AppFonts.' }
if ($AppFonts -and ($Mode -ne 'Apply' -or $Typography -or $PSBoundParameters.ContainsKey('Packages'))) { throw '-AppFonts is only for -Mode Apply, without -Packages or -Typography.' }
# The desktop UI font face (a selected family, pack.py) set through ui-font.ahk by the locked interpreter package.
$uiTypography = Get-Field $manifest 'typography'
if ($null -ne $uiTypography -and (-not (Test-UiFontFace (Get-Field $uiTypography 'face')) -or (Get-Field $uiTypography 'script') -cne 'ui-font.ahk' -or
        @($manifest.packages | Where-Object { $_.name -ceq (Get-Field $uiTypography 'interpreter') }).Count -ne 1)) {
    throw 'Invalid typography in manifest.'
}
if ($Typography -and $null -eq $uiTypography) { throw 'This distribution selects no UI font face.' }
# Store apps Restore installs when absent (pack.py checks the same shape); never owned, updated or removed.
$apps = @(Get-Field $manifest 'apps' | Where-Object { $null -ne $_ })
foreach ($app in $apps) {
    if ((Get-Field $app 'source') -cne 'msstore' -or [string](Get-Field $app 'id') -cnotmatch '^[0-9A-Z]{12}\z' -or
        [string](Get-Field $app 'name') -cnotmatch '^[A-Za-z0-9][A-Za-z0-9 .-]*\z' -or
        [string](Get-Field $app 'package') -cnotmatch '^[A-Za-z0-9][A-Za-z0-9.-]*\z' -or [string](Get-Field $app 'publisherId') -cnotmatch '^[a-z0-9]{13}\z') {
        throw "Invalid app in manifest: $(Get-Field $app 'name')"
    }
    # Its font preconfiguration (pack.py): quoted CSS families for ui, code and content, and the app's own complete
    # light and dark themes, used only where a theme is absent.
    $appearance = Get-Field $app 'appearance'
    if ($null -ne $appearance) {
        $fonts = Get-Field $appearance 'fonts'
        if (@('ui', 'code', 'content' | Where-Object { [string](Get-Field $fonts $_) -cnotmatch '^"[^"\\\x00-\x1f]+"\z' }).Count -or
            @('light', 'dark' | Where-Object { Get-AppThemeProblem (New-AppTheme (Get-Field (Get-Field $appearance 'defaults') $_) $fonts) }).Count) {
            throw "Invalid app appearance in manifest: $(Get-Field $app 'name')"
        }
    }
}
if (@($apps | Where-Object { $null -ne (Get-Field $_ 'appearance') }).Count -gt 1) { throw 'Two apps preconfigure the one Codex config.' }
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
# The same records by id (ordinal, so ids differing only in case stay apart and LedgerIds refuses
# them), filled wherever ledgerRecords grows: a lookup no longer scans the whole ledger.
# Each entry also caches that id's Get-EffectAttempt for this run: validation dominates a run's cost, and
# the same id is validated by recovery, classification and collection. IndexRecord is the only way records
# enter the index and drops the id's cached attempt; ReadLedger clears the index; replacing the index drops
# every cache with it. Cached records and attempts are read-only.
function NewLedgerIndex { [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal) }
$script:ledgerById = NewLedgerIndex
function IndexRecord($Record) {
    $id = [string](Get-Field $Record 'id')
    if (-not $script:ledgerById.ContainsKey($id)) {
        $script:ledgerById[$id] = [pscustomobject]@{ records = [Collections.Generic.List[object]]::new(); attempt = $null }
    }
    $entry = $script:ledgerById[$id]
    $entry.records.Add($Record)
    $entry.attempt = $null
}

# Get-EffectAttempt of one id's records, computed once per index change.
function AttemptOf([string]$Id) {
    if (-not $script:ledgerById.ContainsKey($Id)) { return Get-EffectAttempt @() }
    $entry = $script:ledgerById[$Id]
    if ($null -eq $entry.attempt) { $entry.attempt = Get-EffectAttempt @($entry.records) }
    return $entry.attempt
}
$script:copied, $script:changed, $script:removed, $script:recordsWritten = 0, 0, 0, 0
$script:fontDrift, $script:sharedCreated, $script:gcKeptReferenced, $script:nocttyDrift = @(), @(), @(), @()

function ReadLedger {
    $script:ledgerRecords, $script:nextSeq = @(), 1
    $script:ledgerById.Clear()
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
        IndexRecord $record
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
# named before that file exists, and for a package tree the locked package name, R1),
# commit, void or undone (with the observed state). The pure checks refuse a malformed
# record, including an observation that is not the desired (commit) or prior (void, undone) state.
function WriteRecord([string]$Phase, $Effect, $Observed, [string]$Temp, [string]$Package) {
    $entry = [ordered]@{ ledger = 'effects'; schema = 1; seq = $script:nextSeq; phase = $Phase
        id = Get-Field $Effect 'id'; kind = Get-Field $Effect 'kind'; target = Get-Field $Effect 'target' }
    if ($entry.kind -cin @('registry-value', 'pref-value')) { $entry.name = Get-Field $Effect 'name' }
    $entry.prior, $entry.desired = (Get-Field $Effect 'prior'), (Get-Field $Effect 'desired')
    if ($Phase -cne 'intent') { $entry.observed = $Observed }
    if ($Temp) { $entry.temp = $Temp }
    if ($Package) {
        if ($Phase -cne 'intent' -or $entry.kind -cne 'tree-extracted') { throw 'Only a tree intent names its package.' }
        $entry.package = $Package
    }
    $entry.utc, $entry.source, $entry.mode = [DateTime]::UtcNow.ToString('o'), $manifest.source, $Mode
    $problem = Get-EffectRecordProblem $entry
    if ($problem) { throw "Refusing to write a malformed ledger record for $($entry.id): $problem" }
    # A package intent names exactly one locked package, and its own staging directory must yield
    # that package's derived asset path (Get-PackageAssetPath), so recovery can find what it downloaded.
    if ($Package -and (@($manifest.packages | Where-Object { $_.name -ceq $Package }).Count -ne 1 -or
            -not (Get-PackageAssetPath $entry (Join-Path $localAppData 'Programs')))) {
        throw "Refusing a package intent for $($entry.id): $Package is not the locked package of this tree and staging directory."
    }
    $json = $entry | ConvertTo-Json -Depth 8 -Compress
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes($json)
    $path = Join-Path $ledgerDirectory ('{0:D8}.json' -f $script:nextSeq)
    $stream = [IO.FileStream]::new($path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None,
        4096, [IO.FileOptions]::WriteThrough)
    try { $stream.Write($bytes, 0, $bytes.Length); $stream.Flush($true) } finally { $stream.Dispose() }
    $record = $json | ConvertFrom-Json
    $script:ledgerRecords += $record
    IndexRecord $record
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

# True for the tree of any version of a locked package: exactly %LOCALAPPDATA%\Programs\
# <lock name, lowercase>-<version>, the version a digit first and holding no '-' (so an owned
# older version stays readable for collection and Uninstall, and chromium-extra-1 is not Chromium's).
function IsPackageTree([string]$Target) {
    $leaf = [IO.Path]::GetFileName($Target)
    [IO.Path]::GetDirectoryName($Target) -eq (Join-Path $localAppData 'Programs') -and (Test-PathSegment $leaf) -and
        @($manifest.packages | Where-Object { $leaf -cmatch ('^' + [regex]::Escape($_.name.ToLowerInvariant()) + '-[0-9][A-Za-z0-9.]*\z') }).Count -gt 0
}

# The current state of a recorded or selected effect: an owned font file or HKCU Fonts value, a
# package tree, an App Paths key or default value, a UI font slot, or a Noctty effect (ObserveNoctty).
# Anything else is outside this version and stops the run.
function Observe($Effect) {
    $kind, $target = [string](Get-Field $Effect 'kind'), [string](Get-Field $Effect 'target')
    if ($kind -ceq 'ui-font-face' -and (Test-EffectPath $kind $target)) { return ObserveUiFont $target.Substring('winmetrics:'.Length) }
    if ($kind -ceq 'pref-value' -and (IsChromiumPrefs $target)) { return ObservePref $target ([string](Get-Field $Effect 'name')) }
    if ($kind -ceq 'app-theme-fonts' -and (Test-EffectPath $kind $target)) { return ObserveAppFonts $target.Substring('codex-config:desktop.'.Length) }
    if ($kind -ceq 'file-created' -and [IO.Path]::GetDirectoryName($target) -eq $fontDirectory -and
        [IO.Path]::GetFileName($target) -match '^[0-9a-f]{64}\.ttf$') { return ObserveFile $target }
    if ($kind -ceq 'registry-value' -and $target -eq $fontKey) { return ObserveValue ([string](Get-Field $Effect 'name')) }
    if ($kind -ceq 'tree-extracted' -and (IsPackageTree $target)) { return ObserveTree $target }
    if (IsAppPathEffect $Effect) {
        $subkey = $target -replace '^HKCU\\', ''
        if ($kind -ceq 'registry-key-created') { return ObserveKey $subkey } else { return ObserveValue '' $subkey }
    }
    if ($kind -cne 'file-created' -or $target -eq $nocttyConfig) { return ObserveNoctty $Effect }
    throw "The effect ledger holds $kind $target, which this version (owned fonts only) does not handle."
}

function LedgerIds {
    $ids = @($script:ledgerById.Keys | Sort-Object -Unique -CaseSensitive)
    if (@($ids | Sort-Object -Unique).Count -ne $ids.Count) { throw 'Two effect ledger ids differ only in case.' }
    return $ids
}

function RecordsOf([string]$Id) { if ($script:ledgerById.ContainsKey($Id)) { @($script:ledgerById[$Id].records) } else { @() } }

# The open attempt of an id (its records), or an empty list.
function OpenAttempt([string]$Id) {
    $attempt = AttemptOf $Id
    if ($attempt.problem) { throw "Effect ledger id ${Id}: $($attempt.problem)" }
    if ($attempt.closed) { return @() }
    $open = @($attempt.records)
    # A UI font slot always holds a face, and an app theme some fonts: the prior is written back, not content owned.
    if ($open.Count -and (Get-Field (Get-Field $open[0] 'prior') 'exists') -and (Get-Field $open[0] 'kind') -cnotin @('ui-font-face', 'app-theme-fonts')) {
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

# Removes the one download file a package tree intent may have left beside its staging
# directory (Get-PackageAssetPath), only as a regular file; a package intent from which no
# asset path derives stops the run.
function RemovePackageAsset($Intent) {
    $asset = Get-PackageAssetPath $Intent (Join-Path $localAppData 'Programs')
    if (-not $asset) { throw "A package intent names no valid asset path: $(Get-Field $Intent 'id')" }
    $item = Get-Item -LiteralPath $asset -Force -ErrorAction SilentlyContinue
    if ($null -eq $item) { return }
    if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw "Not a plain asset file: $asset" }
    [IO.File]::Delete($asset)
}

# Closes or confirms an open attempt: first the temporary files or staging directories its
# own intents named (and a package intent's derived asset), then a commit, void or undone
# record carrying the observed state.
function ResolveAttempt($Open, [string]$Phase) {
    foreach ($intent in @($Open | Where-Object { (Get-Field $_ 'phase') -ceq 'intent' })) {
        $temp = IntentTemp $intent
        if ($null -ne (Get-Field $intent 'package')) { RemovePackageAsset $intent }
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
    $class = Get-EffectClass $null (Observe $open[0]) '' $null (AttemptOf $Id)
    if ($class.class -ceq 'indeterminate') { throw "Effect ledger id $Id is indeterminate: $($class.reason)" }
    if ($class.resolution) { ResolveAttempt $open ($(if ($class.resolution -ceq 'confirm') { 'commit' } else { $class.resolution })) }
}

# App font effects are read through the app's config service, so only ConvergeAppFonts and Uninstall (-All) recover them.
function RecoverLedger([switch]$All) { foreach ($id in @(LedgerIds)) { if ($All -or -not (IsAppFontEffect @(RecordsOf $id)[0])) { RecoverId $id } } }

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
    $class = Get-EffectClass $null (Observe $Effect) $Effect.kind $Effect.desired (AttemptOf $Effect.id)
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

# The undo steps of a plan in execution order, by the kind of their effect: UI font faces (so no
# slot names a font the plan removes, and the interpreter is still there), values, created keys
# deepest first, files, then trees. The sort is stable, so each id's steps stay together
# and in their own order (a tree's files, its directories, its root). No value the plan removes
# still names a file when that file goes, and a key has lost what the plan owns in it before it
# goes. (The plan orders ids by their latest attempt.) Any other step stops the run.
function OrderedSteps($Plan) {
    $rank = @{ 'ui-font-face' = -1; 'app-theme-fonts' = -1; 'pref-value' = -1; 'registry-value' = 0; 'registry-key-created' = 1; 'file-created' = 2; 'tree-extracted' = 3 }
    $steps, $order = @($Plan.steps), 0
    foreach ($step in $steps) {
        if ($step.action -cnotin @('set-ui-font-face', 'set-app-theme-fonts', 'delete-pref-value', 'delete-registry-value', 'delete-empty-key', 'delete-file', 'remove-empty-directory') -or
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
                    'set-ui-font-face' {
                        if ((ObserveUiFont $one.slot).face -cne $one.expectFace) { throw "Refusing to revert UI font $($one.slot): it changed since it was read." }
                        WriteUiFontFace $one.slot $one.expectFace $one.face $null  # face only, over the bytes there now
                    }
                    'set-app-theme-fonts' { UndoAppFonts $one $null }
                    'delete-pref-value' { UndoPrefValue $one }
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

# One undo step as text for the Uninstall answer: its action and what it acts on, a path (file or
# directory), key\name (value) or key (created key). Steps are dictionaries, and under strict mode
# a missing key throws, so each shape is checked, not assumed.
function StepText($Step) {
    $on = if ($Step.Contains('expectValue')) { "$($Step.path) $($Step.name)" } elseif ($Step.Contains('path')) { $Step.path } elseif ($Step.Contains('expectFonts')) { "codex-config:desktop.$($Step.theme)" }
        elseif ($Step.Contains('slot')) { "winmetrics:$($Step.slot) '$($Step.expectFace)' -> '$($Step.face)'" }
        elseif ($Step.Contains('name')) { "$($Step.key)\$($Step.name)" } else { $Step.key }
    "$($Step.action) $on"
}

# What of a plan takes part in the Fonts reference checks: HKCU Fonts value names, and files in the font directory.
function FontValueNames($Steps) { @($Steps | Where-Object { $_.action -ceq 'delete-registry-value' -and $_.key -eq $fontKey } | ForEach-Object { $_.name }) }
function IsFontFile($Step) { $Step.action -ceq 'delete-file' -and $Step.kind -ceq 'file-created' -and [IO.Path]::GetDirectoryName($Step.path) -eq $fontDirectory }

# Owned font effects no longer selected, reverted by the same plan as Uninstall:
# values first, then files. A value of a family some UI font slot still names (UiFaces), and so
# its file, is kept open and reported, as is a file some Fonts value still names; a refused plan
# or a locked file fails the run.
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
    $faces = @(UiFaces) + @(AppFontFamilies) + @(ChromiumFontFamilies)
    $held = @($steps | Where-Object { $_.action -ceq 'delete-registry-value' -and $_.key -eq $fontKey -and (NamesFace $_.name $faces) })
    $script:gcKeptReferenced += @($held | ForEach-Object { "$fontKey\$($_.name) (a UI font slot or owned app font names its family)" })
    $steps = @($steps | Where-Object { @($held | ForEach-Object { $_.id }) -cnotcontains $_.id })
    $table = @(FontReferenceTable (FontValueNames $steps))
    $keep = @($steps | Where-Object { (IsFontFile $_) -and @(FontReferences $table $_.path $_.expectSha256).Count })
    $script:gcKeptReferenced += @($keep | ForEach-Object { $_.path })
    UndoOwnedSteps @($steps | Where-Object { @($keep | ForEach-Object { $_.id }) -cnotcontains $_.id })
}

# Apply and Restore, after recovery and PlanNoctty: classify every font effect before the
# first effect, then create or re-own each file and, once its file is exactly the
# selection, its value. Unselected owned fonts are collected later (CollectUnselectedFonts),
# once the UI font slots name the selection.
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
}

function CollectUnselectedFonts { CollectFontGarbage @(FontEffects | ForEach-Object { $_.file.id; $_.value.id }) }

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

# ---- Desktop UI font faces (ui-font-face effects) -------------------------------
# Six slots, face only, written into their persisted HKCU WindowMetrics values (REG_BINARY LOGFONTW, 92 bytes) through
# the registry, which Windows reads at the next sign-in. No SystemParametersInfo SET is called: it recomputes and persists
# the window geometry (CaptionWidth and more) too. Every other byte of each font, and every other WindowMetrics value,
# stays. Observation, recovery and Uninstall read the same values. A face the user changed after this wrote it is
# owned-drift: reported, never written. The raw value layout is not a documented API contract: proven on the builds
# README names, and in effect only after the user's next sign-in (ui-font.ahk's read-only get tells pendingLogon from active).
$script:uiFontDrift, $script:uiInterpreter = @(), $null
$windowMetricsSubkey = 'Control Panel\Desktop\WindowMetrics'
$uiFontValues = @{ caption = 'CaptionFont'; smCaption = 'SmCaptionFont'; menu = 'MenuFont'; status = 'StatusFont'; message = 'MessageFont'; icon = 'IconFont' }

# A slot's persisted bytes, strictly: REG_BINARY, 92 bytes, a terminated valid face; anything else stops the run.
function UiFontBytes([string]$Slot) {
    $name = $uiFontValues[$Slot]
    $value = ObserveValue $name $windowMetricsSubkey
    $bytes = $null  # assigned in the branch: an if-expression would unroll the array into single bytes
    if ($value.exists -and $value.type -ceq 'Binary') { $bytes = [byte[]]$value.data }
    if ($null -eq (Get-LogFontFace $bytes)) { throw "HKCU\$windowMetricsSubkey\$name is not a 92-byte REG_BINARY LOGFONTW with a valid face." }
    , $bytes
}
function ObserveUiFont([string]$Slot) { [ordered]@{ exists = $true; face = (Get-LogFontFace (UiFontBytes $Slot)) } }

# Every WindowMetrics value as name -> kind:data (binary as hex), ordinal; for "nothing else changed".
function WindowMetricsSnapshot {
    $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($windowMetricsSubkey)
    $all = [Collections.Generic.Dictionary[string, string]]::new([StringComparer]::Ordinal)
    if ($null -eq $key) { return , $all }
    try {
        foreach ($name in $key.GetValueNames()) {
            $data = $key.GetValue($name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
            $all[$name] = "$($key.GetValueKind($name)):" + $(if ($data -is [byte[]]) { [BitConverter]::ToString($data) } else { [string]($data -join "`n") })
        }
    } finally { $key.Close() }
    , $all
}

# Why this process may not write the user's HKCU fonts, or $null. It must not run with package identity, nor beneath a
# packaged app (an executable under WindowsApps): a shell started inside such an app reads "no package" itself while its
# registry view can still be the app's. Only APPMODEL_ERROR_NO_PACKAGE (0x80073D54) counts as no identity; any other
# answer refuses. Neither check proves the view is the user's own: run from a normal user shell or task.
function PackageContextProblem {
    try {
        $current = [Windows.ApplicationModel.Package, Windows.ApplicationModel, ContentType = WindowsRuntime]::Current
        return "this process has package identity $($current.Id.FullName)"
    } catch {
        $failure, $none = $_.Exception, $false
        while ($null -ne $failure) {
            if ($failure.HResult -eq -2147009196) { $none = $true }  # 0x80073D54, APPMODEL_ERROR_NO_PACKAGE
            $failure = $failure.InnerException
        }
        if (-not $none) { return 'whether this process has package identity is unknown' }
    }
    $processes = @{}
    foreach ($process in @(Get-CimInstance Win32_Process)) { $processes[[int]$process.ProcessId] = $process }
    $id, $seen = $PID, @{}
    while ($processes.ContainsKey($id) -and -not $seen.ContainsKey($id)) {
        $seen[$id] = $true
        $path = [string]$processes[$id].ExecutablePath
        if ($path -match '\\WindowsApps\\') { return "it runs beneath the packaged app $path" }
        $id = [int]$processes[$id].ParentProcessId
    }
    $null
}

# One slot's face, in place: read again now, only while it holds $Expect and (when given) the non-face bytes $Seen of
# the intent's reading; only lfFaceName is written; afterwards the face is $Face, the other bytes are those just read,
# and no other WindowMetrics value changed. A failure is reported as it is: nothing is restored over another writer.
function WriteUiFontFace([string]$Slot, [string]$Expect, [string]$Face, $Seen) {
    $name = $uiFontValues[$Slot]
    $others = WindowMetricsSnapshot
    $now = UiFontBytes $Slot
    if ((Get-LogFontFace $now) -cne $Expect) { throw "Refusing to write HKCU\$windowMetricsSubkey\${name}: its face is not '$Expect'." }
    if ($null -ne $Seen -and -not (Test-LogFontFaceOnly $Seen $now)) { throw "Refusing to write HKCU\$windowMetricsSubkey\${name}: it changed beyond its face since it was read." }
    $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($windowMetricsSubkey, $true)
    try { $key.SetValue($name, (Get-LogFontWithFace $now $Face), [Microsoft.Win32.RegistryValueKind]::Binary) } finally { $key.Close() }
    $script:changed++
    $after, $othersAfter = (UiFontBytes $Slot), (WindowMetricsSnapshot)
    if ((Get-LogFontFace $after) -cne $Face -or -not (Test-LogFontFaceOnly $now $after)) { throw "HKCU\$windowMetricsSubkey\$name does not read back '$Face' with its other bytes." }
    $changedNames = @(@($others.Keys) + @($othersAfter.Keys) | Sort-Object -Unique | Where-Object { $_ -cne $name -and
        (-not $others.ContainsKey($_) -or -not $othersAfter.ContainsKey($_) -or $others[$_] -cne $othersAfter[$_]) })
    if ($changedNames.Count) { throw "WindowMetrics $($changedNames -join ', ') changed while $name was written; check them." }
}

# The faces the readable slots name now; font collection keeps their families.
function UiFaces { foreach ($slot in Get-UiFontSlots) { try { (ObserveUiFont $slot).face } catch { } } }
function NamesFace([string]$Name, $Faces) {
    foreach ($face in @($Faces)) { if ($Name.StartsWith("$face ", [StringComparison]::OrdinalIgnoreCase)) { return $true } }
    return $false
}

# The selected slot effects; prior is the face found when the intent is written.
function UiFontEffects {
    foreach ($slot in Get-UiFontSlots) {
        [ordered]@{ id = "ui-font-face:WINMETRICS:$($slot.ToUpperInvariant())"; kind = 'ui-font-face'; target = "winmetrics:$slot"
            prior = $null; desired = [ordered]@{ exists = $true; face = $uiTypography.face } }
    }
}

# The interpreter package's executable with its locked SHA-256 (the owned tree, or an exact existing install), for the
# advisory live reading only; $null when there is none.
function UiFontInterpreter {
    if ($null -ne $script:uiInterpreter) { return $script:uiInterpreter }
    $package = $manifest.packages | Where-Object { $_.name -ceq (Get-Field $uiTypography 'interpreter') } | Select-Object -First 1
    if ($null -eq $package) { return $null }
    $state = ClassifyPackage $package
    if ($state.class -cnotin @('owned-match', 'preexisting-match')) { return $null }
    $want = (ConvertTo-FileMap $package.files)[$package.executable]
    $candidates = @(Join-Path $state.effect.target $package.executable.Replace('/', '\')) + @(FindUninstallEntries $package.existing |
        Where-Object { $_.installLocation -is [string] -and $_.installLocation.Trim() } |
        ForEach-Object { Join-Path ([Environment]::ExpandEnvironmentVariables($_.installLocation.Trim().Trim('"'))) $package.existing.executable.Replace('/', '\') })
    foreach ($exe in $candidates) {
        if ((Test-Path -LiteralPath $exe -PathType Leaf) -and (Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash -eq $want) {
            $script:uiInterpreter = $exe
            return $exe
        }
    }
    $null
}

# Advisory: the faces this session uses (ui-font.ahk get), slot -> face; $null when they cannot be read.
function UiLiveFaces {
    $exe = UiFontInterpreter
    if ($null -eq $exe) { return $null }
    try { $slots = (Invoke-Native $exe @('/ErrorStdOut', (BundlePath 'ui-font.ahk'), 'get') 60 | ConvertFrom-Json).slots } catch { return $null }
    $live = @{}
    foreach ($slot in Get-UiFontSlots) { $live[$slot] = [string]$slots.$slot.face }
    $live
}

# Apply -Typography and Restore, once the selected fonts are exact: the context is checked, every slot is classified;
# an owned face of an earlier selection goes back to its prior; then per slot an intent, the face-only write and a
# commit read back. A failure recovers that slot at once when it can (written: commit; not: void).
function ConvergeUiFont {
    $problem = PackageContextProblem
    if ($problem) { throw "UI font faces are not written: $problem." }
    $states = @(UiFontEffects | ForEach-Object { [pscustomobject]@{ effect = $_; state = (Classify $_) } })
    foreach ($s in $states) {
        if ($s.state.class -cnotin @('absent', 'owned-match', 'owned-drift', 'preexisting-match')) { throw "UI font $($s.effect.target) is $($s.state.class): $($s.state.reason)" }
    }
    $script:uiFontDrift += @($states | Where-Object { $_.state.class -ceq 'owned-drift' } |
        ForEach-Object { "$($_.effect.target) is '$((Observe $_.effect).face)', not the face this wrote; not written" })
    $changed = @($states | Where-Object { $_.state.class -ceq 'owned-match' -and -not (Test-EffectStateEqual 'ui-font-face' $_.state.recorded $_.effect.desired) })
    if ($changed.Count) {
        $observations = @{}
        foreach ($s in $changed) { $observations[$s.effect.id] = Observe $s.effect }
        $plan = Get-UninstallPlan @($changed | ForEach-Object { RecordsOf $_.effect.id }) $observations
        if (-not $plan.ok) { throw "UI font faces of an earlier selection cannot be reverted: $(@($plan.refused | ForEach-Object { "$($_.id): $($_.reason)" }) -join '; ')" }
        UndoOwnedSteps @(OrderedSteps $plan)
    }
    foreach ($effect in @(@($states | Where-Object { $_.state.class -ceq 'absent' }) + $changed | ForEach-Object { $_.effect })) {
        $slot = $effect.target.Substring('winmetrics:'.Length)
        $seen = UiFontBytes $slot
        $effect.prior = [ordered]@{ exists = $true; face = (Get-LogFontFace $seen) }
        WriteRecord 'intent' $effect $null $null
        try { WriteUiFontFace $slot $effect.prior.face $effect.desired.face $seen } catch {
            $failure = $_
            try { RecoverId $effect.id } catch { Write-Warning "Recovery of $($effect.id) deferred: $($_.Exception.Message)" }
            throw $failure
        }
        WriteRecord 'commit' $effect (Observe $effect)
    }
}

# Read-only: every slot's persisted face is the selected one, owned or not. Whether this session already uses it is
# reported, not asserted (UiFontReport).
function AssertUiFont {
    $wrong = @(UiFontEffects | ForEach-Object { $face = (Observe $_).face; if ($face -cne $uiTypography.face) { "$($_.target) is '$face'" } })
    if ($wrong.Count) { throw "UI font drift (selected '$($uiTypography.face)'): $($wrong -join '; ')" }
}

# Per slot: the persisted face, the live one (advisory) and the state: active (in use), pendingLogon (persisted, used
# after the next sign-in), liveUnknown (no reading) or drift.
function UiFontReport {
    $live = UiLiveFaces
    [ordered]@{ face = $uiTypography.face; slots = @(foreach ($slot in Get-UiFontSlots) {
        $persisted = (ObserveUiFont $slot).face
        $now = if ($null -ne $live) { $live[$slot] } else { $null }
        [ordered]@{ slot = $slot; persisted = $persisted; live = $now
            state = $(if ($persisted -cne $uiTypography.face) { 'drift' } elseif ($null -eq $now) { 'liveUnknown' } elseif ($now -ceq $uiTypography.face) { 'active' } else { 'pendingLogon' }) }
    }) }
}
# ---- Store apps: installed when absent, never owned ------------------------------
# Presence is this user's package of that name and publisher (Get-AppAction), any version: the Store updates
# an app itself, so a restore gets the version the Store serves that day (online only), reported, not pinned.
# An app present is never reinstalled, updated, closed or removed, and its data is never touched.
$script:appDrift = @()

function AppStates {
    foreach ($app in $apps) {
        $found = @(Get-AppxPackage -Name $app.package | ForEach-Object {
            [pscustomobject]@{ name = [string]$_.Name; publisherId = [string]$_.PublisherId; version = [string]$_.Version; installLocation = [string]$_.InstallLocation } })
        [pscustomobject]@{ app = $app; found = $found; action = (Get-AppAction $found $app) }
    }
}

# Restore: each absent app through the official WinGet from the Microsoft Store source, by its exact id.
function ConvergeApps {
    foreach ($state in @(AppStates | Where-Object { $_.action -ceq 'install' })) {
        $winget = Join-Path $localAppData 'Microsoft\WindowsApps\winget.exe'
        if (-not (Test-Path -LiteralPath $winget)) { $script:appDrift += "$($state.app.name): WinGet (App Installer) is missing; not installed"; continue }
        $null = Invoke-Native $winget @('install', '--id', $state.app.id, '--source', 'msstore', '--exact', '--silent', '--disable-interactivity',
            '--accept-package-agreements', '--accept-source-agreements') 1800
        $script:changed++
    }
}

# ---- ChatGPT app fonts (app-theme-fonts effects) through the app's own config service ----------------
# The app keeps its appearance in the user's Codex config (desktop.appearance{Light,Dark}ChromeTheme). It is read and
# written only through the codex.exe app-server the installed package bundles, as the app itself does:
# initialize, config/read with layers, one config/batchWrite guarded by the user layer's expectedVersion, read back.
# No model, thread or account request is made; nothing else of the app (its data, state, other settings) is read
# for output or written. Starting the service lets it do its normal runtime bookkeeping under the Codex home.
# A running app keeps its theme in memory until it restarts, and writes the whole theme itself when the user
# changes appearance, which then wins (owned-drift here). Nothing here starts, stops or restarts the app.
$script:appFontDrift, $script:appRead = @(), $null
# $null when no app is preconfigured (Select-Object: under strict mode an index into an empty list throws).
$appearanceApp = $apps | Where-Object { $null -ne (Get-Field $_ 'appearance') } | Select-Object -First 1
function IsAppFontEffect($Record) { (Get-Field $Record 'kind') -ceq 'app-theme-fonts' }
function AppFontsPresent { @(AppStates | Where-Object { $_.app.package -ceq $appearanceApp.package -and $_.action -ceq 'present' }).Count -eq 1 }

# The present app's bundled codex.exe (Get-AppAction: exactly one package of that name and publisher).
function AppServerExe {
    if ($null -eq $appearanceApp) { throw 'This distribution preconfigures no app.' }
    $state = AppStates | Where-Object { $_.app.package -ceq $appearanceApp.package } | Select-Object -First 1
    if ($null -eq $state -or $state.action -cne 'present') { throw "$($appearanceApp.name) is not installed (one package $($appearanceApp.package) of publisher $($appearanceApp.publisherId)); its config service is unavailable." }
    $exe = Join-Path $state.found[0].installLocation 'app\resources\codex.exe'
    if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) { throw "$exe is missing." }
    $exe
}

# One app-server session: a process whose stdin, stdout and stderr are UTF-8 pipes, stderr drained (never printed:
# it may hold config), every request answered before one absolute deadline; closed only if it started.
function NewAppSession { [pscustomobject]@{ process = $null; started = $false; stderr = $null; pending = $null; next = 0; deadline = [DateTime]::UtcNow.AddSeconds(120) } }
function StartAppSession($Session) {
    $info = [Diagnostics.ProcessStartInfo]::new((AppServerExe), 'app-server')
    $info.UseShellExecute, $info.CreateNoWindow = $false, $true
    $info.RedirectStandardInput, $info.RedirectStandardOutput, $info.RedirectStandardError = $true, $true, $true
    $info.StandardOutputEncoding, $info.StandardErrorEncoding = [Text.UTF8Encoding]::new($false), [Text.UTF8Encoding]::new($false)
    $Session.process = [Diagnostics.Process]::new()
    $Session.process.StartInfo = $info
    # Windows PowerShell 5.1's stdin writer takes the console input encoding and writes its preamble at start: a UTF-8
    # BOM the service rejects ("expected value at line 1 column 1"). Start with the same code page without a
    # preamble, then put the console's encoding back.
    $console = $null
    try { if ([Console]::InputEncoding.GetPreamble().Length) { $console = [Console]::InputEncoding; [Console]::InputEncoding = [Text.UTF8Encoding]::new($false) } } catch { $console = $null }
    try { $Session.started = $Session.process.Start() } finally { if ($null -ne $console) { try { [Console]::InputEncoding = $console } catch { } } }
    if ($Session.process.StandardInput.Encoding.GetPreamble().Length) { throw "The $($appearanceApp.name) config service cannot be given a UTF-8 pipe without a byte order mark here." }
    $Session.stderr = $Session.process.StandardError.ReadToEndAsync()
    $null = AppCall $Session 'initialize' @{ clientInfo = @{ name = 'windows_iac'; title = 'windows-iac'; version = '1' } }
    AppSend $Session ([ordered]@{ method = 'initialized'; params = @{} })
}
function CloseAppSession($Session) {
    if ($null -eq $Session.process) { return }
    try {
        if ($Session.started) {
            try { $Session.process.StandardInput.Close() } catch { }
            if (-not $Session.process.WaitForExit(5000)) { try { $Session.process.Kill() } catch { }; $null = $Session.process.WaitForExit(5000) }
        }
    } finally { $Session.process.Dispose() }
}
# stdin as UTF-8 bytes (Windows PowerShell 5.1 has no StandardInputEncoding), one JSON message per line.
function AppSend($Session, $Message) {
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes(($Message | ConvertTo-Json -Depth 20 -Compress) + "`n")
    $Session.process.StandardInput.BaseStream.Write($bytes, 0, $bytes.Length)
    $Session.process.StandardInput.BaseStream.Flush()
}
# One request and its answer; notifications and other messages are skipped. An error answer stops the run naming only the
# method and the JSON-RPC error code: no message, line of output or stderr is ever printed.
function AppCall($Session, [string]$Method, $Params) {
    $Session.next++
    $id = $Session.next
    AppSend $Session ([ordered]@{ id = $id; method = $Method; params = $Params })
    while ($true) {
        $left = ($Session.deadline - [DateTime]::UtcNow).TotalMilliseconds
        if ($null -eq $Session.pending) { $Session.pending = $Session.process.StandardOutput.ReadLineAsync() }
        if ($left -le 0 -or -not $Session.pending.Wait([int][Math]::Max(0, $left))) { throw "The $($appearanceApp.name) config service did not answer $Method in time." }
        $line = $Session.pending.Result
        $Session.pending = $null
        if ($null -eq $line) { throw "The $($appearanceApp.name) config service ended during $Method." }
        if (-not $line.Trim()) { continue }
        try { $message = $line | ConvertFrom-Json } catch { throw "The $($appearanceApp.name) config service answered $Method with a line that is not JSON." }
        if ($null -ne (Get-Field $message 'method') -or [string](Get-Field $message 'id') -cne [string]$id) { continue }
        $failure = Get-Field $message 'error'
        # Never the service's message: a config parse error quotes the offending TOML line, which may hold a secret.
        if ($null -ne $failure) { throw "The $($appearanceApp.name) config service refused $Method (error $([string](Get-Field $failure 'code'))); details not printed." }
        return (Get-Field $message 'result')
    }
}

# The config as the service reads it: the effective config, and exactly the user layer (the one without a profile)
# with its file and version. A disabled (read-only) or repeated user layer stops the run; no user layer is accepted
# only while the default config file does not exist (a fresh install), and then nothing guards the version.
function ReadAppConfig($Session) {
    $read = AppCall $Session 'config/read' @{ includeLayers = $true; cwd = $null }
    $users = @(Get-Field $read 'layers' | Where-Object { (Get-Field (Get-Field $_ 'name') 'type') -ceq 'user' -and $null -eq (Get-Field (Get-Field $_ 'name') 'profile') })
    $codexHome = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $env:USERPROFILE '.codex' }  # not $home: that is $HOME
    if ($users.Count -gt 1) { throw 'The Codex config has more than one user layer; nothing is written.' }
    if ($users.Count -eq 0 -and (Test-Path -LiteralPath (Join-Path $codexHome 'config.toml'))) { throw 'The Codex config service reads no user layer beside an existing config.toml; nothing is written.' }
    if ($users.Count -and $null -ne (Get-Field $users[0] 'disabledReason')) { throw 'The Codex user config layer is disabled (read-only); reason not printed; nothing is written.' }
    [pscustomobject]@{ effective = (Get-Field $read 'config')
        user = $(if ($users.Count) { ConvertFrom-LayerNumbers (Get-Field $users[0] 'config') } else { $null })
        version = $(if ($users.Count) { [string](Get-Field $users[0] 'version') } else { $null })
        file = $(if ($users.Count) { [string](Get-Field (Get-Field $users[0] 'name') 'file') } else { $null }) }
}

# The last reading, or one new session's reading; every write replaces it.
function AppConfig {
    if ($null -eq $script:appRead) {
        $session = NewAppSession
        try { StartAppSession $session; $script:appRead = ReadAppConfig $session } finally { CloseAppSession $session }
    }
    $script:appRead
}
function AppTheme($Read, [string]$Key) { Get-Field (Get-Field $Read.user 'desktop') $Key }
function ObserveAppFonts([string]$Key) { [ordered]@{ exists = $true; fonts = (Get-AppFontsState (Get-Field (AppTheme (AppConfig) $Key) 'fonts')) } }

function AppFontEffects {
    $fonts = $appearanceApp.appearance.fonts
    foreach ($key in Get-AppThemeKeys) {
        [ordered]@{ id = "app-theme-fonts:CODEX-CONFIG:DESKTOP.$($key.ToUpperInvariant())"; kind = 'app-theme-fonts'; target = "codex-config:desktop.$key"
            prior = $null; desired = [ordered]@{ exists = $true; fonts = [ordered]@{ ui = $fonts.ui; code = $fonts.code; content = $fonts.content } } }
    }
}

# The families the owned app fonts name, from the ledger alone (font collection keeps them).
function AppFontFamilies {
    foreach ($id in @(LedgerIds | Where-Object { IsAppFontEffect @(RecordsOf $_)[0] })) {
        $open = @(OpenAttempt $id)
        if ($open.Count) { foreach ($value in (Get-AppFontsState (Get-Field (Get-Field $open[0] 'desired') 'fonts')).Values) { if ($value -is [string]) { Get-CssFamilies $value } } }
    }
}

# One batchWrite of $Edits in $Session against the reading $Read, and the reading after it. Everything in the user
# config but what $Keys/$Created may change must be unchanged (Get-AppConfigRest), or the run stops as drift.
function WriteAppConfig($Session, $Read, $Edits, [string[]]$Keys, [string[]]$Created) {
    $before = Get-AppConfigRest $Read.user $Keys $Created
    $script:appRead = $null
    $result = AppCall $Session 'config/batchWrite' ([ordered]@{ edits = @($Edits); filePath = $(if ($Read.file) { $Read.file } else { $null })
        expectedVersion = $Read.version; reloadUserConfig = $true })
    $script:appRead = ReadAppConfig $Session
    $script:changed++
    if ((Get-Field $result 'status') -cne 'ok') { $script:appFontDrift += "the written app fonts are overridden by another config layer ($(Get-Field $result 'status'))" }
    if ((Get-AppConfigRest $script:appRead.user $Keys $Created) -cne $before) { $script:appFontDrift += 'the Codex user config changed beyond the app fonts during the write; check it' }
    $script:appRead
}

# Undo of one owned theme's fonts (Get-AppFontUndoEdits), in $Session or a new one, only while the fonts are those written.
function UndoAppFonts($Step, $Session) {
    $own = $null -eq $Session
    if ($own) { $Session = NewAppSession }
    try {
        if ($own) { StartAppSession $Session }
        $read = ReadAppConfig $Session
        $script:appRead = $read
        $theme = AppTheme $read $Step.theme
        if ((ConvertTo-CanonicalJson (Get-AppFontsState (Get-Field $theme 'fonts'))) -cne (ConvertTo-CanonicalJson $Step.expectFonts)) {
            throw "Refusing to revert the app fonts of $($Step.theme): they changed since they were read."
        }
        $edits = Get-AppFontUndoEdits $Step $theme
        $whole = @($edits | Where-Object { $_.keyPath -ceq "desktop.$($Step.theme)" }).Count -gt 0
        $null = WriteAppConfig $Session $read $edits @($Step.theme) @(if ($whole) { $Step.theme })
        # 26.928.1915.0 keeps the emptied fonts table, and the app reads missing ui and code as null; a service that dropped
        # the table would leave a theme the app discards whole, colors included: that is reported, never left silent.
        $left = AppTheme $script:appRead $Step.theme
        if ($null -ne $left -and (Get-AppThemeProblem $left)) { $script:appFontDrift += "desktop.$($Step.theme) is no longer a theme the app accepts after its fonts were removed" }
    } finally { if ($own) { CloseAppSession $Session } }
}

# Apply -Typography and Restore, for the present app: in one session, recovery of these two effects, their classes, a
# changed selection reverted first, then one intent per theme to write, one batchWrite (expectedVersion), the reading
# after it and a commit per theme read back. A theme another config layer sets, or one the app would drop as invalid
# after the change, is drift and not written; so are fonts changed after this wrote them.
function ConvergeAppFonts {
    $session = NewAppSession
    try {
        StartAppSession $session
        $script:appRead = ReadAppConfig $session
        foreach ($effect in @(AppFontEffects)) { RecoverId $effect.id }
        $states = @(AppFontEffects | ForEach-Object { [pscustomobject]@{ effect = $_; state = (Classify $_) } })
        foreach ($s in $states) {
            if ($s.state.class -cnotin @('absent', 'owned-match', 'owned-drift', 'preexisting-match')) { throw "App fonts $($s.effect.target) are $($s.state.class): $($s.state.reason)" }
        }
        $script:appFontDrift += @($states | Where-Object { $_.state.class -ceq 'owned-drift' } | ForEach-Object { "$($_.effect.target) fonts differ from those this wrote; not written" })
        $changed = @($states | Where-Object { $_.state.class -ceq 'owned-match' -and -not (Test-EffectStateEqual 'app-theme-fonts' $_.state.recorded $_.effect.desired) })
        foreach ($s in $changed) {
            $step = @(Get-UndoSteps @(OpenAttempt $s.effect.id)[0])[0]
            UndoAppFonts $step $session
            WriteRecord 'undone' @(OpenAttempt $s.effect.id)[0] (Observe $s.effect)
        }
        $read = AppConfig
        $write, $edits, $created = @(), @(), @()
        foreach ($effect in @(@($states | Where-Object { $_.state.class -ceq 'absent' }) + $changed | ForEach-Object { $_.effect })) {
            $key = $effect.target.Substring('codex-config:desktop.'.Length)
            $theme = AppTheme $read $key
            if ((ConvertTo-CanonicalJson (Get-Field (Get-Field $read.effective 'desktop') $key)) -cne (ConvertTo-CanonicalJson $theme)) {
                $script:appFontDrift += "another Codex config layer sets desktop.$key; not written"; continue
            }
            $themeEdits = Get-AppFontEdits $key $theme $effect.desired.fonts (Get-Field $appearanceApp.appearance.defaults $(if ($key -clike '*Light*') { 'light' } else { 'dark' }))
            $after = Get-AppThemeAfter $key $theme $themeEdits
            $problem = Get-AppThemeProblem $after
            if ($problem) { $script:appFontDrift += "desktop.$key would not be a theme the app accepts ($problem); not written"; continue }
            $effect.prior = ObserveAppFonts $key
            if ($null -eq $theme) { $effect.desired.theme = $after; $created += $key }
            $write += $effect
            $edits += $themeEdits
        }
        if (-not $write.Count) { return }
        foreach ($effect in $write) { WriteRecord 'intent' $effect $null $null }
        try {
            $null = WriteAppConfig $session $read $edits @(Get-AppThemeKeys) $created
            $wrong = @($write | Where-Object { -not (Test-EffectStateEqual 'app-theme-fonts' $_.desired (Observe $_)) } | ForEach-Object { $_.target })
            if ($wrong.Count) { throw "The Codex user config does not read back the app fonts for $($wrong -join ', ')." }
        } catch {
            $failure = $_
            try { $script:appRead = ReadAppConfig $session } catch { $script:appRead = $null }  # recovery reads this session's state
            foreach ($effect in $write) { try { RecoverId $effect.id } catch { Write-Warning "Recovery of $($effect.id) deferred: $($_.Exception.Message)" } }
            throw $failure
        }
        foreach ($effect in $write) { WriteRecord 'commit' $effect (Observe $effect) }
        foreach ($effect in $write) {
            $key = $effect.target.Substring('codex-config:desktop.'.Length)
            $effective = Get-AppFontsState (Get-Field (Get-Field (Get-Field $script:appRead.effective 'desktop') $key) 'fonts')
            if ((ConvertTo-CanonicalJson $effective) -cne (ConvertTo-CanonicalJson $effect.desired.fonts)) { $script:appFontDrift += "desktop.$key fonts are overridden by another config layer" }
        }
    } finally { CloseAppSession $session }
}

# ---- Chromium font preferences in existing profiles (pref-value effects, Apply -ChromiumFonts) ----------
# A new profile gets the fonts from the seed (initial_preferences). An existing profile is protected data no mode owns,
# with one documented exception: -ChromiumFonts writes exactly the seed's six font leaves (webkit.webprefs.fonts.
# {standard,sansserif,fixed}.{Zyyy,Jpan}) into each normal profile Local State lists, and Uninstall removes them again.
# Chromium 154 registers these prefs without a sync flag (prefs_tab_helper.cc), so no account or sync value overrides
# them. Only the leaves' bytes change (Get-PrefsFontEdit): every other byte, number and key stays. Only while Chromium
# is closed: no lockfile (never removed here), no chrome.exe of this install or with an unreadable path, and no
# preference MAC that tracks webkit (an edit would then be reset or flagged).
$chromiumPackage = $manifest.packages | Where-Object { $null -ne (Get-Field $_ 'seed') } | Select-Object -First 1
$chromiumUserData = $null
if ($null -ne $chromiumPackage) {
    $userDataPath = @($chromiumPackage.protected) | Where-Object { $_ -clike '*/User Data' } | Select-Object -First 1
    if ($userDataPath) { $chromiumUserData = Join-Path $localAppData $userDataPath.Replace('/', '\') }
}
$script:prefDrift, $script:prefScans, $script:chromiumFontsResult = @(), @{}, @()

# The Framework's JSON reader (an installed assembly, loaded, never compiled), bounded as the scan is; only for
# validation and comparison, never to write a profile.
function JsonReader {
    Add-Type -AssemblyName System.Web.Extensions
    $reader = New-Object System.Web.Script.Serialization.JavaScriptSerializer
    $reader.MaxJsonLength, $reader.RecursionLimit = 16MB, 100
    $reader
}
function JsonAt($Document, [string]$Path) {
    $value = $Document
    foreach ($key in $Path.Split('.')) { $value = if ($value -is [Collections.IDictionary] -and $value.ContainsKey($key)) { $value[$key] } else { return $null } }
    $value
}

# The six values: the bundled seed's own (bundle inventory-checked), so no font data is declared twice.
function ChromiumFontValues {
    $seed = (JsonReader).DeserializeObject([IO.File]::ReadAllText((BundlePath $chromiumPackage.seed.file), [Text.Encoding]::UTF8))
    $values = [ordered]@{}
    foreach ($leaf in Get-ChromiumFontLeaves) {
        $value = JsonAt $seed $leaf
        if ($value -isnot [string] -or -not $value) { throw "The bundled seed has no $leaf." }
        $values[$leaf] = $value
    }
    $values
}

function IsChromiumPrefs([string]$Path) {
    $null -ne $chromiumUserData -and [IO.Path]::GetFileName($Path) -ceq 'Preferences' -and
        [IO.Path]::GetDirectoryName([IO.Path]::GetDirectoryName($Path)) -eq $chromiumUserData -and
        [IO.Path]::GetFileName([IO.Path]::GetDirectoryName($Path)) -cmatch '^(Default|Profile [1-9][0-9]{0,3})\z'
}

# The normal profiles Local State's profile.info_cache lists (Default, Profile N; never Guest or System Profile), each a
# plain directory with a plain Preferences file directly in User Data.
function ChromiumProfiles {
    foreach ($path in @($chromiumUserData, (Join-Path $chromiumUserData 'Local State'))) {
        $item = Get-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
        if ($null -eq $item -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw "$path is missing or a reparse point; no Chromium profile is configured." }
    }
    $cache = JsonAt ((JsonReader).DeserializeObject([IO.File]::ReadAllText((Join-Path $chromiumUserData 'Local State'), [Text.Encoding]::UTF8))) 'profile.info_cache'
    if ($cache -isnot [Collections.IDictionary]) { throw 'Local State has no profile.info_cache.' }
    foreach ($name in @($cache.Keys | Sort-Object)) {
        if ($name -cnotmatch '^(Default|Profile [1-9][0-9]{0,3})\z') { continue }
        $dir = Join-Path $chromiumUserData $name
        foreach ($path in @($dir, (Join-Path $dir 'Preferences'))) {
            $item = Get-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
            if ($null -eq $item -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw "$path is missing or a reparse point." }
        }
        $dir
    }
}

# Why a profile may not be written now, or $null.
function ChromiumClosedProblem([string]$Dir) {
    $lock = Join-Path $chromiumUserData 'lockfile'
    if (Test-Path -LiteralPath $lock) { return "$lock exists: Chromium is running or did not close cleanly (the file is never removed here)" }
    $roots = @((Join-Path $localAppData 'Programs\chromium-')) + @(FindUninstallEntries $chromiumPackage.existing | Where-Object { $_.installLocation -is [string] -and $_.installLocation.Trim() } |
        ForEach-Object { [Environment]::ExpandEnvironmentVariables($_.installLocation.Trim().Trim('"')).TrimEnd('\') + '\' })
    foreach ($process in @(Get-CimInstance Win32_Process -Filter "Name = 'chrome.exe'")) {
        $path = [string]$process.ExecutablePath
        if (-not $path) { return "a chrome.exe (process $($process.ProcessId)) whose path cannot be read is running" }
        if (@($roots | Where-Object { $path.StartsWith($_, [StringComparison]::OrdinalIgnoreCase) }).Count) { return "Chromium is running ($path)" }
    }
    foreach ($file in 'Secure Preferences', 'Preferences') {
        $path = Join-Path $Dir $file
        if ($file -ceq 'Preferences') { $null = ReadPrefs $path }  # the strict scan first: a repeated key is refused as such
        if ((Test-Path -LiteralPath $path -PathType Leaf) -and $null -ne (JsonAt (JsonAt ((JsonReader).DeserializeObject([IO.File]::ReadAllText($path, [Text.Encoding]::UTF8))) 'protection.macs') 'webkit')) {
            return "$file protects webkit preferences with a MAC"
        }
    }
    $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey("Software\Chromium\PreferenceMACs\$([IO.Path]::GetFileName($Dir))")
    if ($null -ne $key) {
        try { if (@(@($key.GetValueNames()) + @($key.GetSubKeyNames()) | Where-Object { $_ -like 'webkit*' }).Count) { return 'PreferenceMACs protect webkit preferences' } } finally { $key.Close() }
    }
    $null
}

# A Preferences file read strictly (no BOM, valid UTF-8, one JSON object without a repeated key), scanned once per content.
function ReadPrefs([string]$Path) {
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if ($null -eq $item) { return $null }
    if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw "Not a plain file: $Path" }
    $bytes = [IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) { throw "$Path starts with a byte order mark; not edited." }
    $hasher = [Security.Cryptography.SHA256]::Create()
    try { $sha = -join ($hasher.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') }) } finally { $hasher.Dispose() }
    if ($script:prefScans.ContainsKey($Path) -and $script:prefScans[$Path].sha -ceq $sha) { return $script:prefScans[$Path] }
    try { $text = [Text.UTF8Encoding]::new($false, $true).GetString($bytes) } catch { throw "$Path is not valid UTF-8; not edited." }
    $read = [pscustomobject]@{ sha = $sha; text = $text; root = (Get-JsonScan $text) }
    $script:prefScans[$Path] = $read
    $read
}
function FileSha([string]$Path) { (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }

function ObservePref([string]$Path, [string]$Name) {
    $read = ReadPrefs $Path
    if ($null -eq $read) { return [ordered]@{ exists = $false } }
    $at = Resolve-JsonPath $read.root $Name
    if ($at.blocked) { throw "$Name in $Path passes through a value that is not an object." }
    if ($null -eq $at.member) { return [ordered]@{ exists = $false } }
    if ($at.member.value.kind -cne 'string') { throw "$Name in $Path is not a string." }
    [ordered]@{ exists = $true; value = (ConvertFrom-JsonString $read.text.Substring($at.member.valueStart, $at.member.valueEnd - $at.member.valueStart)) }
}

function PrefEffect([string]$Prefs, [string]$Leaf, [string]$Value) {
    [ordered]@{ id = 'pref-value:' + ($Prefs + '|' + $Leaf).ToUpperInvariant(); kind = 'pref-value'; target = $Prefs; name = $Leaf
        prior = [ordered]@{ exists = $false }; desired = [ordered]@{ exists = $true; value = $Value } }
}

# The edited text must scan (no repeated key) and, read by the Framework reader, equal the original but for $Leaves and the
# parents $Parents (pruned while empty); otherwise nothing is written.
function VerifyPrefsEdit([string]$Before, [string]$After, [string[]]$Leaves, [string[]]$Parents) {
    $null = Get-JsonScan $After
    $omit = [Collections.Generic.Dictionary[string, string]]::new([StringComparer]::Ordinal)
    foreach ($leaf in $Leaves) { $omit[$leaf] = 'drop' }
    foreach ($parent in $Parents) { $omit[$parent] = 'prune' }
    $reader = JsonReader
    if ((ConvertTo-CanonicalJson $reader.DeserializeObject($Before) '' $omit) -cne (ConvertTo-CanonicalJson $reader.DeserializeObject($After) '' $omit)) {
        throw 'The edit would change the profile beyond its font values; nothing written.'
    }
}

# $Text into $Prefs as UTF-8 without BOM: a temporary file beside it, then, with Chromium still closed and the file still
# the one read ($Sha), one File.Replace; the result must read back as written.
function ReplacePrefs([string]$Prefs, [string]$Text, [string]$Sha, [string]$Temp) {
    $problem = PackageContextProblem  # every Preferences write (converge and undo) passes here
    if ($problem) { throw "$Prefs is not written: $problem." }
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes($Text)
    $out = [IO.FileStream]::new($Temp, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None, 4096, [IO.FileOptions]::WriteThrough)
    try { $out.Write($bytes, 0, $bytes.Length); $out.Flush($true) } finally { $out.Dispose() }
    $problem = ChromiumClosedProblem ([IO.Path]::GetDirectoryName($Prefs))
    if ($problem) { throw "$Prefs is not written: $problem." }
    if ((FileSha $Prefs) -cne $Sha) { throw "$Prefs changed while it was edited; nothing written." }
    [IO.File]::Replace($Temp, $Prefs, [NullString]::Value)  # no backup file; a plain $null would be passed as '' (an illegal path)
    $script:prefScans.Remove($Prefs)
    $hasher = [Security.Cryptography.SHA256]::Create()
    try { $want = -join ($hasher.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') }) } finally { $hasher.Dispose() }
    if ((FileSha $Prefs) -cne $want) { throw "$Prefs does not read back what was written." }
}

# Apply -ChromiumFonts: per profile, every leaf classified first; an absent leaf is written (one intent each, then one
# File.Replace for the profile, then a commit each); the same value already there is preexisting-match, never owned;
# another value is the user's (preexisting-drift) and an owned value changed since is owned-drift: both reported, never written.
function ConvergeChromiumFonts {
    if ($null -eq $chromiumUserData) { throw 'This distribution declares no Chromium profile location.' }
    $problem = PackageContextProblem  # the profile is user data: never written from a packaged app's view
    if ($problem) { throw "Chromium font preferences are not written: $problem." }
    $values = ChromiumFontValues
    foreach ($dir in @(ChromiumProfiles)) {
        $name, $prefs = ([IO.Path]::GetFileName($dir)), (Join-Path $dir 'Preferences')
        $problem = ChromiumClosedProblem $dir
        if ($problem) { $script:prefDrift += "${name}: $problem; not written"; continue }
        $add, $write = [ordered]@{}, @()
        foreach ($effect in @(Get-ChromiumFontLeaves | ForEach-Object { PrefEffect $prefs $_ $values[$_] })) {
            $state = Classify $effect
            switch -CaseSensitive ($state.class) {
                'absent' { $add[$effect.name] = $effect.desired.value; $write += $effect }
                'preexisting-match' { }
                'owned-match' { if (-not (Test-EffectStateEqual 'pref-value' $state.recorded $effect.desired)) { $script:prefDrift += "${name} $($effect.name): owned for an earlier selection; Uninstall, then Apply" } }
                'preexisting-drift' { $script:prefDrift += "${name} $($effect.name): another font chosen in this profile; kept" }
                'owned-drift' { $script:prefDrift += "${name} $($effect.name): changed after this wrote it; kept" }
                default { throw "${name} $($effect.name) is $($state.class): $($state.reason)" }
            }
        }
        $script:chromiumFontsResult += [ordered]@{ profile = $name; written = @($write).Count }
        if (-not $write.Count) { continue }
        $read = ReadPrefs $prefs
        $edit = Get-PrefsFontEdit $read.text $read.root $add
        VerifyPrefsEdit $read.text $edit.text @($add.Keys) @($edit.created.Values | ForEach-Object { $_ } | Sort-Object -Unique)
        $temp = $prefs + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
        foreach ($effect in $write) { $effect.desired.created = [string[]]@($edit.created[$effect.name]); WriteRecord 'intent' $effect $null $temp }
        try { ReplacePrefs $prefs $edit.text $read.sha $temp } catch {
            $failure = $_
            if (Test-Path -LiteralPath $temp -PathType Leaf) { [IO.File]::Delete($temp) }
            foreach ($effect in $write) { try { RecoverId $effect.id } catch { Write-Warning "Recovery of $($effect.id) deferred: $($_.Exception.Message)" } }
            throw $failure
        }
        foreach ($effect in $write) { WriteRecord 'commit' $effect (Observe $effect) }
        $script:changed++
    }
}

# Undo of one owned leaf (Uninstall), only while it still holds the value written: the member, and each parent its
# intent created that is then empty, removed; every other byte kept.
function UndoPrefValue($Step) {
    $prefs = $Step.path
    $problem = ChromiumClosedProblem ([IO.Path]::GetDirectoryName($prefs))
    if ($problem) { throw "Refusing to remove $($Step.name) from ${prefs}: $problem." }
    $now = ObservePref $prefs $Step.name
    if (-not $now.exists -or $now.value -cne $Step.expectValue) { throw "Refusing to remove $($Step.name) from ${prefs}: it changed since it was read." }
    $read = ReadPrefs $prefs
    $text = Get-PrefsFontUndo $read.text $Step.name $Step.created
    VerifyPrefsEdit $read.text $text @($Step.name) $Step.created
    $temp = $prefs + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
    try { ReplacePrefs $prefs $text $read.sha $temp } finally { if (Test-Path -LiteralPath $temp -PathType Leaf) { [IO.File]::Delete($temp) } }
    $script:removed++
}

# The families owned Chromium font values name, from the ledger alone (font collection keeps them).
function ChromiumFontFamilies {
    foreach ($id in @(LedgerIds | Where-Object { (Get-Field @(RecordsOf $_)[0] 'kind') -ceq 'pref-value' })) {
        $open = @(OpenAttempt $id)
        if ($open.Count) { [string](Get-Field (Get-Field $open[0] 'desired') 'value') }
    }
}

# Read-only (the service still does its bookkeeping): both themes of the present app name the selected fonts, in the
# user layer and in effect, and each theme is one the app accepts.
function AssertAppFonts {
    $read = AppConfig
    foreach ($effect in @(AppFontEffects)) {
        $key = $effect.target.Substring('codex-config:desktop.'.Length)
        $user, $effective = (AppTheme $read $key), (Get-Field (Get-Field $read.effective 'desktop') $key)
        foreach ($theme in @($user, $effective)) {
            $problem = if ($null -eq $theme) { 'absent' } else { Get-AppThemeProblem $theme }
            if (-not $problem -and (ConvertTo-CanonicalJson (Get-AppFontsState (Get-Field $theme 'fonts'))) -cne (ConvertTo-CanonicalJson $effect.desired.fonts)) { $problem = 'other fonts' }
            if ($problem) { throw "App font drift: desktop.$key is $problem." }
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
    # App Paths default values name a tree too: every name a lock declares or the ledger owns, in HKCU and HKLM.
    $appNames = @(@($manifest.packages | ForEach-Object { Get-Field $_ 'appPath' }) + @(LedgerIds | ForEach-Object {
        $first = @(RecordsOf $_)[0]; if (IsAppPathEffect $first) { [IO.Path]::GetFileName([string](Get-Field $first 'target')) } }) |
        Where-Object { $_ } | Sort-Object -Unique)
    $references = @(NocttyReferences $registryViews ($servers + @($appNames | ForEach-Object { "$appPathsSubkey\$_" })))
    $removed = @($Steps | Where-Object { $_.action -ceq 'delete-registry-value' } | ForEach-Object { $_.id })
    foreach ($id in $trees) {
        $problem = Get-TreeReferenceProblem $references ([string](Get-Field @(RecordsOf $id)[0] 'target')) $removed
        if ($problem) { "${id}: $problem" }
    }
}

# ---- Locked packages: one owned tree per package through the effect ledger ----------
$script:packageDrift = @()
# The per-user App Paths root; only <appPath>, its key and default value, is ever owned beneath it.
$appPathsSubkey = 'Software\Microsoft\Windows\CurrentVersion\App Paths'

# The owned launch-by-name effects of a package with an appPath (Nix names it): the key
# HKCU\...\App Paths\<appPath> and its default value, a REG_SZ naming the owned executable.
function AppPathEffects($Package) {
    $subkey = "$appPathsSubkey\$($Package.appPath)"
    [ordered]@{ key = (KeyEffect $subkey)
        value = (ValueEffect '' (Join-Path (PackageEffect $Package).target $Package.executable.Replace('/', '\')) ('HKCU\' + $subkey)) }
}

# True for a record of an App Paths effect, by its shape and not by the lock, so a name the lock no longer
# declares (retired or renamed) stays readable for collection and Uninstall: the key App Paths\<name>.exe
# (one segment, as pack.py and AssertPackageShape allow) or that key's default value.
function IsAppPathEffect($Record) {
    $kind, $target, $name = [string](Get-Field $Record 'kind'), [string](Get-Field $Record 'target'), (Get-Field $Record 'name')
    $prefix = "HKCU\$appPathsSubkey\"
    if (-not $target.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { return $false }
    $leaf = $target.Substring($prefix.Length)
    $leaf -cmatch '^[A-Za-z0-9][A-Za-z0-9._-]*\.exe\z' -and (Test-PathSegment $leaf) -and
        ($kind -ceq 'registry-key-created' -or ($kind -ceq 'registry-value' -and $name -is [string] -and $name -ceq ''))
}

# The HKLM App Paths entries (64- and 32-bit views) for $Name, read-only: HKCU would shadow each of them.
function MachineAppPath([string]$Name) {
    foreach ($view in @($registryViews | Where-Object { $_[1] -ceq 'LocalMachine' })) {
        $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey($view[1], $view[2])
        try { $key = $base.OpenSubKey("$appPathsSubkey\$Name"); if ($null -ne $key) { $key.Close(); "$($view[0])\$appPathsSubkey\$Name" } } finally { $base.Close() }
    }
}

# The class of one effect now against the ledger; an attempt still to be resolved reads as indeterminate.
function EffectClass($Effect) {
    $class = Get-EffectClass $null (Observe $Effect) $Effect.kind $Effect.desired (AttemptOf $Effect.id)
    if ($class.resolution) { 'indeterminate' } else { $class.class }
}

# Read-only: the App Paths name of a package this run owns exactly or has just installed, as { name; effects;
# write; converged; reason }, or $null when the package declares none or is not ours to launch now (not owned,
# drift, a conflict, or a profile its seed would overwrite, O1). K-rule: it is written only while the key and its
# default value are each absent or owned; a key or value this distribution does not own is drift even when its
# data is ours (never taken over), and so is the name in HKLM (either view), which HKCU would shadow. An owned key
# meeting such a conflict is only reported (Uninstall removes it).
function AppPathState($State) {
    $name = Get-Field $State.package 'appPath'
    if ($null -eq $name -or $State.hazard -or $State.conflict -or -not ($State.install -or $State.class -ceq 'owned-match')) { return $null }
    $effects = AppPathEffects $State.package
    $machine = @(MachineAppPath $name)
    $key, $value = (EffectClass $effects.key), (EffectClass $effects.value)
    $attempt = AttemptOf $effects.value.id
    $recorded = if (@($attempt.records).Count -and -not $attempt.closed) { Get-Field @($attempt.records)[0] 'desired' } else { $null }
    $reason = if ($machine.Count) {
            "$($machine -join ', ') registers $name for this machine, which HKCU would shadow; nothing is written$(if ($key -like 'owned-*') { ' (Uninstall removes ours)' })"
        } elseif ($key -cnotin @('absent', 'owned-match') -or $value -cnotin @('absent', 'owned-match', 'owned-drift')) {
            "$($effects.key.target) is $key and its default value ${value}: not this distribution's, never taken over; remove it by hand, then Restore"
        }
    $write = -not $reason -and ($key -cne 'owned-match' -or $value -cne 'owned-match' -or -not (Test-EffectStateEqual 'registry-value' $recorded $effects.value.desired))
    [pscustomobject]@{ name = $name; effects = $effects; write = $write; converged = -not $reason -and -not $write; reason = $reason }
}

# Creates or re-owns an App Paths name AppPathState found writable: the shared App Paths key if missing (never
# owned), then the key, then its default value (an owned value naming an older tree is reverted and written again).
function ConvergeAppPath($AppPath) {
    SharedKey $appPathsSubkey
    ConvergeEffect $AppPath.effects.key "App Paths $($AppPath.name)" { CreateOwnedKey $AppPath.effects.key }
    ConvergeEffect $AppPath.effects.value "App Paths $($AppPath.name) default value" { CreateOwnedValue $AppPath.effects.value }
}

# Owned App Paths names no lock declares any more (retired or renamed), removed the Uninstall way: value, then key,
# only while the key holds nothing else (A3); anything refused is kept and reported. None while a package's seed
# would overwrite a profile (O1: nothing of that package is written or removed then).
function CollectAppPathGarbage($States) {
    if (@($States | Where-Object { $_.hazard }).Count) { return }
    $declared = @($manifest.packages | ForEach-Object { Get-Field $_ 'appPath' } | Where-Object { $null -ne $_ })
    $prefix = "HKCU\$appPathsSubkey\"
    $ids = @(LedgerIds | Where-Object {
        $first = @(RecordsOf $_)[0]
        (IsAppPathEffect $first) -and @(OpenAttempt $_).Count -and $declared -notcontains ([string](Get-Field $first 'target')).Substring($prefix.Length) })
    if (-not $ids.Count) { return }
    $observations = @{}
    foreach ($id in $ids) { $observations[$id] = Observe @(RecordsOf $id)[0] }
    $plan = Get-UninstallPlan @($ids | ForEach-Object { RecordsOf $_ }) $observations
    $problems = @($plan.refused | ForEach-Object { "$($_.id): $($_.reason)" })
    if ($plan.ok) {
        $contents = @{}
        foreach ($step in @(OrderedSteps $plan | Where-Object { $_.action -ceq 'delete-empty-key' })) { $contents[$step.key] = ObserveKeyContent ($step.key -replace '^HKCU\\', '') }
        $problems += @(Get-ForeignKeyContent @(OrderedSteps $plan) $contents @{})
    }
    if ($problems.Count) { $script:packageDrift += "retired App Paths kept: $($problems -join '; ')"; return }
    UndoOwnedSteps @(OrderedSteps $plan)
}

# The owned effect of one locked package: its tree Programs\<name>-<version> with the pinned inventory
# and, for a seeded package, its seed (never in the archive; the listing is checked against the
# inventory alone).
function PackageEffect($Package) {
    $target = Join-Path $localAppData $Package.directory.Replace('/', '\')
    $files = @{}
    foreach ($entry in $Package.files.PSObject.Properties) { $files[$entry.Name] = ([string]$entry.Value).ToLowerInvariant() }
    $seed = Get-Field $Package 'seed'
    if ($null -ne $seed) { $files[$seed.path] = $seed.sha256 }
    [ordered]@{ id = 'tree-extracted:' + $target.ToUpperInvariant(); kind = 'tree-extracted'; target = $target
        prior = [ordered]@{ exists = $false }; desired = [ordered]@{ exists = $true; files = $files } }
}

# O1, read-only: for a seeded package, the Preferences its seed would overwrite, or $null. Chromium's
# first run, which happens for a User Data without its 'First Run' sentinel, writes the seed over an
# existing Default\Preferences. Nothing here writes the profile or starts Chromium.
function SeedHazard($Package) {
    if ($null -eq (Get-Field $Package 'seed')) { return $null }
    foreach ($data in @($Package.protected)) {
        $root = Join-Path $localAppData $data.Replace('/', '\')
        $preferences = Join-Path $root 'Default\Preferences'
        if ((Test-Path -LiteralPath $preferences) -and -not (Test-Path -LiteralPath (Join-Path $root 'First Run'))) { return $preferences }
    }
    return $null
}

# Writes a package's seed into its staging tree from $Source, the bundle file, whose bytes must still be
# the manifest's (length and SHA-256): a new file (the archive never holds one), flushed to disk before
# the staging tree is compared with the inventory and the seed.
function WriteSeed($Seed, [string]$Source, [string]$Staging) {
    $bytes = [IO.File]::ReadAllBytes($Source)
    $hasher = [Security.Cryptography.SHA256]::Create()
    try { $sha = -join ($hasher.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') }) } finally { $hasher.Dispose() }
    if ($bytes.Length -ne $Seed.size -or $sha -cne $Seed.sha256) { throw "The bundled seed $Source is not the manifest's." }
    $out = [IO.FileStream]::new((Join-Path $Staging $Seed.path.Replace('/', '\')), [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try { $out.Write($bytes, 0, $bytes.Length); $out.Flush($true) } finally { $out.Dispose() }
}

# Read-only class of one package after recovery (Get-PackageClass): the ledger decides ownership
# of its tree; an Uninstall entry that may be this product (HKCU or HKLM, either view) is never
# taken over and, beside an owned tree, is a conflict; an unrecorded tree is preexisting (A2);
# protected data without this package's install history (R1) is someone else's; an owned tree
# written for another inventory or seed is owned-drift (C1); a profile a seed would overwrite (O1)
# stops an install and an owned tree's convergence. An attempt left unrecovered (a read-only mode) is
# indeterminate.
function ClassifyPackage($Package) {
    $effect = PackageEffect $Package
    $entries = @(FindUninstallEntries $Package.existing)
    $problems = @(foreach ($entry in $entries) { foreach ($problem in @(ExistingProblems $entry $Package)) { "$($entry.view)\$($entry.key): $problem" } })
    $attempt = AttemptOf $effect.id
    $tree = Get-EffectClass $null (ObserveTree $effect.target) $effect.kind $effect.desired $attempt
    $treeClass = if ($tree.resolution) { 'indeterminate' } else { $tree.class }
    $recorded = if (@($attempt.records).Count -and -not $attempt.closed) { Get-Field @($attempt.records)[0] 'desired' } else { $null }
    $changed = $null -ne $recorded -and -not (Test-EffectStateEqual $effect.kind $recorded $effect.desired)
    $hazard = SeedHazard $Package
    $present = @(@($Package.protected) | Where-Object { Test-Path -LiteralPath (Join-Path $localAppData $_.Replace('/', '\')) })
    # R1 history matters only when protected data exists; it reads the whole ledger once, so only then.
    $history = if ($present.Count) { Test-PackageHistory $script:ledgerRecords $Package.name (Join-Path $localAppData 'Programs') } else { $false }
    $class = Get-PackageClass $treeClass $entries.Count $problems ($present.Count -gt 0) $history $changed ($null -ne $hazard)
    $reason = if ($class.conflict) { "an external install is registered beside the owned tree, sharing its data ($(@($entries | ForEach-Object { "$($_.view)\$($_.key)" }) -join ', '))" }
        elseif ($class.hazard) {
            "$hazard exists in a profile without its First Run sentinel, so Chromium's next start would overwrite it with this package's seed; " +
                $(if ($class.class -ceq 'preexisting-drift') { 'nothing is installed' } else { 'do not start this Chromium; Uninstall removes the owned tree with its seed and never the profile' })
        }
        elseif ($class.class -ceq 'preexisting-drift' -and $entries.Count) { $problems -join '; ' }
        elseif ($class.class -ceq 'preexisting-drift' -and $treeClass -ceq 'preexisting-drift') { "$($effect.target) exists without this ledger and differs from the pinned inventory; it is never overwritten" }
        elseif ($class.class -ceq 'preexisting-drift') { "protected data exists without this package's install history: $($present -join ', ')" }
        elseif ($class.changed) { "the owned $($effect.target) was installed for another inventory or seed than this selection; Uninstall removes it, then it can be installed again" }
        elseif ($class.class -ceq 'owned-drift') { "the owned $($effect.target) differs from the pinned inventory; Uninstall removes it, then it can be installed again" }
        elseif ($class.class -ceq 'indeterminate') { $(if ($tree.reason) { $tree.reason } else { 'an interrupted attempt is not recovered yet' }) }
    [pscustomobject]@{ package = $Package; effect = $effect; class = $class.class; install = $class.install; converged = $class.converged
        conflict = $class.conflict; hazard = $class.hazard; reason = $reason }
}

# The packages this run converges or checks: every lock for Restore and RestoreTest, those named by -Packages for Apply.
function SelectedPackages {
    if ($Mode -eq 'Restore' -or $Mode -eq 'RestoreTest') { return @($manifest.packages) }
    @($manifest.packages | Where-Object { $packageNames -ccontains $_.name })
}

# Runs an inbox program ($Exe, an absolute path) with its arguments quoted for Windows (Join-NativeArguments)
# and no shell, reading stdout and stderr asynchronously. A run past $Seconds is killed and waited for; a
# nonzero exit fails with the end of its stderr. Returns stdout.
function Invoke-Native([string]$Exe, [string[]]$Arguments, [int]$Seconds) {
    $info = [Diagnostics.ProcessStartInfo]::new($Exe, (Join-NativeArguments $Arguments))
    $info.UseShellExecute, $info.RedirectStandardOutput, $info.RedirectStandardError, $info.CreateNoWindow = $false, $true, $true, $true
    $name = [IO.Path]::GetFileName($Exe)
    $process = [Diagnostics.Process]::Start($info)
    try {
        $out, $err = $process.StandardOutput.ReadToEndAsync(), $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($Seconds * 1000)) { $process.Kill(); $process.WaitForExit(); throw "$name did not finish within $Seconds s." }
        $process.WaitForExit()
        if ($process.ExitCode -ne 0) { throw "$name exited $($process.ExitCode): $((@($err.Result -split "`r?`n" | Where-Object { $_.Trim() }) | Select-Object -Last 3) -join ' | ')" }
        return $out.Result
    } finally { $process.Dispose() }
}

# True when the package's executable in $Tree is in use: an exclusive read/write open fails with a
# sharing or lock violation, as while it runs (a mapped image refuses writers) or another handle holds
# it; Uninstall and collection then leave that tree alone. Any other failure (read-only, access denied)
# is not "in use" and stops the run with its real reason; a missing executable is not in use.
function PackageInUse($Package, [string]$Tree) {
    $exe = Join-Path $Tree $Package.executable.Replace('/', '\')
    if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) { return $false }
    try { [IO.File]::Open($exe, 'Open', 'ReadWrite', 'None').Dispose(); return $false }
    catch {
        $failure = $_.Exception.GetBaseException()
        if ($failure -is [IO.IOException] -and ($failure.HResult -band 0xFFFF) -in @(32, 33)) { return $true }  # ERROR_SHARING_VIOLATION, ERROR_LOCK_VIOLATION
        throw "Cannot tell whether $exe is in use: $($failure.Message)"
    }
}

# Before any effect: an indeterminate or owned-drift package stops the run, and every install (ZIP or 7z,
# both through inbox tar.exe) must fit its volume and path limits (Get-PackageSpaceProblem), the earlier
# installs' space reserved. A profile a seed would overwrite (O1), like R1's foreign profile, only keeps
# the package from installing or converging: it is package drift after the other effects, and nothing is
# written for that package.
function PreflightPackages($States) {
    $blocked = @(foreach ($state in $States) {
        $label = "$($state.package.name) $($state.package.version)"
        if ($state.class -cin @('indeterminate', 'owned-drift')) { "${label}: $($state.reason)" }
    })
    if ($blocked.Count) { throw "Packages stop the run before any effect: $($blocked -join '; ')" }
    $reserved = @{}
    foreach ($state in @($States | Where-Object { $_.install })) {
        $volume = [IO.Path]::GetPathRoot($state.effect.target)
        $free = [long]([IO.DriveInfo]::new($volume).AvailableFreeSpace) - [long]$reserved[$volume]
        $problem = Get-PackageSpaceProblem $state.package $state.effect.target $free
        if ($problem) { throw "$($state.package.name) cannot be installed; nothing was changed: $problem" }
        $reserved[$volume] = [long]$reserved[$volume] + [long](Get-PackageSpaceNeed $state.package)
    }
}

# Installs one absent package: intent (package, staging) -> curl to the derived <staging>.asset (HTTPS
# only, redirects too) -> length, SHA-256 and SHA-1 checked under a handle that keeps writers out until
# extraction ends -> the `tar -tf` listing checked against the inventory alone -> `tar -xf` into staging ->
# the asset deleted -> a seeded package's seed written from the bundle (WriteSeed) -> staging exactly the
# inventory and the seed (no reparse point, extra or missing file) -> one same-volume rename -> commit. A
# failure is recovered at once when it can be (asset and staging, seed included, removed).
function InstallPackage($State) {
    $package, $effect = $State.package, $State.effect
    $programs = Join-Path $localAppData 'Programs'
    SharedDirectory $programs
    $problem = Get-PackageSpaceProblem $package $effect.target ([long]([IO.DriveInfo]::new([IO.Path]::GetPathRoot($effect.target)).AvailableFreeSpace))
    if ($problem) { throw "$($package.name) cannot be installed: $problem" }
    if ((ObserveTree $effect.target).exists) { throw "Refusing to create $($effect.target): it exists." }
    $staging = $effect.target + '.' + [guid]::NewGuid().ToString('N') + '.staging'
    WriteRecord 'intent' $effect $null $staging $package.name
    $asset = Get-PackageAssetPath @(RecordsOf $effect.id)[-1] $programs
    Recovering $effect {
        $curl, $tar = (Join-Path $env:SystemRoot 'System32\curl.exe'), (Join-Path $env:SystemRoot 'System32\tar.exe')
        # -q first: no .curlrc (the user's curl configuration) can change this download.
        $null = Invoke-Native $curl @('-q', '--fail', '--silent', '--show-error', '--location', '--proto', '=https', '--proto-redir', '=https',
            '--max-time', '600', '--output', $asset, $package.url) 660
        $stream = [IO.File]::Open($asset, 'Open', 'Read', 'Read')
        try {
            $sha256 = -join ([Security.Cryptography.SHA256]::Create().ComputeHash($stream) | ForEach-Object { $_.ToString('x2') })
            $sha1 = ''
            if ($null -ne (Get-Field $package 'sha1')) { $stream.Position = 0; $sha1 = -join ([Security.Cryptography.SHA1]::Create().ComputeHash($stream) | ForEach-Object { $_.ToString('x2') }) }
            $problem = Get-AssetProblem $package $stream.Length $sha256 $sha1
            if ($problem) { throw "The downloaded $($package.name) asset is not the lock: $problem" }
            $listing = @(ConvertFrom-TarListing ((Invoke-Native $tar @('-tf', $asset) 600) -split "`n") $package.files)
            $problem = Get-ZipEntryProblem $listing $package.files
            if ($problem) { throw "The $($package.name) archive is not the pinned inventory: $problem" }
            $null = [IO.Directory]::CreateDirectory($staging)
            $null = Invoke-Native $tar @('-xf', $asset, '-C', $staging) 600
        } finally { $stream.Dispose() }
        [IO.File]::Delete($asset)
        $seed = Get-Field $package 'seed'
        if ($null -ne $seed) { WriteSeed $seed (BundlePath $seed.file) $staging }
        if (-not (Test-EffectStateEqual 'tree-extracted' $effect.desired (ObserveTree $staging))) { throw "Staged $staging differs from the inventory." }
        [IO.Directory]::Move($staging, $effect.target)
        WriteRecord 'commit' $effect (ObserveTree $effect.target)
        $script:copied++
    }
}

# Once the selected version of a package is owned and exact: removes the owned trees of its other
# versions through the same plan as Uninstall (file by file, D1-resumable), each only when its
# executable is not in use and nothing else refers to it; anything kept stays owned and is reported.
function CollectPackageGarbage($State) {
    $programs = Join-Path $localAppData 'Programs'
    foreach ($id in @(LedgerIds)) {
        $first = @(RecordsOf $id)[0]
        $target = [string](Get-Field $first 'target')
        if ($id -ceq $State.effect.id -or (Get-Field $first 'kind') -cne 'tree-extracted' -or -not (Test-PackageTarget $target $State.package.name $programs) -or
            -not @(OpenAttempt $id).Count) { continue }
        if (PackageInUse $State.package $target) { $script:packageDrift += "$target is in use; kept"; continue }
        $observations = @{}
        $observations[$id] = Observe $first
        $plan = Get-UninstallPlan @(RecordsOf $id) $observations
        $problems = @($plan.refused | ForEach-Object { $_.reason }) + @(if ($plan.ok) { TreeReferenceProblems @(OrderedSteps $plan) })
        if ($problems.Count) { $script:packageDrift += "$target cannot be collected: $($problems -join '; ')"; continue }
        UndoOwnedSteps @(OrderedSteps $plan)
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
        if ($Apply -and $found) { RecoverLedger -All }
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
        $com = @($steps | Where-Object { $_.action -ceq 'delete-registry-value' -and $_.key -ne $fontKey -and
            -not ([string]$_.key).StartsWith("HKCU\$appPathsSubkey\", [StringComparison]::OrdinalIgnoreCase) })
        if ($com.Count) {
            if ($legacy.action -cin @('refuse', 'report')) { $refused += "default-terminal record: $($legacy.reason)" }
            $terminal = @(@($legacy.steps | Where-Object { $_.name -ceq 'DelegationTerminal' } | ForEach-Object { $_.value }) + @((StartupPair).terminal))[0]
            if ($terminal -eq $nocttyTerminal) { $refused += 'Noctty stays the selected default terminal, so its COM registration is kept.' }
        }
        $contents, $alsoRemoved = @{}, @{ ('HKCU\' + $startupSubkey) = @($legacy.steps | Where-Object { $null -eq $_.value } | ForEach-Object { $_.name }) }
        foreach ($step in @($steps | Where-Object { $_.action -ceq 'delete-empty-key' })) { $contents[$step.key] = ObserveKeyContent ($step.key -replace '^HKCU\\', '') }
        $refused += @(Get-ForeignKeyContent $steps $contents $alsoRemoved) + @(TreeReferenceProblems $steps)
        # A Chromium font preference goes only while Chromium is closed (the same gate as the write), so that is checked now.
        foreach ($dir in @($steps | Where-Object { $_.action -ceq 'delete-pref-value' } | ForEach-Object { [IO.Path]::GetDirectoryName($_.path) } | Sort-Object -Unique)) {
            $problem = ChromiumClosedProblem $dir
            if ($problem) { $refused += "Chromium font preferences in ${dir}: $problem" }
        }
        if (@($steps | Where-Object { $_.action -ceq 'delete-pref-value' }).Count) {
            $problem = PackageContextProblem
            if ($problem) { $refused += "Chromium font preferences: $problem" }
        }
        # A UI font face is written back only where this process may write the user's HKCU fonts.
        if (@($steps | Where-Object { $_.action -ceq 'set-ui-font-face' }).Count) {
            $problem = PackageContextProblem
            if ($problem) { $refused += "UI font faces: $problem" }
        }
        # A package tree whose executable runs (an exclusive read/write open fails) is not touched, so a
        # running browser never loses half its files; a partly removed tree still resumes (D1).
        $programs = Join-Path $localAppData 'Programs'
        foreach ($tree in @($steps | Where-Object { $_.kind -ceq 'tree-extracted' } | ForEach-Object { $_.id } | Sort-Object -Unique -CaseSensitive)) {
            $target = [string](Get-Field @(RecordsOf $tree)[0] 'target')
            foreach ($package in @($manifest.packages | Where-Object { Test-PackageTarget $target $_.name $programs })) {
                if (PackageInUse $package $target) { $refused += "${tree}: $($package.executable) is in use; close $($package.name) first" }
            }
        }
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
        $attempt = AttemptOf $id
        # A malformed id has no attempt records; it stays open (the plan already refused it).
        if ($attempt.problem -or (-not $attempt.closed -and @($attempt.records).Count)) { $open += $id; continue }
        $first = @($attempt.records)[0]
        if (-not (Test-EffectStateEqual ([string](Get-Field $first 'kind')) (Get-Field $first 'prior') (Observe $first))) { $changedAfterClose += $id }
    }
    $answer = [ordered]@{ mode = $Mode; apply = [bool]$Apply; source = $manifest.source; identity = $script:runIdentity
        ledgerFound = $found; siloCheck = 'notPerformed'
        scope = 'owned fonts, desktop UI font faces, the ChatGPT app''s theme fonts, the six Chromium font preferences written into existing profiles, Noctty, package trees and their App Paths names visible to this process, and the default-terminal selection this distribution wrote; protected package data (a browser profile), Store apps and RentSsh are not in the ledger'
        planned = @($steps | ForEach-Object { StepText $_ })
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
    if ($script:appFontDrift.Count) { throw "App font drift: $($script:appFontDrift -join '; ')" }
}

$script:runIdentity = RunIdentity
try {
    if ($Mode -eq 'Uninstall') { Uninstall; return }
    # RestoreTest reads the ledger without the lock or recovery; an unrecovered attempt reads as indeterminate.
    if ($Mode -eq 'RestoreTest') {
        $null = ReadLedger
        $packageStates = @(SelectedPackages | ForEach-Object { ClassifyPackage $_ })
    }
    $ledgerFound, $nocttyPlan, $appStates = $false, $null, @()
    # UI font faces: Restore, and Apply -Typography; checked by RestoreTest too.
    $uiFont = $null -ne $uiTypography -and ($Mode -eq 'Restore' -or $Mode -eq 'RestoreTest' -or $Typography)
    # The app's fonts likewise, for an app already present: -Typography never installs it, Restore does first.
    $appFontScope, $appFontsResult = ($null -ne $appearanceApp -and ($Mode -eq 'Restore' -or $Mode -eq 'RestoreTest' -or $Typography -or $AppFonts)), 'notEvaluated'
    if ($Mode -eq 'Apply' -or $Mode -eq 'Restore') {
        # Owned fonts and Noctty through the effect ledger (native files, trees and HKCU keys and
        # values): recovery, then every Noctty and font effect is classified before the first
        # one; fonts, then the UI font faces, then Noctty (tree, configuration, keys, values), then
        # the selection. -Typography converges the fonts, the UI font faces and a present app's fonts alone.
        $ledgerFound = Test-Path -LiteralPath $ledgerDirectory -PathType Container
        LockLedger
        $null = ReadLedger
        RecoverLedger
        if ($AppFonts) {
            # The selected fonts must already be exact (read-only here); then the present app's fonts alone.
            AssertFonts
            if ($null -ne $appearanceApp -and (AppFontsPresent)) { ConvergeAppFonts }
            if ($script:appFontDrift.Count) { throw "App font drift: $($script:appFontDrift -join '; ')" }
        }
        if ($ChromiumFonts) {
            # The selected fonts must already be exact (read-only here); then the profiles' six leaves alone.
            AssertFonts
            ConvergeChromiumFonts
            if ($script:prefDrift.Count) { throw "Chromium font drift: $($script:prefDrift -join '; ')" }
        }
        if (-not $Typography -and -not $ChromiumFonts -and -not $AppFonts) {
            $nocttyPlan = PlanNoctty -Restore:($Mode -eq 'Restore')
            # Packages (all for Restore, those named by -Packages for Apply), classified after recovery;
            # every package refusal comes before the first effect, then installs, then old versions go.
            # The UI font interpreter is a package, so Restore installs it before the faces are set.
            $packageStates = @(SelectedPackages | ForEach-Object { ClassifyPackage $_ })
            PreflightPackages $packageStates
            foreach ($state in @($packageStates | Where-Object { $_.install })) { InstallPackage $state }
            # App Paths names point at the selected trees before old versions go, and retired names are collected, only
            # in a run that handles packages (Restore, or Apply with -Packages): without them no package state is touched.
            foreach ($appPath in @($packageStates | ForEach-Object { AppPathState $_ } | Where-Object { $null -ne $_ -and $_.write })) { ConvergeAppPath $appPath }
            if ($packageStates.Count) { CollectAppPathGarbage $packageStates }
            foreach ($state in @($packageStates | Where-Object { $_.install -or $_.class -ceq 'owned-match' })) { CollectPackageGarbage $state }
            if ($Mode -eq 'Restore') { ConvergeApps }
        }
        if (-not $ChromiumFonts -and -not $AppFonts) {
            ConvergeFonts
            # The faces and the app's fonts move only onto exact selected fonts, and old fonts go only once nothing names them.
            if (($uiFont -or $appFontScope) -and -not $script:fontDrift.Count) {
                AssertFonts
                if ($uiFont) { ConvergeUiFont }
                if ($appFontScope -and (AppFontsPresent)) { ConvergeAppFonts }
            }
            CollectUnselectedFonts
            if ($script:fontDrift.Count) { throw "Font drift: $($script:fontDrift -join '; ')" }
            if ($script:uiFontDrift.Count) { throw "UI font drift: $($script:uiFontDrift -join '; ')" }
            if ($script:appFontDrift.Count) { throw "App font drift: $($script:appFontDrift -join '; ')" }
        }
        if (-not $Typography -and -not $ChromiumFonts -and -not $AppFonts) {
            ApplyNoctty $nocttyPlan
            SelectNoctty -Check:($Mode -eq 'Restore')
            if ($script:nocttyDrift.Count) { throw "Noctty drift: $($script:nocttyDrift -join '; ')" }
            $packageStates = @(SelectedPackages | ForEach-Object { ClassifyPackage $_ })  # as they are now, for the verdict
        }
    }
    if ($Mode -ne 'Validate') { AssertFonts }
    if ($uiFont) { AssertUiFont }
    if ($appFontScope) { if (AppFontsPresent) { AssertAppFonts; $appFontsResult = 'selected' } else { $appFontsResult = 'appAbsent' } }
    if ($Mode -eq 'Restore' -or $Mode -eq 'RestoreTest') {
        $appStates = @(AppStates)
        $script:appDrift += @($appStates | Where-Object { $_.action -cne 'present' } | ForEach-Object {
            "$($_.app.name) ($($_.app.package)) is $(if ($_.action -ceq 'install') { 'not installed' } else { "not exactly one package of publisher $($_.app.publisherId); never replaced" })" })
        if ($script:appDrift.Count) { throw "App drift: $($script:appDrift -join '; ')" }
    }
    if ($Mode -eq 'Restore' -or $Mode -eq 'RestoreTest') {
        if (-not (TestNoctty)) { throw 'Noctty files or font configuration drift.' }
        if (-not (TestTerminalPackage)) { throw 'Windows Terminal 1.24 or newer is missing.' }
        if (-not (TestNocttyRegistration)) { throw 'Noctty default-terminal registration drift.' }
        if ($Mode -eq 'RestoreTest') { AssertActualSelection }  # Restore checked it before success
    }
    # Every package this run covered is owned-match or preexisting-match, with no external install beside
    # an owned tree, and an owned one launches by its App Paths name; anything else (never written) and any
    # old version kept fails as package drift.
    foreach ($state in $packageStates) {
        $appPath = AppPathState $state
        if ($null -ne $appPath -and -not $appPath.converged) {
            $script:packageDrift += "$($state.package.name) App Paths $($appPath.name): $(if ($appPath.reason) { $appPath.reason } else { 'not written' })"
        }
    }
    $drift = @(@($packageStates | Where-Object { -not $_.converged } | ForEach-Object { "$($_.package.name) $($_.class): $($_.reason)" }) + $script:packageDrift)
    if ($drift.Count) { throw "Package drift: $($drift -join '; ')" }
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
                class = $(if ($state.Count) { $state[0].class } else { 'notEvaluated' }) } });
        appFonts = $appFontsResult
        chromiumFonts = $(if ($ChromiumFonts) { @($script:chromiumFontsResult) } else { 'notEvaluated' })
        uiFont = $(if ($uiFont) { UiFontReport } else { 'notEvaluated' })
        # Store apps: the version installed now; the Store moves it, and installing needs the network.
        apps = @($apps | ForEach-Object {
            $package = $_.package
            $state = @($appStates | Where-Object { $_.app.package -ceq $package })
            [ordered]@{ name = $_.name; package = $package; id = $_.id
                version = $(if ($state.Count -and $state[0].action -ceq 'present') { $state[0].found[0].version } else { 'notEvaluated' }) } });
        inDesiredState = ($Mode -ne 'Validate');
        registrationState = $(if (TestNocttyRegistration) { 'registered' } else { 'unregistered' });
        handoffProof = 'unproven' } | ConvertTo-Json -Compress -Depth 4
}
finally {
    if ($script:ledgerLock) { $script:ledgerLock.Dispose() }
}
