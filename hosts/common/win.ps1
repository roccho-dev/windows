#requires -Version 7.0
[CmdletBinding()]
param([ValidateSet('Validate', 'Test', 'Apply')][string]$Mode = 'Validate')

# One activation boundary. No product selection, download, WinGet, or admin effect.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (-not $IsWindows) { throw 'This activation backend requires Windows.' }
$root = [IO.Path]::GetFullPath($PSScriptRoot) + [IO.Path]::DirectorySeparatorChar
$manifest = Get-Content -LiteralPath (Join-Path $root 'manifest.json') -Raw -Encoding utf8 | ConvertFrom-Json
if ($manifest.schemaVersion -ne 1 -or @($manifest.fonts).Count -eq 0) { throw 'Invalid or empty distribution.' }

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
$fontDirectory = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'Microsoft\Windows\Fonts'
$oldPath, $oldResources, $oldFontDirectory = $env:PATH, $env:DSC_RESOURCE_PATH, $env:WINDOWS_IAC_FONT_DIR
$copied, $changed = 0, 0

function InvokeDsc([string]$Operation) {
    $raw = & $exe --ignore-settings-file config $Operation --file $configuration --output-format json
    if ($LASTEXITCODE -ne 0) { throw "DSC $Operation failed: $LASTEXITCODE" }
    $answer = ($raw -join "`n") | ConvertFrom-Json
    if ($answer.hadErrors -ne $false -or @($answer.results).Count -ne @($manifest.fonts).Count) {
        throw "DSC $Operation did not evaluate every resource successfully."
    }
    return $answer
}

try {
    # Resolve only the bundled native resources, not an ambient resource/version.
    $env:PATH = Split-Path -Parent $exe
    $env:DSC_RESOURCE_PATH = $env:PATH
    $env:WINDOWS_IAC_FONT_DIR = $fontDirectory  # current-user Binding, not Spec
    $null = InvokeDsc 'get'  # read-only interpretation, also used by Validate
    if ($Mode -eq 'Apply') {
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
        $set = InvokeDsc 'set'
        foreach ($item in $set.results) {
            if ($null -ne $item.result.changedProperties) { $changed += @($item.result.changedProperties).Count }
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
        $test = InvokeDsc 'test'
        foreach ($item in $test.results) {
            if ($item.result.inDesiredState -ne $true) { throw "Registry drift: $($item.name)" }
        }
    }
    [ordered]@{ mode = $Mode; source = $manifest.source; fontDirectory = $fontDirectory;
        fonts = @($manifest.fonts).Count; copied = $copied; changedProperties = $changed;
        inDesiredState = ($Mode -ne 'Validate') } | ConvertTo-Json -Compress
}
finally {
    $env:PATH, $env:DSC_RESOURCE_PATH, $env:WINDOWS_IAC_FONT_DIR = $oldPath, $oldResources, $oldFontDirectory
}
