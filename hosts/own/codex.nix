{ pkgs }:

let
  version = "0.157.1";
  archive = pkgs.fetchurl {
    url = "https://github.com/openai/codex/releases/download/rust-v${version}/codex-package-x86_64-unknown-linux-musl.tar.gz";
    sha256 = "0e211868c9fd73cb49ad35ac675b5eafdf6b9f453df8a493df980c59a590fe5f";
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
