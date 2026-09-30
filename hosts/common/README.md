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
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\win.ps1 -Mode Restore      # fonts, UI font faces, Noctty, packages, Store apps (see below)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\win.ps1 -Mode Apply -Typography  # fonts, UI font faces, a present app's fonts
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\win.ps1 -Mode RestoreTest  # fail on drift
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\win.ps1 -Mode Uninstall    # dry run: lists what it would revert
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\win.ps1 -Mode Uninstall -Apply  # reverts owned fonts and Noctty, restores the selection
```

`Restore` converges the selected fonts and the pinned noctty portable ZIP, its
`font-family = PlemolJP Console NF` configuration and its default-terminal
registration (all owned through the effect ledger below), and the locked packages
(Chromium and AutoHotkey; see "Locked packages" below). Windows Terminal is OS/Store-owned and is not installed or
pinned: `Restore` and `RestoreTest` only assert version 1.24 or newer, because its
OpenConsole is Noctty's console half. The release ZIP can be downloaded again
after a clean install; Nix is only needed to build it, not to apply it.

`Restore` registers Noctty natively; it never runs Noctty's own
`+register-default-terminal` (only the CI measurement below does). It owns the
six COM values and the keys it creates (see "Owned Noctty" below), then writes
`HKCU\Console\%%Startup` `DelegationConsole` (the Windows Terminal 1.24+
OpenConsole) and `DelegationTerminal` (Noctty), each only when it differs. It then
checks the registration, one COM activation, and the delegate pair as read from
inside the Windows Terminal package (below); if any of that fails after a write,
only the values this run wrote go back to what this run found just before (not to
the older prior in the record below, which is `Uninstall`'s), and only while they
still hold what it wrote; then `Restore` fails.
`RestoreTest` checks registry state (delegate pair and the six COM values) and
the same package-context pair, and fails if that pair differs or
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
`Apply` (the CI proof mode) converges the same fonts, Noctty and selection as
`Restore` without packages, the Windows Terminal version, COM activation and this
check; `Test` checks fonts only.

**Run `Restore`, `Apply` and `Uninstall` as the same user.** The effect ledger
lives in that user's `%LOCALAPPDATA%`; another account (for example an elevated
token of a different administrator) reads a different or no ledger and would
see nothing owned. `Uninstall` reports its `identity` (SID, profile, elevated)
and `ledgerFound`, and claims an empty owned range only when the ledger was
found. Inside an app's registry silo the ledger and the font values may be
virtualized too; font `Uninstall` performs no silo check (`siloCheck =
"notPerformed"`), so its claim covers only what that process sees.

Before its first change to `HKCU\Console\%%Startup`, `Apply`/`Restore` writes the
prior `DelegationConsole`/`DelegationTerminal` values once to
`LocalApplicationData\windows-iac\provenance\default-terminal.json`. The record
is never replaced; an unreadable record stops `Apply`/`Restore` before any effect,
and `priorSelectsNoctty = true` marks a record taken when Noctty was already
selected, whose true original is unknown. `Uninstall -Apply` restores from it only
values that still hold what was written,
`DelegationTerminal` first, so a half-restored pair resumes; a value changed by
anyone else, or an unknown original, is refused and never guessed. The record is
kept afterwards.

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

`Apply` (the CI proof mode) and `Restore` own the selected content-addressed
TTF files beneath the current user's `LocalApplicationData\Microsoft\Windows\Fonts`
and their `HKCU\Software\Microsoft\Windows NT\CurrentVersion\Fonts` values
`<full name> (TrueType)` (REG_SZ, the file's path), written natively. `Test` and
`RestoreTest` read both back. The same ledger owns Noctty (below). Nothing here
replaces Windows-owned UI fonts or restores old registry settings, accounts,
profiles, or personal app data. The user directory is a runtime Binding, not
common Spec.

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

### Owned Noctty

`Apply`/`Restore` classify every Noctty effect before the first effect of the
run, then (after fonts) create only what is absent, in this order:

1. the tree `%LOCALAPPDATA%\Programs\noctty-<version>`, extracted from the bundled
   ZIP only after every entry name is checked against the pinned inventory, into
   a staging directory its intent names, compared exactly, then renamed;
2. `%LOCALAPPDATA%\noctty\config.ghostty` (`font-family = …`);
3. the `HKCU\Console\%%Startup` key, if missing;
4. the COM keys derived from the six values in `nix.nix` (below
   `Software\Classes\CLSID\{…}` and `…\Interface\{…}`, parents first; an existing
   key is never owned, and the shared `CLSID`/`Interface` roots never are), then
   the six REG_SZ values; then the selection above.

Shared parents they need (`Programs`, `%LOCALAPPDATA%\noctty`, the two roots)
are created as needed, listed in `sharedCreated`, and never removed. No Start-menu
shortcut is created; an existing one is untouched. The run stops before any
effect on: a machine-wide Noctty (either CLSID in HKLM, or an HKLM Uninstall
entry naming it); a tree that differs from the inventory, owned or not (an extra,
missing or changed file, a junction, an empty directory), which is never
overwritten; or a COM registration that is neither entirely present and exact
(then nothing is written for it) nor entirely absent or owned (**K-rule**: one
foreign or differing value, or a mix, refuses), or, when the registration will be
written, an existing COM key holding any value or subkey other than the declared
ones (an existing empty key is fine, and never owned). An unrecorded tree or value that
exactly matches is `preexisting-match`: left alone and never owned (A2), so an
exact pre-ledger Noctty (as on the development host) is not written. A differing
configuration is reported as `Noctty drift` and never written. Version drift (a
registration naming another version's tree) is a differing value: it refuses.
If a running Noctty ever writes into its own tree, that tree reads as drift and
`RestoreTest` fails for that site; this is recorded, not hidden (unmeasured: G3).
After a version change, the older version's owned tree stays until `Uninstall`,
which removes it too; `Apply`/`Restore` do not collect it. In `Restore`, package
installation (disabled until S-A2) comes after this plan, so no package changes
before a Noctty refusal.

The vendor registration also writes bookkeeping keys (`…\{Noctty}\noctty.default-terminal`
with `Present = 0` markers) and two CLSID description strings. They are **not**
written here, on the reading that COM never reads them; this stays conditional on
the VM proof below.

`Uninstall` without `-Apply` changes nothing and lists the plan. With `-Apply` it
plans everything first; if anything is refused (owned drift other than a partly
removed tree, an unhandled id, a file an unowned Fonts value names, a created key
holding a value or subkey the plan does not remove (**A3**), an unowned COM
server path naming an owned tree, or, while owned COM values would go, a
selection record that cannot restore or would leave Noctty selected), nothing is
removed. Otherwise it restores the selection (above), reads it again and stops if
Noctty is still selected, then removes owned values, created keys (deepest first,
only while empty), owned files, and last owned trees (file by file, then empty
directories, never recursively), checking the COM guard again just before. A tree
left partly removed (a crash, or a file locked by a running `noctty.exe`) is
resumed by the next `Uninstall` (`resumed`). A key someone else writes into
between the check and its removal would lose that value with it (a small window;
A3 refuses it at plan time). It reports `ownedOpen` (0 when empty),
`changedAfterClose` (closed targets that no longer read as their prior; reported,
not a failure), `defaultTerminal` (the rollback action), `retained` (the ledger
and provenance directories, which are state rather than effects) and
`notInLedger` (an existing shortcut, the default-terminal record and RentSsh).
`Apply` and `Uninstall` may run elevated on a disposable runner; `Restore` may not.

### Locked packages

`Restore` covers every lock in `nix.nix`; `Apply` covers only those named by
`-Mode Apply -Packages AutoHotkey,Chromium` (exact lock names) and none otherwise.
After recovery and before any effect, each package is classified: the effect
ledger decides ownership of its tree `%LOCALAPPDATA%\Programs\<name>-<version>`
(one `tree-extracted` effect whose intent names the package); an HKCU or HKLM
(64- or 32-bit) Uninstall entry with its declared key, or DisplayName and
Publisher, is never taken over (`preexisting-match` when DisplayVersion and the
ProductVersion of that entry's own executable equal the lock, else
`preexisting-drift`), and beside an owned tree it is a conflict, reported as drift;
an unrecorded tree is `preexisting-match` only when it is exactly the pinned
inventory; declared protected data (the Chromium `User Data` profile) is someone
else's, `preexisting-drift`, unless the ledger shows this package was once
installed and committed here (R1). Only `absent` installs. An indeterminate or
owned-drift package, too little space (asset + `unpackedSize` + seed + 64 MiB) or a path
at the Windows PowerShell 5.1 limits stops the run before any effect.

An install writes its intent first, then downloads the locked URL with the inbox
`curl.exe` (HTTPS only, redirects too, bounded time) to the one file the intent
implies (`<staging>.asset`), checks size, SHA-256 and SHA-1 while holding it open
against writers, checks the `tar -tf` listing against the pinned inventory, extracts
with the inbox `tar.exe` into the staging directory, deletes the asset, requires the
staging tree to be exactly the inventory, renames it into place and commits. An
interrupted install is recovered: the asset and the inventory-named staging files
are removed and the intent voided; anything else there stops recovery and is kept.
Once the selected version is owned and exact, owned trees of its other versions are
removed the Uninstall way (a tree in use, or one another effect refers to, is kept
and reported). `Uninstall` refuses, before removing anything, while a package's
executable is in use; it never removes protected data, a foreign App Paths name or an
external install. A 7z asset (Chromium) installs like a ZIP, through inbox
`tar.exe`.

**Launch by name (App Paths).** A lock's `appPath` (Chromium: `chromium.exe`, never the
executable's own name) is the only name owned: the key
`HKCU\Software\Microsoft\Windows\CurrentVersion\App Paths\<appPath>` and its default
REG_SZ naming the owned executable, written after the tree and pointed at a new
version before old trees go; the `App Paths` key itself is shared, never owned. It is
written only for a package owned exactly (or just installed) without a conflict or a
profile its seed would overwrite, and only while the key and its default value are each
absent or owned: a key or value this distribution does not own is drift even with our
exact data (never taken over; remove it by hand, then `Restore`), and so is the name in
HKLM (64- or 32-bit view), which HKCU would shadow; an owned key that later meets one is
only reported. While it names a tree, that tree is not collected or uninstalled unless
the same plan removes the value. A name no lock declares any more is collected by a run
that handles packages (`Restore`, or `Apply -Packages`): value, then key, only while the
key holds nothing else, and never while a seed would overwrite a profile; `Uninstall`
removes it likewise, refusing a key with foreign content (A3).
Nothing else is registered: no `Path` value, shortcut, PATH, HKLM, file or URL
association, or default-browser entry. **Limits now:** a package removed from the
locks altogether leaves its ledger records unreadable, as for its tree; a read-only
file in an extracted tree would make `Uninstall` fail (recorded, not hidden).

**Chromium font seed.** `pack.py` generates
`payload/chromium/initial_preferences` from the lock's `seed` roles: exactly the six
preferences `webkit.webprefs.fonts.{standard,sansserif,fixed}.{Zyyy,Jpan}`, IBM Plex Sans
JP proportional and PlemolJP Console NF fixed (every TTF of a role must carry that
typographic family). The manifest records its `path` beside `chrome.exe` in the owned
tree, `file`, `sha256` and `size`; the archive may hold no `initial_preferences` or
`master_preferences` there, and the seed is outside `files` and `unpackedSize`. An
install lists the archive against the inventory alone, then, after extraction, writes
the seed into staging as a new, flushed file from the bundle (length and SHA-256
checked again); the staged tree must be exactly the inventory and the seed, which
recovery and `Uninstall` remove with the tree. An owned tree recorded for another
inventory or seed of the same version is `owned-drift` (Uninstall, then install again).
Chromium reads the seed only on a first run, for a `User Data` without its `First Run` sentinel, and then
**overwrites that profile's existing `Preferences`**. So every mode reads, and never
writes, `User Data\First Run` and `User Data\Default\Preferences` (no mode starts
Chromium): while `Default\Preferences` exists without `First Run`, an install is
refused (besides R1, which refuses any profile without this package's history), and
an owned seeded tree never converges. Like R1, this writes nothing for Chromium and
fails as package drift after the other effects (`RestoreTest` fails too), saying not
to start that Chromium; only an owned-drift tree (C1) stops the run before any
effect. `Uninstall` removes the tree with its seed, never the profile. Boundary: a profile present at `Restore` is not
installed over; a partial `User Data` restored by hand after the install and started
before the next `Restore`/`RestoreTest` is outside automated prevention. Only
`Default` is checked; other profiles, and this build's own first-run behaviour, are
unproven until the VM run. Sites that set fonts in CSS, serif, other scripts, and
Chromium's and Windows' own UI are unaffected; a later user setting prevails, and sync
may.

### Desktop UI font faces

`typography` in `nix.nix` names a font role (`ui`, IBM Plex Sans JP) and the locked
interpreter package (AutoHotkey). `Restore`, and `Apply -Typography` (the fonts and
these faces alone, for a machine where `Restore` stops elsewhere, e.g. at a
machine-wide Noctty), set that family as the face of the six Win32 UI font slots
(caption, small caption, menu, status, message; icon title) through
`SystemParametersInfoW`. The call is made by `ui-font.ahk`, run by the owned (or an
exact preexisting) `AutoHotkey64.exe` whose SHA-256 is the lock's. No compiler,
`Add-Type`, input, hook or window is involved. Only `lfFaceName` changes: before writing,
the script requires each slot's persisted `HKCU\Control Panel\Desktop\WindowMetrics` value to equal its
live LOGFONTW, except that lfQuality may be 0 live and 5 persisted, as on a real host where SPI's GET reports the
quality it renders with. It also requires each slot it sets to hold the face the ledger expects. Otherwise it refuses
and writes nothing. It writes the persisted LOGFONTs as they are, face aside, so the persisted quality is kept. Afterwards every other byte of the six live fonts and, separately, of the six persisted ones, and every other
WindowMetrics value, must be unchanged, or it puts all of them back and fails.
Sizes, weights and the DPI are never written. The live and persisted units agree at
100% scaling; at other scalings that precheck may refuse, which is safe but
unproven.

Each slot is a `ui-font-face` ledger effect (target `spi:<slot>`, state `face`,
prior the face found). Another face in a slot nothing owns is `absent`, taken with
that face recorded as prior. One set covers every slot to write, then one commit
per slot read back. Recovery commits a slot that took the face and voids one that
did not. A face changed after this wrote it is owned-drift: `Apply` reports UI
font drift and writes nothing, and `Uninstall` refuses it (set it back by hand).
`Uninstall` writes each prior face back through the interpreter before any tree
goes. It refuses when the interpreter is missing. Unselected owned fonts are
collected only after the faces move, and a font whose family a slot still names
is kept. This covers classic Win32 UI text only: modern Windows shell and XAML
text, and each application's own fonts, are unaffected. A running application may
need a restart to pick up the change.

### Store apps

`apps` in `nix.nix` lists Microsoft Store apps by Store id, package name and publisher
id. For now it holds only the ChatGPT desktop app: `9PLM9XGG6VKS`, package family
`OpenAI.Codex_2p2nqsd0c76g0`. `Restore` reads this user's packages (`Get-AppxPackage`).
With none of that name it runs the official WinGet (`winget install --id <id> --source
msstore --exact --silent`). With exactly one of that publisher it does nothing. Anything
else fails and is never replaced. `Restore` and `RestoreTest` then require it to be
present and report its version.

**ChatGPT app fonts.** The app's `appearance` in `nix.nix` names font roles for the
app's own settings: UI and content use IBM Plex Sans JP, and code uses PlemolJP Console
NF, each written as a quoted CSS family, in both the light and dark themes.
- **When it runs:** `Restore` sets them after installing the app and before its first
  start. `Apply -Typography` sets them only when the app is already present.
- **How it writes:** only through the app's own config service, the `codex.exe
  app-server` bundled in the installed package. It calls `initialize`, `config/read`
  with layers, then one `config/batchWrite` guarded by the user layer's
  `expectedVersion`, then reads back. No model, thread or account request is made.
  There is no file edit, internal IPC, `app.asar`, global-state or database write.
- **What it changes:**
  - An existing theme gets only its `ui`, `code` and `content` font leaves, and loses
    any `uiFace`/`codeFace`/`contentFace` (a Face overrides the family). Its colors, the
    mode and all other settings stay.
  - An absent theme is created whole from the app's own defaults (`jq` of
    26.928.1915.0, with `accentSource = "chatgpt"`). A theme with fonts alone is one the
    app drops.
- **Errors:** a refusal by the service is reported by method and JSON-RPC error code only; its message, which may quote a config line, and the service's stderr are never printed.
- **Refusals:** a theme another config layer sets, one the app would reject, and a
  read-only or repeated user layer are refused. A stale version is refused by the
  service, and nothing is written.
- **Ledger:** each theme is an `app-theme-fonts` effect with the prior font leaves
  (Face objects included) recorded.
  - `Uninstall` puts them back only while they are still the ones written. A theme it
    created and nobody changed is removed whole; a recoloured one keeps its colors and
    loses only the fonts, and stays valid.
  - Fonts changed afterwards (the running app writes the whole theme when the user
    changes appearance) are owned-drift: reported and never written. `Uninstall`
    refuses them.
  - Everything else in the user config is compared before and after each write
    (values only, never printed), and a difference fails the run.
- **Limits:**
  - A running app shows the change after its next restart. Nothing here starts,
    stops or restarts it; that restart and a visual check are the final gate.
  - Starting the service does its normal runtime bookkeeping under the Codex home (and
    its usual network requests), so the write is not the only file activity.
  - Only this user's Codex config is written. The app's data, accounts and other
    settings are never owned.
  - `Uninstall` needs the app present while the ledger owns its fonts.

This uses neither Microsoft DSC nor a pinned package. The Store serves and updates its
current version, so installing needs the network and a restore gets that day's
version. An app is not a ledger effect: it is never reinstalled, updated, closed or
removed, and its data and settings, including in-app fonts, are not owned or written.

**Torn record.** A power loss can tear only the highest-seq record, and every mode
that reads the ledger then stops. Remove that one file by hand only if it is the
highest `<seq>.json` **and** does not parse as JSON; then rerun, and recovery
closes the attempt from the machine's state. A record that parses but is invalid
is never removed: stop and investigate.
**Stale lock.** A power loss can also leave `ledger\.lock`, and every writer then stops with "Another run holds the effect ledger lock"; delete that one file by hand only when no `win.ps1` (`powershell.exe`) process is running.

**#14 (RentSsh).** The ledger owns only what it created (prior absent), except a UI
font face, whose slot always holds one (above). A
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

`test_pack.py` covers compiler metadata, license retention, font families,
deterministic ZIPs and seed bytes, hash inventories, and empty/duplicate/unsafe/
colliding-input rejection using synthetic fixtures. It is not native Windows evidence.

`proof.ps1` runs only on disposable GitHub-hosted Windows runners. It requires
exact source identity; checks the pure ledger classification for every kind;
applies twice with one intent and one commit per owned file and value and zero
changes on the second apply; independently reads the files and values back from
`manifest.fonts`; repairs owned value and byte drift and refuses unowned drift;
rejects package corruption; replays interrupted attempts (void, commit, undone,
temporary files an intent named, a temporary file none named, a second writer, a
torn record); keeps files a foreign value names; moves an owned value to a new
selection and collects the old file; and uninstalls (dry run unchanged, locked
file kept owned, then empty, then a no-op), all with Noctty converged by the same
`Apply` (A22). For Noctty (A15-A21) it checks the order of the owned effects and
an independent readback of the tree, configuration, keys, six values and
selection; a differing owned or unowned tree refused before any effect; a
half-restored selection and a partly removed tree resumed by `Uninstall`; an
interrupted extraction voided and its staging cleaned; A3, the K-rule (one value
exact or foreign with the rest absent) and the COM guard (six exact unowned
values naming an owned tree) refusing before any removal; a differing user
configuration kept; and an exact unowned tree left alone. The create and undo
primitives also run in a Windows PowerShell 5.1 child on synthetic targets. The
G4 gate measures the vendor's own registration against the six values. A
`Restore` rollback after a failed activation or package check is not exercised
on CI (`Restore` refuses the elevated runner, whose Windows Terminal is 1.23).
For packages (A23-A30, AutoHotkey and Chromium each downloaded once) it checks the
`-Packages` contract and R1 before any effect, an external
entry never taken over (alone or beside the owned tree), a clean AutoHotkey install
owned exactly with no asset or staging left and a second Apply writing nothing,
an owned older version collected, interrupted installs recovered (asset and
staging removed; foreign staging content kept), and `Uninstall` refusing while the
executable is in use, then removing the tree but not the profile. For the Chromium
seed (A28 and the primitives) it checks the bundled bytes against the font roles, every
malformed seed refused, the listing against the inventory alone, a staging tree exact
only after the verified seed is written (a differing one writes nothing), recovery
removing the seed, and, with the profile only read, O1 keeping Chromium from installing
(package drift, nothing written) and C1 stopping a stand-in owned tree before any effect.
A29 installs the locked Chromium for real through `win.ps1` (`Apply -Packages
Chromium`) over the proof's stand-in profile, with `First Run` beside it and this
package's history (so R1 and O1 allow it and the profile is never written): one intent
naming the package and one commit, the tree exactly the inventory and the seed, no
asset or staging left. Its first run is then observed and asserted, within a budget of
about 120 s (each step starts only when its bounded share is left; the final bounded
cleanup and readouts come on top), the baseline taken after the install and just
before the first launch: the owned tree is started only with scratch
`--user-data-dir` profiles on the runner. It requires `First Run` and the six seed
preferences after a first GUI run; which of `Default` and `Profile
1` a first run over Preferences without `First Run` overwrites; the fonts a headless PDF
embeds; the tree unchanged; every `chrome.exe` as tree, descendant (traced by PID and
creation time, its parent seen running at or after the child's creation), outside (only
with a readable path elsewhere) or unknown, its windows closed one by one and 45 s to
end, only tree and descendant processes ever killed, and H1 (all ended), H2 (the browser
stays for an observed reason: background mode, or a window still left after closing)
or H3 (outside) decided only on positive evidence, an unknown survivor being unproven,
never a pass; Local State's `background_mode.enabled`; nothing new under the default
`%LOCALAPPDATA%\Chromium` (moved aside, never deleted, never through a reparse point;
anything not moved is a stop condition); fixed HKCU names before and after, read before
any move, every added App Paths, Uninstall, StartMenuInternet, RegisteredApplications and
`Software\Classes` name (those directly under it and OpenWithProgids) listed; any stop
condition fails the proof (only an unreadable PDF and the names added outside App Paths
and Uninstall are record only). A second Apply then writes nothing for Chromium, still
owned exactly, and `Uninstall` removes the tree with its seed and keeps the profile and
the scratch profiles. Within A29 (one download), A30 checks the same install owned
`App Paths\chromium.exe` (one REG_SZ default naming the owned `chrome.exe`, written
once), that a foreign value in the key stops `Uninstall` before any removal, and that
`Uninstall` removes the value, then the key (the runner must have no
`App Paths\chromium.exe` in HKCU or either HKLM view beforehand). It then reports
`appPathsLaunch` in the proof's answer: `proven` when ShellExecute (Win+R's API), from an
empty directory with `chromium` on no PATH, starts exactly the owned `chrome.exe` by the
name `chromium`, and the same launch then fails with "file not found" after `Uninstall`;
`unproven` only when `chromium`, `chromium.exe` and a same-name HKCU probe (a copy of
`PING.EXE` registered under its own name, both spellings) all fail with "file not found"
on this elevated runner, that is, none of the names tried here (`chromium`,
`chromium.exe`, same-name probe in two spellings) resolved using this ShellExecute
method; any other
outcome fails the proof. The primitives prove, on a throwaway name in the runner's real
HKCU, a foreign key (even with our exact data) as drift that is never written, HKLM
conflicts (stubbed), re-pointing, the tree reference and retired names; the main
`Apply`/`RestoreTest` path meeting a foreign key (nothing written, package drift at the
end) is not exercised end to end, only its decision. The
runner is an elevated Windows Server: a clean, unelevated Windows 11 user's `Restore`,
first run on the default `User Data` and Win+R itself are proven only by the VM run.
**Required before #7 is complete and before this build is used on a real host, whatever
`appPathsLaunch` says (VM run, S7):** on a clean
Windows 11 VM, as an unelevated user in an Explorer-launched session, Win+R `chromium`
after `Restore` starts the owned `chrome.exe` (positive), and the same Win+R after
`Uninstall` finds nothing (negative).
A31 (UI font faces, while AutoHotkey is owned) first gives the runner's persisted fonts lfQuality 5, as a fixture it
removes afterwards, and runs `ui-font.ahk get`. A persisted height other than the live one is refused without a write. It
requires each live LOGFONTW to equal the runner's persisted value, and the script
to refuse an unexpected face without writing. It then models a crash after the five
NONCLIENTMETRICS slots took the face (six intents, one set of five). `Apply
-Typography` commits those five, voids the icon, writes it anew and changes
nothing but the six faces. A second run writes nothing; a changed face is drift and
is not written. After A27's `Uninstall` every WindowMetrics value is byte-for-byte
the runner's baseline again. `Restore`'s Store app step (WinGet) is not run on CI;
only its decision (`Get-AppAction`) is. The runner has no ChatGPT app, so the app fonts
are proven on CI only as pure rules: complete default themes, font-only themes refused,
the edits for an existing and an absent theme, records, classes, the undo of a created
and a recoloured theme, and the comparison of the rest of the config. `Apply
-Typography` there reports `appFonts = "appAbsent"`. The adapter itself was run
outside CI, under Windows PowerShell 5.1, against the bundled service of package
26.928.1915.0, on synthetic isolated Codex homes only (not the host's config). It
passed: converge, a second run writing nothing, a stale version refused, user drift
not written, and the `Uninstall` plan restoring the prior Face object and keeping a
recoloured theme. A fresh home without `config.toml` got both default themes.
It also requires every `win.ps1` answer to report
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

`%LOCALAPPDATA%\windows-iac\provenance\default-terminal.json` is per-user state;
rollback reads it and nothing removes it. A clean Chromium install and its App Paths
registration are enabled and proven on the CI runner (A29, A30; the launch by name as
`appPathsLaunch` reports), but the VM run, including the Win+R positive and negative
above, is still open, so `Restore`/`Uninstall` as a whole is not complete.

**Required on a VM before the native registration is accepted (unproven here):**
from an unelevated, Explorer-launched shell with Windows Terminal 1.24 or newer,
`Restore` (COM activation and the package-context pair), the handoff proof above
(a new console opens in this Noctty), and one GUI start and close of Noctty
showing no write inside its tree (G3). These also gate leaving out the vendor's
bookkeeping keys and descriptions; if handoff fails without them, they become
owned values.

**Recorded host observations (2026-10-01, no clean VM).** On the maintainer's host, a
Noctty sample of ASCII, kana, kanji and the Nerd Font glyph U+F121 was accepted by the
user as rendering without visible missing-glyph boxes. That host's Noctty was already
configured with PlemolJP. This is an accepted visual sample on one existing machine.
It is not a clean-install, `Restore` or VM result. No UI font face or Store app was
applied on that host. The clean VM run (S7) is deferred by the user, so a full clean
restore is not claimed.

Application/UI selection beyond noctty and the six Win32 UI font slots, Japanese/Nerd/Emoji rendering,
font reload/relogin, Linux profile activation, and real-host
Spec + Binding → Runtime → Proof/restoration remain unproven. Installing a font
does not prove an application uses it. Native `nix.exe` is not a prerequisite.

Hosted CI success does not authorize dependency merges, issue closure, or real-PC
changes. Keep #7 open until its remaining acceptance is demonstrated.
