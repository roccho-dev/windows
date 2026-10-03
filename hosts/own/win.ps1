param(
    [Parameter(Mandatory)]
    [ValidateSet('Plan', 'Pull', 'Create', 'Replace')]
    [string] $Step,

    # Binding(own, site): site values only. Spec(own) is read from spec.json beside this script.
    [Parameter(Mandatory)]
    [string] $Binding,

    [switch] $SyntheticTrial,
    # Replace only: JSON array holding the pre-recorded argv (no secrets) that recreates the current container.
    [string] $RollbackArgvFile,
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
    'role', 'imageRepository', 'sshPort', 'cdpPort', 'publishAddress',
    'stateMount', 'workMount', 'nixMount', 'shmSize', 'authorizedKeyEnv', 'syntheticTrialEnv')
$Site = Read-Exact $Binding @(
    'role', 'site', 'expectHost', 'container', 'hostPort', 'volume', 'workVolume', 'nixVolume',
    'publicKeyFile', 'privateKeyFile', 'knownHostsFile', 'image', 'imageFrom')

if ($Site.role -cne $Spec.role) { throw "Binding role $($Site.role) does not match Spec role $($Spec.role)" }
foreach ($Name in 'sshPort', 'cdpPort') { Assert-Port $Name $Spec.$Name 1 }
if ($Spec.publishAddress -cne '127.0.0.1') { throw 'Spec publishAddress must stay loopback-only (127.0.0.1).' }
foreach ($Name in 'stateMount', 'workMount') {
    if ($Spec.$Name -cnotmatch '^/[a-z0-9/_-]+$') { throw "Invalid ${Name}: $($Spec.$Name)" }
}
if ($Spec.nixMount -cne '/nix') { throw 'Spec nixMount must be /nix.' }
Assert-Port 'hostPort' $Site.hostPort 1024
Assert-Name 'container' $Site.container
foreach ($Name in 'volume', 'workVolume', 'nixVolume') { Assert-Name $Name $Site.$Name }
# home state, work and the own /nix: three distinct named volumes, never deleted by this script.
$Volumes = [ordered]@{ $Spec.stateMount = $Site.volume; $Spec.workMount = $Site.workVolume; $Spec.nixMount = $Site.nixVolume }
if (@($Volumes.Values | Sort-Object -Unique -CaseSensitive).Count -ne 3) { throw 'The home, work and nix volumes must be distinct.' }
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
    '--shm-size', $Spec.shmSize
)
foreach ($Target in $Volumes.Keys) { $RunArgs += @('--volume', "$($Volumes[$Target]):$Target") }
$RunArgs += @('--env', "OWN_HOME_VOLUME=$($Site.volume)", '--env', "OWN_WORK_VOLUME=$($Site.workVolume)",
    '--env', "OWN_NIX_VOLUME=$($Site.nixVolume)", '--env', "$($Spec.authorizedKeyEnv)=$Key")
if ($SyntheticTrial) {
    Write-Warning 'Synthetic trial only: Chromium sandbox disabled; do not use real logins.'
    $RunArgs += @('--env', "$($Spec.syntheticTrialEnv)=1")
}
$RunArgs += $Site.image
# One-shot helper from exactly the Binding image: the nix volume at /seed, the image's own /nix beneath it. It takes
# the volume-root lock, so it refuses while own (or another seed) holds the volume.
$SeedArgs = @('run', '--rm', '--volume', "$($Site.nixVolume):/seed", '--env', "OWN_NIX_VOLUME=$($Site.nixVolume)", $Site.image, '/bin/own-nix-seed')
# Create/Replace outcome: Running, and own-start printed this line after every mount, lock and store check.
$Proof = "own-mounts ok home=$($Site.volume) work=$($Site.workVolume) nix=$($Site.nixVolume)"

if ($Step -eq 'Plan') {
    # Runtime = instantiate(Spec, Binding) for the whole runbook, as exact argv; touches nothing.
    # keygenOnce and identity run inside the bound Nix-defined WSLC dev runtime, with its OpenSSH client and
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
        workVolumeCreateOnce = @($Wslc, 'volume', 'create', $Site.workVolume)
        nixVolumeCreateOnce = @($Wslc, 'volume', 'create', $Site.nixVolume)
        pull = @($Wslc, 'pull', $Site.image)
        seed = @($Wslc) + $SeedArgs
        create = @($Wslc) + $RunArgs
        postGate = "within 60 s: $($Site.container) Running and its log has the line '$Proof'"
        # Replace: stop, seed, then remove the container only (no -f, no -v); volumes are kept, then create again.
        # Seed or remove failure: start the old container. Later failure: remove only the new container, then run the
        # -RollbackArgvFile argv (the old image cannot run on the /nix volume, so the new argv is never reused).
        replaceStop = @($Wslc, 'stop', $Site.container)
        replaceRemove = @($Wslc, 'remove', $Site.container)
        rollbackStart = @($Wslc, 'start', $Site.container)
        postGateLogs = @($Wslc, 'logs', $Site.container)
        # Pin the host key through WSLC, not over the network: store "[addr]:port <key>" in knownHostsFile.
        hostKeyRead = @($Wslc, 'exec', $Site.container, '/bin/cat', "$($Spec.stateMount)/.ssh/ssh_host_ed25519_key.pub")
        knownHostsFile = $KnownHosts
        knownHostsEntryPrefix = "[$($Spec.publishAddress)]:$($Site.hostPort)"
        addressRead = @($Wslc, 'container', 'inspect', '-f', 'json', $Site.container)
        identity = $Ssh + @($Target, 'id', '-un')
    }
    $Plan | ConvertTo-Json -Depth 3
    exit 0
}

# Windows PowerShell 5.1 turns native stderr into terminating errors under Stop (with 2>$null, or inside a caller's
# *>&1). From here every wslc call runs through this block: stdout is returned unchanged, stderr goes to the
# information stream, and $LASTEXITCODE is the native exit code (-1 if wslc could not be started).
$WslcExe = $Wslc
$Wslc = {
    $ErrorActionPreference = 'Continue'
    $global:LASTEXITCODE = -1
    & $WslcExe @args 2>&1 | ForEach-Object {
        if ($_ -is [System.Management.Automation.ErrorRecord]) { Write-Information -MessageData ([string] $_) -InformationAction Continue }
        else { $_ }
    }
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

function Get-Own {
    $Json = (& $Wslc container inspect -f json $Site.container) -join "`n"
    if ($LASTEXITCODE -ne 0) { return $null }
    # As ConvertFrom-JsonItems below, inline because own-image.yml loads this function by name on its own: the inspect
    # array's own elements on Windows PowerShell 5.1 and 7, so the count below is the number of containers.
    $Items = if ($PSVersionTable.PSVersion.Major -ge 7) { ConvertFrom-Json $Json -NoEnumerate } else { ConvertFrom-Json $Json }
    $Items = @($Items)
    if ($Items.Count -ne 1) { throw "Expected one container named $($Site.container)." }
    return $Items[0]
}

function Get-Images($Item) { @(@($Item.Image, $Item.Config.Image) | Where-Object { $_ } | ForEach-Object { [string] $_ }) }

function Test-RunningProof($Item, $Logs) {
    if (-not $Item -or $Item.State.Running -isnot [bool] -or -not $Item.State.Running) { return $false }
    return @(@($Logs) | ForEach-Object { ([string] $_).TrimEnd() }) -ccontains $Proof
}

function Wait-RunningProof {
    for ($Second = 0; $Second -lt 60; $Second++) {
        Start-Sleep -Seconds 1
        if (Test-RunningProof (Get-Own) @(& $Wslc logs $Site.container 2>$null 6>$null)) { return $true }
    }
    return $false
}

# Rollback: the pre-recorded argv must recreate exactly this container on its current image, without secrets.
function Get-RollbackProblem($Argv, $Item) {
    $Argv = @($Argv)
    if ($Argv.Count -lt 4 -or @($Argv | Where-Object { $_ -isnot [string] }).Count) { return 'Rollback argv must be a JSON array of strings.' }
    if ($Argv[0] -cne 'run' -or $Argv -ccontains '--rm') { return 'Rollback argv must be one persistent run.' }
    $At = [array]::IndexOf([string[]] $Argv, '--name')
    if ($At -lt 0 -or $At + 1 -ge $Argv.Count -or $Argv[$At + 1] -cne $Site.container) { return "Rollback argv must name $($Site.container)." }
    if (-not ((Get-Images $Item) -ccontains $Argv[-1])) { return 'Rollback argv must end with the current container image.' }
    # Strictly the forms this script has run: 'run', exactly one --detach, then only --name, --publish, --shm-size,
    # --volume and allowlisted --env options, each with one value, then the image. Anything else (--entrypoint, --user,
    # --restart, --rm, short or '=' forms, a trailing command) is refused before own is stopped.
    $EnvNames = @('OWN_AUTHORIZED_KEY', 'OWN_TRIAL_UNSANDBOXED', 'OWN_HOME_VOLUME', 'OWN_WORK_VOLUME', 'OWN_NIX_VOLUME')
    $Detach = 0; $Names = 0; $Publish = @(); $Mounted = @()
    for ($I = 1; $I -lt $Argv.Count - 1; $I++) {
        $Token = $Argv[$I]
        if ($Token -ceq '--detach') { $Detach++; continue }
        if ($Token -cnotin '--name', '--publish', '--shm-size', '--volume', '--env') { return "Rollback argv has unsupported token '$Token'." }
        if ($I + 1 -ge $Argv.Count - 1) { return "Rollback argv option $Token has no value." }
        $Value = $Argv[++$I]
        switch -CaseSensitive ($Token) {
            '--name' { $Names++ }
            '--publish' { $Publish += $Value }
            '--volume' { $Mounted += $Value }
            '--shm-size' { if ($Value -cne $Spec.shmSize) { return "Rollback argv must keep --shm-size $($Spec.shmSize)." } }
            '--env' { if ($Value.Split('=')[0] -cnotin $EnvNames) { return "Rollback argv has unsupported --env $($Value.Split('=')[0])." } }
        }
    }
    if ($Detach -ne 1 -or $Names -ne 1) { return 'Rollback argv must have exactly one --detach and one --name.' }
    # The exact old target: its SSH publish and its home volume (plus work and nix only if it already had all three).
    if ($Publish.Count -ne 1 -or $Publish[0] -cne "$($Spec.publishAddress):$($Site.hostPort):$($Spec.sshPort)") {
        return 'Rollback argv must publish exactly the old SSH port.'
    }
    $HomeOnly = "$($Site.volume):$($Spec.stateMount)"
    $All = @($Volumes.Keys | ForEach-Object { "$($Volumes[$_]):$_" }) | Sort-Object -CaseSensitive
    $Got = @($Mounted | Sort-Object -CaseSensitive)
    if (($Got -join "`n") -cne $HomeOnly -and ($Got -join "`n") -cne ($All -join "`n")) {
        return 'Rollback argv must mount exactly the home volume, or exactly the home, work and nix volumes.'
    }
    if (@($Argv | Where-Object { $_ -match '(?i)(token|secret|password|credential|private)' }).Count) { return 'Rollback argv must not carry secrets.' }
    return $null
}

# Rollback outcome: the container is Running on the old image for three consecutive polls within 60 s. The old image
# prints no own-mounts line, so Running and the image are the proof, never a WSLC exit code alone.
function Wait-OldRunning([string] $OldImage) {
    $Seen = 0
    for ($Second = 0; $Second -lt 60; $Second++) {
        Start-Sleep -Seconds 1
        $Now = Get-Own
        if ($Now -and $Now.State.Running -is [bool] -and $Now.State.Running -and ((Get-Images $Now) -ccontains $OldImage)) {
            if (++$Seen -ge 3) { return $true }
        } else { $Seen = 0 }
    }
    return $false
}

function Invoke-Seed {
    & $Wslc @SeedArgs | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "WSLC seed failed: $LASTEXITCODE" }
}

# Replace after a successful stop. Any failure rolls back and Replace still fails, reporting both outcomes:
# before the remove, start the old container; after it, remove only the new container and run the recorded argv.
function Complete-Replace($Rollback) {
    $Removed = $false
    try {
        Invoke-Seed
        & $Wslc remove $Site.container | Out-Host
        if ($LASTEXITCODE -ne 0) { throw "WSLC remove failed: $LASTEXITCODE" }
        $Removed = $true
        foreach ($Volume in $Volumes.Values) {
            & $Wslc volume inspect $Volume | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "Named volume lost after remove: $Volume" }
        }
        & $Wslc @RunArgs | Out-Host
        if ($LASTEXITCODE -ne 0) { throw "WSLC run failed: $LASTEXITCODE" }
        if (Wait-RunningProof) { return }
        throw "New $($Site.container) did not show Running and '$Proof' within 60 s."
    } catch {
        $Failure = $_.Exception.Message
    }
    $Steps = [System.Collections.Generic.List[string]]::new()
    try {
        if (-not $Removed) {
            & $Wslc start $Site.container | Out-Host
            $Steps.Add("start old exit $LASTEXITCODE")
            $Ok = $LASTEXITCODE -eq 0
        } else {
            if (Get-Own) {
                & $Wslc stop $Site.container | Out-Host
                $Steps.Add("stop new exit $LASTEXITCODE")
                & $Wslc remove $Site.container | Out-Host
                $Steps.Add("remove new exit $LASTEXITCODE")
            }
            & $Wslc @Rollback | Out-Host
            $Steps.Add("recorded argv exit $LASTEXITCODE")
            $Ok = $LASTEXITCODE -eq 0
        }
        if ($Ok) {
            $Ok = Wait-OldRunning $Rollback[-1]
            $Steps.Add($(if ($Ok) { 'old Running on its old image' } else { 'old not Running on its old image within 60 s' }))
        }
    } catch { $Ok = $false; $Steps.Add("error: $($_.Exception.Message)") }
    $Outcome = if ($Ok) { 'succeeded' } else { 'FAILED' }
    throw "Replace failed: $Failure | rollback ${Outcome}: $($Steps -join '; ')"
}

& $Wslc volume inspect $Site.volume
if ($LASTEXITCODE -ne 0) { throw "Named volume is missing: $($Site.volume)" }

# Windows PowerShell 5.1 writes a top-level JSON array as one object, so @(... | ConvertFrom-Json) nests it; PowerShell 7
# enumerates it unless -NoEnumerate. Both return here the top-level array's own elements (or the one value), and never
# unwrap a nested element, so the checks below still refuse it.
function ConvertFrom-JsonItems([string] $Text) {
    $Value = if ($PSVersionTable.PSVersion.Major -ge 7) { ConvertFrom-Json $Text -NoEnumerate } else { ConvertFrom-Json $Text }
    $Value
}

if ($Step -eq 'Replace') {
    # Only replace the container this Binding created: it must exist and reference the Binding's volume and state mount.
    $Current = (& $Wslc container inspect -f json $Site.container) -join "`n"
    if ($LASTEXITCODE -ne 0) { throw "Container to replace is missing: $($Site.container)" }
    $Item = @(ConvertFrom-JsonItems $Current)
    if (-not (Test-OwnMount $Item $Site.volume $Spec.stateMount)) {
        throw "Container $($Site.container) does not mount exactly volume $($Site.volume) at $($Spec.stateMount); not replacing."
    }
    if (-not $RollbackArgvFile) { throw 'Replace needs -RollbackArgvFile with the pre-recorded argv of the current container.' }
    $Rollback = @(ConvertFrom-JsonItems (Get-Content -LiteralPath $RollbackArgvFile -Raw))
    $Problem = Get-RollbackProblem $Rollback $Item[0]
    if ($Problem) { throw "$Problem Not replacing." }
}

# work and nix are created once; the home state volume must already exist.
foreach ($Volume in $Site.workVolume, $Site.nixVolume) {
    & $Wslc volume inspect $Volume | Out-Null
    if ($LASTEXITCODE -ne 0) {
        & $Wslc volume create $Volume
        if ($LASTEXITCODE -ne 0) { throw "WSLC volume create failed: $LASTEXITCODE" }
    }
}

if ($Step -eq 'Replace') {
    & $Wslc stop $Site.container
    if ($LASTEXITCODE -ne 0) { throw "WSLC stop failed: $LASTEXITCODE" }
    Complete-Replace $Rollback
} else {
    Invoke-Seed
    & $Wslc @RunArgs
    if ($LASTEXITCODE -ne 0) { throw "WSLC run failed: $LASTEXITCODE" }
    if (-not (Wait-RunningProof)) { throw "WSLC run of $($Site.container) failed its post-gate." }
}
Write-Output $Proof
