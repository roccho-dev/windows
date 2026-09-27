{
  description = "own and rent WSLC OCI images";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/35d3407a3816f3b341d8cf1d60abaf2b7b8166ac";

  outputs = { self, nixpkgs }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs { inherit system; };
      ownSpec = builtins.fromJSON (builtins.readFile ./hosts/own/spec.json);
      own = import ./hosts/own/nix.nix { inherit pkgs; spec = ownSpec; };
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
      # rent: tools live in the image; /home/dev is fresh per container; only /var/lib/rent (state) and
      # /work/repos (existing repos, never copied or chowned) are volumes.
      rentState = "/var/lib/rent";
      rentCert = "/etc/ssl/certs/ca-certificates.crt";
      rentTsSocket = "/var/run/tailscale/tailscaled.sock";
      # Official Claude Code native build, pinned to platforms.linux-x64 of
      # https://downloads.claude.ai/claude-code-releases/2.1.283/manifest.json (size 241556664).
      claudeVersion = "2.1.283";
      claudeBin = pkgs.fetchurl {
        url = "https://downloads.claude.ai/claude-code-releases/${claudeVersion}/linux-x64/claude";
        sha256 = "1859583ce32920595c61ef868bee52e1b1594f7486db209935e01f1e5e804ae2";
      };
      # The glibc build runs through the pinned glibc loader, as the fixed W runtime runs it; updates are off.
      claude = pkgs.writeShellScriptBin "claude" ''
        export DISABLE_AUTOUPDATER=1
        exec ${pkgs.glibc}/lib/ld-linux-x86-64.so.2 --library-path ${pkgs.glibc}/lib ${claudeBin} "$@"
      '';
      # Later one-time import of exactly one Claude account and one session from an old home mounted read-only
      # at /old into the state volume. Never run by rent-start; prints target names and sizes only.
      claudeImport = pkgs.writeShellScriptBin "rent-claude-import" ''
        set -eu
        export PATH=${pkgs.lib.makeBinPath [ pkgs.coreutils pkgs.diffutils ]}
        fail() { echo "rent-claude-import: $*" >&2; exit 1; }
        id=''${1:-}
        [[ $id =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] ||
          fail 'usage: rent-claude-import <session-uuid>'
        mount_opts() {
          local _id _parent _dev _root mp opts _rest
          while read -r _id _parent _dev _root mp opts _rest; do
            [ "$mp" = "$1" ] && { printf '%s\n' "$opts"; return 0; }
          done < /proc/self/mountinfo
          return 1
        }
        opts=$(mount_opts /old) || fail '/old must be the old home, mounted read-only'
        case ",$opts," in *,ro,*) ;; *) fail '/old must be mounted read-only' ;; esac
        mount_opts ${rentState} > /dev/null || fail '${rentState} must be the state volume'
        s=${rentState}/dev
        p=projects/-home-dev
        pairs=(
          "/old/.claude/.credentials.json|$s/claude/.credentials.json|f"
          "/old/.claude.json|$s/claude.json|f"
          "/old/.claude/$p/$id.jsonl|$s/claude/$p/$id.jsonl|f"
          "/old/.claude/$p/$id|$s/claude/$p/$id|d"
        )
        for e in "''${pairs[@]}"; do
          IFS='|' read -r src dst kind <<< "$e"
          [ ! -L "$src" ] || fail "$src is a symlink"
          case $kind in
            f) [ -f "$src" ] && [ "$(stat -c '%u %a' "$src")" = '1000 600' ] || fail "$src must be a UID 1000 mode 600 file" ;;
            d) [ -d "$src" ] && [ "$(stat -c %u "$src")" = 1000 ] || fail "$src must be a UID 1000 directory" ;;
          esac
          # Only rent-start's placeholder may be replaced.
          if [ -e "$dst" ] || [ -L "$dst" ]; then
            [ "$dst" = "$s/claude.json" ] && [ ! -L "$dst" ] && [ "$(cat "$dst")" = '{}' ] || fail "$dst already exists"
          fi
        done
        install -d -m 755 -o 0 -g 0 "$s"
        install -d -m 700 -o 1000 -g 1000 "$s/claude" "$s/claude/projects" "$s/claude/$p"
        for e in "''${pairs[@]}"; do
          IFS='|' read -r src dst kind <<< "$e"
          case $kind in
            f) install -m 600 -o 1000 -g 1000 "$src" "$dst"
               cmp -s "$src" "$dst" || fail "$dst differs from its source" ;;
            d) cp -R --no-dereference --preserve=mode,timestamps "$src" "$dst"
               chown -R -h 1000:1000 "$dst"
               diff -r -q --no-dereference "$src" "$dst" > /dev/null || fail "$dst differs from its source" ;;
          esac
          echo "imported $dst ($(du -sb "$dst" | cut -f1) bytes)"
        done
      '';
      devTools = pkgs.buildEnv {
        name = "rent-dev-tools";
        paths = (with pkgs; [ coreutils git openssh gh tailscale ])
          ++ [ (import ./hosts/own/codex.nix { inherit pkgs; }) claude claudeImport ];
        pathsToLink = [ "/bin" ];
      };
      sshConfig = pkgs.writeText "rent-sshd-config" (import ./hosts/rent/nix.nix {
        port = 2222;
        sshDir = "${rentState}/ssh";
        certFile = rentCert;
      });
      # PID 1: fail closed on mounts, lay out state, then supervise tailscaled and sshd until either exits or TERM.
      rentStart = pkgs.writeShellScriptBin "rent-start" ''
        set -eu
        export PATH=${pkgs.lib.makeBinPath [ pkgs.coreutils pkgs.openssh pkgs.tailscale ]}
        state=${rentState}
        is_mount() {
          local _id _parent _dev _root mp _rest
          while read -r _id _parent _dev _root mp _rest; do
            [ "$mp" = "$1" ] && return 0
          done < /proc/self/mountinfo
          return 1
        }
        for m in /work/repos "$state"; do
          is_mount "$m" || { echo "$m must be a mounted volume" >&2; exit 1; }
        done
        if is_mount /home/dev; then echo '/home/dev must not be a mount' >&2; exit 1; fi
        if [ -z "''${RENT_TS_HOSTNAME:-}" ]; then echo 'Set RENT_TS_HOSTNAME' >&2; exit 1; fi

        dir() { install -d "$3"; chown "$2" "$3"; chmod "$1" "$3"; }
        dir 755 0:0 "$state"
        dir 700 0:0 "$state/tailscale"
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

        install -d -m 755 ${builtins.dirOf rentTsSocket}
        TS_LOGS_DIR="$state/tailscale" tailscaled --tun=userspace-networking \
          --statedir="$state/tailscale" --socket=${rentTsSocket} &
        ts_pid=$!
        up_pid=
        sshd_pid=
        cleanup() {
          trap - TERM INT
          kill -TERM $up_pid $sshd_pid "$ts_pid" 2>/dev/null || true
          wait || true
        }
        trap 'cleanup; exit 143' TERM INT
        ready=
        for _ in $(seq 30); do
          if tailscale --socket=${rentTsSocket} status --json >/dev/null 2>&1; then ready=1; break; fi
          kill -0 "$ts_pid" 2>/dev/null || break
          sleep 1
        done
        if [ -z "$ready" ]; then echo 'tailscaled did not become ready' >&2; cleanup; exit 1; fi
        # Nonblocking; no auth key: on first run this prints the login URL for a later browser login.
        tailscale --socket=${rentTsSocket} up --ssh --hostname="$RENT_TS_HOSTNAME" &
        up_pid=$!
        ${pkgs.openssh}/bin/sshd -D -e -f ${sshConfig} &
        sshd_pid=$!
        status=0
        wait -n "$ts_pid" "$sshd_pid" || status=$?
        echo "rent-start: tailscaled or sshd exited ($status); stopping" >&2
        cleanup
        exit 1
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
        rent-image = pkgs.dockerTools.buildLayeredImage {
          name = "ghcr.io/roccho-dev/windows-rent";
          tag = "nix";
          contents = [ pkgs.bash pkgs.cacert devTools rentStart ];
          extraCommands = ''
            mkdir -p etc/ssl/certs home/dev tmp var/empty
            printf 'root:x:0:0:root:/root:/bin/sh\nsshd:x:74:74:sshd:/var/empty:/bin/sh\ndev:x:1000:1000:Development user:/home/dev:/bin/sh\n' > etc/passwd
            printf 'root:x:0:\nsshd:x:74:\ndev:x:1000:\n' > etc/group
            # Default CA path, so TLS works in sessions that do not inherit SSL_CERT_FILE (Tailscale SSH).
            ln -s ${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt .${rentCert}
            chmod 1777 tmp
          '';
          # No Volumes: an image-declared volume would silently satisfy a missing mount.
          config = {
            Cmd = [ "${rentStart}/bin/rent-start" ];
            Env = [ "HOME=/home/dev" "PATH=/bin:/usr/bin" "SSL_CERT_FILE=${rentCert}" ];
            ExposedPorts."2222/tcp" = {};
            Labels."org.opencontainers.image.source" = "https://github.com/roccho-dev/windows";
          };
        };
      };
      # Fails when the own image or its scripts disagree with hosts/own/spec.json.
      checks.${system}.own-spec = pkgs.runCommand "own-spec-check" {
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
}
