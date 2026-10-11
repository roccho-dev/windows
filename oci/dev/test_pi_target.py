"""Exercise the actual jq gate extracted from pi.nix; this is not Nix evaluation."""
import json
from pathlib import Path
import re
import subprocess
import unittest

SOURCE = Path(__file__).with_name("pi.nix").read_text()
MATCH = re.search(r'--argjson target "\$expected_target" "\n(.*?)\n      " >/dev/null', SOURCE, re.S)
assert MATCH, "expected target gate not found"
GATE = MATCH.group(1).replace('\\"', '"').replace('\\$', '$')
OCI = {"repository": "roccho-dev/windows", "host": "oci-dev", "kind": "pi_auth_command"}
NIXOS = {"repository": "roccho-dev/resources", "host": "versapro", "kind": "pi_auth_command"}


def accepts(target, actual=None, **changes):
    row = {"id": "opencode-go.versapro", "kind": "envs.authCapability.v1",
           "capability": "opencode-go", "source_key": "OPENCODE_API_KEY",
           "target": target if actual is None else actual, "ciphertext": "ciphertexts/test.sops.yaml"}
    row.update(changes)
    return subprocess.run(["jq", "-e", "--arg", "id", row["id"], "--argjson", "target",
                           json.dumps(target), GATE], input=json.dumps(row), text=True,
                          capture_output=True, check=False).returncode == 0


class TargetTests(unittest.TestCase):
    def test_default_contract_preserved(self):
        self.assertIn('bindingId ? "opencode-go.oci-dev"', SOURCE)
        self.assertIn('target ? { repository = "roccho-dev/windows"; host = "oci-dev";', SOURCE)
        self.assertTrue(accepts(OCI))

    def test_nixos_target(self):
        self.assertTrue(accepts(NIXOS))

    def test_cross_target_refused(self):
        self.assertFalse(accepts(NIXOS, OCI))
        self.assertFalse(accepts(OCI, NIXOS))

    def test_wrong_each_target_field(self):
        for key in NIXOS:
            with self.subTest(key=key):
                self.assertFalse(accepts(NIXOS, dict(NIXOS, **{key: "other"})))

    def test_missing_and_extra_target_field(self):
        self.assertFalse(accepts(NIXOS, {"host": "versapro"}))
        self.assertFalse(accepts(NIXOS, dict(NIXOS, extra="value")))

    def test_other_capability_and_key_refused(self):
        self.assertFalse(accepts(NIXOS, capability="jev-api"))
        self.assertFalse(accepts(NIXOS, source_key="JEV_API_KEY"))

    def test_wrong_binding_kind_and_ciphertext_type(self):
        self.assertFalse(accepts(NIXOS, kind="process_env"))
        self.assertFalse(accepts(NIXOS, ciphertext=None))

    def test_json_values_cannot_change_filter(self):
        self.assertFalse(accepts(NIXOS, dict(NIXOS, host='" or true #')))

    def test_shell_templates_parse(self):
        scripts = re.findall(r"text = ''\n(.*?)\n    '';", SOURCE, re.S)
        self.assertEqual(len(scripts), 2)
        for text in scripts:
            text = text.replace("''${", "__SHELL_OPEN__")
            text = re.sub(r"\$\{[^}]+\}", "/dummy", text).replace("__SHELL_OPEN__", "${")
            result = subprocess.run(["bash", "-n"], input=text, text=True, capture_output=True)
            self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == "__main__":
    unittest.main()
