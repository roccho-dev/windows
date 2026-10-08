{ pkgs, backend }:
let
  # One fail-closed guard shared by the future native plan and CI fixtures.
  planGuard = pkgs.writeText "github-root-plan-guard.jq" ''
    def no_unknown:
      if type == "object" then all(.[]; no_unknown)
      elif type == "array" then all(.[]; no_unknown)
      else . == false or . == null
      end;
    (.format_version | type == "string" and startswith("1.")) and
    ((.resource_drift // []) | type == "array" and length == 0) and
    ((.output_changes // {}) | type == "object" and length == 0) and
    ((.checks // []) | type == "array" and all(.[]; .status == "pass")) and
    (.resource_changes | type == "array" and length == 1) and
    (.resource_changes[0] as $r |
      ($r.address == "github_repository.windows") and
      ($r.mode == "managed") and
      ($r.type == "github_repository") and
      ($r.name == "windows") and
      ($r | has("deposed") | not) and
      ($r | has("previous_address") | not) and
      ($r.change as $c |
        ($c.actions == ["no-op"] or $c.actions == ["update"]) and
        ($c | has("importing") | not) and
        ($c.before | type == "object") and
        ($c.after | type == "object") and
        ($c.before.id | type == "string" and length > 0) and
        ($c.before.id == $c.after.id) and
        ($c.before.name == "windows" and $c.after.name == "windows") and
        (($c.after_unknown // {}) | no_unknown) and
        (($c.before_sensitive // {}) | no_unknown) and
        (($c.after_sensitive // {}) | no_unknown) and
        ($c.before as $before |
         $c.after as $after |
         ([($before | keys[]), ($after | keys[])] | unique |
          all(.[]; . == "description" or $before[.] == $after[.])))))
  '';
  # Standard Nix fixed-output dependency fetch. The fixed hash is verified
  # by Nix; unlike ordinary source checks, FODs can fetch the publisher's
  # registry metadata without turning off any sandbox or GPG enforcement.
  signedLock = pkgs.runCommand "github-root-signed-6.13.0-provider-lock" {
    nativeBuildInputs = [ pkgs.opentofu pkgs.jq pkgs.gnugrep ];
    outputHashAlgo = "sha256";
    outputHashMode = "flat";
    # Pinned from the publisher-signed native origin lock output in CI 37786506387.
    outputHash = "sha256-IBsjPz1jHdA4COlZfFZPqnGXDKVVSuGFJsNWj+3Rft0=";
  } ''
    set -eu
    [ "$(tofu version -json | jq -r .terraform_version)" = 1.12.4 ] || {
      echo 'S1_LOCK_GENERATOR: pinned tofu version mismatched' >&2
      exit 1
    }
    mkdir -p source home
    cp ${./main.tf} source/main.tf
    cd source
    unset GITHUB_TOKEN GH_TOKEN GITHUB_ENTERPRISE_TOKEN TF_ENCRYPTION SSH_PRIVATE_KEY
    export HOME="$NIX_BUILD_TOP/home" TF_IN_AUTOMATION=1 OPENTOFU_ENFORCE_GPG_VALIDATION=true
    echo 'S1_LOCK_GENERATOR: origin registry with mandatory publisher GPG signature'
    if ! tofu providers lock -platform=linux_amd64 registry.terraform.io/integrations/github >../lock-generator.log 2>&1; then
      sed -n '1,90p' ../lock-generator.log >&2
      echo 'S1_LOCK_GENERATOR: registry source not verifiable; stopping' >&2
      exit 1
    fi
    sed -n '1,90p' ../lock-generator.log
    if ! grep -Fq '38027F80D7FD5FB2' ../lock-generator.log; then
      echo 'S1_LOCK_GENERATOR: expected official partner signer not proven' >&2
      exit 1
    fi
    zip_count=$(grep -c '"zh:' .terraform.lock.hcl || true)
    h1_count=$(grep -c '"h1:' .terraform.lock.hcl || true)
    echo "S1_LOCK_GENERATOR: native signed lock counts zh=$zip_count h1=$h1_count"
    [ "$zip_count" -ge 1 ] && [ "$h1_count" -ge 1 ] || {
      echo 'S1_LOCK_GENERATOR: no native signed ZIP or installed-package checksum' >&2
      exit 1
    }
    echo 'S1_GENERATED_LOCK_BEGIN'
    cat .terraform.lock.hcl
    echo 'S1_GENERATED_LOCK_END'
    cp .terraform.lock.hcl "$out"
    echo 'S1_LOCK_GENERATOR: native signed origin lock produced; awaiting Nix fixed hash'
  '';
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
    export -n provider_token
    unset GITHUB_TOKEN GH_TOKEN GITHUB_ENTERPRISE_TOKEN TF_ENCRYPTION
    unset secret encryption_config
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
    # A plan is evidence, not an effect grant. Unknowns, drift, import and
    # outside-F changes refuse; later V8 requires independent world readback.
    if ! TF_ENCRYPTION="$encryption_config" tofu -chdir=/work/repos/windows/infra/github show -json "$tmp/plan" |
      jq -e -f ${planGuard} >/dev/null; then
      fail 'unknown, drift, import or non-description plan; no apply'
    fi
    echo 'github-root: bounded native plan only; no apply'
  '';
  # No provider download/init, external Git ref or secret read in this check.
  check = pkgs.runCommand "github-root-source-check" {
    nativeBuildInputs = [ pkgs.bash pkgs.opentofu pkgs.gnugrep pkgs.jq ];
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
    # Strict actual guard filter, synthetic plan only. No provider or remote I/O.
    cat >plan.json <<'PLAN'
{"format_version":"1.0","resource_changes":[{"address":"github_repository.windows","mode":"managed","type":"github_repository","name":"windows","change":{"actions":["update"],"before":{"id":"fixture-repo","name":"windows","description":"before","homepage":""},"after":{"id":"fixture-repo","name":"windows","description":"","homepage":""},"after_unknown":{}}}],"resource_drift":[],"output_changes":{}}
PLAN
    jq -e -f ${planGuard} plan.json >/dev/null
    jq '.resource_changes[0].change.actions = ["no-op"] | .resource_changes[0].change.after.description = "before"' plan.json |
      jq -e -f ${planGuard} >/dev/null
    reject() {
      if jq "$1" plan.json | jq -e -f ${planGuard} >/dev/null; then
        echo 'github-root: unsafe synthetic plan admitted' >&2
        exit 1
      fi
    }
    reject '.resource_changes[0].change.after.homepage = "unapproved"'
    reject '.resource_changes[0].change.after_unknown.homepage = true'
    reject '.resource_changes[0].change.after_unknown.nested = {"field": true}'
    reject '.resource_drift = [{"address": "github_repository.windows"}]'
    reject '.output_changes = {"output":{"change":{"actions":["update"]}}}'
    reject '.resource_changes[0].change.actions = ["delete","create"]'
    reject '.resource_changes[0].change.before.id = ""'
    reject '.resource_changes[0].change.importing = {"id":"windows"}'
    reject '.resource_changes[0].change.after_sensitive.token = true'
    reject '.resource_changes[0].deposed = "old-object"'
    reject '.checks = [{"status":"unknown"}]'
    # Consume only Nix's hash-pinned, publisher-signed origin generator
    # output. Never accept the former hand-seeded lock as equivalent.
    if ! cmp -s ${signedLock} ${./.terraform.lock.hcl}; then
      echo 'S1_GENERATED_LOCK_BEGIN'
      cat ${signedLock}
      echo 'S1_GENERATED_LOCK_END'
      echo 'S1_LOCK_GENERATOR: generated signed lock differs from tracked source' >&2
      exit 1
    fi
    echo 'S1_LOCK_GENERATOR: exact signed origin lock matches committed source'
    touch "$out"
  '';
in {
  inherit app check;
}
