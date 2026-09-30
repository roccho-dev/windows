# windows-dev definitions for Issue #2. Gates 1 and 2 (the exact source of the profile in use and the existing
# owner-auth helper) remain open; this profile is the bounded CI0 bootstrap, not F1 acceptance.
{ pkgs }: rec {
  # One-owner GitHub routing per execution.md: a gh wrapper and a git credential helper, immutable outputs that call
  # the absolute in-closure gh with that owner's root as GH_CONFIG_DIR. Tools binds each clone to the helper; Run
  # excludes system and global Git configuration and prompts.
  ghRoot = "/work/repos/.auth/roccho-dev/gh";
  ghWrapper = pkgs.writeShellScriptBin "gh" ''
    export GH_CONFIG_DIR=${ghRoot}
    exec ${pkgs.gh}/bin/gh "$@"
  '';
  ghCredential = pkgs.writeShellScriptBin "git-credential-github-roccho-dev" ''
    export GH_CONFIG_DIR=${ghRoot}
    exec ${pkgs.gh}/bin/gh auth git-credential "$@"
  '';

  # Local real-Jev prerequisite (roccho-dev/adrs#460): two bounded tools over exactly three build-time constants.
  # Only the production instance below is linked into the profile; oci/dev/proof.sh builds a fixture instance of this
  # same source. sops, age and age-keygen are reached by absolute store path inside these closures, never via PATH.
  jevTools = { envsRemote, appsRemote, identity }: let
    q = pkgs.lib.escapeShellArg;
  in {
    # Creates the target identity once: fixed path, safe parent, exclusive create, public recipient output only.
    init = pkgs.writeShellApplication {
      name = "jev-age-init";
      text = ''
        set +o xtrace
        umask 077
        identity=${q identity}
        cu=${pkgs.coreutils}/bin
        fail() {
          echo "jev-age-init: RED: $1" >&2
          exit 1
        }
        [ "$#" -eq 0 ] || fail "takes no arguments"
        { [ ! -e "$identity" ] && [ ! -L "$identity" ]; } || fail "the target identity exists and is never overwritten"
        dir=$("$cu/dirname" "$identity")
        "$cu/mkdir" -p "$dir"
        { [ -d "$dir" ] && [ ! -L "$dir" ]; } || fail "the identity directory is not a real directory"
        [ "$("$cu/stat" -c %u "$dir")" = "$("$cu/id" -u)" ] || fail "the identity directory is not owned by this user"
        [ $(( 8#$("$cu/stat" -c %a "$dir") & 8#022 )) -eq 0 ] || fail "the identity directory is writable by others"
        tmp=$("$cu/mktemp" "$dir/.identity.XXXXXX")
        trap '"$cu/rm" -f "$tmp"' EXIT
        ${pkgs.age}/bin/age-keygen 2>/dev/null > "$tmp" || fail "age-keygen failed"
        # A hard link is created atomically and never replaces an existing file.
        "$cu/ln" -T "$tmp" "$identity" 2>/dev/null || fail "the target identity exists and is never overwritten"
        ${pkgs.age}/bin/age-keygen -y "$identity"
      '';
    };
    # Starts the exact apps dev server in the foreground with JEV_API_KEY as the only secret in its environment.
    launch = pkgs.writeShellApplication {
      name = "voice-ui-jev-dev";
      text = ''
        set +o xtrace
        ulimit -c 0
        umask 077
        envs_remote=${q envsRemote}
        apps_remote=${q appsRemote}
        identity=${q identity}
        cu=${pkgs.coreutils}/bin
        grep=${pkgs.gnugrep}/bin/grep
        cipher_path=ciphertexts/dev-jev-api.oci-dev.sops.yaml
        usage() {
          echo "usage: voice-ui-jev-dev --envs-sha <40-hex> --apps-sha <40-hex> --port <1024-65535>" >&2
          exit 2
        }
        fail() {
          echo "voice-ui-jev-dev: RED: $1" >&2
          exit 1
        }
        git_() {
          GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_TERMINAL_PROMPT=0 ${pkgs.git}/bin/git -c credential.helper= "$@"
        }
        nix_() {
          ${pkgs.nix}/bin/nix --extra-experimental-features 'nix-command flakes' "$@"
        }

        envs_sha="" apps_sha="" port=""
        [ "$#" -eq 6 ] || usage
        while [ "$#" -gt 0 ]; do
          case "$1" in
            --envs-sha) [ -z "$envs_sha" ] || usage; envs_sha=$2 ;;
            --apps-sha) [ -z "$apps_sha" ] || usage; apps_sha=$2 ;;
            --port) [ -z "$port" ] || usage; port=$2 ;;
            *) usage ;;
          esac
          shift 2
        done
        [[ $envs_sha =~ ^[0-9a-f]{40}$ && $apps_sha =~ ^[0-9a-f]{40}$ && $port =~ ^[1-9][0-9]{3,4}$ ]] || usage
        { [ "$port" -ge 1024 ] && [ "$port" -le 65535 ]; } || usage
        [ ! -e /homeless-shelter ] || fail "/homeless-shelter exists; the child's HOME must not exist"

        # The ciphertext: at a commit on envs proposals, and exactly the one proposals carries now.
        # The scratch directory holds only public data. Git is pinned to write only the files scratch_clear names (no
        # template, packed objects, no automatic maintenance); they are removed one by one, then the empty
        # directories, on exit and before the child. Anything else is kept and the launch is RED.
        work=$("$cu/mktemp" -d)
        repo=$work/envs.git
        scratch_clear() {
          [ -e "$work" ] || return 0
          local f d
          # Only regular files are removed; a link, FIFO, directory or other type at a known name is kept.
          for f in "$repo"/objects/pack/*; do
            [[ ''${f##*/} =~ ^pack-[0-9a-f]{40}([0-9a-f]{24})?\.(pack|idx|rev)$ ]] || continue
            if [ -L "$f" ] || [ ! -f "$f" ]; then return 1; fi
            "$cu/rm" -f -- "$f"
          done
          for f in "$work/cipher.yaml" "$repo/HEAD" "$repo/config" "$repo/FETCH_HEAD" "$repo/packed-refs" \
            "$repo/refs/heads/proposals"; do
            if [ -L "$f" ] || { [ -e "$f" ] && [ ! -f "$f" ]; }; then return 1; fi
            "$cu/rm" -f -- "$f"
          done
          for d in "$repo/objects/pack" "$repo/objects/info" "$repo/objects" "$repo/refs/heads" "$repo/refs/tags" \
            "$repo/refs" "$repo" "$work"; do
            [ ! -e "$d" ] || "$cu/rmdir" -- "$d" 2>/dev/null || return 1
          done
        }
        trap 'scratch_clear || echo "voice-ui-jev-dev: kept $work: unexpected scratch entries" >&2' EXIT
        git_ init -q --bare --template= "$repo"
        git_ -c fetch.unpackLimit=1 -c transfer.unpackLimit=1 -c gc.auto=0 -c maintenance.auto=false \
          -c fetch.writeCommitGraph=false -C "$repo" fetch -q --no-tags "$envs_remote" \
          "+refs/heads/proposals:refs/heads/proposals" || fail "cannot fetch envs proposals"
        git_ -C "$repo" cat-file -e "$envs_sha^{commit}" 2>/dev/null || fail "the envs commit is not on proposals"
        git_ -C "$repo" merge-base --is-ancestor "$envs_sha" proposals || fail "the envs commit is not on proposals"
        at=$(git_ -C "$repo" rev-parse -q --verify "$envs_sha:$cipher_path") || fail "no OCI ciphertext at that envs commit"
        now=$(git_ -C "$repo" rev-parse -q --verify "proposals:$cipher_path") || fail "envs proposals has no OCI ciphertext"
        [ "$at" = "$now" ] || fail "that envs commit's OCI ciphertext is not the current one"
        cipher=$work/cipher.yaml
        git_ -C "$repo" cat-file blob "$at" > "$cipher"
        fields=$("$grep" -E '^[^[:space:]#][^:]*:' "$cipher" | "$cu/cut" -d: -f1 | "$cu/sort" | "$cu/tr" '\n' ' ')
        [ "$fields" = "JEV_API_KEY sops " ] || fail "the ciphertext fields differ"
        "$grep" -q '^JEV_API_KEY: ENC\[AES256_GCM,' "$cipher" || fail "the ciphertext is not SOPS-encrypted"
        recipients=$("$grep" -E '^[[:space:]]*-?[[:space:]]*recipient:[[:space:]]*age1[0-9a-z]+[[:space:]]*$' "$cipher" \
          | "$grep" -oE 'age1[0-9a-z]+' || true)
        { [ -n "$recipients" ] && [ "$(echo "$recipients" | "$cu/wc" -l)" -eq 1 ]; } \
          || fail "the ciphertext must have exactly one recipient"

        # The identity: a regular 0600 file of this user whose recipient is the ciphertext's.
        { [ -f "$identity" ] && [ ! -L "$identity" ]; } || fail "the target identity is missing"
        [ "$("$cu/stat" -c %a "$identity")" = 600 ] || fail "the target identity must have mode 0600"
        [ "$("$cu/stat" -c %u "$identity")" = "$("$cu/id" -u)" ] || fail "the target identity must belong to this user"
        own=$(${pkgs.age}/bin/age-keygen -y "$identity" 2>/dev/null) || fail "the target identity is unreadable"
        [ "$own" = "$recipients" ] || fail "the ciphertext is not for this target identity"

        # The exact apps program, evaluated and realized before anything is decrypted.
        ref="git+$apps_remote?rev=$apps_sha"
        program=$(nix_ eval --raw "$ref#apps.x86_64-linux.dev.program") || fail "cannot evaluate the apps dev program"
        drv=$(nix_ eval --raw "$ref#apps.x86_64-linux.dev.program" --apply \
          'p: let c = builtins.attrNames (builtins.getContext p); in if builtins.length c == 1 then builtins.head c else throw "not one derivation"') \
          || fail "the apps dev program is not one derivation"
        outs=$(nix_ build --no-link --print-out-paths "$drv^*") || fail "cannot build the apps dev program"
        built=""
        while read -r out; do
          case "$program" in "$out" | "$out"/*) built=$out ;; esac
        done <<< "$outs"
        { [ -n "$built" ] && [ -x "$program" ]; } || fail "the built program is not the evaluated one"
        echo "voice-ui-jev-dev: built $program"

        echo "voice-ui-jev-dev: decrypt envs $envs_sha ciphertext $at recipient $recipients"
        key=$(SOPS_AGE_KEY_FILE=$identity ${pkgs.sops}/bin/sops --decrypt --input-type yaml --extract '["JEV_API_KEY"]' \
          "$cipher" 2>/dev/null) || fail "decryption failed"
        [ -n "$key" ] || fail "the decrypted key is empty"
        scratch_clear || fail "kept $work: unexpected scratch entries"
        trap - EXIT

        # One foreground child whose environment is built from nothing (env -i). The key reaches it only through a pipe
        # from a builtin, never argv or a file; with lastpipe the launcher itself becomes the child.
        echo "voice-ui-jev-dev: apps $apps_sha on 127.0.0.1:$port with PATH HOME LANG PORT HOST JEV_API_KEY"
        shopt -s lastpipe
        # shellcheck disable=SC2016
        printf '%s' "$key" | exec "$cu/env" -i PATH="$cu" HOME=/homeless-shelter LANG=C.UTF-8 PORT="$port" HOST=127.0.0.1 \
          ${pkgs.bash}/bin/bash -c 'IFS= read -r -d "" JEV_API_KEY || true; export JEV_API_KEY; exec env -u PWD -u SHLVL -u OLDPWD -- "$0"' \
          "$program"
      '';
    };
  };
  jev = jevTools {
    envsRemote = "https://github.com/roccho-dev/envs";
    appsRemote = "https://github.com/roccho-dev/apps";
    identity = "/work/repos/.auth/roccho-dev/age/oci-dev.key";
  };

  # The tools that the Tools step realizes into /nix/var/nix/profiles/windows-dev.
  profile = pkgs.buildEnv {
    name = "windows-dev";
    paths = (with pkgs; [ bash coreutils git cacert openssh ]) ++ [ ghWrapper ghCredential jev.init jev.launch ];
    pathsToLink = [ "/bin" "/etc/ssl" ];
  };

  # A trusted, single-user development image, not an own/rent runtime image.
  # Nix's database AND closure are seeded together by the existing Init pattern:
  # run this exact image with the empty nix volume at /seed, copy /nix/., then
  # mount that volume at /nix for use. Recreate with the same image identity.
  # A different image uses a fresh nix cache; retain work and the old cache for rollback.
  image = pkgs.dockerTools.buildLayeredImage {
    name = "ghcr.io/roccho-dev/windows-dev";
    tag = "nix";
    contents = [ profile pkgs.nix pkgs.curl ];
    includeNixDB = true;
    extraCommands = ''
      mkdir -p etc/nix home/dev tmp work/repos nix/var/nix/profiles
      chmod 1777 tmp
      printf 'root:x:0:0:Trusted development core:/home/dev:/bin/bash\n' > etc/passwd
      printf 'root:x:0:\n' > etc/group
      printf 'hosts: files dns\n' > etc/nsswitch.conf
      cat > etc/nix/nix.conf <<'EOF'
      experimental-features = nix-command flakes
      build-users-group =
      sandbox = false
      accept-flake-config = false
      EOF
      printf 'export PATH=/nix/var/nix/profiles/windows-dev/bin:/bin\n' > etc/profile
      ln -s ${profile} nix/var/nix/profiles/windows-dev
    '';
    config = {
      Cmd = [ "/bin/bash" "--login" ];
      WorkingDir = "/work/repos";
      Env = [
        "HOME=/home/dev"
        "USER=root"
        "NIX_REMOTE=local"
        "PATH=/nix/var/nix/profiles/windows-dev/bin:/bin"
        "NIX_SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"
        "SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"
        "GIT_SSL_CAINFO=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"
        "GIT_CONFIG_NOSYSTEM=1"
        "GIT_CONFIG_GLOBAL=/dev/null"
        "GIT_TERMINAL_PROMPT=0"
      ];
      # No anonymous volumes, published ports, daemon, host integration or auth import.
      Labels."org.opencontainers.image.source" = "https://github.com/roccho-dev/windows";
    };
  };
}
