{ pkgs }:

let
  version = "0.157.1";
  archive = pkgs.fetchurl {
    url = "https://github.com/openai/codex/releases/download/rust-v${version}/codex-x86_64-unknown-linux-musl.tar.gz";
    sha256 = "e98c1e8e028e8137fa2d2415c82ec58e7b3701a627e3554aace5b3ca31454af2";
  };
in
pkgs.runCommand "codex-cli-${version}" {
  nativeBuildInputs = [ pkgs.gnutar pkgs.gzip ];
} ''
  mkdir -p "$out/bin"
  tar -xzf ${archive} -C "$out/bin"
  mv "$out/bin/codex-x86_64-unknown-linux-musl" "$out/bin/codex"
  chmod 755 "$out/bin/codex"
  test "$("$out/bin/codex" --version)" = "codex-cli ${version}"
''
