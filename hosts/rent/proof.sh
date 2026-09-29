#!/usr/bin/env bash
# Linux OCI proof of the rent dev runtime (Issue #8-A): fresh seed -> develop -> replace with an upgraded image ->
# continue offline -> GC -> roll back and reseed from the retained volume. Disposable resources, synthetic state only,
# no credentials and no publication. Run from the repository root after
# nix build .#rent-image .#rent-image-next (result and result-1).
set -euo pipefail
base_archive=${1:?usage: proof.sh RENT_IMAGE RENT_IMAGE_NEXT}
next_archive=${2:?usage: proof.sh RENT_IMAGE RENT_IMAGE_NEXT}
# A real repository, its real packer and check: this repository at the merged #17 commit.
repo=https://github.com/roccho-dev/windows
repo_rev=4712d1eb8959de4e24775dc3c33ca7d614637177
p="rent-dev-proof-$$"
c=$p
repos=$p-repos state=$p-state nixv=$p-nix empty=$p-empty
evidence=$(mktemp -d)
cleanup() {
  code=$?
  if [ "$code" -ne 0 ]; then docker logs "$c" 2>&1 | tail -n 60 || true; fi
  docker rm -f "$c" >/dev/null 2>&1 || true
  docker volume rm "$repos" "$state" "$nixv" "$empty" >/dev/null 2>&1 || true
  rm -rf "$evidence"
  exit "$code"
}
trap cleanup EXIT
fail() { echo "FAIL $*" >&2; exit 1; }

docker load < "$base_archive" >/dev/null
docker load < "$next_archive" >/dev/null
# Tags select the just-loaded artifacts once; every run below pins the immutable IDs.
base=$(docker image inspect ghcr.io/roccho-dev/windows-rent:nix --format '{{.Id}}')
next=$(docker image inspect ghcr.io/roccho-dev/windows-rent:next --format '{{.Id}}')
roots() { docker run --rm "$1" /bin/readlink /etc/rent-nix-roots; }
base_roots=$(roots "$base") next_roots=$(roots "$next")
[ "$base_roots" != "$next_roots" ] || fail 'the upgrade image has the same runtime closure'
printf 'image %s\nimage-next %s\nrepo revision %s\n' "$base" "$next" "$repo_rev"
for v in "$repos" "$state" "$nixv" "$empty"; do docker volume create "$v" >/dev/null; done

# The counterexample: an empty volume at /nix shadows the image store, so the image cannot even start, and it writes
# nothing (volume-nocopy: no Docker auto-copy stands in for seeding).
nixmount() { echo "type=volume,source=$1,target=/nix,volume-nocopy"; }
if docker run --rm --mount "$(nixmount "$empty")" "$base" > "$evidence/empty" 2>&1; then fail 'started on an empty /nix'; fi
if grep -qF 'rent-mounts ok' "$evidence/empty"; then fail 'gate passed on an empty /nix'; fi
test -z "$(docker run --rm -v "$empty:/e" "$base" /bin/ls -A /e)" || fail 'an empty /nix was written'

# Seed refusals, before any write.
seed() {
  test -z "$(docker ps -aq --filter "volume=$nixv")" || fail 'seed while a container uses the nix volume'
  docker run --rm --network none -v "$nixv:/seed" -e "RENT_NIX_VOLUME=$nixv" "$1" /bin/rent-nix-seed
}
seed_refused() {
  local want=$1; shift
  if docker run --rm --network none "$@" "$base" /bin/rent-nix-seed > "$evidence/seed" 2>&1; then fail "seeded despite: $want"; fi
  grep -qF "$want" "$evidence/seed" || { cat "$evidence/seed" >&2; fail "wrong refusal for: $want"; }
}
seed_refused 'set RENT_NIX_VOLUME' -v "$nixv:/seed"
seed_refused "/seed must be exactly volume $nixv, rw" -v "$nixv:/seed:ro" -e "RENT_NIX_VOLUME=$nixv"
seed_refused "/seed must be exactly volume $empty, rw" -v "$nixv:/seed" -e "RENT_NIX_VOLUME=$empty"
seed_refused 'exactly one volume is allowed' -v "$nixv:/seed" -v "$empty:/extra" -e "RENT_NIX_VOLUME=$nixv"
docker run --rm -v "$repos:/r" "$base" /bin/bash -c 'echo repo > /r/marker'
seed_refused '/seed is neither empty nor a rent /nix volume' -v "$repos:/seed" -e "RENT_NIX_VOLUME=$repos"
test -z "$(docker run --rm -v "$nixv:/n" "$base" /bin/ls -A /n)" || fail 'a refused seed wrote'

# Fresh seed: store, DB, profile and GC root together; an identical rerun copies nothing.
seed "$base" | tee "$evidence/seed1"
grep -qE "^rent-nix-seed ok volume=$nixv roots=$base_roots copied=[1-9][0-9]*$" "$evidence/seed1" || fail 'fresh seed'
seed "$base" | grep -qxF "rent-nix-seed ok volume=$nixv roots=$base_roots copied=0" || fail 'reseed was not a no-op'
# A partial seed (GC root, the last step, missing) is refused by rent-start, and a rerun completes it.
docker run --rm -v "$nixv:/seed" "$base" /bin/rm "/seed/var/nix/gcroots/rent/${base_roots##*/}"
if docker run --rm --name "$c" -v "$repos:/work/repos" -v "$state:/var/lib/rent" --mount "$(nixmount "$nixv")" \
  -e "RENT_REPOS_VOLUME=$repos" -e "RENT_STATE_VOLUME=$state" -e "RENT_NIX_VOLUME=$nixv" "$base" > "$evidence/partial" 2>&1; then
  fail 'started on a partial seed'
fi
grep -qF "rent-nix: this image is not seeded into $nixv" "$evidence/partial" || fail 'partial seed not refused'
seed "$base" | grep -qxF "rent-nix-seed ok volume=$nixv roots=$base_roots copied=0" || fail 'completing a partial seed'
echo 'PASS seed (empty /nix cannot start; refusals write nothing; fresh, idempotent and partial-complete seed)'

start() {
  docker run -d --name "$c" --network "$2" -v "$repos:/work/repos" -v "$state:/var/lib/rent" --mount "$(nixmount "$nixv")" \
    -e "RENT_REPOS_VOLUME=$repos" -e "RENT_STATE_VOLUME=$state" -e "RENT_NIX_VOLUME=$nixv" \
    -e RENT_TS_HOSTNAME=rent-dev-proof -e 'RENT_AUTHORIZED_KEY=ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHJlbnQtZGV2LXByb29mLW5vdC1hLXJlYWwta2V5 proof' \
    "$1" >/dev/null
  for _ in {1..60}; do
    if docker logs "$c" 2>&1 | grep -q '^rent-nix ok ' && docker exec "$c" /bin/test -S /nix/var/nix/daemon-socket/socket 2>/dev/null; then
      return 0
    fi
    sleep 1
  done
  fail "rent-start did not become ready on $1"
}
# The development user, with the environment its SSH sessions get from sshd SetEnv.
dev() {
  docker exec -u 1000:1000 -w /work/repos/proof -e NIX_REMOTE=daemon -e NIX_SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt \
    "$c" /bin/bash -euc "$@"
}
root() { docker exec "$c" /bin/bash -euc "$@"; }
boundaries() {
  root "$(cat <<'EOF'
awk '$5 == "/work/repos" { r++ } $5 == "/var/lib/rent" { s++ } $5 == "/nix" { n++ } $5 == "/home/dev" { h++ } $4 ~ /\/volumes\/.*\/_data$/ { v++ }
  END { exit !(r == 1 && s == 1 && n == 1 && h == 0 && v == 3) }' /proc/1/mountinfo
test "$(stat -c '%a %u %g' /nix/store)" = '1775 0 30000'
test "$(stat -c %u /nix/var/nix/profiles/rent-dev)" = 0
test "$(cat /work/repos/marker)" = repo
EOF
)"
  dev 'if touch /nix/store/dev-write 2>/dev/null || ln -sfn /tmp /nix/var/nix/profiles/rent-dev 2>/dev/null; then exit 1; fi'
}
# Build the real distribution and the repository's own check from the uncommitted tree. The evidence is the real
# packer's output: its checksum verifies, and packages.dsc.json and manifest.json inside the archive carry each
# edited package version. $1: extra nix options; the rest: versions that must appear.
build() {
  dev 'opts=$1; shift
    cd repo
    nix build $opts --no-write-lock-file .#windows-dist .#checks.x86_64-linux.windows-dist --out-link ../dist
    cd ../dist && sha256sum -c --strict --quiet windows-dist.zip.sha256
    for f in packages.dsc.json manifest.json; do
      nix shell $opts --inputs-from ../repo nixpkgs#unzip -c unzip -p windows-dist.zip "$f" > "/tmp/$f"
      for v in "$@"; do grep -qF "\"version\": \"$v\"" "/tmp/$f"; done
    done' _ "$@"
}

# Fresh -> develop, as the dev user through the daemon: a real clone, an uncommitted selection change, the real packer
# and the repository's check building it.
start "$base" bridge
first=$(docker inspect "$c" --format '{{.Id}}')
root 'install -d -o 1000 -g 1000 /work/repos/proof'
boundaries
dev 'test "$(readlink -f "$(command -v nix)")" = "$(readlink -f /nix/var/nix/profiles/rent-dev/bin/nix)"
  test "$(readlink /nix/var/nix/profiles/rent-dev)" = rent-dev-1-link
  if command -v hello >/dev/null; then exit 1; fi
  nix --version
  git init -q repo && cd repo
  git remote add origin '"$repo"'
  git fetch -q --depth 1 origin '"$repo_rev"'
  git checkout -q --detach FETCH_HEAD
  test "$(git rev-parse HEAD)" = '"$repo_rev"'
  # A real selection change: the AutoHotkey version the Windows packer ships; the committed tree does not have it.
  sed -i "s/\"2\.0\.28\"/\"2.0.28-rent-fresh\"/" hosts/common/nix.nix
  test "$(git diff --numstat)" = "$(printf "1\t1\thosts/common/nix.nix")"
  if git grep -q rent-fresh HEAD; then exit 1; fi
  printf "untracked work\n" > untracked-proof
  mkdir -p ~/.codex ~/.claude
  echo codex-session > ~/.codex/proof && echo claude-session > ~/.claude/proof
  echo disposable > ~/home-proof'
build '' 2.0.28-rent-fresh
dev 'cd repo; git diff --binary | sha256sum > ../work.diff.sha256; readlink ../dist > ../dist.path; cat ../dist.path'
echo 'PASS fresh -> develop (real clone; the real packer ships the uncommitted edit; the repo check passes; via the daemon)'

# Replace with the upgraded image: stop, remove the container only, seed the new closure while nothing runs, start.
docker stop -t 30 "$c" >/dev/null
test "$(docker inspect --format '{{.State.ExitCode}}' "$c")" = 143 || fail 'TERM did not reach rent-start'
docker rm "$c" >/dev/null
seed "$next" | grep -qE "^rent-nix-seed ok volume=$nixv roots=$next_roots copied=[1-9][0-9]*$" || fail 'upgrade seed'
# No network on the successor: neither the old HOME nor a silent download can rescue it.
start "$next" none
test "$(docker inspect "$c" --format '{{.Id}}')" != "$first" || fail 'not a new container'
boundaries
dev 'test ! -e ~/home-proof
  test "$(cat ~/.codex/proof)" = codex-session && test "$(cat ~/.claude/proof)" = claude-session
  hello > /dev/null
  test "$(readlink /nix/var/nix/profiles/rent-dev)" = rent-dev-2-link
  test -L /nix/var/nix/profiles/rent-dev-1-link
  cd repo
  test "$(git rev-parse HEAD)" = '"$repo_rev"'
  test "$(cat untracked-proof)" = "untracked work"
  git diff --binary | sha256sum | cmp - ../work.diff.sha256
  test "$(readlink ../dist)" = "$(cat ../dist.path)" && test -e ../dist/windows-dist.zip
  sed -i "s/\"154\.0\.8037\.58\"/\"154.0.8037.58-rent-continued\"/" hosts/common/nix.nix
  git diff --binary | sha256sum > ../work2.diff.sha256'
build --offline 2.0.28-rent-fresh 154.0.8037.58-rent-continued
for r in "$base_roots" "$next_roots"; do test "$(root "readlink /nix/var/nix/gcroots/rent/${r##*/}")" = "$r"; done
echo 'PASS replace -> continue (upgraded image, retained auth/session/work/store/profile, disposable HOME, offline rebuild with both edits)'

# GC keeps every seeded runtime, the profile generations and the developer's out-link; the store verifies.
root 'NIX_REMOTE=daemon nix-store --gc > /dev/null
  for r in '"$base_roots $next_roots"'; do nix-store --check-validity "$r" $(cat "$r"); done
  nix-store --check-validity "$(readlink -f /nix/var/nix/profiles/rent-dev-1-link)" "$(readlink -f /nix/var/nix/profiles/rent-dev-2-link)" \
    "$(readlink /work/repos/proof/dist)" "$(readlink /work/repos/proof/dist-1)"
  nix-store --verify --check-contents'
echo 'PASS gc (seeded runtimes, profile generations and work roots survive; store verifies)'

# Roll back: the old image starts on the retained volume without reseeding and restores its own profile; reseeding it
# from the same definition is a no-op.
docker stop -t 30 "$c" >/dev/null && docker rm "$c" >/dev/null
seed "$base" | grep -qxF "rent-nix-seed ok volume=$nixv roots=$base_roots copied=0" || fail 'reseed of the retained volume'
start "$base" none
boundaries
dev 'if command -v hello >/dev/null; then exit 1; fi
  test "$(readlink /nix/var/nix/profiles/rent-dev)" = rent-dev-3-link
  test "$(readlink /nix/var/nix/profiles/rent-dev-3-link)" = "$(readlink /nix/var/nix/profiles/rent-dev-1-link)"
  test "$(cat ~/.codex/proof)" = codex-session
  cd repo && test "$(cat untracked-proof)" = "untracked work"
  git diff --binary | sha256sum | cmp - ../work2.diff.sha256
  nix-store --check-validity "$(readlink ../dist)" "$(readlink ../dist-1)"'
echo 'PASS rollback (old image on the retained volume, its own profile, retained work and results)'
