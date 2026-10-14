#!/usr/bin/env bash
# Disposable SOURCE proof for the fixed rent B-only OCI, not a live update controller.
# CI alone owns the quiet window. Target version/admission, real credentials and WSLC are outside this proof.
set -Eeuo pipefail
[ "$#" = 3 ] || { echo 'usage: native-proof.sh BASE_STUB_ARCHIVE T0_STORE_PATH T1_STORE_PATH' >&2; exit 2; }
archive=$1 t0=$2 t1=$3
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
  docker run --rm --network none -v "$nixvol:/nix:ro" "$image" /bin/bash -s < hosts/rent/read-selected.sh
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
native_set "$t0"
selection "$t0"
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
    find var/nix/profiles var/nix/gcroots -printf "%p|%y|%l|%s|%T@\\n" | LC_ALL=C sort
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
echo 'PASS: SOURCE-only native T0->T1, rollback/GC/recreate, read-only observation and damaged-state refusal'
