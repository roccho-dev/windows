"""Compile pinned Windows selections into a portable, deterministic distribution.

This module does not choose products, versions, URLs, or host/site values.
Those inputs belong to nix.nix; Windows effects belong to win.ps1, the native
activation adapter.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import re
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


WINDOWS_RESERVED = re.compile(r"(con|prn|aux|nul|com[0-9]|lpt[0-9])(\..*)?", re.IGNORECASE)


def windows_path(name: str) -> str:
    """A '/'-separated relative path Windows recreates exactly: no '.' or empty segment,
    and every segment a valid, unreserved file name without a trailing dot or space.
    The same segment rule as Test-PathSegment in handoff-evaluate.ps1."""
    path = relative(name)
    if path != name or any(re.search(r'[<>:"|?*\\\x00-\x1f]', segment) or segment.endswith((".", " "))
                           or WINDOWS_RESERVED.fullmatch(segment) for segment in path.split("/")):
        raise ValueError(f"Not a Windows path: {name!r}")
    return path


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
                # The typographic family (name ID 16, else 1) is the name a Chromium seed or the Noctty
                # setting selects: every file of a role belongs to exactly the declared family.
                family = font["name"].getDebugName(16) or font["name"].getDebugName(1)
            if family != choice["family"]:
                raise ValueError(f"Font family {family!r} is not {choice['family']!r}: {path.name}")
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


PACKAGE_KEYS = {"name", "version", "url", "format", "size", "sha256", "scope", "effect", "directory",
                "executable", "existing", "protected"}
EXISTING_KEYS = {"uninstallKey", "displayName", "publisher", "installLocation", "executable"}
# A seed is Chromium's initial_preferences beside the executable, holding only font preferences
# written from roles; Chromium also reads the legacy name, so neither may come from the archive.
SEED_KEYS, SEED_FONTS = {"path", "fonts"}, {"proportional", "fixed"}
SEED_NAME, SEED_NAMES = "initial_preferences", ("initial_preferences", "master_preferences")
# The preferences per role: webkit.webprefs.fonts.<generic>.<script>, nested as Chromium's
# Preferences are; Zyyy is the default script, Jpan the one a Japanese page uses.
SEED_GENERICS = {"standard": "proportional", "sansserif": "proportional", "fixed": "fixed"}
SEED_SCRIPTS = ("Zyyy", "Jpan")
# An App Paths name: one segment ending in lowercase .exe; win.ps1 AssertPackageShape holds the same rule.
APP_PATH = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]*\.exe")
TOKEN = re.compile(r"[A-Za-z0-9][A-Za-z0-9.-]*")
# A version starts with a digit and holds no '-', so Programs/<name>-<version> splits one way
# only (chromium-extra-1 is never Chromium's); win.ps1 Get-PackageAssetPath relies on it.
VERSION = re.compile(r"[0-9][A-Za-z0-9.]*")
# Byte counts win.ps1 reads from JSON under Windows PowerShell 5.1: kept exact as a double there.
MAX_SIZE = 2**53 - 1


def is_size(value: object) -> bool:
    return type(value) is int and 0 < value <= MAX_SIZE


def text(value: object, what: str) -> str:
    if not isinstance(value, str) or not value:
        raise ValueError(f"{what} is not a non-empty string")
    return value


def hex_digest(value: object, length: int, what: str) -> str:
    if not isinstance(value, str) or not re.fullmatch(f"[0-9a-f]{{{length}}}", value):
        raise ValueError(f"{what} is not {length} lowercase hex digits")
    return value


def overlaps(one: str, other: str) -> bool:
    """True when one path equals or contains the other, compared per segment without case."""
    a, b = one.casefold().split("/"), other.casefold().split("/")
    return a[:len(b)] == b or b[:len(a)] == a


def package_locks(packages: object) -> list[dict]:
    """Validate release-asset locks. The only owned effect a lock may declare is a
    current-user tree extracted to %LOCALAPPDATA%/Programs/<name>-<version>, which
    may not overlap the expected current-user install or protected runtime data.
    existing.installLocation serves only that overlap check: presence is decided by
    a matching HKCU or HKLM Uninstall entry, never by this path (see nix.nix)."""
    if not isinstance(packages, list) or not packages:
        raise ValueError("Empty package selection")
    names, owned, app_paths = set(), [], set()
    for package in packages:
        if not isinstance(package, dict) or set(package) - {"sha1", "seed", "appPath"} != PACKAGE_KEYS:
            raise ValueError(f"Package lock keys differ from {sorted(PACKAGE_KEYS)} (+ optional sha1, seed, appPath)")
        name, version = text(package["name"], "name"), text(package["version"], "version")
        if not TOKEN.fullmatch(name) or not VERSION.fullmatch(version) or name.casefold() in names:
            raise ValueError(f"Invalid or duplicate package: {name!r} {version!r}")
        names.add(name.casefold())
        if package["format"] not in ("zip", "7z"):
            raise ValueError(f"Unsupported package format: {package['format']!r}")
        url = text(package["url"], "url")
        if (not url.startswith("https://github.com/") or "/releases/download/" not in url
                or not url.endswith("." + package["format"])):
            raise ValueError(f"Package URL is not a pinned release asset: {url}")
        if not is_size(package["size"]):
            raise ValueError(f"Invalid package size for {name}")
        hex_digest(package["sha256"], 64, f"{name} sha256")
        if "sha1" in package:
            hex_digest(package["sha1"], 40, f"{name} sha1")
        if package["scope"] != "user" or package["effect"] != "tree-extracted":
            raise ValueError(f"Package {name} must own only a user-scope extracted tree")
        directory = windows_path(text(package["directory"], "directory"))
        if directory != f"Programs/{name.casefold()}-{version}":
            raise ValueError(f"Package directory is not the owned path: {directory}")
        executable = windows_path(text(package["executable"], "executable"))
        if "seed" in package:
            seed = package["seed"]
            if (not isinstance(seed, dict) or set(seed) != SEED_KEYS or not isinstance(seed["fonts"], dict)
                    or set(seed["fonts"]) != SEED_FONTS or not all(isinstance(r, str) and r for r in seed["fonts"].values())):
                raise ValueError(f"Package {name} seed is not {{path, fonts: {{proportional, fixed}}}} with role names")
            path = PurePosixPath(windows_path(text(seed["path"], f"{name} seed path")))
            if path.name != SEED_NAME or path.parent != PurePosixPath(executable).parent:
                raise ValueError(f"Package {name} seed is not {SEED_NAME} beside {executable}")
        if "appPath" in package:
            app_path = package["appPath"]
            if (not isinstance(app_path, str) or not APP_PATH.fullmatch(app_path) or windows_path(app_path) != app_path
                    or app_path.casefold() in app_paths):
                raise ValueError(f"Package {name} appPath is not one unique <name>.exe segment: {app_path!r}")
            app_paths.add(app_path.casefold())
        existing = package["existing"]
        if not isinstance(existing, dict) or set(existing) != EXISTING_KEYS:
            raise ValueError(f"Package {name} existing-install keys differ from {sorted(EXISTING_KEYS)}")
        for key in EXISTING_KEYS:
            text(existing[key], f"{name} existing.{key}")
        if "\\" in existing["uninstallKey"]:
            raise ValueError(f"Package {name} uninstallKey is not one key name")
        windows_path(existing["executable"])
        protected = package["protected"]
        if not isinstance(protected, list):
            raise ValueError(f"Package {name} protected is not a list")
        foreign = [windows_path(existing["installLocation"])] + [windows_path(text(p, "protected path")) for p in protected]
        if any(overlaps(directory, path) for path in foreign + owned):
            raise ValueError(f"Package directory overlaps an unowned or owned path: {directory}")
        owned.append(directory)
    return packages


def verify_asset(package: dict, path: Path) -> None:
    """Fail unless the fetched asset has the locked size, sha256 and, when locked, sha1."""
    sha256, sha1, size = hashlib.sha256(), hashlib.sha1(), 0
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1 << 20), b""):
            sha256.update(chunk)
            sha1.update(chunk)
            size += len(chunk)
    if size != package["size"] or sha256.hexdigest() != package["sha256"] or \
            ("sha1" in package and sha1.hexdigest() != package["sha1"]):
        raise ValueError(f"Asset differs from the {package['name']} lock")


def listed_paths(listing: str) -> list[str]:
    """Entry paths of a `7zz l -slt` listing, each a Windows path, unique without case.
    Run on the listing before extraction."""
    _, separator, entries = listing.partition("\n----------\n")
    if not separator:
        raise ValueError("Not a 7-Zip technical listing")
    paths = [windows_path(line[len("Path = "):]) for line in entries.splitlines() if line.startswith("Path = ")]
    if not paths or len({p.casefold() for p in paths}) != len(paths):
        raise ValueError("Empty listing or case-insensitive duplicate archive path")
    return paths


def tree_inventory(root: Path, listed: list[str], required: str) -> dict[str, str]:
    """relative path -> sha256 of every file extracted under root. Fails on a symlink,
    anything but a regular file or directory, a path the archive listing does not name
    (a listed path's parent directories count as named), a directory with no file
    beneath it, or a missing required file. The inventory lists files only, so every
    directory is implied by a file, and a non-recursive Uninstall that removes the
    files and then their now-empty parents leaves nothing behind."""
    allowed, files, directories = set(), {}, []
    for path in listed:
        parts = path.casefold().split("/")
        allowed.update("/".join(parts[:i]) for i in range(1, len(parts) + 1))
    for path in sorted(root.rglob("*")):
        name = windows_path(path.relative_to(root).as_posix())
        if path.is_symlink() or name.casefold() not in allowed:
            raise ValueError(f"Symlink or unlisted extracted path: {name}")
        if path.is_file():
            files[name] = digest(path)
        elif path.is_dir():
            directories.append(name)
        else:
            raise ValueError(f"Not a regular file or directory: {name}")
    empty = [d for d in directories if not any(f.startswith(d + "/") for f in files)]
    if empty:
        raise ValueError(f"Extracted tree has directories without files: {empty}")
    if required not in files:
        raise ValueError(f"Extracted tree lacks {required}")
    return files


def package_inventory(lock_path: Path, archive_path: Path, listing: Path, tree: Path, out: Path) -> None:
    """The pinned inventory of one package: files (path -> sha256) and unpackedSize, the sum of
    their byte sizes as extracted, which Restore's free-space gate adds to the asset size."""
    package, = package_locks([json.loads(lock_path.read_text(encoding="utf-8"))])
    verify_asset(package, archive_path)
    files = tree_inventory(tree, listed_paths(listing.read_text(encoding="utf-8")), package["executable"])
    write_json(out, {"files": files, "unpackedSize": sum((tree / name).stat().st_size for name in files)})


def inventoried(packages: object) -> list[dict]:
    """Validated locks, each with the build-time inventory's `files` and `unpackedSize` in place of its store path."""
    if not isinstance(packages, list):
        raise ValueError("Empty package selection")
    locks, inventories = [], []
    for package in packages:
        if not isinstance(package, dict) or not isinstance(package.get("inventory"), str):
            raise ValueError("Package lock has no inventory")
        locks.append({key: value for key, value in package.items() if key != "inventory"})
        inventories.append(json.loads(Path(package["inventory"]).read_text(encoding="utf-8")))
    for lock, inventory in zip(package_locks(locks), inventories):
        if not isinstance(inventory, dict) or set(inventory) != {"files", "unpackedSize"} or not is_size(inventory["unpackedSize"]):
            raise ValueError(f"Invalid inventory for {lock['name']}")
        files = inventory["files"]
        if (not isinstance(files, dict) or lock["executable"] not in files
                or len({name.casefold() for name in files}) != len(files)
                or any(windows_path(name) != name or not isinstance(sha, str) for name, sha in files.items())):
            raise ValueError(f"Invalid inventory for {lock['name']}")
        for sha in files.values():
            hex_digest(sha, 64, f"{lock['name']} inventory sha256")
        if "seed" in lock:
            parent = PurePosixPath(lock["seed"]["path"]).parent
            names = [lock["seed"]["path"]] + [(parent / n).as_posix() for n in SEED_NAMES]
            if any(overlaps(name, path) for name in names for path in files):
                raise ValueError(f"The {lock['name']} archive has its own preferences file or a path under the seed")
        lock["files"], lock["unpackedSize"] = files, inventory["unpackedSize"]
    return locks


def noctty_inventory(archive_path: Path) -> dict[str, str]:
    """noctty/... path -> sha256 of every file, each a Windows path. A directory entry must
    also be noctty or beneath it and hold a file: the inventory lists files only, so an
    empty directory would be extracted but never owned or removed (the package M2 rule)."""
    files: dict[str, str] = {}
    directories: list[str] = []
    with zipfile.ZipFile(archive_path) as upstream:
        for entry in upstream.infolist():
            name = windows_path(entry.filename.rstrip("/") if entry.is_dir() else entry.filename)
            if entry.is_dir():
                if name != "noctty" and not name.startswith("noctty/"):
                    raise ValueError(f"Unexpected noctty directory: {name}")
                directories.append(name)
                continue
            if not name.startswith("noctty/") or name.casefold() in (n.casefold() for n in files):
                raise ValueError(f"Unexpected or duplicate noctty path: {name}")
            if (entry.external_attr >> 16) & 0o170000 == 0o120000:
                raise ValueError(f"Symlink in noctty archive: {name}")
            files[name] = hashlib.sha256(upstream.read(entry)).hexdigest()
    empty = [d for d in directories if not any(f.startswith(d + "/") for f in files)]
    if empty:
        raise ValueError(f"Noctty archive has directories without files: {empty}")
    if not {"noctty/noctty.exe", "noctty/noctty.com",
            "noctty/noctty-terminal-handoff-proxy.dll"}.issubset(files):
        raise ValueError("Noctty archive lacks default-terminal components")
    return files


# Adapter rules, not selection data (win.ps1 holds the same roots): a registration key is a
# CLSID or Interface {guid} key or beneath it, so the shared roots are never among the keys
# derived from it; {install} opens the data, optionally quoted, and names an inventory file.
REGISTRATION_KEY = re.compile(r"Software\\Classes\\(CLSID|Interface)\\\{[0-9A-F]{8}(-[0-9A-F]{4}){3}-[0-9A-F]{12}\}"
                              r"(\\[^\\\x00-\x1f]+)*")
INSTALL_DATA = re.compile(r'("?)\{install\}\\([^"]+)\1')


def noctty_registration(values: object, files: dict[str, str]) -> list[dict]:
    """The HKCU String values of the default-terminal registration, each exactly {key, name,
    data}; name '' is the default value. No two share key and name without case."""
    if not isinstance(values, list) or not values:
        raise ValueError("No Noctty registration")
    seen = set()
    for value in values:
        if not isinstance(value, dict) or set(value) != {"key", "name", "data"} or \
                not all(isinstance(field, str) for field in value.values()):
            raise ValueError(f"Noctty registration value is not {{key, name, data}} strings: {value!r}")
        key, name, data = value["key"], value["name"], value["data"]
        install = INSTALL_DATA.fullmatch(data)
        if (not REGISTRATION_KEY.fullmatch(key) or not data or re.search(r"[\x00-\x1f]", name + data)
                or "{install}" in key + name or ("{install}" in data and not install)
                or (install and install.group(2).replace("\\", "/") not in files)):
            raise ValueError(f"Invalid Noctty registration value: {key} [{name}]")
        if (key.casefold(), name.casefold()) in seen:
            raise ValueError(f"Duplicate Noctty registration value: {key} [{name}]")
        seen.add((key.casefold(), name.casefold()))
    return values


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


def seed_preferences(seed: dict, entries: list[dict]) -> bytes:
    """The seed's bytes: exactly the six font preferences, each role's family from fonts.json,
    as compact sorted UTF-8 JSON with one trailing newline, so equal inputs give equal bytes."""
    families = {e["role"]: e["family"] for e in entries}
    for role in seed["fonts"].values():
        if role not in families:
            raise ValueError(f"Seed font role is not selected by common fonts: {role!r}")
    fonts = {generic: {script: families[seed["fonts"][role]] for script in SEED_SCRIPTS}
             for generic, role in SEED_GENERICS.items()}
    document = {"webkit": {"webprefs": {"fonts": fonts}}}
    return (json.dumps(document, ensure_ascii=False, sort_keys=True, separators=(",", ":")) + "\n").encode("utf-8")


def distribution(fonts: Path, noctty: Path, cloudflared: Path, choices: Path,
                 scripts: Path, source: str, out: Path) -> None:
    out.mkdir(parents=True, exist_ok=True)
    selected = json.loads(choices.read_text(encoding="utf-8"))
    if not selected.get("cloudflared", {}).get("version"):
        raise ValueError("No cloudflared version selected")
    if not cloudflared.read_bytes().startswith(b"MZ"):
        raise ValueError("cloudflared payload is not a Windows executable")
    if selected["noctty"]["fontFamily"] not in {e["family"] for e in json.loads((fonts / "fonts.json").read_text(encoding="utf-8"))}:
        raise ValueError("Noctty font is not selected by common fonts")
    noctty_files = noctty_inventory(noctty)
    registration = noctty_registration(selected["noctty"].get("registration"), noctty_files)
    packages = inventoried(selected.get("packages"))
    with tempfile.TemporaryDirectory() as temporary:
        root = Path(temporary)
        shutil.copytree(fonts / "share", root / "share")
        entries = json.loads((fonts / "fonts.json").read_text(encoding="utf-8"))
        if not entries:
            raise ValueError("Empty font payload")
        for name in ("win.ps1", "proof.ps1", "handoff-proof.ps1", "handoff-evaluate.ps1",
                     "package-view.ps1", "README.md"):
            shutil.copyfile(scripts / name, root / name)
        (root / "payload").mkdir()
        shutil.copyfile(noctty, root / "payload/noctty.zip")
        # The pinned official client, installed only by the explicit RentSsh mode, never by Restore.
        shutil.copyfile(cloudflared, root / "payload/cloudflared.exe")
        # A seed ships as a bundle file; the manifest names where it goes and what it holds.
        for package in packages:
            if "seed" in package:
                data = seed_preferences(package["seed"], entries)
                seed_file = f"payload/{package['name'].casefold()}/{SEED_NAME}"
                (root / seed_file).parent.mkdir()
                (root / seed_file).write_bytes(data)
                package["seed"] = {"path": package["seed"]["path"], "file": seed_file,
                                   "sha256": hashlib.sha256(data).hexdigest(), "size": len(data)}
        files = {p.relative_to(root).as_posix(): digest(p) for p in sorted(root.rglob("*")) if p.is_file()}
        write_json(root / "manifest.json", {"schemaVersion": 3, "source": source, "fonts": entries,
                   "noctty": {"version": selected["noctty"]["version"],
                              "fontFamily": selected["noctty"]["fontFamily"],
                              "files": noctty_files, "registration": registration},
                   "cloudflared": {"version": selected["cloudflared"]["version"], "file": "payload/cloudflared.exe",
                                   "sha256": files["payload/cloudflared.exe"]},
                   "packages": packages, "files": files})
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
    for argument in ("fonts", "noctty", "cloudflared", "choices", "scripts"):
        dist_parser.add_argument(argument, type=Path)
    dist_parser.add_argument("source")
    dist_parser.add_argument("out", type=Path)
    listing_parser = sub.add_parser("listing")
    listing_parser.add_argument("listing", type=Path)
    inventory_parser = sub.add_parser("inventory")
    for argument in ("lock", "archive", "listing", "tree", "out"):
        inventory_parser.add_argument(argument, type=Path)
    args = parser.parse_args()
    if args.command == "fonts":
        prepare_fonts(json.loads(args.policy.read_text()), args.out)
    elif args.command == "listing":
        listed_paths(args.listing.read_text(encoding="utf-8"))
    elif args.command == "inventory":
        package_inventory(args.lock, args.archive, args.listing, args.tree, args.out)
    else:
        distribution(args.fonts, args.noctty, args.cloudflared, args.choices,
                     args.scripts, args.source, args.out)
