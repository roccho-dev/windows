"""Compile pinned Windows selections into a portable, deterministic distribution.

This module does not choose products, versions, URLs, or host/site values.
Those inputs belong to nix.nix; Windows effects belong to win.ps1, the native
activation adapter.
"""
from __future__ import annotations

import argparse
import hashlib
import io
import json
from pathlib import Path, PurePosixPath
import re
import shutil
import tempfile
import zipfile
import xml.etree.ElementTree as ET

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


def typography(value: object, entries: list[dict], packages: list[dict]) -> dict | None:
    """The desktop UI font face win.ps1 sets through ui-font.ahk: {desktop: <role>, interpreter:
    <package name>} becomes {face: <that role's family>, interpreter, script}. The face fits a
    LOGFONTW lfFaceName (1 to 31 UTF-16 units, no control or surrogate), as Test-UiFontFace checks."""
    if value is None:
        return None
    if not isinstance(value, dict) or set(value) != {"desktop", "interpreter"}:
        raise ValueError("typography is not {desktop, interpreter}")
    families = {e["role"]: e["family"] for e in entries}
    if value["desktop"] not in families:
        raise ValueError(f"typography role is not selected by common fonts: {value['desktop']!r}")
    face = families[value["desktop"]]
    units = len(face.encode("utf-16-le")) // 2
    # A str holds code points, so a character beyond the BMP is caught by ord, not by a surrogate range.
    if not 1 <= units <= 31 or re.search(r"[\x00-\x1f\x7f\ud800-\udfff]", face) or any(ord(c) > 0xFFFF for c in face):
        raise ValueError(f"typography face does not fit a LOGFONTW: {face!r}")
    if [p["name"] for p in packages].count(value["interpreter"]) != 1:
        raise ValueError(f"typography interpreter is not one locked package: {value['interpreter']!r}")
    return {"face": face, "interpreter": value["interpreter"], "script": "ui-font.ahk"}


APP_KEYS = {"name", "source", "id", "package", "publisherId"}
APP_FONTS = ("ui", "code", "content")
THEME_KEYS = {"accent", "accentSource", "contrast", "ink", "opaqueWindows", "surface", "semanticColors"}
THEME_COLORS = ("accent", "ink", "surface")
SEMANTIC_COLORS = {"diffAdded", "diffRemoved", "skill"}
HEX_COLOR = re.compile(r"#[0-9a-fA-F]{6}")


def appearance(value: object, entries: list[dict]) -> dict:
    """An app's font preconfiguration: {fonts: {ui, code, content: <role>}, defaults: {light, dark}}
    becomes {fonts: {ui, code, content: '"<family>"'}, defaults}. Each default is a complete theme
    as the app's schema requires one (win.ps1 Get-AppThemeProblem holds the same rule), fonts aside."""
    if not isinstance(value, dict) or set(value) != {"fonts", "defaults"}:
        raise ValueError("appearance is not {fonts, defaults}")
    families = {e["role"]: e["family"] for e in entries}
    fonts = value["fonts"]
    if not isinstance(fonts, dict) or set(fonts) != set(APP_FONTS) or any(fonts[k] not in families for k in APP_FONTS):
        raise ValueError(f"appearance fonts are not ui, code and content of selected roles: {fonts!r}")
    if any(re.search(r'["\\\x00-\x1f]', families[fonts[k]]) for k in APP_FONTS):
        raise ValueError("an appearance font family cannot be one quoted CSS family")
    css = {k: f'"{families[fonts[k]]}"' for k in APP_FONTS}
    defaults = value["defaults"]
    if not isinstance(defaults, dict) or set(defaults) != {"light", "dark"}:
        raise ValueError("appearance defaults are not light and dark")
    for name, theme in defaults.items():
        semantic = theme.get("semanticColors") if isinstance(theme, dict) else None
        if not isinstance(theme, dict) or set(theme) != THEME_KEYS or \
                not all(isinstance(theme[k], str) and HEX_COLOR.fullmatch(theme[k]) for k in THEME_COLORS) or \
                theme["accentSource"] not in ("chatgpt", "custom") or \
                type(theme["contrast"]) is not int or not 0 <= theme["contrast"] <= 100 or \
                type(theme["opaqueWindows"]) is not bool or not isinstance(semantic, dict) or set(semantic) != SEMANTIC_COLORS or \
                not all(isinstance(c, str) and HEX_COLOR.fullmatch(c) for c in semantic.values()):
            raise ValueError(f"appearance default {name} is not a complete app theme")
    return {"fonts": css, "defaults": defaults}


def store_apps(value: object, entries: list[dict]) -> list[dict]:
    """Microsoft Store apps Restore installs when absent (official WinGet, msstore source, exact id)
    and otherwise only reads: the package family name's name and publisher id identify it. At most
    one app may carry an appearance: it writes the one Codex user config."""
    if value is None:
        return []
    if not isinstance(value, list):
        raise ValueError("apps is not a list")
    for app in value:
        if not isinstance(app, dict) or set(app) - {"appearance"} != APP_KEYS or app["source"] != "msstore" or \
                not all(isinstance(app[k], str) for k in APP_KEYS) or \
                not re.fullmatch(r"[0-9A-Z]{12}", app["id"]) or \
                not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9 .-]*", app["name"]) or \
                not TOKEN.fullmatch(app["package"]) or not re.fullmatch(r"[a-z0-9]{13}", app["publisherId"]):
            raise ValueError(f"App is not {sorted(APP_KEYS)} of a msstore id and package identity: {app!r}")
    for key in ("name", "id", "package"):
        if len({app[key].casefold() for app in value}) != len(value):
            raise ValueError(f"Two apps share a {key}")
    if sum("appearance" in app for app in value) > 1:
        raise ValueError("Two apps preconfigure the one Codex config")
    return [{**app, "appearance": appearance(app["appearance"], entries)} if "appearance" in app else app for app in value]


def winget_bootstrap(value: object) -> dict | None:
    """Pinned official x64 recovery metadata only; no fetched bootstrap bytes enter the bundle."""
    if value is None:
        return None
    if not isinstance(value, dict) or set(value) != {"architecture", "publisher", "publisherId", "bundle", "dependencies"}:
        raise ValueError("Invalid WinGet bootstrap shape")
    if value["architecture"] != "x64" or value["publisherId"] != "8wekyb3d8bbwe" or value["publisher"] != \
            "CN=Microsoft Corporation, O=Microsoft Corporation, L=Redmond, S=Washington, C=US":
        raise ValueError("WinGet bootstrap must select official Microsoft x64 packages")
    for key, suffix, extra in (("bundle", ".msixbundle", {"name", "version", "entry", "appVersion"}),
                               ("dependencies", ".zip", {"packages"})):
        asset = value[key]
        if not isinstance(asset, dict) or set(asset) != {"url", "size", "sha256"} | extra or not is_size(asset["size"]):
            raise ValueError(f"Invalid bootstrap {key} lock")
        hex_digest(asset["sha256"], 64, key)
        if not isinstance(asset["url"], str) or not re.fullmatch(
                r"https://github\.com/microsoft/winget-cli/releases/download/v[0-9.]+/[A-Za-z0-9_.-]+" + re.escape(suffix), asset["url"]):
            raise ValueError(f"Bootstrap {key} is not an official fixed release asset")
    bundle = value["bundle"]
    if bundle["name"] != "Microsoft.DesktopAppInstaller" or bundle["entry"] != "AppInstaller_x64.msix":
        raise ValueError("Bootstrap bundle must contain the x64 App Installer")
    packages = value["dependencies"]["packages"]
    if not isinstance(packages, list) or not packages:
        raise ValueError("Bootstrap dependencies are empty")
    names = set()
    for package in packages:
        if not isinstance(package, dict) or set(package) != {"name", "version", "entry"} or \
                not TOKEN.fullmatch(text(package["name"], "dependency name")) or package["name"] in names:
            raise ValueError("Invalid or duplicate bootstrap dependency")
        names.add(package["name"])
        if package["entry"] != f"x64/{package['name']}_{package['version']}_x64.appx":
            raise ValueError("Dependency entry does not match its locked identity")
    for version in [bundle["version"], bundle["appVersion"]] + [p["version"] for p in packages]:
        if not isinstance(version, str) or not re.fullmatch(r"[0-9]+(?:\.[0-9]+){3}", version):
            raise ValueError("Bootstrap version must have four numeric parts")
    return value


def verify_bootstrap(value: dict, bundle_path: Path, dependency_path: Path) -> None:
    """Build gate on actual locked archives, including nested manifests, never an extraction.
    Native signature/deployment checks remain Windows responsibilities."""
    winget_bootstrap(value)
    bundle, packages = value["bundle"], value["dependencies"]["packages"]
    for lock, path in ((bundle, bundle_path), (value["dependencies"], dependency_path)):
        verify_asset({"name": "WinGet bootstrap", **lock}, path)

    def xml(archive, entry):
        if archive.namelist().count(entry) != 1:
            raise ValueError(f"Bootstrap must contain exactly one {entry}")
        return ET.fromstring(archive.read(entry))

    def manifest(archive, expected, framework, dependencies):
        root = xml(archive, "AppxManifest.xml")
        identity = root.find("{*}Identity")
        wanted = {"Name": expected["name"], "Publisher": value["publisher"],
                  "Version": expected["version"], "ProcessorArchitecture": "x64"}
        actual_framework = root.find("{*}Properties/{*}Framework")
        if identity is None or identity.attrib != wanted or \
                (actual_framework is not None and actual_framework.text == "true") != framework:
            raise ValueError("Bootstrap inner identity/framework differs from lock")
        actual = [d.attrib for d in root.findall("{*}Dependencies/{*}PackageDependency")]
        wanted_deps = [{"Name": p["name"], "Publisher": value["publisher"], "MinVersion": p["version"]} for p in dependencies]
        if sorted(actual, key=lambda d: d.get("Name", "")) != sorted(wanted_deps, key=lambda d: d["Name"]):
            raise ValueError("Bootstrap inner dependency minima differ from lock")

    with zipfile.ZipFile(bundle_path) as archive:
        root = xml(archive, "AppxMetadata/AppxBundleManifest.xml")
        identity = root.find("{*}Identity")
        if identity is None or identity.attrib != {"Name": bundle["name"], "Publisher": value["publisher"], "Version": bundle["version"]}:
            raise ValueError("Bootstrap bundle identity differs from lock")
        application = [p for p in root.findall("{*}Packages/{*}Package") if p.get("Type") == "application" and p.get("Architecture") == "x64" and p.get("IsStub") != "true"]
        if len(application) != 1 or application[0].get("FileName") != bundle["entry"] or application[0].get("Version") != bundle["appVersion"]:
            raise ValueError("Bootstrap bundle x64 entry differs from lock")
        with zipfile.ZipFile(io.BytesIO(archive.read(bundle["entry"]))) as inner:
            manifest(inner, {"name": bundle["name"], "version": bundle["appVersion"]}, False, packages)
    with zipfile.ZipFile(dependency_path) as archive:
        for package in packages:
            with zipfile.ZipFile(io.BytesIO(archive.read(package["entry"]))) as inner:
                manifest(inner, package, True, [])


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


def wsl_platform(value: object) -> dict | None:
    if value is None:
        return None
    if not isinstance(value, dict):
        raise ValueError("WSL platform is not an object")
    guid = re.compile(r"\{[0-9A-F]{8}(?:-[0-9A-F]{4}){3}-[0-9A-F]{12}\}\Z")
    if (value.get("architecture") != "x64" or value.get("minimumBuild") != 26100
            or value.get("feature") != "VirtualMachinePlatform"
            or value.get("appxName") != "MicrosoftCorporationII.WindowsSubsystemForLinux"
            or value.get("publisherId") != "8wekyb3d8bbwe"
            or value.get("release") not in ("stable", "prerelease")
            or value.get("productName") != "Windows Subsystem for Linux"
            or value.get("manufacturer") != "Microsoft Corporation"
            or value.get("upgradeCode") != "{6D5B792B-1EDC-4DE9-8EAD-201B820F8E82}"
            or value.get("template") != "x64;1033"
            or value.get("publisher") != "CN=Microsoft Corporation, O=Microsoft Corporation, L=Redmond, S=Washington, C=US"
            or any(not isinstance(value.get(k), str) or not guid.fullmatch(value[k])
                   for k in ("productCode", "upgradeCode", "packageCode"))
            or any(not isinstance(value.get(k), str) or not re.fullmatch(r"[0-9]+(?:\.[0-9]+){3}", value[k])
                   for k in ("version", "minimumVersion"))
            or not isinstance(value.get("url"), str)
            or not value["url"].startswith("https://github.com/microsoft/WSL/releases/download/")
            or not value["url"].endswith(".x64.msi")
            or type(value.get("size")) is not int or not 0 < value["size"] <= MAX_SIZE
            or not isinstance(value.get("sha256"), str) or not re.fullmatch(r"[0-9a-f]{64}", value["sha256"])):
        raise ValueError("Invalid supported WSL platform lock")
    return dict(value)


def verify_platform(lock: object, asset: Path) -> None:
    selected = wsl_platform(lock)
    if selected is None:
        raise ValueError("Missing WSL platform lock")
    verify_asset({"name": selected["productName"], **selected}, asset)
    with asset.open("rb") as stream:
        if stream.read(8) != bytes.fromhex("d0cf11e0a1b11ae1"):
            raise ValueError("WSL installer is not an MSI compound document")


def noctty_launch(value: object) -> dict:
    """Bounded existing-session shell selection; no startup/create fallback."""
    if (not isinstance(value, dict) or set(value) != {"session", "container", "shell", "windowSaveState"}
            or any(not isinstance(value.get(k), str) or not re.fullmatch(r"[a-z0-9][a-z0-9-]+", value[k])
                   for k in ("session", "container"))
            or value.get("shell") != "/bin/sh" or value.get("windowSaveState") != "never"):
        raise ValueError("Invalid Noctty existing-session shell selection")
    return dict(value)


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
    launch = noctty_launch(selected["noctty"].get("launch"))
    packages = inventoried(selected.get("packages"))
    with tempfile.TemporaryDirectory() as temporary:
        root = Path(temporary)
        shutil.copytree(fonts / "share", root / "share")
        entries = json.loads((fonts / "fonts.json").read_text(encoding="utf-8"))
        if not entries:
            raise ValueError("Empty font payload")
        ui = typography(selected.get("typography"), entries, packages)
        apps = store_apps(selected.get("apps"), entries)
        bootstrap = winget_bootstrap(selected.get("wingetBootstrap"))
        platform = wsl_platform(selected.get("wslPlatform"))
        if apps and bootstrap is None:
            raise ValueError("Declared Store apps require absent-AppInstaller recovery metadata")
        for name in ("win.ps1", "proof.ps1", "handoff-proof.ps1", "handoff-evaluate.ps1",
                     "package-view.ps1", "ui-font.ahk", "README.md"):
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
                              "launch": launch,
                              "files": noctty_files, "registration": registration},
                   "cloudflared": {"version": selected["cloudflared"]["version"], "file": "payload/cloudflared.exe",
                                   "sha256": files["payload/cloudflared.exe"]},
                   "packages": packages, "typography": ui, "apps": apps, "wingetBootstrap": bootstrap, "wslPlatform": platform, "files": files})
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
    bootstrap_parser = sub.add_parser("bootstrap")
    for argument in ("lock", "bundle", "dependencies"):
        bootstrap_parser.add_argument(argument, type=Path)
    platform_parser = sub.add_parser("platform")
    for argument in ("lock", "asset"):
        platform_parser.add_argument(argument, type=Path)
    args = parser.parse_args()
    if args.command == "fonts":
        prepare_fonts(json.loads(args.policy.read_text()), args.out)
    elif args.command == "listing":
        listed_paths(args.listing.read_text(encoding="utf-8"))
    elif args.command == "inventory":
        package_inventory(args.lock, args.archive, args.listing, args.tree, args.out)
    elif args.command == "bootstrap":
        verify_bootstrap(json.loads(args.lock.read_text(encoding="utf-8")), args.bundle, args.dependencies)
    elif args.command == "platform":
        verify_platform(json.loads(args.lock.read_text(encoding="utf-8")), args.asset)
    else:
        distribution(args.fonts, args.noctty, args.cloudflared, args.choices,
                     args.scripts, args.source, args.out)
