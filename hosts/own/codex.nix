{ pkgs, definition }:

assert builtins.isAttrs definition;
assert builtins.isAttrs definition.contract;
assert builtins.isAttrs definition.pin;
assert definition.contract.sourceKind == "github-release";
assert definition.contract.channel == "stable";
assert definition.contract.versionScheme == "semver";
assert definition.contract.platform == "x86_64-unknown-linux-musl";
assert definition.contract.verifyKind == "github-asset-digest";
assert definition.contract.packageShape == "codex-musl-tar";
let
  inherit (definition) contract pin;
  inherit (pin) version contentHash;
  archive = pkgs.fetchurl {
    url = "https://github.com/${contract.officialSource}/releases/download/rust-v${version}/${contract.assetSelector}";
    sha256 = contentHash;
  };
in
pkgs.runCommand "codex-cli-${version}" {
  nativeBuildInputs = [ pkgs.gnutar pkgs.gzip ];
} ''
  mkdir -p "$out"
  tar -xzf ${archive} -C "$out"
  chmod 755 "$out/bin/codex" "$out/bin/codex-code-mode-host"
  test "$("$out/bin/codex" --version)" = "codex-cli ${version}"
  test -x "$out/bin/codex-code-mode-host"
''
