{ pkgs, backend }:
let
  # Source is inert under CI: only --source-check runs without principals.
  # A future operational GO must prove existing native principal and custody.
  app = pkgs.writeShellScriptBin "github-root" ''
    set -euo pipefail
    umask 077
    export PATH=${pkgs.lib.makeBinPath [ pkgs.opentofu pkgs.coreutils pkgs.python3 pkgs.jq pkgs.curl pkgs.git ]}:$PATH
    fail() { echo "github-root: $1" >&2; exit 64; }
    if [ "$#" = 1 ] && [ "$1" = --source-check ]; then
      echo 'github-root: source-only check, no backend or provider'
      exit 0
    fi
    [ "$#" = 1 ] && [ "$1" = plan ] ||
      fail 'plan-only; import/apply requires separate operational GO'
    [ -n "''${GITHUB_TOKEN:-}" ] && [ -n "''${SSH_PRIVATE_KEY:-}" ] ||
      fail 'native provider and Git principals not bound'
    # Native GitHub provider token stays shell-private outside OpenTofu.
    provider_token=$GITHUB_TOKEN
    unset GITHUB_TOKEN GH_TOKEN GITHUB_ENTERPRISE_TOKEN TF_ENCRYPTION
    [ "$(id -u)" = 0 ] &&
      [ "$PWD" = /work/repos/windows ] &&
      [ -f infra/github/main.tf ] ||
      fail 'selected OCIdev UID0 and /work/repos/windows not established'
    [ -f "$SSH_PRIVATE_KEY" ] && [ ! -L "$SSH_PRIVATE_KEY" ] ||
      fail 'native Git principal file unavailable'
    dir=/work/repos/.auth/roccho-dev/opentofu
    key=$dir/github-windows.passphrase
    [ -d "$dir" ] && [ ! -L "$dir" ] &&
      [ "$(stat -c '%u:%a' "$dir")" = 0:700 ] &&
      [ -f "$key" ] && [ ! -L "$key" ] && [ -s "$key" ] &&
      [ "$(stat -c '%u:%a' "$key")" = 0:600 ] ||
      fail 'dedicated UID0 0700/0600 custody not proven'
    # Raw key is read through stdin only; never argv, public log or Windows file.
    secret=$(jq -Rs . < "$key")
    encryption_config="$(cat <<ENCRYPT
key_provider "pbkdf2" "github" {
  passphrase = $secret
  iterations = 200000
}
method "aes_gcm" "github" {
  keys = key_provider.pbkdf2.github
}
state {
  method = method.aes_gcm.github
  enforced = true
}
plan {
  method = method.aes_gcm.github
  enforced = true
}
ENCRYPT
)"
    unset secret
    port=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')
    tmp=$(mktemp -d)
    pid=
    cleanup() {
      if [ -n "$pid" ]; then
        kill "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
      fi
      rm -f -- "$tmp/backend.log" "$tmp/init.log" "$tmp/plan.log" "$tmp/plan"
      rmdir -- "$tmp" 2>/dev/null || true
    }
    trap cleanup EXIT
    env -u GITHUB_TOKEN -u GH_TOKEN -u GITHUB_ENTERPRISE_TOKEN -u TF_ENCRYPTION ${backend}/bin/terraform-backend-git --address "127.0.0.1:$port" >"$tmp/backend.log" 2>&1 &
    pid=$!
    url="http://127.0.0.1:$port/?type=git&repository=git%40github.com%3Aroccho-dev%2Fwindows.git&ref=tofu-state&state=state%2Fgithub-windows.json"
    ready=0
    for round in $(seq 1 50); do
      kill -0 "$pid" 2>/dev/null || fail 'standard backend exited'
      code=$(curl -sS --max-time 1 -o /dev/null -w '%{http_code}' "$url") || code=000
      if [ "$code" = 200 ] || [ "$code" = 204 ]; then ready=1; break; fi
      sleep 0.2
    done
    [ "$ready" = 1 ] || fail 'transient loopback backend not ready'
    if ! TF_ENCRYPTION="$encryption_config" GITHUB_TOKEN="$provider_token" tofu -chdir=/work/repos/windows/infra/github init -input=false -reconfigure -lockfile=readonly \
      -backend-config="address=$url" -backend-config="lock_address=$url" \
      -backend-config="unlock_address=$url" -backend-config="lock_method=LOCK" \
      -backend-config="unlock_method=UNLOCK" >"$tmp/init.log" 2>&1; then
      fail 'standard native init rejected; no fallback'
    fi
    if ! TF_ENCRYPTION="$encryption_config" GITHUB_TOKEN="$provider_token" tofu -chdir=/work/repos/windows/infra/github plan -input=false -out="$tmp/plan" >"$tmp/plan.log" 2>&1; then
      fail 'standard native plan rejected; no apply'
    fi
    # A plan cannot authorize its own effect. Reject every outside-F delta.
    if ! TF_ENCRYPTION="$encryption_config" tofu -chdir=/work/repos/windows/infra/github show -json "$tmp/plan" |
      jq -e '
        (.resource_changes // []) as $r |
        ($r | length == 1) and
        ($r[0].address == "github_repository.windows") and
        ($r[0].change.actions == ["no-op"] or $r[0].change.actions == ["update"]) and
        (($r[0].change.before // {}) as $before |
         ($r[0].change.after // {}) as $after |
         ([($before | keys[]), ($after | keys[])] | unique |
           map(select(. != "description" and $before[.] != $after[.])) | length == 0))
      ' >/dev/null; then
      fail 'unexpected import/replace/create/delete or non-description plan'
    fi
    echo 'github-root: bounded native plan only; no apply'
  '';
  # No provider download/init, external Git ref or secret read in this check.
  check = pkgs.runCommand "github-root-source-check" {
    nativeBuildInputs = [ pkgs.bash pkgs.opentofu pkgs.gnugrep ];
  } ''
    set -eu
    tofu fmt -check -no-color ${./main.tf}
    bash -n ${app}/bin/github-root
    ${app}/bin/github-root --source-check >source-check.log
    grep -qF 'source-only check, no backend or provider' source-check.log
    grep -qF 'unset GITHUB_TOKEN GH_TOKEN GITHUB_ENTERPRISE_TOKEN TF_ENCRYPTION' ${app}/bin/github-root
    grep -qF 'env -u GITHUB_TOKEN -u GH_TOKEN -u GITHUB_ENTERPRISE_TOKEN -u TF_ENCRYPTION' ${app}/bin/github-root
    grep -qF 'TF_ENCRYPTION="$encryption_config" GITHUB_TOKEN="$provider_token" tofu' ${app}/bin/github-root
    if grep -qF 'export TF_ENCRYPTION=' ${app}/bin/github-root; then
      echo 'github-root: broad secret export' >&2
      exit 1
    fi
    grep -qF 'zh:5dd05dee677f6ebdbed00cbb1b9be444ab2d1062d345cbc9ec50a47cb41b8622' ${./.terraform.lock.hcl}
    touch "$out"
  '';
in {
  inherit app check;
}
