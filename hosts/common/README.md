# Common desktop selection → Windows activation

Issue #7 implementation slice. The authority is `nix.nix`, not this document or
the generated JSON. No Windows Nix installation, WinGet catalog, mutable latest,
per-product installer, custom DSC resource, or new top-level directory is added.

```text
existing flake.lock + common/nix.nix
  ├─ common-fonts                 same selected TTF bytes, usable by Linux
  └─ windows-dist.zip            fonts + licenses + pinned DSC + generated config
       └─ win.ps1                verify → realize files → native DSC registry
```

The existing nixpkgs pin selects IBM Plex Sans JP and PlemolJP Console NF.
Only the normal Console NF variant is selected, not the separate 35 variant.
DSC 3.3.0 Windows x86_64 is fixed by release URL and upstream SHA-256 in Nix.
The portable backend and all selected font licenses travel with the artifact.
The PowerShell adapter has no product names, versions, URLs, or network path.

## Build and use

```sh
nix flake check --no-write-lock-file
nix build .#windows-dist --no-write-lock-file
# result/windows-dist.zip and result/windows-dist.zip.sha256
nix build .#common-fonts --no-write-lock-file
# result/share/fonts is consumable by a Linux font configuration
```

On Windows x86_64 with PowerShell 7, verify the ZIP against the checksum from the
trusted successful CI/release, extract it into a fresh directory, then run:

```powershell
pwsh -NoProfile -File .\win.ps1                 # default: read-only validation
pwsh -NoProfile -File .\win.ps1 -Mode Apply     # explicit per-user effect
pwsh -NoProfile -File .\win.ps1 -Mode Test      # nonzero/error on drift
```

`Apply` writes only the selected content-addressed TTF files beneath the current
user's `LocalApplicationData\Microsoft\Windows\Fonts` and their corresponding
HKCU font registrations. It does not replace Windows system fonts, rewrite an
application configuration, modify persistent PATH, use admin privileges, remove
unmanaged fonts, or download anything. The current-user location is the Binding;
it is not embedded in the common Spec. DSC resource discovery is confined to
the bundled backend for the invocation.

A failed apply can leave partial state; rerun the same artifact to converge.
Applying a retained prior artifact restores registrations for names it owns.
This is **not** a transactional rollback or a garbage collector: removed family
names and old content-addressed files are deliberately not deleted. Do not use
this slice to claim arbitrary desktop upgrades/downgrades are fully reversible.

The ZIP checksum binds transported bytes; the embedded inventory detects
post-extraction corruption, not publisher authenticity. Keep a trusted source
for the expected checksum. The manifest records the exact source commit; the
Windows proof rejects dirty/unbound sources.

## Proof boundaries

`test_pack.py` checks metadata, license retention, deterministic ZIPs, complete
hash inventories, duplicate rejection, empty selection rejection, and unsafe
archive paths. These are compiler tests, not Windows effects.

`proof.ps1` runs only on disposable GitHub-hosted Windows runners. It validates,
applies twice, requires zero changes on the second apply, checks actual registry
values, rejects installed-byte drift, repairs it, and rejects package corruption.
The workflow only builds, transports, invokes that proof, and gates publication.
Publishing uses the build job's same ZIP, never a rebuild. PR runs cannot publish;
this distribution's release job runs only for a successful push to `main`.

## Before → after; remaining #7 gates

| Before | This slice |
|---|---|
| DSC / WinGet could make a second acquisition or version decision | Nix resolves everything; activation is offline |
| Font family selections could diverge by OS | One selection emits both Linux fonts and a Windows bundle |
| Generated DSC could become a second hand-edited Spec | Configuration and inventory are compiler outputs, untracked |
| CI's read-only validation vs apply-twice contract was ambiguous | Generic convergence is CI proof; real-host UX remains separate |
| A green syntax check could be called desktop completion | Compiler, native convergence, and real-host acceptance are distinct |

This is intentionally **not the whole of #7**. The following stay open:

- The existing own/rent image workflows still exist. Consolidating their
  target-owned OCI smoke proofs and publication into the final single `ci.yml`
  needs a composed-tree change across the open OCI PR stack. This slice does
  not remove a previously established image proof or silently accept that stack.
- Actual UI/application selection, Noctty integration, Japanese/Nerd rendering,
  emoji product/format choice, font reload/relogin behavior, and real-host
  Spec + Binding → Runtime → Proof/rollback have not been established here.
  Installing and registering a font is not proof that an application uses it.
- The Linux font output is reusable; no existing Linux machine/profile is
  activated by this PR. Native `nix.exe` and additional backends are not required.
- Issue #8's development-capable OCI and Issue #2's migration gates are unchanged.

Do not close #7, merge the dependency PRs, or mutate a real PC merely because this
slice's hosted CI passes. Those are separate acceptance/authorization boundaries.
