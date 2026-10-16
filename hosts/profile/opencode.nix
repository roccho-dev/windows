# OpenCode 2 CLI (not nixpkgs.opencode, which is V1 in this lock).
# Upstream npm's platform binary, with its fixed hash independently recorded by
# numtide/llm-agents.nix packages/opencode2/hashes.json at version 2.0.30.
{ pkgs }:
pkgs.stdenv.mkDerivation (finalAttrs: {
  pname = "opencode2";
  version = "2.0.30";

  src = pkgs.fetchurl {
    url = "https://registry.npmjs.org/@opencode/cli-linux-x64/-/cli-linux-x64-${finalAttrs.version}.tgz";
    hash = "sha256-+779hvzULwPWJTvRpaHlMlWCdGebZp+Cnz3ZIf+jMgU=";
  };
  sourceRoot = "package";
  nativeBuildInputs = [ pkgs.autoPatchelfHook pkgs.makeWrapper ];
  buildInputs = [ pkgs.stdenv.cc.cc.lib pkgs.wayland ];
  dontBuild = true;
  # Bun's native executable contains appended application data.
  dontStrip = true;

  installPhase = ''
    runHook preInstall
    install -Dm755 bin/opencode $out/bin/.opencode2-unwrapped
    makeWrapper $out/bin/.opencode2-unwrapped $out/bin/opencode \
      --prefix PATH : ${pkgs.lib.makeBinPath [ pkgs.ripgrep ]} \
      --prefix LD_LIBRARY_PATH : ${pkgs.lib.makeLibraryPath [ pkgs.stdenv.cc.cc.lib pkgs.wayland ]}
    runHook postInstall
  '';

  doInstallCheck = true;
  nativeInstallCheckInputs = [ pkgs.versionCheckHook ];
  versionCheckProgramArg = "--version";

  meta = with pkgs.lib; {
    description = "Official OpenCode 2 CLI binary";
    homepage = "https://opencode.ai/v2/docs/";
    license = licenses.mit;
    platforms = [ "x86_64-linux" ];
    mainProgram = "opencode";
  };
})
