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
  # Separate ABSENT-state admission; normal planGuard still rejects imports.
  adoptionGuard = pkgs.writeText "github-root-adoption-guard.jq" ''
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
        ($c.importing == {"id":"windows"}) and
        ($c.before | type == "object") and
        ($c.after | type == "object") and
        ($c.before.id == "windows") and
        ($c.after.id == "windows") and
        ($c.before.name == "windows" and $c.after.name == "windows") and
        (($c.after_unknown // {}) | no_unknown) and
        (($c.before_sensitive // {}) | no_unknown) and
        (($c.after_sensitive // {}) | no_unknown) and
        ($c.before as $before |
         $c.after as $after |
         ([($before | keys[]), ($after | keys[])] | unique |
          all(.[]; . == "description" or $before[.] == $after[.])))))
  '';
  # Readback verifies only the existing repository and native state identity.
  receiptGuard = pkgs.writeText "github-root-adoption-receipt.jq" ''
    (.lineage | type == "string" and length > 0) and
    (.serial | type == "number" and . >= 1) and
    (.resources | type == "array" and length == 1) and
    (.resources[0] as $r |
      ($r.mode == "managed") and
      ($r.type == "github_repository") and
      ($r.name == "windows") and
      ($r.instances | type == "array" and length == 1) and
      ($r.instances[0].attributes.id == "windows") and
      ($r.instances[0].attributes.name == "windows"))
  '';
  # The only principal source: the declared bound repository's existing Git credential helper slot. Both Git calls
  # drop any inherited repository or config injection, read no system/global config and never prompt or askpass
  # (the bound repository already names the username, so a fallback could otherwise supply the token). It sets
  # provider_token for the caller and prints nothing; an unbound origin, missing slot, missing token or another
  # principal fails closed.
  credential = pkgs.writeText "github-root-bound-credential.sh" ''
    bound_token() {
      local src=$1 principal=$2 url=$3 cred
      local -a g=(env -u GIT_DIR -u GIT_WORK_TREE -u GIT_COMMON_DIR -u GIT_INDEX_FILE -u GIT_OBJECT_DIRECTORY
        -u GIT_ALTERNATE_OBJECT_DIRECTORIES -u GIT_CONFIG -u GIT_CONFIG_PARAMETERS -u GIT_CONFIG_COUNT
        -u GIT_EXEC_PATH -u GIT_ASKPASS -u SSH_ASKPASS
        GIT_TERMINAL_PROMPT=0 GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
        git -C "$src" -c core.askPass= -c credential.interactive=never)
      provider_token=
      [ "$("''${g[@]}" config --get remote.origin.url)" = "$url" ] || return 1
      cred=$(printf 'url=%s\n\n' "$url" | "''${g[@]}" credential fill) || return 1
      case $'\n'$cred$'\n' in
        *$'\n'"username=$principal"$'\n'*) ;;
        *) unset cred; return 1 ;;
      esac
      case $'\n'$cred in
        *$'\n'password=?*) ;;
        *) unset cred; return 1 ;;
      esac
      provider_token=''${cred#*$'\n'password=}
      provider_token=''${provider_token%%$'\n'*}
      unset cred
    }
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
    [ "$#" = 1 ] || fail 'usage: github-root plan|adopt; separate operational GO required'
    case "$1" in
      plan|adopt) mode=$1 ;;
      *) fail 'only named plan/adopt modes; no generic apply/import route' ;;
    esac
    # Inherited principals are never used; the token comes only from the declared bound repository.
    unset GITHUB_TOKEN GH_TOKEN GITHUB_ENTERPRISE_TOKEN TF_ENCRYPTION SSH_PRIVATE_KEY
    unset secret encryption_config provider_token
    src=/work/repos/windows.git/.worktrees/host-own-ghinfra-runtime
    repo_url=https://github.com/roccho-dev/windows
    uid=$(id -u)
    [ "$PWD" = "$src" ] && [ -f infra/github/main.tf ] ||
      fail 'declared own source checkout not established'
    . ${credential}
    # Native GitHub token stays shell-private, reaching only the backend and OpenTofu children.
    bound_token "$src" roccho-dev "$repo_url" ||
      fail 'bound windows repository credential missing or not the declared roccho-dev principal'
    export -n provider_token
    dir=/work/repos/.auth/roccho-dev/opentofu
    key=$dir/github-windows.passphrase
    [ -d "$dir" ] && [ ! -L "$dir" ] &&
      [ "$(stat -c '%u:%a' "$dir")" = "$uid:700" ] &&
      [ -f "$key" ] && [ ! -L "$key" ] && [ -s "$key" ] &&
      [ "$(stat -c '%u:%a' "$key")" = "$uid:600" ] ||
      fail 'dedicated custody not owned 0700/0600 by the effective UID'
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
      rm -f -- "$tmp/backend.log" "$tmp/init.log" "$tmp/plan.log" "$tmp/plan" "$tmp/apply.log" "$tmp/readback.log"
      rmdir -- "$tmp" 2>/dev/null || true
    }
    trap cleanup EXIT
    # Upstream HTTPS basic auth needs GIT_USERNAME even for a token; a prefix assignment keeps the token out of argv.
    GIT_USERNAME=x-access-token GITHUB_TOKEN="$provider_token" ${backend}/bin/terraform-backend-git --address "127.0.0.1:$port" >"$tmp/backend.log" 2>&1 &
    pid=$!
    url="http://127.0.0.1:$port/?type=git&repository=https%3A%2F%2Fgithub.com%2Froccho-dev%2Fwindows.git&ref=tofu-state&state=state%2Fgithub-windows.json"
    ready=0
    for round in $(seq 1 50); do
      kill -0 "$pid" 2>/dev/null || fail 'standard backend exited'
      code=$(curl -sS --max-time 1 -o /dev/null -w '%{http_code}' "$url") || code=000
      if [ "$code" = 200 ] || [ "$code" = 204 ]; then ready=1; break; fi
      sleep 0.2
    done
    [ "$ready" = 1 ] || fail 'transient loopback backend not ready'
    if ! TF_ENCRYPTION="$encryption_config" GITHUB_TOKEN="$provider_token" tofu -chdir="$src/infra/github" init -input=false -reconfigure -lockfile=readonly \
      -backend-config="address=$url" -backend-config="lock_address=$url" \
      -backend-config="unlock_address=$url" -backend-config="lock_method=LOCK" \
      -backend-config="unlock_method=UNLOCK" >"$tmp/init.log" 2>&1; then
      fail 'standard native init rejected; no fallback'
    fi
    if ! TF_ENCRYPTION="$encryption_config" GITHUB_TOKEN="$provider_token" tofu -chdir="$src/infra/github" plan -input=false -out="$tmp/plan" >"$tmp/plan.log" 2>&1; then
      fail 'standard native plan rejected; no apply'
    fi
    # The existing plan mode remains read-only and rejects all importing.
    # A separately authorized G operator can later invoke adopt only after
    # I/B/K/G principal, inventory, custody, exclusive owner and review gates.
    guard=${planGuard}
    [ "$mode" = adopt ] && guard=${adoptionGuard}
    if ! TF_ENCRYPTION="$encryption_config" tofu -chdir="$src/infra/github" show -json "$tmp/plan" |
      jq -e -f "$guard" >/dev/null; then
      fail 'native plan not admissible for this mode; no apply'
    fi
    if [ "$mode" = plan ]; then
      echo 'github-root: bounded native plan only; no apply'
      exit 0
    fi
    # Only the ONE reviewed, saved import plan: never auto-approve or replan.
    if ! TF_ENCRYPTION="$encryption_config" GITHUB_TOKEN="$provider_token" \
      tofu -chdir="$src/infra/github" apply -input=false -no-color "$tmp/plan" \
      >"$tmp/apply.log" 2>&1; then
      fail 'native saved-plan adoption failed; reconcile UNKNOWN before retry'
    fi
    # State readback stays in an in-memory pipe, never a plaintext file/log.
    if ! TF_ENCRYPTION="$encryption_config" GITHUB_TOKEN="$provider_token" \
      tofu -chdir="$src/infra/github" state pull 2>"$tmp/readback.log" |
      jq -e -f ${receiptGuard} >/dev/null; then
      fail 'native adoption receipt not proven; reconcile UNKNOWN'
    fi
    echo 'github-root: native existing-repository adoption receipt verified'
  '';
  # No provider download/init, external Git ref or secret read in this check.
  check = pkgs.runCommand "github-root-source-check" {
    nativeBuildInputs = [ pkgs.bash pkgs.opentofu pkgs.gnugrep pkgs.jq pkgs.git ];
  } ''
    set -eu
    tofu fmt -check -no-color ${./main.tf}
    bash -n ${app}/bin/github-root
    bash -n ${credential}
    ${app}/bin/github-root --source-check >source-check.log
    grep -qF 'source-only check, no backend or provider' source-check.log
    grep -qF 'unset GITHUB_TOKEN GH_TOKEN GITHUB_ENTERPRISE_TOKEN TF_ENCRYPTION SSH_PRIVATE_KEY' ${app}/bin/github-root
    grep -qF 'GIT_USERNAME=x-access-token GITHUB_TOKEN="$provider_token" ${backend}/bin/terraform-backend-git' ${app}/bin/github-root
    grep -qF 'repository=https%3A%2F%2Fgithub.com%2Froccho-dev%2Fwindows.git' ${app}/bin/github-root
    grep -qF 'bound_token "$src" roccho-dev "$repo_url"' ${app}/bin/github-root
    grep -qF 'TF_ENCRYPTION="$encryption_config" GITHUB_TOKEN="$provider_token" tofu' ${app}/bin/github-root
    if grep -qF 'export TF_ENCRYPTION=' ${app}/bin/github-root; then
      echo 'github-root: broad secret export' >&2
      exit 1
    fi
    # Retired routes: no SSH principal, no fixed UID0 or old cwd, no token export or env-argv handoff.
    for retired in '$SSH_PRIVATE_KEY' 'git%40github.com' '/work/repos/windows/' '= 0:700' '= 0:600' \
      'id -u)" = 0' 'export GITHUB_TOKEN' 'export provider_token' 'env -u'; do
      if grep -qF -- "$retired" ${app}/bin/github-root; then
        echo "github-root: retired route present: $retired" >&2
        exit 1
      fi
    done
    # The bound credential source against a fixture repository: only the declared principal's slot for the
    # declared origin yields a token, and nothing is printed. Wrong or missing slot and token are RED.
    . ${credential}
    export HOME=$PWD/home GIT_CONFIG_NOSYSTEM=1
    mkdir -p home
    u=https://github.com/roccho-dev/windows
    git init -q fx
    git -C fx config remote.origin.url "$u"
    git -C fx config credential.helper ""
    git -C fx config credential.useHttpPath true
    git -C fx config "credential.$u.helper" "$PWD/helper"
    # As the real bind writes, the bound repository always names the declared username itself.
    git -C fx config "credential.$u.username" roccho-dev
    cat >helper <<HELPER
#!${pkgs.runtimeShell}
[ "\$1" = get ] || exit 0
cat "$PWD/answer"
HELPER
    chmod +x helper
    # A token from anywhere but the bound slot: answers both as a credential helper and as an askpass program.
    cat >rogue <<ROGUE
#!${pkgs.runtimeShell}
case "\$1" in get) printf 'username=roccho-dev\npassword=fixture-token\n' ;; *[Pp]assword*) echo fixture-token ;; esac
ROGUE
    chmod +x rogue
    git init -q fx2
    git -C fx2 config remote.origin.url "$u"
    git -C fx2 config credential.helper "$PWD/rogue"
    answer() {
      printf "$1" >answer
      if bound_token fx roccho-dev "$u" >out.log 2>err.log; then got=0; else got=1; fi
      if [ "$got" != "$2" ] || [ -s out.log ] || grep -qF fixture-token err.log; then
        echo "github-root: bound credential case $3 wrong" >&2
        exit 1
      fi
    }
    answer 'username=roccho-dev\npassword=fixture-token\n' 0 bound
    [ "$provider_token" = fixture-token ] || { echo 'github-root: bound token not selected' >&2; exit 1; }
    answer 'username=other-principal\npassword=fixture-token\n' 1 wrong-slot
    answer "" 1 missing-slot
    answer 'username=roccho-dev\n' 1 missing-token
    # With the username already known, an empty slot must not fall back to a configured askpass, an injected
    # helper or an inherited repository.
    git -C fx config core.askPass "$PWD/rogue"
    answer "" 1 config-askpass
    git -C fx config --unset core.askPass
    export GIT_CONFIG_COUNT=2 GIT_CONFIG_KEY_0=credential.helper GIT_CONFIG_VALUE_0= \
      GIT_CONFIG_KEY_1=credential.helper GIT_CONFIG_VALUE_1="$PWD/rogue"
    answer "" 1 injected-helper
    unset GIT_CONFIG_COUNT GIT_CONFIG_KEY_0 GIT_CONFIG_VALUE_0 GIT_CONFIG_KEY_1 GIT_CONFIG_VALUE_1
    export GIT_DIR=$PWD/fx2/.git
    answer "" 1 inherited-repository
    unset GIT_DIR
    git -C fx config remote.origin.url https://github.com/roccho-dev/other
    answer 'username=roccho-dev\npassword=fixture-token\n' 1 other-origin
    [ -z "$provider_token" ] || { echo 'github-root: failed lookup kept a token' >&2; exit 1; }
    echo 'github-root-source: bound credential fixtures passed'
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
    # Source-only import tests. The real backend/provider/apply is never run.
    jq '.resource_changes[0].change.importing = {"id":"windows"} |
        .resource_changes[0].change.before.id = "windows" |
        .resource_changes[0].change.after.id = "windows"' plan.json >adopt.json
    jq -e -f ${adoptionGuard} adopt.json >/dev/null
    if jq -e -f ${planGuard} adopt.json >/dev/null; then
      echo 'github-root: normal plan incorrectly admitted import' >&2; exit 1
    fi
    reject_adopt() {
      if jq "$1" adopt.json | jq -e -f ${adoptionGuard} >/dev/null; then
        echo 'github-root: unsafe synthetic adoption admitted' >&2; exit 1
      fi
    }
    reject_adopt 'del(.resource_changes[0].change.importing)'
    reject_adopt '.resource_changes[0].change.importing.id = "other"'
    reject_adopt '.resource_changes[0].change.importing.extra = "other"'
    reject_adopt '.resource_changes[0].change.actions = ["create"]'
    reject_adopt '.resource_changes[0].change.actions = ["delete","create"]'
    reject_adopt '.resource_changes[0].change.before.id = "other"'
    reject_adopt '.resource_changes[0].change.after.name = "another"'
    reject_adopt '.resource_changes[0].change.after.homepage = "unexpected"'
    reject_adopt '.resource_changes[0].change.after_unknown.homepage = true'
    reject_adopt '.resource_drift = [{"address":"github_repository.windows"}]'
    reject_adopt '.output_changes = {"out":{"change":{"actions":["create"]}}}'
    reject_adopt '.resource_changes += [.resource_changes[0]]'
    cat >receipt.json <<'RECEIPT'
{"lineage":"synthetic","serial":2,"resources":[{"mode":"managed","type":"github_repository","name":"windows","instances":[{"attributes":{"id":"windows","name":"windows"}}]}]}
RECEIPT
    jq -e -f ${receiptGuard} receipt.json >/dev/null
    if jq '.resources[0].instances[0].attributes.id = "unrelated"' receipt.json |
      jq -e -f ${receiptGuard} >/dev/null; then
      echo 'github-root: wrong-state receipt accepted' >&2; exit 1
    fi
    echo 'github-root-source: guarded existing-repository adoption fixtures passed'
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
