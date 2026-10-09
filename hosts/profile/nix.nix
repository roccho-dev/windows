# The one small development profile for own and rent (Issue #8). Codex and Claude Code are official releases pinned
# by hash; every other package comes from the locked nixpkgs. Adding a package is a change here, CI, and a new image;
# nothing is installed into a host by hand. `extra` supplies role tools and the CI upgrade proof. `owner` only names the
# profile's stable Git credential helper (own: its Binding; rent keeps the default); each repository's principal is
# declared by its own binding (hosts/profile/gh.nix), never derived from owner or the URL namespace.
{ pkgs, extra ? [], owner ? "roccho-dev" }:
let
  releaseDefinitions = builtins.fromJSON (builtins.readFile ./releases.json);
  releaseVersions = builtins.mapAttrs (_: definition: definition.pin.version) releaseDefinitions;
  codex = import ../own/codex.nix { inherit pkgs; definition = releaseDefinitions.codex; };
  claudeDefinition = releaseDefinitions.claude;
  claudeContract = claudeDefinition.contract;
  claudePin = claudeDefinition.pin;
  claudeBin = pkgs.fetchurl {
    url = "${claudeContract.officialSource}/${claudePin.version}/${claudeContract.platform}/${claudeContract.assetSelector}";
    sha256 = claudePin.contentHash;
  };
  # The glibc build runs through the pinned glibc loader, as the fixed W runtime runs it; updates are off.
  claude = pkgs.writeShellScriptBin "claude" ''
    export DISABLE_AUTOUPDATER=1
    exec ${pkgs.glibc}/lib/ld-linux-x86-64.so.2 --library-path ${pkgs.glibc}/lib ${claudeBin} "$@"
  '';
  releaseVersionCases = pkgs.lib.concatMapStrings (name: ''
    ${name}) printf '%s\n' '${releaseVersions.${name}}' ;;
  '') (builtins.attrNames releaseVersions);
  releaseVersion = pkgs.writeShellScriptBin "release-version" ''
    set -eu
    case "''${1:-}" in
${releaseVersionCases}      *) echo "release-version: unknown CLI ''${1:-}" >&2; exit 2 ;;
    esac
  '';
  # gh is the shared principal-routing wrapper, with the profile's Git credential helper (#8-C).
  github = import ./gh.nix { inherit pkgs owner; };
in
assert builtins.attrNames releaseDefinitions == [ "claude" "codex" ];
assert builtins.isAttrs releaseDefinitions.codex.contract;
assert builtins.isAttrs releaseDefinitions.codex.contract.proof;
assert builtins.isAttrs releaseDefinitions.codex.pin;
assert builtins.isAttrs releaseDefinitions.claude.contract;
assert builtins.isAttrs releaseDefinitions.claude.contract.proof;
assert builtins.isAttrs releaseDefinitions.claude.pin;
assert claudeContract.sourceKind == "claude-manifest";
assert claudeContract.channel == "stable";
assert claudeContract.versionScheme == "semver";
assert claudeContract.verifyKind == "gpg-signed-manifest";
assert claudeContract.proof.kind == "gpg-signed-manifest";
assert claudeContract.proof.keyFingerprint == "31DDDE24DDFAB679F42D7BD2BAA929FF1A7ECACE";
assert claudeContract.packageShape == "single-glibc-executable";
pkgs.buildEnv {
  name = "dev-profile";
  paths = (with pkgs; [ bash coreutils diffutils findutils gnugrep gnused gnutar gzip nix git openssh ])
    ++ [ github.wrapper github.helper codex claude releaseVersion ] ++ extra;
  pathsToLink = [ "/bin" ];
  passthru = { inherit releaseDefinitions releaseVersions; };
}
