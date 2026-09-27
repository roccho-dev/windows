#!/usr/bin/env bash
# Linux OCI proof only. Uses disposable resources, no credentials and no publication.
# Run from the repository root after nix build .#dev-image.
set -euo pipefail
image_archive=${1:?usage: proof.sh IMAGE_ARCHIVE}
apps_rev=cab6e3fce426af842c3e154fecb3660f2495e664
prefix="windows-dev-proof-$(date +%s)-$$"
core="$prefix-core"
nix_volume="$prefix-nix"
work_volume="$prefix-work"
evidence=$(mktemp -d)
cleanup() {
  code=$?
  if [ "$code" -ne 0 ]; then
    docker logs "$core" 2>/dev/null || true
    docker exec "$core" /bin/cat /tmp/apps-dev.log 2>/dev/null || true
  fi
  docker rm -f "$core" >/dev/null 2>&1 || true
  docker volume rm "$nix_volume" "$work_volume" >/dev/null 2>&1 || true
  rm -rf "$evidence"
  exit "$code"
}
trap cleanup EXIT

docker load < "$image_archive"
# Tags select the just-loaded artifact once; every subsequent run pins its immutable ID.
image=$(docker image inspect ghcr.io/roccho-dev/windows-dev:nix --format '{{.Id}}')
printf 'image %s\napps revision %s\n' "$image" "$apps_rev"
docker volume create "$nix_volume" >/dev/null
docker volume create "$work_volume" >/dev/null

# Same explicit Init pattern as win.ps1: no Docker auto-copy, daemon or host Nix store.
# A volume at /seed leaves the image's /nix visible for the one-time seed operation.
docker run --rm --network none --volume "$nix_volume:/seed" "$image" \
  /bin/bash --login -euc '
    test -z "$(ls -A /seed)"
    cp -a /nix/. /seed/
    printf "%s\n" "$1" > /seed/var/windows-seed-image
  ' seed "$image"

start() {
  docker run -d --name "$core" --network "$1" \
    --mount "type=volume,source=$nix_volume,target=/nix,volume-nocopy" \
    --mount "type=volume,source=$work_volume,target=/work/repos,volume-nocopy" \
    "$image" /bin/sleep infinity >/dev/null
  docker inspect "$core" --format '{{json .Mounts}}' | \
    jq -e 'length == 2 and ([.[].Destination] | sort) == ["/nix", "/work/repos"]' >/dev/null
}
inside() { docker exec "$core" /bin/bash --login -euc "$@"; }
serve() {
  docker exec -d "$core" /bin/bash --login -ec \
    "cd /work/repos/apps; exec nix run $1 --no-write-lock-file .#dev > /tmp/apps-dev.log 2>&1"
  for attempt in {1..180}; do
    if docker exec "$core" /bin/curl -fsS http://127.0.0.1:8787/ > "$evidence/page" 2>/dev/null; then
      grep -q 'windows-8-uncommitted-proof' "$evidence/page"
      return
    fi
    sleep 1
  done
  echo 'apps development endpoint did not become ready' >&2
  return 1
}

start bridge
inside '
  test "$HOME" = /home/dev
  test -r "$NIX_SSL_CERT_FILE"
  test "$(cat /nix/var/windows-seed-image)" = "$1"
  nix --version
  nix-store --verify --check-contents
  git init -q /work/repos/apps
  cd /work/repos/apps
  git remote add origin https://github.com/roccho-dev/apps
  git fetch -q --depth 1 origin "$2"
  git checkout -q --detach FETCH_HEAD
  test "$(git rev-parse HEAD)" = "$2"
  sha256sum flake.lock > /work/repos/lock.sha256
  printf "\n<!-- windows-8-uncommitted-proof -->\n" >> packages/voice-ui/web/index.html
  printf "untracked work\n" > /work/repos/apps/untracked-proof
  printf "discard this HOME\n" > "$HOME/disposable-proof"
  # Real apps build, not a canned hello or a nix --version success.
  nix build --no-write-lock-file .#voice-ui-dist --profile /nix/var/nix/profiles/apps-proof
  sha256sum -c /work/repos/lock.sha256
  readlink -f /nix/var/nix/profiles/windows-dev > /work/repos/dev-profile.txt
  git diff --binary > /work/repos/work.diff
' fresh "$image" "$apps_rev"
serve ''
cp "$evidence/page" "$evidence/before"
old_id=$(docker inspect "$core" --format '{{.Id}}')
echo 'PASS fresh -> develop (real apps build and HTTP response with uncommitted edit)'

docker rm -f "$core" >/dev/null
# No network on the successor: neither the old HOME nor a silent re-download can rescue it.
start none
test "$(docker inspect "$core" --format '{{.Id}}')" != "$old_id"
inside '
  test ! -e "$HOME/disposable-proof"
  test "$(cat /nix/var/windows-seed-image)" = "$1"
  test "$(readlink -f /nix/var/nix/profiles/windows-dev)" = "$(cat /work/repos/dev-profile.txt)"
  cd /work/repos/apps
  test "$(git rev-parse HEAD)" = "$2"
  test "$(cat untracked-proof)" = "untracked work"
  git diff --binary > /tmp/work.diff
  test "$(sha256sum < /work/repos/work.diff)" = "$(sha256sum < /tmp/work.diff)"
  sha256sum -c /work/repos/lock.sha256
  nix build --offline --no-write-lock-file .#voice-ui-dist --profile /nix/var/nix/profiles/apps-proof
' continue "$image" "$apps_rev"
serve '--offline'
cmp "$evidence/before" "$evidence/page"
inside '
  nix-store --gc
  test -x /nix/var/nix/profiles/windows-dev/bin/git
  nix --version
  nix-store --verify --check-contents
'
echo 'PASS replace -> continue (different container, retained work/store/profile, disposable HOME, offline apps)'
