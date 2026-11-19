#!/usr/bin/env python3
"""Featuring nominations via the App Store Connect API.

`ascelerate` has no nomination command, so this drives /v1/nominations directly
using the ES256 signer that already lives next door in scripts/analytics.

    python3 nominate.py list                    # every nomination, all states
    python3 nominate.py show <id>
    python3 nominate.py create nomination-1.9.json     # creates a DRAFT
    python3 nominate.py update <id> nomination-1.9.json
    python3 nominate.py submit <id>             # the only irreversible step
    python3 nominate.py delete <id>

`create` always writes `submitted: false`. Submitting is a separate, explicit
command because a submitted nomination goes to Apple's editorial team and
cannot be recalled.
"""
import json, os, sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "analytics"))
import asc  # noqa: E402

STATES = ("DRAFT", "SUBMITTED", "ARCHIVED")
TYPES = ("APP_LAUNCH", "APP_ENHANCEMENTS", "NEW_CONTENT")


def load(path):
    with open(path) as fh:
        spec = json.load(fh)
    if spec["type"] not in TYPES:
        sys.exit(f"type must be one of {TYPES}, got {spec['type']!r}")
    # Undocumented server caps. Apple returns PARAMETER_ERROR.INVALID past these,
    # so check locally rather than burning a round trip on a long draft.
    for field, cap in (("description", 1000), ("notes", 500)):
        if len(spec.get(field, "")) > cap:
            sys.exit(f"{field} is {len(spec[field])} chars, cap is {cap}")

    attrs = {
        "name": spec["name"],
        "type": spec["type"],
        "description": spec["description"],
        "publishStartDate": spec["publishStartDate"],
        # Never submit from a file. `submit` is its own command on purpose.
        "submitted": False,
    }
    # PATCH rejects a body carrying neither `submitted` nor `archived`, so the
    # hardcoded false above doubles as the required field on update.
    for key in ("publishEndDate", "notes", "locales", "deviceFamilies",
                "supplementalMaterialsUris", "hasInAppEvents",
                "preOrderEnabled", "launchInSelectMarketsFirst"):
        if key in spec:
            attrs[key] = spec[key]

    rels = {"relatedApps": {"data": [{"type": "apps", "id": str(a)}
                                     for a in spec["relatedApps"]]}}
    if spec.get("supportedTerritories"):
        rels["supportedTerritories"] = {
            "data": [{"type": "territories", "id": t}
                     for t in spec["supportedTerritories"]]
        }
    return {"data": {"type": "nominations", "attributes": attrs, "relationships": rels}}


def summarize(n):
    a = n["attributes"]
    window = a.get("publishStartDate", "?")
    if a.get("publishEndDate"):
        window += " .. " + a["publishEndDate"]
    print(f"{n['id']}  {a.get('state','?'):9} {a.get('type','?'):17} {a.get('name','')}")
    print(f"    window {window}")
    if a.get("submittedDate"):
        print(f"    submitted {a['submittedDate']}")


def cmd_list():
    found = 0
    for state in STATES:
        # filter[state] is mandatory on this endpoint, so query each state.
        d = asc.get(f"/v1/nominations?filter[state]={state}&limit=200")
        for n in d.get("data", []):
            summarize(n)
            found += 1
    if not found:
        print("no nominations")


def cmd_show(nid):
    d = asc.get(f"/v1/nominations/{nid}")
    print(json.dumps(d["data"], indent=2))


def cmd_create(path):
    body = load(path)
    d = asc.post("/v1/nominations", body)
    print("created DRAFT (not submitted to Apple)")
    summarize(d["data"])
    print(f"\nsubmit with:  python3 {sys.argv[0]} submit {d['data']['id']}")


def cmd_update(nid, path):
    body = load(path)
    body["data"]["id"] = nid
    # PATCH 500s if relationships ride along, even unchanged ones. Attributes
    # only; re-point relatedApps or territories by recreating the nomination.
    body["data"].pop("relationships", None)
    d = asc.patch(f"/v1/nominations/{nid}", body)
    summarize(d["data"])


def cmd_submit(nid):
    d = asc.get(f"/v1/nominations/{nid}")
    a = d["data"]["attributes"]
    print(f"About to submit to Apple's editorial team:\n  {a['name']}\n  {a['type']}  {a.get('publishStartDate')}")
    if input("type SUBMIT to confirm: ").strip() != "SUBMIT":
        sys.exit("aborted")
    r = asc.patch(f"/v1/nominations/{nid}",
                  {"data": {"type": "nominations", "id": nid,
                            "attributes": {"submitted": True}}})
    summarize(r["data"])


def cmd_delete(nid):
    asc.send("DELETE", f"/v1/nominations/{nid}", None)
    print(f"deleted {nid}")


if __name__ == "__main__":
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    cmd, rest = sys.argv[1], sys.argv[2:]
    {"list": cmd_list, "show": cmd_show, "create": cmd_create,
     "update": cmd_update, "submit": cmd_submit, "delete": cmd_delete}[cmd](*rest)
