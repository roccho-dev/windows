#!/usr/bin/env python3
"""CI-only PROPOSED D/q preflight for existing rent B-only native-proof.sh.

Data only. Does not run nix-env, read a Target, grant access, or issue a receipt.
The shell SOURCE SUT must perform actual Docker/Nix observations and re-check.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
from pathlib import Path

PIN = "355b038bcbe2b24a8ad0121f79b7cc4c72b76b3f"
OUTPUT = "packages.x86_64-linux.rent-tool-profile"
STORE = re.compile(r"/nix/store/[0-9a-z]{32}-[^/\s]+\Z")
PROFILE = "/nix/var/nix/profiles/rent-dev"
EXPECTED = {
    "base": "ci:rent-base-only-B0", "tool": "ci:rent-tool-T0",
    "launch": "ci:rent-start-S0", "config_binding": "ci:rent-binding-C0",
    "state_contract": "ci:rent-state-K0",
}


def refuse(message):
    raise ValueError(message)


def read_only(observation):
    """A read is distinct from admission, previous E and change permission."""
    if observation == "selection=ABSENT proof=geometry-only":
        selection = "ABSENT"
    elif re.fullmatch(
        r"selection=SELECTED generation=rent-dev-[1-9][0-9]*-link "
        r"store=/nix/store/[0-9a-z]{32}-[^/\s]+ proof=geometry-only",
        observation,
    ):
        selection = "SELECTED"
    else:
        refuse("read observation is UNKNOWN or malformed")
    return {"kind": "ci-rent-bound-read.v0", "selection": selection,
            "admission": "NOT_ADMITTED", "effect": "FORBIDDEN",
            "target_noop": "UNPROVEN"}


def preflight(binding, *, candidate, expected_store, observation, q, host_ref, scope,
              previous, base, launch, config_binding, state_contract):
    if type(binding) is not dict or set(binding) != {
        "kind", "admission", "target_ref", "host_ref", "parent_ref",
        "unit_ref", "scope", "selector", "desired_output", "proposed_q",
        "material", "hosts", "relations", "identity",
    }:
        refuse("binding has unrecognized or missing SOURCE fields")
    if (binding["kind"] != "envs.hostToolFunctionalBindingProposal.v0"
            or binding["admission"] != "NOT_ADMITTED"
            or binding["target_ref"] != "pc7337-rent"
            or binding["selector"] != PROFILE
            or binding["desired_output"] != "rent-tool-profile"):
        refuse("binding attempted adoption or foreign Target/selector")
    mat = binding["material"]
    if (type(mat) is not dict
            or set(mat) != {"repository", "source_commit", "flake_output"}
            or mat != {"repository": "roccho-dev/windows",
                       "source_commit": PIN, "flake_output": OUTPUT}):
        refuse("Tool material is not immutable windows Producer")
    canon = json.dumps({"target_ref": binding["target_ref"], "material": mat},
                       sort_keys=True, separators=(",", ":"), ensure_ascii=True)
    expected_q = "sha256:" + hashlib.sha256(canon.encode()).hexdigest()
    if (binding["proposed_q"] != expected_q or q != expected_q
            or type(candidate) is not str or STORE.fullmatch(candidate) is None
            or candidate != expected_store):
        refuse("wrong q or real Nix Tool closure")
    if (host_ref != binding["host_ref"] or scope != binding["scope"]
            or binding["host_ref"] == binding["parent_ref"]
            or binding["unit_ref"] != "ci-rent-oci-unit-1"):
        refuse("wrong explicit scoped Host/Unit")
    if (type(binding["identity"]) is not dict or binding["identity"] != EXPECTED
            or base != EXPECTED["base"] or launch != EXPECTED["launch"]
            or config_binding != EXPECTED["config_binding"]
            or state_contract != EXPECTED["state_contract"]):
        refuse("I(D) and actual SOURCE B/launch/config/state facts differ")
    # The real immutable Relation projector is exercised independently by envs
    # on these same exact binding bytes; this script only checks the attested
    # shape before physical Nix selection.
    contains = [
        e for e in binding["relations"]
        if type(e) is dict and e.get("kind") == "contains"
        and e.get("scope") == scope and e.get("parent") == binding["parent_ref"]
        and e.get("child") == host_ref
    ] if type(binding["relations"]) is list else []
    if len(contains) != 1:
        refuse("scoped explicit contains is absent; manages is not authority")
    if previous != "NONE":
        refuse("prior effect unresolved: only independent READ is permitted")
    read = read_only(observation)
    if read["selection"] != "ABSENT":
        refuse("same-bound initial selection is no longer ABSENT; no blind retry")
    return {
        "kind": "ci-rent-bound-change-candidate.v0",
        "stage": "SYNTHETIC_PROPOSED_DQ_PREFLIGHT_ONLY",
        "target_ref": binding["target_ref"], "host_ref": host_ref,
        "unit_ref": binding["unit_ref"], "scope": scope,
        "proposed_q": expected_q, "candidate_store": candidate,
        "admission": "NOT_ADMITTED", "accepted_q": None,
        "target_noop": "UNPROVEN", "effect": "FORBIDDEN",
        "target_ready": False, "merge_ready": False,
    }


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("binding", type=Path)
    p.add_argument("--mode", choices=("read", "preflight"), required=True)
    p.add_argument("--observation", required=True)
    p.add_argument("--candidate")
    p.add_argument("--expected-store")
    p.add_argument("--q")
    p.add_argument("--host-ref")
    p.add_argument("--scope")
    p.add_argument("--previous", default="NONE")
    p.add_argument("--base")
    p.add_argument("--launch")
    p.add_argument("--config-binding")
    p.add_argument("--state-contract")
    args = p.parse_args()
    try:
        if args.mode == "read":
            result = read_only(args.observation)
        else:
            source = json.loads(args.binding.read_text(encoding="utf-8"))
            result = preflight(source, candidate=args.candidate,
                               expected_store=args.expected_store,
                               observation=args.observation, q=args.q,
                               host_ref=args.host_ref, scope=args.scope,
                               previous=args.previous, base=args.base,
                               launch=args.launch,
                               config_binding=args.config_binding,
                               state_contract=args.state_contract)
    except (ValueError, OSError, KeyError, TypeError) as err:
        print("SOURCE_PROPOSED_BINDING_REFUSED: " + str(err), file=sys.stderr)
        return 2
    print(json.dumps(result, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
