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
$nocttyConfig = Join-Path $localAppData 'noctty\config.ghostty'
$nocttyShortcut = Join-Path ([Environment]::GetFolderPath('StartMenu')) 'Programs\noctty.lnk'
$nocttyConfigText = 'font-family = ' + $manifest.noctty.fontFamily + "`n"
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
            if ($state -eq 'missing') {
                if (Test-Path -LiteralPath $userBackup) { throw "$userBackup already exists; not overwriting it." }
                [IO.File]::WriteAllBytes($userBackup, $prior)
            }
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
        $shortcut.TargetPath = Join-Path $nocttyDirectory 'noctty\noctty.exe'
        $shortcut.WorkingDirectory = Join-Path $nocttyDirectory 'noctty'
        $shortcut.Save()
        $null = InvokeDsc 'set' $packagesConfiguration @($manifest.packages).Count
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
