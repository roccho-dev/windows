#requires -Version 5.1
[CmdletBinding()]
param(
    [ValidateSet('Validate', 'Test', 'Apply', 'Restore', 'RestoreTest', 'RentSsh', 'RentSshTest')][string]$Mode = 'Validate',
    # RentSsh/RentSshTest only: the live binding, known only after envs and the first rent start. Nothing is guessed.
    [string]$Alias = 'windows-rent',
    [string]$Hostname,
    [string]$HostKey,
    [string]$Identity
)

# One activation boundary. Product selection belongs to the built distribution.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ($env:OS -ne 'Windows_NT') { throw 'This activation backend requires Windows.' }
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
$exe = BundlePath $manifest.backend
if (-not $inventory.ContainsKey($manifest.backend)) { throw 'Unlisted backend.' }
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
$configuration = BundlePath 'configuration.dsc.json'
$fontDirectory = Join-Path $localAppData 'Microsoft\Windows\Fonts'
$nocttyDirectory = Join-Path $localAppData ('Programs\noctty-' + $manifest.noctty.version)
$nocttyExe = Join-Path $nocttyDirectory 'noctty\noctty.exe'
$nocttyCom = Join-Path $nocttyDirectory 'noctty\noctty.com'
$nocttyConfig = Join-Path $localAppData 'noctty\config.ghostty'
$nocttyShortcut = Join-Path ([Environment]::GetFolderPath('StartMenu')) 'Programs\noctty.lnk'
$nocttyConfigText = 'font-family = ' + $manifest.noctty.fontFamily + "`n"
$terminalStartup = 'HKCU:\Console\%%Startup'
$windowsTerminalConsole = '{2EACA947-7F5F-4CFA-BA87-8F7FBEEFBE69}'
$nocttyTerminal = '{33368C6F-D328-410C-B225-26DC9F12C728}'
$nocttyProxy = '{1D349824-21FB-46C7-ACF3-746EDC991D52}'
$terminalProvenance = Join-Path $localAppData 'windows-iac\provenance\default-terminal.json'
$oldPath, $oldResources, $oldFontDirectory = $env:PATH, $env:DSC_RESOURCE_PATH, $env:WINDOWS_IAC_FONT_DIR
$copied, $changed = 0, 0
$packageStates = @()

function InvokeDsc([string]$Operation, [string]$Document, [int]$Count) {
    $raw = & $exe --ignore-settings-file config $Operation --file $Document --output-format json
    if ($LASTEXITCODE -ne 0) { throw "DSC $Operation failed: $LASTEXITCODE" }
    $answer = ($raw -join "`n") | ConvertFrom-Json
    if ($answer.hadErrors -ne $false -or @($answer.results).Count -ne $Count) {
        throw "DSC $Operation did not evaluate every resource successfully."
    }
    return $answer
}

function TestNocttyFiles {
    if (-not (Test-Path -LiteralPath $nocttyDirectory -PathType Container)) { return $false }
    foreach ($entry in $manifest.noctty.files.PSObject.Properties) {
        $relative = $entry.Name
        if ($relative -notmatch '^noctty/[^:]+' -or $relative -match '(\\|(^|/)\.\.(/|$))') {
            throw "Unsafe noctty path: $relative"
        }
        $path = Join-Path $nocttyDirectory ($relative.Replace('/', '\'))
        if (-not (Test-Path -LiteralPath $path -PathType Leaf) -or
            (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ne $entry.Value) { return $false }
    }
    return $true
}

function TestNoctty {
    return (TestNocttyFiles) -and (Test-Path -LiteralPath $nocttyConfig -PathType Leaf) -and
        ([IO.File]::ReadAllText($nocttyConfig) -ceq $nocttyConfigText) -and
        (Test-Path -LiteralPath $nocttyShortcut -PathType Leaf)
}

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

function RegistryDefault([string]$Path) {
    $key = Get-Item -LiteralPath $Path -ErrorAction SilentlyContinue
    if ($null -eq $key) { return $null }
    return $key.GetValue('')
}

function RestoreRegistryString([string]$Path, [string]$Name, [object]$Value) {
    if ($null -eq $Value) {
        Remove-ItemProperty -LiteralPath $Path -Name $Name -ErrorAction SilentlyContinue
    } else {
        $null = New-ItemProperty -LiteralPath $Path -Name $Name -Value $Value -PropertyType String -Force
    }
}

# Registration only: the registry state that selects Noctty. It is not evidence
# that a new console is handed off to Noctty; only handoff-proof.ps1 on a real
# interactive host can produce that evidence.
function TestNocttyRegistration {
    $startup = Get-Item -LiteralPath $terminalStartup -ErrorAction SilentlyContinue
    if ($null -eq $startup -or
        $startup.GetValue('DelegationConsole') -ne $windowsTerminalConsole -or
        $startup.GetValue('DelegationTerminal') -ne $nocttyTerminal) { return $false }
    $classes = 'HKCU:\Software\Classes'
    if ((RegistryDefault "$classes\CLSID\$nocttyTerminal\LocalServer32") -ne ('"' + $nocttyExe + '"') -or
        (RegistryDefault "$classes\CLSID\$nocttyProxy\InprocServer32") -ne (Join-Path (Split-Path -Parent $nocttyExe) 'noctty-terminal-handoff-proxy.dll')) {
        return $false
    }
    foreach ($iid in @('{59D55CCE-FC8A-48B4-ACE8-0A9286C6557F}',
                       '{AA6B364F-4A50-4176-9002-0AE755E7B5EF}',
                       '{6F23DA90-15C5-4203-9DB0-64E73F1B1B00}')) {
        if ((RegistryDefault "$classes\Interface\$iid\ProxyStubClsid32") -ne $nocttyProxy) { return $false }
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

try {
    # Resolve only the bundled native resources, not an ambient resource/version.
    $env:PATH = (Split-Path -Parent $exe) + ';' + $oldPath
    $env:DSC_RESOURCE_PATH = Split-Path -Parent $exe
    $env:WINDOWS_IAC_FONT_DIR = $fontDirectory  # current-user Binding, not Spec
    # Packages are read, never downloaded or extracted, outside Restore; Validate,
    # Test and Apply do not read the machine for them at all.
    if ($Mode -eq 'Restore' -or $Mode -eq 'RestoreTest') {
        $packageStates = @(foreach ($package in $manifest.packages) {
            [pscustomobject]@{ package = $package; state = (ClassifyPackage $package) }
        })
    }
    if ($Mode -eq 'Restore') {
        # Before any Restore effect: an unknown owner stops, and a clean install
        # (fetch and verify every asset, then extract) runs first or not at all.
        $unknown = @($packageStates | Where-Object { $_.state.class -ceq 'indeterminate' })
        if ($unknown.Count) { throw "Package state unknown: $(@($unknown | ForEach-Object { $_.state.reason }) -join '; ')" }
        $absent = @($packageStates | Where-Object { $_.state.class -ceq 'absent' } | ForEach-Object { $_.package })
        if ($absent.Count) { InstallPackages $absent }
    }
    $null = InvokeDsc 'get' $configuration @($manifest.fonts).Count
    if ($Mode -eq 'Apply' -or $Mode -eq 'Restore') {
        $null = New-Item -ItemType Directory -Path $fontDirectory -Force
        foreach ($font in $manifest.fonts) {
            if ($font.file -notmatch '^[0-9a-f]{64}\.ttf$') { throw 'Invalid content-addressed font name.' }
            $target = Join-Path $fontDirectory $font.file
            if (-not (Test-Path -LiteralPath $target -PathType Leaf) -or
                (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash -ne $font.sha256) {
                Copy-Item -LiteralPath (BundlePath "share/fonts/truetype/$($font.file)") -Destination $target -Force
                $copied++
            }
        }
        $set = InvokeDsc 'set' $configuration @($manifest.fonts).Count
        foreach ($item in $set.results) {
            if ($null -ne $item.result.changedProperties) { $changed += @($item.result.changedProperties).Count }
        }
    }
    if ($Mode -eq 'Restore') {
        if (-not (Test-Path -LiteralPath $nocttyDirectory -PathType Container)) {
            $null = New-Item -ItemType Directory -Path $nocttyDirectory -Force
            Expand-Archive -LiteralPath (BundlePath 'payload/noctty.zip') -DestinationPath $nocttyDirectory
        }
        if (-not (TestNocttyFiles)) { throw 'Noctty files differ; close noctty and repair the versioned directory.' }
        $null = New-Item -ItemType Directory -Path (Split-Path -Parent $nocttyConfig) -Force
        [IO.File]::WriteAllText($nocttyConfig, $nocttyConfigText, [Text.UTF8Encoding]::new($false))
        $null = New-Item -ItemType Directory -Path (Split-Path -Parent $nocttyShortcut) -Force
        $shortcut = (New-Object -ComObject WScript.Shell).CreateShortcut($nocttyShortcut)
        $shortcut.TargetPath = $nocttyExe
        $shortcut.WorkingDirectory = Join-Path $nocttyDirectory 'noctty'
        $shortcut.Save()
        if (-not (TestTerminalPackage)) { throw 'Noctty default-terminal handoff requires Windows Terminal 1.24 or newer.' }
        if (-not (Test-Path -LiteralPath $terminalStartup)) {
            $null = New-Item -Path $terminalStartup
        }
        $startup = Get-Item -LiteralPath $terminalStartup
        $previousConsole = $startup.GetValue('DelegationConsole')
        $previousTerminal = $startup.GetValue('DelegationTerminal')
        RecordPriorTerminal $previousConsole $previousTerminal
        $registered = $false
        try {
            $null = New-ItemProperty -LiteralPath $terminalStartup -Name DelegationConsole -Value $windowsTerminalConsole -PropertyType String -Force
            $null = & $nocttyCom +register-default-terminal
            if ($LASTEXITCODE -ne 0) { throw "Noctty default-terminal registration failed: $LASTEXITCODE" }
            $registered = $true
            if (-not (TestNocttyRegistration)) { throw 'Noctty default-terminal registration is incomplete.' }
            if (-not (TestNocttyActivation)) { throw 'Noctty COM activation failed after registration.' }
            # Before success: a registration the package cannot see is rolled back below.
            AssertActualSelection
        } catch {
            $failure = $_
            if ($registered) { $null = & $nocttyCom +unregister-default-terminal }
            RestoreRegistryString $terminalStartup 'DelegationConsole' $previousConsole
            RestoreRegistryString $terminalStartup 'DelegationTerminal' $previousTerminal
            throw $failure
        }
    }
    if ($Mode -ne 'Validate') {
        foreach ($font in $manifest.fonts) {
            if ($font.file -notmatch '^[0-9a-f]{64}\.ttf$') { throw 'Invalid font name.' }
            $target = Join-Path $fontDirectory $font.file
            if (-not (Test-Path -LiteralPath $target -PathType Leaf) -or
                (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash -ne $font.sha256) {
                throw "Installed bytes differ: $($font.fullName)"
            }
        }
        $test = InvokeDsc 'test' $configuration @($manifest.fonts).Count
        foreach ($item in $test.results) {
            if ($item.result.inDesiredState -ne $true) { throw "Registry drift: $($item.name)" }
        }
    }
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
    [ordered]@{ mode = $Mode; source = $manifest.source; fontDirectory = $fontDirectory;
        fonts = @($manifest.fonts).Count; copied = $copied; changedProperties = $changed;
        noctty = $manifest.noctty.version
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
    $env:PATH, $env:DSC_RESOURCE_PATH, $env:WINDOWS_IAC_FONT_DIR = $oldPath, $oldResources, $oldFontDirectory
}
