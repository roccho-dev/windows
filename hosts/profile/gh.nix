# Owner GitHub routing (Issue #8-C), one definition for own, rent and dev: the gh wrapper and the owner's Git
# credential helper, immutable outputs reached through each runtime's profile. Credentials persist only in the owner
# root /work/repos/.auth/<owner>/gh. A repository selects it in its own common-dir config (credential.helper reset, then
# this helper for its github.com/<owner> origin, as the helper's own bind writes); everywhere else gh's config directory
# is the absent procfs path /proc/gh-unselected: gh reads no config and starts from defaults, and procfs lets nobody,
# root included, create it (a read-only directory would not stop root; a non-directory such as /dev/null breaks gh).
# Token and target overrides never win on either path. owner is the declared credential owner of the role or target.
{ pkgs, owner ? "roccho-dev" }:
assert builtins.match "[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?" owner != null;
let
  root = "/work/repos/.auth/${owner}/gh";
  helperName = "git-credential-github-${owner}";
  clear = "unset GH_TOKEN GITHUB_TOKEN GH_ENTERPRISE_TOKEN GITHUB_ENTERPRISE_TOKEN GH_REPO GH_HOST";
  bin = pkgs.lib.makeBinPath [ pkgs.coreutils ];
  # `<helper> bind REPO URL`, the one production binding, dispatched before any credential request is read. Git calls
  # a helper as `<helper> get|store|erase`, so exactly three arguments are required: a helper value carrying `bind ...`
  # gets Git's action appended and is refused. REPO's common-dir config (owned by the caller, no worktree config, no
  # include) receives exactly seven local settings: credential.helper reset, this stable-profile helper for URL and
  # URL.git, useHttpPath, no redirects, origin and push URL equal to URL (an origin of URL.git is rewritten to URL).
  # Each setting must be absent or already equal; any other local credential, http, url or include key, a repeated or
  # different value, or an origin other than URL or URL.git refuses before any write. Repeating is a no-op. A known
  # failure restores, within this same invocation, only what this invocation wrote and still finds unchanged; anything
  # else stays as found and is reported. One public line reports the result; no value or credential is printed.
  # Exit 0 bound (or already bound), 2 invalid invocation, 6 refused (nothing written), 7 failed and restored,
  # 8 failed with a change retained.
  bind = ''
    r=''${2-} u=''${3-} h=$0 prior= writes=0 restored=0 retained=0
    say() { printf 'bind result=%s reason=%s repo=%s url=%s prior=%s writes=%s restored=%s retained=%s\n' \
      "$1" "$2" "$r" "$u" "''${prior:--}" "$writes" "$restored" "$retained"; exit "$3"; }
    [ "$#" = 3 ] || { r=- u=-; say usage argc 2; }
    [[ $r =~ ^/[A-Za-z0-9._/-]+$ ]] || { r=-; say usage repo 2; }
    [[ $u =~ ^https://github\.com/${owner}/([A-Za-z0-9._-]+)$ ]] && [[ ''${BASH_REMATCH[1]} != *.git ]] &&
      [ "''${BASH_REMATCH[1]}" != . ] && [ "''${BASH_REMATCH[1]}" != .. ] || { u=-; say usage url 2; }
    # The value written is this helper's stable profile path, never a store path.
    [[ $h =~ ^/nix/var/nix/profiles/[a-z0-9-]+/bin/${helperName}$ ]] && [ -x "$h" ] &&
      [[ $(readlink -f "$h") == /nix/store/*/bin/${helperName} ]] || say usage helper 2
    g() { GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null ${pkgs.git}/bin/git -C "$r" "$@"; }
    [ -d "$r" ] && [ ! -L "$r" ] || say refused repo 6
    c=$(g rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || say refused repo 6
    me=$(id -u)
    [ -d "$c" ] && [ ! -L "$c" ] && [ -f "$c/config" ] && [ ! -L "$c/config" ] &&
      [ "$(stat -c %u "$c"):$(stat -c %u "$c/config")" = "$me:$me" ] || say refused owner 6
    [ "$(g config --local --get-all extensions.worktreeConfig 2>/dev/null | wc -l)" = 0 ] || say refused worktreeConfig 6
    names=$(g config --local --name-only --get-regexp '^(credential|http|url|include|includeif)\.' 2>/dev/null) ||
      [ "$?" = 1 ] || say refused unreadable 6
    while IFS= read -r n; do
      case $n in
        ""|credential.helper|credential.usehttppath|http.followredirects|"credential.$u.helper"|"credential.$u.git.helper") ;;
        *) say refused unexpected 6 ;;
      esac
    done <<< "$names"
    K=(credential.helper "credential.$u.helper" "credential.$u.git.helper" credential.useHttpPath http.followRedirects
      remote.origin.url remote.origin.pushurl)
    V=("" "$h" "$h" true false "$u" "$u")
    # count:value of one local key; U when Git cannot tell.
    state() {
      local v rc
      v=$(g config --local --get-all "''${K[$1]}" 2>/dev/null) && rc=0 || rc=$?
      case $rc in
        0) printf '%s:%s' "$(g config --local --get-all "''${K[$1]}" 2>/dev/null | wc -l)" "$v" ;;
        1) printf '0:' ;;
        *) printf 'U:' ;;
      esac
    }
    C=()
    for i in "''${!K[@]}"; do
      s=$(state "$i")
      if [ "$s" = 0: ] && [ "$i" != 5 ]; then c=A
      elif [ "$s" = "1:''${V[$i]}" ]; then c=P
      elif [ "$i" = 5 ] && [ "$s" = "1:$u.git" ]; then c=G
      elif [ "$s" = U: ]; then c=U
      else c=X; fi
      C+=("$c"); prior=$prior$c
    done
    case $prior in *U*) say refused unreadable 6 ;; *X*) say refused conflict 6 ;; esac
    fail= wrote=()
    for i in "''${!K[@]}"; do
      case ''${C[$i]} in
        A) wrote+=("$i"); g config --local "''${K[$i]}" "''${V[$i]}" 2>/dev/null || { fail=write; break; } ;;
        G) wrote+=("$i"); g config --local --fixed-value --replace-all remote.origin.url "$u" "$u.git" 2>/dev/null ||
             { fail=write; break; } ;;
        *) continue ;;
      esac
      writes=$((writes + 1))
    done
    if [ -z "$fail" ]; then
      for i in "''${!K[@]}"; do [ "$(state "$i")" = "1:''${V[$i]}" ] || { fail=postimage; break; }; done
    fi
    [ -n "$fail" ] || say ok - 0
    # Known failure: undo only this invocation's writes whose value is still exactly what it wrote.
    for i in "''${wrote[@]}"; do
      s=$(state "$i")
      if [ "''${C[$i]}" = A ]; then
        if [ "$s" = 0: ]; then continue
        elif [ "$s" = "1:''${V[$i]}" ] && g config --local --fixed-value --unset "''${K[$i]}" "''${V[$i]}" 2>/dev/null &&
          [ "$(state "$i")" = 0: ]; then restored=$((restored + 1))
        else retained=$((retained + 1)); fi
      else
        if [ "$s" = "1:$u.git" ]; then continue
        elif [ "$s" = "1:$u" ] && g config --local --fixed-value --replace-all remote.origin.url "$u.git" "$u" 2>/dev/null &&
          [ "$(state "$i")" = "1:$u.git" ]; then restored=$((restored + 1))
        else retained=$((retained + 1)); fi
      fi
    done
    [ "$retained" = 0 ] && say restored "$fail" 7
    say unknown "$fail" 8
  '';
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
      export GH_CONFIG_DIR=/proc/gh-unselected GH_PROMPT_DISABLED=1
    fi
    exec ${pkgs.gh}/bin/gh "$@"
  '';
  # Git's request is key=value lines up to a blank line. For every action (get, store, erase), only protocol=https,
  # host=github.com and a path ${owner}/<repo> (Git sends the path because binding sets useHttpPath) reach the owner
  # root; a missing, repeated or other protocol, host or path gets no answer, no output and no side effect.
  helper = pkgs.writeShellScriptBin helperName ''
    ${clear}
    if [ "''${1-}" = bind ]; then
      export PATH=${bin}
      ${bind}
    fi
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
