# Owner GitHub routing (Issue #8-C), one definition for own, rent and dev: the gh wrapper and the owner's Git
# credential helper, immutable outputs reached through each runtime's profile. Credentials persist only in the owner
# root /work/repos/.auth/<owner>/gh. A repository selects it in its own common-dir config (credential.helper reset, then
# this helper for its github.com/<owner> origin, as Tools' bind writes); everywhere else gh's config directory is
# /dev/null, which is no directory, so nothing can be read or created there, by root either (a read-only directory
# would not stop root). Token and target overrides never win on either path.
{ pkgs, owner ? "roccho-dev" }:
let
  root = "/work/repos/.auth/${owner}/gh";
  helperName = "git-credential-github-${owner}";
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
      export GH_CONFIG_DIR=/dev/null GH_PROMPT_DISABLED=1
    fi
    exec ${pkgs.gh}/bin/gh "$@"
  '';
  # Git's request is key=value lines up to a blank line. For every action (get, store, erase), only protocol=https,
  # host=github.com and a path ${owner}/<repo> (Git sends the path because binding sets useHttpPath) reach the owner
  # root; a missing, repeated or other protocol, host or path gets no answer, no output and no side effect.
  helper = pkgs.writeShellScriptBin helperName ''
    ${clear}
    request=() protocol= host= path= seen=
    while IFS= read -r line && [ -n "$line" ]; do
      request+=("$line")
      key=''${line%%=*}
      case $key in protocol|host|path) ;; *) continue ;; esac
      case " $seen " in *" $key "*) exit 0 ;; esac
      seen="$seen $key"
      printf -v "$key" '%s' "''${line#*=}"
    done
    repo=''${path#${owner}/}
    if [ "$protocol" != https ] || [ "$host" != github.com ] || [ "$repo" = "$path" ] ||
      ! [[ $repo =~ ^[A-Za-z0-9._-]+$ ]] || [ "$repo" = . ] || [ "$repo" = .. ]; then
      exit 0
    fi
    export GH_CONFIG_DIR=${root}
    printf '%s\n' "''${request[@]}" "" | ${pkgs.gh}/bin/gh auth git-credential "$@"
  '';
}
