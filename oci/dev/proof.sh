#!/usr/bin/env bash
# Linux OCI proof only. Uses disposable resources, no credentials and no publication.
# Run from the repository root after nix build .#dev-image. With --jev-only it runs only the fixture Jev proof below
# and needs neither the image nor Docker; the full proof in CI always runs it first.
set -euo pipefail
mode=full
if [ "${1:-}" = --jev-only ] && [ "$#" -eq 1 ]; then mode=jev; else image_archive=${1:?usage: proof.sh IMAGE_ARCHIVE | --jev-only}; fi
apps_rev=cab6e3fce426af842c3e154fecb3660f2495e664
prefix="windows-dev-proof-$(date +%s)-$$"
core="$prefix-core"
nix_volume="$prefix-nix"
work_volume="$prefix-work"
evidence=$(mktemp -d)
# Cleanup removes only what this proof created, one entry at a time, never recursively: a regular file at a known name,
# an empty directory, and a fixture Git object whose content Git verifies against its own name. Any other type or
# content is kept and the cleanup fails.
plain() {
  if [ -L "$1" ] || { [ -e "$1" ] && [ ! -f "$1" ]; }; then echo "kept unexpected entry $1" >&2; return 1; fi
  rm -f -- "$1"
}
empty() {
  if [ -e "$1" ] || [ -L "$1" ]; then rmdir -- "$1" || { echo "kept non-empty or unexpected $1" >&2; return 1; }; fi
}
# A fixture repository made with --template=, without reflogs or automatic GC, so .git holds only these names.
git_clear() {
  local g=$1/.git f o t
  for f in "$g"/objects/[0-9a-f][0-9a-f]/*; do
    [ -e "$f" ] || [ -L "$f" ] || continue
    o=${f#"$g"/objects/}; o=${o%%/*}${o#*/}
    if ! [[ $o =~ ^[0-9a-f]{40}$ ]] || [ -L "$f" ] || [ ! -f "$f" ]; then echo "kept unexpected object entry $f" >&2; return 1; fi
    t=$(git -C "$1" cat-file -t "$o" 2>/dev/null) || { echo "kept unreadable object $f" >&2; return 1; }
    [ "$(git -C "$1" cat-file "$t" "$o" | git hash-object -t "$t" --stdin)" = "$o" ] \
      || { echo "kept object whose content differs from its name $f" >&2; return 1; }
    rm -f -- "$f"
  done
  for f in HEAD config index COMMIT_EDITMSG refs/heads/proposals refs/heads/side refs/heads/work; do plain "$g/$f" || return 1; done
  for f in "$g"/objects/[0-9a-f][0-9a-f]; do empty "$f" || return 1; done
  for f in objects/info objects/pack objects refs/heads refs/tags refs; do empty "$g/$f" || return 1; done
  empty "$g"
}
# Everything the Jev proof creates under $evidence/jev, including the fixture test identity.
jev_clear() {
  local fx=$evidence/jev r
  if [ -e "$fx/formal" ]; then
    for r in provenance.json merged-pr-proof.json voice-ui-target-runtime.nix-export voice-ui-target-runtime.nix-export.sha256; do plain "$fx/formal/deploy/$r" || return 1; done
    empty "$fx/formal/deploy" && empty "$fx/formal" || return 1
  fi
  for r in envs apps ops neg; do if [ -e "$fx/$r/.git" ]; then git_clear "$fx/$r" || return 1; fi; done
  plain "$fx/envs/side" && plain "$fx/envs/ciphertexts/dev-jev-api.oci-dev.sops.yaml" &&
    empty "$fx/envs/ciphertexts" && empty "$fx/envs" &&
    plain "$fx/apps/flake.nix" && plain "$fx/apps/flake.lock" && empty "$fx/apps" &&
    plain "$fx/ops/flake.nix" && plain "$fx/ops/flake.lock" && empty "$fx/ops" &&
    plain "$fx/neg/file" && empty "$fx/neg" &&
    plain "$fx/age/oci-dev.key" && plain "$fx/age/kept" && empty "$fx/age" &&
    plain "$fx/launch.out" && plain "$fx/ops.out" && plain "$fx/ops.err" && plain "$fx/scratch-clear.sh" &&
    empty "$fx/tmp" && empty "$fx"
}
cleanup() {
  code=$?
  if [ "$code" -ne 0 ]; then
    docker logs "$core" 2>/dev/null || true
    docker exec "$core" /bin/cat /tmp/apps-dev.log 2>/dev/null || true
  fi
  docker rm -f "$core" >/dev/null 2>&1 || true
  docker volume rm "$nix_volume" "$work_volume" >/dev/null 2>&1 || true
  plain "$evidence/page" && plain "$evidence/before" || code=1
  if [ -e "$evidence/jev" ]; then jev_clear || code=1; fi
  empty "$evidence" || code=1
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

  # Production: exactly the three bounded tools on the profile, the four real constants, no raw crypto binary.
  local profile prod_launch prod_init prod_ops
  profile=$("${nx[@]}" build --no-link --print-out-paths --no-write-lock-file .#dev-profile)
  prod_launch=$(readlink -f "$profile/bin/voice-ui-jev-dev")
  prod_init=$(readlink -f "$profile/bin/jev-age-init")
  prod_ops=$(readlink -f "$profile/bin/ops-jev")
  for raw in sops age age-keygen jev; do test ! -e "$profile/bin/$raw"; done
  sed -E 's/^[[:space:]]*//' "$prod_launch" | grep -xF "envs_remote=https://github.com/roccho-dev/envs" >/dev/null
  sed -E 's/^[[:space:]]*//' "$prod_launch" | grep -xF "apps_remote=https://github.com/roccho-dev/apps" >/dev/null
  sed -E 's/^[[:space:]]*//' "$prod_launch" | grep -xF "identity=/work/repos/.auth/roccho-dev/age/oci-dev.key" >/dev/null
  sed -E 's/^[[:space:]]*//' "$prod_init" | grep -xF "identity=/work/repos/.auth/roccho-dev/age/oci-dev.key" >/dev/null
  sed -E 's/^[[:space:]]*//' "$prod_ops" | grep -xF "envs_remote=https://github.com/roccho-dev/envs" >/dev/null
  sed -E 's/^[[:space:]]*//' "$prod_ops" | grep -xF "ops_remote=https://github.com/roccho-dev/ops" >/dev/null
  sed -E 's/^[[:space:]]*//' "$prod_ops" | grep -xF "identity=/work/repos/.auth/roccho-dev/age/oci-dev.key" >/dev/null
  if grep -qE '^[[:space:]]*(apps_remote|port|host)=' "$prod_ops"; then echo 'ops-jev carries apps constants' >&2; return 1; fi
  if grep -qE '^[[:space:]]*set -(x|o xtrace)' "$prod_launch" "$prod_init" "$prod_ops"; then echo 'a jev tool enables xtrace' >&2; return 1; fi

  # Fixture instance: the same source with only the four constants changed.
  local tools launch init ops
  tools="(import ./oci/dev/nix.nix { pkgs = $pkgs; }).jevTools {
    envsRemote = \"file://$fx/envs\"; appsRemote = \"file://$fx/apps\"; opsRemote = \"file://$fx/ops\";
    identity = \"$fx/age/oci-dev.key\"; }"
  launch=$("${nx[@]}" build --impure --no-link --print-out-paths --expr "($tools).launch")/bin/voice-ui-jev-dev
  init=$("${nx[@]}" build --impure --no-link --print-out-paths --expr "($tools).init")/bin/jev-age-init
  ops=$("${nx[@]}" build --impure --no-link --print-out-paths --expr "($tools).ops")/bin/ops-jev
  same() { grep -vE '^[[:space:]]*(envs_remote|apps_remote|ops_remote|identity)=' "$1" | sha256sum; }
  test "$(same "$launch")" = "$(same "$prod_launch")"
  test "$(same "$init")" = "$(same "$prod_init")"
  test "$(same "$ops")" = "$(same "$prod_ops")"
  test "$launch" != "$prod_launch"
  test "$init" != "$prod_init"
  test "$ops" != "$prod_ops"

  # Reuse the workflow's literal classifier, not a second path algorithm.
  local classify_source
  classify_source=$(sed -n '/^          classify() {$/,/^          }$/p' .github/workflows/ci.yml | sed 's/^          //')
  test -n "$classify_source"
  eval "$classify_source"
  test "$(classify '')" = false
  test "$(classify .github/workflows/ci.yml)" = false
  test "$(classify oci/dev/nix.nix)" = true
  test "$(classify oci/dev/proof.sh)" = true
  test "$(classify $'oci/dev/nix.nix\noci/dev/proof.sh\n.github/workflows/ci.yml')" = true
  for changed in flake.nix hosts/own/win.ps1 hosts/rent/win.ps1 bundle.ps1; do
    test "$(classify "$changed")" = false
    test "$(classify $'oci/dev/nix.nix\n'"$changed")" = false
  done
  # Exercise the literal preload in the built tool, not a second budget implementation.
  local node
  node=$("${nx[@]}" build --impure --no-link --print-out-paths --expr "($pkgs).nodejs")/bin/node
  "$node" --input-type=module - "$prod_launch" <<'JS'
import fs from 'node:fs';
import assert from 'node:assert/strict';
const text=fs.readFileSync(process.argv[2],'utf8');
const match=text.match(/preload="(data:text\/javascript,[^"]+)"/);
assert(match); const uri=match[1].replace('__LIMIT__','12');
let nativeCalls=0; const forwarded=[], counters=[];
const write=process.stderr.write;
process.stderr.write=s=>{counters.push(s);return true;};
globalThis.fetch=async(input,init)=>{nativeCalls++;forwarded.push(init.redirect);return {fixture:'transparent'};};
try {
  await import(uri);
  for(const [url,method] of [['https://invalid.example/','POST'],['https://api.typesafe.ai/v1/systemone','GET']])
    await assert.rejects(fetch(url,{method}),/upstream_boundary/);
  assert.equal(nativeCalls,0);
  const results=await Promise.allSettled(Array.from({length:13},()=>fetch('https://api.typesafe.ai/v1/systemone',{method:'POST'})));
  assert.equal(nativeCalls,12); assert.equal(results.filter(r=>r.status==='fulfilled').length,12);
  assert.equal(results[12].reason.message,'upstream_budget');
  assert(results.slice(0,12).every(r=>r.value.fixture==='transparent'));
  assert(forwarded.every(r=>r==='error'));
  assert.deepEqual(counters,Array.from({length:12},(_,i)=>'jev-upstream-send:'+(i+1)+'\n'));
} finally { process.stderr.write=write; }
console.log('PASS fixed built-tool upstream limit: boundary0, concurrent12, 13th0, redirect:error, transparent response');
JS
  # Formal rejection must precede identity, ciphertext, network and child access.
  # The supplied C tuple's real positive case is a separate final-operand proof.
  local formal_code=0 formal_out
  formal_out=$(NODE_OPTIONS=--invalid-formal-bootstrap-option NODE_EXTRA_CA_CERTS=/not-a-formal-ca "$launch" --formal --envs-sha 0000000000000000000000000000000000000000 \
    --deploy-sha 0000000000000000000000000000000000000000 \
    --deploy-provenance-sha256 $(printf '%064d' 0) --deploy-proof-sha256 $(printf '%064d' 0) \
    --artifacts "$fx/not-provided" --port 23001 2>&1) || formal_code=$?
  test "$formal_code" -ne 0
  grep -qF 'RED: formal_admission' <<< "$formal_out"
  if grep -qE 'decrypt|target identity|cannot fetch' <<< "$formal_out"; then echo 'formal rejection reached target bootstrap' >&2; return 1; fi

  # Supplied empty formal values cannot masquerade as omitted options or hide duplicates.
  local formal_args=(--envs-sha 0000000000000000000000000000000000000000 --deploy-sha 0000000000000000000000000000000000000000
    --deploy-provenance-sha256 "$(printf '%064d' 0)" --deploy-proof-sha256 "$(printf '%064d' 0)" --artifacts "$fx/not-provided" --port 23001)
  local bad_args i variant original flag
  for i in 1 3 5 7 9 11; do
    for variant in empty empty-duplicate duplicate nextflag; do
      bad_args=("${formal_args[@]}"); original=${bad_args[$i]}
      case "$variant" in empty|empty-duplicate) bad_args[$i]='';; nextflag) bad_args[$i]=--post-limit;; esac
      case "$variant" in empty-duplicate|duplicate) bad_args+=("${formal_args[$((i-1))]}" "$original");; esac
      formal_code=0
      formal_out=$("$launch" --formal "${bad_args[@]}" 2>&1) || formal_code=$?
      test "$formal_code" -eq 2
      if grep -qE 'formal_admission|decrypt|target identity|cannot fetch|jev-upstream-send:' <<< "$formal_out"; then echo 'empty formal value reached admission/target' >&2; return 1; fi
    done
  done
  for flag in --post-limit --host; do
  for variant in empty empty-duplicate duplicate nextflag; do
    if [ "$flag" = --post-limit ]; then original=12; else original=127.0.0.1; fi
    bad_args=("${formal_args[@]}" "$flag" "$original")
    case "$variant" in empty|empty-duplicate) bad_args[13]='';; nextflag) bad_args[13]=--port;; esac
    case "$variant" in empty-duplicate|duplicate) bad_args+=("$flag" "$original");; esac
    formal_code=0
    formal_out=$("$launch" --formal "${bad_args[@]}" 2>&1) || formal_code=$?
    test "$formal_code" -eq 2
    if grep -qE 'formal_admission|decrypt|target identity|cannot fetch|jev-upstream-send:' <<< "$formal_out"; then echo 'invalid optional formal value reached admission/target' >&2; return 1; fi
  done
  done
  # Crafted public metadata reaches distinct admission stages, never target bootstrap.
  mkdir "$fx/formal" "$fx/formal/deploy"
  printf '{}' > "$fx/formal/deploy/provenance.json"
  printf '{}' > "$fx/formal/deploy/merged-pr-proof.json"
  printf x > "$fx/formal/deploy/voice-ui-target-runtime.nix-export"
  printf x > "$fx/formal/deploy/voice-ui-target-runtime.nix-export.sha256"
  local prov_hash proof_hash expected_stage
  prov_hash=$(sha256sum "$fx/formal/deploy/provenance.json"); prov_hash=${prov_hash%% *}
  proof_hash=$(sha256sum "$fx/formal/deploy/merged-pr-proof.json"); proof_hash=${proof_hash%% *}
  for expected_stage in deploy_provenance deploy_proof; do
    local expected_prov=$prov_hash expected_proof=$proof_hash
    if [ "$expected_stage" = deploy_provenance ]; then expected_prov=$(printf '%064d' 0); else expected_proof=$(printf '%064d' 0); fi
    formal_code=0
    formal_out=$("$launch" --formal --envs-sha 0000000000000000000000000000000000000000 \
      --deploy-sha 0000000000000000000000000000000000000000 \
      --deploy-provenance-sha256 "$expected_prov" --deploy-proof-sha256 "$expected_proof" \
      --artifacts "$fx/formal" --port 23001 --post-limit 12 2>&1) || formal_code=$?
    test "$formal_code" -ne 0
    grep -qF "RED: formal_admission_$expected_stage" <<< "$formal_out"
    if grep -qE 'decrypt|target identity|cannot fetch|jev-upstream-send:' <<< "$formal_out"; then echo 'formal rejection reached target/provider' >&2; return 1; fi
  done
  for name in provenance.json merged-pr-proof.json voice-ui-target-runtime.nix-export voice-ui-target-runtime.nix-export.sha256; do plain "$fx/formal/deploy/$name"; done
  empty "$fx/formal/deploy"; empty "$fx/formal"
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
  # No template, reflog or automatic GC: .git keeps only the names git_clear enumerates.
  fixture_init() {
    g init -q --template= -b "$2" "$1"
    g -C "$1" config core.logAllRefUpdates false
    g -C "$1" config gc.auto 0
  }
  commit() {
    g -C "$fx/envs" add -A
    g -C "$fx/envs" commit -q -m "$1"
    g -C "$fx/envs" rev-parse HEAD
  }
  encrypt() {
    printf '{"JEV_API_KEY":"%s"}\n' "$key" \
      | SOPS_AGE_RECIPIENTS="$1" "$sops" --encrypt --input-type json --output-type yaml /dev/stdin
  }
  fixture_init "$fx/envs" proposals
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
        ls -1 /proc/$$/fd > /tmp/voice-ui-jev-proof-$PORT.fds
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
  fixture_init "$fx/apps" work
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

  # Fixture ops remote: a stub jev that reads its whole request from stdin, records only names, digests and its open
  # descriptors, prints exactly one JSON line, and exits 3 when the request asks for it; and one that cannot build.
  local ops_flake ops_good ops_bad
  ops_flake=$(cat <<'NIX'
{
  inputs.nixpkgs.url = "path:NIXPKGS";
  outputs = { nixpkgs, ... }: {
    packages.x86_64-linux.jev = nixpkgs.legacyPackages.x86_64-linux.writeShellScriptBin "jev" ''
      ls -1 /proc/$$/fd > /tmp/ops-jev-proof.fds
      input=$(cat)
      names=$(tr '\0' '\n' < /proc/$$/environ | cut -d= -f1 | sort | tr '\n' ' ')
      home="$HOME $([ -e "$HOME" ] && echo present || echo absent)"
      key=$(printf %s "$JEV_API_KEY" | sha256sum | cut -d' ' -f1)
      req=$(printf %s "$input" | sha256sum | cut -d' ' -f1)
      case "$(tr '\0' ' ' < /proc/$$/cmdline)" in *"$JEV_API_KEY"*) argv=key ;; *) argv=clean ;; esac
      printf '{"names":"%s","home":"%s","core":"%s","key":"%s","request":"%s","argv":"%s"}\n' \
        "$names" "$home" "$(ulimit -c)" "$key" "$req" "$argv"
      case "$input" in *'"exit":3'*) exit 3 ;; esac
    '';
  };
}
NIX
)
  fixture_init "$fx/ops" work
  printf '%s\n' "${ops_flake//NIXPKGS/$nixpkgs_src}" > "$fx/ops/flake.nix"
  g -C "$fx/ops" add flake.nix
  (cd "$fx/ops" && "${nx[@]}" flake lock)
  g -C "$fx/ops" add -A
  g -C "$fx/ops" commit -q -m stub
  ops_good=$(g -C "$fx/ops" rev-parse HEAD)
  printf '{ outputs = _: throw "no jev package"; }\n' > "$fx/ops/flake.nix"
  g -C "$fx/ops" add -A
  g -C "$fx/ops" commit -q -m broken
  ops_bad=$(g -C "$fx/ops" rev-parse HEAD)

  # Every launch runs with a hostile parent environment; no outcome may print the key.
  local port marker out="$fx/launch.out"
  port=$((20000 + RANDOM % 20000))
  marker=/tmp/voice-ui-jev-proof-$port
  mkdir "$fx/tmp"
  # The child's open descriptors, apart from 255 (a bash script's own file): only stdin, stdout and stderr. Every
  # launch below also holds descriptors 7 and 9 in the caller, so a descriptor the caller leaves open must not leak.
  only_stdio() {
    local got
    got=$(grep -vxF 255 "$1" | tr '\n' ' ')
    [ "$got" = "0 1 2 " ] || { echo "child descriptors are '$got', expected '0 1 2 '" >&2; return 1; }
  }
  launch_as() {
    local expect=$1 code=0
    shift
    rm -f "$marker" "$marker.fds"
    env TMPDIR="$fx/tmp" GH_TOKEN=fixture-gh GH_CONFIG_DIR=/nonexistent SOPS_AGE_KEY_FILE=/nonexistent HOST=0.0.0.0 SHELLOPTS=xtrace \
      'BASH_FUNC_leak%%=() { :; }' 'NOT-AN-IDENTIFIER=leak' "$launch" "$@" > "$out" 2>&1 7< /dev/null 9< /dev/null || code=$?
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
  only_stdio "$marker.fds"
  test "$(grep -n 'voice-ui-jev-dev: built ' "$out" | cut -d: -f1)" -lt "$(grep -n 'voice-ui-jev-dev: decrypt ' "$out" | cut -d: -f1)"
  # An explicit --host alone chooses the listen address, in any position; the hostile HOST above never does.
  launch_as pass --host 0.0.0.0 "${args[@]}"
  test "$(head -n 1 "$marker")" = "names HOME HOST JEV_API_KEY LANG PATH PORT "
  grep -qx 'host 0.0.0.0' "$marker"
  grep -qx 'argv clean' "$marker"
  grep -qF "on 0.0.0.0:$port with" "$out"
  launch_as pass "${args[@]}" --host 127.0.0.1
  grep -qx 'host 127.0.0.1' "$marker"

  # Arguments: exactly three flags, exact SHAs, an unprivileged port.
  launch_as red --envs-sha "$good" --apps-sha "$apps_good"
  launch_as red "${args[@]}" --port "$port"
  launch_as red --envs-sha "${good^^}" --apps-sha "$apps_good" --port "$port"
  launch_as red --envs-sha "$good" --apps-sha "$apps_good" --port 80
  launch_as red --envs-sha "$good" --apps-sha "$apps_good" --port 70000
  # The host: only 127.0.0.1 or 0.0.0.0, once, with a value.
  for h in localhost :: 192.0.2.1 '' 127.0.0.2; do launch_as red "${args[@]}" --host "$h"; done
  launch_as red "${args[@]}" --host
  launch_as red "${args[@]}" --host 0.0.0.0 --host 0.0.0.0
  launch_as red --envs-sha "$good" --apps-sha "$apps_good" --host 0.0.0.0 --host 127.0.0.1
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
  encrypt "$recipient" > "$cipher"; good=$(commit current-again)

  # ops-jev: the caller's stdin is the child's request, the child's single stdout line and exit status are the caller's,
  # the launcher speaks only on stderr, and every outcome runs with the same hostile parent. No outcome prints the key.
  local ops_fds=/tmp/ops-jev-proof.fds ops_out="$fx/ops.out" ops_err="$fx/ops.err" request
  request='{"type":"noul","text":"fixture","question":"fixture?"}'
  ops_as() {
    local expect=$1 input=$2 code=0
    shift 2
    rm -f "$ops_fds"
    printf '%s' "$input" | env TMPDIR="$fx/tmp" GH_TOKEN=fixture-gh GH_CONFIG_DIR=/nonexistent SOPS_AGE_KEY_FILE=/nonexistent \
      JEV_API_KEY=parent-leak SHELLOPTS=xtrace 'BASH_FUNC_leak%%=() { :; }' 'NOT-AN-IDENTIFIER=leak' \
      "$ops" "$@" > "$ops_out" 2> "$ops_err" 7< /dev/null 9< /dev/null || code=$?
    if grep -qF "$key" "$ops_out" "$ops_err"; then echo 'the key reached ops-jev output' >&2; return 1; fi
    if grep -qF 'ops-jev:' "$ops_out"; then echo 'ops-jev wrote its own messages to stdout' >&2; return 1; fi
    case $expect in
      pass | exit3)
        [ "$code" -eq "$([ "$expect" = pass ] && echo 0 || echo 3)" ] && [ "$(wc -l < "$ops_out")" -eq 1 ] && [ -e "$ops_fds" ] ;;
      red) [ "$code" -ne 0 ] && [ ! -s "$ops_out" ] && [ ! -e "$ops_fds" ] ;;
    esac || { cat "$ops_err" >&2; echo "ops-jev: expected $expect, exit $code: $*" >&2; return 1; }
  }
  local ops_args=(--envs-sha "$good" --ops-sha "$ops_good") digest
  digest=$(printf %s "$key" | sha256sum | cut -d' ' -f1)
  ops_as pass "$request" "${ops_args[@]}"
  test "$(cat "$ops_out")" = "{\"names\":\"HOME JEV_API_KEY LANG PATH \",\"home\":\"/homeless-shelter absent\",\"core\":\"0\",\"key\":\"$digest\",\"request\":\"$(printf %s "$request" | sha256sum | cut -d' ' -f1)\",\"argv\":\"clean\"}"
  only_stdio "$ops_fds"
  test "$(grep -n 'ops-jev: built ' "$ops_err" | cut -d: -f1)" -lt "$(grep -n 'ops-jev: decrypt ' "$ops_err" | cut -d: -f1)"
  ops_as pass "$request" --ops-sha "$ops_good" --envs-sha "$good"
  ops_as exit3 '{"type":"noul","exit":3}' "${ops_args[@]}"
  # Arguments: exactly the two flags, exact SHAs; no apps flag, port, host, attribute or extra argument.
  ops_as red "$request" --envs-sha "$good"
  ops_as red "$request" "${ops_args[@]}" --port 20000
  ops_as red "$request" "${ops_args[@]}" jev
  ops_as red "$request" --envs-sha "$good" --apps-sha "$ops_good"
  ops_as red "$request" --envs-sha "$good" --ops-sha "${ops_good^^}"
  ops_as red "$request" --envs-sha "$good" --envs-sha "$good"
  # The shared currentness, identity and build-before-decrypt boundary.
  ops_as red "$request" --envs-sha "$stale" --ops-sha "$ops_good"
  ops_as red "$request" --envs-sha "$off" --ops-sha "$ops_good"
  ops_as red "$request" --envs-sha "$good" --ops-sha "$ops_bad"
  if grep -q 'ops-jev: decrypt' "$ops_err"; then echo 'ops-jev decrypted before its program was built' >&2; return 1; fi
  ops_as red "$request" --envs-sha "$good" --ops-sha "$(printf unknown | sha256sum | cut -c1-40)"
  chmod 0644 "$fx/age/oci-dev.key"; ops_as red "$request" "${ops_args[@]}"; chmod 0600 "$fx/age/oci-dev.key"
  rm -f "$ops_fds"
  test -z "$(ls -A "$fx/tmp")"
  # scratch_clear as built into the launcher: it removes exactly the scratch the launcher writes, and keeps and refuses
  # anything else (here a loose object and a foreign pack name).
  sed -n '/^[[:space:]]*scratch_clear() {$/,/^[[:space:]]*}$/p' "$launch" > "$fx/scratch-clear.sh"
  grep -q '^[[:space:]]*scratch_clear() {$' "$fx/scratch-clear.sh"
  # scratch_case KIND ENTRY: plant a foreign file, FIFO or link at ENTRY (none for clean); the launcher's own
  # scratch_clear must keep it and fail, and after the test removes its own plant, remove everything.
  scratch_case() {
    local kind=$1 extra=$2 cu work repo p code=0
    cu=$(dirname "$(readlink -f "$(command -v rmdir)")")
    work=$(mktemp -d -p "$fx") repo=$work/envs.git p=pack-$(printf '%040d' 0)
    mkdir -p "$repo/objects/pack" "$repo/objects/info" "$repo/refs/heads" "$repo/refs/tags"
    touch "$work/cipher.yaml" "$repo/HEAD" "$repo/config" "$repo/FETCH_HEAD" "$repo/refs/heads/proposals" \
      "$repo/objects/pack/$p.pack" "$repo/objects/pack/$p.idx" "$repo/objects/pack/$p.rev"
    case $kind in
      clean) ;;
      file) mkdir -p "$(dirname "$repo/$extra")"; echo foreign > "$repo/$extra" ;;
      fifo) rm -f "$repo/$extra"; mkfifo "$repo/$extra" ;;
      link) rm -f "$repo/$extra"; ln -s /etc/hostname "$repo/$extra" ;;
    esac
    # shellcheck disable=SC1091
    (source "$fx/scratch-clear.sh"; scratch_clear) || code=$?
    if [ "$kind" != clean ]; then
      case $kind in
        file) [ "$code" -ne 0 ] && [ "$(cat "$repo/$extra")" = foreign ] ;;
        fifo) [ "$code" -ne 0 ] && [ -p "$repo/$extra" ] ;;
        link) [ "$code" -ne 0 ] && [ "$(readlink "$repo/$extra")" = /etc/hostname ] ;;
      esac || { echo "scratch_clear removed or accepted $kind $extra" >&2; return 1; }
      rm -f -- "$repo/$extra"
      case $extra in objects/ab/*) rmdir -- "$repo/objects/ab" ;; esac
      code=0
      # shellcheck disable=SC1091
      (source "$fx/scratch-clear.sh"; scratch_clear) || code=$?
    fi
    [ "$code" -eq 0 ] && [ ! -e "$work" ] || { echo "scratch_clear left or refused the launcher scratch ($kind)" >&2; return 1; }
  }
  scratch_case clean ''
  scratch_case file objects/ab/cdef0123456789abcdef0123456789abcdef01
  scratch_case file objects/pack/pack-foreign.pack
  scratch_case fifo HEAD
  scratch_case link HEAD
  # git_clear on a fixture repository: a foreign file at an object-shaped name is kept and refused; once the test's own
  # plant is gone, only Git-verified objects and fixed names are removed and nothing remains.
  local neg=$fx/neg planted
  fixture_init "$neg" proposals
  echo neg > "$neg/file"; g -C "$neg" add file; g -C "$neg" commit -q -m neg
  planted=$neg/.git/objects/00/$(printf '%038d' 0)
  mkdir -p "${planted%/*}"; echo foreign > "$planted"
  if git_clear "$neg"; then echo 'git_clear removed a foreign object-shaped file' >&2; return 1; fi
  test "$(cat "$planted")" = foreign
  plain "$planted"
  git_clear "$neg" && plain "$neg/file" && empty "$neg"
  # The whole Jev fixture area, including the test identity: an unexpected entry is kept and refused; then all is gone.
  echo foreign > "$fx/unexpected"
  if jev_clear 2>/dev/null; then echo 'jev_clear accepted an unexpected entry' >&2; return 1; fi
  test "$(cat "$fx/unexpected")" = foreign
  plain "$fx/unexpected"
  jev_clear
  test ! -e "$fx"
  rm -f "$marker" "$marker.fds"
  echo 'PASS formal admission: absent operand refused before identity/cipher/network/child; classifier owner-only true, empty/CI-only/mixed/product false;'
  echo 'PASS jev tools (fixtures): production profile has only the three bounded tools and exact constants; same source;'
  echo 'PASS jev launch: closed child environment, loopback unless --host 0.0.0.0 is explicit, no core, absent HOME, only stdio descriptors, no temp left after any launch, key never in argv or output, build before decrypt;'
  echo 'PASS ops-jev: caller stdin is the request, one stdout JSON line, exit status passed through, launcher messages on stderr only, PATH HOME LANG JEV_API_KEY only, only stdio descriptors, build before decrypt, RED on arguments/stale/off/unbuildable/unknown/identity;'
  echo 'PASS jev scratch: removed file by file before the child, never recursively; unexpected entries and types kept and refused;'
  echo 'PASS jev fixtures: Git-verified objects and known files removed, foreign entries kept and refused; no fixture or test identity left;'
  echo 'PASS jev RED: arguments, host, stale/off/unknown envs commit, unbuildable apps, identity mode/missing/other, tamper, two recipients, extra field, absent'
}
jev_proof
[ "$mode" = full ] || exit 0

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
