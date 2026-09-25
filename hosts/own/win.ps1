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

$Spec = Read-Exact (Join-Path $PSScriptRoot 'spec.json') @('role', 'sshPort', 'stateMount', 'shmSize', 'authorizedKeyEnv', 'syntheticTrialEnv', 'imageRepository')
$Site = Read-Exact $Binding @('role', 'site', 'expectHost', 'wslc', 'container', 'hostPort', 'volume', 'publicKeyFile', 'image')

if ($Site.role -cne $Spec.role) { throw "Binding role $($Site.role) does not match Spec role $($Spec.role)" }
if ($Site.container -cnotmatch '^[a-z0-9][a-z0-9-]+$') { throw "Invalid container name: $($Site.container)" }
if ($Site.volume -cnotmatch '^[a-z0-9][a-z0-9-]+$') { throw "Invalid volume name: $($Site.volume)" }
if ($Site.hostPort -isnot [int] -or $Site.hostPort -lt 1024 -or $Site.hostPort -gt 65535) { throw "Invalid hostPort: $($Site.hostPort)" }
if ($Site.image -cnotmatch ('^' + [regex]::Escape($Spec.imageRepository) + '@sha256:[a-f0-9]{64}$')) {
    throw "Binding image must be $($Spec.imageRepository)@sha256:<digest>"
}
if ($env:COMPUTERNAME -ine $Site.expectHost) {
    throw "expected Windows host $($Site.expectHost), found $env:COMPUTERNAME"
}

$KeyFile = [Environment]::ExpandEnvironmentVariables($Site.publicKeyFile)
$Key = "<contents of $KeyFile>"
if ($Step -ne 'Plan') {
    if (-not (Test-Path -LiteralPath $Site.wslc)) { throw "WSLC is missing: $($Site.wslc)" }
}
if ($Step -eq 'Create') {
    $Key = (Get-Content -LiteralPath $KeyFile -Raw).Trim()
    if ($Key -notmatch '^ssh-ed25519 [A-Za-z0-9+/=]+(?: .*)?$') { throw 'Expected one ed25519 public key.' }
}
$RunArgs = @(
    'run', '--name', $Site.container, '--detach',
    '--publish', "127.0.0.1:$($Site.hostPort):$($Spec.sshPort)",
    '--shm-size', $Spec.shmSize,
    '--volume', "$($Site.volume):$($Spec.stateMount)",
    '--env', "$($Spec.authorizedKeyEnv)=$Key"
)
if ($SyntheticTrial) {
    Write-Warning 'Synthetic trial only: Chromium sandbox disabled; do not use real logins.'
    $RunArgs += @('--env', "$($Spec.syntheticTrialEnv)=1")
}

if ($Step -eq 'Plan') {
    # Runtime = instantiate(Spec, Binding), printed without touching WSLC, volumes or keys.
    Write-Host "Plan own on $env:COMPUTERNAME (binding site $($Site.site))"
    Write-Host "Pull:   $($Site.wslc) pull $($Site.image)"
    Write-Host "Create: $($Site.wslc) $($RunArgs -join ' ') $($Site.image)"
    exit 0
}

Write-Host "$Step on $env:COMPUTERNAME / $($Site.container) / SSH TCP $($Site.hostPort)"
if (-not $Apply) {
    Write-Host 'Dry run. Add -Apply for this one step.'
    exit 0
}

if ($Step -eq 'Pull') {
    & $Site.wslc pull $Site.image
    if ($LASTEXITCODE -ne 0) { throw "WSLC pull failed: $LASTEXITCODE" }
    exit 0
}

& $Site.wslc volume inspect $Site.volume
if ($LASTEXITCODE -ne 0) { throw "Named volume is missing: $($Site.volume)" }
& $Site.wslc @RunArgs $Site.image
if ($LASTEXITCODE -ne 0) { throw "WSLC run failed: $LASTEXITCODE" }
