"""Compile pinned Windows selections into a portable, deterministic DSC distribution.

This module does not choose products, versions, URLs, or host/site values.
Those inputs belong to nix.nix; Windows effects belong to win.ps1.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import shutil
import tempfile
import zipfile

from fontTools.ttLib import TTFont


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def write_json(path: Path, value: object) -> None:
    path.write_text(json.dumps(value, ensure_ascii=False, sort_keys=True, indent=2) + "\n", encoding="utf-8")


def relative(name: str) -> str:
    path = PurePosixPath(name)
    if not name or "\\" in name or ":" in name or path.is_absolute() or ".." in path.parts:
        raise ValueError(f"Unsafe archive path: {name!r}")
    return path.as_posix()


def prepare_fonts(policy: list[dict], out: Path) -> None:
    target = out / "share/fonts/truetype"
    target.mkdir(parents=True)
    entries, names = [], set()
    for choice in policy:
        paths = sorted(Path(choice["directory"]).rglob("*.ttf"))
        if not paths:
            raise ValueError(f"No TTF files for role {choice['role']}")
        for path in paths:
            with TTFont(path) as font:
                name = font["name"].getDebugName(4)
            if not name or name.casefold() in names:
                raise ValueError(f"Missing or duplicate font full name: {name!r}")
            names.add(name.casefold())
            sha = digest(path)
            filename = sha + ".ttf"
            shutil.copyfile(path, target / filename)
            entries.append({"role": choice["role"], "family": choice["family"],
                            "version": choice["version"], "fullName": name,
                            "file": filename, "sha256": sha})
        licenses = sorted(p for p in Path(choice["licenseSource"]).rglob("*")
                          if p.is_file() and p.name.casefold().startswith(("license", "ofl", "copyright")))
        if not licenses:
            raise ValueError(f"No upstream license found for role {choice['role']}")
        license_dir = out / "share/licenses" / choice["role"]
        license_dir.mkdir(parents=True)
        for path in licenses:
            shutil.copyfile(path, license_dir / (digest(path) + "-" + path.name))
    if not entries:
        raise ValueError("An empty selection cannot prove activation")
    write_json(out / "fonts.json", entries)


def configuration(entries: list[dict]) -> dict:
    return {
        "$schema": "https://aka.ms/dsc/schemas/v3/bundled/config/document.json",
        "resources": [{
            "name": entry["fullName"],
            "type": "Microsoft.Windows/Registry",
            "properties": {
                "keyPath": "HKCU\\Software\\Microsoft\\Windows NT\\CurrentVersion\\Fonts",
                "valueName": entry["fullName"] + " (TrueType)",
                "valueData": {"String": "[concat(envvar('WINDOWS_IAC_FONT_DIR'), '\\', '" + entry["file"] + "')]"},
            },
        } for entry in entries],
    }


def package_configuration(packages: list[dict]) -> dict:
    if not packages or len({p["id"].casefold() for p in packages}) != len(packages):
        raise ValueError("Empty or duplicate package selection")
    return {
        "$schema": "https://aka.ms/dsc/schemas/v3/bundled/config/document.json",
        "resources": [{
            "name": package["name"],
            "type": "Microsoft.WinGet/Package",
            "properties": {"id": package["id"], "source": "winget",
                           "version": package["version"], "acceptAgreements": True,
                           "installMode": "silent"},
        } for package in packages],
    }


def noctty_inventory(archive_path: Path) -> dict[str, str]:
    files: dict[str, str] = {}
    with zipfile.ZipFile(archive_path) as upstream:
        for entry in upstream.infolist():
            name = relative(entry.filename)
            if entry.is_dir():
                continue
            if not name.startswith("noctty/") or name.casefold() in (n.casefold() for n in files):
                raise ValueError(f"Unexpected or duplicate noctty path: {name}")
            if (entry.external_attr >> 16) & 0o170000 == 0o120000:
                raise ValueError(f"Symlink in noctty archive: {name}")
            files[name] = hashlib.sha256(upstream.read(entry)).hexdigest()
    if not {"noctty/noctty.exe", "noctty/noctty.com",
            "noctty/noctty-terminal-handoff-proxy.dll"}.issubset(files):
        raise ValueError("Noctty archive lacks default-terminal components")
    return files


def archive(root: Path, destination: Path) -> None:
    seen = set()
    with zipfile.ZipFile(destination, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=9) as result:
        for path in sorted(root.rglob("*")):
            if path.is_symlink():
                raise ValueError(f"Symlinks are not portable: {path}")
            if not path.is_file():
                continue
            name = relative(path.relative_to(root).as_posix())
            if name.casefold() in seen:
                raise ValueError(f"Case-insensitive path collision: {name}")
            seen.add(name.casefold())
            info = zipfile.ZipInfo(name, date_time=(1980, 1, 1, 0, 0, 0))
            info.create_system = 3
            info.external_attr = 0o100644 << 16
            info.compress_type = zipfile.ZIP_DEFLATED
            result.writestr(info, path.read_bytes(), compresslevel=9)


def distribution(fonts: Path, backend: Path, noctty: Path, choices: Path,
                 scripts: Path, source: str, out: Path) -> None:
    out.mkdir(parents=True, exist_ok=True)
    selected = json.loads(choices.read_text(encoding="utf-8"))
    if selected["noctty"]["fontFamily"] not in {e["family"] for e in json.loads((fonts / "fonts.json").read_text(encoding="utf-8"))}:
        raise ValueError("Noctty font is not selected by common fonts")
    noctty_files = noctty_inventory(noctty)
    with tempfile.TemporaryDirectory() as temporary:
        root = Path(temporary)
        shutil.copytree(fonts / "share", root / "share")
        entries = json.loads((fonts / "fonts.json").read_text(encoding="utf-8"))
        if not entries:
            raise ValueError("Empty font payload")
        with zipfile.ZipFile(backend) as upstream:
            seen = set()
            for entry in upstream.infolist():
                name = relative(entry.filename)
                if name.casefold() in seen or (entry.external_attr >> 16) & 0o170000 == 0o120000:
                    raise ValueError(f"Duplicate path or symlink in backend: {name}")
                seen.add(name.casefold())
                upstream.extract(entry, root / "backend")
        executables = list((root / "backend").rglob("dsc.exe"))
        if len(executables) != 1:
            raise ValueError("Expected exactly one pinned dsc.exe")
        for name in ("win.ps1", "proof.ps1", "handoff-proof.ps1", "handoff-evaluate.ps1",
                     "package-view.ps1", "README.md"):
            shutil.copyfile(scripts / name, root / name)
        write_json(root / "configuration.dsc.json", configuration(entries))
        (root / "payload").mkdir()
        shutil.copyfile(noctty, root / "payload/noctty.zip")
        write_json(root / "packages.dsc.json", package_configuration(selected["packages"]))
        files = {p.relative_to(root).as_posix(): digest(p) for p in sorted(root.rglob("*")) if p.is_file()}
        write_json(root / "manifest.json", {"schemaVersion": 2, "source": source,
                   "backend": executables[0].relative_to(root).as_posix(), "fonts": entries,
                   "noctty": {"version": selected["noctty"]["version"],
                              "fontFamily": selected["noctty"]["fontFamily"],
                              "files": noctty_files},
                   "packages": selected["packages"], "files": files})
        output = out / "windows-dist.zip"
        archive(root, output)
        (out / "windows-dist.zip.sha256").write_text(digest(output) + "  windows-dist.zip\n", encoding="ascii")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    font_parser = sub.add_parser("fonts")
    font_parser.add_argument("policy", type=Path)
    font_parser.add_argument("out", type=Path)
    dist_parser = sub.add_parser("dist")
    for argument in ("fonts", "backend", "noctty", "choices", "scripts"):
        dist_parser.add_argument(argument, type=Path)
    dist_parser.add_argument("source")
    dist_parser.add_argument("out", type=Path)
    args = parser.parse_args()
    if args.command == "fonts":
        prepare_fonts(json.loads(args.policy.read_text()), args.out)
    else:
        distribution(args.fonts, args.backend, args.noctty, args.choices,
                     args.scripts, args.source, args.out)
