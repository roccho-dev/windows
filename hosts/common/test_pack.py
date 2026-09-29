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
                                       "packages": [{"name": "Fixture", "id": "Fixture.App", "version": "1.0"}]}))
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
            self.assertEqual(manifest["source"], "a" * 40)
            self.assertEqual(manifest["noctty"]["version"], "1.0")
            self.assertEqual(manifest["cloudflared"], {"version": "2.0", "file": "payload/cloudflared.exe",
                                                       "sha256": pack.digest(cloudflared)})
            self.assertEqual(z.read("payload/cloudflared.exe"), cloudflared.read_bytes())
            self.assertEqual(manifest["files"]["payload/cloudflared.exe"], pack.digest(cloudflared))
            self.assertEqual(len(manifest["packages"]), 1)
            self.assertEqual(set(manifest["files"]), set(z.namelist()) - {"manifest.json"})
            for name in ("handoff-proof.ps1", "handoff-evaluate.ps1", "package-view.ps1"):
                self.assertIn(name, manifest["files"])
            for name, sha in manifest["files"].items():
                self.assertEqual(pack.hashlib.sha256(z.read(name)).hexdigest(), sha)
            config = json.loads(z.read("configuration.dsc.json"))
            self.assertEqual(config["resources"][0]["type"], "Microsoft.Windows/Registry")
            self.assertIn("envvar('WINDOWS_IAC_FONT_DIR')", config["resources"][0]["properties"]["valueData"]["String"])
            self.assertNotIn(str(self.root), json.dumps(manifest))
            package_config = json.loads(z.read("packages.dsc.json"))
            self.assertEqual(package_config["resources"][0]["type"], "Microsoft.WinGet/Package")
            self.assertEqual(package_config["resources"][0]["properties"]["version"], "1.0")

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
