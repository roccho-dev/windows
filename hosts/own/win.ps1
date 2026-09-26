param(
    [Parameter(Mandatory)]
    [ValidateSet('Plan', 'Pull', 'Create', 'Replace')]
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

# True only when the container inspect object has exactly one mount at $Target, and it is the named volume $Volume.
function Test-OwnMount($Inspect, [string] $Volume, [string] $Target) {
    $items = @($Inspect)
    if ($items.Count -ne 1 -or -not ($items[0].PSObject.Properties.Name -ccontains 'Mounts')) { return $false }
    $atTarget = @(@($items[0].Mounts) | Where-Object { $_ -and ([string] $_.Destination) -ceq $Target })
    if ($atTarget.Count -ne 1) { return $false }
    $m = $atTarget[0]
    return (([string] $m.Type) -ceq 'volume') -and (([string] $m.Name) -ceq $Volume)
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
if ($Step -in 'Create', 'Replace') {
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
    # keygenOnce, identity and tunnel run inside the bound Nix-defined WSLC dev runtime, with its OpenSSH client and
    # the key generated there; no Windows SSH. The client reaches sshd at the container's WSLC address (addressRead)
    # and first writes "[<address>]:<sshPort> <pinned key from knownHostsFile>" to its /tmp/known_hosts.
    $Ssh = @('ssh', '-F', '/dev/null', '-p', "$($Spec.sshPort)", '-i', $PrivateKey, '-o', 'IdentitiesOnly=yes', '-o', 'BatchMode=yes',
        '-o', 'StrictHostKeyChecking=yes', '-o', 'UserKnownHostsFile=/tmp/known_hosts', '-o', 'GlobalKnownHostsFile=/dev/null')
    $Target = "dev@<WSLC address of $($Site.container)>"
    $Plan = [ordered]@{
        site = $Site.site
        imageFrom = $Site.imageFrom
        # Inside the dev runtime; only the .pub is exported to publicKeyFile.
        keygenOnce = @('ssh-keygen', '-q', '-t', 'ed25519', '-N', '', '-f', $PrivateKey, '-C', "windows-$($Spec.role)-wslc")
        volumeCreateOnce = @($Wslc, 'volume', 'create', $Site.volume)
        pull = @($Wslc, 'pull', $Site.image)
        create = @($Wslc) + $RunArgs
        # Replace: stop and remove the container only (no -f, no -v); the named volume is kept, then create again.
        replaceStop = @($Wslc, 'stop', $Site.container)
        replaceRemove = @($Wslc, 'remove', $Site.container)
        # Pin the host key through WSLC, not over the network: store "[addr]:port <key>" in knownHostsFile.
        hostKeyRead = @($Wslc, 'exec', $Site.container, '/bin/cat', "$($Spec.stateMount)/.ssh/ssh_host_ed25519_key.pub")
        knownHostsFile = $KnownHosts
        knownHostsEntryPrefix = "[$($Spec.publishAddress)]:$($Site.hostPort)"
        addressRead = @($Wslc, 'container', 'inspect', '-f', 'json', $Site.container)
        identity = $Ssh + @($Target, 'id', '-un')
        # B2 (held): this reaches a Windows browser only if that client Run also publishes publishAddress:tunnelPort.
        tunnel = $Ssh + @('-N', '-o', 'ExitOnForwardFailure=yes', '-o', 'ServerAliveInterval=30',
            '-L', "0.0.0.0:$($Site.tunnelPort):127.0.0.1:$($Spec.xpraPort)", $Target)
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

if ($Step -eq 'Replace') {
    # Only replace the container this Binding created: it must exist and reference the Binding's volume and state mount.
    $Current = (& $Wslc container inspect -f json $Site.container) -join "`n"
    if ($LASTEXITCODE -ne 0) { throw "Container to replace is missing: $($Site.container)" }
    if (-not (Test-OwnMount ($Current | ConvertFrom-Json) $Site.volume $Spec.stateMount)) {
        throw "Container $($Site.container) does not mount exactly volume $($Site.volume) at $($Spec.stateMount); not replacing."
    }
    & $Wslc stop $Site.container
    if ($LASTEXITCODE -ne 0) { throw "WSLC stop failed: $LASTEXITCODE" }
    & $Wslc remove $Site.container
    if ($LASTEXITCODE -ne 0) { throw "WSLC remove failed: $LASTEXITCODE" }
    & $Wslc volume inspect $Site.volume
    if ($LASTEXITCODE -ne 0) { throw "Named volume lost after remove: $($Site.volume)" }
}

& $Wslc @RunArgs
if ($LASTEXITCODE -ne 0) { throw "WSLC run failed: $LASTEXITCODE" }
