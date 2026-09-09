#!/usr/bin/env python3
"""Download App Store Connect analytics report instances to ./data.

    python3 scripts/analytics/pull.py            # ongoing series (2026-09-09 onward, created pre-launch)
    python3 scripts/analytics/pull.py --snapshot # whatever Apple holds from before that

Fetching also resets Apple's 30-day inactivity timer on the ONGOING request —
if nobody pulls for a month Apple stops it and the series ends, so run this
periodically even when nobody is reading the numbers.
"""
import os
import sys

import asc

# Both requests were created 2026-09-09, while 1.0 was still WAITING_FOR_REVIEW,
# so unlike Tramontana this app loses no launch window. Apple starts an ONGOING
# request at its creation date and never backfills, so do not replace this one
# to "start clean" — that discards the series.
ONGOING_REQUEST = "2b0f2739-76e1-4465-80f2-7f5bcedc614b"

# One-time snapshot: nothing predates the request here, so this is expected to
# stay empty until the app has history of its own.
SNAPSHOT_REQUEST = "55f42de6-5bb5-45cd-a004-a06407b019ed"

WANTED = [
    "App Store Discovery and Engagement Standard",
    "App Downloads Standard",
    # Landline is free with no in-app purchases, so these three should stay
    # empty. They are listed anyway so that the day anything is sold the series
    # already exists rather than starting from that date.
    "App Store Purchases Standard",
    "App Store Subscription Event Report Standard",
    "App Store Subscription State Report Standard",
    # Both of these return zero instances until the app clears Apple's privacy
    # threshold. That is a volume gate, not a misconfiguration — re-requesting
    # them changes nothing. Retention is unmeasurable until they fill.
    "App Store Installation and Deletion Standard",
    "App Sessions Standard",
]

BASE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "data")


def reports(request_id):
    out = []
    url = f"/v1/analyticsReportRequests/{request_id}/reports?limit=200"
    while url:
        page = asc.get(url)
        out += page["data"]
        url = page.get("links", {}).get("next")
    return out


def download(report, prefix):
    instances = asc.get(f"/v1/analyticsReports/{report['id']}/instances?limit=200")["data"]
    written = 0
    for instance in instances:
        attrs = instance["attributes"]
        if attrs["granularity"] != "DAILY":
            continue
        target = os.path.join(BASE, f"{prefix}_{attrs['processingDate']}.tsv")
        if os.path.exists(target):
            continue
        segments = asc.get(f"/v1/analyticsReportInstances/{instance['id']}/segments")["data"]
        if not segments:
            continue
        text = "\n".join(asc.fetch_gz(s["attributes"]["url"]) for s in segments)
        with open(target, "w") as handle:
            handle.write(text)
        written += 1
    return len(instances), written


def main():
    request_id = SNAPSHOT_REQUEST if "--snapshot" in sys.argv else ONGOING_REQUEST
    os.makedirs(BASE, exist_ok=True)

    # A request Apple has stopped keeps answering, it just never gains new instances —
    # so say it out loud rather than letting the series quietly flatline.
    request = asc.get(f"/v1/analyticsReportRequests/{request_id}")["data"]
    if request["attributes"].get("stoppedDueToInactivity"):
        print(f"WARNING: request {request_id} was STOPPED by Apple for inactivity.")
        print("         The gap cannot be recovered; a new request starts from its creation date.")

    by_name = {}
    for report in reports(request_id):
        by_name.setdefault(report["attributes"]["name"], []).append(report)

    for name in WANTED:
        found = by_name.get(name, [])
        if not found:
            print(f"{name}: not offered for this app")
            continue
        for report in found:
            total, new = download(report, name.replace(" ", "_"))
            print(f"{name}: {total} instances, {new} new file(s)")


if __name__ == "__main__":
    main()
