param(
    [Parameter(Mandatory)]
    [ValidateSet('Pull', 'Create', 'Serve')]
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
    [switch] $Apply
)

$ErrorActionPreference = 'Stop'
if ($env:COMPUTERNAME -ine $ExpectHost) {
    throw "expected Windows host $ExpectHost, found $env:COMPUTERNAME"
}
$Wslc = 'C:\Program Files\WSL\wslc.exe'
if (-not (Test-Path -LiteralPath $Wslc)) { throw "WSLC is missing: $Wslc" }

if ($Step -in @('Pull', 'Create')) {
    if ($Image -cnotmatch '^ghcr\.io/roccho-dev/windows-rent@sha256:[a-f0-9]{64}$') {
        throw 'Provide the CI image by exact GHCR digest.'
    }
}
if ($Step -eq 'Create') {
    if (-not $Volume) { throw 'Provide the existing named volume.' }
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
if ($Step -eq 'Create') {
    & $Wslc run --name $Container --detach --publish "127.0.0.1:${Port}:2222" --volume "${Volume}:/home/dev" --env "RENT_AUTHORIZED_KEY=$Key" $Image
    if ($LASTEXITCODE -ne 0) { throw "WSLC run failed: $LASTEXITCODE" }
    exit 0
}

$Tailnet = & tailscale status --json | ConvertFrom-Json
if ($LASTEXITCODE -ne 0 -or $Tailnet.BackendState -ne 'Running' -or -not $Tailnet.TailscaleIPs) {
    throw 'Tailscale is not connected to a tailnet.'
}
$Prefs = & tailscale debug prefs | ConvertFrom-Json
if ($LASTEXITCODE -ne 0 -or $Prefs.ShieldsUp) { throw 'Tailscale Shields Up blocks incoming SSH.' }
& tailscale serve --bg "--tcp=$Port" "tcp://127.0.0.1:$Port"
if ($LASTEXITCODE -ne 0) { throw "Tailscale Serve failed: $LASTEXITCODE" }
& tailscale serve status
if ($LASTEXITCODE -ne 0) { throw "Tailscale Serve readback failed: $LASTEXITCODE" }
