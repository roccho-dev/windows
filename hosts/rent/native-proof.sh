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
    wrong-B) args=("$t0" "$bound_q" ci-host-rent-1 ci-session-1 NONE "$before_o" ci:other-B);;
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
[ "$(docker inspect --format '{{.Image}}' "$c")" = "$image" ] ||
  fail 'bound T-only selection changed the base OCI image'
# A finite test receipt is derived from the ACTUAL post-write readback and the
# SAME preflight q/Host/store. It is a shell variable, not a runtime ledger.
bound_receipt=$(python3 - "$preflight" "$before_o" "$actual_bound_o" "$t0" "$bound_q" <<'PY'
import json,sys
intent=json.loads(sys.argv[1])
before,after,selected,q=sys.argv[2:]
assert intent["proposed_q"]==q and intent["candidate_store"]==selected
assert intent["effect"]=="FORBIDDEN" and intent["admission"]=="NOT_ADMITTED"
assert before=="selection=ABSENT proof=geometry-only"
assert after=="selection=SELECTED generation=rent-dev-1-link store="+selected+" proof=geometry-only"
print(json.dumps({"kind":"ci-rent-bound-observation.v0","attempt":"ci-rent-bound-1",
                  "proposed_q":q,"target_ref":intent["target_ref"],
                  "host_ref":intent["host_ref"],"unit_ref":intent["unit_ref"],
                  "before":before,"after":after,"store":selected,
                  "admission":"NOT_ADMITTED","target_effect_authorized":False,
                  "result":"SOURCE_CI_READBACK_ONLY"},sort_keys=True))
PY
) || fail 'bound actual O/readback attempt did not match q'
[[ $bound_receipt == *'"result": "SOURCE_CI_READBACK_ONLY"'* ]] ||
  fail 'missing bounded SOURCE attempt evidence'
# A lost receipt is UNKNOWN, not success or automatic NOOP. Re-read O but
# never perform an equivalent second write; a preflight retry must be denied.
if bound_preflight "$t0" "$bound_q" ci-host-rent-1 ci-session-1 UNKNOWN "$actual_bound_o" >/dev/null 2>&1; then
  fail 'unknown bound effect retried blindly'
fi
[ "$(observe_ro)" = "$actual_bound_o" ] ||
  fail 'UNKNOWN reconciliation read mutated the selected Tool'
# Simulate losing the caller's in-memory CI receipt; selection must remain
# observed, but retry cannot fabricate an additional successful effect.
unset bound_receipt
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
# P2/P3 SOURCE fixture: same actual Docker/Nix instance and native generations.
# The receiver is never installed into B, launched by logon, or authorized LIVE.
python3 - "$c" "$t0" "$t1" "$binding" <<'PY'
import copy, importlib.util, json, re, subprocess, sys
from pathlib import Path
container,t0,t1,source_path=sys.argv[1:]
binding=json.loads(Path(source_path).read_text(encoding="utf-8"))
spec=importlib.util.spec_from_file_location("rent_receiver",Path("hosts/rent/tool-receiver.py"))
assert spec and spec.loader
receiver=importlib.util.module_from_spec(spec)
spec.loader.exec_module(receiver)
q=binding["proposed_q"]
rev="ci-"+q[7:23]
subject=dict(target_ref=binding["target_ref"],host_ref=binding["host_ref"],
             unit_ref=binding["unit_ref"],scope=binding["scope"],
             actor_ref="ci-fixed-W",work_ref="ci-rent-source-SUT",
             attempt_ref="ci-rent-source-1",route_ref="ci-only-route")
def grant(granted_step,**updates):
    # Use a distinct positional variable so an intentionally invalid
    # grant_over={"step":"RECORD"} reaches the receiver rather than raising.
    g=dict(kind="envs.syntheticStageGrant.v0",**subject,step=granted_step,
           permit=True,issuer_fixture="ci-independent-source-issuer")
    g.update(updates)
    return g
def request(action,**updates):
    r=dict(kind="envs.syntheticHostSourceRequest.v0",**subject,
           action=action,proposed_q=q,
           requested_store=None if action=="READ" else t0)
    r.update(updates)
    return r
def bound(**updates):
    b=dict(kind="windows.syntheticBoundSource.v0",binding=copy.deepcopy(binding),
           desired=dict(kind="envs.syntheticDesired.v0",target_ref=binding["target_ref"],
                        proposed_q=q,material=binding["material"],
                        revision=rev,store_path=t0),
           current_q=rev,previous_state="NONE",read_grant=grant("READ"),
           quiet=True,single_writer=True,recovery=True,
           fixture_issuer="ci-independent-source-issuer")
    b.update(updates)
    return b
def docker(*args,input=None):
    p=subprocess.run(["docker",*args],input=input,stdout=subprocess.PIPE,
                     stderr=subprocess.PIPE,text=True)
    if p.returncode:
        raise RuntimeError("disposable Docker/Nix command failed: "+p.stderr[-700:])
    return p.stdout.strip()
class Actual:
    kind="windows.syntheticDisposableNixTransport.v0"
    fixture_only=True
    def __init__(self):
        self.reads=self.selects=self.records=self.rollbacks=0
        self.fail_after_write=False
        self.fail_before_write=False
        self.fail_record_ack=False
        self.fail_rollback_before_write=False
        self.reader=Path("hosts/rent/read-selected.sh").read_text(encoding="utf-8")
    def expected_producer_store(self):
        # $t0 is the actual immutable F1 Nix-built Tool-only output,
        # independent of caller-proposed store/desired/q.
        return t0
    def observe(self):
        self.reads+=1
        try:
            raw=docker("exec","-i","-u","1000:1000",container,
                       "/bin/bash","-s",input=self.reader)
        except RuntimeError:
            return self.wrap("UNKNOWN",None,None,False)
        if raw=="selection=ABSENT proof=geometry-only":
            return self.wrap("ABSENT",None,None,True)
        matched=re.fullmatch(
            r"selection=SELECTED generation=(rent-dev-[1-9][0-9]*-link) "
            r"store=(/nix/store/[0-9a-z]{32}-[^/\s]+) proof=geometry-only",raw)
        if not matched:
            return self.wrap("UNKNOWN",None,None,False)
        store=matched.group(2)
        try:
            docker("exec",container,"/bin/nix-store","--check-validity",store)
            valid=True
        except RuntimeError:
            valid=False
        return self.wrap("SELECTED",store,matched.group(1),valid)
    def wrap(self,state,store,generation,valid):
        ident=None
        if state!="UNKNOWN":
            ident=copy.deepcopy(binding["identity"])
            ident["tool"]=("ci:rent-tool-T0" if store==t0 else
                           "ci:rent-tool-T1" if store==t1 else "ci:Tool-ABSENT")
        return dict(kind="windows.syntheticRentObservation.v0",
                    **{k:binding[k] for k in
                       ("target_ref","host_ref","unit_ref","scope")},
                    state=state,store_path=store,generation=generation,
                    identity=ident,fresh=state!="UNKNOWN",closure_valid=valid)
    def quiet(self):
        top=docker("top",container,"-eo","pid,args")
        if not all(token in top for token in ("rent-start","nix-daemon","sshd")):
            return False
        return not any(re.search(r"/bin/"+exe+r"(?:\s|$)",top)
                       for exe in ("codex","claude","python3","uv","hello"))
    def validate_closure(self,store):
        if store not in (t0,t1):
            return False
        try:
            paths=docker("exec",container,"/bin/nix-store",
                         "--query","--requisites",store).splitlines()
            for path in paths:
                docker("exec",container,"/bin/nix-store","--check-validity",path)
            helper=docker("exec",container,"/bin/readlink","-e",
                          store+"/bin/git-credential-github-roccho-dev")
            core=docker("exec",container,"/bin/readlink","-e",
                        "/bin/git-credential-github-roccho-dev")
            return helper==core
        except RuntimeError:
            return False
    def select(self,store):
        self.selects+=1
        if self.fail_before_write:
            raise RuntimeError("CI synthetic write acknowledgement unknown before Nix")
        docker("exec",container,"/bin/nix-env","--profile",
               "/nix/var/nix/profiles/rent-dev","--set",store)
        if self.fail_after_write:
            raise RuntimeError("CI synthetic acknowledgement lost after real Nix write")
    def record(self,receipt):
        self.records+=1
        if self.fail_record_ack:
            raise RuntimeError("CI record stored but acknowledgement lost")
        # This is a disposable transport ACK, not a Target receipt or ledger.
        return "CI_ONLY_RECORD_NO_TARGET_LEDGER"
    def rollback(self,preimage):
        assert preimage in (t0,t1)
        self.rollbacks+=1
        if self.fail_rollback_before_write:
            raise RuntimeError("CI-only rollback transport UNKNOWN before Nix write")
        docker("exec",container,"/bin/nix-env","--profile",
               "/nix/var/nix/profiles/rent-dev","--rollback")
port=Actual()
image=docker("inspect","-f","{{.Image}}",container)
state=docker("exec",container,"/bin/bash","-euc",
             "sha256sum /var/lib/rent/dev/codex/auth.json "
             "/var/lib/rent/dev/claude/ci-session-marker /work/repos/proof-marker")
assert port.observe()["store_path"]==t1
def call(action,*,req_over=None,grant_over=None,bound_over=None,receipt=None):
    step={"READ":"READ","CHANGE":"TOOL_CHANGE",
          "RECORD":"RECORD","ROLLBACK":"ROLLBACK"}[action]
    req=request(action,**(req_over or {}))
    g=grant(step,**(grant_over or {}))
    b=bound(**(bound_over or {}))
    if req["attempt_ref"] != subject["attempt_ref"]:
        # Explicit CI issuer grants a separate exact attempt. Do NOT rebind
        # other mutated subject fields, such as an unapproved route.
        g["attempt_ref"]=req["attempt_ref"]
        b["read_grant"]["attempt_ref"]=req["attempt_ref"]
    return receiver.receive_step(req,g,b,port,receipt=receipt)
def check(ref,stage,**kwargs):
    result=call(ref,**kwargs)
    assert result["stage"]==stage,(ref,stage,result)
    assert result["admission"]=="NOT_ADMITTED"
    assert result["production_effect"]=="FORBIDDEN"
    assert result["target_ready"] is False and result["merge_ready"] is False
    return result
start_reads=port.reads
check("READ","REFUSED_PRE_EFFECT",grant_over={"permit":False},
      bound_over={"desired":None,"current_q":None,"previous_state":"UNKNOWN"})
assert port.reads==start_reads and port.selects==0
got=check("READ","READ_OBSERVED",
          bound_over={"desired":None,"current_q":None,"previous_state":"UNKNOWN"})
assert got["observation"]["store_path"]==t1 and port.selects==0
check("CHANGE","REFUSED_PRE_EFFECT",grant_over={"step":"RECORD"})
check("CHANGE","REFUSED_PRE_EFFECT",req_over={"route_ref":"ci-other-route"})
check("CHANGE","REFUSED_PRE_EFFECT",req_over={"requested_store":t1})
# R B: q/material unchanged while both caller-owned desired and request
# point at t1 (the other VALID closure). Independently built F1 says t0.
bad_d=bound()["desired"]
bad_d["store_path"]=t1
check("CHANGE","REFUSED_PRE_EFFECT",req_over={"requested_store":t1},
      bound_over={"desired":bad_d})
assert port.selects==0 and port.records==0 and port.rollbacks==0
issued=check("CHANGE","TOOL_CHANGE_READBACK_CANDIDATE")["issued_receipt"]
assert issued and issued["selected"]==t0 and issued["preimage"]==t1
assert port.selects==1 and port.observe()["store_path"]==t0
check("CHANGE","REFUSED_PRE_EFFECT")  # same current D Tool, no second write
assert port.selects==1
check("RECORD","REFUSED_PRE_EFFECT",grant_over={"permit":False},
      bound_over={"previous_state":"CONFIRMED","quiet":False,
                  "single_writer":False,"recovery":False},receipt=issued)
assert port.records==0
check("RECORD","REFUSED_PRE_EFFECT",bound_over={"previous_state":"CONFIRMED"},
      receipt=copy.deepcopy(issued))
assert port.records==0
check("RECORD","RECORD_ONLY_CANDIDATE",
      bound_over={"previous_state":"CONFIRMED","quiet":False,
                  "single_writer":False,"recovery":False},receipt=issued)
assert port.records==1 and port.selects==1
check("RECORD","REFUSED_PRE_EFFECT",
      bound_over={"previous_state":"CONFIRMED"},receipt=issued)
assert port.records==1
check("ROLLBACK","REFUSED_PRE_EFFECT",grant_over={"permit":False},
      bound_over={"previous_state":"CONFIRMED"},receipt=issued)
assert port.rollbacks==0
check("ROLLBACK","ROLLBACK_READBACK_REQUIRED",
      bound_over={"previous_state":"CONFIRMED"},receipt=issued)
assert port.rollbacks==1 and port.observe()["store_path"]==t1
check("ROLLBACK","REFUSED_PRE_EFFECT",
      bound_over={"previous_state":"CONFIRMED"},receipt=issued)
assert port.rollbacks==1
# R C: ROLLBACK must not erase the consumed-attempt tombstone. The same
# attempt, now with old T1 selected and previous_state reset, may NOT select.
check("CHANGE","REFUSED_PRE_EFFECT")
assert port.selects==1 and port.observe()["store_path"]==t1
# Simulate a real Nix write followed by lost acknowledgement: UNKNOWN, never
# retry an equivalent change in this disposable instance. CI cleanup is explicit.
port.fail_after_write=True
check("CHANGE","UNKNOWN_AFTER_SEND_NO_REPLAY",
      req_over={"attempt_ref":"ci-rent-source-2"})
assert port.selects==2 and port.observe()["store_path"]==t0
check("CHANGE","REFUSED_PRE_EFFECT",
      req_over={"attempt_ref":"ci-rent-source-2"})
assert port.selects==2
docker("exec",container,"/bin/nix-env","--profile",
       "/nix/var/nix/profiles/rent-dev","--rollback") # CI teardown, NOT receiver retry
assert port.observe()["store_path"]==t1
# R C: when an invoked select fails before an actual Nix write, the OLD O
# remains visible but that same attempt must still never be replayed.
port.fail_after_write=False
port.fail_before_write=True
check("CHANGE","UNKNOWN_AFTER_SEND_NO_REPLAY",
      req_over={"attempt_ref":"ci-rent-source-3"})
assert port.selects==3 and port.observe()["store_path"]==t1
port.fail_before_write=False
check("CHANGE","REFUSED_PRE_EFFECT",
      req_over={"attempt_ref":"ci-rent-source-3"})
assert port.selects==3 and port.observe()["store_path"]==t1
# R A: RECORD ACK loss can follow a real CI-only record side effect. The
# same attempt's second RECORD must not call transport.record again.
issued4=check("CHANGE","TOOL_CHANGE_READBACK_CANDIDATE",
              req_over={"attempt_ref":"ci-rent-source-4"})["issued_receipt"]
assert issued4["selected"]==t0 and port.selects==4
port.fail_record_ack=True
check("RECORD","UNKNOWN_AFTER_SEND_NO_REPLAY",
      req_over={"attempt_ref":"ci-rent-source-4"},
      bound_over={"previous_state":"CONFIRMED"},receipt=issued4)
assert port.records==2
port.fail_record_ack=False
check("RECORD","REFUSED_PRE_EFFECT",
      req_over={"attempt_ref":"ci-rent-source-4"},
      bound_over={"previous_state":"CONFIRMED"},receipt=issued4)
assert port.records==2 and port.selects==4
docker("exec",container,"/bin/nix-env","--profile",
       "/nix/var/nix/profiles/rent-dev","--rollback") # CI teardown only
assert port.observe()["store_path"]==t1
# R2: a genuine receipt for a new CHANGE is not a license to replay ROLLBACK
# when the first rollback was invoked but its ACK disappeared BEFORE Nix wrote.
# The SAME real Docker/Nix container stays T0 after the injected exception.
issued5=check("CHANGE","TOOL_CHANGE_READBACK_CANDIDATE",
              req_over={"attempt_ref":"ci-rent-source-5"})["issued_receipt"]
assert issued5["preimage"]==t1 and issued5["selected"]==t0
assert port.selects==5 and port.observe()["store_path"]==t0
before_rollback=port.rollbacks
port.fail_rollback_before_write=True
check("ROLLBACK","UNKNOWN_AFTER_SEND_NO_REPLAY",
      req_over={"attempt_ref":"ci-rent-source-5"},
      bound_over={"previous_state":"CONFIRMED"},receipt=issued5)
assert port.rollbacks==before_rollback+1 and port.observe()["store_path"]==t0
port.fail_rollback_before_write=False
check("ROLLBACK","REFUSED_PRE_EFFECT",
      req_over={"attempt_ref":"ci-rent-source-5"},
      bound_over={"previous_state":"CONFIRMED"},receipt=issued5)
assert port.rollbacks==before_rollback+1 and port.observe()["store_path"]==t0
# Independently permitted READ remains possible after UNKNOWN but does not
# settle the old rollback outcome or permit an equivalent retry.
read_after_unknown=check("READ","READ_OBSERVED",
      req_over={"attempt_ref":"ci-rent-source-5"},
      bound_over={"desired":None,"current_q":None,"previous_state":"UNKNOWN"})
assert read_after_unknown["observation"]["store_path"]==t0
assert port.rollbacks==before_rollback+1 and port.records==2 and port.selects==5
docker("exec",container,"/bin/nix-env","--profile",
       "/nix/var/nix/profiles/rent-dev","--rollback") # CI teardown only; not receiver recovery
assert port.observe()["store_path"]==t1
assert docker("inspect","-f","{{.Image}}",container)==image
assert docker("exec",container,"/bin/bash","-euc",
              "sha256sum /var/lib/rent/dev/codex/auth.json "
              "/var/lib/rent/dev/claude/ci-session-marker /work/repos/proof-marker")==state
print("PASS: same real OCI/Nix receiver READ->CHANGE->RECORD-only->ROLLBACK; "
      "pre-effect refusal zero, post-send CHANGE/RECORD/ROLLBACK UNKNOWN no replay, "
      "Base/state unchanged")
PY
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
