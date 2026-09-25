param(
    [Parameter(Mandatory)]
    [ValidateSet('Plan', 'Init', 'Clone', 'Import', 'Tools', 'Run')]
    [string] $Step,

    # Binding(dev, site): site values only. Spec(dev) is read from spec.json beside this script.
    [Parameter(Mandatory)]
    [string] $Binding,

    [switch] $Apply,

    # Run only: the container command and its arguments (default: the image's shell).
    [Parameter(ValueFromRemainingArguments)]
    [string[]] $Command
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

function Assert-Match([string] $Name, $Value, [string] $Pattern) {
    if ($Value -isnot [string] -or $Value -cnotmatch $Pattern) { throw "Invalid ${Name}: $Value" }
}

$Spec = Read-Exact (Join-Path $PSScriptRoot 'spec.json') @(
    'role', 'image', 'labelKey', 'nixMount', 'workMount', 'repoPath', 'repoMount', 'cloneUrl')
$Site = Read-Exact $Binding @(
    'role', 'site', 'expectHost', 'nixVolume', 'workVolume', 'repoRoot', 'importRef', 'importSha', 'baseSha', 'gitNixpkgs', 'toolsRev')

if ($Site.role -cne $Spec.role) { throw "Binding role $($Site.role) does not match Spec role $($Spec.role)" }
Assert-Match 'image' $Spec.image '^nixos/nix@sha256:[a-f0-9]{64}$'
Assert-Match 'labelKey' $Spec.labelKey '^[a-z0-9.-]+/[a-z0-9-]+$'
# Store paths are absolute, so the seeded store only works at /nix.
Assert-Match 'nixMount' $Spec.nixMount '^/nix$'
foreach ($Name in 'workMount', 'repoMount') { Assert-Match $Name $Spec.$Name '^/[a-z0-9/_-]+$' }
Assert-Match 'repoPath' $Spec.repoPath ('^' + [regex]::Escape($Spec.workMount) + '/[a-z0-9_-]+$')
Assert-Match 'cloneUrl' $Spec.cloneUrl '^https://github\.com/[A-Za-z0-9-]+/[A-Za-z0-9._-]+$'
foreach ($Name in 'nixVolume', 'workVolume') { Assert-Match $Name $Site.$Name '^[a-z0-9][a-z0-9-]+$' }
if ($Site.nixVolume -ceq $Site.workVolume) { throw 'nixVolume and workVolume must differ.' }
Assert-Match 'repoRoot' $Site.repoRoot '^[A-Za-z]:\\[A-Za-z0-9\\._-]+$'
Assert-Match 'importRef' $Site.importRef '^refs/heads/[A-Za-z0-9._/-]+$'
foreach ($Name in 'importSha', 'baseSha', 'gitNixpkgs', 'toolsRev') { Assert-Match $Name $Site.$Name '^[a-f0-9]{40}$' }
if ($env:COMPUTERNAME -ine $Site.expectHost) {
    throw "expected Windows host $($Site.expectHost), found $env:COMPUTERNAME"
}

# WSLC is a fixed platform path, never Binding data: a data file must not choose what -Apply executes.
$ProgramFiles = if ($env:ProgramFiles) { $env:ProgramFiles } else { 'C:\Program Files' }
$Wslc = Join-Path $ProgramFiles 'WSL\wslc.exe'

# Container scripts are fixed text; site values reach them only as validated positional arguments.
# They avoid double quotes (Windows PowerShell 5.1 does not escape them for native commands),
# and grep/awk, which the official image lacks. Exit 3: target already holds other content;
# exit 4: /nix is not the store Init seeded from this image; exit 5: /repo not read-only.
$Git = 'g() { nix --extra-experimental-features ''nix-command flakes'' shell github:NixOS/nixpkgs/$p#git -c git $@; }; '
$Seed = 'm=/seed/var/windows-seed-image; if [ -e $m ]; then read v < $m; test $v = $1; exit; fi; ' +
    'test $(ls -A /seed | wc -l) -eq 0 || exit 3; cp -a /nix/. /seed/ && echo $1 > $m'
# Clone, Import and Tools run only on the volume Init seeded; the image is their first argument.
$Seeded = 'read v < /nix/var/windows-seed-image && test $v = $1 || exit 4; shift; '
$Verify = 'read v < /nix/var/windows-seed-image && echo $v && test $v = $1 && nix --version && nix-store --verify --check-contents'
$Clone = $Seeded + 'p=$1 u=$2 r=$3 b=$4; ' + $Git +
    'test ! -e $r || exit 3; g clone $u $r && g -C $r checkout --detach $b && test $(g -C $r rev-parse HEAD) = $b && g -C $r remote get-url origin'
$Import = $Seeded + 'p=$1 r=$2 f=$3 s=$4 b=$5 d=$6; o=; while read -r x x x x t y x; do case $t in $d) o=$y;; esac; done < /proc/self/mountinfo; ' +
    'case ,$o, in *,ro,*) ;; *) exit 5;; esac; ' + $Git +
    'cd $r && g -c safe.directory=$d/.bare fetch --no-tags $d/.bare $f:$f && test $(g rev-parse $f) = $s && g merge-base --is-ancestor $b $s && g rev-parse $f'
# Tools builds the flake's dev-profile at the committed toolsRev into $DevProfile, which is also its GC root.
# set -f keeps ? literal in the flake URL.
$DevProfile = '/nix/var/nix/profiles/windows-dev'
$ImagePath = '/root/.nix-profile/bin:/nix/var/nix/profiles/default/bin:/nix/var/nix/profiles/default/sbin'
$Tools = $Seeded + 'set -f; p=$1 r=$2 d=$3; ' +
    'nix --extra-experimental-features ''nix-command flakes'' build --profile $d git+file://$r?rev=$p#dev-profile && readlink $d'
# Every run is ephemeral, never pulls, and uses the pinned image.
function New-Run([string[]] $Mounts, [string] $Script, [string[]] $Values) {
    $Argv = @('run', '--rm', '--pull', 'never')
    foreach ($Mount in $Mounts) { $Argv += @('--volume', $Mount) }
    $Argv + @($Spec.image, 'sh', '-c', $Script, 'sh') + $Values
}

$NixAt = "$($Site.nixVolume):$($Spec.nixMount)"
$WorkAt = "$($Site.workVolume):$($Spec.workMount)"
# Runtime = instantiate(Spec, Binding) as exact wslc argv. The read-only /repo bind appears in Import only.
$Plan = [ordered]@{
    site = $Site.site
    wslc = $Wslc
    Init = [ordered]@{
        nixVolumeIfAbsent = @('volume', 'create', '--label', "$($Spec.labelKey)=nix", $Site.nixVolume)
        workVolumeIfAbsent = @('volume', 'create', '--label', "$($Spec.labelKey)=work", $Site.workVolume)
        seed = New-Run @("$($Site.nixVolume):/seed") $Seed @($Spec.image)
        verify = New-Run @($NixAt) $Verify @($Spec.image)
    }
    Clone = New-Run @($NixAt, $WorkAt) $Clone @($Spec.image, $Site.gitNixpkgs, $Spec.cloneUrl, $Spec.repoPath, $Site.baseSha)
    Import = New-Run @($NixAt, $WorkAt, "$($Site.repoRoot):$($Spec.repoMount):ro") $Import @(
        $Spec.image, $Site.gitNixpkgs, $Spec.repoPath, $Site.importRef, $Site.importSha, $Site.baseSha, $Spec.repoMount)
    Tools = New-Run @($NixAt, $WorkAt) $Tools @($Spec.image, $Site.toolsRev, $Spec.repoPath, $DevProfile)
    # Run: the profile's tools first on PATH, then the image's own PATH; no ports and no /repo.
    Run = @('run', '--rm', '--pull', 'never', '--volume', $NixAt, '--volume', $WorkAt,
        '--env', "PATH=$DevProfile/bin:$ImagePath", $Spec.image) + @($Command | Where-Object { $_ })
}

function Invoke-Wslc([string] $What, [string[]] $Argv) {
    Write-Host "> $What $(ConvertTo-Json -Compress -InputObject $Argv)"
    & $Wslc @Argv | Write-Host
    $Code = $LASTEXITCODE
    Write-Host "< $What exit $Code $((Get-Date).ToUniversalTime().ToString('o'))"
    if ($Code -ne 0) { throw "$What failed: wslc exit $Code" }
}

# The volume's role label; '' when it has none, $null when the volume is absent.
function Read-VolumeRole([string] $Name) {
    Write-Host "> inspect $Name"
    $Json = (& $Wslc volume inspect -f json $Name) -join "`n"
    Write-Host "< inspect exit $LASTEXITCODE"
    if ($LASTEXITCODE -ne 0) { return $null }
    $Data = $Json | ConvertFrom-Json
    $Items = @($Data)
    $Labels = if ($Items.Count -eq 1) { $Items[0].PSObject.Properties['Labels'] }
    $Label = if ($Labels -and $Labels.Value) { $Labels.Value.PSObject.Properties[$Spec.labelKey] }
    if ($Label) { [string] $Label.Value } else { '' }
}

# Create a volume only when absent; an existing volume is used only if it carries this role label.
function Confirm-Volume([string] $Name, [string] $Role, [string[]] $Create) {
    $Found = Read-VolumeRole $Name
    if ($null -eq $Found) {
        Invoke-Wslc "create $Name" $Create
        $Found = Read-VolumeRole $Name
    }
    if ($Found -cne $Role) { throw "Volume $Name is not labelled $($Spec.labelKey)=$Role; not using it." }
}

if ($Step -eq 'Plan') {
    $Plan | ConvertTo-Json -Depth 4
    exit 0
}

if (-not (Test-Path -LiteralPath $Wslc)) { throw "WSLC is missing: $Wslc" }
if ($Step -eq 'Import' -and -not (Test-Path -LiteralPath (Join-Path $Site.repoRoot '.bare\HEAD'))) {
    throw "No bare repository at $($Site.repoRoot)\.bare"
}
if ($Step -eq 'Tools' -and $Site.toolsRev -ceq ('0' * 40)) {
    throw 'toolsRev unset: commit the Binding with the reviewed revision before Tools.'
}
Write-Host "$Step on $env:COMPUTERNAME / $($Site.site)"
if (-not $Apply) {
    $Plan.$Step | ConvertTo-Json -Depth 3
    Write-Host 'Dry run. Add -Apply for this one step.'
    exit 0
}

if ($Step -eq 'Init') {
    Confirm-Volume $Site.nixVolume 'nix' $Plan.Init.nixVolumeIfAbsent
    Confirm-Volume $Site.workVolume 'work' $Plan.Init.workVolumeIfAbsent
    Invoke-Wslc 'seed' $Plan.Init.seed
    Invoke-Wslc 'verify' $Plan.Init.verify
} else {
    Invoke-Wslc $Step $Plan.$Step
}