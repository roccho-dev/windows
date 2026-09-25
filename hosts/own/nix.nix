{ pkgs }:

let
  fontConfig = pkgs.makeFontsConf {
    fontDirectories = [ pkgs.dejavu_fonts pkgs.noto-fonts-cjk-sans ];
  };
  sshConfig = pkgs.writeText "own-sshd-config" ''
    Port 2223
    ListenAddress 0.0.0.0
    HostKey /home/dev/.ssh/ssh_host_ed25519_key
    AuthorizedKeysFile .ssh/authorized_keys
    PubkeyAuthentication yes
    PasswordAuthentication no
    KbdInteractiveAuthentication no
    PermitRootLogin no
    AllowUsers dev
    UsePAM no
    PidFile /tmp/own-sshd.pid
    Subsystem sftp internal-sftp
  '';
  pages = {
    human = pkgs.writeText "own-human.html" ''<title>own human</title><body style="background:#315a92;color:white;font:48px sans-serif">own human<br>日本語表示<br><input aria-label="trial input"></body>'';
    agentA = pkgs.writeText "own-agent-a.html" ''<title>own agent A</title><body style="background:#317854;color:white;font:48px sans-serif">own agent A<br>日本語表示</body>'';
    agentB = pkgs.writeText "own-agent-b.html" ''<title>own agent B</title><body style="background:#8054a0;color:white;font:48px sans-serif">own agent B<br>日本語表示</body>'';
  };
  browser = pkgs.writeShellScript "own-browser" ''
    set -eu
    export HOME=/home/dev
    export DISPLAY=:100
    export XDG_RUNTIME_DIR=/tmp/own-runtime
    export FONTCONFIG_FILE=${fontConfig}
    profile=/home/dev/chromium
    exec 9>"$profile/.own-instance.lock"
    ${pkgs.util-linux}/bin/flock -n 9 || {
      echo 'Chromium profile is already in use' >&2
      exit 1
    }
    ${pkgs.coreutils}/bin/rm -f "$profile"/SingletonLock "$profile"/SingletonSocket "$profile"/SingletonCookie
    browser_args=()
    if [ "''${OWN_TRIAL_UNSANDBOXED:-0}" = 1 ]; then
      echo 'Synthetic trial only: Chromium sandbox disabled; do not use real logins' >&2
      browser_args+=(--no-sandbox)
    fi
    ${pkgs.chromium}/bin/chromium "''${browser_args[@]}" --no-first-run --no-default-browser-check \
      --window-size=1100,700 \
      --user-data-dir="$profile" --remote-debugging-address=127.0.0.1 \
      --remote-debugging-port=9222 --profile-directory=Default \
      --new-window file://${pages.human} &
    browser_pid=$!
    ready=0
    for attempt in $(seq 1 60); do
      if ${pkgs.curl}/bin/curl --fail --silent http://127.0.0.1:9222/json/version >/dev/null; then
        ready=1
        break
      fi
      ${pkgs.coreutils}/bin/sleep 1
    done
    if [ "$ready" -ne 1 ]; then
      echo 'Chromium CDP did not start' >&2
      exit 1
    fi
    ${pkgs.chromium}/bin/chromium "''${browser_args[@]}" --user-data-dir="$profile" \
      --profile-directory='Profile 1' --new-window file://${pages.agentA}
    ${pkgs.chromium}/bin/chromium "''${browser_args[@]}" --user-data-dir="$profile" \
      --profile-directory='Profile 2' --new-window file://${pages.agentB}
    wait "$browser_pid"
  '';
  start = pkgs.writeShellScriptBin "own-start" ''
    set -eu
    export PATH=${pkgs.lib.makeBinPath [ pkgs.coreutils pkgs.util-linux pkgs.openssh pkgs.xpra ]}:$PATH
    chown 1000:1000 /home/dev
    install -d -m 700 -o 1000 -g 1000 /home/dev/.ssh /home/dev/chromium /tmp/own-runtime
    if [ ! -s /home/dev/.ssh/authorized_keys ]; then
      if [ -z "''${OWN_AUTHORIZED_KEY:-}" ]; then
        echo 'Set OWN_AUTHORIZED_KEY on first creation' >&2
        exit 1
      fi
      printf '%s\n' "$OWN_AUTHORIZED_KEY" > /home/dev/.ssh/authorized_keys
    fi
    chown 1000:1000 /home/dev/.ssh/authorized_keys /home/dev/chromium
    chmod 600 /home/dev/.ssh/authorized_keys
    if [ ! -s /home/dev/.ssh/ssh_host_ed25519_key ]; then
      ${pkgs.openssh}/bin/ssh-keygen -q -t ed25519 -N "" -f /home/dev/.ssh/ssh_host_ed25519_key
    fi
    chmod 600 /home/dev/.ssh/ssh_host_ed25519_key
    ${pkgs.openssh}/bin/sshd -D -e -f ${sshConfig} &
    ssh_pid=$!
    ${pkgs.util-linux}/bin/setpriv --reuid=1000 --regid=1000 --clear-groups \
      ${pkgs.coreutils}/bin/env HOME=/home/dev XDG_RUNTIME_DIR=/tmp/own-runtime \
      FONTCONFIG_FILE=${fontConfig} \
      ${pkgs.xpra}/bin/xpra seamless :100 \
      --bind-tcp=127.0.0.1:14500 --html=on --websocket-upgrade=on \
      --daemon=no --exit-with-client=no --exit-with-children=no \
      --mdns=no --pulseaudio=no --dbus-launch=no --dbus-control=no \
      --printing=no --notifications=no --webcam=no \
      --start=${browser} &
    xpra_pid=$!
    trap 'kill "$ssh_pid" "$xpra_pid" 2>/dev/null || true' TERM INT
    wait -n "$ssh_pid" "$xpra_pid"
  '';
in
{
  inherit start;
  tools = pkgs.buildEnv {
    name = "own-tools";
    paths = with pkgs; [
      bash
      chromium
      coreutils
      curl
      fontconfig
      openssh
      util-linux
      xpra
    ];
    pathsToLink = [ "/bin" ];
  };
}
