#!/usr/bin/env bash
# CI-only rent Base/Tool compatibility. Docker volumes and credentials are synthetic and disposable.
# No WSLC, Cloudflare connection, current Host, or production profile mutation.
set -Eeuo pipefail
real_archive=$1 stub_archive=$2 legacy_archive=$3 next_archive=$4
p="rent-base-proof-$$"
c="$p-container" repos="$p-repos" state="$p-state" nixvol="$p-nix"
evidence=$(mktemp -d)
fail() { echo "rent base proof: $*" >&2; exit 1; }
cleanup() {
  status=$?
  trap - EXIT
  if [ "$status" -ne 0 ]; then docker logs "$c" 2>&1 | tail -n 30 || true; fi
  docker rm -f "$c" >/dev/null 2>&1 || true
  docker volume rm "$repos" "$state" "$nixvol" >/dev/null 2>&1 || true
  rm -f -- "$evidence/seed" "$evidence/guard" "$evidence/start"
  rmdir -- "$evidence" || status=1
  exit "$status"
}
trap cleanup EXIT
for archive in "$real_archive" "$stub_archive" "$legacy_archive" "$next_archive"; do
  docker load < "$archive" >/dev/null
done
real=$(docker image inspect ghcr.io/roccho-dev/windows-rent:base --format '{{.Id}}')
stub=$(docker image inspect ghcr.io/roccho-dev/windows-rent:base-stub --format '{{.Id}}')
legacy=$(docker image inspect ghcr.io/roccho-dev/windows-rent:stub --format '{{.Id}}')
next=$(docker image inspect ghcr.io/roccho-dev/windows-rent:next --format '{{.Id}}')
[ "$real" != "$legacy" ] && [ "$stub" != "$legacy" ] || fail 'new Base image is legacy'
for image in "$real" "$stub"; do
  test "$(docker image inspect "$image" --format '{{json .Config.Volumes}}')" = null
  docker run --rm --network none "$image" /bin/bash -euc '
    test -x /bin/nix && test -x /bin/gh
    test -L /bin/codex && test ! -e /bin/codex
    test -L /bin/claude && test ! -e /bin/claude
    test ! -e /nix/var/nix/profiles/rent-dev
    test ! -L /nix/var/nix/profiles/rent-dev
    test -L /etc/rent-nix-roots
  ' || fail 'Base contains a preselected Tool or lacks administration binaries'
done
for v in "$repos" "$state" "$nixvol"; do docker volume create "$v" >/dev/null; done
docker run --rm --network none -v "$state:/s" "$stub" /bin/bash -euc '
  install -d -m 700 -o 0 -g 0 /s/cloudflared
  printf "ci-synthetic-token\n" > /s/cloudflared/token
  chmod 600 /s/cloudflared/token'
docker run --rm --network none -v "$repos:/r" "$stub" /bin/bash -euc 'printf "unchanged\n" > /r/proof-marker'
seed() {
  docker run --rm --network none -v "$nixvol:/seed" -e "RENT_NIX_VOLUME=$nixvol" "$1" /bin/rent-nix-seed
}
selected() {
  docker run --rm --network none -v "$nixvol:/n:ro" "$stub" \
    /bin/readlink /n/var/nix/profiles/rent-dev
}
nixmount="type=volume,source=$nixvol,target=/nix,volume-nocopy"
start_args=(--network none -v "$repos:/work/repos" -v "$state:/var/lib/rent"
  --mount "$nixmount" -e "RENT_REPOS_VOLUME=$repos"
  -e "RENT_STATE_VOLUME=$state" -e "RENT_NIX_VOLUME=$nixvol"
  -e 'RENT_AUTHORIZED_KEY=ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHJlbnQtZGV2LXByb29mLW5vdC1hLXJlYWwta2V5 ci')
run_start() {
  docker run -d --name "$c" "${start_args[@]}" "$stub" >/dev/null
  ready=0
  for i in {1..75}; do
    if docker logs "$c" 2>&1 | grep -qF 'rent-start ok services=nix-daemon,cloudflared,sshd' &&
       docker exec "$c" /bin/test -S /nix/var/nix/daemon-socket/socket >/dev/null 2>&1; then
      ready=1; break
    fi
    [ "$(docker inspect "$c" --format '{{.State.Running}}')" = true ] || break
    sleep 1
  done
  [ "$ready" = 1 ] || fail 'B-only rent-start did not become service-ready'
}
stop_start() {
  docker stop -t 30 "$c" >/dev/null
  docker rm "$c" >/dev/null
}
# B-only seed never selects T, and first boot distinguishes BaseReady from ToolReady.
seed "$stub" > "$evidence/seed"
docker run --rm --network none -v "$nixvol:/n:ro" "$stub" /bin/bash -euc '
  test -e /n/var/rent-nix
  test ! -e /n/var/nix/profiles/rent-dev && test ! -L /n/var/nix/profiles/rent-dev'
run_start
docker logs "$c" 2>&1 | grep -qF 'rent-profile: base-admin-ready apps=absent auth=unverified'
docker logs "$c" 2>&1 | grep -qF 'profile=absent'
docker exec "$c" /bin/bash -euc 'test ! -e /nix/var/nix/profiles/rent-dev; test ! -L /nix/var/nix/profiles/rent-dev'
stop_start

# Seed a real existing legacy rent-dev generation, then let Base seed/restart without resetting it.
seed "$legacy" > "$evidence/seed"
old=$(selected)
[ -n "$old" ] || fail 'legacy profile not selected'
seed "$stub" > "$evidence/seed"
[ "$(selected)" = "$old" ] || fail 'Base seed reset the legacy generation'
run_start
[ "$(docker exec "$c" /bin/readlink /nix/var/nix/profiles/rent-dev)" = "$old" ] || fail 'Base start reset T'
docker exec "$c" /bin/bash -euc '
  test "$(cat /work/repos/proof-marker)" = unchanged
  test "$(readlink -e /bin/codex)" = "$(readlink -e /nix/var/nix/profiles/rent-dev/bin/codex)"
  /bin/codex --version | grep -q "^codex-cli "
  /bin/claude --version >/dev/null
  /bin/python3 --version >/dev/null
  /bin/uv --version >/dev/null
' || fail 'retained Tool is not actually executable'
stop_start

# A later valid generation is also retained: Base neither creates nor rolls back generations.
seed "$next" > "$evidence/seed"
new=$(selected)
[ -n "$new" ] && [ "$new" != "$old" ] || fail 'the newer generation was not selected'
seed "$stub" > "$evidence/seed"
[ "$(selected)" = "$new" ] || fail 'Base reseed overwrote selected T'
run_start
docker exec "$c" /bin/bash -euc '
  test -x /nix/var/nix/profiles/rent-dev/bin/hello
  /nix/var/nix/profiles/rent-dev/bin/hello >/dev/null
' || fail 'later selected Tool is not executable'
stop_start

# Refusal must not alter Nix metadata, generations or GC roots; snapshots use only this disposable volume.
snapshot() {
  docker run --rm --network none -v "$nixvol:/n:ro" "$stub" /bin/bash -euc '
    cd /n
    find var/nix/profiles var/nix/gcroots -printf "%p|%y|%l|%s|%T@\n" | LC_ALL=C sort
    sha256sum var/rent-nix var/nix/db/db.sqlite
  ' | sha256sum
}
refuse() {
  label=$1
  before=$(snapshot)
  if seed "$stub" > "$evidence/guard" 2>&1; then fail "seed accepted $label"; fi
  grep -qF 'foreign, invalid or incompatible retained generation' "$evidence/guard" ||
    fail "wrong seed refusal for $label"
  if docker run --rm "${start_args[@]}" "$stub" > "$evidence/start" 2>&1; then
    fail "start accepted $label"
  fi
  grep -qF 'rent-profile: foreign, invalid or incompatible retained generation' "$evidence/start" ||
    fail "wrong start refusal for $label"
  [ "$(snapshot)" = "$before" ] || fail "seed/start wrote Nix metadata while refusing $label"
}
docker run --rm --network none -v "$nixvol:/n" "$stub" /bin/ln -sfn /tmp/foreign /n/var/nix/profiles/rent-dev
refuse 'foreign selected target'
docker run --rm --network none -v "$nixvol:/n" -e "SELECTED=$new" "$stub" \
  /bin/bash -euc 'ln -sfn "$SELECTED" /n/var/nix/profiles/rent-dev'
docker run --rm --network none -v "$nixvol:/n" "$stub" \
  /bin/ln -s rent-dev-999-link /n/var/nix/profiles/.rent-dev.new
refuse 'interrupted selector'
docker run --rm --network none -v "$nixvol:/n" "$stub" /bin/rm /n/var/nix/profiles/.rent-dev.new
docker run --rm --network none -v "$nixvol:/n" "$stub" \
  /bin/ln -s /nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-foreign /n/var/nix/profiles/rent-dev-999-link
refuse 'broken foreign generation'
docker run --rm --network none -v "$nixvol:/n" "$stub" /bin/rm /n/var/nix/profiles/rent-dev-999-link
test "$(selected)" = "$new" || fail 'refused attempts changed T'
seed "$stub" > "$evidence/seed"
test "$(selected)" = "$new" || fail 'valid Base seed changed T after refusals'
echo 'PASS B-only rent build/load/start, B-ready, legacy T, next T, unchanged selection and fail-closed geometry'
