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

# Local real-Jev prerequisite (roccho-dev/adrs#460). Fixtures only: throwaway identities, a fixture key, local git
# remotes and a stub app; no credential, no real Jev and no provider effect. It proves the production tools and a
# fixture instance of the same source, built here and never linked into the profile.
jev_proof() {
  local nx=(nix --extra-experimental-features 'nix-command flakes')
  local fx="$evidence/jev" pkgs='import (builtins.getFlake (toString ./.)).inputs.nixpkgs { system = "x86_64-linux"; }'
  mkdir "$fx"

  # Production: exactly the two bounded tools on the profile, the three real constants, no raw crypto binary.
  local profile prod_launch prod_init
  profile=$("${nx[@]}" build --no-link --print-out-paths --no-write-lock-file .#dev-profile)
  prod_launch=$(readlink -f "$profile/bin/voice-ui-jev-dev")
  prod_init=$(readlink -f "$profile/bin/jev-age-init")
  for raw in sops age age-keygen; do test ! -e "$profile/bin/$raw"; done
  grep -qxF "envs_remote=https://github.com/roccho-dev/envs" "$prod_launch"
  grep -qxF "apps_remote=https://github.com/roccho-dev/apps" "$prod_launch"
  grep -qxF "identity=/work/repos/.auth/roccho-dev/age/oci-dev.key" "$prod_launch"
  grep -qxF "identity=/work/repos/.auth/roccho-dev/age/oci-dev.key" "$prod_init"
  if grep -qE '^[[:space:]]*set -(x|o xtrace)' "$prod_launch" "$prod_init"; then echo 'a jev tool enables xtrace' >&2; return 1; fi

  # Fixture instance: the same source with only the three constants changed.
  local tools launch init
  tools="(import ./oci/dev/nix.nix { pkgs = $pkgs; }).jevTools {
    envsRemote = \"file://$fx/envs\"; appsRemote = \"file://$fx/apps\"; identity = \"$fx/age/oci-dev.key\"; }"
  launch=$("${nx[@]}" build --impure --no-link --print-out-paths --expr "($tools).launch")/bin/voice-ui-jev-dev
  init=$("${nx[@]}" build --impure --no-link --print-out-paths --expr "($tools).init")/bin/jev-age-init
  same() { grep -vE '^(envs_remote|apps_remote|identity)=' "$1" | sha256sum; }
  test "$(same "$launch")" = "$(same "$prod_launch")"
  test "$(same "$init")" = "$(same "$prod_init")"
  test "$launch" != "$prod_launch"
  test "$init" != "$prod_init"

  # jev-age-init: refuses an unsafe parent and any overwrite, writes 0600, prints only the public recipient.
  local recipient other
  mkdir "$fx/age"
  chmod 0777 "$fx/age"
  if "$init" > /dev/null 2>&1; then echo 'jev-age-init accepted a world-writable directory' >&2; return 1; fi
  test ! -e "$fx/age/oci-dev.key"
  chmod 0700 "$fx/age"
  recipient=$("$init")
  [[ $recipient =~ ^age1[0-9a-z]{58}$ ]]
  test "$(stat -c %a "$fx/age/oci-dev.key")" = 600
  test "$(ls -A "$fx/age")" = oci-dev.key
  if "$init" > /dev/null 2>&1; then echo 'jev-age-init overwrote the identity' >&2; return 1; fi
  if "$init" --force > /dev/null 2>&1; then echo 'jev-age-init accepted an argument' >&2; return 1; fi

  # Fixture envs remote: a stale ancestor, the current ciphertext on proposals, and a commit off proposals.
  local key sops cipher stale good off
  key="fixture-jev-$RANDOM$RANDOM$RANDOM"
  sops=$("${nx[@]}" build --impure --no-link --print-out-paths --expr "($pkgs).sops")/bin/sops
  g() { git -c user.name=proof -c user.email=proof@invalid "$@"; }
  commit() {
    g -C "$fx/envs" add -A
    g -C "$fx/envs" commit -q -m "$1"
    g -C "$fx/envs" rev-parse HEAD
  }
  encrypt() {
    printf '{"JEV_API_KEY":"%s"}\n' "$key" \
      | SOPS_AGE_RECIPIENTS="$1" "$sops" --encrypt --input-type json --output-type yaml /dev/stdin
  }
  g init -q -b proposals "$fx/envs"
  mkdir "$fx/envs/ciphertexts"
  cipher="$fx/envs/ciphertexts/dev-jev-api.oci-dev.sops.yaml"
  encrypt "$recipient" > "$cipher"; stale=$(commit stale)
  encrypt "$recipient" > "$cipher"; good=$(commit current)
  g -C "$fx/envs" checkout -q -b side "$stale"; printf 'side\n' > "$fx/envs/side"; off=$(commit side)
  g -C "$fx/envs" checkout -q proposals

  # Fixture apps remote: a stub dev program that records only names, flags and digests, and one that cannot build.
  local nixpkgs_src flake apps_good apps_bad
  nixpkgs_src=$("${nx[@]}" eval --impure --raw --expr '(builtins.getFlake (toString ./.)).inputs.nixpkgs.outPath')
  flake=$(cat <<'NIX'
{
  inputs.nixpkgs.url = "path:NIXPKGS";
  outputs = { nixpkgs, ... }: {
    apps.x86_64-linux.dev = {
      type = "app";
      program = "${nixpkgs.legacyPackages.x86_64-linux.writeShellScript "voice-ui-jev-proof-stub" ''
        {
          echo "names $(tr '\0' '\n' < /proc/$$/environ | cut -d= -f1 | sort | tr '\n' ' ')"
          echo "host $HOST"
          echo "core $(ulimit -c)"
          echo "home $HOME $([ -e "$HOME" ] && echo present || echo absent)"
          echo "key $(printf %s "$JEV_API_KEY" | sha256sum | cut -d' ' -f1)"
          case "$(tr '\0' ' ' < /proc/$$/cmdline)" in *"$JEV_API_KEY"*) echo "argv key" ;; *) echo "argv clean" ;; esac
        } > /tmp/voice-ui-jev-proof-$PORT
      ''}";
    };
  };
}
NIX
)
  g init -q -b work "$fx/apps"
  printf '%s\n' "${flake//NIXPKGS/$nixpkgs_src}" > "$fx/apps/flake.nix"
  g -C "$fx/apps" add flake.nix
  (cd "$fx/apps" && "${nx[@]}" flake lock)
  g -C "$fx/apps" add -A
  g -C "$fx/apps" commit -q -m stub
  apps_good=$(g -C "$fx/apps" rev-parse HEAD)
  printf '{ outputs = _: throw "no dev program"; }\n' > "$fx/apps/flake.nix"
  g -C "$fx/apps" add -A
  g -C "$fx/apps" commit -q -m broken
  apps_bad=$(g -C "$fx/apps" rev-parse HEAD)

  # Every launch runs with a hostile parent environment; no outcome may print the key.
  local port marker out="$fx/launch.out"
  port=$((20000 + RANDOM % 20000))
  marker=/tmp/voice-ui-jev-proof-$port
  mkdir "$fx/tmp"
  launch_as() {
    local expect=$1 code=0
    shift
    rm -f "$marker"
    env TMPDIR="$fx/tmp" GH_TOKEN=fixture-gh GH_CONFIG_DIR=/nonexistent SOPS_AGE_KEY_FILE=/nonexistent HOST=0.0.0.0 SHELLOPTS=xtrace \
      'BASH_FUNC_leak%%=() { :; }' 'NOT-AN-IDENTIFIER=leak' "$launch" "$@" > "$out" 2>&1 || code=$?
    if grep -qF "$key" "$out"; then echo 'the key reached launcher output' >&2; return 1; fi
    if [ "$expect" = pass ]; then [ "$code" -eq 0 ] && [ -e "$marker" ]; else [ "$code" -ne 0 ] && [ ! -e "$marker" ]; fi \
      || { cat "$out" >&2; echo "voice-ui-jev-dev: expected $expect, exit $code: $*" >&2; return 1; }
  }
  local args=(--envs-sha "$good" --apps-sha "$apps_good" --port "$port")

  launch_as pass "${args[@]}"
  test "$(head -n 1 "$marker")" = "names HOME HOST JEV_API_KEY LANG PATH PORT "
  grep -qx 'host 127.0.0.1' "$marker"
  grep -qx 'core 0' "$marker"
  grep -qx 'home /homeless-shelter absent' "$marker"
  grep -qx "key $(printf %s "$key" | sha256sum | cut -d' ' -f1)" "$marker"
  grep -qx 'argv clean' "$marker"
  test "$(grep -n 'voice-ui-jev-dev: built ' "$out" | cut -d: -f1)" -lt "$(grep -n 'voice-ui-jev-dev: decrypt ' "$out" | cut -d: -f1)"

  # Arguments: exactly three flags, exact SHAs, an unprivileged port.
  launch_as red --envs-sha "$good" --apps-sha "$apps_good"
  launch_as red "${args[@]}" --port "$port"
  launch_as red --envs-sha "${good^^}" --apps-sha "$apps_good" --port "$port"
  launch_as red --envs-sha "$good" --apps-sha "$apps_good" --port 80
  launch_as red --envs-sha "$good" --apps-sha "$apps_good" --port 70000
  # The envs commit: stale ancestor, off proposals, or unknown.
  launch_as red --envs-sha "$stale" --apps-sha "$apps_good" --port "$port"
  launch_as red --envs-sha "$off" --apps-sha "$apps_good" --port "$port"
  launch_as red --envs-sha "$(printf unknown | sha256sum | cut -c1-40)" --apps-sha "$apps_good" --port "$port"
  # An apps program that cannot be built stops before anything is decrypted.
  launch_as red --envs-sha "$good" --apps-sha "$apps_bad" --port "$port"
  if grep -q 'voice-ui-jev-dev: decrypt' "$out"; then echo 'decrypted before the apps program was built' >&2; return 1; fi
  # The identity: wrong mode, missing, or another identity.
  chmod 0644 "$fx/age/oci-dev.key"; launch_as red "${args[@]}"; chmod 0600 "$fx/age/oci-dev.key"
  mv "$fx/age/oci-dev.key" "$fx/age/kept"; launch_as red "${args[@]}"
  other=$("$init"); launch_as red "${args[@]}"
  rm -f "$fx/age/oci-dev.key"; mv "$fx/age/kept" "$fx/age/oci-dev.key"
  # The ciphertext on proposals: tampered, two recipients, an extra field, or absent.
  local text head rest tampered two extra absent
  text=$(cat "$cipher"); head=${text%%"ENC[AES256_GCM,data:"*}; rest=${text#*"ENC[AES256_GCM,data:"}
  printf '%sENC[AES256_GCM,data:%s%s\n' "$head" "$([ "${rest:0:1}" = A ] && echo B || echo A)" "${rest:1}" > "$cipher"
  tampered=$(commit tampered)
  launch_as red --envs-sha "$tampered" --apps-sha "$apps_good" --port "$port"
  encrypt "$recipient,$other" > "$cipher"; two=$(commit two-recipients)
  launch_as red --envs-sha "$two" --apps-sha "$apps_good" --port "$port"
  encrypt "$recipient" > "$cipher"; printf 'note: plain\n' >> "$cipher"; extra=$(commit extra-field)
  launch_as red --envs-sha "$extra" --apps-sha "$apps_good" --port "$port"
  rm -f "$cipher"; absent=$(commit absent)
  launch_as red --envs-sha "$absent" --apps-sha "$apps_good" --port "$port"
  test -z "$(ls -A "$fx/tmp")"
  rm -f "$marker"
  echo 'PASS jev tools (fixtures): production profile has only the two bounded tools and exact constants; same source;'
  echo 'PASS jev launch: closed child environment, loopback, no core, absent HOME, no temp left after any launch, key never in argv or output, build before decrypt;'
  echo 'PASS jev RED: arguments, stale/off/unknown envs commit, unbuildable apps, identity mode/missing/other, tamper, two recipients, extra field, absent'
}
jev_proof

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
