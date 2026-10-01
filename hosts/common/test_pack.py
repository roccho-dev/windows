"""Compiler tests; native Windows convergence is deliberately a separate proof."""
import json
import io
from pathlib import Path
import tempfile
import unittest
import zipfile

from fontTools.fontBuilder import FontBuilder
from fontTools.pens.ttGlyphPen import TTGlyphPen

import pack

WSL_LOCK = {
    "architecture": "x64", "minimumBuild": 26100, "minimumVersion": "2.9.3.0", "feature": "VirtualMachinePlatform",
    "appxName": "MicrosoftCorporationII.WindowsSubsystemForLinux", "publisherId": "8wekyb3d8bbwe",
    "url": "https://github.com/microsoft/WSL/releases/download/2.9.13/wsl.2.9.13.0.x64.msi",
    "size": 367693824, "sha256": "a00b0010f802ac461aaf44374b6ecbeae4b620453a77565f31eade5737e8af55",
    "release": "prerelease", "version": "2.9.13.0", "productCode": "{861425A4-7173-4B0D-8EC1-7A94FD333418}",
    "upgradeCode": "{6D5B792B-1EDC-4DE9-8EAD-201B820F8E82}", "packageCode": "{10B09957-0F00-4852-B522-8E6EDB50249B}",
    "productName": "Windows Subsystem for Linux", "manufacturer": "Microsoft Corporation", "template": "x64;1033",
    "publisher": "CN=Microsoft Corporation, O=Microsoft Corporation, L=Redmond, S=Washington, C=US",
}

PROXY = "{1D349824-21FB-46C7-ACF3-746EDC991D52}"
# The six values nix.nix declares (CI #58 G4).
REGISTRATION = [
    {"key": "Software\\Classes\\CLSID\\{33368C6F-D328-410C-B225-26DC9F12C728}\\LocalServer32", "name": "",
     "data": '"{install}\\noctty\\noctty.exe"'},
    {"key": f"Software\\Classes\\CLSID\\{PROXY}\\InprocServer32", "name": "",
     "data": "{install}\\noctty\\noctty-terminal-handoff-proxy.dll"},
    {"key": f"Software\\Classes\\CLSID\\{PROXY}\\InprocServer32", "name": "ThreadingModel", "data": "Both"},
] + [{"key": f"Software\\Classes\\Interface\\{iid}\\ProxyStubClsid32", "name": "", "data": PROXY}
     for iid in ("{59D55CCE-FC8A-48B4-ACE8-0A9286C6557F}", "{6F23DA90-15C5-4203-9DB0-64E73F1B1B00}",
                 "{AA6B364F-4A50-4176-9002-0AE755E7B5EF}")]


class CompilerTests(unittest.TestCase):
    def test_platform_bytes_and_supported_scope(self):
        self.assertEqual(pack.wsl_platform(WSL_LOCK), WSL_LOCK)
        self.assertIsNone(pack.wsl_platform(None))
        for key, value in (("architecture", "arm64"), ("minimumBuild", 19041), ("feature", "Other"),
                           ("productCode", "bad"), ("publisher", "Other"), ("size", True), ("minimumVersion", "2.9")):
            with self.subTest(key=key), self.assertRaises(ValueError):
                pack.wsl_platform(dict(WSL_LOCK, **{key: value}))
        path = self.root / "fixture.msi"
        path.write_bytes(bytes.fromhex("d0cf11e0a1b11ae1") + b"synthetic")
        lock = dict(WSL_LOCK, size=path.stat().st_size, sha256=pack.digest(path))
        pack.verify_platform(lock, path)
        with self.assertRaises(ValueError):
            pack.verify_platform(dict(lock, size=lock["size"] + 1), path)
        path.write_bytes(b"not MSI")
        with self.assertRaisesRegex(ValueError, "not an MSI"):
            pack.verify_platform(dict(lock, size=path.stat().st_size, sha256=pack.digest(path)), path)

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)

    def font(self, name="Test Font", filename="input.ttf", family=None, typographic=None, folder="upstream"):
        builder = FontBuilder(1000, isTTF=True)
        builder.setupGlyphOrder([".notdef", "space"])
        builder.setupCharacterMap({32: "space"})
        builder.setupGlyf({name: TTGlyphPen(None).glyph() for name in (".notdef", "space")})
        builder.setupHorizontalMetrics({name: (500, 0) for name in (".notdef", "space")})
        builder.setupHorizontalHeader(ascent=800, descent=-200)
        names = {"familyName": family or name, "styleName": "Regular", "fullName": name,
                 "uniqueFontIdentifier": name, "psName": name.replace(" ", "")}
        if typographic:
            names["typographicFamily"] = typographic
        builder.setupNameTable(names)
        builder.setupOS2(sTypoAscender=800, sTypoDescender=-200, usWinAscent=800, usWinDescent=200)
        builder.setupPost()
        source = self.root / folder
        source.mkdir(exist_ok=True)
        builder.save(source / filename)
        (source / "OFL.txt").write_text("Synthetic test license, not a redistributed font.")
        return {"role": "fixture", "family": name, "version": "1", "directory": str(source), "licenseSource": str(source)}

    def payload(self):
        policy = self.font()
        out = self.root / "fonts"
        pack.prepare_fonts([policy], out)
        return out

    def test_font_bytes_names_and_license(self):
        fonts = self.payload()
        entry, = json.loads((fonts / "fonts.json").read_text())
        self.assertEqual(entry["fullName"], "Test Font")
        path = fonts / "share/fonts/truetype" / entry["file"]
        self.assertEqual(pack.digest(path), entry["sha256"])
        self.assertEqual(entry["file"], entry["sha256"] + ".ttf")
        self.assertTrue(list((fonts / "share/licenses/fixture").iterdir()))

    def test_missing_license_fails(self):
        policy = self.font()
        (Path(policy["licenseSource"]) / "OFL.txt").unlink()
        with self.assertRaisesRegex(ValueError, "license"):
            pack.prepare_fonts([policy], self.root / "fonts")

    def test_empty_selection_fails(self):
        with self.assertRaisesRegex(ValueError, "empty"):
            pack.prepare_fonts([], self.root / "fonts")

    def test_duplicate_full_name_fails(self):
        policy = self.font()
        self.font(filename="duplicate.ttf")
        with self.assertRaisesRegex(ValueError, "duplicate"):
            pack.prepare_fonts([policy], self.root / "fonts")

    def test_every_role_file_is_the_declared_family(self):
        # A weight whose name ID 1 is "<family> Light" belongs by its typographic family (name ID 16).
        policy = self.font()
        self.font(name="Test Font Light", filename="light.ttf", family="Test Font Light", typographic="Test Font")
        pack.prepare_fonts([policy], self.root / "fonts")
        for case, (family, typographic) in {"name ID 1": ("Test Font Mono", None),
                                            "name ID 16 wins": ("Test Font", "Other Font")}.items():
            self.font(name="Odd", filename="odd.ttf", family=family, typographic=typographic)  # replaces the last
            with self.subTest(case=case), self.assertRaisesRegex(ValueError, "Font family"):
                pack.prepare_fonts([policy], self.root / f"fonts-{case}")

    def test_unsafe_paths_fail(self):
        for name in ("", "../escape", "/absolute", "C:/drive", "dir\\escape", "a/../../escape"):
            with self.subTest(name=name), self.assertRaises(ValueError):
                pack.relative(name)

    def test_archive_case_collision_fails(self):
        source = self.root / "tree"
        source.mkdir()
        for name in ("File", "file"):
            (source / name).write_text("x")
        with self.assertRaisesRegex(ValueError, "collision"):
            pack.archive(source, self.root / "test.zip")

    def lock(self, **changes):
        lock = {"name": "Fixture", "version": "1.0",
                "url": "https://github.com/example/fixture/releases/download/v1.0/fixture.zip",
                "format": "zip", "size": 1, "sha256": "0" * 64, "scope": "user",
                "effect": "tree-extracted", "directory": "Programs/fixture-1.0",
                "executable": "bin/fixture.exe",
                "existing": {"uninstallKey": "Fixture", "displayName": "Fixture", "publisher": "Example",
                             "installLocation": "Fixture/Application", "executable": "fixture.exe"},
                "protected": ["Fixture/User Data"]}
        lock.update(changes)
        return lock

    def existing(self, **changes):
        existing = dict(self.lock()["existing"])
        existing.update(changes)
        return existing

    def test_package_lock_contract(self):
        self.assertEqual(pack.package_locks([self.lock()]), [self.lock()])
        self.assertEqual(pack.package_locks([self.lock(sha1="0" * 40)]), [self.lock(sha1="0" * 40)])
        self.assertEqual(pack.package_locks([self.lock(size=pack.MAX_SIZE)]), [self.lock(size=pack.MAX_SIZE)])
        bad = {
            "empty": [],
            "not a list": {"packages": []},
            "duplicate": [self.lock(), self.lock()],
            "extra key": [self.lock(id="Fixture.App")],
            "http": [self.lock(url="http://github.com/example/fixture/releases/download/v1.0/fixture.zip")],
            "not a release asset": [self.lock(url="https://example.com/fixture.zip")],
            "format mismatch": [self.lock(format="7z")],
            "list format": [self.lock(format=["zip"])],
            "installer": [self.lock(format="exe", url="https://github.com/e/f/releases/download/v1/f.exe")],
            "bool size": [self.lock(size=True)],
            "zero size": [self.lock(size=0)],
            "size above 2**53 - 1": [self.lock(size=2**53)],
            "short sha": [self.lock(sha256="b63be7548792b4ad0dfe424d91cc693b478")],
            "upper sha": [self.lock(sha256="A" * 64)],
            "int sha": [self.lock(sha256=1)],
            "short sha1": [self.lock(sha1="0" * 39)],
            "int name": [self.lock(name=1)],
            "slash name": [self.lock(name="a/b", directory="Programs/a/b-1.0")],
            "version traversal": [self.lock(version="1/..", directory="Programs/fixture-1/..")],
            "version with a dash": [self.lock(version="1.0-rc1", directory="Programs/fixture-1.0-rc1")],
            "version not a digit first": [self.lock(version="v1.0", directory="Programs/fixture-v1.0")],
            "machine scope": [self.lock(scope="machine")],
            "other effect": [self.lock(effect="registry-value")],
            "escape": [self.lock(directory="Programs/../fixture-1.0")],
            "unowned path": [self.lock(directory="Programs/other-1.0")],
            "executable escape": [self.lock(executable="../fixture.exe")],
            "reserved executable": [self.lock(executable="bin/NUL.txt")],
            "trailing dot protected": [self.lock(protected=["Fixture/User Data."])],
            "no existing identity": [self.lock(existing={})],
            "empty publisher": [self.lock(existing=self.existing(publisher=""))],
            "uninstall key path": [self.lock(existing=self.existing(uninstallKey="A\\B"))],
            "inside existing install": [self.lock(existing=self.existing(installLocation="Programs"))],
            "protected not a list": [self.lock(protected="Fixture/User Data")],
            "owns protected data": [self.lock(protected=["programs/FIXTURE-1.0/User Data"])],
        }
        for case, packages in bad.items():
            with self.subTest(case=case), self.assertRaises(ValueError):
                pack.package_locks(packages)

    SEED = {"path": "bin/initial_preferences", "fonts": {"proportional": "fixture", "fixed": "fixture"}}

    def seed(self, **changes):
        seed = {"path": self.SEED["path"], "fonts": dict(self.SEED["fonts"])}
        seed.update(changes)
        return seed

    def test_app_path_lock_contract(self):
        for app_path in ("fixture.exe", "Chromium.exe", "a-b_c.1.exe", "9.exe"):
            with self.subTest(app_path=app_path):
                self.assertEqual(pack.package_locks([self.lock(appPath=app_path)]), [self.lock(appPath=app_path)])
        other = {"name": "Other", "directory": "Programs/other-1.0"}
        self.assertEqual(len(pack.package_locks([self.lock(appPath="fixture.exe"), self.lock(appPath="other.exe", **other)])), 2)
        for app_path in ("fixture", "fixture.EXE", "fixture.exe ", " fixture.exe", "fixture.exe\n", ".exe", "-fixture.exe",
                         "a/fixture.exe", "a\\fixture.exe", "../fixture.exe", "fixture.exe.", "con.exe", "NUL.exe", "fix ture.exe",
                         "fixture.exe/", "fixture.cmd", "", 1, None, ["fixture.exe"]):
            with self.subTest(app_path=app_path), self.assertRaises(ValueError):
                pack.package_locks([self.lock(appPath=app_path)])
        # One App Paths name per lock, without case: two locks may not share it.
        with self.assertRaisesRegex(ValueError, "appPath"):
            pack.package_locks([self.lock(appPath="Fixture.exe"), self.lock(appPath="fixture.exe", **other)])

    def test_app_path_reaches_the_manifest_but_not_the_inventory(self):
        fonts = self.payload()
        noctty, cloudflared, choices, scripts = self.inputs()
        self.with_packages(choices, self.lock(appPath="fixture.exe", inventory=str(self.inventory())))
        pack.distribution(fonts, noctty, cloudflared, choices, scripts, "test", self.root / "out")
        with zipfile.ZipFile(self.root / "out" / "windows-dist.zip") as z:
            package, = json.loads(z.read("manifest.json"))["packages"]
        self.assertEqual(package["appPath"], "fixture.exe")
        self.assertEqual(package["files"], {"bin/fixture.exe": "1" * 64})
        self.assertEqual(package, self.lock(appPath="fixture.exe", files={"bin/fixture.exe": "1" * 64}, unpackedSize=10))

    def test_seed_lock_contract(self):
        self.assertEqual(pack.package_locks([self.lock(seed=self.seed())]), [self.lock(seed=self.seed())])
        bad = {
            "not a dict": "bin/initial_preferences",
            "extra key": self.seed(file="payload/x"),
            "no fonts": {"path": "bin/initial_preferences"},
            "fonts not a dict": self.seed(fonts="fixture"),
            "a font key missing": self.seed(fonts={"proportional": "fixture"}),
            "an extra font key": self.seed(fonts={**self.SEED["fonts"], "serif": "fixture"}),
            "empty role": self.seed(fonts={"proportional": "", "fixed": "fixture"}),
            "role not a string": self.seed(fonts={"proportional": 1, "fixed": "fixture"}),
            "not beside the executable": self.seed(path="initial_preferences"),
            "deeper than the executable": self.seed(path="bin/x/initial_preferences"),
            "legacy name": self.seed(path="bin/master_preferences"),
            "other case": self.seed(path="bin/Initial_Preferences"),
            "other name": self.seed(path="bin/preferences.json"),
            "escape": self.seed(path="bin/../bin/initial_preferences"),
            "not a Windows path": self.seed(path="bin/initial_preferences."),
        }
        for case, seed in bad.items():
            with self.subTest(case=case), self.assertRaisesRegex(ValueError, "seed|Not a Windows path|Unsafe"):
                pack.package_locks([self.lock(seed=seed)])

    def test_windows_paths(self):
        for name in ("bin/fixture.exe", "Chrome-bin/154.0.8037.58/chrome.dll", "a/.hidden", "nul-free/aux2"):
            self.assertEqual(pack.windows_path(name), name)
        for name in ("a.", "a ", "dir./b", "NUL", "NUL.txt", "x/aux", "com1.log", "LPT9", "a<b", 'a"b', "a|b",
                     "a?b", "a*b", "a:b", "a\x01b", "a/./b", "a//b", "../a", "/a", ""):
            with self.subTest(name=name), self.assertRaises(ValueError):
                pack.windows_path(name)

    def test_asset_must_match_lock(self):
        asset = self.root / "asset"
        asset.write_bytes(b"abc")
        good = self.lock(size=3, sha256=pack.hashlib.sha256(b"abc").hexdigest(),
                         sha1=pack.hashlib.sha1(b"abc").hexdigest())
        pack.verify_asset(good, asset)
        for change in ({"size": 4}, {"sha256": "0" * 64}, {"sha1": "0" * 40}):
            with self.subTest(change=change), self.assertRaisesRegex(ValueError, "differs"):
                pack.verify_asset({**good, **change}, asset)

    def test_listing_paths(self):
        listing = ("--\nPath = /nix/store/x-fixture.zip\nType = zip\n\n----------\n"
                   "Path = bin\nFolder = +\n\nPath = bin/fixture.exe\nFolder = -\n")
        self.assertEqual(pack.listed_paths(listing), ["bin", "bin/fixture.exe"])
        for case, text in {"no separator": "Path = bin/fixture.exe\n",
                           "empty": "--\n----------\n",
                           "traversal": "--\n----------\nPath = ../fixture.exe\n",
                           "absolute": "--\n----------\nPath = /fixture.exe\n",
                           "trailing dot": "--\n----------\nPath = a.\n",
                           "reserved": "--\n----------\nPath = bin/NUL.txt\n",
                           "invalid character": "--\n----------\nPath = a<b\n",
                           "case duplicate": "--\n----------\nPath = A\n\nPath = a\n"}.items():
            with self.subTest(case=case), self.assertRaises(ValueError):
                pack.listed_paths(text)

    def extracted(self):
        tree = self.root / "tree"
        (tree / "bin").mkdir(parents=True)
        (tree / "bin/fixture.exe").write_bytes(b"MZ fixture")
        (tree / "readme").write_text("fixture")
        return tree

    def test_tree_inventory(self):
        tree = self.extracted()
        # "bin" is not listed itself, as in a zip without directory entries.
        files = pack.tree_inventory(tree, ["bin/fixture.exe", "readme"], "bin/fixture.exe")
        self.assertEqual(files, {"bin/fixture.exe": pack.digest(tree / "bin/fixture.exe"),
                                 "readme": pack.digest(tree / "readme")})
        with self.assertRaisesRegex(ValueError, "unlisted"):
            pack.tree_inventory(tree, ["bin/fixture.exe"], "bin/fixture.exe")
        with self.assertRaisesRegex(ValueError, "lacks"):
            pack.tree_inventory(tree, ["bin/fixture.exe", "readme"], "bin/other.exe")
        (tree / "bin/empty/deeper").mkdir(parents=True)
        with self.assertRaisesRegex(ValueError, "without files"):
            pack.tree_inventory(tree, ["bin/fixture.exe", "bin/empty/deeper", "readme"], "bin/fixture.exe")

    def test_tree_inventory_rejects_symlink(self):
        tree = self.extracted()
        try:
            (tree / "link").symlink_to(tree / "readme")
        except OSError:
            self.skipTest("symlinks unavailable")
        with self.assertRaisesRegex(ValueError, "Symlink"):
            pack.tree_inventory(tree, ["bin/fixture.exe", "readme", "link"], "bin/fixture.exe")

    def test_package_inventory_command(self):
        tree = self.extracted()
        asset = self.root / "fixture.zip"
        asset.write_bytes(b"archive bytes")
        lock_path, listing, out = self.root / "lock.json", self.root / "listing.txt", self.root / "inventory.json"
        lock_path.write_text(json.dumps(self.lock(size=13, sha256=pack.digest(asset))))
        listing.write_text("--\n----------\nPath = bin/fixture.exe\n\nPath = readme\n")
        pack.package_inventory(lock_path, asset, listing, tree, out)
        self.assertEqual(json.loads(out.read_text()),
                         {"files": pack.tree_inventory(tree, ["bin/fixture.exe", "readme"], "bin/fixture.exe"),
                          "unpackedSize": len(b"MZ fixture") + len(b"fixture")})
        lock_path.write_text(json.dumps(self.lock(size=13)))
        with self.assertRaisesRegex(ValueError, "differs"):
            pack.package_inventory(lock_path, asset, listing, tree, out)

    def inventory(self, files=None, size=10, raw=None):
        # One file per call: several cases are built before any of them is read.
        path = self.root / f"inventory-{len(list(self.root.glob('inventory-*.json')))}.json"
        files = {"bin/fixture.exe": "1" * 64} if files is None else files
        path.write_text(json.dumps({"files": files, "unpackedSize": size} if raw is None else raw))
        return path

    def inputs(self):
        noctty = self.root / "noctty.zip"
        with zipfile.ZipFile(noctty, "w") as z:
            z.writestr("noctty/noctty.exe", "fixture application")
            z.writestr("noctty/noctty.com", "fixture console entry")
            z.writestr("noctty/noctty-terminal-handoff-proxy.dll", "fixture handoff proxy")
        cloudflared = self.root / "cloudflared.exe"
        cloudflared.write_bytes(b"MZ fixture: not the real client")
        choices = self.root / "choices.json"
        choices.write_text(json.dumps({"noctty": {"version": "1.0", "fontFamily": "Test Font",
                                                  "registration": REGISTRATION},
                                       "cloudflared": {"version": "2.0"},
                                       "wingetBootstrap": self.bootstrap(),
                                       "packages": [self.lock(inventory=str(self.inventory()))]}))
        scripts = self.root / "scripts"
        scripts.mkdir(exist_ok=True)
        for name in ("win.ps1", "proof.ps1", "handoff-proof.ps1", "handoff-evaluate.ps1",
                     "package-view.ps1", "ui-font.ahk", "README.md"):
            (scripts / name).write_text("fixture")
        return noctty, cloudflared, choices, scripts

    APP = {"name": "ChatGPT", "source": "msstore", "id": "9PLM9XGG6VKS", "package": "OpenAI.Codex",
           "publisherId": "2p2nqsd0c76g0"}

    def bootstrap(self):
        return {"architecture": "x64", "publisherId": "8wekyb3d8bbwe",
                "publisher": "CN=Microsoft Corporation, O=Microsoft Corporation, L=Redmond, S=Washington, C=US",
                "bundle": {"url": "https://github.com/microsoft/winget-cli/releases/download/v1.2.3/installer.msixbundle",
                           "size": 10, "sha256": "1" * 64, "name": "Microsoft.DesktopAppInstaller",
                           "version": "2026.917.151.0", "entry": "AppInstaller_x64.msix", "appVersion": "1.29.380.0"},
                "dependencies": {"url": "https://github.com/microsoft/winget-cli/releases/download/v1.2.3/dependencies.zip",
                                 "size": 10, "sha256": "2" * 64, "packages": [
                                     {"name": "Microsoft.VCLibs.140.00", "version": "14.0.33519.0",
                                      "entry": "x64/Microsoft.VCLibs.140.00_14.0.33519.0_x64.appx"}]}}

    def test_bootstrap_archive_identity_not_filename_only(self):
        lock = self.bootstrap()
        publisher = lock["publisher"]
        package = lock["dependencies"]["packages"][0]

        def archive(entries):
            output = io.BytesIO()
            with zipfile.ZipFile(output, "w") as z:
                for name, contents in entries.items():
                    z.writestr(name, contents)
            return output.getvalue()

        def manifest(name, version, framework=False, dependencies="", arch="x64"):
            return f'<Package><Identity Name="{name}" Version="{version}" Publisher="{publisher}" ProcessorArchitecture="{arch}"/>' \
                   f'<Properties><Framework>{str(framework).lower()}</Framework></Properties><Dependencies>{dependencies}</Dependencies></Package>'

        dependency = f'<PackageDependency Name="{package["name"]}" MinVersion="{package["version"]}" Publisher="{publisher}"/>'
        bundle_xml = f'<Bundle><Identity Name="Microsoft.DesktopAppInstaller" Publisher="{publisher}" Version="2026.917.151.0"/>' \
                     '<Packages><Package Type="application" Architecture="x64" Version="1.29.380.0" FileName="AppInstaller_x64.msix"/>' \
                     '<Package Type="application" Architecture="x64" Version="1.29.379.0" FileName="stub.msix" IsStub="true"/></Packages></Bundle>'
        deps = self.root / "dependencies.zip"
        deps.write_bytes(archive({package["entry"]: archive({"AppxManifest.xml": manifest(package["name"], package["version"], True)})}))
        lock["dependencies"].update(size=deps.stat().st_size, sha256=pack.digest(deps))
        bundle = self.root / "installer.msixbundle"
        for arch in ("x64", "x86"):
            bundle.write_bytes(archive({"AppxMetadata/AppxBundleManifest.xml": bundle_xml, "AppInstaller_x64.msix":
                                       archive({"AppxManifest.xml": manifest("Microsoft.DesktopAppInstaller", "1.29.380.0", dependencies=dependency, arch=arch)})}))
            lock["bundle"].update(size=bundle.stat().st_size, sha256=pack.digest(bundle))
            if arch == "x64":
                pack.verify_bootstrap(lock, bundle, deps)
            else:
                with self.assertRaisesRegex(ValueError, "inner identity"):
                    pack.verify_bootstrap(lock, bundle, deps)
        lock["bundle"]["sha256"] = "0" * 64
        with self.assertRaisesRegex(ValueError, "differs"):
            pack.verify_bootstrap(lock, bundle, deps)

    def test_bootstrap_shape_and_metadata_only(self):
        good = self.bootstrap()
        self.assertEqual(pack.winget_bootstrap(good), good)
        for field, change in (("architecture", "arm64"), ("publisherId", "aaaaaaaaaaaaa"), ("publisher", "Other")):
            with self.subTest(field=field), self.assertRaises(ValueError):
                pack.winget_bootstrap({**good, field: change})
        for part, field, change in (("bundle", "appVersion", "1.2"), ("bundle", "version", "latest"),
                                    ("bundle", "entry", "AppInstaller_arm64.msix"), ("dependencies", "url", "https://example.com/a.zip")):
            with self.subTest(part=part, field=field), self.assertRaises(ValueError):
                pack.winget_bootstrap({**good, part: {**good[part], field: change}})
        fonts = self.payload()
        noctty, cloudflared, choices, scripts = self.inputs()
        pack.distribution(fonts, noctty, cloudflared, choices, scripts, "test", self.root / "out")
        with zipfile.ZipFile(self.root / "out/windows-dist.zip") as z:
            selected = json.loads(z.read("manifest.json"))
            self.assertEqual(selected["wingetBootstrap"], good)
            self.assertFalse(any(n.endswith((".msixbundle", ".appx", "dependencies.zip")) for n in z.namelist()))

    def test_typography_and_apps_reach_the_manifest(self):
        fonts = self.payload()
        noctty, cloudflared, choices, scripts = self.inputs()
        selected = json.loads(choices.read_text())
        selected["typography"] = {"desktop": "fixture", "interpreter": "Fixture"}
        selected["apps"] = [{**self.APP, "appearance": self.appearance()}]
        choices.write_text(json.dumps(selected))
        pack.distribution(fonts, noctty, cloudflared, choices, scripts, "test", self.root / "out")
        with zipfile.ZipFile(self.root / "out" / "windows-dist.zip") as z:
            manifest = json.loads(z.read("manifest.json"))
            self.assertIn("ui-font.ahk", manifest["files"])
        self.assertEqual(manifest["typography"], {"face": "Test Font", "interpreter": "Fixture", "script": "ui-font.ahk"})
        self.assertEqual(manifest["apps"], [{**self.APP, "appearance": {"fonts": {k: '"Test Font"' for k in ("ui", "code", "content")},
                                                                          "defaults": self.appearance()["defaults"]}}])
        # Without either, the manifest says so and win.ps1 converges neither.
        pack.distribution(fonts, noctty, cloudflared, *self.inputs()[2:], "test", self.root / "none")
        with zipfile.ZipFile(self.root / "none" / "windows-dist.zip") as z:
            manifest = json.loads(z.read("manifest.json"))
        self.assertIsNone(manifest["typography"])
        self.assertEqual(manifest["apps"], [])

    def test_typography_contract(self):
        entries = [{"role": "ui", "family": "IBM Plex Sans JP"}]
        packages = [{"name": "AutoHotkey"}]
        self.assertEqual(pack.typography({"desktop": "ui", "interpreter": "AutoHotkey"}, entries, packages),
                         {"face": "IBM Plex Sans JP", "interpreter": "AutoHotkey", "script": "ui-font.ahk"})
        self.assertEqual(pack.typography({"desktop": "ui", "interpreter": "AutoHotkey"},
                                         [{"role": "ui", "family": "x" * 31}], packages)["face"], "x" * 31)
        bad = {
            "not a dict": ("ui", entries),
            "extra key": ({"desktop": "ui", "interpreter": "AutoHotkey", "face": "x"}, entries),
            "unknown role": ({"desktop": "terminal", "interpreter": "AutoHotkey"}, entries),
            "unknown interpreter": ({"desktop": "ui", "interpreter": "Python"}, entries),
            "face too long": ({"desktop": "ui", "interpreter": "AutoHotkey"}, [{"role": "ui", "family": "x" * 32}]),
            "face beyond the BMP": ({"desktop": "ui", "interpreter": "AutoHotkey"}, [{"role": "ui", "family": "x\U0001F600"}]),
            "face with a control": ({"desktop": "ui", "interpreter": "AutoHotkey"}, [{"role": "ui", "family": "a\tb"}]),
        }
        for case, (value, fonts) in bad.items():
            with self.subTest(case=case), self.assertRaisesRegex(ValueError, "typography"):
                pack.typography(value, fonts, packages)

    # The app's own complete themes (26.928.1915.0 `jq`, with accentSource), as nix.nix declares them.
    THEMES = {"light": {"accent": "#339cff", "accentSource": "chatgpt", "contrast": 45, "ink": "#1a1c1f", "opaqueWindows": False,
                        "surface": "#ffffff", "semanticColors": {"diffAdded": "#00a240", "diffRemoved": "#ba2623", "skill": "#924ff7"}},
              "dark": {"accent": "#339cff", "accentSource": "chatgpt", "contrast": 60, "ink": "#ffffff", "opaqueWindows": False,
                       "surface": "#181818", "semanticColors": {"diffAdded": "#40c977", "diffRemoved": "#fa423e", "skill": "#ad7bf9"}}}

    def appearance(self, **changes):
        value = {"fonts": {"ui": "fixture", "content": "fixture", "code": "fixture"}, "defaults": json.loads(json.dumps(self.THEMES))}
        value.update(changes)
        return value

    def test_appearance_contract(self):
        entries = [{"role": "ui", "family": "IBM Plex Sans JP"}, {"role": "terminal", "family": "PlemolJP Console NF"}]
        good = self.appearance(fonts={"ui": "ui", "content": "ui", "code": "terminal"})
        self.assertEqual(pack.appearance(good, entries)["fonts"],
                         {"ui": '"IBM Plex Sans JP"', "content": '"IBM Plex Sans JP"', "code": '"PlemolJP Console NF"'})
        self.assertEqual(pack.appearance(good, entries)["defaults"], self.THEMES)

        def theme(name, **changes):
            themes = json.loads(json.dumps(self.THEMES))
            themes[name].update(changes)
            return themes
        bad = {
            "unknown role": self.appearance(fonts={"ui": "ui", "content": "ui", "code": "serif"}),
            "missing content": self.appearance(fonts={"ui": "ui", "code": "terminal"}),
            "no dark default": self.appearance(defaults={"light": self.THEMES["light"]}),
            # A theme with fonts alone is one the app drops: every color is required.
            "font-only theme": self.appearance(defaults={**self.THEMES, "light": {}}),
            "missing surface": self.appearance(defaults={**self.THEMES, "dark": {k: v for k, v in self.THEMES["dark"].items() if k != "surface"}}),
            "short hex": self.appearance(defaults=theme("light", accent="#39f")),
            "contrast above 100": self.appearance(defaults=theme("dark", contrast=101)),
            "bool contrast": self.appearance(defaults=theme("dark", contrast=True)),
            "string opaqueWindows": self.appearance(defaults=theme("dark", opaqueWindows="false")),
            "other accentSource": self.appearance(defaults=theme("dark", accentSource="system")),
            "fonts in a default": self.appearance(defaults=theme("dark", fonts={"ui": None})),
            "a semantic color missing": self.appearance(defaults=theme("light", semanticColors={"diffAdded": "#00a240", "skill": "#924ff7"})),
        }
        for case, value in bad.items():
            with self.subTest(case=case), self.assertRaises(ValueError):
                pack.appearance(value, entries)
        with self.assertRaises(ValueError):
            pack.appearance(good, [{"role": "ui", "family": 'A "quoted" family'}, {"role": "terminal", "family": "x"}])
        with self.assertRaisesRegex(ValueError, "one Codex config"):
            pack.store_apps([{**self.APP, "appearance": good},
                             {**self.APP, "name": "Other", "id": "9ABCDEFGHIJK", "package": "Other.App", "appearance": good}], entries)
    def test_store_app_contract(self):
        self.assertEqual(pack.store_apps([self.APP], []), [self.APP])
        self.assertEqual(pack.store_apps(None, []), [])
        bad = {
            "not a list": self.APP,
            "extra key": [{**self.APP, "version": "1.0"}],
            "missing key": [{k: v for k, v in self.APP.items() if k != "publisherId"}],
            "winget source": [{**self.APP, "source": "winget"}],
            "lowercase id": [{**self.APP, "id": "9plm9xgg6vks"}],
            "short id": [{**self.APP, "id": "9PLM9XGG6VK"}],
            "package with an underscore": [{**self.APP, "package": "OpenAI.Codex_2p2nqsd0c76g0"}],
            "publisher id length": [{**self.APP, "publisherId": "2p2nqsd0c76g"}],
            "publisher id case": [{**self.APP, "publisherId": "2P2NQSD0C76G0"}],
            "int name": [{**self.APP, "name": 1}],
            "duplicate id": [self.APP, {**self.APP, "name": "Other", "package": "Other.App"}],
            "duplicate package": [self.APP, {**self.APP, "name": "Other", "id": "9ABCDEFGHIJK", "package": "openai.codex"}],
        }
        for case, value in bad.items():
            with self.subTest(case=case), self.assertRaises(ValueError):
                pack.store_apps(value, [])

    def test_distribution_is_deterministic_and_complete(self):
        fonts = self.payload()
        noctty, cloudflared, choices, scripts = self.inputs()
        for out in ("one", "two"):
            pack.distribution(fonts, noctty, cloudflared, choices, scripts, "a" * 40, self.root / out)
        first, second = [self.root / out / "windows-dist.zip" for out in ("one", "two")]
        self.assertEqual(first.read_bytes(), second.read_bytes())
        with zipfile.ZipFile(first) as z:
            manifest = json.loads(z.read("manifest.json"))
            self.assertEqual(manifest["schemaVersion"], 3)
            self.assertEqual(manifest["source"], "a" * 40)
            self.assertEqual(manifest["noctty"]["version"], "1.0")
            self.assertEqual(manifest["noctty"]["registration"], REGISTRATION)
            self.assertEqual(manifest["cloudflared"], {"version": "2.0", "file": "payload/cloudflared.exe",
                                                       "sha256": pack.digest(cloudflared)})
            self.assertEqual(z.read("payload/cloudflared.exe"), cloudflared.read_bytes())
            self.assertEqual(manifest["files"]["payload/cloudflared.exe"], pack.digest(cloudflared))
            self.assertEqual(manifest["packages"], [self.lock(files={"bin/fixture.exe": "1" * 64}, unpackedSize=10)])
            self.assertNotIn("packages.dsc.json", z.namelist())
            self.assertEqual(set(manifest["files"]), set(z.namelist()) - {"manifest.json"})
            for name in ("handoff-proof.ps1", "handoff-evaluate.ps1", "package-view.ps1"):
                self.assertIn(name, manifest["files"])
            for name, sha in manifest["files"].items():
                self.assertEqual(pack.hashlib.sha256(z.read(name)).hexdigest(), sha)
            # Nix is the only authority and win.ps1 the native adapter: no DSC backend or document.
            self.assertNotIn("backend", manifest)
            self.assertNotIn("configuration.dsc.json", z.namelist())
            self.assertFalse([n for n in z.namelist() if n.casefold().endswith("dsc.exe")])
            self.assertEqual(manifest["fonts"][0]["fullName"], "Test Font")
            self.assertNotIn(str(self.root), json.dumps(manifest))
            self.assertNotIn("WinGet", json.dumps(manifest))

    def with_packages(self, choices, *packages):
        selected = json.loads(choices.read_text())
        selected["packages"] = list(packages)
        choices.write_text(json.dumps(selected))

    def test_seed_is_generated_from_roles(self):
        fonts = self.payload()
        noctty, cloudflared, choices, scripts = self.inputs()
        self.with_packages(choices, self.lock(seed=self.seed(), inventory=str(self.inventory())))
        for out in ("one", "two"):
            pack.distribution(fonts, noctty, cloudflared, choices, scripts, "test", self.root / out)
        first, second = [self.root / out / "windows-dist.zip" for out in ("one", "two")]
        self.assertEqual(first.read_bytes(), second.read_bytes())
        family = {script: "Test Font" for script in ("Jpan", "Zyyy")}
        expected = (json.dumps({"webkit": {"webprefs": {"fonts": {"fixed": family, "sansserif": family, "standard": family}}}},
                               sort_keys=True, separators=(",", ":")) + "\n").encode("utf-8")
        with zipfile.ZipFile(first) as z:
            manifest = json.loads(z.read("manifest.json"))
            data = z.read("payload/fixture/initial_preferences")
        # Exactly the six preferences, nested, compact, sorted, no BOM, one trailing newline.
        self.assertEqual(data, expected)
        self.assertEqual(data.count(b'"Test Font"'), 6)
        self.assertEqual(manifest["packages"][0]["seed"],
                         {"path": "bin/initial_preferences", "file": "payload/fixture/initial_preferences",
                          "sha256": pack.hashlib.sha256(expected).hexdigest(), "size": len(expected)})
        self.assertEqual(manifest["files"]["payload/fixture/initial_preferences"], pack.hashlib.sha256(expected).hexdigest())
        # The seed is added to the tree, never counted in the archive's inventory or unpacked size.
        self.assertEqual(manifest["packages"][0]["files"], {"bin/fixture.exe": "1" * 64})
        self.assertEqual(manifest["packages"][0]["unpackedSize"], 10)

    def test_seed_roles_and_collisions(self):
        # A proportional role and a fixed role, each its own family, land on their own preferences.
        fonts = self.root / "fonts"
        pack.prepare_fonts([self.font(), dict(self.font(name="Mono Font", folder="mono"), role="mono")], fonts)
        self.assertEqual(json.loads(pack.seed_preferences(self.seed(fonts={"proportional": "fixture", "fixed": "mono"}),
                                                          json.loads((fonts / "fonts.json").read_text()))),
                         {"webkit": {"webprefs": {"fonts": {
                             "standard": {"Zyyy": "Test Font", "Jpan": "Test Font"},
                             "sansserif": {"Zyyy": "Test Font", "Jpan": "Test Font"},
                             "fixed": {"Zyyy": "Mono Font", "Jpan": "Mono Font"}}}}})
        noctty, cloudflared, choices, scripts = self.inputs()
        exe = {"bin/fixture.exe": "1" * 64}
        for case, (seed, files, pattern) in {
                "unselected role": (self.seed(fonts={"proportional": "fixture", "fixed": "absent"}), exe, "not selected"),
                "archive has the seed": (self.seed(), {**exe, "bin/initial_preferences": "1" * 64}, "preferences"),
                "archive has it in another case": (self.seed(), {**exe, "BIN/Initial_Preferences": "1" * 64}, "preferences"),
                "archive has the legacy name": (self.seed(), {**exe, "bin/master_preferences": "1" * 64}, "preferences"),
                "archive has a path under the seed": (self.seed(), {**exe, "bin/initial_preferences/x": "1" * 64}, "preferences"),
                }.items():
            self.with_packages(choices, self.lock(seed=seed, inventory=str(self.inventory(files))))
            with self.subTest(case=case), self.assertRaisesRegex(ValueError, pattern):
                pack.distribution(fonts, noctty, cloudflared, choices, scripts, "test", self.root / "out")
        # The legacy name elsewhere in the archive is not beside the executable, so Chromium never reads it.
        self.with_packages(choices, self.lock(seed=self.seed(), inventory=str(self.inventory({**exe, "master_preferences": "1" * 64}))))
        pack.distribution(fonts, noctty, cloudflared, choices, scripts, "test", self.root / "elsewhere")

    def test_packages_need_a_valid_inventory(self):
        fonts = self.payload()
        noctty, cloudflared, choices, scripts = self.inputs()
        selected = json.loads(choices.read_text())
        for case, package in {"no inventory": self.lock(),
                              "no executable": self.lock(inventory=str(self.inventory({"readme": "1" * 64}))),
                              "bad hash": self.lock(inventory=str(self.inventory({"bin/fixture.exe": "x"}))),
                              "unsafe path": self.lock(inventory=str(self.inventory({"bin/fixture.exe": "1" * 64,
                                                                                    "../x": "1" * 64}))),
                              "not a Windows path": self.lock(inventory=str(self.inventory({"bin/fixture.exe": "1" * 64,
                                                                                           "bin/a.": "1" * 64}))),
                              "case duplicate": self.lock(inventory=str(self.inventory({"bin/fixture.exe": "1" * 64,
                                                                                       "BIN/fixture.exe": "1" * 64}))),
                              "zero size": self.lock(inventory=str(self.inventory(size=0))),
                              "size above 2**53 - 1": self.lock(inventory=str(self.inventory(size=2**53))),
                              "bool size": self.lock(inventory=str(self.inventory(size=True))),
                              "text size": self.lock(inventory=str(self.inventory(size="10"))),
                              "no size": self.lock(inventory=str(self.inventory(raw={"files": {"bin/fixture.exe": "1" * 64}}))),
                              "extra field": self.lock(inventory=str(self.inventory(raw={"files": {"bin/fixture.exe": "1" * 64},
                                                                                         "unpackedSize": 10, "seed": {}}))),
                              "flat map": self.lock(inventory=str(self.inventory(raw={"bin/fixture.exe": "1" * 64})))
                              }.items():
            selected["packages"] = [package]
            choices.write_text(json.dumps(selected))
            with self.subTest(case=case), self.assertRaises(ValueError):
                pack.distribution(fonts, noctty, cloudflared, choices, scripts, "test", self.root / "out")

    def test_noctty_zip_traversal_fails(self):
        fonts = self.payload()
        noctty, cloudflared, choices, scripts = self.inputs()
        with zipfile.ZipFile(noctty, "a") as z:
            z.writestr("../noctty.exe", "fixture")
        with self.assertRaisesRegex(ValueError, "Unsafe"):
            pack.distribution(fonts, noctty, cloudflared, choices, scripts, "test", self.root / "out")

    def test_noctty_archive_windows_paths_and_directories(self):
        fonts = self.payload()
        noctty, cloudflared, choices, scripts = self.inputs()
        with zipfile.ZipFile(noctty, "a") as z:
            z.writestr("noctty/", "")
            z.writestr("noctty/share/", "")
            z.writestr("noctty/share/readme.txt", "fixture")
        pack.distribution(fonts, noctty, cloudflared, choices, scripts, "test", self.root / "ok")
        for case, (name, pattern) in {"empty directory": ("noctty/empty/", "without files"),
                                      "reserved name": ("noctty/NUL.txt", "Not a Windows path"),
                                      "trailing dot": ("noctty/share/a.", "Not a Windows path"),
                                      "directory outside": ("other/", "Unexpected noctty directory")}.items():
            archive = self.root / f"noctty-{case.replace(' ', '-')}.zip"
            archive.write_bytes(noctty.read_bytes())
            with zipfile.ZipFile(archive, "a") as z:
                z.writestr(name, "" if name.endswith("/") else "fixture")
            with self.subTest(case=case), self.assertRaisesRegex(ValueError, pattern):
                pack.distribution(fonts, archive, cloudflared, choices, scripts, "test", self.root / "out")

    def test_noctty_registration(self):
        files = {"noctty/noctty.exe": "1" * 64, "noctty/noctty-terminal-handoff-proxy.dll": "2" * 64}
        self.assertEqual(pack.noctty_registration(REGISTRATION, files), REGISTRATION)
        clsid = "Software\\Classes\\CLSID\\{33368C6F-D328-410C-B225-26DC9F12C728}"
        value = {"key": clsid + "\\LocalServer32", "name": "", "data": '"{install}\\noctty\\noctty.exe"'}
        for case, values in {"empty": [], "not a list": value,
                             "extra field": [dict(value, type="String")], "not a string": [dict(value, data=1)],
                             "shared root": [dict(value, key="Software\\Classes\\CLSID")],
                             "other root": [dict(value, key="Software\\Classes\\AppID\\{33368C6F-D328-410C-B225-26DC9F12C728}")],
                             "empty segment": [dict(value, key=clsid + "\\\\LocalServer32")],
                             "install in key": [dict(value, key=clsid + "\\{install}")],
                             "install in name": [dict(value, name="{install}")],
                             "install not first": [dict(value, data="x {install}\\noctty\\noctty.exe")],
                             "unbalanced quote": [dict(value, data='{install}\\noctty\\noctty.exe"')],
                             "not an inventory file": [dict(value, data="{install}\\noctty\\noctty.com")],
                             "empty data": [dict(value, data="")],
                             "case duplicate": [value, dict(value, key=clsid + "\\localserver32", data="x")]}.items():
            with self.subTest(case=case), self.assertRaises(ValueError):
                pack.noctty_registration(values, files)
        fonts = self.payload()
        noctty, cloudflared, choices, scripts = self.inputs()
        selected = json.loads(choices.read_text())
        del selected["noctty"]["registration"]
        choices.write_text(json.dumps(selected))
        with self.assertRaisesRegex(ValueError, "No Noctty registration"):
            pack.distribution(fonts, noctty, cloudflared, choices, scripts, "test", self.root / "out")

    def test_cloudflared_must_be_selected_and_executable(self):
        fonts = self.payload()
        noctty, cloudflared, choices, scripts = self.inputs()
        cloudflared.write_bytes(b"#!/bin/sh\n")
        with self.assertRaisesRegex(ValueError, "not a Windows executable"):
            pack.distribution(fonts, noctty, cloudflared, choices, scripts, "test", self.root / "out")
        cloudflared.write_bytes(b"MZ fixture")
        selected = json.loads(choices.read_text())
        del selected["cloudflared"]
        choices.write_text(json.dumps(selected))
        with self.assertRaisesRegex(ValueError, "No cloudflared version"):
            pack.distribution(fonts, noctty, cloudflared, choices, scripts, "test", self.root / "out")


if __name__ == "__main__":
    unittest.main()
