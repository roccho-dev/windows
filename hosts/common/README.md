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
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\win.ps1 -Mode Restore      # four selected components
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\win.ps1 -Mode RestoreTest  # fail on drift
```

`Restore` converges the selected fonts, the pinned noctty portable ZIP and its
`font-family = PlemolJP Console NF` configuration, and the pinned WinGet package
IDs/versions for Chrome Beta and AutoHotkey through native DSC resources. The
Chrome Beta installer may require elevation. The machine needs a network
connection and a working WinGet source for those two packages; they are not
redistributed in the ZIP. Noctty is included because its WinGet package is not
published. The release ZIP can be downloaded again after a clean install; Nix
is only needed to build it, not to apply it.

`Apply` and `Test` retain their font-only meaning for the CI proof. They own
selected content-addressed TTF files beneath the current user's
`LocalApplicationData\Microsoft\Windows\Fonts` and corresponding HKCU font
registrations. `Restore` also writes the selected noctty configuration, but
does not replace Windows-owned UI fonts or restore old registry settings,
accounts, profiles, or personal app data. The user directory is a runtime Binding, not common Spec.
DSC discovery is confined to the bundled backend for each invocation.

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
corruption. Negative controls must fail for their expected reason.

The workflow builds, transports, invokes target-owned proof, and gates release.
Actions are commit-pinned. Windows proof and main-only publication consume the
same artifact ID and ZIP checksum; publication never rebuilds. PRs cannot publish.

## Remaining acceptance

This is **not the whole of #7**. Existing own/rent image workflows remain; their
proven target-owned smoke tests and publication still need composition into the
final single `ci.yml` with the open OCI stack. Do not discard existing proof to
claim one workflow prematurely. Existing OCI definitions and #8 are unchanged.

Application/UI selection beyond noctty, Japanese/Nerd/Emoji rendering,
font reload/relogin, Linux profile activation, and real-host
Spec + Binding → Runtime → Proof/restoration remain unproven. Installing a font
does not prove an application uses it. Native `nix.exe` is not a prerequisite.

Hosted CI success does not authorize dependency merges, issue closure, or real-PC
changes. Keep #7 open until its remaining acceptance is demonstrated.
