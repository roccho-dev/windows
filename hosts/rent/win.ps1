param(
    [Parameter(Mandatory)]
    [ValidateSet('Pull', 'Create', 'Replace', 'LogonTask')]
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
    [switch] $Apply
)

$ErrorActionPreference = 'Stop'
if ($env:COMPUTERNAME -ine $ExpectHost) {
    throw "expected Windows host $ExpectHost, found $env:COMPUTERNAME"
}
$Wslc = 'C:\Program Files\WSL\wslc.exe'
if (-not (Test-Path -LiteralPath $Wslc)) { throw "WSLC is missing: $Wslc" }

# The only pre-state image Replace may remove: the published rent image that kept /home/dev on a volume.
$OldImage = 'ghcr.io/roccho-dev/windows-rent@sha256:da1393586b2e847c7508038675be8701c185b77be777ef1492689d4c604185ce'
# Exactly these two named volumes; never the old home volume.
$Mounts = [ordered]@{ '/work/repos' = $ReposVolume; '/var/lib/rent' = $StateVolume }

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

if ($Step -in @('Pull', 'Create', 'Replace')) {
    if ($Image -cnotmatch '^ghcr\.io/roccho-dev/windows-rent@sha256:[a-f0-9]{64}$') {
        throw 'Provide the CI image by exact GHCR digest.'
    }
}
if ($Step -in @('Create', 'Replace')) {
    if (-not $PublicKeyFile) { throw 'Provide a public key file.' }
    $Key = (Get-Content -LiteralPath $PublicKeyFile -Raw).Trim()
    if ($Key -notmatch '^ssh-ed25519 [A-Za-z0-9+/=]+(?: .*)?$') { throw 'Expected one ed25519 public key.' }
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

# Create and Replace: repos must already exist (never create an empty one); state is created once.
& $Wslc volume inspect $ReposVolume | Out-Null
if ($LASTEXITCODE -ne 0) { throw "Repos volume is missing: $ReposVolume" }

if ($Step -eq 'Replace') {
    $Current = (& $Wslc container inspect -f json $Container) -join "`n"
    if ($LASTEXITCODE -ne 0) { throw "Container to replace is missing: $Container" }
    $Parsed = $Current | ConvertFrom-Json
    $Items = @($Parsed)
    if ($Items.Count -ne 1 -or -not ((Test-OldShape $Items[0]) -or (Test-NewShape $Items[0]))) {
        throw "Container $Container is neither the old $OldImage shape nor the two-volume shape; not replacing."
    }
}

& $Wslc volume inspect $StateVolume | Out-Null
if ($LASTEXITCODE -ne 0) {
    & $Wslc volume create $StateVolume
    if ($LASTEXITCODE -ne 0) { throw "WSLC volume create failed: $LASTEXITCODE" }
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

$RunArgs = @('run', '--name', $Container, '--detach', '--publish', "127.0.0.1:${Port}:2222")
foreach ($Target in $Mounts.Keys) { $RunArgs += @('--volume', "$($Mounts[$Target]):$Target") }
$RunArgs += @('--env', "RENT_TS_HOSTNAME=$TsHostname", '--env', "RENT_AUTHORIZED_KEY=$Key", $Image)
& $Wslc @RunArgs
if ($LASTEXITCODE -ne 0) { throw "WSLC run failed: $LASTEXITCODE" }
