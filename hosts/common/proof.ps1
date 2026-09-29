#requires -Version 7.0
[CmdletBinding()]
param([Parameter(Mandatory)][string]$ExpectedSource)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ($env:GITHUB_ACTIONS -ne 'true' -or $env:RUNNER_ENVIRONMENT -ne 'github-hosted') {
    throw 'Proof mutates disposable state and is restricted to GitHub-hosted runners.'
}
function Run([string]$Mode) {
    (& (Join-Path $PSScriptRoot 'win.ps1') -Mode $Mode) | ConvertFrom-Json
}
function MustReject([scriptblock]$Action, [string]$Pattern) {
    try { $null = & $Action }
    catch {
        if ($_.Exception.Message -notlike $Pattern) { throw }
        return
    }
    throw 'Negative control unexpectedly passed.'
}
$validated = Run 'Validate'
if ($validated.source -ne $ExpectedSource -or $ExpectedSource -notmatch '^[0-9a-f]{40}$') { throw 'Source mismatch.' }
$manifest = Get-Content (Join-Path $PSScriptRoot 'manifest.json') -Raw -Encoding utf8 | ConvertFrom-Json
$config = Get-Content (Join-Path $PSScriptRoot 'configuration.dsc.json') -Raw -Encoding utf8 | ConvertFrom-Json

# Seed damaged bytes BEFORE registration: Windows may lock registered fonts.
# This models an interrupted first installation, without stopping OS services.
$installed = Join-Path $validated.fontDirectory $manifest.fonts[0].file
if (Test-Path -LiteralPath $installed) { throw 'Proof requires a fresh disposable font target.' }
$null = New-Item -ItemType Directory -Path $validated.fontDirectory -Force
[IO.File]::WriteAllText($installed, 'negative-control')
MustReject { Run 'Test' } 'Installed bytes differ:*'
$first = Run 'Apply'
if ($first.copied -lt 1) { throw 'Preexisting corruption was not repaired.' }
$second = Run 'Apply'
if ($second.copied -ne 0 -or $second.changedProperties -ne 0) { throw 'Second apply changed state.' }
$null = Run 'Test'

# Independent provider readback uses the generated declaration, not a second Spec.
for ($i = 0; $i -lt $manifest.fonts.Count; $i++) {
    $resource = $config.resources[$i].properties
    $path = 'Registry::' + ($resource.keyPath -replace '^HKCU\\', 'HKEY_CURRENT_USER\')
    $actual = Get-ItemPropertyValue -LiteralPath $path -Name $resource.valueName
    if ($actual -ne (Join-Path $first.fontDirectory $manifest.fonts[$i].file)) { throw 'Independent registry readback failed.' }
}

# Drift must fail specifically because DSC reports nonconvergence, not any error.
$resource = $config.resources[0].properties
$key = 'Registry::' + ($resource.keyPath -replace '^HKCU\\', 'HKEY_CURRENT_USER\')
Set-ItemProperty -LiteralPath $key -Name $resource.valueName -Value 'negative-control'
MustReject { Run 'Test' } 'Registry drift:*'
$null = Run 'Apply'
$null = Run 'Test'

# Valid JSON with altered bytes still fails the inventory before effects.
$path = Join-Path $PSScriptRoot 'configuration.dsc.json'
$original = [IO.File]::ReadAllBytes($path)
try {
    [IO.File]::AppendAllText($path, "`n")
    MustReject { Run 'Validate' } 'Bundle content mismatch:*'
}
finally { [IO.File]::WriteAllBytes($path, $original) }
$null = Run 'Test'

# Rent SSH client, bound explicitly with synthetic values (a live binding comes from envs and the rent's own host key).
# It proves the pinned client, the generated OpenSSH configuration and the Include handling; it never connects.
$bind = @{ Hostname = 'rent.example.invalid'; HostKey = 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGNpLXN5bnRoZXRpYy1ob3N0LWtleS1ub3QtcmVhbA=='
    Identity = (Join-Path $env:RUNNER_TEMP 'rent-ci-identity') }
[IO.File]::WriteAllText($bind.Identity, 'synthetic identity path; never used to connect')
function RunSsh([string]$Mode, [hashtable]$With = $bind) { (& (Join-Path $PSScriptRoot 'win.ps1') -Mode $Mode @With) | ConvertFrom-Json }
$sshDir = Join-Path $env:USERPROFILE '.ssh'
$userConfig = Join-Path $sshDir 'config'
if (Test-Path -LiteralPath (Join-Path $sshDir 'windows-rent')) { throw 'Proof requires a fresh disposable SSH profile.' }
# A prior user configuration whose exact bytes must survive, below the one added line and in the one backup.
$null = New-Item -ItemType Directory -Path $sshDir -Force
if (-not (Test-Path -LiteralPath $userConfig)) { [IO.File]::WriteAllText($userConfig, "Host prior`r`n  User prior`r`n") }
$prior = [IO.File]::ReadAllBytes($userConfig)
MustReject { RunSsh 'RentSshTest' } 'RentSsh drift:*'
foreach ($bad in @(@{ Hostname = 'bad host' }, @{ HostKey = 'ssh-rsa AAAA' }, @{ Identity = 'C:\missing\key' }, @{ Alias = 'Bad Alias' })) {
    $with = $bind.Clone(); foreach ($k in $bad.Keys) { $with[$k] = $bad[$k] }
    MustReject { RunSsh 'RentSsh' $with } 'Invalid*'
}
if ([Convert]::ToBase64String([IO.File]::ReadAllBytes($userConfig)) -ne [Convert]::ToBase64String($prior)) { throw 'A refused binding wrote the user config.' }
# A stale backup is refused before any write: no client, no rent files, both user files byte-identical.
$clientDir = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) ('Programs\cloudflared-' + $manifest.cloudflared.version)
if (Test-Path -LiteralPath $clientDir) { throw 'Proof requires no installed client yet.' }
$backup = Join-Path $sshDir 'config.before-windows-rent'
[IO.File]::WriteAllText($backup, "stale backup`n")
$stale = [IO.File]::ReadAllBytes($backup)
MustReject { RunSsh 'RentSsh' } '*config.before-windows-rent already exists; not overwriting it.'
if ((Test-Path -LiteralPath $clientDir) -or (Test-Path -LiteralPath (Join-Path $sshDir 'windows-rent'))) { throw 'A refused binding installed files.' }
if ([Convert]::ToBase64String([IO.File]::ReadAllBytes($userConfig)) -ne [Convert]::ToBase64String($prior) -or
    [Convert]::ToBase64String([IO.File]::ReadAllBytes($backup)) -ne [Convert]::ToBase64String($stale)) { throw 'A refused binding changed the user config or backup.' }
Remove-Item -LiteralPath $backup
$ssh = RunSsh 'RentSsh'
$expected = [Text.Encoding]::UTF8.GetBytes("Include windows-rent/config`n") + $prior
foreach ($pass in 1, 2) {
    if ([Convert]::ToBase64String([IO.File]::ReadAllBytes($userConfig)) -ne [Convert]::ToBase64String([byte[]]$expected)) { throw "User config is not the Include line plus its exact prior bytes (pass $pass)." }
    if ([Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $sshDir 'config.before-windows-rent'))) -ne [Convert]::ToBase64String($prior)) { throw 'Backup differs from the prior bytes.' }
    $null = RunSsh 'RentSsh'
}
$null = RunSsh 'RentSshTest'
if ((Get-FileHash -LiteralPath $ssh.client -Algorithm SHA256).Hash -ne $manifest.cloudflared.sha256) { throw 'Installed client differs from the manifest.' }
$version = (& $ssh.client --version) -join "`n"
if ($version -notmatch ('^cloudflared version ' + [regex]::Escape($manifest.cloudflared.version) + '( |$)')) { throw "Unexpected client version: $version" }
# What Windows OpenSSH (as Codex Remote SSH uses it) resolves for the alias, from the user's own config.
$resolved = @(& ssh.exe -G windows-rent) | ForEach-Object { $_.ToLowerInvariant() }
foreach ($line in @('hostname rent.example.invalid', 'user dev', 'hostkeyalias windows-rent', 'stricthostkeychecking true',
        ('proxycommand "' + $ssh.client.ToLowerInvariant() + '" access ssh --hostname %h'))) {
    if ($resolved -cnotcontains $line) { throw "ssh -G lacks: $line" }
}
if (-not ($resolved | Where-Object { $_ -like 'userknownhostsfile *windows-rent*known_hosts*' })) { throw 'ssh -G lacks the pinned known_hosts.' }
# Drift is reported and repaired by the same explicit mode.
[IO.File]::AppendAllText($ssh.config, "  StrictHostKeyChecking no`n")
MustReject { RunSsh 'RentSshTest' } 'RentSsh drift:*'
$null = RunSsh 'RentSsh'
$null = RunSsh 'RentSshTest'

[ordered]@{ source = $ExpectedSource; proof = 'PASS'; fonts = $first.fonts;
    secondApplyChanges = 0; preexistingCorruptionRepaired = $true;
    registryDriftRejected = $true; corruptionRejected = $true;
    rentSsh = "cloudflared $($manifest.cloudflared.version) client, strict config, Include preserved and idempotent, drift repaired"
    scope = 'current-user file, registry and SSH-client convergence; not rendering, real-host UX or a Cloudflare connection' } | ConvertTo-Json
