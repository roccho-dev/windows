{ pkgs, spec }:

let
  home = spec.stateMount;
  codex = import ./codex.nix { inherit pkgs; };
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
    SetEnv SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt
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
  start = pkgs.writeShellScriptBin "own-start" ''
    set -eu
    export PATH=${pkgs.lib.makeBinPath [ pkgs.coreutils pkgs.util-linux pkgs.openssh pkgs.xpra ]}:$PATH
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
    trap 'kill "$ssh_pid" "$xpra_pid" 2>/dev/null || true; kill -TERM "$browser_pid" 2>/dev/null || true; wait "$browser_pid" 2>/dev/null || true' TERM INT
    wait -n "$ssh_pid" "$xpra_pid"
  '';
in
{
  inherit start sshConfig browser;
  tools = pkgs.buildEnv {
    name = "own-tools";
    paths = (with pkgs; [
      bash
      bubblewrap
      chromium
      coreutils
      curl
      fontconfig
      gh
      git
      openssh
      ripgrep
      util-linux
      xpra
    ]) ++ [ codex cdpTty view ];
    pathsToLink = [ "/bin" ];
  };
}
