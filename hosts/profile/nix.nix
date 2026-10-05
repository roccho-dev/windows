# The one small development profile for own and rent (Issue #8). Codex and Claude Code are official releases pinned
# by hash; every other package comes from the locked nixpkgs. Adding a package is a change here, CI, and a new image;
# nothing is installed into a host by hand. `extra` exists only for the CI upgrade proof. `owner` is the role's or
# target's declared credential owner (own: its Binding); rent keeps the default.
{ pkgs, extra ? [], owner ? "roccho-dev" }:
let
  codex = import ../own/codex.nix { inherit pkgs; };
  # Official Claude Code native build, pinned to platforms.linux-x64 of
  # https://downloads.claude.ai/claude-code-releases/2.1.283/manifest.json (size 241556664).
  claudeVersion = "2.1.283";
  claudeBin = pkgs.fetchurl {
    url = "https://downloads.claude.ai/claude-code-releases/${claudeVersion}/linux-x64/claude";
    sha256 = "1859583ce32920595c61ef868bee52e1b1594f7486db209935e01f1e5e804ae2";
  };
  # The glibc build runs through the pinned glibc loader, as the fixed W runtime runs it; updates are off.
  claude = pkgs.writeShellScriptBin "claude" ''
    export DISABLE_AUTOUPDATER=1
    exec ${pkgs.glibc}/lib/ld-linux-x86-64.so.2 --library-path ${pkgs.glibc}/lib ${claudeBin} "$@"
  '';
  # gh is the shared owner-routing wrapper, with the owner's Git credential helper (#8-C).
  github = import ./gh.nix { inherit pkgs owner; };
in
pkgs.buildEnv {
  name = "dev-profile";
  paths = (with pkgs; [ bash coreutils diffutils findutils gnugrep gnused gnutar gzip nix git openssh ])
    ++ [ github.wrapper github.helper codex claude ] ++ extra;
  pathsToLink = [ "/bin" ];
}
