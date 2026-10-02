param(
    # The own Chromium profile to view: 1, 2 or 3.
    [int] $Profile = 0,

    # Binding(own, site); the dev runtime Binding for the same site is read from oci/dev/bindings.
    [string] $Binding = (Join-Path $PSScriptRoot 'bindings\G6I3.json'),

    # Run the synthetic preflight cases only: no WSLC, no live files.
    [switch] $SelfTest
)

# Shows one own Chromium profile in this terminal (e.g. Noctty) through cdp-tty: an ephemeral WSLC dev runtime
# runs ordinary SSH with strict host-key checking to the running own container and executes /bin/own-view N.
# Read-only on the host: it inspects own, reads its public host key through WSLC and the already pinned Windows
# known_hosts entry, and changes nothing persistent. The private key stays in the dev runtime's work volume and is
# passed to ssh as a path only; no Windows .ssh folder is mounted. It prints one end-to-end exit code.

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

# A named value of a parsed JSON object, or $null when absent (no strict-mode property errors).
function Get-Field($Object, [string] $Name) {
    if ($null -eq $Object) { return $null }
    $Property = $Object.PSObject.Properties[$Name]
    if ($null -eq $Property) { return $null }
    $Property.Value
}

# Type and base64 of one OpenSSH public key line, or throw.
function Split-PublicKey([string] $Line, [string] $What) {
    $Parts = @(([string] $Line).Trim() -split '\s+')
    if ($Parts.Count -lt 2 -or $Parts[0] -cne 'ssh-ed25519' -or $Parts[1] -cnotmatch '^[A-Za-z0-9+/]+={0,2}$') {
        throw "$What is not one ssh-ed25519 public key."
    }
    [ordered]@{ type = $Parts[0]; key = $Parts[1] }
}

# Pure preflight. Given own's inspect JSON, its public host key as read through WSLC and the pinned Windows
# known_hosts text, return the container command for the dev runtime, or throw why viewing must not start.
function Get-ViewCommand($Spec, $Site, $Inspect, [string] $HostKeyLine, [string] $KnownHostsText, $Profile) {
    if (@(1, 2, 3) -notcontains $Profile -or "$Profile" -notmatch '^[123]$') { throw "Profile must be 1, 2 or 3, not '$Profile'." }
    $Items = @($Inspect)
    if ($Items.Count -ne 1) { throw "Expected exactly one container named $($Site.container)." }
    $Own = $Items[0]
    if (([string] (Get-Field $Own 'Name')).TrimStart('/') -cne $Site.container) { throw "Inspect did not return $($Site.container)." }
    if ((Get-Field (Get-Field $Own 'State') 'Running') -ne $true) { throw "$($Site.container) is not running." }
    $Image = [string] (Get-Field (Get-Field $Own 'Config') 'Image')
    if ($Image -cne $Site.image) { throw "$($Site.container) runs $Image, not the Binding image $($Site.image)." }
    $Address = [string] (Get-Field (Get-Field (Get-Field (Get-Field $Own 'NetworkSettings') 'Networks') 'bridge') 'IPAddress')
    $Octets = @($Address -split '\.')
    if ($Octets.Count -ne 4 -or @($Octets | Where-Object { $_ -notmatch '^(0|[1-9][0-9]{0,2})$' -or [int] $_ -gt 255 }).Count) {
        throw "$($Site.container) has no valid bridge IPv4 address ('$Address')."
    }
    $Current = Split-PublicKey $HostKeyLine "The host key read from $($Site.container)"
    # Exactly one pinned entry for the published loopback name; hashed or other names do not count.
    $Pinned = "[$($Spec.publishAddress)]:$($Site.hostPort)"
    $Entries = @(([string] $KnownHostsText) -split "`r?`n" | Where-Object { $_ -and -not $_.TrimStart().StartsWith('#') } |
        Where-Object { (@($_.Trim() -split '\s+'))[0] -ceq $Pinned })
    if ($Entries.Count -ne 1) { throw "Expected exactly one pinned host key for $Pinned in the known_hosts file; found $($Entries.Count)." }
    $Want = Split-PublicKey ((@($Entries[0].Trim() -split '\s+', 2))[1]) "The pinned host key for $Pinned"
    if ($Want.type -cne $Current.type -or $Want.key -cne $Current.key) {
        throw "The host key of $($Site.container) does not match the pinned key for $Pinned; not connecting."
    }
    if ($Site.privateKeyFile -cnotmatch '^/[A-Za-z0-9/._-]+$') { throw "privateKeyFile must be an absolute Linux path, not '$($Site.privateKeyFile)'." }
    # Fixed shell text, values only as positional arguments; no double quotes (Windows PowerShell 5.1 does not
    # escape them for native commands). set -f keeps the [address]:port pattern literal.
    $Script = 'set -f; printf ''%s %s %s\n'' $1 $2 $3 > /tmp/known_hosts || exit 70; ' +
        'exec ssh -F /dev/null -i $4 -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=yes ' +
        '-o UserKnownHostsFile=/tmp/known_hosts -o GlobalKnownHostsFile=/dev/null -t -p $5 dev@$6 /bin/own-view $7'
    @('sh', '-c', $Script, 'sh', "[$Address]:$($Spec.sshPort)", $Current.type, $Current.key,
        $Site.privateKeyFile, "$($Spec.sshPort)", $Address, "$Profile")
}

function Invoke-SelfTest {
    $Spec = [pscustomobject]@{ publishAddress = '127.0.0.1'; sshPort = 2223 }
    $Site = [pscustomobject]@{ container = 'windows-own'; hostPort = 2223; privateKeyFile = '/work/repos/.auth/ssh/windows-own/id_ed25519'
        image = 'ghcr.io/roccho-dev/windows-own@sha256:' + ('a' * 64) }
    $Key = 'AAAAC3NzaC1lZDI1NTE5AAAAIB' + ('x' * 43)
    $Other = 'AAAAC3NzaC1lZDI1NTE5AAAAIC' + ('y' * 43)
    function Own([bool] $Running = $true, [string] $Image = $Site.image, [string] $Address = '172.17.0.5') {
        [pscustomobject]@{ Name = '/windows-own'; State = [pscustomobject]@{ Running = $Running }
            Config = [pscustomobject]@{ Image = $Image }
            NetworkSettings = [pscustomobject]@{ Networks = [pscustomobject]@{ bridge = [pscustomobject]@{ IPAddress = $Address } } } }
    }
    $HostKey = "ssh-ed25519 $Key root@own"
    $Pins = "# pinned`n[127.0.0.1]:2223 ssh-ed25519 $Key`n[other]:22 ssh-ed25519 $Other"
    $Tally = @{ n = 0 }
    function Reject([string] $Case, [scriptblock] $Call, [string] $Why) {
        try { $null = & $Call } catch {
            if ($_.Exception.Message -notlike "*$Why*") { throw "SelfTest ${Case}: rejected for the wrong reason: $($_.Exception.Message)" }
            $Tally.n++; return
        }
        throw "SelfTest ${Case}: was not rejected."
    }

    $Command = Get-ViewCommand $Spec $Site (Own) $HostKey $Pins 3
    $Values = @($Command | Select-Object -Skip 4)
    $Joined = @($Command) -join ' '
    $Checks = [ordered]@{
        'runs sh -c with the fixed script' = ($Command[0] -ceq 'sh' -and $Command[1] -ceq '-c' -and $Command[3] -ceq 'sh')
        'strict host-key checking only against /tmp/known_hosts' = ($Command[2] -clike '*StrictHostKeyChecking=yes*' -and
            $Command[2] -clike '*UserKnownHostsFile=/tmp/known_hosts*' -and $Command[2] -clike '*GlobalKnownHostsFile=/dev/null*')
        'no double quote reaches the native command line' = (-not $Joined.Contains('"'))
        'known_hosts names the current address, not the loopback pin' = ($Values[0] -ceq '[172.17.0.5]:2223')
        'the key written is the verified public key' = ($Values[1] -ceq 'ssh-ed25519' -and $Values[2] -ceq $Key)
        'the private key is a Linux path only' = ($Values[3] -ceq $Site.privateKeyFile -and -not $Joined.Contains('PRIVATE KEY'))
        'no Windows path or mount in the command' = (-not ($Joined -match '[A-Za-z]:\\|\\\.ssh|--volume|--mount'))
        'connects to the current address and requested profile' = ($Values[5] -ceq '172.17.0.5' -and $Values[6] -ceq '3' -and
            $Command[2] -clike '*-t -p $5 dev@$6 /bin/own-view $7')
    }
    foreach ($Name in $Checks.Keys) { if (-not $Checks[$Name]) { throw "SelfTest good case: $Name failed." }; $Tally.n++ }

    Reject 'key mismatch' { Get-ViewCommand $Spec $Site (Own) "ssh-ed25519 $Other" $Pins 1 } 'does not match the pinned key'
    Reject 'pin missing' { Get-ViewCommand $Spec $Site (Own) $HostKey "[other]:22 ssh-ed25519 $Key" 1 } 'found 0'
    Reject 'pin duplicated' { Get-ViewCommand $Spec $Site (Own) $HostKey "$Pins`n[127.0.0.1]:2223 ssh-ed25519 $Key" 1 } 'found 2'
    Reject 'hashed pin only' { Get-ViewCommand $Spec $Site (Own) $HostKey "|1|abc=|def= ssh-ed25519 $Key" 1 } 'found 0'
    Reject 'image mismatch' { Get-ViewCommand $Spec $Site (Own -Image ($Site.image -replace 'a{64}$', ('b' * 64))) $HostKey $Pins 1 } 'not the Binding image'
    Reject 'stopped' { Get-ViewCommand $Spec $Site (Own -Running $false) $HostKey $Pins 1 } 'is not running'
    Reject 'bad address' { Get-ViewCommand $Spec $Site (Own -Address '999.1.1.1') $HostKey $Pins 1 } 'no valid bridge IPv4'
    Reject 'no address' { Get-ViewCommand $Spec $Site (Own -Address '') $HostKey $Pins 1 } 'no valid bridge IPv4'
    Reject 'non-ed25519 host key' { Get-ViewCommand $Spec $Site (Own) "ssh-rsa $Key" $Pins 1 } 'not one ssh-ed25519'
    Reject 'two containers' { Get-ViewCommand $Spec $Site @((Own), (Own)) $HostKey $Pins 1 } 'exactly one container'
    foreach ($Bad in 0, 4, -1) { Reject "profile $Bad" { Get-ViewCommand $Spec $Site (Own) $HostKey $Pins $Bad } 'Profile must be 1, 2 or 3' }
    Write-Output "view.ps1 SelfTest passed: $($Tally.n) checks (PowerShell $($PSVersionTable.PSVersion))"
}

if ($SelfTest) { Invoke-SelfTest; exit 0 }

$Spec = Read-Exact (Join-Path $PSScriptRoot 'spec.json') @(
    'role', 'imageRepository', 'sshPort', 'xpraPort', 'cdpPort', 'publishAddress',
    'stateMount', 'workMount', 'nixMount', 'shmSize', 'authorizedKeyEnv', 'syntheticTrialEnv')
$Site = Read-Exact $Binding @(
    'role', 'site', 'expectHost', 'container', 'hostPort', 'tunnelPort', 'volume', 'workVolume', 'nixVolume',
    'publicKeyFile', 'privateKeyFile', 'knownHostsFile', 'image', 'imageFrom')
if ($Site.role -cne $Spec.role) { throw "Binding role $($Site.role) does not match Spec role $($Spec.role)" }
if ($env:COMPUTERNAME -ine $Site.expectHost) { throw "expected Windows host $($Site.expectHost), found $env:COMPUTERNAME" }
if ($Site.container -cnotmatch '^[a-z0-9][a-z0-9-]+$' -or $Site.site -cnotmatch '^[A-Za-z0-9-]+$') { throw 'Invalid container or site in the Binding.' }
# WSLC is a fixed platform path, never Binding data.
$ProgramFiles = if ($env:ProgramFiles) { $env:ProgramFiles } else { 'C:\Program Files' }
$Wslc = Join-Path $ProgramFiles 'WSL\wslc.exe'
if (-not (Test-Path -LiteralPath $Wslc)) { throw "WSLC is missing: $Wslc" }

# Read-only native call: stdout lines and exit code; stderr is not turned into terminating errors in 5.1.
function Read-Native([string[]] $Argv) {
    $ErrorActionPreference = 'Continue'
    $Out = @(& $Wslc @Argv 2>$null | ForEach-Object { [string] $_ })
    [ordered]@{ code = $LASTEXITCODE; lines = $Out }
}

$Inspect = Read-Native @('container', 'inspect', '-f', 'json', $Site.container)
if ($Inspect.code -ne 0) { throw "Cannot inspect $($Site.container): wslc exit $($Inspect.code)" }
$HostKey = Read-Native @('exec', $Site.container, '/bin/cat', "$($Spec.stateMount)/.ssh/ssh_host_ed25519_key.pub")
if ($HostKey.code -ne 0) { throw "Cannot read the public host key of $($Site.container): wslc exit $($HostKey.code)" }
$KnownHosts = [Environment]::ExpandEnvironmentVariables($Site.knownHostsFile)
if (-not (Test-Path -LiteralPath $KnownHosts -PathType Leaf)) { throw "The pinned known_hosts file is missing: $KnownHosts" }
$Command = Get-ViewCommand $Spec $Site (($Inspect.lines -join "`n") | ConvertFrom-Json) ($HostKey.lines -join "`n") `
    (Get-Content -LiteralPath $KnownHosts -Raw) $Profile
Write-Host "own $($Site.container) running $($Site.image); address $($Command[9]); pinned host key matches."

$DevScript = Join-Path $PSScriptRoot '..\..\oci\dev\win.ps1'
$DevBinding = Join-Path $PSScriptRoot "..\..\oci\dev\bindings\$($Site.site).json"
$Code = 0
try {
    & $DevScript -Step Run -Binding $DevBinding -Apply -Interactive -- @Command
} catch {
    # oci/dev/win.ps1 reports the wslc run exit code in its failure; anything else is a local failure before the run.
    if ($_.Exception.Message -match 'wslc exit (-?\d+)') { $Code = [int] $Matches[1] }
    else { Write-Host "view: $($_.Exception.Message)"; $Code = 1 }
}
# One end-to-end code: the ephemeral dev runtime's exit, which is ssh's (255 = transport or authentication)
# or, after a successful connection, own-view's as ssh relayed it. Not attributed further.
Write-Host "view: end-to-end exit $Code (dev runtime / ssh / own-view $Profile; 255 usually means the SSH transport)"
exit $Code
