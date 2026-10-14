#!/usr/bin/env bash
# Disposable SOURCE proof for the fixed rent B-only OCI, not a live update controller.
# CI alone owns the quiet window. Target version/admission, real credentials and WSLC are outside this proof.
set -Eeuo pipefail
[ "$#" = 4 ] || { echo 'usage: native-proof.sh BASE_STUB_ARCHIVE T0_STORE_PATH T1_STORE_PATH FIXED_PROPOSED_BINDING_JSON' >&2; exit 2; }
archive=$1 t0=$2 t1=$3 binding=$4
[ -f "$binding" ] && [ ! -L "$binding" ] || { echo 'missing immutable public SOURCE fixture' >&2; exit 2; }
[[ $t0 =~ ^/nix/store/[0-9a-z]{32}-[^/]+$ && $t1 =~ ^/nix/store/[0-9a-z]{32}-[^/]+$ ]] &&
  [ "$t0" != "$t1" ] || { echo 'expected two distinct immutable Nix Tool closures' >&2; exit 2; }
p="rent-native-proof-$$"
c="$p-container" repos="$p-repos" state="$p-state" nixvol="$p-nix"
evidence=$(mktemp -d)
fail() { echo "rent-native-proof: $*" >&2; exit 1; }
cleanup() {
  status=$?
  trap - EXIT
  if [ "$status" -ne 0 ]; then docker logs "$c" 2>&1 | tail -n 25 || true; fi
  docker rm -f "$c" >/dev/null 2>&1 || true
  docker volume rm "$repos" "$state" "$nixvol" >/dev/null 2>&1 || true
  rm -f -- "$evidence/seed" "$evidence/import"
  rmdir -- "$evidence" || status=1
  exit "$status"
}
trap cleanup EXIT
docker load < "$archive" >/dev/null
image=$(docker image inspect ghcr.io/roccho-dev/windows-rent:base-stub --format '{{.Id}}')
for v in "$repos" "$state" "$nixvol"; do docker volume create "$v" >/dev/null; done
docker run --rm --network none -v "$state:/s" "$image" /bin/bash -euc '
  install -d -m 700 /s/cloudflared
  printf "ci-synthetic-token\n" > /s/cloudflared/token
  chmod 600 /s/cloudflared/token
  install -d -m 755 /s/dev
  install -d -m 700 -o 1000 -g 1000 /s/dev/codex /s/dev/claude
  printf "ci-auth-not-a-credential\n" > /s/dev/codex/auth.json
  printf "ci-session-marker\n" > /s/dev/claude/ci-session-marker
  chown 1000:1000 /s/dev/codex/auth.json /s/dev/claude/ci-session-marker
  chmod 600 /s/dev/codex/auth.json /s/dev/claude/ci-session-marker'
docker run --rm --network none -v "$repos:/r" "$image" /bin/bash -euc 'printf "ci-repository-marker\n" > /r/proof-marker'
seed() {
  docker run --rm --network none -v "$nixvol:/seed" -e "RENT_NIX_VOLUME=$nixvol" \
    "$image" /bin/rent-nix-seed
}
seed > "$evidence/seed"
mount_args=(--network none -v "$repos:/work/repos" -v "$state:/var/lib/rent"
  --mount "type=volume,source=$nixvol,target=/nix,volume-nocopy"
  -e "RENT_REPOS_VOLUME=$repos" -e "RENT_STATE_VOLUME=$state" -e "RENT_NIX_VOLUME=$nixvol"
  -e "RENT_AUTHORIZED_KEY=ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHJlbnQtZGV2LXByb29mLW5vdC1hLXJlYWwta2V5 ci")
launch() {
  docker run -d --name "$c" "${mount_args[@]}" "$image" >/dev/null
  ok=0
  for _ in {1..75}; do
    if docker logs "$c" 2>&1 | grep -qF 'rent-start ok services=nix-daemon,cloudflared,sshd' &&
       docker exec "$c" /bin/test -S /nix/var/nix/daemon-socket/socket >/dev/null 2>&1; then
      ok=1; break
    fi
    [ "$(docker inspect --format '{{.State.Running}}' "$c")" = true ] || break
    sleep 1
  done
  [ "$ok" = 1 ] || fail 'base-only OCI did not become service-ready'
}
launch
# Read O using only ordinary shell and filesystem evidence; no Nix daemon query or write.
observe() { docker exec -i -u 1000:1000 "$c" /bin/bash -s < hosts/rent/read-selected.sh; }
observe_ro() {
  docker run --rm -i --network none -v "$nixvol:/nix:ro" "$image" /bin/bash -s < hosts/rent/read-selected.sh
}
[ "$(observe)" = 'selection=ABSENT proof=geometry-only' ] ||
  fail 'fresh B was not observed as Tool-absent'
[ "$(observe_ro)" = 'selection=ABSENT proof=geometry-only' ] ||
  fail 'readonly volume observation of empty B failed'
[ ! -e /work ] || fail 'CI proof ran with a live /work mount'
initial=$(docker exec "$c" /bin/bash -euc '
  test ! -e /nix/var/nix/profiles/rent-dev && test ! -L /nix/var/nix/profiles/rent-dev
  test ! -x /bin/codex && test -x /bin/nix && test -x /bin/gh
  printf "base-only\n"')
[ "$initial" = base-only ] || fail 'unexpected initially selected Tool'
# READ has its own scope: neither a previous UNKNOWN effect nor an admitted D
# is a precondition for this disposable readonly observation.
actual_o=$(observe_ro)
bound_read=$(python3 hosts/rent/proposed-binding-proof.py /nonexistent-public-source-binding \
  --mode read --observation "$actual_o") || fail 'synthetic READ failed'
[[ $bound_read == *'"selection": "ABSENT"'* && $bound_read == *'"effect": "FORBIDDEN"'* ]] ||
  fail 'readonly observation was promoted to an effect'
# Transport the exact pre-built T closures, not an image rebuild or an implicit latest fetch.
nix-store --export $(nix-store --query --requisites "$t0" "$t1") |
  docker exec -i "$c" /bin/nix-store --import > "$evidence/import"
for t in "$t0" "$t1"; do
  docker exec "$c" /bin/nix-store --check-validity "$t"
done
# This helper lives only in the fixture. Real target changes require an independent current D/authority,
# continuous quiet ownership and a recovery plan; this process does not grant any of them.
native_set() {
  local desired=$1 processes wanted_helper core_helper paths path
  [ "$(docker inspect --format '{{.State.Running}}' "$c")" = true ] || return 1
  [ "$(docker exec "$c" /bin/id -u)" = 0 ] || return 1
  processes=$(docker top "$c" -eo pid,args) || return 1
  [[ $processes == *rent-start* && $processes == *nix-daemon* && $processes == *sshd* ]] || return 1
  if grep -qE '/bin/(codex|claude|python3|uv|hello)( |$)' <<< "$processes"; then return 1; fi
  core_helper=$(docker exec "$c" /bin/readlink -e /bin/git-credential-github-roccho-dev) || return 1
  wanted_helper=$(docker exec "$c" /bin/readlink -e "$desired/bin/git-credential-github-roccho-dev") || return 1
  [ "$wanted_helper" = "$core_helper" ] || return 1
  for app in codex claude python3 uv; do
    docker exec "$c" /bin/test -x "$desired/bin/$app" || return 1
  done
  paths=$(docker exec "$c" /bin/nix-store --query --requisites "$desired") || return 1
  # shellcheck disable=SC2086
  docker exec "$c" /bin/nix-store --check-validity $paths || return 1
  docker exec "$c" /bin/nix-env --profile /nix/var/nix/profiles/rent-dev --set "$desired"
}
# CI-only functional bridge: same proposed q/Host/scope goes from readonly O
# to actual fixed closure selection. No admitted D, credential or Target GO.
bound_q=$(python3 - "$binding" <<'PY'
import json,sys
with open(sys.argv[1], encoding="utf-8") as f:
    x=json.load(f)
print(x["proposed_q"])
PY
)
bound_preflight() {
  local wanted=$1 q=$2 host=$3 scope=$4 prior=$5 observation=$6
  local base=${7:-ci:rent-base-only-B0}
  python3 hosts/rent/proposed-binding-proof.py "$binding" --mode preflight \
    --candidate "$wanted" --expected-store "$t0" --q "$q" --host-ref "$host" --scope "$scope" \
    --previous "$prior" --observation "$observation" --base "$base" \
    --launch ci:rent-start-S0 --config-binding ci:rent-binding-C0 \
    --state-contract ci:rent-state-K0
}
selection() {
  local want=$1
  [ "$(docker exec "$c" /bin/readlink -e /nix/var/nix/profiles/rent-dev)" = "$want" ] ||
    fail "the selected native T is not $want"
  docker exec "$c" /bin/bash -euc '
    for app in codex claude python3 uv; do
      test "$(readlink -e /bin/$app)" = "$(readlink -e /nix/var/nix/profiles/rent-dev/bin/$app)"
    done
    test "$(codex --version)" = "codex-cli $(release-version codex)"
    claude --version >/dev/null
    python3 --version >/dev/null
    uv --version >/dev/null'
}
state_snapshot() {
  docker exec "$c" /bin/bash -euc '
    sha256sum /var/lib/rent/dev/codex/auth.json /var/lib/rent/dev/claude/ci-session-marker /work/repos/proof-marker
    stat -c "%n %u:%g %a" /var/lib/rent/dev/codex/auth.json /var/lib/rent/dev/claude/ci-session-marker'
}
snapshot=$(state_snapshot)
# F2: negatives with the SAME exact proposed binding as envs F1. All deny
# before any native_set, so the empty selector, image and state must persist.
before_o=$(observe_ro)
for mode in wrong-tool wrong-q wrong-host wrong-scope unknown-effect wrong-B; do
  case "$mode" in
    wrong-tool) args=("$t1" "$bound_q" ci-host-rent-1 ci-session-1 NONE "$before_o");;
    wrong-q) args=("$t0" sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa ci-host-rent-1 ci-session-1 NONE "$before_o");;
    wrong-host) args=("$t0" "$bound_q" ci-host-foreign ci-session-1 NONE "$before_o");;
    wrong-scope) args=("$t0" "$bound_q" ci-host-rent-1 ci-other-session NONE "$before_o");;
    unknown-effect) args=("$t0" "$bound_q" ci-host-rent-1 ci-session-1 UNKNOWN "$before_o");;
    wrong-B) args=("$t0" "$bound_q" ci-host-rent-1 ci-session-1 NONE "$before_o" ci:other-B");;
  esac
  if bound_preflight "${args[@]}" >/dev/null 2>&1; then
    fail "bounded SOURCE input $mode reached native mutation"
  fi
  [ "$(observe_ro)" = "$before_o" ] && [ "$(state_snapshot)" = "$snapshot" ] ||
    fail "bounded refusal $mode changed selection or auth/work state"
done
# The positive bound preflight is a non-executable candidate. The existing
# native_set is the ONLY Nix mutation inside this disposable Docker CI process.
preflight=$(bound_preflight "$t0" "$bound_q" ci-host-rent-1 ci-session-1 NONE "$before_o") ||
  fail 'bound q/Host/unit/source material rejected actual first O'
[[ $preflight == *'"stage": "SYNTHETIC_PROPOSED_DQ_PREFLIGHT_ONLY"'* &&
   $preflight == *'"effect": "FORBIDDEN"'* &&
   $preflight == *'"candidate_store": "'$t0'"'* ]] ||
  fail 'bound candidate did not select the exact actual T0 closure'
native_set "$t0"
selection "$t0"
actual_bound_o=$(observe_ro)
[ "$actual_bound_o" = "selection=SELECTED generation=rent-dev-1-link store=$t0 proof=geometry-only" ] ||
  fail 'bound q effect did not read back the actual T0'
[ "$(state_snapshot)" = "$snapshot" ] || fail 'bound T changed auth/session/repo'
# A lost receipt is UNKNOWN, not success or automatic NOOP. Re-read O but
# never perform an equivalent second write; a preflight retry must be denied.
if bound_preflight "$t0" "$bound_q" ci-host-rent-1 ci-session-1 UNKNOWN "$actual_bound_o" >/dev/null 2>&1; then
  fail 'unknown bound effect retried blindly'
fi
[ "$(observe_ro)" = "$actual_bound_o" ] ||
  fail 'UNKNOWN reconciliation read mutated the selected Tool'
echo 'PASS: proposed D/q/Host binding -> actual OCI O -> exact T0 Nix selector -> readback; wrong q/T/Host/scope/B/UNKNOWN refused'
case "$(observe)" in
  "selection=SELECTED generation=rent-dev-1-link store=$t0 proof=geometry-only") ;;
  *) fail 'T0 observed generation does not match selected T0' ;;
esac
test "$(observe)" = "$(observe_ro)" || fail 'running/readonly observation disagrees'
if docker exec -u 1000:1000 "$c" /bin/nix-env --profile /nix/var/nix/profiles/rent-dev --set "$t1"; then
  fail 'untrusted dev selected a root-owned profile'
fi
selection "$t0"
# Failed/unknown candidate is refused before mutation; the selected generation stays current.
if native_set /nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-not-registered; then
  fail 'unregistered candidate was selected'
fi
selection "$t0"
# Real non-quiescent app-parent fixture: do not kill a process and do not switch T.
docker exec -d "$c" /bin/bash -c 'exec -a /bin/codex /bin/bash -c "sleep 4; :"'
observed=
for _ in {1..20}; do
  observed=$(docker top "$c" -eo pid,args) || fail 'process observation UNKNOWN'
  grep -qF '/bin/codex -c' <<< "$observed" && break
  sleep 0.1
done
grep -qF '/bin/codex -c' <<< "$observed" || fail 'active app-parent fixture did not stay observable'
if native_set "$t1"; then fail 'Tool switched while an app was still active'; fi
selection "$t0"
sleep 5
native_set "$t1"
selection "$t1"
case "$(observe)" in
  "selection=SELECTED generation=rent-dev-2-link store=$t1 proof=geometry-only") ;;
  *) fail 'T1 selected geometry mismatch' ;;
esac
docker exec "$c" /bin/test -x /nix/var/nix/profiles/rent-dev/bin/hello || fail 'T1 extra missing'
docker exec "$c" /nix/var/nix/profiles/rent-dev/bin/hello >/dev/null
[ "$(state_snapshot)" = "$snapshot" ] || fail 'T-only generation update changed auth/session/repository'
before=$(docker exec "$c" /bin/readlink /nix/var/nix/profiles/rent-dev)
docker exec "$c" /bin/nix-env --profile /nix/var/nix/profiles/rent-dev --rollback
after=$(docker exec "$c" /bin/readlink /nix/var/nix/profiles/rent-dev)
[ "$before" != "$after" ] || fail 'native rollback did not select an earlier generation'
selection "$t0"
case "$(observe)" in
  "selection=SELECTED generation=rent-dev-1-link store=$t0 proof=geometry-only") ;;
  *) fail 'rollback was not observed as T0' ;;
esac
# A restart and a recreation retain T0; B itself does not re-select the highest T.
docker stop -t 30 "$c" >/dev/null
if native_set "$t1"; then fail 'Tool switched with no observable running context'; fi
docker start "$c" >/dev/null
for _ in {1..75}; do
  if docker exec "$c" /bin/test -S /nix/var/nix/daemon-socket/socket >/dev/null 2>&1; then break; fi
  sleep 1
done
selection "$t0"
[ "$(state_snapshot)" = "$snapshot" ] || fail 'restart changed recorded state'
native_set "$t1"
selection "$t1"
docker exec "$c" /bin/nix-store --gc >/dev/null
docker exec "$c" /bin/nix-store --check-validity "$t0" "$t1"
docker stop -t 30 "$c" >/dev/null
docker rm "$c" >/dev/null
seed > "$evidence/seed"
launch
selection "$t1"
[ "$(state_snapshot)" = "$snapshot" ] || fail 'recreation changed auth/session/repository'
test "$(observe)" = "$(observe_ro)" || fail 'recreation changed observed selection geometry'
docker exec "$c" /bin/nix-env --profile /nix/var/nix/profiles/rent-dev --list-generations
# Negative O-only fixtures run with the synthetic OCI stopped; each damaged preimage is retained
# and each read must refuse without mutation. Repair is part of disposable test, not observer code.
docker stop -t 30 "$c" >/dev/null
profile_geometry() {
  docker run --rm --network none -v "$nixvol:/nix:ro" "$image" /bin/bash -euc '
    cd /nix
    stat -c "%n|%a|%u|%g" var var/nix var/nix/profiles
    find var/nix/profiles var/nix/gcroots -printf "%p|%y|%l|%m|%U|%G|%s|%T@\n" | LC_ALL=C sort
    sha256sum var/rent-nix var/nix/db/db.sqlite' | sha256sum
}
assert_unknown_read_only() {
  local expected=$1 before after rc=0 outcome
  before=$(profile_geometry)
  outcome=$(observe_ro 2>&1) || rc=$?
  [ "$rc" = 2 ] && [[ $outcome == "rent-selection: UNKNOWN ("* ]] ||
    fail "observer accepted $expected or returned unexpected result"
  after=$(profile_geometry)
  [ "$before" = "$after" ] || fail "observation mutated $expected profile or store metadata"
}
sel=$(docker run --rm --network none -v "$nixvol:/nix:ro" "$image" /bin/readlink /nix/var/nix/profiles/rent-dev)
[[ $sel =~ ^rent-dev-[0-9]+-link$ ]] || fail 'invalid fixture preimage selection'
docker run --rm --network none -v "$nixvol:/nix" "$image" /bin/ln -sfn /tmp/foreign /nix/var/nix/profiles/rent-dev
assert_unknown_read_only 'foreign selected link'
docker run --rm --network none -v "$nixvol:/nix" "$image" /bin/ln -sfn "$sel" /nix/var/nix/profiles/rent-dev
docker run --rm --network none -v "$nixvol:/nix" "$image" /bin/ln -s /nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-foreign /nix/var/nix/profiles/rent-dev-999-link
assert_unknown_read_only 'invalid extra generation'
docker run --rm --network none -v "$nixvol:/nix" "$image" /bin/rm /nix/var/nix/profiles/rent-dev-999-link
docker run --rm --network none -v "$nixvol:/nix" "$image" /bin/ln -s /tmp/unfinished /nix/var/nix/profiles/.rent-dev.pending
assert_unknown_read_only 'interrupted profile selector'
docker run --rm --network none -v "$nixvol:/nix" "$image" /bin/rm /nix/var/nix/profiles/.rent-dev.pending
docker run --rm --network none -v "$nixvol:/nix" "$image" /bin/rm /nix/var/nix/profiles/rent-dev
assert_unknown_read_only 'orphan generations'
docker run --rm --network none -v "$nixvol:/nix" "$image" /bin/ln -s "$sel" /nix/var/nix/profiles/rent-dev
test "$(observe_ro)" = "selection=SELECTED generation=$sel store=$t1 proof=geometry-only" ||
  fail 'valid selector was not restored in disposable fixture'

# The B-only profileCheck also requires all three parent directories to be root-owned and not
# group/other writable. The observer must never call this geometry SELECTED/ABSENT when B refuses.
# Changes below touch only the disposable, stopped CI volume; all observations mount /nix read-only.
assert_base_refuses_unsafe() {
  local label=$1 before
  before=$(profile_geometry)
  if seed > "$evidence/seed" 2>&1; then fail "B-only seed accepted $label"; fi
  grep -qF 'foreign, invalid or incompatible retained generation' "$evidence/seed" ||
    fail "B-only seed refused $label for the wrong reason"
  if docker run --rm "${mount_args[@]}" "$image" > "$evidence/seed" 2>&1; then
    fail "B-only start accepted $label"
  fi
  grep -qF 'rent-profile: foreign, invalid or incompatible retained generation' "$evidence/seed" ||
    fail "B-only start refused $label for the wrong reason"
  [ "$(profile_geometry)" = "$before" ] || fail "B-only refusal wrote metadata for $label"
}
for spec in "var/nix/profiles 777" "var/nix 775" "var 777"; do
  read -r relative unsafe_mode <<< "$spec"
  before_mode=$(docker run --rm --network none -v "$nixvol:/nix:ro" "$image"     /bin/stat -c %a "/nix/$relative")
  docker run --rm --network none -v "$nixvol:/nix" "$image"     /bin/chmod "$unsafe_mode" "/nix/$relative"
  assert_unknown_read_only "selected parent $relative mode $unsafe_mode"
  if [ "$relative" = var/nix/profiles ]; then
    assert_base_refuses_unsafe 'SELECTED with world-writable profiles'
  fi
  docker run --rm --network none -v "$nixvol:/nix" "$image"     /bin/chmod "$before_mode" "/nix/$relative"
  test "$(observe_ro)" = "selection=SELECTED generation=$sel store=$t1 proof=geometry-only" ||
    fail "restored selected parent $relative was not observed"
done

# ABSENT is not safe merely because the active selector is missing: even with every generation
# removed, an unsafe parent directory could let an untrusted user install a malicious selector.
docker run --rm --network none -v "$nixvol:/nix" "$image" /bin/bash -euc '
  d=/nix/var/nix/profiles
  test -L "$d/rent-dev" && rm -- "$d/rent-dev"
  for g in "$d"/rent-dev-*-link; do test -L "$g"; rm -- "$g"; done'
test "$(observe_ro)" = 'selection=ABSENT proof=geometry-only' ||
  fail 'fixture did not reach a valid ABSENT state before permission change'
before_mode=$(docker run --rm --network none -v "$nixvol:/nix:ro" "$image"   /bin/stat -c %a /nix/var/nix/profiles)
docker run --rm --network none -v "$nixvol:/nix" "$image" /bin/chmod 777 /nix/var/nix/profiles
assert_unknown_read_only 'ABSENT with world-writable profiles'
assert_base_refuses_unsafe 'ABSENT with world-writable profiles'
docker run --rm --network none -v "$nixvol:/nix" "$image"   /bin/chmod "$before_mode" /nix/var/nix/profiles
test "$(observe_ro)" = 'selection=ABSENT proof=geometry-only' ||
  fail 'valid ABSENT was not restored after the isolated permission fixture'
echo 'PASS: SOURCE-only native T0->T1, rollback/GC/recreate, read-only observation and unsafe parent modes refused for SELECTED/ABSENT'
