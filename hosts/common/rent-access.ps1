#requires -Version 5.1
# The windows-rent ProxyCommand (#14), installed by win.ps1 -Mode RentSsh beside the pinned cloudflared.exe:
#   "<System32>\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -NonInteractive -File "<this file>" %h
# It reads the owner-only Access client slot that only win.ps1 -Mode RentAccess writes, refuses before any child
# unless the slot is exactly its last host-ledger commit and still owner-only, then starts that cloudflared.exe with
# exactly 'access ssh --hostname <host>' and the two TUNNEL_SERVICE_TOKEN_* values in the child's environment alone.
# The child inherits this process's standard handles, so SSH bytes never pass through PowerShell. This script writes
# nothing to stdout; a refusal is one fixed line on stderr, never a value. Paths come from the USERPROFILE and
# LOCALAPPDATA that ssh inherits from the user's session. A provider rejection or Access login is cloudflared's own.
param([Parameter(Mandatory)][string]$Hostname)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
function Refuse([string]$Reason) {
    [Console]::Error.WriteLine("rent-access: $Reason; cloudflared not started.")
    exit 2
}
function PlainFile([string]$Path) {
    # No reparse point anywhere on the path, and the leaf is a regular file.
    $current = $Path
    while ($current) {
        $item = Get-Item -LiteralPath $current -Force -ErrorAction SilentlyContinue
        if ($item -and ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { return $false }
        if ($current -eq $Path -and (-not $item -or $item.PSIsContainer)) { return $false }
        $parent = [IO.Path]::GetDirectoryName($current.TrimEnd('\'))
        if ($parent -eq $current) { break }; $current = $parent
    }
    return $true
}
$secret = $null
try {
    if ($Hostname -cnotmatch '^(?=.{1,253}$)[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+\z') { Refuse 'the Access hostname is invalid' }
    if (-not $env:USERPROFILE -or -not $env:LOCALAPPDATA -or -not [IO.Path]::IsPathRooted($env:USERPROFILE) -or -not [IO.Path]::IsPathRooted($env:LOCALAPPDATA)) { Refuse 'the user profile paths are unavailable' }
    $client = Join-Path $PSScriptRoot 'cloudflared.exe'
    $slot = [IO.Path]::GetFullPath((Join-Path $env:USERPROFILE '.ssh\windows-rent\access'))
    if (-not (PlainFile $client)) { Refuse 'the pinned client is absent or not a plain file' }
    if (-not (PlainFile $slot)) { Refuse 'the Access credential slot is absent or not a plain file' }
    if (@(Get-ChildItem -LiteralPath (Split-Path -Parent $slot) -Force | Where-Object { $_.Name.StartsWith('access.', [StringComparison]::OrdinalIgnoreCase) }).Count) { Refuse 'an Access slot temporary file is present' }
    $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User
    # .NET directly, never Get-Acl: a Windows PowerShell started from PowerShell 7 inherits a PSModulePath whose
    # Microsoft.PowerShell.Security it cannot load.
    $security = [IO.File]::GetAccessControl($slot, [Security.AccessControl.AccessControlSections]'Owner, Access')
    $rules = @($security.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]))
    if ($security.GetOwner([Security.Principal.SecurityIdentifier]) -ne $sid -or -not $security.AreAccessRulesProtected -or $rules.Count -ne 1 -or
        $rules[0].IsInherited -or $rules[0].IdentityReference -ne $sid -or $rules[0].AccessControlType -ne [Security.AccessControl.AccessControlType]::Allow -or
        $rules[0].FileSystemRights -ne [Security.AccessControl.FileSystemRights]::FullControl) { Refuse 'the Access credential slot is not owner-only' }
    $bytes = [IO.File]::ReadAllBytes($slot)
    $text = [Text.Encoding]::GetEncoding(28591).GetString($bytes)
    if ($bytes.Length -lt 4 -or $bytes.Length -gt 2050 -or $text -cnotmatch '^([!-~]{1,1024})\n([!-~]{1,1024})\n\z') { Refuse 'the Access credential slot is malformed' }
    $id, $secret = $Matches[1], $Matches[2]
    $hash = [Security.Cryptography.SHA256]::Create()
    try { $sha = -join ($hash.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') }) } finally { $hash.Dispose() }
    [Array]::Clear($bytes, 0, $bytes.Length)
    # The slot must be exactly the latest record of its host-ledger id, a commit: a foreign, drifted, half-rotated or
    # undone slot is refused. The integrity value is compared here and never printed.
    $ledger, $key, $latest = (Join-Path $env:LOCALAPPDATA 'windows-iac\ledger'), ('file-created:' + $slot.ToUpperInvariant()), $null
    if (Test-Path -LiteralPath $ledger -PathType Container) {
        foreach ($item in @(Get-ChildItem -LiteralPath $ledger -Force -File | Where-Object { $_.Name -cmatch '^[0-9]{8}\.json$' })) {
            $json = [IO.File]::ReadAllText($item.FullName)
            if (-not $json.Contains('WINDOWS-RENT')) { continue }
            $record = $json | ConvertFrom-Json
            if ([string]$record.id -cne $key) { continue }
            if ($null -eq $latest -or [long]$record.seq -gt [long]$latest.seq) { $latest = $record }
        }
    }
    if ($null -eq $latest -or [string]$latest.phase -cne 'commit' -or [string]$latest.target -ne $slot -or
        [string]$latest.desired.sha256 -cne $sha -or [string]$latest.observed.sha256 -cne $sha) { Refuse 'the Access credential slot is not its owned committed value' }
    $info = [Diagnostics.ProcessStartInfo]::new($client, ('access ssh --hostname ' + $Hostname))
    $info.UseShellExecute = $false
    foreach ($name in @($info.EnvironmentVariables.Keys | ForEach-Object { [string]$_ } | Where-Object { $_.StartsWith('TUNNEL_', [StringComparison]::OrdinalIgnoreCase) })) {
        $info.EnvironmentVariables.Remove($name)
    }
    $info.EnvironmentVariables['TUNNEL_SERVICE_TOKEN_ID'] = $id
    $info.EnvironmentVariables['TUNNEL_SERVICE_TOKEN_SECRET'] = $secret
    $secret, $id, $text, $Matches = $null, $null, $null, $null
    $child = [Diagnostics.Process]::Start($info)
    $info.EnvironmentVariables.Remove('TUNNEL_SERVICE_TOKEN_SECRET')
    $child.WaitForExit()
    exit $child.ExitCode
} catch {
    Refuse 'an unexpected failure occurred'
}
