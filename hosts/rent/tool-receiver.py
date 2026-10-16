#!/usr/bin/env python3
"""SOURCE-only rent Tool receiver: injected disposable Docker/Nix transport.

NOT installed, invoked at logon, an SSH/HTTP daemon, an admitted D issuer or
a product update route. The CI runner must inject independent, explicit
synthetic grants and a disposable single-target transport. This module uses
only Python stdlib and never invokes Docker, Nix, secret APIs, or the Host itself.
All actual Nix selector effects occur through the CI transport only.
"""
from __future__ import annotations

import importlib.util
import re
from pathlib import Path
from typing import Any

STORE = re.compile(r"/nix/store/[0-9a-z]{32}-[^/\s]+\Z")
STAGES = {"READ": "READ", "CHANGE": "TOOL_CHANGE",
          "RECORD": "RECORD", "ROLLBACK": "ROLLBACK"}
SUBJECT = ("target_ref", "host_ref", "unit_ref", "scope",
           "actor_ref", "work_ref", "attempt_ref", "route_ref")
REQUEST_FIELDS = {"kind", "action", "target_ref", "host_ref", "unit_ref",
                  "scope", "actor_ref", "work_ref", "attempt_ref",
                  "route_ref", "proposed_q", "requested_store"}
GRANT_FIELDS = {"kind", "target_ref", "host_ref", "unit_ref", "scope",
                "actor_ref", "work_ref", "attempt_ref", "route_ref",
                "step", "permit", "issuer_fixture"}
BOUND_FIELDS = {"kind", "binding", "desired", "current_q", "previous_state",
                "read_grant", "quiet", "single_writer", "recovery",
                "fixture_issuer"}
DESIRED_FIELDS = {"kind", "target_ref", "proposed_q", "material",
                  "revision", "store_path"}
OBS_FIELDS = {"kind", "target_ref", "host_ref", "unit_ref", "scope",
              "state", "store_path", "generation", "identity",
              "fresh", "closure_valid"}
IDENTITY_FIELDS = {"base", "tool", "launch", "config_binding", "state_contract"}


class Refused(ValueError):
    pass


def demand(ok: bool, why: str) -> None:
    if not ok:
        raise Refused(why)


def exact(value: Any, fields: set[str], why: str) -> dict[str, Any]:
    demand(type(value) is dict and set(value) == fields, why)
    return value


def result(stage: str, *, observation=None, receipt=None,
           synthetic_effect=None) -> dict[str, Any]:
    return {
        "kind": "windows.syntheticRentReceiverVerdict.v0",
        "stage": stage, "observation": observation, "issued_receipt": receipt,
        "synthetic_effect": synthetic_effect, "admission": "NOT_ADMITTED",
        "accepted_q": None, "target_noop": "UNPROVEN",
        "production_effect": "FORBIDDEN", "target_ready": False,
        "merge_ready": False,
    }


def _grant(value: Any, request: dict[str, Any], stage: str) -> None:
    g = exact(value, GRANT_FIELDS, "grant shape")
    demand(g["kind"] == "envs.syntheticStageGrant.v0"
           and g["step"] == stage and type(g["permit"]) is bool
           and g["permit"] is True
           and g["issuer_fixture"] == "ci-independent-source-issuer"
           and all(g[key] == request[key] for key in SUBJECT),
           "stage/subject/route/issuer/permit not independently bound")


def _preflight(request: Any, grant: Any, bound: Any, transport: Any):
    req = exact(request, REQUEST_FIELDS, "request shape")
    demand(req["kind"] == "envs.syntheticHostSourceRequest.v0"
           and req["action"] in STAGES, "unknown SOURCE action")
    for key in ("actor_ref", "work_ref", "attempt_ref", "route_ref"):
        demand(type(req[key]) is str and req[key].startswith("ci-")
               and len(req[key]) <= 100, "receiver subject must be CI-only")
    b = exact(bound, BOUND_FIELDS, "bound-source shape")
    demand(b["kind"] == "windows.syntheticBoundSource.v0"
           and b["fixture_issuer"] == "ci-independent-source-issuer",
           "not an independently supplied SOURCE binding")
    bind = exact(b["binding"], {"kind", "admission", "target_ref",
              "host_ref", "parent_ref", "unit_ref", "scope", "selector",
              "desired_output", "proposed_q", "material", "hosts",
              "relations", "identity"}, "exact F1 shape")
    demand(bind.get("kind") == "envs.hostToolFunctionalBindingProposal.v0"
           and bind.get("admission") == "NOT_ADMITTED"
           and all(req[k] == bind[k] for k in
                   ("target_ref", "host_ref", "unit_ref", "scope"))
           and req["proposed_q"] == bind.get("proposed_q")
           and bind.get("selector") == "/nix/var/nix/profiles/rent-dev",
           "foreign F1 Host/Unit/q or attempted admission")
    # Reuse exactly the existing windows F1 material preflight, not a new
    # q hash or an assumed runner's global permission.
    spec = importlib.util.spec_from_file_location(
        "rent_proposed_source_preflight",
        Path(__file__).with_name("proposed-binding-proof.py"))
    demand(spec is not None and spec.loader is not None, "fixed F1 unavailable")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    demand(bind.get("material") == {
        "repository": "roccho-dev/windows", "source_commit": module.PIN,
        "flake_output": module.OUTPUT,
    } and bind.get("identity") == module.EXPECTED
           and bind.get("unit_ref") == "ci-rent-oci-unit-1",
           "not pinned immutable windows Tool SOURCE")
    import json
    canon = json.dumps({"target_ref": bind["target_ref"],
                        "material": bind["material"]},
                       sort_keys=True, separators=(",", ":"), ensure_ascii=True)
    q = "sha256:" + module.hashlib.sha256(canon.encode("utf-8")).hexdigest()
    demand(bind.get("proposed_q") == q and req["proposed_q"] == q,
           "fake PROPOSED q or foreign fixed Tool")
    rel = bind["relations"]
    demand(type(rel) is list and len([
        x for x in rel if type(x) is dict and x.get("kind") == "contains"
        and x.get("parent") == bind["parent_ref"]
        and x.get("child") == bind["host_ref"]
        and x.get("scope") == bind["scope"]]) == 1,
           "missing scoped Host containment relation")
    demand(type(transport) is not str
           and getattr(transport, "kind", None)
           == "windows.syntheticDisposableNixTransport.v0"
           and getattr(transport, "fixture_only", None) is True
           and all(callable(getattr(transport, name, None))
                   for name in ("observe", "validate_closure", "quiet",
                                "select", "record", "rollback",
                                "expected_producer_store")),
           "missing independently injected disposable Nix transport")
    _grant(b["read_grant"], req, "READ")
    _grant(grant, req, STAGES[req["action"]])
    demand(req["requested_store"] is None if req["action"] == "READ"
           else type(req["requested_store"]) is str
           and STORE.fullmatch(req["requested_store"]) is not None,
           "READ material or mutation store is unsupported")
    return req, b


def _observe(transport: Any, req: dict[str, Any]):
    o = exact(transport.observe(), OBS_FIELDS, "observation shape")
    demand(o["kind"] == "windows.syntheticRentObservation.v0"
           and all(o[k] == req[k] for k in
                   ("target_ref", "host_ref", "unit_ref", "scope"))
           and o["state"] in ("ABSENT", "SELECTED", "UNKNOWN")
           and type(o["fresh"]) is bool
           and type(o["closure_valid"]) is bool,
           "observed different or malformed Host/Unit")
    if o["state"] == "SELECTED":
        demand(type(o["store_path"]) is str
               and STORE.fullmatch(o["store_path"]) is not None
               and type(o["generation"]) is str and o["generation"].startswith("rent-dev-")
               and type(o["identity"]) is dict
               and set(o["identity"]) == IDENTITY_FIELDS,
               "selected Tool observation lacks valid generation/identity")
    else:
        demand(o["store_path"] is None and o["generation"] is None,
               "ABSENT/UNKNOWN observation claims a selected Tool")
        if o["state"] == "UNKNOWN":
            demand(o["identity"] is None, "UNKNOWN asserts full identity")
        else:
            demand(o["identity"] is None or
                   type(o["identity"]) is dict and set(o["identity"]) == IDENTITY_FIELDS,
                   "ABSENT identity ambiguous")
    return o


def _current_d(req, b, port):
    d = exact(b["desired"], DESIRED_FIELDS, "synthetic D shape")
    bind = b["binding"]
    demand(d["kind"] == "envs.syntheticDesired.v0"
           and d["target_ref"] == req["target_ref"]
           and d["proposed_q"] == bind["proposed_q"]
           and d["material"] == bind["material"]
           and type(d["revision"]) is str
           and d["revision"] == "ci-" + bind["proposed_q"][7:23]
           and b["current_q"] == d["revision"]
           and req["requested_store"] == d["store_path"]
           and type(d["store_path"]) is str
           and STORE.fullmatch(d["store_path"]) is not None,
           "missing exact current synthetic D/q selected store")
    # This expected T0 is independently supplied by the disposable Nix
    # producer transport, not by the request/desired object. q hashes
    # immutable material, and cannot by itself prove an arbitrary store path.
    expected = port.expected_producer_store()
    demand(type(expected) is str and STORE.fullmatch(expected) is not None
           and d["store_path"] == expected,
           "synthetic D Tool differs from Nix-built pinned Producer closure")
    return d


def _valid_receipt(port, receipt, req, revision, obs):
    entries = getattr(port, "_receiver_issued", None)
    issued = entries.get(req["attempt_ref"]) if type(entries) is dict else None
    demand(issued is not None and type(receipt) is dict
           and receipt is issued[0] and receipt == issued[1]
           and receipt["attempt"] == req["attempt_ref"]
           and receipt["issuer"] == issued[2]
           and receipt["revision"] == revision
           and receipt["selected"] == obs["store_path"]
           and receipt["generation"] == obs["generation"]
           and getattr(port, "_receiver_latest", None) == req["attempt_ref"],
           "missing, forged, old or non-current receiver-issued receipt")
    return issued


def receive_step(request: dict[str, Any], scoped_grant: dict[str, Any] | None,
                 bound_source: dict[str, Any], actual_target_transport: Any,
                 *, receipt: dict[str, Any] | None = None) -> dict[str, Any]:
    """One SOURCE step: the caller provides independently injected CI premises.

    Pre-send refusals return REFUSED_PRE_EFFECT; a write may have happened
    after transport was invoked, so all later uncertainty is UNKNOWN, no retry.
    """
    sent = False
    try:
        req, b = _preflight(request, scoped_grant, bound_source, actual_target_transport)
        action = req["action"]
        port = actual_target_transport
        if action == "READ":
            # No D/current q/change/previous-E prerequisite; unauthorized READ
            # was rejected before the very first transport.observe() call.
            obs = _observe(port, req)
            return result("READ_OBSERVED" if obs["state"] != "UNKNOWN"
                          else "READ_UNKNOWN", observation=obs)
        desired = _current_d(req, b, port)
        demand(b["previous_state"] in ("NONE", "CONFIRMED", "UNKNOWN"),
               "unknown previous effect shape")
        obs = _observe(port, req)
        demand(obs["state"] != "UNKNOWN" and obs["fresh"] and obs["closure_valid"],
               "fresh bounded O is unavailable")
        if action == "CHANGE":
            demand(b["previous_state"] == "NONE"
                   and b["quiet"] is True and b["single_writer"] is True
                   and b["recovery"] is True,
                   "unresolved prior effect or unsafe change quiet/writer")
            demand(obs["identity"] is not None
                   and all(obs["identity"][k] == b["binding"]["identity"][k]
                           for k in ("base", "launch", "config_binding",
                                     "state_contract")),
                   "B/launch/config/state require a different plan")
            demand(obs["store_path"] != desired["store_path"],
                   "same Tool geometry does not prove NOOP")
            # A sent attempt is consumed BEFORE the irreversible Nix call.
            # Do not erase it on rollback, and do not allow a blind retry when
            # the write's acknowledgement disappears before readback.
            attempted = getattr(port, "_receiver_change_started", None)
            if attempted is None:
                attempted = port._receiver_change_started = set()
            demand(req["attempt_ref"] not in attempted
                   and req["attempt_ref"] not in getattr(port, "_receiver_issued", {})
                   and req["attempt_ref"] not in getattr(port, "_receiver_recorded", set()),
                   "duplicate or consumed mutating attempt not allowed")
            demand(port.quiet() is True, "continuous CI quiet not proven")
            demand(port.validate_closure(desired["store_path"]) is True,
                   "exact SOURCE Tool closure not valid")
            attempted.add(req["attempt_ref"])
            sent = True
            port.select(desired["store_path"])
            new_o = _observe(port, req)
            if (new_o["state"] != "SELECTED"
                    or new_o["store_path"] != desired["store_path"]
                    or not new_o["fresh"] or not new_o["closure_valid"]):
                return result("UNKNOWN_AFTER_SEND_NO_REPLAY")
            # Issuer state exists only in THIS disposable transport process.
            # Reconstructing a receiver/port after loss cannot reproduce it.
            if getattr(port, "_receiver_issued", None) is None:
                port._receiver_issued = {}
            demand(req["attempt_ref"] not in port._receiver_issued,
                   "duplicate attempt after write")  # caught as UNKNOWN
            issue = {
                "kind": "windows.syntheticRentReceipt.v0",
                "attempt": req["attempt_ref"], "issuer": b["fixture_issuer"],
                "revision": desired["revision"], "effect": "SYNTHETIC_ONLY",
                "selected": desired["store_path"], "preimage": obs["store_path"],
                "generation": new_o["generation"],
            }
            import copy
            port._receiver_issued[req["attempt_ref"]] = (
                issue, copy.deepcopy(issue), b["fixture_issuer"])
            port._receiver_latest = req["attempt_ref"]
            return result("TOOL_CHANGE_READBACK_CANDIDATE",
                          observation=new_o, receipt=issue,
                          synthetic_effect="ONE_DISPOSABLE_NIX_SELECTION")
        demand(b["previous_state"] == "CONFIRMED",
               "record or rollback requires settled prior effect")
        _valid_receipt(port, receipt, req, desired["revision"], obs)
        if action == "RECORD":
            record_started = getattr(port, "_receiver_record_started", None)
            if record_started is None:
                record_started = port._receiver_record_started = set()
            demand(req["attempt_ref"] not in record_started
                   and req["attempt_ref"] not in getattr(port, "_receiver_recorded", set()),
                   "duplicate or unresolved RECEIPT/RECORD")
            # A transport may store RECORD before an ACK is delivered.
            # Preserve this attempt even if the transport throws/returns UNKNOWN.
            record_started.add(req["attempt_ref"])
            sent = True
            accepted = port.record(receipt)
            # After sending RECORD, an absent/ambiguous acknowledgement is
            # UNKNOWN, never a falsely recorded or pre-effect refused step.
            if accepted != "CI_ONLY_RECORD_NO_TARGET_LEDGER":
                return result("UNKNOWN_AFTER_SEND_NO_REPLAY")
            if getattr(port, "_receiver_recorded", None) is None:
                port._receiver_recorded = set()
            port._receiver_recorded.add(req["attempt_ref"])
            return result("RECORD_ONLY_CANDIDATE",
                          observation=obs, synthetic_effect="ONE_CI_ONLY_RECORD")
        demand(action == "ROLLBACK" and b["quiet"] is True
               and b["single_writer"] is True and b["recovery"] is True
               and receipt["preimage"] is not None
               and STORE.fullmatch(receipt["preimage"]) is not None
               and port.quiet() is True
               and port.validate_closure(receipt["preimage"]) is True,
               "missing rollback grant, quiet or genuine preimage")
        # A rollback invocation may change Nix before its ACK arrives.
        # Consume this exact attempt BEFORE transport; an UNKNOWN result may
        # leave the original issued receipt/selected T intact, so receipt
        # validation alone cannot prevent an equivalent blind retry.
        rollback_started = getattr(port, "_receiver_rollback_started", None)
        if rollback_started is None:
            rollback_started = port._receiver_rollback_started = set()
        demand(req["attempt_ref"] not in rollback_started,
               "duplicate or unknown rollback attempt cannot be resent")
        rollback_started.add(req["attempt_ref"])
        sent = True
        port.rollback(receipt["preimage"])
        after = _observe(port, req)
        if (after["state"] != "SELECTED" or after["store_path"] != receipt["preimage"]
                or not after["fresh"] or not after["closure_valid"]):
            return result("UNKNOWN_AFTER_SEND_NO_REPLAY")
        del port._receiver_issued[req["attempt_ref"]]
        port._receiver_latest = None
        return result("ROLLBACK_READBACK_REQUIRED", observation=after,
                      synthetic_effect="ONE_DISPOSABLE_NIX_ROLLBACK")
    except (Refused, ValueError, TypeError, KeyError, AttributeError):
        return result("UNKNOWN_AFTER_SEND_NO_REPLAY" if sent else "REFUSED_PRE_EFFECT")
    except Exception:
        return result("UNKNOWN_AFTER_SEND_NO_REPLAY" if sent else "REFUSED_PRE_EFFECT")
