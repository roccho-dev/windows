#requires -Version 5.1
[CmdletBinding()]
param([ValidateSet('Validate', 'Test', 'Apply', 'Restore', 'RestoreTest')][string]$Mode = 'Validate')

# One activation boundary. Product selection belongs to the built distribution.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ($env:OS -ne 'Windows_NT') { throw 'This activation backend requires Windows.' }
$root = [IO.Path]::GetFullPath($PSScriptRoot) + [IO.Path]::DirectorySeparatorChar
$manifest = Get-Content -LiteralPath (Join-Path $root 'manifest.json') -Raw -Encoding utf8 | ConvertFrom-Json
if ($manifest.schemaVersion -ne 2 -or @($manifest.fonts).Count -eq 0 -or
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
# Function definitions only: the pure selection comparison and the package-context reader.
. (BundlePath 'handoff-evaluate.ps1')
. (BundlePath 'package-view.ps1')
# Restore is per-user. An elevated token may belong to another account, and
# elevated COM ignores per-user classes, so its activation check could start a
# machine-wide Noctty instead of this user's registration.
if ($Mode -eq 'Restore' -and
    ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run Restore unelevated, from an Explorer-launched shell of the user being restored.'
}
$configuration = BundlePath 'configuration.dsc.json'
$packagesConfiguration = BundlePath 'packages.dsc.json'
$fontDirectory = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'Microsoft\Windows\Fonts'
$localAppData = [Environment]::GetFolderPath('LocalApplicationData')
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
        $null = InvokeDsc 'set' $packagesConfiguration @($manifest.packages).Count
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
        $apps = InvokeDsc 'test' $packagesConfiguration @($manifest.packages).Count
        foreach ($item in $apps.results) {
            if ($item.result.inDesiredState -ne $true) { throw "Package drift: $($item.name)" }
        }
    }
    # inDesiredState covers the declared state this mode tested. Handoff is never
    # part of it: this script does not launch or observe a console.
    [ordered]@{ mode = $Mode; source = $manifest.source; fontDirectory = $fontDirectory;
        fonts = @($manifest.fonts).Count; copied = $copied; changedProperties = $changed;
        noctty = $manifest.noctty.version; packages = @($manifest.packages).Count;
        inDesiredState = ($Mode -ne 'Validate');
        registrationState = $(if (TestNocttyRegistration) { 'registered' } else { 'unregistered' });
        handoffProof = 'unproven' } | ConvertTo-Json -Compress
}
finally {
    $env:PATH, $env:DSC_RESOURCE_PATH, $env:WINDOWS_IAC_FONT_DIR = $oldPath, $oldResources, $oldFontDirectory
}
