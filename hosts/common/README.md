# Common selection → Windows recovery

Issue #7 implementation slice. `nix.nix` owns selections and pins; generated
DSC configuration is not a second editable Spec. No custom DSC resource,
WinGet catalog, per-product installer, or new top-level directory is added.

```text
flake.lock + common/nix.nix
  ├─ common-fonts          selected TTF bytes and licenses, reusable by Linux
  └─ windows-dist.zip     fonts + pinned noctty + pinned DSC + generated configs
       └─ win.ps1         verify → realize files → DSC convergence
```

## Build and use

```sh
nix flake check --no-write-lock-file
nix build .#windows-dist --no-write-lock-file
# result/windows-dist.zip and result/windows-dist.zip.sha256
nix build .#common-fonts --no-write-lock-file
# result/share/fonts
```

On a clean Windows 11 x64 installation with Windows PowerShell 5.1 and WinGet,
verify the ZIP against a checksum from a
trusted successful CI/release, extract into a fresh directory, then run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\win.ps1 -Mode Validate     # read-only
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\win.ps1 -Mode Restore      # fonts, Noctty, and two packages
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\win.ps1 -Mode RestoreTest  # fail on drift
```

`Restore` converges the selected fonts, the pinned noctty portable ZIP and its
`font-family = PlemolJP Console NF` configuration, and the pinned WinGet package
IDs/versions for Chromium and AutoHotkey. The
selected Chromium WinGet manifest offers a current-user installer. The machine
needs a network connection and a working WinGet source for those two packages;
they are not redistributed in the ZIP. Windows Terminal is OS/Store-owned and is
not installed or pinned: `Restore` and `RestoreTest` only assert version 1.24 or
newer, because its OpenConsole is Noctty's console half. Noctty is included because its WinGet
package is not published. The release ZIP can be downloaded again after a clean install; Nix
is only needed to build it, not to apply it.

After installing the dependencies, `Restore` selects the Windows Terminal 1.24+
OpenConsole console delegate and calls Noctty's `+register-default-terminal` for
the current user. `Restore` then checks the registration and one COM activation;
a failure restores the previous delegate selection and fails `Restore`.
`RestoreTest` checks only registry state (delegate pair, COM class and proxy DLL
mappings) for the default terminal; it does not launch a console or the Noctty
COM server, though it still runs the DSC and WinGet resource tests. Every mode reports `registrationState`
(`registered` or `unregistered`) and `handoffProof = "unproven"`:
registration and COM activation are not evidence that a new console opens in
Noctty, and `inDesiredState` never includes handoff. Windows Terminal remains installed
as the OpenConsole dependency; removing it would break this default-terminal
handoff. The generated state is reapplied after a clean install rather than
backing up old registry data.

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
Windows Terminal package (`Invoke-CommandInDesktopPackage` running a
`wscript.exe` script, which creates no console; the script only reads the
registry, though side effects of Windows Script Host itself are not ruled out).
Its script and answer live in a new `%USERPROFILE%\noctty-package-view-<guid>`
directory, outside AppData (which the package may redirect), OneDrive and the
bundle. The probe waits up to `-TimeoutSeconds` for the answer and then up to
`-TimeoutSeconds` more for any `wscript.exe` whose command line names that
directory to exit, so it can take twice the timeout. It then deletes only its
known files and the empty directory, never recursively, and records the scratch
path and cleanup result; a still-running script host leaves the directory in
place. Waiting assumes WMI reports the packaged `wscript.exe` command line
(unverified); if not, a late writer can only make the non-recursive delete fail
and be recorded as `kept`. With no answer, the record notes that a script host
may still start later; it then finds no directory and cannot write.
OpenConsole runs in that package, and a process there has been observed to read
a different pair than HKCU shows; where that package value comes from is
unverified. HKCU is read before and after the package view; a change in between
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
`Manual` (Win+R), and again after a coordinated reboot.

Chromium does not update itself. Refresh the pinned version in `nix.nix`, build
and prove a new release in CI, then reapply it to receive updates.

`Apply` and `Test` retain their font-only meaning for the CI proof. They own
selected content-addressed TTF files beneath the current user's
`LocalApplicationData\Microsoft\Windows\Fonts` and corresponding HKCU font
registrations. `Restore` also writes the selected noctty configuration and
default-terminal registration, but
does not replace Windows-owned UI fonts or restore old registry settings,
accounts, profiles, or personal app data. The user directory is a runtime Binding, not common Spec.
Each invocation puts the bundled backend first on `PATH` and in
`DSC_RESOURCE_PATH`, but discovery is not confined to the bundle: the
`Microsoft.WinGet/Package` resource is not bundled and is resolved from the
machine's App Installer/WinGet installation.

The ZIP checksum binds transported bytes. The embedded inventory detects
post-extraction corruption, not publisher authenticity. The manifest records
the source commit; the Windows proof requires the expected exact commit.

## Failure and restoration

A failed apply can leave partial state. Rerun the same artifact to converge,
but corrupt registered/in-use font files may be locked by Windows and cause
Apply to fail. This adapter does not stop OS services or reboot to unlock them.
New font versions use new content-addressed filenames, avoiding in-place updates.

Reapplying a prior artifact restores registrations for names it owns. This is
**not transactional rollback or garbage collection**: removed family names and
old content-addressed files are deliberately not deleted.

## Proof boundaries

`test_pack.py` covers compiler metadata, license retention, deterministic ZIPs,
hash inventories, and empty/duplicate/unsafe-input rejection using synthetic
fixtures. It is not native Windows evidence.

`proof.ps1` runs only on disposable GitHub-hosted Windows runners. It requires
exact source identity, repairs damaged bytes seeded before registration,
applies twice with zero changes on the second apply, independently reads actual
registry values, rejects and repairs registry drift, and rejects package
corruption. It also requires every `win.ps1` answer to report
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

Application/UI selection beyond noctty, Japanese/Nerd/Emoji rendering,
font reload/relogin, Linux profile activation, and real-host
Spec + Binding → Runtime → Proof/restoration remain unproven. Installing a font
does not prove an application uses it. Native `nix.exe` is not a prerequisite.

Hosted CI success does not authorize dependency merges, issue closure, or real-PC
changes. Keep #7 open until its remaining acceptance is demonstrated.
