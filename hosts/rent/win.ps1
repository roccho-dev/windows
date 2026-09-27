param(
    [Parameter(Mandatory)]
    [ValidateSet('Plan', 'Pull', 'Create', 'Replace', 'Migrate', 'LogonTask')]
    [string] $Step,

    [Parameter(Mandatory)]
    [string] $ExpectHost,

    [Parameter(Mandatory)]
    [ValidatePattern('^[a-z0-9][a-z0-9-]+$')]
    [string] $Container,

    [Parameter(Mandatory)]
    [ValidateRange(1024, 65535)]
    [int] $Port,

    [string] $Image,
    [ValidatePattern('^[a-z0-9][a-z0-9-]+$')]
    [string] $ReposVolume = 'repos',
    [ValidatePattern('^[a-z0-9][a-z0-9-]+$')]
    [string] $StateVolume = 'windows-rent-state',
    [ValidatePattern('^[a-z0-9][a-z0-9-]+$')]
    [string] $TsHostname = 'pc7337-windows-rent',
    [string] $PublicKeyFile,
    # Migrate only: the old home is mounted read-only into a one-shot --rm helper, never into the rent container.
    [ValidatePattern('^[a-z0-9][a-z0-9-]+$')]
    [string] $OldHomeVolume = 'dev-home',
    # Migrate only: the old runtime that owns the old home; it must exist, be stopped, and mount it at /home/dev.
    [ValidatePattern('^[a-z0-9][a-z0-9-]+$')]
    [string] $OldContainer = 'envs-dev-mutable',
    [ValidatePattern('^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')]
    [string] $SessionId = '4eba321e-6ade-4815-930d-dfa58b6fc960',
    # Migrate only: the exact pre-recorded image of the old source container.
    [ValidatePattern('^[^\s"'']+$')]
    [string] $OldImageSource,
    # Replace only: JSON array holding the pre-recorded argv (no secrets) that recreates the current container.
    [string] $RollbackArgvFile,
    [switch] $Apply
)

$ErrorActionPreference = 'Stop'
if ($env:COMPUTERNAME -ine $ExpectHost) {
    throw "expected Windows host $ExpectHost, found $env:COMPUTERNAME"
}
$Wslc = 'C:\Program Files\WSL\wslc.exe'
if ($Step -ne 'Plan' -and -not (Test-Path -LiteralPath $Wslc)) { throw "WSLC is missing: $Wslc" }

# The only pre-state image Replace may remove: the published rent image that kept /home/dev on a volume.
$OldImage = 'ghcr.io/roccho-dev/windows-rent@sha256:da1393586b2e847c7508038675be8701c185b77be777ef1492689d4c604185ce'
# Exactly these two named volumes; never the old home volume.
$Mounts = [ordered]@{ '/work/repos' = $ReposVolume; '/var/lib/rent' = $StateVolume }
if (@($Mounts.Values) -ccontains $OldHomeVolume) { throw "The old home volume $OldHomeVolume must not be repos or state." }
if ($OldContainer -ceq $Container) { throw "The old container $OldContainer must not be $Container." }

# WSLC inspect is the authority for name, state and image only; mounts are proven inside the container
# (rent-start and rent-state-import read their own mountinfo).
function Get-Images($Item) { @(@($Item.Image, $Item.Config.Image) | Where-Object { $_ } | ForEach-Object { [string] $_ }) }

function Test-Stopped($Item) {
    $Running = $Item.State.Running
    return ($Running -is [bool]) -and -not $Running -and ([string] $Item.State.Status) -cne 'running'
}

# Replace target: exactly $Container on the pre-recorded old image or on this Binding's image.
function Test-ReplaceableImage($Item) {
    if (([string] $Item.Name).TrimStart('/') -cne $Container) { return $false }
    $Images = Get-Images $Item
    return ($Images -ccontains $OldImage) -or ($Images -ccontains $Image)
}

# Migrate source: why the inspected old runtime is not the stopped, pinned source, or $null.
function Get-OldSourceProblem($Item) {
    if (-not $Item) { return "Source container $OldContainer is missing." }
    if (([string] $Item.Name).TrimStart('/') -cne $OldContainer) { return "Inspect did not return $OldContainer." }
    if ($Item.State.Running -isnot [bool]) { return "State of $OldContainer is unreadable." }
    if (-not (Test-Stopped $Item)) { return "$OldContainer is running." }
    if (-not ((Get-Images $Item) -ccontains $OldImageSource)) { return "$OldContainer is not the pinned image $OldImageSource." }
    return $null
}

# Possible concurrent writers of the old home: any container other than $Container that is not provably stopped.
function Get-WriterProblem($Items) {
    foreach ($Item in @($Items)) {
        $Name = ([string] $Item.Name).TrimStart('/')
        if ($Name -ceq $Container) { continue }
        if (-not (Test-Stopped $Item)) { return "Container $Name is not provably stopped." }
    }
    return $null
}

# Outcome of Create/Replace: running, and rent-start printed the fixed mount proof.
$Proof = "rent-mounts ok repos=$ReposVolume state=$StateVolume"
function Test-RunningProof($Item, $Logs) {
    if (-not $Item -or $Item.State.Running -isnot [bool] -or -not $Item.State.Running) { return $false }
    return @(@($Logs) | ForEach-Object { ([string] $_).TrimEnd() }) -ccontains $Proof
}

# Rollback: the pre-recorded argv must recreate exactly $Container on its current image, without secrets.
function Get-RollbackProblem($Argv, $Item) {
    $Argv = @($Argv)
    if ($Argv.Count -lt 4 -or @($Argv | Where-Object { $_ -isnot [string] }).Count) { return 'Rollback argv must be a JSON array of strings.' }
    if ($Argv[0] -cne 'run' -or $Argv -ccontains '--rm') { return 'Rollback argv must be one persistent run.' }
    $At = [array]::IndexOf([string[]] $Argv, '--name')
    if ($At -lt 0 -or $At + 1 -ge $Argv.Count -or $Argv[$At + 1] -cne $Container) { return "Rollback argv must name $Container." }
    if (-not ((Get-Images $Item) -ccontains $Argv[-1])) { return 'Rollback argv must end with the current container image.' }
    if (@($Argv | Where-Object { $_ -match '(?i)(token|secret|password|credential|private)' }).Count) { return 'Rollback argv must not carry secrets.' }
    return $null
}

function Get-Container([string] $Name) {
    $Current = (& $Wslc inspect $Name) -join "`n"
    if ($LASTEXITCODE -ne 0) { return $null }
    $Parsed = $Current | ConvertFrom-Json
    $Items = @($Parsed)
    if ($Items.Count -ne 1) { throw "Expected one container named $Name." }
    return $Items[0]
}

function Assert-OldSourceStopped {
    $Problem = Get-OldSourceProblem (Get-Container $OldContainer)
    if ($Problem) { throw "$Problem Not migrating." }
}

if ($Step -in @('Plan', 'Pull', 'Create', 'Replace', 'Migrate')) {
    if ($Image -cnotmatch '^ghcr\.io/roccho-dev/windows-rent@sha256:[a-f0-9]{64}$') {
        throw 'Provide the CI image by exact GHCR digest.'
    }
}
$Key = "<contents of $PublicKeyFile>"
if ($Step -in @('Create', 'Replace')) {
    if (-not $PublicKeyFile) { throw 'Provide a public key file.' }
    $Key = (Get-Content -LiteralPath $PublicKeyFile -Raw).Trim()
    if ($Key -notmatch '^ssh-ed25519 [A-Za-z0-9+/=]+(?: .*)?$') { throw 'Expected one ed25519 public key.' }
}

$RunArgs = @('run', '--name', $Container, '--detach', '--publish', "127.0.0.1:${Port}:2222")
foreach ($Target in $Mounts.Keys) { $RunArgs += @('--volume', "$($Mounts[$Target]):$Target") }
$RunArgs += @('--env', "RENT_REPOS_VOLUME=$ReposVolume", '--env', "RENT_STATE_VOLUME=$StateVolume",
    '--env', "RENT_TS_HOSTNAME=$TsHostname", '--env', "RENT_AUTHORIZED_KEY=$Key", $Image)
$MigrateArgs = @('run', '--rm', '--volume', "${OldHomeVolume}:/old:ro", '--volume', "${StateVolume}:/var/lib/rent",
    '--env', "RENT_OLD_VOLUME=$OldHomeVolume", '--env', "RENT_STATE_VOLUME=$StateVolume",
    $Image, '/bin/rent-state-import', $SessionId)
$ListArgs = @('container', 'list', '--all', '-q')

if ($Step -eq 'Plan') {
    # Exact argv for every live step; touches nothing.
    [ordered]@{
        pull = @($Wslc, 'pull', $Image)
        stateVolumeCreateOnce = @($Wslc, 'volume', 'create', $StateVolume)
        create = @($Wslc) + $RunArgs
        replaceAccepts = "$Container on exactly $OldImage or $Image (inspect name and image only), with a pre-recorded rollback argv"
        replaceStop = @($Wslc, 'stop', $Container)
        replaceRemove = @($Wslc, 'remove', $Container)
        postGate = "within 60 s: $Container Running and its log has the line '$Proof'; otherwise Replace rolls back"
        postGateLogs = @($Wslc, 'logs', $Container)
        migrateAccepts = "$OldContainer exists, is stopped, and is exactly $OldImageSource (checked before and right before the helper); every other container except $Container is stopped; $Container absent or exactly $OldImage"
        migrateSourceInspect = @($Wslc, 'inspect', $OldContainer)
        migrateContainerList = @($Wslc) + $ListArgs
        migrate = @($Wslc) + $MigrateArgs
    } | ConvertTo-Json -Depth 3
    exit 0
}

Write-Host "$Step on $env:COMPUTERNAME / $Container / TCP $Port"
if (-not $Apply) {
    Write-Host 'Dry run. Add -Apply for this one step.'
    exit 0
}

if ($Step -eq 'Pull') {
    & $Wslc pull $Image
    if ($LASTEXITCODE -ne 0) { throw "WSLC pull failed: $LASTEXITCODE" }
    exit 0
}

if ($Step -eq 'LogonTask') {
    $Actor = whoami
    $Action = New-ScheduledTaskAction -Execute $Wslc -Argument "start $Container"
    $Trigger = New-ScheduledTaskTrigger -AtLogOn -User $Actor
    $Trigger.Delay = 'PT30S'
    $Principal = New-ScheduledTaskPrincipal -UserId $Actor -LogonType Interactive -RunLevel Limited
    $Settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) -ExecutionTimeLimit (New-TimeSpan -Minutes 5) -MultipleInstances IgnoreNew -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
    Register-ScheduledTask -TaskName "$Container-oci-logon" -Action $Action -Trigger $Trigger -Principal $Principal -Settings $Settings -Force | Out-Null
    Get-ScheduledTask -TaskName "$Container-oci-logon" | Select-Object TaskName, State
    exit 0
}

function Assert-NoOtherWriter {
    $Ids = @(& $Wslc @ListArgs | Where-Object { $_ })
    if ($LASTEXITCODE -ne 0 -or $Ids.Count -gt 64) { throw 'Container list is unreadable; not migrating.' }
    $Problem = Get-WriterProblem @($Ids | ForEach-Object { Get-Container $_ })
    if ($Problem) { throw "$Problem Not migrating." }
}

if ($Step -eq 'Migrate') {
    if (-not $OldImageSource) { throw 'Migrate needs -OldImageSource, the pre-recorded image of the old container.' }
    Assert-OldSourceStopped
    Assert-NoOtherWriter
    & $Wslc volume inspect $OldHomeVolume | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Old home volume is missing: $OldHomeVolume" }
    $Item = Get-Container $Container
    if ($Item -and -not ((Get-Images $Item) -ccontains $OldImage)) { throw "Container $Container is not the old $OldImage; not migrating." }
} else {
    # Create and Replace: repos must already exist (never create an empty one).
    & $Wslc volume inspect $ReposVolume | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Repos volume is missing: $ReposVolume" }
    if ($Step -eq 'Replace') {
        $Item = Get-Container $Container
        if (-not $Item) { throw "Container to replace is missing: $Container" }
        if (-not (Test-ReplaceableImage $Item)) { throw "Container $Container is neither exactly $OldImage nor $Image; not replacing." }
        if (-not $RollbackArgvFile) { throw 'Replace needs -RollbackArgvFile with the pre-recorded argv of the current container.' }
        $Rollback = @((Get-Content -LiteralPath $RollbackArgvFile -Raw) | ConvertFrom-Json)
        $Problem = Get-RollbackProblem $Rollback $Item
        if ($Problem) { throw "$Problem Not replacing." }
    }
}

& $Wslc volume inspect $StateVolume | Out-Null
if ($LASTEXITCODE -ne 0) {
    & $Wslc volume create $StateVolume
    if ($LASTEXITCODE -ne 0) { throw "WSLC volume create failed: $LASTEXITCODE" }
}

if ($Step -eq 'Migrate') {
    # Recheck right before the helper; one-shot helper removed by --rm; nothing is deleted from the old home.
    # The helper itself proves /old and the state mount from its own mountinfo before importing.
    & $Wslc volume inspect $StateVolume | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "State volume is missing: $StateVolume" }
    Assert-OldSourceStopped
    Assert-NoOtherWriter
    & $Wslc @MigrateArgs
    if ($LASTEXITCODE -ne 0) { throw "WSLC migrate helper failed: $LASTEXITCODE" }
    exit 0
}

if ($Step -eq 'Replace') {
    # Container only: no -f, no -v; every volume, including the old home volume, is kept.
    & $Wslc stop $Container
    if ($LASTEXITCODE -ne 0) { throw "WSLC stop failed: $LASTEXITCODE" }
    & $Wslc remove $Container
    if ($LASTEXITCODE -ne 0) { throw "WSLC remove failed: $LASTEXITCODE" }
    foreach ($Volume in $Mounts.Values) {
        & $Wslc volume inspect $Volume | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "Volume lost after remove: $Volume" }
    }
}

& $Wslc @RunArgs
$RunCode = $LASTEXITCODE
$Proven = $false
if ($RunCode -eq 0) {
    for ($Second = 0; $Second -lt 60 -and -not $Proven; $Second++) {
        Start-Sleep -Seconds 1
        $Proven = Test-RunningProof (Get-Container $Container) @(& $Wslc logs $Container 2>$null)
    }
}
if ($Proven) { Write-Output $Proof; exit 0 }
if ($Step -eq 'Replace') {
    # Only the pre-recorded argv; every volume is kept.
    if (Get-Container $Container) {
        & $Wslc stop $Container | Out-Null
        & $Wslc remove $Container
        if ($LASTEXITCODE -ne 0) { throw "New $Container failed its post-gate and could not be removed; not rolling back." }
    }
    & $Wslc @Rollback
    throw "New $Container failed its post-gate (run exit $RunCode); rolled back with the pre-recorded argv (exit $LASTEXITCODE)."
}
throw "WSLC run of $Container failed its post-gate (run exit $RunCode)."
