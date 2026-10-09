{ pkgs, release }:

assert builtins.isAttrs release;
assert builtins.isString release.version;
assert builtins.isString release.sha256;
let
  inherit (release) version sha256;
  archive = pkgs.fetchurl {
    url = "https://github.com/openai/codex/releases/download/rust-v${version}/codex-package-x86_64-unknown-linux-musl.tar.gz";
    inherit sha256;
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
