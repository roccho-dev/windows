"""Compiler tests; native Windows convergence is deliberately a separate proof."""
import json
from pathlib import Path
import tempfile
import unittest
import zipfile

from fontTools.fontBuilder import FontBuilder
from fontTools.pens.ttGlyphPen import TTGlyphPen

import pack


class CompilerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)

    def font(self, name="Test Font", filename="input.ttf"):
        builder = FontBuilder(1000, isTTF=True)
        builder.setupGlyphOrder([".notdef", "space"])
        builder.setupCharacterMap({32: "space"})
        builder.setupGlyf({name: TTGlyphPen(None).glyph() for name in (".notdef", "space")})
        builder.setupHorizontalMetrics({name: (500, 0) for name in (".notdef", "space")})
        builder.setupHorizontalHeader(ascent=800, descent=-200)
        builder.setupNameTable({"familyName": name, "styleName": "Regular", "fullName": name,
                               "uniqueFontIdentifier": name, "psName": name.replace(" ", "")})
        builder.setupOS2(sTypoAscender=800, sTypoDescender=-200, usWinAscent=800, usWinDescent=200)
        builder.setupPost()
        source = self.root / "upstream"
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
            "short sha": [self.lock(sha256="b63be7548792b4ad0dfe424d91cc693b478")],
            "upper sha": [self.lock(sha256="A" * 64)],
            "int sha": [self.lock(sha256=1)],
            "short sha1": [self.lock(sha1="0" * 39)],
            "int name": [self.lock(name=1)],
            "slash name": [self.lock(name="a/b", directory="Programs/a/b-1.0")],
            "version traversal": [self.lock(version="1/..", directory="Programs/fixture-1/..")],
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
        self.assertEqual(json.loads(out.read_text()), pack.tree_inventory(tree, ["bin/fixture.exe", "readme"],
                                                                          "bin/fixture.exe"))
        lock_path.write_text(json.dumps(self.lock(size=13)))
        with self.assertRaisesRegex(ValueError, "differs"):
            pack.package_inventory(lock_path, asset, listing, tree, out)

    def inventory(self, files=None):
        path = self.root / "inventory.json"
        path.write_text(json.dumps({"bin/fixture.exe": "1" * 64} if files is None else files))
        return path

    def inputs(self):
        backend = self.root / "dsc.zip"
        with zipfile.ZipFile(backend, "w") as z:
            z.writestr("dsc.exe", "not executable: packaging fixture only")
            z.writestr("LICENSE.txt", "test license")
        noctty = self.root / "noctty.zip"
        with zipfile.ZipFile(noctty, "w") as z:
            z.writestr("noctty/noctty.exe", "fixture application")
            z.writestr("noctty/noctty.com", "fixture console entry")
            z.writestr("noctty/noctty-terminal-handoff-proxy.dll", "fixture handoff proxy")
        cloudflared = self.root / "cloudflared.exe"
        cloudflared.write_bytes(b"MZ fixture: not the real client")
        choices = self.root / "choices.json"
        choices.write_text(json.dumps({"noctty": {"version": "1.0", "fontFamily": "Test Font"},
                                       "cloudflared": {"version": "2.0"},
                                       "packages": [self.lock(inventory=str(self.inventory()))]}))
        scripts = self.root / "scripts"
        scripts.mkdir(exist_ok=True)
        for name in ("win.ps1", "proof.ps1", "handoff-proof.ps1", "handoff-evaluate.ps1",
                     "package-view.ps1", "README.md"):
            (scripts / name).write_text("fixture")
        return backend, noctty, cloudflared, choices, scripts

    def test_distribution_is_deterministic_and_complete(self):
        fonts = self.payload()
        backend, noctty, cloudflared, choices, scripts = self.inputs()
        for out in ("one", "two"):
            pack.distribution(fonts, backend, noctty, cloudflared, choices, scripts, "a" * 40, self.root / out)
        first, second = [self.root / out / "windows-dist.zip" for out in ("one", "two")]
        self.assertEqual(first.read_bytes(), second.read_bytes())
        with zipfile.ZipFile(first) as z:
            manifest = json.loads(z.read("manifest.json"))
            self.assertEqual(manifest["schemaVersion"], 3)
            self.assertEqual(manifest["source"], "a" * 40)
            self.assertEqual(manifest["noctty"]["version"], "1.0")
            self.assertEqual(manifest["cloudflared"], {"version": "2.0", "file": "payload/cloudflared.exe",
                                                       "sha256": pack.digest(cloudflared)})
            self.assertEqual(z.read("payload/cloudflared.exe"), cloudflared.read_bytes())
            self.assertEqual(manifest["files"]["payload/cloudflared.exe"], pack.digest(cloudflared))
            self.assertEqual(manifest["packages"], [self.lock(files={"bin/fixture.exe": "1" * 64})])
            self.assertNotIn("packages.dsc.json", z.namelist())
            self.assertEqual(set(manifest["files"]), set(z.namelist()) - {"manifest.json"})
            for name in ("handoff-proof.ps1", "handoff-evaluate.ps1", "package-view.ps1"):
                self.assertIn(name, manifest["files"])
            for name, sha in manifest["files"].items():
                self.assertEqual(pack.hashlib.sha256(z.read(name)).hexdigest(), sha)
            config = json.loads(z.read("configuration.dsc.json"))
            self.assertEqual(config["resources"][0]["type"], "Microsoft.Windows/Registry")
            self.assertIn("envvar('WINDOWS_IAC_FONT_DIR')", config["resources"][0]["properties"]["valueData"]["String"])
            self.assertNotIn(str(self.root), json.dumps(manifest))
            self.assertNotIn("WinGet", json.dumps(manifest))

    def test_packages_need_a_valid_inventory(self):
        fonts = self.payload()
        backend, noctty, cloudflared, choices, scripts = self.inputs()
        selected = json.loads(choices.read_text())
        for case, package in {"no inventory": self.lock(),
                              "no executable": self.lock(inventory=str(self.inventory({"readme": "1" * 64}))),
                              "bad hash": self.lock(inventory=str(self.inventory({"bin/fixture.exe": "x"}))),
                              "unsafe path": self.lock(inventory=str(self.inventory({"bin/fixture.exe": "1" * 64,
                                                                                    "../x": "1" * 64}))),
                              "not a Windows path": self.lock(inventory=str(self.inventory({"bin/fixture.exe": "1" * 64,
                                                                                           "bin/a.": "1" * 64}))),
                              "case duplicate": self.lock(inventory=str(self.inventory({"bin/fixture.exe": "1" * 64,
                                                                                       "BIN/fixture.exe": "1" * 64})))
                              }.items():
            selected["packages"] = [package]
            choices.write_text(json.dumps(selected))
            with self.subTest(case=case), self.assertRaises(ValueError):
                pack.distribution(fonts, backend, noctty, cloudflared, choices, scripts, "test", self.root / "out")

    def test_backend_zip_traversal_fails(self):
        fonts = self.payload()
        backend, noctty, cloudflared, choices, scripts = self.inputs()
        with zipfile.ZipFile(backend, "w") as z:
            z.writestr("../dsc.exe", "fixture")
        with self.assertRaisesRegex(ValueError, "Unsafe"):
            pack.distribution(fonts, backend, noctty, cloudflared, choices, scripts, "test", self.root / "out")

    def test_cloudflared_must_be_selected_and_executable(self):
        fonts = self.payload()
        backend, noctty, cloudflared, choices, scripts = self.inputs()
        cloudflared.write_bytes(b"#!/bin/sh\n")
        with self.assertRaisesRegex(ValueError, "not a Windows executable"):
            pack.distribution(fonts, backend, noctty, cloudflared, choices, scripts, "test", self.root / "out")
        cloudflared.write_bytes(b"MZ fixture")
        selected = json.loads(choices.read_text())
        del selected["cloudflared"]
        choices.write_text(json.dumps(selected))
        with self.assertRaisesRegex(ValueError, "No cloudflared version"):
            pack.distribution(fonts, backend, noctty, cloudflared, choices, scripts, "test", self.root / "out")


if __name__ == "__main__":
    unittest.main()
