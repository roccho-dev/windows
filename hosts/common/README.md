# Common selection → Windows recovery

Issue #7 implementation slice. `nix.nix` is the only authority for selections,
pins and package locks; `win.ps1` is a small native Windows activation adapter
that realizes them. No DSC backend, WinGet catalog, per-product installer, or new
top-level directory is used. (The DSC `Microsoft.Windows/Registry` resource is a
proof-of-concept example that Microsoft says not to use in production, so the
bundled DSC backend and its generated document were removed.)

```text
flake.lock + common/nix.nix
  ├─ common-fonts          selected TTF bytes and licenses, reusable by Linux
  └─ windows-dist.zip     fonts + pinned noctty + cloudflared + locked package metadata
       └─ win.ps1         verify → classify → owned effects through the effect ledger
```

## Build and use

```sh
nix flake check --no-write-lock-file
nix build .#windows-dist --no-write-lock-file
# result/windows-dist.zip and result/windows-dist.zip.sha256
nix build .#common-fonts --no-write-lock-file
# result/share/fonts
```

On a Windows 11 x64 installation with Windows PowerShell 5.1, verify the ZIP
against a checksum from a trusted successful CI/release, extract into a fresh
directory, then run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\win.ps1 -Mode Validate     # read-only
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\win.ps1 -Mode Restore      # fonts, Noctty, packages (see below)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\win.ps1 -Mode RestoreTest  # fail on drift
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\win.ps1 -Mode Uninstall    # dry run: lists what it would revert
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\win.ps1 -Mode Uninstall -Apply  # reverts owned fonts
```

`Restore` converges the selected fonts (owned, through the effect ledger below),
the pinned noctty portable ZIP and its `font-family = PlemolJP Console NF`
configuration, and checks the locked packages (Chromium and AutoHotkey). A
package is `preexisting` whenever an HKCU or HKLM (64- or 32-bit) Uninstall entry
has its declared key name, or its DisplayName and Publisher, wherever that entry
points; it is `preexisting-match` only when DisplayVersion and the ProductVersion
of the entry's own InstallLocation executable equal the lock, and is never
written. Declared protected data (the Chromium `User Data` profile) without an
entry is `preexisting-drift`, never absent. An absent package stops `Restore`
before any download or effect: **clean package install is disabled** until the
ledger covers it. `RestoreTest` fails on any package that is not
`preexisting-match`. Windows Terminal is OS/Store-owned and is not installed or
pinned: `Restore` and `RestoreTest` only assert version 1.24 or newer, because its
OpenConsole is Noctty's console half. The release ZIP can be downloaded again
after a clean install; Nix is only needed to build it, not to apply it.

After installing the dependencies, `Restore` selects the Windows Terminal 1.24+
OpenConsole console delegate and calls Noctty's `+register-default-terminal` for
the current user. `Restore` then checks the registration, one COM activation,
and the delegate pair as read from inside the Windows Terminal package (below);
any failure restores the previous delegate selection and fails `Restore`.
`RestoreTest` checks registry state (delegate pair, COM class and proxy DLL
mappings) and the same package-context pair, and fails if that pair differs or
cannot be read; it writes no registry value. It does not start the Noctty COM
server or open a window, but it starts a Windows PowerShell reader under a
headless `conhost.exe` inside the Windows Terminal package (below). Every mode reports `registrationState`
(`registered` or `unregistered`) and `handoffProof = "unproven"`:
registration and COM activation are not evidence that a new console opens in
Noctty, and `inDesiredState` never includes handoff. Windows Terminal remains installed
as the OpenConsole dependency; removing it would break this default-terminal
handoff. The generated state is reapplied after a clean install rather than
backing up old registry data.

**Run `Restore`, `RestoreTest` and the handoff proof from an unelevated shell
launched from Explorer (Start menu) as the user being restored.** `Restore`
refuses an elevated token. A process inside another app's registry silo, such
as an agent sandbox, can read and write a local `HKCU` that the rest of the
system never sees: on the development host, ETW showed such a shell's
`DelegationTerminal` write land in `\REGISTRY\WC\Silo…` while the Windows
Terminal package read the durable `\REGISTRY\USER\<SID>` hive. The
package-context pair check makes `Restore`/`RestoreTest` fail rather than report
success there. It covers only `%%Startup`, the key OpenConsole reads; COM keys,
Noctty files, fonts and the Noctty config written from such a shell may also be
virtualized, which only the host handoff proof (for COM and `noctty.exe`) and
later typography evidence can show. If `%%Startup` was already correct, a match
does not prove this run's file and font writes reached the real user profile.
The package-context reader needs Windows
PowerShell 5.1 (Appx module for `Invoke-CommandInDesktopPackage`) and Windows
Terminal; it does not use Windows Script Host, which on the development host
had no `.js` script engine.
`Apply` and `Test` are font-only CI proof modes and do not run this check.

**Run `Restore`, `Apply` and `Uninstall` as the same user.** The effect ledger
lives in that user's `%LOCALAPPDATA%`; another account (for example an elevated
token of a different administrator) reads a different or no ledger and would
see nothing owned. `Uninstall` reports its `identity` (SID, profile, elevated)
and `ledgerFound`, and claims an empty owned range only when the ledger was
found. Inside an app's registry silo the ledger and the font values may be
virtualized too; font `Uninstall` performs no silo check (`siloCheck =
"notPerformed"`), so its claim covers only what that process sees.

Before its first change to `HKCU\Console\%%Startup`, `Restore` writes the prior
`DelegationConsole`/`DelegationTerminal` values once to
`LocalApplicationData\windows-iac\provenance\default-terminal.json`. The record
is never replaced; an unreadable record fails `Restore`, and
`priorSelectsNoctty = true` marks a record taken when Noctty was already
selected, whose true original is unknown. **Rollback from this record is not
implemented yet**: no mode reads it, and Noctty's `+unregister-default-terminal`
effect on COM/Interface keys is unverified. Until then, restore the recorded
pair by hand and keep the record.

### Default-terminal handoff proof (host only)

`handoff-proof.ps1` is the only producer of `handoffProof = "proven"`. It
refuses to run on CI runners or elevated, never changes the registration, and
writes each evidence file once, refusing to overwrite it. Launch no other
console during a trace. Its verdict rule lives in `handoff-evaluate.ps1`, which
has no effects; `proof.ps1` checks each verdict there with synthetic evidence,
and those synthetic cases are not an observed handoff.

```powershell
# elevated shell: record the console host provider
logman start noctty-handoff -p "{fe1ff234-1f09-50a8-d38d-c44fab43e818}" 0xffffffffffffffff 5 -o "$env:TEMP\noctty-handoff.etl" -ets
# unelevated shell: RestoreTest, then one probe console (or -Launcher Manual for Win+R)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\handoff-proof.ps1 -Phase Probe -Launcher ShellExecute
# elevated shell
logman stop noctty-handoff -ets
# unelevated shell: combine the probe record with the stopped trace
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\handoff-proof.ps1 -Phase Finalize -Evidence <probe.json> -TraceFile "$env:TEMP\noctty-handoff.etl"
```

Before launching, the probe also reads the `%%Startup` pair from inside the
Windows Terminal package (`package-view.ps1`, shared with `win.ps1`:
`Invoke-CommandInDesktopPackage` running `conhost.exe --headless` hosting a
generated Windows PowerShell 5.1 script with `-NoProfile -NonInteractive`; the
script only reads the registry, and `-ExecutionPolicy Bypass` applies to that
process alone). The explicit headless conhost is the reader's own console
server: on the development host a Console.Host ETW trace of this launch had no
`ConsoleHandoffSessionStarted`, `SrvInit_ReceiveHandoff` or
`DelegateToTerminalSucceeded`, while launching `powershell.exe -WindowStyle
Hidden` directly was handed off to Windows Terminal. The reader therefore opens
no window and adds no handoff to the probe's trace. This relies on Windows'
`conhost.exe --headless` behavior; if it changes, the comparison fails closed.
PowerShell itself may write startup caches inside the Windows Terminal package.
Its script and answer live in a new `%USERPROFILE%\noctty-package-view-<guid>`
directory, outside AppData (which the package may redirect), OneDrive and the
bundle. The probe waits up to `-TimeoutSeconds` for the answer and then up to
`-TimeoutSeconds` more for any `conhost.exe` or `powershell.exe` whose command
line names that directory to exit, so it can take twice the timeout. It then deletes only its
known files and the empty directory, never recursively, and records the scratch
path and cleanup result; a still-running reader leaves the directory in
place. Waiting assumes WMI reports the packaged reader's command line
(unverified); if not, a late writer can only make the non-recursive delete fail
and be recorded as `kept`. With no answer, the record notes that a reader may
still start later; it then finds no directory and cannot write.
OpenConsole runs in that package, which reads the durable user hive; a
differing pair means this process's own HKCU is probably virtualized (see
above). HKCU is read before and after the package view; a change in between
makes the comparison `unproven`. The comparison
(`Compare-TerminalSelection` in `handoff-evaluate.ps1`) treats a valid,
differing package pair as `failed`, and no, late, or malformed answer as
`unproven`. The probe repairs nothing. It records the local time zone,
which `Finalize` uses to read tracerpt's wall clock. It then starts `cmd.exe` titled with a random
nonce and records which process owns the window carrying that title, and any
new `WindowsTerminal.exe` host.
`Finalize` decodes the stopped trace with `tracerpt` and reads the single
`SrvInit_ReceiveHandoff` `TerminalClsid` in the probe's time window. tracerpt
prints `TimeCreated` as the local wall clock with an untrustworthy numeric
offset (seen: `+08:59` in Asia/Tokyo), so such stamps are read as local time;
`Z` stamps are UTC and stamps with neither are unparseable. The result
is `proven` only when the window belongs to this distribution's portable
`noctty.exe`, no new Windows Terminal host started, and that CLSID is Noctty's
`{33368C6F-D328-410C-B225-26DC9F12C728}`. Contrary evidence is `failed`; missing
or ambiguous evidence (no window, no or several events, untraceable provider) is
`unproven`. Acceptance repeats this three times each with `ShellExecute` and
`Manual` (Win+R), and again after a coordinated reboot. As supporting evidence
only, read the real `LocalApplicationData\noctty\config.ghostty` from the same
Explorer-launched shell; its `font-family` belongs to the separate typography
acceptance, not to this handoff verdict.

Chromium does not update itself. Refresh the pinned version in `nix.nix`, build
and prove a new release in CI, then reapply it to receive updates.

### Rent SSH client (#14)

The ZIP also carries the official `cloudflared-windows-amd64.exe` of exactly the
version the rent image runs, pinned by SHA-256 in `nix.nix`. `Restore` does not
install it and never touches SSH configuration. The explicit mode does, with the
live binding that exists only after envs creates the Access hostname and the
rent first generates its host key:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\win.ps1 -Mode RentSsh `
  -Hostname <Access hostname> -HostKey '<ssh-ed25519 key from the rent state volume>' -Identity <private key path>
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\win.ps1 -Mode RentSshTest <same arguments>  # fail on drift
```

It installs the client under `LocalAppData\Programs\cloudflared-<version>`,
writes `%USERPROFILE%\.ssh\windows-rent\{config,known_hosts}` (host `windows-rent`,
`ProxyCommand ... access ssh`, `HostKeyAlias`, `StrictHostKeyChecking yes`), and
makes `Include windows-rent/config` the first line of `%USERPROFILE%\.ssh\config`
so Windows OpenSSH and Codex Remote SSH resolve the alias. The prior bytes of that
file stay below the line and are kept once as `config.before-windows-rent`; it
refuses a byte-order mark, an Include elsewhere, or an existing backup. Access
credentials are never written here.

## Owned fonts and the effect ledger

`Apply` (the CI font-only mode) and `Restore` own the selected content-addressed
TTF files beneath the current user's `LocalApplicationData\Microsoft\Windows\Fonts`
and their `HKCU\Software\Microsoft\Windows NT\CurrentVersion\Fonts` values
`<full name> (TrueType)` (REG_SZ, the file's path), written natively. `Test` and
`RestoreTest` read both back. `Restore` also writes the selected noctty
configuration and default-terminal registration, which are **not** in the ledger
yet (next slice), and does not replace Windows-owned UI fonts or restore old
registry settings, accounts, profiles, or personal app data. The user directory
is a runtime Binding, not common Spec.

Every owned effect is recorded in `%LOCALAPPDATA%\windows-iac\ledger`, one file
per record (`<seq>.json`, created new, written through and flushed) while
`ledger\.lock` is held: an **intent** before the effect (a new font file names its
temporary file there first), then a **commit** with the read-back state; reverting
writes **undone**, and an interrupted intent that never took effect is closed
**void**. Before anything else, each run recovers interrupted attempts from what
it reads: an intent whose effect is present is committed, one whose target is
still absent is voided (deleting only the temporary file that intent named), and
a committed effect found reverted is closed undone. Anything else stops the run.
Only what this code created is owned (the prior state is always absent), so:

- A matching file or value that was already there is `preexisting` and never
  written or removed; one that differs is reported as `Font drift` and left alone.
- Owned drift (changed bytes or value) is repaired by reverting and owning again.
- A value recorded for an older selection is reverted and owned again for the new
  file; owned files no longer selected are collected afterwards (values first).
  A file that any HKCU or HKLM Fonts value still names (by path, or by the same
  bytes under another name) is kept and reported as `gcKeptReferenced`.
- A file Windows has locked (a loaded font) is never deferred or forced: the run
  fails and the file stays owned for the next run.

`Uninstall` without `-Apply` changes nothing and lists the plan. With `-Apply` it
builds the whole plan and a Fonts reference check first; if anything is refused
(owned drift, an unhandled id, a file an unowned value names), nothing is removed.
Otherwise it removes owned values, then owned files, each only while it is still
exactly what was recorded, and closes each undone. It reports `ownedOpen` (0 when
empty), `changedAfterClose` (closed targets that no longer read as their prior;
reported, not a failure), `retained` (the ledger and provenance directories,
which are state rather than effects) and `notInLedger` (Noctty, the
default-terminal record and RentSsh, which it does not touch yet). `Apply` and a
fonts-only `Uninstall` may run elevated on a disposable runner; `Restore` may not.

**Torn record.** A power loss can tear only the highest-seq record, and every mode
that reads the ledger then stops. Remove that one file by hand only if it is the
highest `<seq>.json` **and** does not parse as JSON; then rerun, and recovery
closes the attempt from the machine's state. A record that parses but is invalid
is never removed: stop and investigate.
**Stale lock.** A power loss can also leave `ledger\.lock`, and every writer then stops with "Another run holds the effect ledger lock"; delete that one file by hand only when no `win.ps1` (`powershell.exe`) process is running.

**#14 (RentSsh).** The ledger owns only what it created (prior absent). A
`prefix-inserted` or `file-replaced` effect cannot be moved to a new version by
undo-then-rewrite, because the restored prior classifies as `preexisting-*`; #14
must define an explicit transition record first.

The ZIP checksum binds transported bytes. The embedded inventory detects
post-extraction corruption, not publisher authenticity. The manifest records
the source commit; the Windows proof requires the expected exact commit.

## Failure and restoration

A failed apply can leave partial state and an open ledger attempt; rerun the same
artifact and recovery converges it. Corrupt registered/in-use font files may be
locked by Windows and make the run fail; this adapter does not stop OS services
or reboot to unlock them. New font versions use new content-addressed filenames,
avoiding in-place updates.

## Proof boundaries

`test_pack.py` covers compiler metadata, license retention, deterministic ZIPs,
hash inventories, and empty/duplicate/unsafe-input rejection using synthetic
fixtures. It is not native Windows evidence.

`proof.ps1` runs only on disposable GitHub-hosted Windows runners. It requires
exact source identity; checks the pure ledger classification for every kind;
applies twice with one intent and one commit per owned file and value and zero
changes on the second apply; independently reads the files and values back from
`manifest.fonts`; repairs owned value and byte drift and refuses unowned drift;
rejects package corruption; replays interrupted attempts (void, commit, undone,
temporary files an intent named, a temporary file none named, a second writer, a
torn record); keeps files a foreign value names; moves an owned value to a new
selection and collects the old file; and uninstalls (dry run unchanged, locked
file kept owned, then empty, then a no-op). It also requires every `win.ps1` answer to report
`handoffProof = "unproven"` and `handoff-proof.ps1` to refuse the runner, so CI
never claims a real default-terminal handoff. Negative controls must fail for
their expected reason.

The workflow builds, transports, invokes target-owned proof, and gates release.
Actions are commit-pinned. Windows proof and publication, which runs only for
pushes to the trusted default branch `proposals`, consume the same artifact ID
and ZIP checksum; publication never rebuilds. PRs cannot publish.

## Remaining acceptance

This is **not the whole of #7**. Existing own/rent image workflows remain; their
proven target-owned smoke tests and publication still need composition into the
final single `ci.yml` with the open OCI stack. Do not discard existing proof to
claim one workflow prematurely. Existing OCI definitions and #8 are unchanged.

`%LOCALAPPDATA%\windows-iac\provenance\default-terminal.json` is new per-user
state written by `Restore`; no current uninstall or rollback path removes it.
`Uninstall` reverts owned fonts only: Noctty, its configuration and shortcut,
the default-terminal registration and COM values, and clean package installs
join the ledger in later slices, so `Restore`/`Uninstall` as a whole is not
complete.

Application/UI selection beyond noctty, Japanese/Nerd/Emoji rendering,
font reload/relogin, Linux profile activation, and real-host
Spec + Binding → Runtime → Proof/restoration remain unproven. Installing a font
does not prove an application uses it. Native `nix.exe` is not a prerequisite.

Hosted CI success does not authorize dependency merges, issue closure, or real-PC
changes. Keep #7 open until its remaining acceptance is demonstrated.
