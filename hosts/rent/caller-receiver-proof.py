#!/usr/bin/env python3
"""P3: fixed envs P1 caller -> Windows P2 receiver -> ONE disposable OCI/Nix Port.

Invoked only by hosts/rent/native-proof.sh in a disposable SOURCE CI container.
This file has no production caller, Target route, admitted D or credentials.
Its immutable public source inputs are content-addressed Git blobs.
"""
from __future__ import annotations

import copy
import hashlib
import json
import sys
import tempfile
import urllib.request
from pathlib import Path

ENVS_HEAD = "3beabaa50a60adc6ce93f65af8820aad5efe0716"
REVIEWED = {
    "adapters/host_tool_source_entry.py": "758a0b8954719994f03c01c459f68e0ea9bf59e3",
    "adapters/host_tool_functional_binding.py": "6f7e8913665daeaf5a4d7aea7a57adf888638fcf",
    "adapters/host_tool_selection.py": "11aa708b3f880f2956367da98b6a9c2af1b34dfd",
    "adapters/host_tool_continuation.py": "5dca451121d4d9d7ba92587620bdb7f9def7ca32",
    "adapters/host_tool_guard.py": "ad895e8335b19068cfa4c9a277f3c72b14bd32db",
    "checks/host_tool_source_provenance.py": "0eab8dc3359556744964dc68d77b41506a690bb3",
    "checks/test_host_tool_functional_binding.py": "805f0cb0fd1af504977b63a7a81884b31f0bcd16",
    "checks/test_host_tool_continuation.py": "6b3f8341499ccbc77219066a0b9af4d131e15d28",
    "contracts/targets.jsonl": "375af894f810b534724cc448536bd0c36cfa966f",
    "contracts/proposals/host-tool-selection.jsonl": "a42f3665d6413a19a771d760b79b50be81bfe8cf",
}
F1_BLOB = "cee080d45e3e7dea8d3c0a608dd2827659101d45"


def blob(raw: bytes) -> str:
    return hashlib.sha1(b"blob " + str(len(raw)).encode() + b"\0" + raw).hexdigest()


def download_reviewed(root: Path):
    """No auth, no token, immutable SHA, verify each Git blob before import."""
    for relative, expected in REVIEWED.items():
        assert relative.startswith(("adapters/", "checks/", "contracts/"))
        uri = f"https://raw.githubusercontent.com/roccho-org/envs/{ENVS_HEAD}/{relative}"
        request_obj = urllib.request.Request(
            uri, headers={"User-Agent": "windows-rent-p3-disposable-source-proof"},
        )
        with urllib.request.urlopen(request_obj, timeout=30) as response:
            assert response.status == 200
            raw = response.read(200_001)
        assert len(raw) <= 200_000 and blob(raw) == expected, (
            "P1 immutable source file/blob differs", relative
        )
        out = root / relative
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_bytes(raw)


def proof():
    # All references below must be passed from the EXISTING P2 here-doc,
    # not a second Docker instance or independent fake Port.
    actual = P2_ACTUAL
    receiver = P2_RECEIVER
    binding = P2_BINDING
    docker = P2_DOCKER
    request = P2_REQUEST
    grant = P2_GRANT
    bound = P2_BOUND
    container, t0, t1 = P2_CONTAINER, P2_T0, P2_T1
    q, rev = P2_Q, P2_REV
    same_image, state_before = P2_IMAGE, P2_STATE
    assert actual.fixture_only is True
    assert actual.kind == "windows.syntheticDisposableNixTransport.v0"
    assert binding["proposed_q"] == q
    # The already-reviewed CI loader fetched this exact F1 Git blob to $binding.
    f1_bytes = Path(P2_BINDING_PATH).read_bytes()
    assert blob(f1_bytes) == F1_BLOB
    assert json.loads(f1_bytes) == binding
    assert actual.observe()["store_path"] == t1
    assert docker("inspect", "-f", "{{.Image}}", container) == same_image

    with tempfile.TemporaryDirectory(prefix="v6-p3-public-envs-source-") as temp:
        src = Path(temp)
        download_reviewed(src)
        sys.path[:0] = [str(src / "checks"), str(src / "adapters")]
        try:
            from host_tool_source_entry import source_step
            from host_tool_selection import read_jsonl
            from test_host_tool_functional_binding import real_relation_projector
            from test_host_tool_continuation import facts

            relation_project, _relation_error = real_relation_projector()
            proposals = read_jsonl(src / "contracts/proposals/host-tool-selection.jsonl")
            targets = read_jsonl(src / "contracts/targets.jsonl")
            assert binding["target_ref"] == "pc7337-rent"
            assert binding["proposed_q"] == q
            ref = {k: binding[k] for k in ("target_ref", "host_ref", "unit_ref", "scope")}
            subject = dict(ref, actor_ref="ci-fixed-W", work_ref="ci-p3-same-nix-work",
                           attempt_ref="ci-p3-1", route_ref="ci-only-route")

            def g(subject, step):
                return {"kind": "envs.syntheticStageGrant.v0", **subject,
                        "step": step, "permit": True,
                        "issuer_fixture": "ci-independent-source-issuer"}

            def previous(state):
                return {"kind": "envs.syntheticEffect.v0",
                        "target_ref": ref["target_ref"], "state": state,
                        "revision": rev if state == "CONFIRMED" else None,
                        "store_path": t0 if state == "CONFIRMED" else None}

            class SamePortBridge:
                kind = "envs.syntheticDisposableTargetPort.v0"
                fixture_only = True

                def __init__(self):
                    # Preserve identity: this is the SAME actual P2 Docker/Nix Port.
                    self.actual = actual
                    self.receiver = receiver
                    self.route_calls = {"READ": 0, "CHANGE": 0, "RECORD": 0, "ROLLBACK": 0}
                    self.attempt = "ci-p3-1"

                def receive(self, step, *, receipt=None, store=None):
                    action = step
                    req = request(action, actor_ref=subject["actor_ref"],
                                  work_ref=subject["work_ref"],
                                  route_ref=subject["route_ref"],
                                  attempt_ref=self.attempt,
                                  requested_store=None if action == "READ" else t0)
                    if store is not None:
                        req["requested_store"] = store
                    rgrant = grant("READ", actor_ref=req["actor_ref"],
                                   work_ref=req["work_ref"], route_ref=req["route_ref"],
                                   attempt_ref=req["attempt_ref"])
                    sgrant = grant({"READ": "READ", "CHANGE": "TOOL_CHANGE",
                                    "RECORD": "RECORD", "ROLLBACK": "ROLLBACK"}[action],
                                   actor_ref=req["actor_ref"], work_ref=req["work_ref"],
                                   route_ref=req["route_ref"], attempt_ref=req["attempt_ref"])
                    b = bound(read_grant=rgrant,
                              previous_state="CONFIRMED" if action in ("RECORD", "ROLLBACK") else "NONE")
                    self.route_calls[action] += 1
                    return self.receiver.receive_step(req, sgrant, b, self.actual, receipt=receipt)

                def observe(self):
                    outcome = self.receive("READ")
                    if outcome["stage"] not in ("READ_OBSERVED", "READ_UNKNOWN"):
                        raise ValueError("P2 receiver refused current P3 readonly observation")
                    observed = outcome["observation"]
                    ident = copy.deepcopy(observed["identity"])
                    if ident is not None:
                        ident.update(target_ref=ref["target_ref"], unit_ref=ref["unit_ref"])
                    return {"kind": "envs.syntheticPortObservation.v0", **ref,
                            "state": observed["state"], "store_path": observed["store_path"],
                            "identity": ident, "fresh": observed["fresh"],
                            "closure_valid": observed["closure_valid"]}

                def select(self, store, attempt, revision):
                    assert revision == rev and store == t0
                    self.attempt = attempt
                    result = self.receive("CHANGE", store=store)
                    if result["stage"] != "TOOL_CHANGE_READBACK_CANDIDATE":
                        raise RuntimeError("P2 receiver change not proven: " + result["stage"])
                    return result["issued_receipt"]

                def record(self, receipt, revision):
                    assert revision == rev
                    self.attempt = receipt["attempt"]
                    result = self.receive("RECORD", receipt=receipt)
                    if result["stage"] != "RECORD_ONLY_CANDIDATE":
                        raise ValueError("P2 receiver record was refused: " + result["stage"])
                    return "SYNTHETIC_RECORD_ONLY"

                def rollback(self, receipt, attempt, desired):
                    assert desired["revision"] == rev
                    self.attempt = attempt
                    result = self.receive("ROLLBACK", receipt=receipt)
                    if result["stage"] != "ROLLBACK_READBACK_REQUIRED":
                        raise ValueError("P2 receiver rollback was refused: " + result["stage"])
                    return "SYNTHETIC_ROLLBACK_NOT_NEW_D_SUCCESS"

            bridge = SamePortBridge()
            desired = {"kind": "envs.syntheticDesired.v0",
                       "target_ref":ref["target_ref"], "proposed_q": q,
                       "material": copy.deepcopy(binding["material"]),
                       "revision":rev, "store_path":t0}
            access = {"kind": "envs.syntheticScopedAuthority.v0", **subject,
                      "read": True, "change": True, "record": True,
                      "rollback": True, "quiet": True, "single_writer": True,
                      "recovery": True, "route": True}
            stages = {"READ": "READ", "CHANGE": "TOOL_CHANGE",
                      "RECORD": "RECORD", "ROLLBACK": "ROLLBACK"}

            def call(action, *, attempt="ci-p3-1", authority_override=None,
                     stage_override=None, read_override=None,
                     desired_override="CURRENT", prior="NONE", receipt=None):
                reqsubject = dict(subject, attempt_ref=attempt)
                bridge.attempt = attempt
                req = {"kind": "envs.syntheticHostSourceRequest.v0", **reqsubject,
                       "action": action, "proposed_q": q,
                       "requested_store": None if action == "READ" else t0}
                rfact = facts("READ")
                rfact.update({k:req[k] for k in ("target_ref", "actor_ref",
                                                "work_ref", "attempt_ref")})
                sfact = facts(stages[action])
                sfact.update({k:req[k] for k in ("target_ref", "actor_ref",
                                                "work_ref", "attempt_ref")})
                auth = dict(access, attempt_ref=attempt)
                if authority_override is not None:
                    auth.update(authority_override)
                rg = g(reqsubject, "READ")
                if read_override is not None:
                    rg.update(read_override)
                sg = g(reqsubject, stages[action])
                if stage_override is not None:
                    sg.update(stage_override)
                return source_step(
                    req, binding_source=copy.deepcopy(binding),
                    proposals=proposals, targets=targets,
                    relation_project=relation_project, authority=auth,
                    read_grant=rg, stage_grant=None if action=="READ" else sg,
                    read_facts=rfact, change_facts=sfact, current_q=rev,
                    desired=(copy.deepcopy(desired) if desired_override=="CURRENT"
                             else desired_override),
                    previous=previous(prior), port=bridge, receipt=receipt,
                )

            def inert(outcome):
                assert outcome["effect"] == "FORBIDDEN"
                assert outcome["admission"] == "NOT_ADMITTED"
                assert outcome["accepted_q"] is None
                assert outcome["target_ready"] is False and outcome["merge_ready"] is False

            # The original P2 CI has T1 selected. P3 operates on THIS same real Port.
            original_snapshot = docker("exec", container, "/bin/bash", "-euc",
                                       "sha256sum /var/lib/rent/dev/codex/auth.json "
                                       "/var/lib/rent/dev/claude/ci-session-marker "
                                       "/work/repos/proof-marker")
            original_counts = (actual.selects, actual.records, actual.rollbacks)
            start_reads = actual.reads
            refused = call("READ", read_override={"permit": False},
                           desired_override=None, prior="UNKNOWN")
            assert refused["stage"] == "REFUSED_SOURCE_OR_AUTHORITY"
            inert(refused)
            assert actual.reads == start_reads
            read = call("READ", desired_override=None, prior="UNKNOWN",
                        authority_override={"change":False, "quiet":False,
                                            "single_writer":False, "recovery":False})
            assert read["stage"] == "SYNTHETIC_READ_OBSERVED"
            assert read["observation"]["store_path"] == t1
            inert(read)

            for override in ({"permit":False}, {"step":"RECORD"},
                             {"route_ref":"ci-invalid-route"}):
                bad = call("CHANGE", stage_override=override)
                assert bad["stage"] == "REFUSED_SOURCE_OR_AUTHORITY"
                inert(bad)
            assert (actual.selects, actual.records, actual.rollbacks) == original_counts
            effect = call("CHANGE")
            assert effect["stage"] == "SYNTHETIC_READBACK_CANDIDATE_NOT_SUCCESS", effect
            issued = effect["issued_receipt"]
            assert issued is actual._receiver_issued["ci-p3-1"][0]
            assert issued["preimage"] == t1 and issued["selected"] == t0
            assert actual.observe()["store_path"] == t0 and actual.selects == original_counts[0] + 1
            inert(effect)

            previous_confirmed = "CONFIRMED"
            no_record = call("RECORD",prior=previous_confirmed, receipt=issued,
                             authority_override={"record":False})
            assert no_record["stage"] == "REFUSED_SOURCE_OR_AUTHORITY"
            counts_before_record = (actual.selects,actual.records,actual.rollbacks)
            recorded = call("RECORD",prior=previous_confirmed, receipt=issued,
                            authority_override={"change":False,"quiet":False,
                                                "single_writer":False,"recovery":False})
            assert recorded["stage"] == "SYNTHETIC_RECORD_ONLY_CANDIDATE", recorded
            assert (actual.selects, actual.records, actual.rollbacks) == (
                counts_before_record[0],counts_before_record[1]+1,counts_before_record[2])
            inert(recorded)
            old = call("RECORD",prior=previous_confirmed, receipt=issued)
            assert old["stage"] == "REFUSED_PORT_PRECONDITION"
            assert actual.records == counts_before_record[1]+1
            denied = call("ROLLBACK",prior=previous_confirmed, receipt=issued,
                          authority_override={"rollback":False})
            assert denied["stage"] == "REFUSED_SOURCE_OR_AUTHORITY"
            roll_before=actual.rollbacks
            rolled = call("ROLLBACK",prior=previous_confirmed, receipt=issued,
                          authority_override={"change":False})
            assert rolled["stage"] == "SYNTHETIC_ROLLBACK_READBACK_REQUIRED", rolled
            assert actual.rollbacks == roll_before + 1 and actual.observe()["store_path"] == t1
            inert(rolled)
            duplicate = call("ROLLBACK",prior=previous_confirmed, receipt=issued)
            assert duplicate["stage"] in ("REFUSED_SOURCE_OR_AUTHORITY",
                                           "REFUSED_PORT_PRECONDITION")
            assert actual.rollbacks == roll_before + 1

            # The latest separate attempt loses its real Nix-change ACK.
            actual.fail_after_write=True
            before=actual.selects
            lost = call("CHANGE",attempt="ci-p3-2")
            assert lost["stage"] == "SYNTHETIC_EFFECT_UNKNOWN_NO_REPLAY", lost
            assert actual.selects == before+1 and actual.observe()["store_path"] == t0
            actual.fail_after_write=False
            retry = call("CHANGE",attempt="ci-p3-2")
            assert retry["stage"] in ("REFUSED_SOURCE_OR_AUTHORITY",
                                       "SYNTHETIC_EFFECT_UNKNOWN_NO_REPLAY")
            assert actual.selects == before+1
            reread = call("READ",attempt="ci-p3-2",prior="UNKNOWN",
                          desired_override=None)
            assert reread["stage"] == "SYNTHETIC_READ_OBSERVED"
            assert reread["observation"]["store_path"] == t0
            # CI-only teardown: never a receiver/caller recovery attempt.
            docker("exec",container,"/bin/nix-env","--profile",
                   "/nix/var/nix/profiles/rent-dev","--rollback")
            assert actual.observe()["store_path"] == t1
            assert docker("inspect","-f","{{.Image}}",container)==same_image
            assert docker("exec",container,"/bin/bash","-euc",
                          "sha256sum /var/lib/rent/dev/codex/auth.json "
                          "/var/lib/rent/dev/claude/ci-session-marker "
                          "/work/repos/proof-marker")==original_snapshot
            assert original_snapshot == state_before
            print("PASS: fixed envs #103 actual source_step -> windows #97 sole "
                  "receive_step -> SAME Docker/Nix Port; READ/CHANGE/RECORD/ROLLBACK, "
                  "stage-grant refusals, post-send UNKNOWN no replay, state/image retained")
        finally:
            del sys.path[:2]


if __name__ == "__main__":
    proof()
