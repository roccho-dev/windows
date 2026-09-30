# own on the common dev profile (Issue #8-B): home state, work and a writable own /nix are three named volumes.
# mountLib and nixConf are the flake's generic mountinfo gate and multi-user nix.conf, passed in unchanged.
{ pkgs, spec, mountLib, nixConf, profile, tag ? "nix" }:

assert spec.nixMount == "/nix";
let
  home = spec.stateMount;
  work = spec.workMount;
  # Written once into a seeded own /nix volume; nothing else may be seeded or run as own's store.
  marker = "windows-own-nix v1";
  cert = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
  # set_profile ROOT TARGET: ROOT/var/nix/profiles/own-dev -> TARGET through a new generation link, unless it already
  # is. Older generations stay as rollback targets and GC roots.
  profileLib = ''
    set_profile() {
      local d="$1/var/nix/profiles" g n=0
      install -d -m 755 "$d"
      if [ -L "$d/own-dev" ]; then
        g=$(readlink "$d/own-dev")
        [[ $g =~ ^own-dev-[0-9]+-link$ ]] && [ -L "$d/$g" ] || { echo "$d/own-dev is not a generation link" >&2; exit 1; }
        [ "$(readlink "$d/$g")" != "$2" ] || return 0
      elif [ -e "$d/own-dev" ]; then
        echo "$d/own-dev exists and is not a link" >&2; exit 1
      fi
      for g in "$d"/own-dev-*-link; do
        [ -L "$g" ] || continue
        g=''${g##*/own-dev-}; g=''${g%-link}
        [ "$g" -le "$n" ] || n=$g
      done
      n=$((n + 1))
      ln -s "$2" "$d/own-dev-$n-link"
      ln -sfn "own-dev-$n-link" "$d/.own-dev.new"
      mv -T "$d/.own-dev.new" "$d/own-dev"
    }
  '';
  # Squash-merge commit of ops PR #426 (merged 2026-09-26T05:36:11Z into default branch `proposals`; not in `main`).
  opsSrc = pkgs.fetchFromGitHub {
    owner = "roccho-dev";
    repo = "ops";
    rev = "9e6603324e5d7691dd06675c3267e887ce1e8915";
    hash = "sha256-2oqzs9GMtCyXY26fDnmtH7dwCFYx2GbF5LFKN5TRtz8=";
  };
  cdpTty = pkgs.callPackage "${opsSrc}/packages/cdp-tty" { };
  fontConfig = pkgs.makeFontsConf {
    fontDirectories = [ pkgs.dejavu_fonts pkgs.noto-fonts-cjk-sans ];
  };
  sshConfig = pkgs.writeText "own-sshd-config" ''
    Port ${toString spec.sshPort}
    ListenAddress 0.0.0.0
    HostKey ${home}/.ssh/ssh_host_ed25519_key
    AuthorizedKeysFile .ssh/authorized_keys
    PubkeyAuthentication yes
    PasswordAuthentication no
    KbdInteractiveAuthentication no
    PermitRootLogin no
    AllowUsers dev
    UsePAM no
    SetEnv SSL_CERT_FILE=${cert} NIX_SSL_CERT_FILE=${cert} NIX_REMOTE=daemon
    PidFile /tmp/own-sshd.pid
    Subsystem sftp internal-sftp
  '';
  # Synthetic local pages only: a navigation link, a text input and a per-profile localStorage marker.
  nav = pkgs.writeText "own-nav.html" ''
    <!doctype html><meta charset="utf-8"><title>own nav</title>
    <body style="background:#444444;color:white;font:32px sans-serif">own nav<br><a href="javascript:history.back()">back</a></body>
  '';
  page = n: color: pkgs.writeText "own-p${n}.html" ''
    <!doctype html><meta charset="utf-8"><title>own p${n}</title>
    <body style="background:${color};color:white;font:32px sans-serif">own p${n}<br>日本語表示<br>
    <input aria-label="text input" style="font:32px sans-serif"><br>
    <button onclick="localStorage.setItem('own-marker', 'p${n}'); show()">set marker</button>
    <button onclick="show()">show marker</button> marker: <b id="m"></b><br>
    <a href="file://${nav}">navigate</a>
    <script>function show() { document.getElementById('m').textContent = localStorage.getItem('own-marker') || '(none)'; }</script>
    <div style="height:2400px"></div><p>bottom of own p${n}</p>
    </body>
  '';
  pages = {
    p1 = page "1" "#315a92";
    p2 = page "2" "#317854";
    p3 = page "3" "#8054a0";
  };
  # Three headless profiles, each its own process and loopback-only CDP port; nothing is published.
  browser = pkgs.writeShellScript "own-browser" ''
    set -eu
    export HOME=${home}
    export XDG_RUNTIME_DIR=/tmp/own-runtime
    export FONTCONFIG_FILE=${fontConfig}
    browser_args=(--headless=new --no-first-run --no-default-browser-check --remote-debugging-address=127.0.0.1)
    if [ "''${${spec.syntheticTrialEnv}:-0}" = 1 ]; then
      echo 'Synthetic trial only: Chromium sandbox disabled; do not use real logins' >&2
      browser_args+=(--no-sandbox)
    fi
    # Stale Singleton* locks on the volume are cleared only while no Chromium process runs.
    for d in /proc/[0-9]*; do
      case "$(${pkgs.coreutils}/bin/tr '\0' ' ' < "$d/cmdline" 2>/dev/null)" in
        *libexec/chromium/chromium*) echo 'Chromium is already running' >&2; exit 1;;
      esac
    done
    pids=()
    start() {
      profile=${home}/chromium/p$1
      ${pkgs.coreutils}/bin/install -d -m 700 "$profile"
      ${pkgs.coreutils}/bin/rm -f "$profile"/SingletonLock "$profile"/SingletonSocket "$profile"/SingletonCookie
      ${pkgs.chromium}/bin/chromium "''${browser_args[@]}" --user-data-dir="$profile" "$3" "file://$2" &
      pids+=($!)
    }
    start 1 ${pages.p1} --remote-debugging-port=${toString spec.cdpPort}
    start 2 ${pages.p2} --remote-debugging-port=${toString (spec.cdpPort + 1)}
    start 3 ${pages.p3} --remote-debugging-port=${toString (spec.cdpPort + 2)}
    trap 'kill -TERM "''${pids[@]}" 2>/dev/null || true; wait' TERM INT
    wait
  '';
  # own-view <1|2|3>: the profile's first page target, shown through ops #426 cdp-tty.
  view = pkgs.writeShellScriptBin "own-view" ''
    set -eu
    case "''${1:-}" in 1|2|3) ;; *) echo 'usage: own-view <1|2|3>' >&2; exit 2;; esac
    port=$(( ${toString spec.cdpPort} + $1 - 1 ))
    list=$(${pkgs.curl}/bin/curl -fsS --max-time 5 "http://127.0.0.1:$port/json/list") || {
      echo "profile $1: no CDP on 127.0.0.1:$port" >&2; exit 1; }
    ws=$(printf '%s' "$list" | ${pkgs.jq}/bin/jq -r '[.[] | select(.type == "page")][0].webSocketDebuggerUrl // empty')
    [ -n "$ws" ] || { echo "profile $1: no page target" >&2; exit 1; }
    exec ${cdpTty}/bin/cdp-tty "$ws"
  '';
  # PID 1. Fails closed on mounts, holds the /nix root lock for the container's lifetime (a seed takes the same lock),
  # checks the seeded store, then supervises nix-daemon, sshd and xpra. It runs from the /nix volume, so an unseeded
  # volume cannot start it at all.
  start = pkgs.writeShellScriptBin "own-start" ''
    set -eu
    export PATH=${pkgs.lib.makeBinPath [ pkgs.coreutils pkgs.util-linux pkgs.openssh pkgs.xpra pkgs.nix ]}:$PATH
    ${mountLib}
    homevol=''${OWN_HOME_VOLUME:-}
    workvol=''${OWN_WORK_VOLUME:-}
    nixvol=''${OWN_NIX_VOLUME:-}
    volume_name "$homevol" && volume_name "$workvol" && volume_name "$nixvol" ||
      { echo 'own-mounts: set OWN_HOME_VOLUME, OWN_WORK_VOLUME and OWN_NIX_VOLUME to volume names' >&2; exit 1; }
    volume_at ${home} "$homevol" rw || { echo "own-mounts: ${home} must be exactly volume $homevol, rw" >&2; exit 1; }
    volume_at ${work} "$workvol" rw || { echo "own-mounts: ${work} must be exactly volume $workvol, rw" >&2; exit 1; }
    volume_at /nix "$nixvol" rw || { echo "own-mounts: /nix must be exactly volume $nixvol, rw" >&2; exit 1; }
    [ "$(volume_count)" = 3 ] || { echo 'own-mounts: exactly three volumes are allowed' >&2; exit 1; }
    # The lock is on the volume root itself (no lock file); fd 9 stays open in PID 1 and every service it starts.
    exec 9</nix
    flock -x -n 9 || { echo "own-nix: $nixvol is in use by another own container or a seed" >&2; exit 1; }
    roots=$(readlink /etc/own-nix-roots)
    [ "$(cat /nix/var/own-nix 2>/dev/null)" = '${marker}' ] || { echo 'own-nix: /nix is not a seeded own /nix volume' >&2; exit 1; }
    [ "$(readlink "/nix/var/nix/gcroots/own/''${roots##*/}")" = "$roots" ] ||
      { echo "own-nix: this image is not seeded into $nixvol; run own-nix-seed first" >&2; exit 1; }
    # shellcheck disable=SC2046
    nix-store --check-validity "$roots" $(cat "$roots") || { echo 'own-nix: seeded paths are not valid' >&2; exit 1; }
    ${profileLib}
    set_profile /nix ${profile}
    echo "own-mounts ok home=$homevol work=$workvol nix=$nixvol"
    # A new, empty work volume becomes dev's; existing content is never chowned, copied or moved.
    if [ -z "$(ls -A ${work})" ]; then chown 1000:1000 ${work}; fi
    NIX_SSL_CERT_FILE=${cert} nix-daemon &
    nd_pid=$!
    chown 1000:1000 ${home}
    install -d -m 700 -o 1000 -g 1000 ${home}/.ssh ${home}/chromium /tmp/own-runtime
    if [ ! -s ${home}/.ssh/authorized_keys ]; then
      if [ -z "''${${spec.authorizedKeyEnv}:-}" ]; then
        echo 'Set ${spec.authorizedKeyEnv} on first creation' >&2
        exit 1
      fi
      printf '%s\n' "''${${spec.authorizedKeyEnv}}" > ${home}/.ssh/authorized_keys
    fi
    chown 1000:1000 ${home}/.ssh/authorized_keys ${home}/chromium
    chmod 600 ${home}/.ssh/authorized_keys
    if [ ! -s ${home}/.ssh/ssh_host_ed25519_key ]; then
      ${pkgs.openssh}/bin/ssh-keygen -q -t ed25519 -N "" -f ${home}/.ssh/ssh_host_ed25519_key
    fi
    chmod 600 ${home}/.ssh/ssh_host_ed25519_key
    ${pkgs.openssh}/bin/sshd -D -e -f ${sshConfig} &
    ssh_pid=$!
    ${pkgs.util-linux}/bin/setpriv --reuid=1000 --regid=1000 --clear-groups \
      ${pkgs.coreutils}/bin/env HOME=${home} XDG_RUNTIME_DIR=/tmp/own-runtime \
      FONTCONFIG_FILE=${fontConfig} \
      ${pkgs.xpra}/bin/xpra seamless :100 \
      --bind-tcp=127.0.0.1:${toString spec.xpraPort} --html=on --websocket-upgrade=on \
      --daemon=no --exit-with-client=no --exit-with-children=no \
      --mdns=no --pulseaudio=no --dbus-launch=no --dbus-control=no \
      --printing=no --notifications=no --webcam=no &
    xpra_pid=$!
    ${pkgs.util-linux}/bin/setpriv --reuid=1000 --regid=1000 --clear-groups ${browser} &
    browser_pid=$!
    # On stop, Chromium gets SIGTERM and time to flush its profiles before the container exits.
    trap 'kill "$ssh_pid" "$xpra_pid" "$nd_pid" 2>/dev/null || true; kill -TERM "$browser_pid" 2>/dev/null || true; wait "$browser_pid" 2>/dev/null || true' TERM INT
    wait -n "$ssh_pid" "$xpra_pid" "$nd_pid"
  '';
  # own-only tools beside the common dev profile (which carries Nix, Git/SSH, gh, Codex, Claude and basic tools).
  tools = pkgs.buildEnv {
    name = "own-tools";
    paths = (with pkgs; [ bubblewrap chromium curl fontconfig ripgrep util-linux xpra ]) ++ [ cdpTty view ];
    pathsToLink = [ "/bin" ];
  };
  # The GC-rooted runtime seeded into the own /nix volume; own-nix-seed is not among them (it runs only against the
  # image's own store with the volume at /seed).
  roots = pkgs.writeText "own-nix-roots" (pkgs.lib.concatMapStrings (p: "${p}\n") [ pkgs.cacert profile tools start ]);
  closure = pkgs.closureInfo { rootPaths = [ roots ]; };
  # Seed or upgrade an own /nix volume from this image under the volume-root lock, so never while own or another seed
  # uses it: copy missing store paths (each appears only complete), register them, set the profile, GC root last.
  seed = pkgs.writeShellScriptBin "own-nix-seed" ''
    set -eu
    export PATH=${pkgs.lib.makeBinPath [ pkgs.coreutils pkgs.util-linux pkgs.nix ]}
    fail() { echo "own-nix-seed: $*" >&2; exit 1; }
    ${mountLib}
    nixvol=''${OWN_NIX_VOLUME:-}
    volume_name "$nixvol" || fail 'set OWN_NIX_VOLUME to a volume name'
    volume_at /seed "$nixvol" rw || fail "/seed must be exactly volume $nixvol, rw"
    if mounted /nix; then fail '/nix must be the image store, not a mount'; fi
    [ "$(volume_count)" = 1 ] || fail 'exactly one volume is allowed'
    exec 9</seed
    flock -x -n 9 || fail "$nixvol is in use by a running own container or another seed"
    if [ -e /seed/var/own-nix ]; then
      [ "$(cat /seed/var/own-nix)" = '${marker}' ] || fail '/seed has a different marker'
    elif [ -n "$(ls -A /seed)" ]; then
      fail '/seed is neither empty nor an own /nix volume'
    else
      install -d -m 755 /seed/var
      printf '%s\n' '${marker}' > /seed/var/own-nix
    fi
    # An interrupted copy leaves its staging directory; it is never reused or deleted: refuse until inspected.
    for t in /seed/.own-seed-tmp /seed/.own-seed.*; do
      if [ -e "$t" ] || [ -L "$t" ]; then fail "$t is left from an interrupted seed; not deleting it"; fi
    done
    install -d -m 1775 -o 0 -g 30000 /seed/store
    tmp=$(mktemp -d /seed/.own-seed.XXXXXXXX)
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
    install -d -m 755 /seed/var/nix/gcroots/own
    ln -sfn ${roots} /seed/var/nix/gcroots/own/.new
    mv -T /seed/var/nix/gcroots/own/.new /seed/var/nix/gcroots/own/${baseNameOf roots}
    echo "own-nix-seed ok volume=$nixvol roots=${roots} copied=$copied"
  '';
  config = {
    Cmd = [ "${start}/bin/own-start" ];
    Env = [ "HOME=${home}" "PATH=/bin:/usr/bin" "SSL_CERT_FILE=${cert}" ];
    ExposedPorts."${toString spec.sshPort}/tcp" = {};
    # No Volumes: an image-declared volume would silently satisfy a missing mount.
    Labels."org.opencontainers.image.source" = "https://github.com/roccho-dev/windows";
  };
in
{
  inherit start sshConfig browser tools seed config;
  image = pkgs.dockerTools.buildLayeredImage {
    name = spec.imageRepository;
    inherit tag config;
    contents = [ pkgs.cacert profile tools start seed ];
    extraCommands = ''
      mkdir -p etc/nix .${home} tmp var/empty
      {
        printf 'root:x:0:0:root:/root:/bin/sh\nsshd:x:74:74:sshd:/var/empty:/bin/sh\ndev:x:1000:1000:Development user:${home}:/bin/sh\n'
        for i in 1 2 3 4 5 6 7 8; do printf 'nixbld%s:x:%s:30000:Nix build user:/var/empty:/bin/sh\n' $i $((30000 + i)); done
      } > etc/passwd
      printf 'root:x:0:\nsshd:x:74:\ndev:x:1000:\nnixbld:x:30000:nixbld1,nixbld2,nixbld3,nixbld4,nixbld5,nixbld6,nixbld7,nixbld8\n' > etc/group
      cp ${nixConf} etc/nix/nix.conf
      ln -s ${roots} etc/own-nix-roots
      touch etc/profile
      chmod 1777 tmp
    '';
  };
}
