# CPU-only Ollaya source for the dev OCI. Decision runtime, not a Jev replacement.
# Upstream release checksum is fixed; no installer, service, model or secret is run during the build.
{ pkgs }:
let
  version = "0.12.0";
in
pkgs.stdenvNoCC.mkDerivation {
  pname = "ollaya";
  inherit version;

  src = pkgs.fetchurl {
    url = "https://github.com/ollaya-dev/ollaya/releases/download/v${version}/ollaya-linux-amd64.tar.zst";
    hash = "sha256-okw95eHF8zuwlz6uGjasjpAz9H866DaITjhXobLqEAM=";
  };

  nativeBuildInputs = [ pkgs.autoPatchelfHook pkgs.zstd ];
  buildInputs = [ pkgs.stdenv.cc.cc.lib ];

  sourceRoot = ".";
  unpackPhase = ''
    runHook preUnpack
    mkdir -p unpacked
    ${pkgs.zstd}/bin/zstd -dc "$src" | ${pkgs.gnutar}/bin/tar -xf - -C unpacked
    runHook postUnpack
  '';

  installPhase = ''
    runHook preInstall
    test -x unpacked/bin/ollaya
    mkdir -p "$out"
    cp -R unpacked/bin unpacked/lib unpacked/share "$out/"
    runHook postInstall
  '';
}
