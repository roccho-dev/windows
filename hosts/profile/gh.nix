# GitHub routing by declared principal (Issue #8-C), one definition for own, rent and dev: the gh wrapper and the Git
# credential helper, immutable outputs reached through each runtime's profile. A repository's own common-dir config is
# the only declaration: its canonical origin https://github.com/<namespace>/<repo> and, for that URL, this helper and the
# expected principal (credential.<URL>.username), as the helper's own bind writes. The namespace never names the
# principal: hc-consul-pj/<repo> may be used as mti-takasawa and roccho-dev/<repo> as roccho-dev in the same profile.
# Credentials persist only in the principal's slot /work/repos/.auth/<principal>/gh, gh's own file storage. Everywhere
# else gh's config directory is the absent procfs path /proc/gh-unselected: gh reads no config and starts from defaults,
# and procfs lets nobody, root included, create it (a read-only directory would not stop root; a non-directory such as
# /dev/null breaks gh). Token and target overrides never win on either path.
#
# What a selection proves: the exact declaration above, read as bind checks it (the repository's common-dir config is
# the caller's own and holds the nine settings bind writes, each exactly once, this helper at a stable profile path, no
# other local credential, http, url or include key and no worktree config), a slot that is a current-format
# (version "1") gh file store (a real directory of regular files), and that the pinned native gh answers for the
# declared principal as its configured active user. Selection only reads; it never writes, repairs or rebinds a
# repository. It does not prove the token's provider principal: an account added, copied or swapped into a slot is not
# detected. A slot is accepted only through separately authorized custody (first login, refresh, loss recovery, any copy, import or added
# login): the pinned native gh with GH_CONFIG_DIR=<slot>, the same D-Bus and token guards and explicit
# `auth login --hostname github.com --git-protocol https --insecure-storage`, never through this wrapper; then only the
# declared account in the slot's gh account metadata, `gh api --hostname github.com user --jq .login` from the same slot
# equal to it, and the repository operations actually needed checked independently (read is not write). A lost or
# refused slot stays refused until that custody replaces it; the same repository binding is then reused unchanged.
#
# owner only names this profile's stable helper (git-credential-github-<owner>, kept for existing bindings); it selects
# no namespace, principal or slot.
{ pkgs, owner ? "roccho-dev" }:
assert builtins.match "[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?" owner != null;
let
  helperName = "git-credential-github-${owner}";
  clear = "unset GH_TOKEN GITHUB_TOKEN GH_ENTERPRISE_TOKEN GITHUB_ENTERPRISE_TOKEN GH_REPO GH_HOST";
  # gh's keyring is the D-Bus Secret Service; a non-empty address is dialled as given and never searched for elsewhere,
  # so this absent procfs socket closes any ambient keyring for gh's own process tree.
  nobus = "export DBUS_SESSION_BUS_ADDRESS=unix:path=/proc/gh-unselected";
  bin = pkgs.lib.makeBinPath [ pkgs.coreutils ];
  name = "[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?";
  # Read-only reads of repository r's own common-dir config (system and global Git configuration are not read), shared
  # by bind and the selection so both check one declaration.
  decl = ''
    g() { GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null ${pkgs.git}/bin/git -C "$r" "$@"; }
    # count:value of one local key, counting every record Git returns (an added empty value included); U when Git
    # cannot tell, either read failing (the key gone between them included).
    st() {
      local v rc n
      v=$(g config --local --get-all "$1" 2>/dev/null) && rc=0 || rc=$?
      case $rc in
        0) n=$(set -o pipefail; g config --local --get-all "$1" 2>/dev/null | ${bin}/wc -l) || { printf 'U:'; return; }
           printf '%s:%s' "$n" "$v" ;;
        1) printf '0:' ;;
        *) printf 'U:' ;;
      esac
    }
    # r is a real repository whose common-dir and its config are the caller's own regular files, with no worktree
    # config and no local credential, http, url or include key other than the nine for u; otherwise why names the refusal.
    owned() {
      local c n names
      [ -d "$r" ] && [ ! -L "$r" ] || { why=repo; return 1; }
      c=$(g rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || { why=repo; return 1; }
      [ -d "$c" ] && [ ! -L "$c" ] && [ -f "$c/config" ] && [ ! -L "$c/config" ] &&
        [ "$(${bin}/stat -c %u "$c"):$(${bin}/stat -c %u "$c/config")" = "$(${bin}/id -u):$(${bin}/id -u)" ] ||
        { why=owner; return 1; }
      [ "$(g config --local --get-all extensions.worktreeConfig 2>/dev/null | ${bin}/wc -l)" = 0 ] ||
        { why=worktreeConfig; return 1; }
      names=$(g config --local --name-only --get-regexp '^(credential|http|url|include|includeif)\.' 2>/dev/null) ||
        [ "$?" = 1 ] || { why=unreadable; return 1; }
      while IFS= read -r n; do
        case $n in
          ""|credential.helper|credential.usehttppath|http.followredirects|"credential.$u.helper"|"credential.$u.git.helper"|\
            "credential.$u.username"|"credential.$u.git.username") ;;
          *) why=unexpected; return 1 ;;
        esac
      done <<< "$names"
    }
    # The nine settings for URL u, helper value h and principal pr.
    nine() {
      K=(credential.helper "credential.$u.helper" "credential.$u.git.helper" "credential.$u.username"
        "credential.$u.git.username" credential.useHttpPath http.followRedirects remote.origin.url remote.origin.pushurl)
      V=("" "$h" "$h" "$pr" "$pr" true false "$u" "$u")
    }
  '';
  # The selection both the helper and the wrapper make, in the current repository, never writing its config. pick
  # sets u (canonical URL), slug (<namespace>/<repo>), p (principal) and root only if the repository passes bind's own
  # checks and holds exactly the nine settings, with h a stable profile path of this helper (self, its store file).
  # answer asks the pinned native gh, with a fresh request carrying only path and the declared principal, and
  # succeeds only if its reply names exactly that principal with a password (an empty active user answers x-access-token).
  # The reply stays in this process's memory; nothing is printed, logged or exported.
  select = ''
    one() { local s; s=$(st "$1"); [[ $s == 1:?* ]] || return 1; printf '%s' "''${s#1:}"; }
    pick() {
      local i k l n=0 r=. h pr why
      u=$(one remote.origin.url) || return 1
      [[ $u =~ ^https://github\.com/(${name})/([A-Za-z0-9._-]+)$ ]] && [[ ''${BASH_REMATCH[3]} != *.git ]] &&
        [ "''${BASH_REMATCH[3]}" != . ] && [ "''${BASH_REMATCH[3]}" != .. ] || return 1
      slug=''${u#https://github.com/}
      owned || return 1
      h=$(one "credential.$u.helper") && pr=$(one "credential.$u.username") || return 1
      [[ $h =~ ^/nix/var/nix/profiles/[a-z0-9-]+/bin/${helperName}$ ]] && [ "$(${bin}/readlink -f "$h")" = "$self" ] ||
        return 1
      [[ $pr =~ ^${name}$ ]] && [ "$pr" != x-access-token ] || return 1
      nine
      for i in "''${!K[@]}"; do [ "$(st "''${K[$i]}")" = "1:''${V[$i]}" ] || return 1; done
      p=$pr root=/work/repos/.auth/$pr/gh
      [ -d "$root" ] && [ ! -L "$root" ] || return 1
      for k in config.yml hosts.yml; do [ -f "$root/$k" ] && [ ! -L "$root/$k" ] || return 1; done
      # gh 2.96.0 migrates and rewrites any config without version "1" as it starts: such a slot is refused first.
      while IFS= read -r l; do [ "$l" = 'version: "1"' ] && n=$((n + 1)); done < "$root/config.yml"
      [ "$n" = 1 ]
    }
    answer() {
      local l n=0 w=0
      reply=$(printf 'protocol=https\nhost=github.com\npath=%s\nusername=%s\n\n' "$path" "$p" |
        GH_CONFIG_DIR=$root ${pkgs.gh}/bin/gh auth git-credential get 2>/dev/null) || return 1
      while IFS= read -r l; do
        case $l in "username=$p") n=$((n + 1)) ;; username=*) return 1 ;; password=?*) w=$((w + 1)); secret=''${l#password=} ;; esac
      done <<< "$reply"
      reply=
      [ "$n" = 1 ] && [ "$w" = 1 ]
    }
  '';
  # `<helper> bind REPO URL PRINCIPAL`, the one production binding, dispatched before any credential request is read.
  # Git calls a helper as `<helper> get|store|erase`, so exactly four arguments are required: a helper value carrying
  # `bind ...` gets Git's action appended and is refused. URL is the canonical https://github.com/<namespace>/<repo>
  # (any namespace); PRINCIPAL is the declared GitHub account, never derived from URL. REPO's common-dir config (owned by
  # the caller, no worktree config, no include) receives exactly nine local settings: credential.helper reset, this
  # stable-profile helper and PRINCIPAL as username for URL and URL.git, useHttpPath, no redirects, origin and push URL
  # equal to URL (an origin of URL.git is rewritten to URL). Each setting must be absent or already equal; any other
  # local credential, http, url or include key, a repeated or different value (another principal included), or an origin
  # other than URL or URL.git refuses before any write. A clone bound by the earlier seven settings gains only the two
  # usernames. Repeating is a no-op. A known failure restores, within this same invocation, only what this invocation
  # wrote and still finds unchanged; anything else stays as found and is reported. One public line reports the result; no
  # value or credential is printed. Exit 0 bound (or already bound), 2 invalid invocation, 6 refused (nothing written),
  # 7 failed and restored, 8 failed with a change retained.
  bind = ''
    r=''${2-} u=''${3-} pr=''${4-} h=$0 prior= writes=0 restored=0 retained=0
    say() { printf 'bind result=%s reason=%s repo=%s url=%s prior=%s writes=%s restored=%s retained=%s\n' \
      "$1" "$2" "$r" "$u" "''${prior:--}" "$writes" "$restored" "$retained"; exit "$3"; }
    [ "$#" = 4 ] || { r=- u=-; say usage argc 2; }
    [[ $r =~ ^/[A-Za-z0-9._/-]+$ ]] || { r=-; say usage repo 2; }
    [[ $u =~ ^https://github\.com/(${name})/([A-Za-z0-9._-]+)$ ]] && [[ ''${BASH_REMATCH[3]} != *.git ]] &&
      [ "''${BASH_REMATCH[3]}" != . ] && [ "''${BASH_REMATCH[3]}" != .. ] || { u=-; say usage url 2; }
    [[ $pr =~ ^${name}$ ]] && [ "$pr" != x-access-token ] || say usage principal 2
    # The value written is this helper's stable profile path, never a store path.
    [[ $h =~ ^/nix/var/nix/profiles/[a-z0-9-]+/bin/${helperName}$ ]] && [ -x "$h" ] &&
      [[ $(readlink -f "$h") == /nix/store/*/bin/${helperName} ]] || say usage helper 2
    owned || say refused "$why" 6
    nine
    state() { st "''${K[$1]}"; }
    C=()
    for i in "''${!K[@]}"; do
      s=$(state "$i")
      if [ "$s" = 0: ] && [ "$i" != 7 ]; then c=A
      elif [ "$s" = "1:''${V[$i]}" ]; then c=P
      elif [ "$i" = 7 ] && [ "$s" = "1:$u.git" ]; then c=G
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
  # Git's request is key=value lines up to a blank line; only protocol, host, path and username are read, each at most
  # once. get answers only in a bound repository, for protocol=https, host=github.com, the path of its exact origin
  # (<namespace>/<repo> or <namespace>/<repo>.git, never a prefix or another segment) and its declared principal as
  # username; the native gh then gets a fresh request of those fields only (no url, password or other field passes) and
  # its reply is passed on only if it names that principal. store and erase are native no-ops: after the request they
  # read no repository config and no slot. Anything else gets no answer, no output and no side effect.
  helper = pkgs.writeShellScriptBin helperName ''
    ${clear}
    ${nobus}
    ${decl}
    if [ "''${1-}" = bind ]; then
      export PATH=${bin}
      ${bind}
    fi
    case "$#:''${1-}" in 1:get|1:store|1:erase) ;; *) exit 0 ;; esac
    protocol= host= path= username= seen=
    while IFS= read -r line && [ -n "$line" ]; do
      key=''${line%%=*}
      case $key in protocol|host|path|username) ;; *) continue ;; esac
      case " $seen " in *" $key "*) exit 0 ;; esac
      seen="$seen $key"
      printf -v "$key" '%s' "''${line#*=}"
    done
    [ "$1" = get ] || exit 0
    self=$(${bin}/readlink -f "$0")
    ${select}
    pick || exit 0
    [ "$protocol" = https ] && [ "$host" = github.com ] && [ "$username" = "$p" ] || exit 0
    [ "$path" = "$slug" ] || [ "$path" = "$slug.git" ] || exit 0
    answer || exit 0
    printf 'username=%s\npassword=%s\n' "$p" "$secret"
  '';
in
{
  inherit helper;
  # gh selects the declared principal's slot only in a bound repository whose slot the native gh answers for that
  # principal; otherwise it runs unselected. Target flags (-R, --hostname) never change the selected slot.
  wrapper = pkgs.writeShellScriptBin "gh" ''
    ${clear}
    ${nobus}
    export GH_NO_UPDATE_NOTIFIER=1
    self=${helper}/bin/${helperName}
    ${decl}
    ${select}
    if pick && path=$slug && answer; then
      export GH_CONFIG_DIR=$root
    else
      export GH_CONFIG_DIR=/proc/gh-unselected GH_PROMPT_DISABLED=1
    fi
    secret= reply=
    exec ${pkgs.gh}/bin/gh "$@"
  '';
}
