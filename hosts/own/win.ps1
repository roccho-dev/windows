param(
    [Parameter(Mandatory)]
    [ValidateSet('Plan', 'Pull', 'Create')]
    [string] $Step,

    # Binding(own, site): site values only. Spec(own) is read from spec.json beside this script.
    [Parameter(Mandatory)]
    [string] $Binding,

    [switch] $SyntheticTrial,
    [switch] $Apply
)

$ErrorActionPreference = 'Stop'

function Read-Exact([string] $Path, [string[]] $Keys) {
    $Data = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    $Names = @($Data.PSObject.Properties.Name)
    $Missing = @($Keys | Where-Object { $Names -cnotcontains $_ })
    $Extra = @($Names | Where-Object { $Keys -cnotcontains $_ })
    if ($Missing -or $Extra) {
        throw "$Path must have exactly [$($Keys -join ', ')]; missing [$($Missing -join ', ')], unexpected [$($Extra -join ', ')]"
    }
    $Data
}

# ConvertFrom-Json yields Int32 on Windows PowerShell 5.1 and Int64 on PowerShell 7.
function Assert-Port([string] $Name, $Value, [int] $Min) {
    if (-not ($Value -is [int] -or $Value -is [long]) -or $Value -lt $Min -or $Value -gt 65535) {
        throw "Invalid ${Name}: $Value"
    }
}

function Assert-Name([string] $Name, $Value) {
    if ($Value -cnotmatch '^[a-z0-9][a-z0-9-]+$') { throw "Invalid ${Name}: $Value" }
}

$Spec = Read-Exact (Join-Path $PSScriptRoot 'spec.json') @(
    'role', 'imageRepository', 'sshPort', 'xpraPort', 'cdpPort', 'publishAddress',
    'stateMount', 'shmSize', 'authorizedKeyEnv', 'syntheticTrialEnv')
$Site = Read-Exact $Binding @(
    'role', 'site', 'expectHost', 'container', 'hostPort', 'tunnelPort', 'volume',
    'publicKeyFile', 'privateKeyFile', 'knownHostsFile', 'image', 'imageFrom')

if ($Site.role -cne $Spec.role) { throw "Binding role $($Site.role) does not match Spec role $($Spec.role)" }
foreach ($Name in 'sshPort', 'xpraPort', 'cdpPort') { Assert-Port $Name $Spec.$Name 1 }
if ($Spec.publishAddress -cne '127.0.0.1') { throw 'Spec publishAddress must stay loopback-only (127.0.0.1).' }
if ($Spec.stateMount -cnotmatch '^/[a-z0-9/_-]+$') { throw "Invalid stateMount: $($Spec.stateMount)" }
foreach ($Name in 'hostPort', 'tunnelPort') { Assert-Port $Name $Site.$Name 1024 }
Assert-Name 'container' $Site.container
Assert-Name 'volume' $Site.volume
if ($Site.image -cnotmatch ('^' + [regex]::Escape($Spec.imageRepository) + '@sha256:[a-f0-9]{64}$')) {
    throw "Binding image must be $($Spec.imageRepository)@sha256:<digest>"
}
if ($env:COMPUTERNAME -ine $Site.expectHost) {
    throw "expected Windows host $($Site.expectHost), found $env:COMPUTERNAME"
}

# WSLC is a fixed platform path, never Binding data: a data file must not choose what -Apply executes.
$ProgramFiles = if ($env:ProgramFiles) { $env:ProgramFiles } else { 'C:\Program Files' }
$Wslc = Join-Path $ProgramFiles 'WSL\wslc.exe'
$PublicKey = [Environment]::ExpandEnvironmentVariables($Site.publicKeyFile)
$PrivateKey = [Environment]::ExpandEnvironmentVariables($Site.privateKeyFile)
$KnownHosts = [Environment]::ExpandEnvironmentVariables($Site.knownHostsFile)

$Key = "<contents of $PublicKey>"
if ($Step -ne 'Plan' -and -not (Test-Path -LiteralPath $Wslc)) { throw "WSLC is missing: $Wslc" }
if ($Step -eq 'Create') {
    $Key = (Get-Content -LiteralPath $PublicKey -Raw).Trim()
    if ($Key -notmatch '^ssh-ed25519 [A-Za-z0-9+/=]+(?: .*)?$') { throw 'Expected one ed25519 public key.' }
}

$RunArgs = @(
    'run', '--name', $Site.container, '--detach',
    '--publish', "$($Spec.publishAddress):$($Site.hostPort):$($Spec.sshPort)",
    '--shm-size', $Spec.shmSize,
    '--volume', "$($Site.volume):$($Spec.stateMount)",
    '--env', "$($Spec.authorizedKeyEnv)=$Key"
)
if ($SyntheticTrial) {
    Write-Warning 'Synthetic trial only: Chromium sandbox disabled; do not use real logins.'
    $RunArgs += @('--env', "$($Spec.syntheticTrialEnv)=1")
}
$RunArgs += $Site.image

if ($Step -eq 'Plan') {
    # Runtime = instantiate(Spec, Binding) for the whole runbook, as exact argv; touches nothing.
    $Ssh = @('ssh', '-F', 'NUL', '-p', "$($Site.hostPort)", '-i', $PrivateKey, '-o', 'IdentitiesOnly=yes')
    $Plan = [ordered]@{
        site = $Site.site
        imageFrom = $Site.imageFrom
        keygenOnce = @('ssh-keygen', '-q', '-t', 'ed25519', '-N', '', '-f', $PrivateKey, '-C', "windows-$($Spec.role)")
        volumeCreateOnce = @($Wslc, 'volume', 'create', $Site.volume)
        pull = @($Wslc, 'pull', $Site.image)
        create = @($Wslc) + $RunArgs
        # Pin the host key through WSLC, not over the network: write "[addr]:port <key>" to knownHostsFile.
        hostKeyRead = @($Wslc, 'exec', $Site.container, '/bin/cat', "$($Spec.stateMount)/.ssh/ssh_host_ed25519_key.pub")
        knownHostsEntryPrefix = "[$($Spec.publishAddress)]:$($Site.hostPort)"
        identity = $Ssh + @('-o', 'StrictHostKeyChecking=yes', '-o', "UserKnownHostsFile=$KnownHosts", "dev@$($Spec.publishAddress)", 'id', '-un')
        tunnel = $Ssh + @('-N', '-o', 'StrictHostKeyChecking=yes', '-o', "UserKnownHostsFile=$KnownHosts", '-o', 'ExitOnForwardFailure=yes', '-o', 'ServerAliveInterval=30',
            '-L', "$($Spec.publishAddress):$($Site.tunnelPort):127.0.0.1:$($Spec.xpraPort)", "dev@$($Spec.publishAddress)")
        browserUrl = "http://$($Spec.publishAddress):$($Site.tunnelPort)/"
    }
    $Plan | ConvertTo-Json -Depth 3
    exit 0
}

Write-Host "$Step on $env:COMPUTERNAME / $($Site.container) / SSH TCP $($Site.hostPort)"
if (-not $Apply) {
    Write-Host 'Dry run. Add -Apply for this one step.'
    exit 0
}

if ($Step -eq 'Pull') {
    & $Wslc pull $Site.image
    if ($LASTEXITCODE -ne 0) { throw "WSLC pull failed: $LASTEXITCODE" }
    exit 0
}

& $Wslc volume inspect $Site.volume
if ($LASTEXITCODE -ne 0) { throw "Named volume is missing: $($Site.volume)" }
& $Wslc @RunArgs
if ($LASTEXITCODE -ne 0) { throw "WSLC run failed: $LASTEXITCODE" }
