# The one small development profile for own and rent (Issue #8). Codex and Claude Code are official releases pinned
# by hash; every other package comes from the locked nixpkgs. Adding a package is a change here, CI, and a new image;
# nothing is installed into a host by hand. `extra` supplies role tools and the CI upgrade proof. `owner` only names the
# profile's stable Git credential helper (own: its Binding; rent keeps the default); each repository's principal is
# declared by its own binding (hosts/profile/gh.nix), never derived from owner or the URL namespace.
# `piTarget` (own only) names one exact envs target for the existing Pi credential launcher; null keeps the plain entry.
{ pkgs, extra ? [], owner ? "roccho-dev", mode ? "legacy", piTarget ? null }:
let
  # Core(L_B, owner) never evaluates an app pin. The default retains rent/dev's existing profile.
  github = import ./gh.nix { inherit pkgs owner; };
  corePaths = with pkgs; [ bash coreutils diffutils findutils gnugrep gnused gnutar gzip nix git openssh ];
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
  # Only the immutable upstream is consumed; own never evaluates the dev credential resolver/launcher.
  opencode = import ./opencode.nix { inherit pkgs; };
  pi = import ../../oci/dev/pi.nix { inherit pkgs; };
  ownPiEntry = pkgs.runCommand "own-pi-entry-${pi.version}" {
    nativeBuildInputs = [ pkgs.makeWrapper ];
  } ''
    mkdir -p "$out/bin"
    makeWrapper ${pi.upstream}/bin/pi-upstream "$out/bin/pi" \
      --set PI_PACKAGE_DIR ${pi.upstream}/share/pi
  '';
  # A target-bound own uses the same Pi source and resolver with its own binding, identity and agent directory.
  ownPi = if piTarget == null then ownPiEntry
    else (import ../../oci/dev/pi.nix ({ inherit pkgs; } // piTarget)).launcher;
  # The same bounded jev-age-init (absent-only, safe parent, public recipient only) over this target's identity, so the
  # target creates its own key in place; only its init is used (remotes are the dev values, never reached by init).
  ownAgeInit = ((import ../../oci/dev/nix.nix { inherit pkgs; }).jevTools {
    envsRemote = "https://github.com/roccho-dev/envs";
    appsRemote = "https://github.com/roccho-dev/apps";
    opsRemote = "https://github.com/roccho-dev/ops";
    inherit (piTarget) identity;
  }).init;
in
assert piTarget == null || mode == "own";
assert piTarget == null || piTarget ? identity;
assert builtins.elem mode [ "legacy" "core" "own" ];
if mode == "core" then pkgs.buildEnv {
  name = "own-core";
  paths = corePaths ++ [ github.wrapper github.helper ];
  pathsToLink = [ "/bin" ];
  passthru = { inherit github; credentialOwner = owner; };
} else
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
  name = if mode == "own" then "own-tool-profile" else "dev-profile";
  # Every supported own generation anchors the identical H_B at the existing absolute helper locator.
  paths = (if mode == "own" then [ github.helper ownPi ] ++ pkgs.lib.optional (piTarget != null) ownAgeInit
      else corePaths ++ [ github.wrapper github.helper ])
    ++ [ codex claude opencode releaseVersion ] ++ extra;
  pathsToLink = [ "/bin" ];
  passthru = { inherit releaseDefinitions releaseVersions github ownPiEntry ownPi; piUpstream = pi.upstream; }
    // pkgs.lib.optionalAttrs (piTarget != null) { inherit ownAgeInit; };
}
