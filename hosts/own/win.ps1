param(
    [Parameter(Mandatory)]
    [ValidateSet('Pull', 'Create')]
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
    [string] $Volume,
    [string] $PublicKeyFile,
    [switch] $SyntheticTrial,
    [switch] $Apply
)

$ErrorActionPreference = 'Stop'
if ($env:COMPUTERNAME -ine $ExpectHost) {
    throw "expected Windows host $ExpectHost, found $env:COMPUTERNAME"
}
$Wslc = 'C:\Program Files\WSL\wslc.exe'
if (-not (Test-Path -LiteralPath $Wslc)) { throw "WSLC is missing: $Wslc" }
if ($Image -cnotmatch '^ghcr\.io/roccho-dev/windows-own@sha256:[a-f0-9]{64}$') {
    throw 'Provide the own CI image by exact GHCR digest.'
}
if ($Step -eq 'Create') {
    if (-not $Volume) { throw 'Provide the existing named volume.' }
    if (-not $PublicKeyFile) { throw 'Provide a public key file.' }
    $Key = (Get-Content -LiteralPath $PublicKeyFile -Raw).Trim()
    if ($Key -notmatch '^ssh-ed25519 [A-Za-z0-9+/=]+(?: .*)?$') { throw 'Expected one ed25519 public key.' }
}

Write-Host "$Step on $env:COMPUTERNAME / $Container / SSH TCP $Port"
if (-not $Apply) {
    Write-Host 'Dry run. Add -Apply for this one step.'
    exit 0
}

if ($Step -eq 'Pull') {
    & $Wslc pull $Image
    if ($LASTEXITCODE -ne 0) { throw "WSLC pull failed: $LASTEXITCODE" }
    exit 0
}

& $Wslc volume inspect $Volume
if ($LASTEXITCODE -ne 0) { throw "Named volume is missing: $Volume" }
$RunArgs = @('run', '--name', $Container, '--detach', '--publish', "127.0.0.1:${Port}:2223", '--shm-size', '1G', '--volume', "${Volume}:/home/dev", '--env', "OWN_AUTHORIZED_KEY=$Key")
if ($SyntheticTrial) {
    Write-Warning 'Synthetic trial only: Chromium sandbox disabled; do not use real logins.'
    $RunArgs += @('--env', 'OWN_TRIAL_UNSANDBOXED=1')
}
& $Wslc @RunArgs $Image
if ($LASTEXITCODE -ne 0) { throw "WSLC run failed: $LASTEXITCODE" }
