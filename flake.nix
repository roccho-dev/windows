{
  description = "own and rent WSLC OCI images";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/35d3407a3816f3b341d8cf1d60abaf2b7b8166ac";

  outputs = { self, nixpkgs }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs { inherit system; };
      gitState = import ./infra/git-state/nix.nix { inherit pkgs; };
      githubRoot = import ./infra/github/nix.nix { inherit pkgs; backend = gitState.backend; };
      ownSpec = builtins.fromJSON (builtins.readFile ./hosts/own/spec.json);
      # The target's declared owner names own's stable gh helper (rent keeps the default); each repository's principal
      # is the one its own binding declares (hosts/profile/gh.nix).
      ownOwner = (builtins.fromJSON (builtins.readFile ./hosts/own/bindings/G6I3.json)).owner;
      # CI only, never published or applied: another declared own target. Every site value, the credential owner
      # included, differs from the G6I3 sample; the role and the image publisher are the own role's invariants.
      ciAltBinding = {
        role = "own"; site = "ALTSITE"; expectHost = "ALTHOST"; owner = "alt-owner"; session = "wslc-cli-alt";
        sshAlias = "alt-own"; container = "alt-own"; hostPort = 2224;
        volume = "alt-own-home"; workVolume = "alt-own-work"; nixVolume = "alt-own-nix";
        publicKeyFile = "%USERPROFILE%\\.ssh\\id_alt_wslc.pub"; privateKeyFile = "/work/repos/.auth/ssh/alt-own/id_ed25519";
        knownHostsFile = "%USERPROFILE%\\.ssh\\known_hosts_alt"; windowsIdentityFile = "%USERPROFILE%\\.ssh\\id_alt";
        image = "ghcr.io/roccho-dev/windows-own@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
        imageFrom = "CI-only alternate target fixture";
      };
      ciAlt = import ./hosts/common/nix.nix { inherit pkgs; source = "uncommitted"; ownBinding = ciAltBinding; };
      # own on the same common dev profile as rent; the generic mountLib and multi-user nix.conf are shared, unchanged.
      ownFor = { profile, tag }: import ./hosts/own/nix.nix {
        inherit pkgs profile tag mountLib;
        spec = ownSpec;
        nixConf = rentNixConf;
      };
      own = ownFor { profile = import ./hosts/profile/nix.nix { inherit pkgs; owner = ownOwner; }; tag = "nix"; };
      dev = import ./oci/dev/nix.nix { inherit pkgs; };
      common = import ./hosts/common/nix.nix {
        inherit pkgs;
        source = self.rev or "uncommitted";
      };
      ownConfig = own.config;
      # rent: tools live in the image; /home/dev is fresh per container; /var/lib/rent (state), /work/repos (existing
      # repos, never copied or chowned) and /nix (rent's own writable store, seeded from the image) are volumes.
      rentState = "/var/lib/rent";
      rentCert = "/etc/ssl/certs/ca-certificates.crt";
      # Fixed Cloudflare tunnel token slot in the state volume; envs places it, the image never carries a token.
      rentToken = "${rentState}/cloudflared/token";
      # Written once into a seeded rent /nix volume; nothing else may be seeded or run as rent's store.
      rentNixMarker = "windows-rent-nix v1";
      # Multi-user Nix: the daemon (root) owns the store; builds run as nixbld users; dev is an untrusted client.
      rentNixConf = pkgs.writeText "rent-nix.conf" ''
        experimental-features = nix-command flakes
        build-users-group = nixbld
        sandbox = false
        trusted-users = root
      '';
      # set_profile ROOT TARGET: make ROOT/var/nix/profiles/rent-dev point at TARGET through a new generation link,
      # unless it already does. Older generations stay as rollback targets and GC roots.
      profileLib = ''
        set_profile() {
          local d="$1/var/nix/profiles" g n=0
          install -d -m 755 "$d"
          if [ -L "$d/rent-dev" ]; then
            g=$(readlink "$d/rent-dev")
            [[ $g =~ ^rent-dev-[0-9]+-link$ ]] && [ -L "$d/$g" ] || { echo "$d/rent-dev is not a generation link" >&2; exit 1; }
            [ "$(readlink "$d/$g")" != "$2" ] || return 0
          elif [ -e "$d/rent-dev" ]; then
            echo "$d/rent-dev exists and is not a link" >&2; exit 1
          fi
          for g in "$d"/rent-dev-*-link; do
            [ -L "$g" ] || continue
            g=''${g##*/rent-dev-}; g=''${g%-link}
            [ "$g" -le "$n" ] || n=$g
          done
          n=$((n + 1))
          ln -s "$2" "$d/rent-dev-$n-link"
          ln -sfn "rent-dev-$n-link" "$d/.rent-dev.new"
          mv -T "$d/.rent-dev.new" "$d/rent-dev"
        }
      '';
      # The one mount authority: this container's own /proc/self/mountinfo, read within 10 s. A named volume is a
      # mount whose root ends in /volumes/<name>/_data, as WSLC and Docker both report; WSLC inspect Mounts is not used.
      mountLib = ''
        mounts=$(timeout 10 cat /proc/self/mountinfo) || { echo "$(basename "$0"): mountinfo unreadable within 10 s" >&2; exit 1; }
        # target name mode: exactly one mount at target, and it is that named volume with that mode.
        volume_at() {
          local n=0 ok=1 _id _parent _dev root mp opts _rest
          while read -r _id _parent _dev root mp opts _rest; do
            [ "$mp" = "$1" ] || continue
            n=$((n + 1))
            case "$root" in */volumes/"$2"/_data) ;; *) ok=0 ;; esac
            case ",$opts," in *,"$3",*) ;; *) ok=0 ;; esac
          done <<< "$mounts"
          [ "$n" = 1 ] && [ "$ok" = 1 ]
        }
        volume_count() {
          local n=0 _id _parent _dev root _rest
          while read -r _id _parent _dev root _rest; do
            case "$root" in */volumes/*/_data) n=$((n + 1)) ;; esac
          done <<< "$mounts"
          echo "$n"
        }
        mounted() {
          local _id _parent _dev _root mp _rest
          while read -r _id _parent _dev _root mp _rest; do [ "$mp" = "$1" ] && return 0; done <<< "$mounts"
          return 1
        }
        volume_name() { case ''${1:-} in ""|*[!a-z0-9-]*) return 1 ;; esac; }
      '';
      # Typed import of exactly the selected items from an old home mounted read-only at /old into the state volume:
      # credentials (Claude .credentials.json), session (the one session's journal and its directory, a related pair) and
      # codex (Codex auth.json), each named at most once. The fixed parents on both sides must be real directories.
      # Content, type, owner and mode, symlinks not followed, are compared before anything is written, and any read
      # failure is a refusal: every selected item equal is a success with no write, and --compare only reports. Each
      # differing item is copied beside its target and checked against the source evidence taken once; the source must
      # still match it; then the original is renamed to <target>.prior (never overwritten) and the copy renamed into place.
      # That evidence, and the originals', lives only in this process's memory: on a failure after the first rename, each
      # changed item is put back only from a prior that still matches its original, and verified. Exit 0 unchanged, 10
      # updated, 11 updated with a staging directory kept after its removal failed, 20 refused with no target changed (a staging copy may
      # remain), 21 failed and restored; anything else (a crash, drift, unreadable evidence or an unverified restore) is
      # UNKNOWN. Never run by rent-start; prints item paths only.
      stateImport = pkgs.writeShellScriptBin "rent-state-import" ''
        set -eu
        export PATH=${pkgs.lib.makeBinPath [ pkgs.coreutils pkgs.diffutils pkgs.findutils pkgs.util-linux ]}
        fail() { echo "rent-state-import: $*" >&2; exit 20; }
        compare=0
        if [ "''${1:-}" = --compare ]; then compare=1; shift; fi
        project=-home-dev
        if [ "''${1:-}" = --project ]; then
          [ "$#" -ge 2 ] || fail '--project needs one plain project element'
          project=$2; shift 2
        fi
        [[ $project =~ ^[A-Za-z0-9_.-]+$ && $project != . && $project != .. ]] ||
          fail 'project must be one plain element'
        id=''${1:-}
        [[ $id =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] && [ "$#" -ge 2 ] ||
          fail 'usage: rent-state-import [--compare] [--project <element>] <session-uuid> credentials|session|codex...'
        shift
        ${mountLib}
        oldvol=''${RENT_OLD_VOLUME:-}
        statevol=''${RENT_STATE_VOLUME:-}
        volume_name "$oldvol" && volume_name "$statevol" || fail 'set RENT_OLD_VOLUME and RENT_STATE_VOLUME to volume names'
        volume_at /old "$oldvol" ro || fail "/old must be exactly volume $oldvol, mounted read-only"
        volume_at ${rentState} "$statevol" rw || fail "${rentState} must be exactly volume $statevol, writable"
        # The state-root lock a running rent holds: no import while it (or another writer) runs.
        exec 9<${rentState}
        flock -x -n 9 || fail "${rentState} is in use by a running rent or another writer"
        s=${rentState}/dev
        p=projects/$project
        items=() seen=
        for item in "$@"; do
          case " $seen " in *" $item "*) fail "item $item is named twice" ;; esac
          seen="$seen $item"
          case $item in
            credentials) items+=("/old/.claude/.credentials.json|$s/claude/.credentials.json|f") ;;
            session) items+=("/old/.claude/$p/$id|$s/claude/$p/$id|d" "/old/.claude/$p/$id.jsonl|$s/claude/$p/$id.jsonl|f") ;;
            codex) items+=("/old/.codex/auth.json|$s/codex/auth.json|f") ;;
            *) fail "unknown item $item" ;;
          esac
        done
        # The fixed parents on both sides, where they exist, are real directories: nothing is followed out of the paths.
        for d in /old/.claude /old/.claude/projects "/old/.claude/$p" /old/.codex "$s" "$s/claude" "$s/claude/projects" "$s/claude/$p" "$s/codex"; do
          if [ -L "$d" ] || { [ -e "$d" ] && [ ! -d "$d" ]; }; then fail "$d is not a real directory"; fi
        done
        case " $seen " in *' session '*)
          [ -d "/old/.claude/$p" ] && [ "$(stat -c %u "/old/.claude/$p")" = 1000 ] ||
            fail 'source project must be a UID 1000 directory'
          if [ -e "$s/claude/$p" ] && [ "$(stat -c %u "$s/claude/$p")" != 1000 ]; then
            fail 'target project must be a UID 1000 directory'
          fi
          ;; esac
        # Content, type, owner and mode of one file or tree, symlinks not followed, or 'absent'; any read failure fails.
        # Held only in this process's memory, never printed.
        state() {
          local out
          if [ -L "$1" ] || { [ -e "$1" ] && [ ! -d "$1" ]; }; then
            out=$(stat -c '%F|%u|%g|%a' "$1") || return 1
            if [ -f "$1" ] && [ ! -L "$1" ]; then out="$out|$(sha256sum < "$1")" || return 1; fi
          elif [ -d "$1" ]; then
            out=$(set -o pipefail; cd "$1" && find . -printf '%p|%y|%U|%G|%m|%l\n' | LC_ALL=C sort &&
              find . -type f -exec sha256sum {} + | LC_ALL=C sort) || return 1
          else out=absent; fi
          printf '%s\n' "$out"
        }
        changed=() srcs=()
        for e in "''${items[@]}"; do
          IFS='|' read -r src dst kind <<< "$e"
          [ ! -L "$src" ] || fail "$src is a symlink"
          case $kind in
            f) [ -f "$src" ] && [ "$(stat -c '%u %a' "$src")" = '1000 600' ] || fail "$src must be a UID 1000 mode 600 file" ;;
            d) [ -d "$src" ] && [ "$(stat -c %u "$src")" = 1000 ] || fail "$src must be a UID 1000 directory" ;;
          esac
          ss=$(state "$src") || fail "cannot read $src"
          ds=$(state "$dst") || fail "cannot read $dst"
          if [ "$ds" = "$ss" ]; then echo "equal $dst"
          else echo "differs $dst"; changed+=("$e"); srcs+=("$ss"); fi
        done
        [ "$compare" = 0 ] || exit 0
        if [ "''${#changed[@]}" = 0 ]; then echo 'rent-state-import unchanged'; exit 0; fi
        # A preimage or staging copy left by an earlier run is never reused or deleted: refuse until it is inspected.
        for e in "''${changed[@]}"; do
          IFS='|' read -r src dst kind <<< "$e"
          for t in "$dst.prior" "''${dst%/*}/.import-''${dst##*/}".*; do
            if [ -e "$t" ] || [ -L "$t" ]; then fail "$t is left from an earlier import; not reusing or deleting it"; fi
          done
        done
        [ -d "$s" ] || install -d -m 755 -o 0 -g 0 "$s" || fail "cannot create $s"
        for d in "$s/codex" "$s/claude" "$s/claude/projects" "$s/claude/$p"; do
          [ -d "$d" ] || install -d -m 700 -o 1000 -g 1000 "$d" || fail "cannot create $d"
        done
        # Stage every changed item complete beside its target first, checked against the source evidence taken once, and
        # take each original's evidence; any failure here changed no target.
        held=() staged=() step=()
        for i in "''${!changed[@]}"; do
          IFS='|' read -r src dst kind <<< "''${changed[i]}"
          tmp=$(mktemp -d "''${dst%/*}/.import-''${dst##*/}.XXXXXXXX") || fail "cannot stage $dst"
          new=$tmp/''${dst##*/}
          cp -a --no-dereference "$src" "$new" || fail "cannot copy $src"
          ns=$(state "$new") || fail "cannot read $new"
          [ "$ns" = "''${srcs[i]}" ] || fail "$new differs from its source"
          hs=$(state "$dst") || fail "cannot read $dst"
          staged+=("$new"); held+=("$hs"); step+=(0)
        done
        # The source holder is quiesced: a source that no longer matches what was compared and copied refuses here.
        for i in "''${!changed[@]}"; do
          IFS='|' read -r src dst kind <<< "''${changed[i]}"
          ss=$(state "$src") && [ "$ss" = "''${srcs[i]}" ] || fail "$src changed while importing"
        done
        # Put each changed item back to the original this process saw, only where the copy and the prior still match
        # their evidence; anything unreadable or drifted leaves the outcome UNKNOWN.
        restore() {
          local i ok=1 now
          for ((i = ''${#changed[@]} - 1; i >= 0; i--)); do
            IFS='|' read -r src dst kind <<< "''${changed[i]}"
            if [ "''${step[i]}" = 2 ]; then
              if now=$(state "$dst") && [ "$now" = "''${srcs[i]}" ] && mv -T "$dst" "''${staged[i]}"; then step[i]=1; else ok=0; continue; fi
            fi
            if [ "''${step[i]}" = 1 ] && [ "''${held[i]}" != absent ]; then
              if now=$(state "$dst.prior") && [ "$now" = "''${held[i]}" ] && mv -T "$dst.prior" "$dst" &&
                now=$(state "$dst") && [ "$now" = "''${held[i]}" ]; then step[i]=0; else ok=0; fi
            elif [ "''${step[i]}" = 1 ]; then
              if now=$(state "$dst") && [ "$now" = absent ]; then step[i]=0; else ok=0; fi
            fi
          done
          if [ "$ok" = 1 ]; then echo 'rent-state-import: failed; every changed item restored' >&2; exit 21; fi
          echo 'rent-state-import: failed; restore incomplete, state UNKNOWN' >&2; exit 30
        }
        # The session's directory goes before its journal; each original becomes its prior, then the copy takes its place.
        for i in "''${!changed[@]}"; do
          IFS='|' read -r src dst kind <<< "''${changed[i]}"
          if [ "''${held[i]}" != absent ]; then mv -T "$dst" "$dst.prior" || restore; step[i]=1; fi
          mv -T "''${staged[i]}" "$dst" || restore
          step[i]=2
          now=$(state "$dst") && [ "$now" = "''${srcs[i]}" ] || restore
          echo "updated $dst"
        done
        # Every item is in place and verified, and every staging copy was moved; a staging directory whose removal fails is
        # kept and reported (11), not undone.
        left=0
        for n in "''${staged[@]}"; do rmdir "''${n%/*}" || left=1; done
        if [ "$left" = 1 ]; then echo 'rent-state-import updated; a staging directory was kept after its removal failed' >&2; exit 11; fi
        echo 'rent-state-import updated'
        exit 10
      '';
      # rent-only tools beside the common dev profile. /bin/flock is the image's own lock tool for a one-shot writer
      # such as the envs token receiver, which runs with the image's default PATH.
      rentTools = pkgs.buildEnv {
        name = "rent-tools";
        paths = [ stateImport (pkgs.linkFarm "rent-flock" [ { name = "bin/flock"; path = "${pkgs.util-linux}/bin/flock"; } ]) ];
        pathsToLink = [ "/bin" ];
      };
      sshConfig = pkgs.writeText "rent-sshd-config" (import ./hosts/rent/nix.nix {
        port = 2222;
        sshDir = "${rentState}/ssh";
        certFile = rentCert;
      });
      # PID 1: fail closed on mounts, the seeded store and the tunnel token file, lay out state, then supervise nix-daemon,
      # cloudflared and sshd until any exits or TERM. It runs from the /nix volume, so an unseeded volume cannot start it.
      # tunnel is the cloudflared package; only the CI-only stub image passes anything else.
      rentStart = devProfile: tunnel: pkgs.writeShellScriptBin "rent-start" ''
        set -eu
        export PATH=${pkgs.lib.makeBinPath [ pkgs.coreutils pkgs.gnugrep pkgs.openssh pkgs.nix pkgs.util-linux ]}
        state=${rentState}
        # One gate before any service: exactly the Binding repos, state and nix volumes, all writable, nothing else.
        ${mountLib}
        repos=''${RENT_REPOS_VOLUME:-}
        statevol=''${RENT_STATE_VOLUME:-}
        nixvol=''${RENT_NIX_VOLUME:-}
        volume_name "$repos" && volume_name "$statevol" && volume_name "$nixvol" ||
          { echo 'rent-mounts: set RENT_REPOS_VOLUME, RENT_STATE_VOLUME and RENT_NIX_VOLUME to volume names' >&2; exit 1; }
        volume_at /work/repos "$repos" rw || { echo "rent-mounts: /work/repos must be exactly volume $repos, rw" >&2; exit 1; }
        volume_at "$state" "$statevol" rw || { echo "rent-mounts: $state must be exactly volume $statevol, rw" >&2; exit 1; }
        volume_at /nix "$nixvol" rw || { echo "rent-mounts: /nix must be exactly volume $nixvol, rw" >&2; exit 1; }
        if mounted /home/dev; then echo 'rent-mounts: /home/dev must not be a mount' >&2; exit 1; fi
        [ "$(volume_count)" = 3 ] || { echo 'rent-mounts: exactly three volumes are allowed' >&2; exit 1; }
        # One writer per volume: an exclusive lock on each volume root, held for the container's life (PID 1 keeps fds
        # 7-9 open until it exits). A second rent, a seed, a state import or a receiver taking the same
        # lock is refused; a writer that takes no lock is not stopped by it.
        exec 7</work/repos 8<"$state" 9</nix
        for fd in 7 8 9; do
          flock -x -n "$fd" || { echo 'rent-lock: repos, state or nix is in use by another rent, seed, import or receiver' >&2; exit 1; }
        done
        echo "rent-mounts ok repos=$repos state=$statevol nix=$nixvol"
        # This image's runtime closure must be seeded completely: marker, GC root last, every path valid in the DB.
        roots=$(readlink /etc/rent-nix-roots)
        [ "$(cat /nix/var/rent-nix 2>/dev/null)" = '${rentNixMarker}' ] ||
          { echo "rent-nix: /nix is not a seeded rent /nix volume" >&2; exit 1; }
        [ "$(readlink "/nix/var/nix/gcroots/rent/''${roots##*/}")" = "$roots" ] ||
          { echo "rent-nix: this image is not seeded into $nixvol; run rent-nix-seed first" >&2; exit 1; }
        # shellcheck disable=SC2046
        nix-store --check-validity "$roots" $(cat "$roots") || { echo 'rent-nix: seeded paths are not valid' >&2; exit 1; }
        ${profileLib}
        set_profile /nix ${devProfile}
        echo "rent-nix ok roots=$roots profile=$(readlink /nix/var/nix/profiles/rent-dev)"
        # The one tunnel secret slot, placed by envs: checked before any service, never read, printed or hashed here.
        # Its content is an opaque token that cloudflared alone judges.
        token=${rentToken}
        token_fail() { echo "rent-transport: token file $token $1; not starting" >&2; exit 1; }
        [ -e "$token" ] || [ -L "$token" ] || token_fail 'is missing'
        [ ! -L "$token" ] && [ -f "$token" ] || token_fail 'must be a regular file'
        [ "$(stat -c '%u:%g %a' "$token")" = '0:0 600' ] || token_fail 'must be owned 0:0 with mode 600'
        size=$(stat -c %s "$token")
        [ "$size" -ge 1 ] && [ "$size" -le 4096 ] || token_fail 'must hold 1 to 4096 bytes'
        grep -q '[^[:space:]]' "$token" || token_fail 'is blank'
        echo "rent-transport ok token-file=$token"

        dir() { install -d "$3"; chown "$2" "$3"; chmod "$1" "$3"; }
        dir 755 0:0 "$state"
        dir 755 0:0 "$state/ssh"
        dir 755 0:0 "$state/dev"
        dir 700 1000:1000 "$state/dev/codex"
        dir 700 1000:1000 "$state/dev/claude"
        # Claude writes ~/.claude.json through the link; the placeholder lets it start in a root-owned directory.
        if [ ! -e "$state/dev/claude.json" ] && [ ! -L "$state/dev/claude.json" ]; then
          printf '{}\n' > "$state/dev/claude.json"
        fi
        if [ -L "$state/dev/claude.json" ] || [ ! -f "$state/dev/claude.json" ]; then
          echo "$state/dev/claude.json must be a regular file" >&2; exit 1
        fi
        chown 1000:1000 "$state/dev/claude.json"
        chmod 600 "$state/dev/claude.json"
        dir 700 1000:1000 /home/dev
        dir 755 1000:1000 /home/dev/.config
        link() {
          if [ -L "$2" ]; then
            [ "$(readlink "$2")" = "$1" ] || { echo "$2 does not point to $1" >&2; exit 1; }
          elif [ -e "$2" ]; then
            echo "$2 exists and is not a link to $1" >&2; exit 1
          else
            ln -s "$1" "$2"
            chown -h 1000:1000 "$2"
          fi
        }
        link "$state/dev/codex" /home/dev/.codex
        # gh keeps no state here: the owner root /work/repos/.auth/<owner>/gh is selected per repository (#8-C). An
        # existing $state/dev/gh is left untouched and unused.
        link "$state/dev/claude" /home/dev/.claude
        link "$state/dev/claude.json" /home/dev/.claude.json

        if [ ! -s "$state/ssh/authorized_keys" ]; then
          if [ -z "''${RENT_AUTHORIZED_KEY:-}" ]; then
            echo "Set RENT_AUTHORIZED_KEY on first creation" >&2
            exit 1
          fi
          printf '%s\n' "$RENT_AUTHORIZED_KEY" > "$state/ssh/authorized_keys"
        fi
        chown 0:0 "$state/ssh/authorized_keys"
        chmod 644 "$state/ssh/authorized_keys"
        if [ ! -s "$state/ssh/ssh_host_ed25519_key" ]; then
          ssh-keygen -q -t ed25519 -N "" -f "$state/ssh/ssh_host_ed25519_key"
        fi
        chmod 600 "$state/ssh/ssh_host_ed25519_key"

        # The only store writer while this container runs; dev reaches it through NIX_REMOTE=daemon.
        NIX_SSL_CERT_FILE=${rentCert} nix-daemon &
        nd_pid=$!
        sshd_pid=
        cf_pid=
        cleanup() {
          trap - TERM INT
          kill -TERM $sshd_pid $cf_pid "$nd_pid" 2>/dev/null || true
          wait || true
        }
        trap 'cleanup; exit 143' TERM INT
        # The only external route: the token by file (never argv or environment); a critical child like the others,
        # so a rejected or revoked tunnel stops the container instead of hiding behind a healthy local sshd.
        ${tunnel}/bin/cloudflared tunnel --no-autoupdate run --token-file "$token" &
        cf_pid=$!
        ${pkgs.openssh}/bin/sshd -D -e -f ${sshConfig} &
        sshd_pid=$!
        echo "rent-start ok services=nix-daemon,cloudflared,sshd"
        status=0
        wait -n "$nd_pid" "$cf_pid" "$sshd_pid" || status=$?
        echo "rent-start: nix-daemon, cloudflared or sshd exited ($status); stopping" >&2
        cleanup
        exit 1
      '';
      # One rent image per dev profile. The runtime paths are the GC-rooted closure seeded into the rent /nix volume;
      # rent-nix-seed is not among them, because it runs only against the image's own store with the volume at /seed.
      mkRent = { profile, tag, tunnel ? pkgs.cloudflared }:
        let
          start = rentStart profile tunnel;
          roots = pkgs.writeText "rent-nix-roots"
            (pkgs.lib.concatMapStrings (p: "${p}\n") [ pkgs.cacert profile rentTools start ]);
          closure = pkgs.closureInfo { rootPaths = [ roots ]; };
          # Seed or upgrade a rent /nix volume from this image, while no container uses it: copy missing store paths
          # (each appears only complete), register the closure, set the rent-dev profile, then the GC root, last.
          seed = pkgs.writeShellScriptBin "rent-nix-seed" ''
            set -eu
            export PATH=${pkgs.lib.makeBinPath [ pkgs.coreutils pkgs.nix pkgs.util-linux ]}
            fail() { echo "rent-nix-seed: $*" >&2; exit 1; }
            ${mountLib}
            nixvol=''${RENT_NIX_VOLUME:-}
            volume_name "$nixvol" || fail 'set RENT_NIX_VOLUME to a volume name'
            volume_at /seed "$nixvol" rw || fail "/seed must be exactly volume $nixvol, rw"
            if mounted /nix; then fail '/nix must be the image store, not a mount'; fi
            [ "$(volume_count)" = 1 ] || fail 'exactly one volume is allowed'
            # The caller's expected backing (device and filesystem root, read in this invocation from the volume store its
            # writer check compared against): a different actual /seed mount refuses before any write, exit 3.
            if [ -n "''${RENT_NIX_EXPECT:-}" ]; then
              got=
              while read -r _id _parent dev root mp _rest; do [ "$mp" = /seed ] && got="$dev $root"; done <<< "$mounts"
              [ "$got" = "$RENT_NIX_EXPECT" ] || { echo "rent-nix-seed: /seed is not the expected volume backing; nothing written" >&2; exit 3; }
            fi
            # The /nix root lock a running rent holds: no seed while it (or another seed) uses the volume.
            exec 9</seed
            flock -x -n 9 || fail "$nixvol is in use by a running rent or another seed"
            if [ -e /seed/var/rent-nix ]; then
              [ "$(cat /seed/var/rent-nix)" = '${rentNixMarker}' ] || fail '/seed has a different marker'
            elif [ -n "$(ls -A /seed)" ]; then
              fail '/seed is neither empty nor a rent /nix volume'
            else
              install -d -m 755 /seed/var
              printf '%s\n' '${rentNixMarker}' > /seed/var/rent-nix
            fi
            # An interrupted copy leaves its staging directory; it is never reused or deleted: refuse until inspected.
            for t in /seed/.rent-seed-tmp /seed/.rent-seed.*; do
              if [ -e "$t" ] || [ -L "$t" ]; then fail "$t is left from an interrupted seed; not deleting it"; fi
            done
            install -d -m 1775 -o 0 -g 30000 /seed/store
            tmp=$(mktemp -d /seed/.rent-seed.XXXXXXXX)
            [ -z "$(ls -A "$tmp")" ] || fail "$tmp is not empty"
            copied=0
            while read -r p; do
              b=''${p#/nix/store/}
              if [ -e "/seed/store/$b" ] || [ -L "/seed/store/$b" ]; then continue; fi
              cp -a "$p" "$tmp/$b"
              mv -T "$tmp/$b" "/seed/store/$b"
              copied=$((copied + 1))
            done < ${closure}/store-paths
            rmdir "$tmp"
            # Paths are logical /nix/store names; only the database lives under /seed here.
            nix-store --store 'local?state=/seed/var/nix' --load-db < ${closure}/registration
            ${profileLib}
            set_profile /seed ${profile}
            install -d -m 755 /seed/var/nix/gcroots/rent
            ln -sfn ${roots} /seed/var/nix/gcroots/rent/.new
            mv -T /seed/var/nix/gcroots/rent/.new /seed/var/nix/gcroots/rent/${baseNameOf roots}
            echo "rent-nix-seed ok volume=$nixvol roots=${roots} copied=$copied"
          '';
        in pkgs.dockerTools.buildLayeredImage {
          name = "ghcr.io/roccho-dev/windows-rent";
          inherit tag;
          contents = [ pkgs.cacert profile rentTools start seed ];
          extraCommands = ''
            mkdir -p etc/ssl/certs etc/nix home/dev tmp var/empty
            {
              printf 'root:x:0:0:root:/root:/bin/sh\nsshd:x:74:74:sshd:/var/empty:/bin/sh\ndev:x:1000:1000:Development user:/home/dev:/bin/sh\n'
              for i in 1 2 3 4 5 6 7 8; do printf 'nixbld%s:x:%s:30000:Nix build user:/var/empty:/bin/sh\n' $i $((30000 + i)); done
            } > etc/passwd
            printf 'root:x:0:\nsshd:x:74:\ndev:x:1000:\nnixbld:x:30000:nixbld1,nixbld2,nixbld3,nixbld4,nixbld5,nixbld6,nixbld7,nixbld8\n' > etc/group
            cp ${rentNixConf} etc/nix/nix.conf
            ln -s ${roots} etc/rent-nix-roots
            # Default CA path, so TLS works in sessions that do not inherit SSL_CERT_FILE.
            ln -s ${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt .${rentCert}
            chmod 1777 tmp
          '';
          # No Volumes: an image-declared volume would silently satisfy a missing mount.
          config = {
            Cmd = [ "${start}/bin/rent-start" ];
            # Default exec reads no global or system Git configuration, as SSH sessions (hosts/rent/nix.nix) (#8-C).
            Env = [ "HOME=/home/dev" "PATH=/bin:/usr/bin" "SSL_CERT_FILE=${rentCert}" "GIT_CONFIG_NOSYSTEM=1" "GIT_CONFIG_GLOBAL=/dev/null" ];
            ExposedPorts."2222/tcp" = {};
            Labels."org.opencontainers.image.source" = "https://github.com/roccho-dev/windows";
          };
        };
      rentExtras = with pkgs; [ python313 uv ];
      rentProfileFor = extra: import ./hosts/profile/nix.nix { inherit pkgs; extra = rentExtras ++ extra; };
      rentProfile = rentProfileFor [];
      # CI only, never published: stands in for cloudflared under the exact argv rent-start uses, so local SSH, state
      # and #8 continuity can run without Cloudflare. A synthetic token proves nothing about Cloudflare itself.
      rentTunnelStub = pkgs.writeShellScriptBin "cloudflared" ''
        [ "$*" = 'tunnel --no-autoupdate run --token-file ${rentToken}' ] || { echo "tunnel stub: unexpected argv" >&2; exit 2; }
        [ -r ${rentToken} ] || { echo 'tunnel stub: token file unreadable' >&2; exit 3; }
        echo 'tunnel stub: running (no Cloudflare connection)'
        # Stay this process, so CI can read the argv rent-start gave it.
        ${pkgs.coreutils}/bin/sleep infinity &
        wait $!
      '';
    in {
      packages.${system} = {
        own-image = own.image;
        # CI only, never published: the same own definition plus one profile package, to prove seed-on-upgrade.
        own-image-next = (ownFor {
          profile = import ./hosts/profile/nix.nix { inherit pkgs; owner = ownOwner; extra = [ pkgs.hello ]; };
          tag = "next";
        }).image;
        rent-image = mkRent { profile = rentProfile; tag = "nix"; };
        # CI only, never published: the published definition with the tunnel stub, for local SSH/state/#8 proofs.
        rent-image-stub = mkRent { profile = rentProfile; tag = "stub"; tunnel = rentTunnelStub; };
        # CI only, never published: the stub image plus one package, to prove seed-on-upgrade and rollback.
        rent-image-next = mkRent {
          profile = rentProfileFor [ pkgs.hello ];
          tag = "next";
          tunnel = rentTunnelStub;
        };
        # CI only, never published: the same principal routing and bind under the alternate target's helper name,
        # without an image; and that target's Binding as JSON for the own Windows script's strict reader.
        ci-alt-owner-gh = let alt = import ./hosts/profile/gh.nix { inherit pkgs; inherit (ciAltBinding) owner; }; in
          pkgs.buildEnv { name = "ci-alt-owner-gh"; paths = [ alt.wrapper alt.helper ]; pathsToLink = [ "/bin" ]; };
        ci-alt-own-binding = pkgs.writeText "ci-alt-own-binding.json" (builtins.toJSON ciAltBinding);
        git-state-backend = gitState.backend;
        dev-profile = dev.profile;
        dev-image = dev.image;
        common-fonts = common.fonts;
        windows-dist = common.dist;
      };
      apps.${system}.github-root = {
        type = "app";
        program = "${githubRoot.app}/bin/github-root";
      };
      checks.${system} = {
        windows-dist = common.check;
        git-state-finite-poc = gitState.fixture;
        github-root-source = githubRoot.check;
        # The alternate Binding through the production projection (hosts/common/nix.nix) and the existing pack.py
        # validators: its own values only, none of the sample's, and no distribution or image is built.
        own-alt-binding = pkgs.runCommand "own-alt-binding-check" {
          nativeBuildInputs = [ ciAlt.python ];
          projection = builtins.toJSON ciAlt.ownProjection;
          binding = builtins.toJSON ciAltBinding;
        } ''
          set -eu
          export PYTHONDONTWRITEBYTECODE=1 PYTHONPATH=${./hosts/common}
          python - <<'EOF'
          import json, os, pack
          p, b = json.loads(os.environ["projection"]), json.loads(os.environ["binding"])
          launch = pack.noctty_launch(p["launch"])
          own = pack.own_resume(p["ownResume"], launch)
          assert (launch["session"], launch["container"]) == (b["session"], b["container"]), launch
          assert own == {"expectHost": b["expectHost"], "container": b["container"], "hostPort": b["hostPort"],
                         "image": b["image"], "session": b["session"],
                         "volumes": [{"name": b["volume"], "destination": "/home/dev"},
                                     {"name": b["workVolume"], "destination": "/work/repos"},
                                     {"name": b["nixVolume"], "destination": "/nix"}],
                         "ssh": {"alias": b["sshAlias"], "identity": ".ssh/id_alt", "knownHosts": ".ssh/known_hosts_alt"}}, own
          text = json.dumps(p)
          for sample in ("G6I3", "wslc-cli-resta", "g6i3-own", "windows_own", "windows-own-"):
              assert sample not in text, sample
          EOF
          touch $out
        '';
        # Fails when the own image or its scripts disagree with hosts/own/spec.json.
        own-spec = pkgs.runCommand "own-spec-check" {
          nativeBuildInputs = [ pkgs.jq ];
          config = builtins.toJSON ownConfig;
          spec = builtins.toJSON ownSpec;
        } ''
          set -eu
          port=$(jq -r .sshPort <<<"$spec"); mount=$(jq -r .stateMount <<<"$spec")
          jq -e --arg p "$port/tcp" --arg m "$mount" \
            '(.ExposedPorts | has($p)) and (has("Volumes") | not) and (.Env | index("HOME=" + $m))' <<<"$config"
          # The three mounts own-start gates on: home state, work and the own /nix.
          for m in "$mount" "$(jq -r .workMount <<<"$spec")" "$(jq -r .nixMount <<<"$spec")"; do
            grep -qF "volume_at $m " ${own.start}/bin/own-start
          done
          grep -qF 'exactly three volumes are allowed' ${own.start}/bin/own-start
          grep -qx "Port $port" ${own.sshConfig}
          grep -qF "HostKey $mount/.ssh/" ${own.sshConfig}
          grep -qF "$(jq -r .authorizedKeyEnv <<<"$spec")" ${own.start}/bin/own-start
          grep -qF "$mount/.ssh/authorized_keys" ${own.start}/bin/own-start
          # Xpra is not adopted: own-start neither names nor waits on it, and sshd and nix-daemon are the only
          # essential services; the browsers stay outside the wait set as before. Store hashes are dropped first (base32
          # can spell it), and the text is read whole before matching, so a read failure cannot pass for absence.
          # own-tools is not referenced here (that would build its closure in this check); the own smoke checks it.
          start=$(sed -E 's|/nix/store/[0-9a-z]{32}-|/nix/store/|g' ${own.start}/bin/own-start)
          case "''${start,,}" in *xpra*) echo 'own-start still names xpra' >&2; exit 1 ;; esac
          [ "$(grep -c '^wait -n ' ${own.start}/bin/own-start)" = 1 ]
          grep -qx 'wait -n "$ssh_pid" "$nd_pid"' ${own.start}/bin/own-start
          # #8-C: SSH sessions and default exec read no global or system Git configuration (P2 tests the real image).
          grep -qF ' NIX_REMOTE=daemon GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null' ${own.sshConfig}
          jq -e '(.Env | index("GIT_CONFIG_NOSYSTEM=1")) and (.Env | index("GIT_CONFIG_GLOBAL=/dev/null"))' <<<"$config"
          grep -qF "$(jq -r .syntheticTrialEnv <<<"$spec")" ${own.browser}
          grep -qF "remote-debugging-port=$(jq -r .cdpPort <<<"$spec")" ${own.browser}
          touch $out
        '';
      };
    };
}
