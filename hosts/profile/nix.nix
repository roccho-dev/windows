# The one small development profile for own and rent (Issue #8). Codex and Claude Code are official releases pinned
# by hash; every other package comes from the locked nixpkgs. Adding a package is a change here, CI, and a new image;
# nothing is installed into a host by hand. `extra` supplies role tools and the CI upgrade proof. `owner` only names the
# profile's stable Git credential helper (own: its Binding; rent keeps the default); each repository's principal is
# declared by its own binding (hosts/profile/gh.nix), never derived from owner or the URL namespace.
{ pkgs, extra ? [], owner ? "roccho-dev" }:
let
  releasePins = builtins.fromJSON (builtins.readFile ./releases.json);
  releaseVersions = builtins.mapAttrs (_: release: release.version) releasePins;
  codex = import ../own/codex.nix { inherit pkgs; release = releasePins.codex; };
  claudeRelease = releasePins.claude;
  # Official Claude Code native build, pinned to the manifest's platforms.linux-x64 asset.
  claudeBin = pkgs.fetchurl {
    url = "https://downloads.claude.ai/claude-code-releases/${claudeRelease.version}/linux-x64/claude";
    sha256 = claudeRelease.sha256;
  };
  # The glibc build runs through the pinned glibc loader, as the fixed W runtime runs it; updates are off.
  claude = pkgs.writeShellScriptBin "claude" ''
    export DISABLE_AUTOUPDATER=1
    exec ${pkgs.glibc}/lib/ld-linux-x86-64.so.2 --library-path ${pkgs.glibc}/lib ${claudeBin} "$@"
  '';
  # gh is the shared principal-routing wrapper, with the profile's Git credential helper (#8-C).
  github = import ./gh.nix { inherit pkgs owner; };
in
assert builtins.isAttrs releasePins.codex;
assert builtins.isString releasePins.codex.version;
assert builtins.isString releasePins.codex.sha256;
assert builtins.isAttrs releasePins.claude;
assert builtins.isString releasePins.claude.version;
assert builtins.isString releasePins.claude.sha256;
pkgs.buildEnv {
  name = "dev-profile";
  paths = (with pkgs; [ bash coreutils diffutils findutils gnugrep gnused gnutar gzip nix git openssh ])
    ++ [ github.wrapper github.helper codex claude ] ++ extra;
  pathsToLink = [ "/bin" ];
  passthru = { inherit releaseVersions; };
}
