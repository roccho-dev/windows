{
  description = "own and rent WSLC OCI images";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/35d3407a3816f3b341d8cf1d60abaf2b7b8166ac";

  outputs = { self, nixpkgs }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs { inherit system; };
      ownSpec = builtins.fromJSON (builtins.readFile ./hosts/own/spec.json);
      own = import ./hosts/own/nix.nix { inherit pkgs; spec = ownSpec; };
      dev = import ./oci/dev/nix.nix { inherit pkgs; };
      common = import ./hosts/common/nix.nix {
        inherit pkgs;
        source = self.rev or "uncommitted";
      };
      ownConfig = {
        Cmd = [ "${own.start}/bin/own-start" ];
        Env = [
          "HOME=${ownSpec.stateMount}"
          "PATH=/bin:/usr/bin"
          "SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"
        ];
        ExposedPorts."${toString ownSpec.sshPort}/tcp" = {};
        Volumes.${ownSpec.stateMount} = {};
        Labels."org.opencontainers.image.source" = "https://github.com/roccho-dev/windows";
      };
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
      # Later one-time import of exactly one Claude account and session, plus Codex auth, from an old home mounted
      # read-only at /old into the state volume. Never run by rent-start; prints target names and sizes only.
      stateImport = pkgs.writeShellScriptBin "rent-state-import" ''
        set -eu
        export PATH=${pkgs.lib.makeBinPath [ pkgs.coreutils pkgs.diffutils ]}
        fail() { echo "rent-state-import: $*" >&2; exit 1; }
        id=''${1:-}
        [[ $id =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] ||
          fail 'usage: rent-state-import <session-uuid>'
        ${mountLib}
        oldvol=''${RENT_OLD_VOLUME:-}
        statevol=''${RENT_STATE_VOLUME:-}
        volume_name "$oldvol" && volume_name "$statevol" || fail 'set RENT_OLD_VOLUME and RENT_STATE_VOLUME to volume names'
        volume_at /old "$oldvol" ro || fail "/old must be exactly volume $oldvol, mounted read-only"
        volume_at ${rentState} "$statevol" rw || fail "${rentState} must be exactly volume $statevol, writable"
        s=${rentState}/dev
        p=projects/-home-dev
        same() { if [ -d "$1" ]; then diff -r -q --no-dereference "$1" "$2" > /dev/null 2>&1; else cmp -s "$1" "$2"; fi; }
        pairs=(
          "/old/.claude/.credentials.json|$s/claude/.credentials.json|f"
          "/old/.claude/$p/$id.jsonl|$s/claude/$p/$id.jsonl|f"
          "/old/.claude/$p/$id|$s/claude/$p/$id|d"
          "/old/.codex/auth.json|$s/codex/auth.json|f"
        )
        for e in "''${pairs[@]}"; do
          IFS='|' read -r src dst kind <<< "$e"
          [ ! -L "$src" ] || fail "$src is a symlink"
          case $kind in
            f) [ -f "$src" ] && [ "$(stat -c '%u %a' "$src")" = '1000 600' ] || fail "$src must be a UID 1000 mode 600 file" ;;
            d) [ -d "$src" ] && [ "$(stat -c %u "$src")" = 1000 ] || fail "$src must be a UID 1000 directory" ;;
          esac
          # Only rent-start's placeholder, or an identical copy from an interrupted run, may already exist.
          if [ -e "$dst" ] || [ -L "$dst" ]; then
            if [ "$dst" = "$s/claude.json" ] && [ ! -L "$dst" ] && [ "$(cat "$dst")" = '{}' ]; then :
            elif [ ! -L "$dst" ] && same "$src" "$dst"; then :
            else fail "$dst already exists and differs from its source"; fi
          fi
        done
        install -d -m 755 -o 0 -g 0 "$s"
        install -d -m 700 -o 1000 -g 1000 "$s/codex" "$s/claude" "$s/claude/projects" "$s/claude/$p"
        # Each target appears only complete: copy to a .partial name, check it, then rename into place.
        for e in "''${pairs[@]}"; do
          IFS='|' read -r src dst kind <<< "$e"
          if ! { [ -e "$dst" ] && same "$src" "$dst"; }; then
            rm -rf "$dst.partial"
            case $kind in
              f) install -m 600 -o 1000 -g 1000 "$src" "$dst.partial" ;;
              d) cp -R --no-dereference --preserve=mode,timestamps "$src" "$dst.partial"
                 chown -R -h 1000:1000 "$dst.partial" ;;
            esac
            same "$src" "$dst.partial" || fail "$dst.partial differs from its source"
            mv -T "$dst.partial" "$dst"
          fi
          echo "imported $dst ($(du -sb "$dst" | cut -f1) bytes)"
        done
      '';
      # rent-only tools beside the common dev profile.
      rentTools = pkgs.buildEnv {
        name = "rent-tools";
        paths = [ stateImport ];
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
        export PATH=${pkgs.lib.makeBinPath [ pkgs.coreutils pkgs.gnugrep pkgs.openssh pkgs.nix ]}
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
        dir 700 1000:1000 "$state/dev/gh"
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
        link "$state/dev/gh" /home/dev/.config/gh
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
            export PATH=${pkgs.lib.makeBinPath [ pkgs.coreutils pkgs.nix ]}
            fail() { echo "rent-nix-seed: $*" >&2; exit 1; }
            ${mountLib}
            nixvol=''${RENT_NIX_VOLUME:-}
            volume_name "$nixvol" || fail 'set RENT_NIX_VOLUME to a volume name'
            volume_at /seed "$nixvol" rw || fail "/seed must be exactly volume $nixvol, rw"
            if mounted /nix; then fail '/nix must be the image store, not a mount'; fi
            [ "$(volume_count)" = 1 ] || fail 'exactly one volume is allowed'
            if [ -e /seed/var/rent-nix ]; then
              [ "$(cat /seed/var/rent-nix)" = '${rentNixMarker}' ] || fail '/seed has a different marker'
            elif [ -n "$(ls -A /seed)" ]; then
              fail '/seed is neither empty nor a rent /nix volume'
            else
              install -d -m 755 /seed/var
              printf '%s\n' '${rentNixMarker}' > /seed/var/rent-nix
            fi
            install -d -m 1775 -o 0 -g 30000 /seed/store
            rm -rf /seed/.rent-seed-tmp
            install -d -m 700 /seed/.rent-seed-tmp
            copied=0
            while read -r p; do
              b=''${p#/nix/store/}
              if [ -e "/seed/store/$b" ] || [ -L "/seed/store/$b" ]; then continue; fi
              cp -a "$p" "/seed/.rent-seed-tmp/$b"
              mv -T "/seed/.rent-seed-tmp/$b" "/seed/store/$b"
              copied=$((copied + 1))
            done < ${closure}/store-paths
            rmdir /seed/.rent-seed-tmp
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
            Env = [ "HOME=/home/dev" "PATH=/bin:/usr/bin" "SSL_CERT_FILE=${rentCert}" ];
            ExposedPorts."2222/tcp" = {};
            Labels."org.opencontainers.image.source" = "https://github.com/roccho-dev/windows";
          };
        };
      rentProfile = import ./hosts/profile/nix.nix { inherit pkgs; };
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
        own-image = pkgs.dockerTools.buildLayeredImage {
          name = ownSpec.imageRepository;
          tag = "nix";
          contents = [ pkgs.bash pkgs.cacert own.tools own.start ];
          extraCommands = ''
            mkdir -p etc .${ownSpec.stateMount} tmp var/empty
            printf 'root:x:0:0:root:/root:/bin/sh\nsshd:x:74:74:sshd:/var/empty:/bin/sh\ndev:x:1000:1000:Development user:${ownSpec.stateMount}:/bin/sh\n' > etc/passwd
            printf 'root:x:0:\nsshd:x:74:\ndev:x:1000:\n' > etc/group
            touch etc/profile
            chmod 1777 tmp
          '';
          config = ownConfig;
        };
        rent-image = mkRent { profile = rentProfile; tag = "nix"; };
        # CI only, never published: the published definition with the tunnel stub, for local SSH/state/#8 proofs.
        rent-image-stub = mkRent { profile = rentProfile; tag = "stub"; tunnel = rentTunnelStub; };
        # CI only, never published: the stub image plus one package, to prove seed-on-upgrade and rollback.
        rent-image-next = mkRent {
          profile = import ./hosts/profile/nix.nix { inherit pkgs; extra = [ pkgs.hello ]; };
          tag = "next";
          tunnel = rentTunnelStub;
        };
        dev-profile = dev.profile;
        dev-image = dev.image;
        common-fonts = common.fonts;
        windows-dist = common.dist;
      };
      checks.${system} = {
        windows-dist = common.check;
        # Fails when the own image or its scripts disagree with hosts/own/spec.json.
        own-spec = pkgs.runCommand "own-spec-check" {
          nativeBuildInputs = [ pkgs.jq ];
          config = builtins.toJSON ownConfig;
          spec = builtins.toJSON ownSpec;
        } ''
          set -eu
          port=$(jq -r .sshPort <<<"$spec"); mount=$(jq -r .stateMount <<<"$spec")
          jq -e --arg p "$port/tcp" --arg m "$mount" \
            '(.ExposedPorts | has($p)) and (.Volumes | has($m)) and (.Env | index("HOME=" + $m))' <<<"$config"
          grep -qx "Port $port" ${own.sshConfig}
          grep -qF "HostKey $mount/.ssh/" ${own.sshConfig}
          grep -qF "$(jq -r .authorizedKeyEnv <<<"$spec")" ${own.start}/bin/own-start
          grep -qF "$mount/.ssh/authorized_keys" ${own.start}/bin/own-start
          grep -qF "127.0.0.1:$(jq -r .xpraPort <<<"$spec")" ${own.start}/bin/own-start
          grep -qF "$(jq -r .syntheticTrialEnv <<<"$spec")" ${own.browser}
          grep -qF "remote-debugging-port=$(jq -r .cdpPort <<<"$spec")" ${own.browser}
          touch $out
        '';
      };
    };
}
