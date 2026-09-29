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

function TestNocttyDefault {
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
        $terminal = Get-AppxPackage -Name Microsoft.WindowsTerminal | Select-Object -First 1
        if ($null -eq $terminal -or [version]$terminal.Version -lt [version]'1.24.0.0') {
            throw 'Noctty default-terminal handoff requires Windows Terminal 1.24 or newer.'
        }
        $null = New-Item -Path $terminalStartup -Force
        $null = New-ItemProperty -LiteralPath $terminalStartup -Name DelegationConsole -Value $windowsTerminalConsole -PropertyType String -Force
        $null = & $nocttyCom +register-default-terminal
        if ($LASTEXITCODE -ne 0) { throw "Noctty default-terminal registration failed: $LASTEXITCODE" }
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
        if (-not (TestNocttyDefault)) { throw 'Noctty default-terminal registration drift.' }
        $apps = InvokeDsc 'test' $packagesConfiguration @($manifest.packages).Count
        foreach ($item in $apps.results) {
            if ($item.result.inDesiredState -ne $true) { throw "Package drift: $($item.name)" }
        }
    }
    [ordered]@{ mode = $Mode; source = $manifest.source; fontDirectory = $fontDirectory;
        fonts = @($manifest.fonts).Count; copied = $copied; changedProperties = $changed;
        noctty = $manifest.noctty.version; packages = @($manifest.packages).Count;
        inDesiredState = ($Mode -ne 'Validate') } | ConvertTo-Json -Compress
}
finally {
    $env:PATH, $env:DSC_RESOURCE_PATH, $env:WINDOWS_IAC_FONT_DIR = $oldPath, $oldResources, $oldFontDirectory
}
