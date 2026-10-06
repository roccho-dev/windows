#Requires -Version 7
param(
    [Parameter(Mandatory)]
    [ValidateSet('Plan', 'Pull', 'Create', 'Stage', 'Revert', 'Migrate', 'LogonTask')]
    [string] $Step,

    [Parameter(Mandatory)]
    [string] $ExpectHost,

    # The running rent: Create makes it; Stage and Revert keep it (stopped or restarted), never remove it; LogonTask
    # points the one logon task at it.
    [Parameter(Mandatory)]
    [ValidatePattern('^[a-z0-9][a-z0-9-]+$')]
    [string] $Container,

    [Parameter(Mandatory)]
    [ValidateRange(1024, 65535)]
    [int] $Port,

    [string] $Image,
    # Stage/Revert: the separately named candidate on the same named volumes.
    [ValidatePattern('^[a-z0-9][a-z0-9-]+$')]
    [string] $Candidate = 'windows-rent-cf',
    [ValidatePattern('^[a-z0-9][a-z0-9-]+$')]
    [string] $ReposVolume = 'repos',
    [ValidatePattern('^[a-z0-9][a-z0-9-]+$')]
    [string] $StateVolume = 'windows-rent-state',
    # rent's own writable /nix, seeded from the exact image before every Create/Stage start.
    [ValidatePattern('^[a-z0-9][a-z0-9-]+$')]
    [string] $NixVolume = 'windows-rent-nix',
    [string] $PublicKeyFile,
    # Migrate only: the old home is mounted read-only into a one-shot --rm helper, never into the rent container.
    [ValidatePattern('^[a-z0-9][a-z0-9-]+$')]
    [string] $OldHomeVolume = 'dev-home',
    # Migrate only: the old runtime that owns the old home; it must exist, be stopped, and mount it at /home/dev.
    [ValidatePattern('^[a-z0-9][a-z0-9-]+$')]
    [string] $OldContainer = 'envs-dev-mutable',
    [ValidatePattern('^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')]
    [string] $SessionId = '4eba321e-6ade-4815-930d-dfa58b6fc960',
    # Migrate, and Stage with an old home: the typed items selected for import where they differ (credentials: Claude
    # .credentials.json; session: that session's journal and directory; codex: Codex auth.json). None means no import.
    [ValidateSet('credentials', 'session', 'codex')]
    [string[]] $ImportItems = @(),
    # Migrate only: the exact pre-recorded image of the old source container.
    [ValidatePattern('^[^\s"'']+$')]
    [string] $OldImageSource,
    # Stage only: the verified envs placement distribution (place.ps1, sops.exe, rent-receive.sh and its ciphertexts) and
    # the rent target's own age identity file. Stage places the tunnel token from them after the kept rent stops.
    [string] $PlacementDistribution,
    [string] $PlacementIdentity,
    [switch] $Apply
)

$ErrorActionPreference = 'Stop'
# WSLC exit codes are checked explicitly and never throw, so no failure can skip a recovery step.
$PSNativeCommandUseErrorActionPreference = $false
if ($env:COMPUTERNAME -ine $ExpectHost) {
    throw "expected Windows host $ExpectHost, found $env:COMPUTERNAME"
}
$Wslc = 'C:\Program Files\WSL\wslc.exe'
if ($Step -ne 'Plan' -and -not (Test-Path -LiteralPath $Wslc)) { throw "WSLC is missing: $Wslc" }
# place.ps1 is a Windows PowerShell 5.1 script that ends with exit: it runs as its own process, so its exit can never end
# Stage or skip a recovery decision. Only its exit code is read; the token stays inside that process and its receiver.
$PlacementShell = 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'
$Placement = $PlacementShell

# Exactly these three distinct named volumes; never the old home volume.
$Mounts = [ordered]@{ '/work/repos' = $ReposVolume; '/var/lib/rent' = $StateVolume; '/nix' = $NixVolume }
if (@($Mounts.Values) -ccontains $OldHomeVolume) { throw "The old home volume $OldHomeVolume must not be repos, state or nix." }
if (@($Mounts.Values | Sort-Object -Unique -CaseSensitive).Count -ne $Mounts.Count) { throw 'The repos, state and nix volumes must be distinct.' }
if ($OldContainer -ceq $Container) { throw "The old container $OldContainer must not be $Container." }
if ($Candidate -ceq $Container -or $Candidate -ceq $OldContainer) { throw "The candidate $Candidate must be a new name." }
# The one logon task; LogonTask repoints it, so a logon never starts a second rent on the same volumes.
$TaskName = 'windows-rent-oci-logon'

# WSLC inspect is the authority for name, state and image only; mounts are proven inside the container
# (rent-start and rent-state-import read their own mountinfo).
function Get-Images($Item) { @(@($Item.Image, $Item.Config.Image) | Where-Object { $_ } | ForEach-Object { [string] $_ }) }

function Test-Stopped($Item) {
    $Running = $Item.State.Running
    return ($Running -is [bool]) -and -not $Running -and ([string] $Item.State.Status) -cne 'running'
}

function Test-Running($Item) { return $Item -and $Item.State.Running -is [bool] -and $Item.State.Running }

# Migrate source: why the inspected old runtime is not the stopped, pinned source, or $null.
function Get-OldSourceProblem($Item) {
    if (-not $Item) { return "Source container $OldContainer is missing." }
    if (([string] $Item.Name).TrimStart('/') -cne $OldContainer) { return "Inspect did not return $OldContainer." }
    if ($Item.State.Running -isnot [bool]) { return "State of $OldContainer is unreadable." }
    if (-not (Test-Stopped $Item)) { return "$OldContainer is running." }
    if (-not ((Get-Images $Item) -ccontains $OldImageSource)) { return "$OldContainer is not the pinned image $OldImageSource." }
    return $null
}

# Concurrent writers, for the supported environment only: WSLC 2.9.3 named volumes of the guest driver with empty
# options, as the Docker-managed engine stores them apart from its own container layers. WSLC shows no mounts, so a
# running container other than $Except is judged by its own PID 1 mount table against where each written volume
# actually lives (its anchor: device and filesystem root, read within this invocation). It shares a volume when a mount
# on that device has a root equal to, above or below the anchor's, compared component by component; an overlay writes
# only to its upper and work directories, which must be the engine's own layer directories. A volume in $Write may not
# be mounted writable, one in $NoReader not at all, and no mount may expose the store above a volume. Unreadable,
# changing or unexplained mounts count as sharing. This is a snapshot of cooperating containers, not a guard against a
# privileged remount or a hidden host alias.
$script:Anchors = $null
function Get-WriterProblem($Items, [string] $Except = $Container, [string[]] $Write = @($Mounts.Values), [string[]] $NoReader = @()) {
    foreach ($Item in @($Items)) {
        $Name = ([string] $Item.Name).TrimStart('/')
        if ($Except -and $Name -ceq $Except) { continue }
        if (Test-Stopped $Item) { continue }
        $Problem = if (Test-Running $Item) { Get-SharingProblem $Item $Write $NoReader } else { 'is not provably stopped.' }
        if ($Problem) { return "Container $Name $Problem" }
    }
    return $null
}

# A running container's own PID 1 mounts, read through WSLC between two inspects that must show the same start; $null
# when unreadable, malformed or changed meanwhile.
function Get-MountTable($Item) {
    $Id = [string] $Item.Id
    if (-not $Id) { return $null }
    $Lines = @(& $Wslc exec $Id cat /proc/1/mountinfo 2>$null)
    if ($LASTEXITCODE -ne 0) { return $null }
    $Again = Get-Container $Id
    if (-not (Test-Running $Again) -or [string] $Again.Id -cne $Id -or [string] $Again.State.StartedAt -cne [string] $Item.State.StartedAt) { return $null }
    $Table = [System.Collections.Generic.List[object]]::new()
    foreach ($Line in $Lines) {
        $F = ([string] $Line).TrimEnd() -split ' '
        $Sep = [array]::IndexOf($F, '-')
        if ($Sep -lt 6 -or $F.Count -lt $Sep + 4) { return $null }
        $Table.Add([pscustomobject] @{ Dev = $F[2]; Root = $F[3]; Point = $F[4]; Options = $F[5]; Type = $F[$Sep + 1]; Super = $F[$Sep + 3] })
    }
    if (-not @($Table | Where-Object { $_.Point -ceq '/' }).Count) { return $null }
    return $Table.ToArray()
}

function Get-RootRelation([string] $Root, [string] $Anchor) {
    if ($Root -ceq $Anchor) { return 'equal' }
    $Above = $Root.TrimEnd('/')
    if ($Anchor.StartsWith("$Above/", [StringComparison]::Ordinal)) { return 'above' }
    if ($Root.StartsWith("$Anchor/", [StringComparison]::Ordinal)) { return 'below' }
    return $null
}

# Where each rent volume and the old home live, from a container that mounts the state volume now: its device and
# filesystem root. A volume that holder does not mount takes the state volume's device and sibling root, the guest
# driver's layout; the seed checks that expectation against its own mount before any write. Every existing volume must
# be the guest driver's with empty options. $null when any of this is unsupported or unreadable.
function Get-Anchors($Holder) {
    $Table = Get-MountTable $Holder
    if (-not $Table) { return $null }
    $Names = @(@($Mounts.Values) + $OldHomeVolume)
    $Found = @{}
    foreach ($Name in $Names) {
        # repos and state exist as guest volumes; nix and the old home may also be truly absent; nothing else is supported.
        $Kind = Get-VolumeKind $Name
        if ($Kind -cne 'guest' -and -not ($Kind -ceq 'absent' -and $Name -cin @($NixVolume, $OldHomeVolume))) { return $null }
        $M = @($Table | Where-Object { $_.Type -cne 'overlay' -and $_.Root.EndsWith("/$Name/_data", [StringComparison]::Ordinal) })
        if ($M.Count -gt 1) { return $null }
        if ($M.Count -eq 1) { $Found[$Name] = @{ Dev = $M[0].Dev; Root = $M[0].Root } }
    }
    $State = $Found[$StateVolume]
    if (-not $State -or -not $State.Root.EndsWith("/volumes/$StateVolume/_data", [StringComparison]::Ordinal)) { return $null }
    $Store = $State.Root.Substring(0, $State.Root.Length - "/$StateVolume/_data".Length)
    foreach ($Name in $Names) {
        if (-not $Found[$Name]) { $Found[$Name] = @{ Dev = $State.Dev; Root = "$Store/$Name/_data" } }
        elseif ($Found[$Name].Dev -cne $State.Dev -or $Found[$Name].Root -cne "$Store/$Name/_data") { return $null }
    }
    return $Found
}

# One named volume, read now: 'guest' (the guest driver with empty options, the supported layout), 'other' (another
# driver, options or identity), 'absent' (inspect fails and a readable volume list does not name it) or 'unknown'.
function Get-VolumeKind([string] $Name) {
    $Text = (& $Wslc volume inspect $Name 2>$null) -join "`n"
    if ($LASTEXITCODE -ne 0) {
        $Rows = @(& $Wslc volume list 2>$null)
        if ($LASTEXITCODE -ne 0 -or $Rows.Count -lt 1 -or ([string] $Rows[0]).Trim() -cnotmatch '^DRIVER\s+VOLUME NAME$') { return 'unknown' }
        # Every non-blank row must read as 'driver name'; one that does not leaves the list, and so the absence, unknown.
        $Names = @()
        foreach ($Row in @($Rows | Select-Object -Skip 1)) {
            $Text = ([string] $Row).Trim()
            if (-not $Text) { continue }
            if ($Text -cnotmatch '^\S+\s+(\S.*)$') { return 'unknown' }
            $Names += $Matches[1].Trim()
        }
        return $(if ($Names -ccontains $Name) { 'unknown' } else { 'absent' })
    }
    $V = try { @($Text | ConvertFrom-Json) } catch { @() }
    if ($V.Count -ne 1) { return 'unknown' }
    if ([string] $V[0].Name -cne $Name -or [string] $V[0].Driver -cne 'guest' -or -not $V[0].DriverOpts -or
        @($V[0].DriverOpts.PSObject.Properties).Count) { return 'other' }
    return 'guest'
}

# This invocation's readback of a written volume: it must be the supported guest volume; when it is truly absent and
# -Create is given, it is created and read back as one.
function Assert-Volume([string] $Name, [switch] $Create) {
    $Kind = Get-VolumeKind $Name
    if ($Kind -ceq 'absent' -and $Create) {
        & $Wslc volume create $Name
        if ($LASTEXITCODE -ne 0) { throw "WSLC volume create failed: $LASTEXITCODE" }
        $Kind = Get-VolumeKind $Name
    }
    if ($Kind -cne 'guest') { throw "Volume $Name is $Kind, not a guest-driver volume with empty options (the supported layout)." }
}

function Get-SharingProblem($Item, [string[]] $Write, [string[]] $NoReader) {
    if (-not $script:Anchors) { return 'is running and no volume anchor was read in this invocation.' }
    $Table = Get-MountTable $Item
    if (-not $Table) { return 'has an unreadable or changing mount table.' }
    foreach ($M in $Table) {
        if ($M.Type -ceq 'overlay') {
            # Every layer of a supported overlay is an engine layer directory: lower layers are read, upper and work written.
            foreach ($Option in ($M.Super -split ',')) {
                if ($Option -cmatch '^(upperdir|workdir)=(.*)$' -and $Matches[2] -cnotmatch '^/var/lib/docker/overlay2/[0-9a-f]+/(diff|work)$') {
                    return 'has an overlay writing outside the engine layers.'
                }
                if ($Option -cmatch '^lowerdir=(.*)$') {
                    foreach ($Lower in ($Matches[1] -split ':')) {
                        if ($Lower -cnotmatch '^/var/lib/docker/overlay2/(l/[A-Za-z0-9]+|[0-9a-f]+/diff)$') { return 'has an overlay reading outside the engine layers.' }
                    }
                }
                if ($Option -cmatch '^(lowerdir|datadir)\+=') { return 'has an overlay layer form outside the supported layout.' }
            }
            continue
        }
        foreach ($Name in @(@($Write) + @($NoReader) | Sort-Object -Unique)) {
            $A = $script:Anchors[$Name]
            if ($M.Dev -cne $A.Dev) { continue }
            $Relation = Get-RootRelation $M.Root $A.Root
            if (-not $Relation) { continue }
            if ($Relation -ceq 'above') { return "exposes the volume store above $Name." }
            if ($NoReader -ccontains $Name) { return "mounts volume $Name." }
            if ($Write -ccontains $Name -and ",$($M.Options)," -clike '*,rw,*') { return "mounts volume $Name writable." }
        }
    }
    return $null
}

# Outcome of Create/Stage: Running, rent-start's mount line and its ready line (printed only after the token file
# passed and every service was launched), and still Running for 10 consecutive polls: a rejected tunnel stops it.
$Proof = "rent-mounts ok repos=$ReposVolume state=$StateVolume nix=$NixVolume"
$Ready = 'rent-start ok services=nix-daemon,cloudflared,sshd'
function Test-RunningProof($Item, $Logs) {
    if (-not (Test-Running $Item)) { return $false }
    $Lines = @(@($Logs) | ForEach-Object { ([string] $_).TrimEnd() })
    return ($Lines -ccontains $Proof) -and ($Lines -ccontains $Ready)
}

# Stage precondition on inspect now: the kept rent Running on readable images other than $Image, no candidate yet.
function Get-StageProblem($Old, $Existing) {
    if ($Old -and ([string] $Old.Name).TrimStart('/') -cne $Container) { return "Inspect of $Container returned $($Old.Name)." }
    if (-not (Test-Running $Old)) { return "$Container must exist and be Running to stage beside it." }
    if (-not (Get-Images $Old)) { return "$Container has no readable image." }
    if ((Get-Images $Old) -ccontains $Image) { return "$Container already runs $Image; nothing to stage." }
    if ($Existing) { return "Candidate $Candidate already exists; not staging." }
    return $null
}

# Stage placement inputs, checked before any task change or stop: why they are not usable, or $null. Paths and shapes only;
# no secret is read. place.ps1's receiver writes only windows-rent-state, so any other state volume is refused.
function Get-PlacementProblem {
    if ($StateVolume -cne 'windows-rent-state') { return "Placement writes only windows-rent-state; state volume $StateVolume is refused." }
    if (-not $PlacementDistribution -or -not $PlacementIdentity) { return 'Stage needs -PlacementDistribution and -PlacementIdentity.' }
    $Files = [ordered]@{
        'system PowerShell 5.1' = $PlacementShell
        'place.ps1' = Join-Path $PlacementDistribution 'place.ps1'
        'sops.exe' = Join-Path $PlacementDistribution 'sops.exe'
        'rent-receive.sh' = Join-Path $PlacementDistribution 'rent-receive.sh'
        'tunnel envelope' = Join-Path (Join-Path $PlacementDistribution 'ciphertexts') 'dev-rent-tunnel.sops.yaml'
        'rent age identity' = $PlacementIdentity
    }
    foreach ($Name in $Files.Keys) {
        $Item = Get-Item -LiteralPath $Files[$Name] -Force -ErrorAction SilentlyContinue
        if (-not $Item -or $Item.PSIsContainer -or ($Item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            return "Placement input '$Name' is not a plain file: $($Files[$Name])"
        }
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

# Readback of the kept rent or the candidate by name: inspect must return that very container, or nothing.
function Get-Named([string] $Name) {
    $Item = Get-Container $Name
    if ($Item -and ([string] $Item.Name).TrimStart('/') -cne $Name) { throw "Inspect of $Name returned $($Item.Name)." }
    return $Item
}

function Assert-OldSourceStopped {
    $Problem = Get-OldSourceProblem (Get-Container $OldContainer)
    if ($Problem) { throw "$Problem Not migrating." }
}

if ($Step -in @('Plan', 'Pull', 'Create', 'Stage', 'Migrate')) {
    if ($Image -cnotmatch '^ghcr\.io/roccho-dev/windows-rent@sha256:[a-f0-9]{64}$') {
        throw 'Provide the CI image by exact GHCR digest.'
    }
}
$Key = "<contents of $PublicKeyFile>"
if ($Step -in @('Create', 'Stage')) {
    if (-not $PublicKeyFile) { throw 'Provide a public key file.' }
    $Key = (Get-Content -LiteralPath $PublicKeyFile -Raw).Trim()
    if ($Key -notmatch '^ssh-ed25519 [A-Za-z0-9+/=]+(?: .*)?$') { throw 'Expected one ed25519 public key.' }
}
# Stage refuses unusable placement inputs here, before any WSLC call, task change or stop.
if ($Step -eq 'Stage') {
    $Problem = Get-PlacementProblem
    if ($Problem) { throw "$Problem Not staging." }
}
if ($Step -eq 'Migrate' -and -not $ImportItems.Count) { throw 'Migrate needs -ImportItems, the selected items to import.' }
if (@($ImportItems | Sort-Object -Unique).Count -ne $ImportItems.Count) { throw 'Each import item may be named only once.' }
if ($ImportItems.Count -and -not $OldImageSource) { throw 'An import needs -OldImageSource, the pre-recorded image of the old home holder.' }

# The tunnel token is never an argument or environment value: rent-start reads its fixed file in the state volume.
function Get-RunArgs([string] $Name) {
    $Argv = @('run', '--name', $Name, '--detach', '--publish', "127.0.0.1:${Port}:2222")
    foreach ($Target in $Mounts.Keys) { $Argv += @('--volume', "$($Mounts[$Target]):$Target") }
    return $Argv + @('--env', "RENT_REPOS_VOLUME=$ReposVolume", '--env', "RENT_STATE_VOLUME=$StateVolume",
        '--env', "RENT_NIX_VOLUME=$NixVolume", '--env', "RENT_AUTHORIZED_KEY=$Key", $Image)
}
$RunArgs = Get-RunArgs $Container
$StageArgs = Get-RunArgs $Candidate
$MigrateArgs = @('run', '--rm', '--volume', "${OldHomeVolume}:/old:ro", '--volume', "${StateVolume}:/var/lib/rent",
    '--env', "RENT_OLD_VOLUME=$OldHomeVolume", '--env', "RENT_STATE_VOLUME=$StateVolume",
    $Image, '/bin/rent-state-import', $SessionId) + $ImportItems
$ListArgs = @('container', 'list', '--all', '-q')
# One-shot helper from exactly $Image: the nix volume at /seed, the image's own /nix beneath it; removed by --rm.
$SeedArgs = @('run', '--rm', '--volume', "${NixVolume}:/seed", '--env', "RENT_NIX_VOLUME=$NixVolume", $Image, '/bin/rent-nix-seed')
# Stage's token placement: envs place.ps1 decrypts with the rent identity and hands the token to its receiver in exactly
# $Image on windows-rent-state. Paths and the image digest only.
$PlaceDistribution = if ($PlacementDistribution) { $PlacementDistribution } else { '<placement distribution>' }
$PlaceIdentity = if ($PlacementIdentity) { $PlacementIdentity } else { '<rent age identity>' }
$PlaceArgs = @('-NoProfile', '-NonInteractive', '-File', (Join-Path $PlaceDistribution 'place.ps1'), '-Target', 'rent',
    '-Identity', $PlaceIdentity, '-Ciphertext', (Join-Path (Join-Path $PlaceDistribution 'ciphertexts') 'dev-rent-tunnel.sops.yaml'),
    '-RentImage', $Image)

if ($Step -eq 'Plan') {
    # Exact argv for every live step; touches nothing.
    [ordered]@{
        pull = @($Wslc, 'pull', $Image)
        stateVolumeCreateOnce = @($Wslc, 'volume', 'create', $StateVolume)
        nixVolumeCreateOnce = @($Wslc, 'volume', 'create', $NixVolume)
        seedAccepts = "right before each seed, every container is provably stopped or, judged by its own PID 1 mounts against volume anchors read in this invocation from a running $Container, Running without mounting $NixVolume writable or exposing its store (with no anchors, any Running container refuses); with anchors the seed gets the expected backing and exits 3, writing nothing, when /seed differs, which halts Stage"
        seedContainerList = @($Wslc) + $ListArgs
        seed = @($Wslc) + $SeedArgs
        create = @($Wslc) + $RunArgs
        readyGate = "within 60 s: Running with log lines '$Proof' and '$Ready', then Running for 10 consecutive polls"
        stageAccepts = "$Container exists and is Running (its images read by inspect now), $Candidate absent, every other container provably stopped or Running without mounting a rent volume writable or exposing its store (judged by its own PID 1 mounts against volume anchors read from $Container now; unreadable anchors or mounts refuse), logon task $TaskName exactly '$Wslc start $Container'; placement inputs are plain files and the state volume is windows-rent-state, checked before any change"
        # Order: stageTask (while $Container still runs, so a logon can only try the not-yet-existing candidate),
        # stageStop, stagePlace, seed, the migrate argv for the selected import items (only when given), stageRun,
        # readyGate. Success leaves the task on the running candidate.
        stageTask = @($TaskName, $Wslc, 'start', $Candidate)
        stageStop = @($Wslc, 'stop', $Container)
        stagePlace = @($PlacementShell) + $PlaceArgs
        stagePlaceHalt = "any placement result but exit 0 halts Stage: no seed, run, task restore or start of $Container; $Container stays stopped, the logon task targets the absent $Candidate, and the slot and writer state are UNKNOWN until separately authorized recovery"
        stageRun = @($Wslc) + $StageArgs
        readyLogs = @($Wslc, 'logs', $Candidate)
        # After a placement exit 0, a Stage failure halts instead (no revert, task not restored, $Container stopped) on seed
        # exit 3, an import outcome other than 0/10/11/20/21, or any failure after an import that updated the state; any
        # other failure, and the Revert step, run: revertStop if running, then the candidate provably stopped by readback
        # whatever stop returned, revertRemove (a failed Stage's candidate only), the writer check passing for every other
        # container, revertTask read back, and only then revertStart and Running on its inspected images for 3 consecutive
        # polls. This returns the runtime and logon task only: the placed token and any imported state stay as they are.
        revertStop = @($Wslc, 'stop', $Candidate)
        revertRemove = @($Wslc, 'remove', $Candidate)
        revertTask = @($TaskName, $Wslc, 'start', $Container)
        revertStart = @($Wslc, 'start', $Container)
        logonTask = @($TaskName, $Wslc, 'start', $Container)
        migrateAccepts = "$OldContainer exists, is stopped, and is exactly $OldImageSource (checked before and right before the helper); $Container absent, or provably stopped with the same Id and images right before the helper; no other running container holds the state volume or writes the old home; only the selected items ($($ImportItems -join ', ')) that differ are written"
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

# The one logon task: which container it starts, by readback; $null when absent. Anything but exactly one
# '<wslc> start <name>' action is refused rather than interpreted.
function Get-TaskTarget {
    $Tasks = @(Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue)
    if ($Tasks.Count -eq 0) { return $null }
    $Actions = @($Tasks[0].Actions)
    if ($Tasks.Count -ne 1 -or $Actions.Count -ne 1 -or [string] $Actions[0].Execute -cne $Wslc -or
        [string] $Actions[0].Arguments -cnotmatch '^start ([a-z0-9][a-z0-9-]+)$') {
        throw "Logon task $TaskName is not exactly one '$Wslc start <container>' action."
    }
    return $Matches[1]
}

# Point the one logon task at $Name (re-registering the same task, never a second one) and prove it by readback.
function Set-TaskTarget([string] $Name) {
    $Actor = whoami
    $Action = New-ScheduledTaskAction -Execute $Wslc -Argument "start $Name"
    $Trigger = New-ScheduledTaskTrigger -AtLogOn -User $Actor
    $Trigger.Delay = 'PT30S'
    $Principal = New-ScheduledTaskPrincipal -UserId $Actor -LogonType Interactive -RunLevel Limited
    $Settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) -ExecutionTimeLimit (New-TimeSpan -Minutes 5) -MultipleInstances IgnoreNew -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
    Register-ScheduledTask -TaskName $TaskName -Action $Action -Trigger $Trigger -Principal $Principal -Settings $Settings -Force | Out-Null
    $Now = Get-TaskTarget
    if ($Now -cne $Name) { throw "Logon task $TaskName starts '$Now' after registration, not $Name." }
}

if ($Step -eq 'LogonTask') {
    Set-TaskTarget $Container
    Write-Output "Logon task $TaskName starts $Container"
    exit 0
}

# Only when another container runs are anchors needed: read once in this invocation from the running $Except holder.
function Assert-NoOtherWriter([string] $Except = $Container, [string] $Action = 'migrating', [string[]] $Write = @($Mounts.Values),
    [string[]] $NoReader = @()) {
    $Ids = @(& $Wslc @ListArgs | Where-Object { $_ })
    if ($LASTEXITCODE -ne 0 -or $Ids.Count -gt 64) { throw "Container list is unreadable; not $Action." }
    $Items = @($Ids | ForEach-Object { Get-Container $_ })
    $Named = { param($I) ([string] $I.Name).TrimStart('/') }
    if (-not $script:Anchors -and @($Items | Where-Object { $_ -and (& $Named $_) -cne $Except -and (Test-Running $_) }).Count) {
        $Holder = @($Items | Where-Object { $_ -and $Except -and (& $Named $_) -ceq $Except -and (Test-Running $_) })
        if ($Holder.Count -eq 1) { $script:Anchors = Get-Anchors $Holder[0] }
    }
    $Problem = Get-WriterProblem $Items $Except $Write $NoReader
    if ($Problem) { throw "$Problem Not $Action." }
}

# Seed the nix volume from exactly $Image while no other container can write it; rent-nix-seed proves its own mounts.
# With anchors, the seed is given the expected backing and refuses before any write when its actual mount differs: the
# store is then unknown, so that halts rather than restarting anything.
function Invoke-Seed {
    Assert-NoOtherWriter '' 'seeding' @($NixVolume)
    $Argv = $SeedArgs
    if ($script:Anchors) {
        $Expect = "RENT_NIX_EXPECT=$($script:Anchors[$NixVolume].Dev) $($script:Anchors[$NixVolume].Root)"
        $Argv = @($SeedArgs[0..5]) + @('--env', $Expect) + @($SeedArgs[6..($SeedArgs.Count - 1)])
    }
    & $Wslc @Argv | Out-Host
    if ($LASTEXITCODE -eq 3) { $script:Halt = 'the volume store is not the one the writer check compared'; throw 'WSLC seed exit 3: /seed is not the expected backing' }
    if ($LASTEXITCODE -ne 0) { throw "WSLC seed failed: $LASTEXITCODE" }
}

# The typed import inside Stage, after the seed and before the candidate runs: the old home's holder stopped on its pinned
# image, and no running container holding the state volume in any mode or the old home writable. Unchanged or updated
# continues; a refusal with no target changed or a verified restore is a known failure; any other outcome halts.
function Invoke-Import {
    Assert-OldSourceStopped
    Assert-NoOtherWriter '' 'importing' @($StateVolume, $OldHomeVolume) @($StateVolume)
    & $Wslc @MigrateArgs | Out-Host
    switch ($LASTEXITCODE) {
        0 { return 'unchanged' }
        10 { return 'updated' }
        11 { return 'updated' }
        20 { throw 'WSLC import refused with no target changed' }
        21 { throw 'WSLC import failed and restored every changed item' }
        default { $script:Halt = "the import outcome is unknown (exit $LASTEXITCODE)"; throw "WSLC import: $($script:Halt)." }
    }
}

function Wait-Ready([string] $Name) {
    $Seen = 0
    for ($Second = 0; $Second -lt 60 -or ($Seen -gt 0 -and $Second -lt 70); $Second++) {
        Start-Sleep -Seconds 1
        if (Test-RunningProof (Get-Named $Name) @(& $Wslc logs $Name 2>$null)) {
            if (++$Seen -ge 10) { return $true }
        } elseif ($Seen) { return $false }
    }
    return $false
}

# The kept rent is back only when it is Running on the images inspect showed for it, for 3 consecutive polls.
function Wait-OldRunning($Old) {
    $Seen = 0
    for ($Second = 0; $Second -lt 60; $Second++) {
        Start-Sleep -Seconds 1
        $Now = Get-Named $Container
        if ((Test-Running $Now) -and "$(Get-Images $Now)" -ceq "$(Get-Images $Old)") {
            if (++$Seen -ge 3) { return $true }
        } else { $Seen = 0 }
    }
    return $false
}

# Back to the kept rent: stop the candidate (and remove it only when it is a failed Stage's), start the old rent,
# and prove it Running on its own images. No -f, no -v; this function touches no volume (a token Stage placed stays).
# Every step is appended to $Steps.
function Invoke-Revert($Old, $Steps, [bool] $RemoveCandidate) {
    $Now = Get-Named $Candidate
    if ($Now) {
        if (-not (Test-Stopped $Now)) {
            & $Wslc stop $Candidate | Out-Host
            $Steps.Add("stop candidate exit $LASTEXITCODE")
        }
        # Whatever stop reported, only a candidate read back as provably stopped lets anything else happen.
        if (-not (Test-Stopped (Get-Named $Candidate))) { $Steps.Add('candidate not provably stopped'); return $false }
        $Steps.Add('candidate provably stopped')
        if ($RemoveCandidate) {
            & $Wslc remove $Candidate | Out-Host
            $Steps.Add("remove candidate exit $LASTEXITCODE")
            if ($LASTEXITCODE -ne 0) { return $false }
        }
    }
    # No return while another writer may run: every container but the kept rent must pass the writer check (a snapshot,
    # not a guarantee against later races). Otherwise nothing more happens and the task stays where it is.
    try { Assert-NoOtherWriter $Container 'restoring' }
    catch { $Steps.Add("$($_.Exception.Message) Not starting $Container"); return $false }
    # The logon task goes back first: the kept rent starts only once no logon can start the candidate.
    try { Set-TaskTarget $Container; $Steps.Add("task starts $Container") }
    catch { $Steps.Add("task not restored ($($_.Exception.Message)); not starting $Container"); return $false }
    & $Wslc start $Container | Out-Host
    $Steps.Add("start old exit $LASTEXITCODE")
    if ($LASTEXITCODE -ne 0) { return $false }
    $Ok = Wait-OldRunning $Old
    $Steps.Add($(if ($Ok) { 'old Running on its images' } else { 'old not Running on its images within 60 s' }))
    return $Ok
}

# Stop the kept rent for Stage. A nonzero exit is judged by readback: still Running means nothing changed; provably
# stopped with no other writer means it is started again and proven back; anything unknown is left alone.
function Invoke-StageStop($Old) {
    & $Wslc stop $Container | Out-Host
    $Code = $LASTEXITCODE
    if ($Code -eq 0) { return }
    try { $Now = Get-Named $Container }
    catch { throw "WSLC stop of $Container failed: $Code; readback failed ($($_.Exception.Message)); not starting anything." }
    if (Test-Running $Now) { throw "WSLC stop of $Container failed: $Code; it is still Running; nothing else changed." }
    if (-not (Test-Stopped $Now)) { throw "WSLC stop of $Container failed: $Code; its state is unknown; not starting anything." }
    $Steps = [System.Collections.Generic.List[string]]::new()
    try {
        Assert-NoOtherWriter $Container 'restoring'
        & $Wslc start $Container | Out-Host
        $Steps.Add("start old exit $LASTEXITCODE")
        $Ok = ($LASTEXITCODE -eq 0) -and (Wait-OldRunning $Old)
    } catch { $Ok = $false; $Steps.Add("error: $($_.Exception.Message)") }
    $Outcome = if ($Ok) { 'succeeded' } else { 'FAILED' }
    throw "WSLC stop of $Container failed: $Code but it stopped | restore ${Outcome}: $($Steps -join '; ')"
}

# Hand the one logon task to the candidate while the kept rent still runs (the candidate does not exist yet, so a logon
# can start nothing), then stop the kept rent and complete Stage. Before the candidate exists, a failure points the task
# back at the kept rent; after, Complete-Stage reverts. The task never starts the kept rent while the candidate may run.
function Invoke-Stage($Old) {
    $Before = $null
    try { Set-TaskTarget $Candidate; Invoke-StageStop $Old }
    catch { $Before = $_.Exception.Message }
    if ($Before) {
        try { Set-TaskTarget $Container; $Back = "task starts $Container" }
        catch { $Back = "task NOT restored: $($_.Exception.Message)" }
        throw "Stage failed before $Candidate existed: $Before | $Back"
    }
    Complete-Stage $Old
}

# Stage after the old rent was stopped (kept, never removed). First the token is placed, while no rent runs. Any result
# but a known exit 0 (another code, a timeout's -1, an exception) leaves the slot and its writer unknown, so Stage halts
# with nothing further: no seed, no candidate, no task restore, no old start, no retry. After a placement exit 0, Stage
# likewise halts on seed exit 3 (the store is not the one checked), an unknown import outcome, or any failure after an
# import that updated the state; any other later failure reverts the runtime and task, and Stage still fails.
function Complete-Stage($Old) {
    try {
        & $Placement @PlaceArgs | Out-Host
        $Placed = if ($LASTEXITCODE -is [int] -and $LASTEXITCODE -eq 0) { $null } else { "exit $LASTEXITCODE" }
    } catch {
        $Placed = 'an exception'
    }
    if ($Placed) {
        throw "Stage halted after placement attempt ($Placed): $Container kept stopped, logon task targets absent $Candidate, slot and writer state UNKNOWN; recovery needs separate authority."
    }
    # After the seed, the selected typed import (if any); an updated state is never handed back to the kept rent, whose
    # compatibility with it is unproven, so any failure after it halts like an unknown outcome. Revert is no credential rollback.
    $script:Halt = $null; $Imported = $null
    try {
        Invoke-Seed
        if ($ImportItems.Count) { $Imported = Invoke-Import }
        & $Wslc @StageArgs | Out-Host
        if ($LASTEXITCODE -ne 0) { throw "WSLC run of $Candidate failed: $LASTEXITCODE" }
        if (Wait-Ready $Candidate) { return }
        throw "$Candidate did not stay Running with '$Proof' and '$Ready'."
    } catch {
        $Failure = $_.Exception.Message
    }
    if ($script:Halt -or $Imported -ceq 'updated') {
        $Why = if ($script:Halt) { $script:Halt } else { 'the import updated the state' }
        throw "Stage halted: $Failure | $Why; $Container kept stopped, $Candidate left as found, logon task not restored, state UNKNOWN; recovery needs separate authority."
    }
    $Steps = [System.Collections.Generic.List[string]]::new()
    try { $Ok = Invoke-Revert $Old $Steps $true } catch { $Ok = $false; $Steps.Add("error: $($_.Exception.Message)") }
    $Outcome = if ($Ok) { 'succeeded' } else { 'FAILED' }
    throw "Stage failed: $Failure | revert ${Outcome}: $($Steps -join '; ')"
}

if ($Step -eq 'Revert') {
    $Old = Get-Named $Container
    if (-not $Old -or -not (Get-Images $Old)) { throw "Kept rent $Container is missing or has no readable image." }
    if (-not (Get-Named $Candidate)) { throw "Candidate $Candidate is missing; nothing to revert." }
    $Target = Get-TaskTarget
    if ($Target -cne $Candidate -and $Target -cne $Container) { throw "Logon task $TaskName starts '$Target', neither $Candidate nor $Container; not reverting." }
    # Every container but the candidate must pass the writer check, so the kept rent, which mounts every rent volume, must be stopped.
    Assert-NoOtherWriter $Candidate 'reverting'
    $Steps = [System.Collections.Generic.List[string]]::new()
    try { $Ok = Invoke-Revert $Old $Steps $false } catch { $Ok = $false; $Steps.Add("error: $($_.Exception.Message)") }
    if (-not $Ok) { throw "Revert FAILED: $($Steps -join '; ')" }
    Write-Output "Revert succeeded: $($Steps -join '; ')"
    exit 0
}

if ($Step -eq 'Migrate') {
    Assert-OldSourceStopped
    # The kept rent, when it exists, is pinned as inspected now (no recorded image) and must stay provably stopped.
    $Kept = Get-Container $Container
    if ($Kept -and -not (Test-Stopped $Kept)) { throw "Container $Container is not provably stopped; not migrating." }
    Assert-NoOtherWriter $Container 'migrating' @($StateVolume, $OldHomeVolume) @($StateVolume)
    Assert-Volume $OldHomeVolume
} else {
    # Create and Stage: repos must already exist (never create an empty one).
    Assert-Volume $ReposVolume
    if ($Step -eq 'Stage') {
        # The kept rent and its images come from inspect now; nothing is taken from a recorded digest.
        $Old = Get-Named $Container
        $Problem = Get-StageProblem $Old (Get-Named $Candidate)
        if ($Problem) { throw $Problem }
        $Target = Get-TaskTarget
        if ($Target -cne $Container) { throw "Logon task $TaskName must start exactly $Container before staging; it starts '$Target'. Nothing changed." }
        Assert-NoOtherWriter $Container 'staging'
        Assert-Volume $StateVolume
    }
}

# Every written volume is read back in this invocation; only a truly absent state or nix volume is created, then read back.
Assert-Volume $StateVolume -Create:($Step -ne 'Stage')
if ($Step -ne 'Migrate') { Assert-Volume $NixVolume -Create }

if ($Step -eq 'Migrate') {
    # Recheck right before the helper; one-shot helper removed by --rm; nothing is deleted from the old home.
    # The helper itself proves /old and the state mount from its own mountinfo before importing.
    Assert-Volume $StateVolume
    Assert-OldSourceStopped
    $Now = Get-Container $Container
    if ([bool] $Now -ne [bool] $Kept -or ($Now -and ([string] $Now.Id -cne [string] $Kept.Id -or "$(Get-Images $Now)" -cne "$(Get-Images $Kept)" -or
            -not (Test-Stopped $Now)))) { throw "Container $Container changed before the import; not migrating." }
    Assert-NoOtherWriter $Container 'migrating' @($StateVolume, $OldHomeVolume) @($StateVolume)
    & $Wslc @MigrateArgs
    switch ($LASTEXITCODE) {
        0 { Write-Output 'Migrate: every selected item already equal; nothing written.' }
        { $_ -in 10, 11 } { Write-Output "Migrate: selected differing items updated; each original kept as its .prior (exit $LASTEXITCODE)." }
        default { throw "WSLC migrate helper exit $LASTEXITCODE (20 refused with no target changed, 21 restored, else UNKNOWN)." }
    }
    exit 0
}

if ($Step -eq 'Stage') {
    Invoke-Stage $Old
    Write-Output "Stage succeeded: $Candidate ready and the logon task starts it; $Container kept stopped. Revert returns only the runtime and logon task to $Container, not the placed token or imported state; whether $Container suits the current state is not established here."
} else {
    Invoke-Seed
    & $Wslc @RunArgs
    if ($LASTEXITCODE -ne 0) { throw "WSLC run of $Container failed: $LASTEXITCODE" }
    if (-not (Wait-Ready $Container)) { throw "WSLC run of $Container failed its ready gate." }
    Write-Output $Proof
}
exit 0
