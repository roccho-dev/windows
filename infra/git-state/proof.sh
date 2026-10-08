#!/usr/bin/env bash
# provider-free, local-only, exact-binary finite test. No product state, auth or endpoints.
set -euo pipefail
umask 077

main_tf=$1
backend_bin=$2
result=$3
fx="$TMPDIR/git-state-poc"
mkdir -p "$fx/home" "$fx/seed" "$fx/a" "$fx/b" "$fx/tmp-a" "$fx/tmp-b"
export HOME="$fx/home"
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_TERMINAL_PROMPT=0
export TF_IN_AUTOMATION=1 TF_INPUT=0 CHECKPOINT_DISABLE=1
unset GITHUB_TOKEN GITHUB_TOKEN_FILE GIT_PASSWORD GIT_PASSWORD_FILE GIT_USERNAME SSH_AUTH_SOCK

# The upstream go-git credential resolver attempts SSH even for file:// URLs.
# A throwaway signer satisfies that lookup; go-git's file transport ignores it.
ssh-keygen -q -t ed25519 -N '' -f "$fx/id_ed25519" >/dev/null
export SSH_PRIVATE_KEY="$fx/id_ed25519"
remote="$fx/remote.git"
git init --quiet --bare --initial-branch=main "$remote"
git -C "$fx/seed" init --quiet --initial-branch=main
git -C "$fx/seed" -c user.name=fixture -c user.email=fixture@example.invalid \
  commit --quiet --allow-empty -m 'synthetic initial ref'
git -C "$fx/seed" remote add origin "file://$remote"
git -C "$fx/seed" push --quiet origin HEAD:refs/heads/main
test "$(git --git-dir="$remote" rev-list --count refs/heads/main)" = 1
echo 'GIT_STATE_POC seeded-nonempty-git-ref'

# End-to-end OpenTofu encryption plus upstream's fixture-only AES transport storage.
# Both state and plan refuse absent native encryption rather than downgrading.
suffix=$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')
canary_a="SYNTHETIC_${suffix}_A"
canary_b="SYNTHETIC_${suffix}_B"
export TF_VAR_synthetic_value="$canary_a"
export TF_BACKEND_HTTP_ENCRYPTION_PROVIDER=aes
export TF_BACKEND_HTTP_ENCRYPTION_PASSPHRASE="local-fixture-only-backend-$suffix"
export TF_ENCRYPTION="key_provider \"pbkdf2\" \"fixture\" {
  passphrase = \"local-fixture-only-tofu-passphrase-$suffix\"
  iterations = 200000
}
method \"aes_gcm\" \"fixture\" {
  keys = key_provider.pbkdf2.fixture
}
state {
  method = method.aes_gcm.fixture
  enforced = true
}
plan {
  method = method.aes_gcm.fixture
  enforced = true
}"
cp "$main_tf" "$fx/a/main.tf"
cp "$main_tf" "$fx/b/main.tf"

pids=()
pid_a=
pid_b=
cleanup() {
  local p
  for p in "${pids[@]}"; do kill "$p" 2>/dev/null || true; done
  for p in "${pids[@]}"; do wait "$p" 2>/dev/null || true; done
  # Nix owns the isolated build directory; never recursively delete fixture/foreign objects.
}
trap cleanup EXIT
port_free() {
  python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()'
}
state_url() {
  printf 'http://127.0.0.1:%s/?type=git&repository=file://%s&ref=main&state=state.tfstate' "$1" "$remote"
}
start_backend() {
  local which=$1 port=$2
  (cd "$fx/tmp-$which"; exec env TMPDIR="$fx/tmp-$which" "$backend_bin" --address "127.0.0.1:$port") \
    >"$fx/backend-$which.log" 2>&1 &
  local pid=$!
  pids+=("$pid")
  if [ "$which" = a ]; then pid_a=$pid; elif [ "$which" = b ]; then pid_b=$pid; fi
  local url code round
  url=$(state_url "$port")
  for round in $(seq 1 70); do
    if ! kill -0 "$pid" 2>/dev/null; then
      echo "backend-$which terminated during startup" >&2
      sed -n '1,35p' "$fx/backend-$which.log" >&2
      return 1
    fi
    code=$(curl --silent --max-time 2 -o "$fx/ready-$which" -w '%{http_code}' "$url") || code=000
    if [ "$code" = 204 ] || [ "$code" = 200 ]; then return 0; fi
    sleep 0.2
  done
  echo "backend-$which did not reach a readable local state endpoint" >&2
  return 1
}
port_a=$(port_free)
start_backend a "$port_a"
port_b=$(port_free)
if [ "$port_a" = "$port_b" ]; then echo 'fixture ports collided' >&2; exit 1; fi
start_backend b "$port_b"
url_a=$(state_url "$port_a")
url_b=$(state_url "$port_b")
echo 'GIT_STATE_POC two-loopback-backends-ready'

tf_init() {
  local client=$1 url=$2
  tofu -chdir="$fx/$client" init -input=false -no-color -reconfigure \
    -backend-config="address=$url" \
    -backend-config="lock_address=$url" \
    -backend-config="unlock_address=$url" \
    -backend-config="lock_method=LOCK" \
    -backend-config="unlock_method=UNLOCK" \
    >"$fx/init-$client.log" 2>&1 || {
    echo "synthetic tofu init failed for client-$client" >&2
    sed -n '1,55p' "$fx/init-$client.log" >&2
    return 1
  }
  echo "GIT_STATE_POC client-$client-init"
}
tf_init a "$url_a"
tofu -chdir="$fx/a" apply -input=false -no-color -auto-approve \
  >"$fx/apply-a.log" 2>&1 || {
  echo 'synthetic tofu initial apply failed' >&2
  sed -n '1,55p' "$fx/apply-a.log" >&2
  exit 1
}
echo 'GIT_STATE_POC client-a-apply-success'
tofu -chdir="$fx/a" state pull >"$fx/state-a.json" 2>"$fx/state-pull-a.log" || {
  echo 'synthetic state pull failed after apply' >&2
  sed -n '1,45p' "$fx/state-pull-a.log" >&2
  exit 1
}
echo 'GIT_STATE_POC client-a-state-pull-success'
# Exact observed native terraform_data DynamicPseudoType encoding is
# {"type":"string","value":...}; require one managed fixture and both values.
# Never log the value or its hashes. The same assertion is used on both clients.
fixture_matches() {
  local file=$1 expected=$2
  jq -e --arg v "$expected" '
    def packed_string($s):
      type == "object" and (keys | sort) == ["type","value"]
      and .type == "string" and (.value | type) == "string" and .value == $s;
    (.resources | length) == 1 and
    ([.resources[] | select(.mode == "managed" and .type == "terraform_data" and .name == "fixture")] | length) == 1 and
    ([.resources[] | select(.mode == "managed" and .type == "terraform_data" and .name == "fixture") | .instances[]] | length) == 1 and
    (.resources[0].instances[0].attributes |
      (.input | packed_string($v)) and
      (.output | packed_string($v)) and .input == .output)
  ' "$file" >/dev/null
}
fixture_matches "$fx/state-a.json" "$canary_a" || {
  echo 'synthetic state missing its expected built-in terraform_data value' >&2
  jq -c '{
    resource_count: (.resources | length),
    fixture: [.resources[] | select(.type == "terraform_data" and .name == "fixture") |
      {mode, type, name, instance_count: (.instances | length),
       schemas: [.instances[] | .attributes |
         {attribute_names: keys,
          input_kind: (.input | type),
          input_keys: (if (.input | type) == "object" then (.input | keys) else [] end),
          input_fields: (if (.input | type) == "object" then (.input | to_entries | map({key, kind: (.value | type)})) else [] end),
          output_kind: (.output | type),
          output_keys: (if (.output | type) == "object" then (.output | keys) else [] end),
          output_fields: (if (.output | type) == "object" then (.output | to_entries | map({key, kind: (.value | type)})) else [] end)}]}]
  }' "$fx/state-a.json" >&2 || true
  exit 1
}
echo 'GIT_STATE_POC client-a-resource-value-verified'
serial_a=$(jq -er '.serial' "$fx/state-a.json")
lineage_a=$(jq -er '.lineage' "$fx/state-a.json")
test -n "$lineage_a" && test "$serial_a" -gt 0
test "$(git --git-dir="$remote" rev-list --count refs/heads/main)" -gt 1
echo 'GIT_STATE_POC clean-init-apply-encrypted-git-save'

# Second clean working directory and second independent backend process.
tf_init b "$url_b"
tofu -chdir="$fx/b" state pull >"$fx/state-b.json"
jq -e --arg s "$serial_a" --arg l "$lineage_a" '(.serial | tostring) == $s and .lineage == $l' \
  "$fx/state-b.json" >/dev/null
fixture_matches "$fx/state-b.json" "$canary_a"
tofu -chdir="$fx/b" plan -input=false -no-color -out="$fx/plan.encrypted" \
  >"$fx/plan-b.log" 2>&1
test -s "$fx/plan.encrypted"
if grep -aFq "$canary_a" "$fx/plan.encrypted"; then echo 'plaintext in encrypted plan' >&2; exit 1; fi
echo 'GIT_STATE_POC independent-restore-lineage-serial-plan'

# Real upstream LOCK/UNLOCK protocol: backend A holds an owned synthetic lock,
# separately initialized tofu client B must reject state mutation from backend B.
cat >"$fx/owner-lock.json" <<'EOF'
{"ID":"finite-fixture-owned-lock","Operation":"OperationTypeApply","Who":"synthetic-client-a","Version":"fixture","Created":"2026-10-08T00:00:00Z","Path":"state.tfstate"}
EOF
cat >"$fx/challenger-lock.json" <<'EOF'
{"ID":"finite-fixture-challenger-lock","Operation":"OperationTypeApply","Who":"synthetic-client-b","Version":"fixture","Created":"2026-10-08T00:00:00Z","Path":"state.tfstate"}
EOF
http_code() {
  local method=$1 url=$2 payload=$3
  curl --silent --max-time 15 --output "$fx/http-response" --write-out '%{http_code}' \
    --header 'Content-Type: application/json' --request "$method" \
    --data-binary @"$payload" "$url"
}
test "$(http_code LOCK "$url_a" "$fx/owner-lock.json")" = 200
lock_ref=refs/heads/locks/state.tfstate
git --git-dir="$remote" show-ref --verify --quiet "$lock_ref"
git --git-dir="$remote" show "$lock_ref:state.tfstate.lock" |
  jq -e '.ID == "finite-fixture-owned-lock" and .Who == "synthetic-client-a"' >/dev/null
main_at_lock=$(git --git-dir="$remote" rev-parse refs/heads/main)
# Reject a second independent lock requester; a 500 due to upstream incompatibility
# is NOT misreported as successful 409 semantics.
code=$(http_code LOCK "$url_b" "$fx/challenger-lock.json")
test "$code" = 409 || { echo "second backend failed to report conflict (HTTP $code)" >&2; exit 1; }
if timeout 45s tofu -chdir="$fx/b" plan -input=false -no-color -lock-timeout=0s \
  >"$fx/lock-refusal.log" 2>&1; then
  echo 'second tofu client bypassed the held Git lock' >&2; exit 1
else
  status=$?
  test "$status" -ne 124 && grep -iq 'lock' "$fx/lock-refusal.log"
fi
test "$(git --git-dir="$remote" rev-parse refs/heads/main)" = "$main_at_lock"
echo 'GIT_STATE_POC two-process-lock-refusal'

# Simulate the owning HTTP backend dying while its remote Git lock remains.
kill "$pid_a"
wait "$pid_a" 2>/dev/null || true
! kill -0 "$pid_a" 2>/dev/null
git --git-dir="$remote" show-ref --verify --quiet "$lock_ref"
if timeout 45s tofu -chdir="$fx/b" plan -input=false -no-color -lock-timeout=0s \
  >"$fx/interrupted-lock.log" 2>&1; then
  echo 'stale lock was silently overwritten after owner interruption' >&2; exit 1
else
  status=$?
  test "$status" -ne 124 && grep -iq 'lock' "$fx/interrupted-lock.log"
fi
test "$(git --git-dir="$remote" rev-parse refs/heads/main)" = "$main_at_lock"
# We own the exact fixture lock and have observed that its process is absent:
# release via the ordinary HTTP UNLOCK with exact owner ID, not force-unlock.
test "$(http_code UNLOCK "$url_b" "$fx/owner-lock.json")" = 200
if git --git-dir="$remote" show-ref --verify --quiet "$lock_ref"; then
  echo 'owned fixture lock remained after standard unlock' >&2; exit 1
fi
echo 'GIT_STATE_POC interruption-owned-unlock'

# Standard Git pre-receive is fixture-only fault injection, not an owned
# backend or a new lock protocol: accept lock refs but deny main state writes.
save_ref_before=$(git --git-dir="$remote" rev-parse refs/heads/main)
test ! -e "$remote/hooks/pre-receive" && test ! -L "$remote/hooks/pre-receive"
cat >"$remote/hooks/pre-receive" <<EOF
#!/bin/sh
while read -r old new ref; do
  if [ "\$ref" = refs/heads/main ]; then
    printf '%s\n' denied-main > "$fx/denied-main-push"
    echo 'synthetic Git main ref save denied' >&2
    exit 1
  fi
done
exit 0
EOF
chmod 700 "$remote/hooks/pre-receive"
export TF_VAR_synthetic_value="$canary_b"
if timeout 70s tofu -chdir="$fx/b" apply -input=false -no-color -auto-approve \
  >"$fx/apply-rejected-save.log" 2>&1; then
  echo 'synthetic remote rejected state save but tofu reported success' >&2
  exit 1
else
  status=$?
  test "$status" -ne 124 || { echo 'synthetic failed-save apply timed out' >&2; exit 1; }
fi
test -f "$fx/denied-main-push" && test "$(cat "$fx/denied-main-push")" = denied-main || {
  echo 'failed apply did not reach standard Git main state push' >&2; exit 1
}
test "$(git --git-dir="$remote" rev-parse refs/heads/main)" = "$save_ref_before" || {
  echo 'failed state save changed remote Git main' >&2; exit 1
}
if git --git-dir="$remote" show-ref --verify --quiet "$lock_ref"; then
  echo 'failed state save left unresolved lock; standard-tool repair deferred' >&2; exit 1
fi
# Distinguish failed in-memory backend cache from remote recoverability.
if tofu -chdir="$fx/b" state pull >"$fx/state-save-rejected.json" 2>"$fx/rejected-pull.log"; then
  jq -e --arg l "$lineage_a" --argjson s "$serial_a" \
    '.lineage == $l and .serial == $s' "$fx/state-save-rejected.json" >/dev/null
  fixture_matches "$fx/state-save-rejected.json" "$canary_a"
  echo 'GIT_STATE_POC original-process-read-after-denied-save-ok'
else
  echo 'GIT_STATE_POC original-process-read-after-denied-save-failed'
fi
# Remove only the known synthetic standard Git fault hook.
test -f "$remote/hooks/pre-receive"
rm -- "$remote/hooks/pre-receive"
test ! -e "$remote/hooks/pre-receive"

# Independent fresh process and client recover the persisted Git state.
mkdir -p "$fx/c" "$fx/tmp-c"
cp "$main_tf" "$fx/c/main.tf"
port_c=$(port_free)
test "$port_c" != "$port_a" && test "$port_c" != "$port_b"
start_backend c "$port_c"
url_c=$(state_url "$port_c")
tf_init c "$url_c"
tofu -chdir="$fx/c" state pull >"$fx/state-recovered.json" 2>"$fx/recovery-pull.log" || {
  echo 'independent clean process could not recover persisted state' >&2; exit 1
}
jq -e --arg l "$lineage_a" --argjson s "$serial_a" \
  '.lineage == $l and .serial == $s' "$fx/state-recovered.json" >/dev/null
fixture_matches "$fx/state-recovered.json" "$canary_a"
test "$(git --git-dir="$remote" rev-parse refs/heads/main)" = "$save_ref_before"
echo 'GIT_STATE_POC denied-state-save-independent-process-restore'

# Retry only through the ordinary repaired backend with this fresh client.
tofu -chdir="$fx/c" apply -input=false -no-color -auto-approve \
  >"$fx/apply-b.log" 2>&1
tofu -chdir="$fx/c" state pull >"$fx/state-after.json"
jq -e --arg l "$lineage_a" --argjson s "$serial_a" \
  '.lineage == $l and .serial > $s' "$fx/state-after.json" >/dev/null
fixture_matches "$fx/state-after.json" "$canary_b"
echo 'GIT_STATE_POC post-interruption-save-no-overwrite'

# With the native encryption environment missing, the source-enforced state/plan
# encryption must fail closed; no additional Git commit or plaintext plan file.
main_before=$(git --git-dir="$remote" rev-parse refs/heads/main)
if env -u TF_ENCRYPTION tofu -chdir="$fx/c" plan -input=false -no-color \
  -out="$fx/no-encryption.plan" >"$fx/no-encryption.log" 2>&1; then
  echo 'tofu wrote a plan without required encryption' >&2; exit 1
fi
test ! -e "$fx/no-encryption.plan"
# Exit status alone is not encryption proof; require a native encryption
# diagnostic and exclude unrelated transport failures.
if ! grep -Eiq '(encrypt|enforc)' "$fx/no-encryption.log"; then
  echo 'missing native encryption was not the diagnosed refusal cause' >&2; exit 1
fi
if grep -Eiq '(connection refused|no route to host|dial tcp|HTTP 50[0-9])' "$fx/no-encryption.log"; then
  echo 'network error cannot prove enforced encryption rejection' >&2; exit 1
fi
test "$(git --git-dir="$remote" rev-parse refs/heads/main)" = "$main_before"
if git --git-dir="$remote" show-ref --verify --quiet "$lock_ref"; then
  echo 'missing-encryption test left a Git lock' >&2; exit 1
fi
echo 'GIT_STATE_POC missing-encryption-diagnostic-and-ref-refusal'

# All object blobs, including unreachable historical Git objects, must be free
# of either synthetic state secret. Never print or hash real key material.
git --git-dir="$remote" cat-file --batch-all-objects \
  --batch-check='%(objectname) %(objecttype)' >"$fx/object-index"
while read -r oid kind; do
  if [ "$kind" = blob ]; then
    git --git-dir="$remote" cat-file blob "$oid" >"$fx/blob-test"
    for secret in "$canary_a" "$canary_b"; do
      if grep -aFq "$secret" "$fx/blob-test"; then
        echo 'plaintext synthetic secret leaked into Git object history' >&2
        exit 1
      fi
    done
  fi
done <"$fx/object-index"
test ! -e "$fx/no-encryption.plan"
touch "$fx/foreign-keep"
test -f "$fx/foreign-keep"
echo 'GIT_STATE_POC all-git-objects-no-plaintext; foreign-fixture-preserved'
touch "$result"
