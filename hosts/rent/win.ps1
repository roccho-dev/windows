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

# Old shape: no mounts reported and exactly the old image.
function Test-OldShape($Item) {
    if (@(@($Item.Mounts) | Where-Object { $_ }).Count -ne 0) { return $false }
    return @(@($Item.Image, $Item.Config.Image) | Where-Object { $_ } | ForEach-Object { [string] $_ }) -ccontains $OldImage
}

# New shape: exactly the two named volumes at their targets and nothing else.
function Test-NewShape($Item) {
    $All = @(@($Item.Mounts) | Where-Object { $_ })
    if ($All.Count -ne $Mounts.Count) { return $false }
    foreach ($Target in $Mounts.Keys) {
        $At = @($All | Where-Object { ([string] $_.Destination) -ceq $Target })
        if ($At.Count -ne 1 -or ([string] $At[0].Type) -cne 'volume' -or ([string] $At[0].Name) -cne $Mounts[$Target]) {
            return $false
        }
    }
    return $true
}

# Migrate source: why the inspected old runtime is not provably the stopped owner of the old home, or $null.
function Get-OldSourceProblem($Item) {
    if (-not $Item) { return "Source container $OldContainer is missing." }
    if (([string] $Item.Name).TrimStart('/') -cne $OldContainer) { return "Inspect did not return $OldContainer." }
    $Running = $Item.State.Running
    if ($Running -isnot [bool]) { return "State of $OldContainer is unreadable." }
    if ($Running -or ([string] $Item.State.Status) -ceq 'running') { return "$OldContainer is running." }
    $AtHome = @(@($Item.Mounts) | Where-Object { $_ -and ([string] $_.Destination) -ceq '/home/dev' })
    if ($AtHome.Count -ne 1 -or ([string] $AtHome[0].Type) -cne 'volume' -or ([string] $AtHome[0].Name) -cne $OldHomeVolume) {
        return "$OldContainer does not provably mount volume $OldHomeVolume at /home/dev."
    }
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
$RunArgs += @('--env', "RENT_TS_HOSTNAME=$TsHostname", '--env', "RENT_AUTHORIZED_KEY=$Key", $Image)
$MigrateArgs = @('run', '--rm', '--volume', "${OldHomeVolume}:/old:ro", '--volume', "${StateVolume}:/var/lib/rent",
    $Image, '/bin/rent-state-import', $SessionId)

if ($Step -eq 'Plan') {
    # Exact argv for every live step; touches nothing.
    [ordered]@{
        pull = @($Wslc, 'pull', $Image)
        stateVolumeCreateOnce = @($Wslc, 'volume', 'create', $StateVolume)
        create = @($Wslc) + $RunArgs
        replaceAccepts = "exactly $OldImage with no mounts, or exactly $($ReposVolume):/work/repos and $($StateVolume):/var/lib/rent"
        replaceStop = @($Wslc, 'stop', $Container)
        replaceRemove = @($Wslc, 'remove', $Container)
        migrateAccepts = "$OldContainer exists, is not running, and mounts volume $OldHomeVolume at /home/dev (checked before and right before the helper); $Container absent or still the old shape"
        migrateSourceInspect = @($Wslc, 'inspect', $OldContainer)
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

if ($Step -eq 'Migrate') {
    Assert-OldSourceStopped
    & $Wslc volume inspect $OldHomeVolume | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Old home volume is missing: $OldHomeVolume" }
    $Item = Get-Container $Container
    if ($Item -and -not (Test-OldShape $Item)) { throw "Container $Container already uses the new shape; not migrating." }
} else {
    # Create and Replace: repos must already exist (never create an empty one).
    & $Wslc volume inspect $ReposVolume | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Repos volume is missing: $ReposVolume" }
    if ($Step -eq 'Replace') {
        $Item = Get-Container $Container
        if (-not $Item) { throw "Container to replace is missing: $Container" }
        if (-not ((Test-OldShape $Item) -or (Test-NewShape $Item))) {
            throw "Container $Container is neither the old $OldImage shape nor the two-volume shape; not replacing."
        }
    }
}

& $Wslc volume inspect $StateVolume | Out-Null
if ($LASTEXITCODE -ne 0) {
    & $Wslc volume create $StateVolume
    if ($LASTEXITCODE -ne 0) { throw "WSLC volume create failed: $LASTEXITCODE" }
}

if ($Step -eq 'Migrate') {
    # Recheck right before the helper; one-shot helper removed by --rm; nothing is deleted from the old home.
    Assert-OldSourceStopped
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
if ($LASTEXITCODE -ne 0) { throw "WSLC run failed: $LASTEXITCODE" }
