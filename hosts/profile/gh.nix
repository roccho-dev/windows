# Owner GitHub routing (Issue #8-C), one definition for own, rent and dev: the gh wrapper and the owner's Git
# credential helper, immutable outputs reached through each runtime's profile. Credentials persist only in the owner
# root /work/repos/.auth/<owner>/gh. A repository selects it in its own common-dir config (credential.helper reset, then
# this helper for its github.com/<owner> origin, as Tools' bind writes); everywhere else gh gets an empty read-only
# config, so it has no credentials and no writable store. Token and target overrides never win on either path.
{ pkgs, owner ? "roccho-dev" }:
let
  root = "/work/repos/.auth/${owner}/gh";
  helperName = "git-credential-github-${owner}";
  unselected = pkgs.runCommand "gh-unselected-config" { } "mkdir $out";
  clear = "unset GH_TOKEN GITHUB_TOKEN GH_ENTERPRISE_TOKEN GITHUB_ENTERPRISE_TOKEN GH_REPO GH_HOST";
in
{
  wrapper = pkgs.writeShellScriptBin "gh" ''
    ${clear}
    export GH_NO_UPDATE_NOTIFIER=1
    # Only this repository's own config decides; system and global Git configuration are not read.
    local_git() { GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null ${pkgs.git}/bin/git config --local --get "$1" 2>/dev/null; }
    if url=$(local_git remote.origin.url) && case $url in https://github.com/${owner}/*) true ;; *) false ;; esac &&
      helper=$(local_git "credential.$url.helper") && [ "''${helper##*/}" = ${helperName} ]; then
      export GH_CONFIG_DIR=${root}
    else
      export GH_CONFIG_DIR=${unselected} GH_PROMPT_DISABLED=1
    fi
    exec ${pkgs.gh}/bin/gh "$@"
  '';
  helper = pkgs.writeShellScriptBin helperName ''
    ${clear}
    export GH_CONFIG_DIR=${root}
    exec ${pkgs.gh}/bin/gh auth git-credential "$@"
  '';
}
