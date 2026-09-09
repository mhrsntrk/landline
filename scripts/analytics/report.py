#!/usr/bin/env python3
"""Summarise the pulled analytics into the store funnel, revenue and usage.

    python3 scripts/analytics/pull.py && python3 scripts/analytics/report.py

The dedupe is the part that matters. Every daily instance RESTATES a trailing
window of dates, so concatenating each instance's TSV counts the same days
several times over — raw sums came out about 2.5x too high. For each date we
keep only the rows from the latest processing date that covers it.
"""
import collections
import csv
import glob
import os
import re

BASE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "data")

# Reports do not agree on what the first column is called: the funnel reports say
# `Date`, the subscription event report says `Event Date`. Matching only "Date"
# left the header row unrecognised, so it was folded in as data and `header`
# stayed None — every caller then died on an index lookup.
DATE_COLUMNS = ("Date", "Event Date")

# Reports whose row total lives somewhere other than `Counts`.
VALUE_COLUMNS = ("Counts", "Purchases", "Active Subscriptions", "Quantity")


def load(prefix):
    """Return (header, rows, dates) for one report's DAILY files."""
    header = None
    best = {}  # date -> (processing_date, rows)
    for path in sorted(glob.glob(os.path.join(BASE, f"{prefix}_*.tsv"))):
        # Non-daily instances get saved by hand as `..._MONTHLY_<date>.tsv` and this
        # glob matches them too. They restate the same events at a coarser
        # granularity, so blending them into a daily load double-counts — Installs
        # read 15 instead of 5 that way. Keep only `<prefix>_<date>.tsv`.
        suffix = os.path.basename(path)[len(prefix) + 1:]
        if not re.fullmatch(r"\d{4}-\d{2}-\d{2}\.tsv", suffix):
            continue
        processed = suffix[:10]
        buckets = collections.defaultdict(list)
        for row in csv.reader(open(path), delimiter="\t"):
            if not row:
                continue
            if row[0] in DATE_COLUMNS:
                header = row
                continue
            buckets[row[0]].append(row)
        for date, rows in buckets.items():
            if date not in best or processed > best[date][0]:
                best[date] = (processed, rows)
    rows = [row for date in sorted(best) for row in best[date][1]]
    return header, rows, sorted(best)


def value_column(header):
    return next((c for c in VALUE_COLUMNS if c in header), None)


def total(rows, header, keys, value=None):
    value = value or value_column(header)
    indexes = [header.index(k) for k in keys]
    value_index = header.index(value)
    counter = collections.Counter()
    for row in rows:
        counter[tuple(row[i] for i in indexes)] += int(float(row[value_index] or 0))
    return counter


def show(title, counter, limit=None):
    print(f"\n-- {title} --")
    for key, count in (counter.most_common(limit) if limit else counter.most_common()):
        print(f"  {' '.join(key):<30} {count}")


def by_date(rows, header, column, match, value=None):
    value = value or value_column(header)
    date_index = header.index(next(c for c in DATE_COLUMNS if c in header))
    column_index = header.index(column)
    value_index = header.index(value)
    counter = collections.Counter()
    for row in rows:
        if row[column_index] == match:
            counter[row[date_index]] += int(float(row[value_index] or 0))
    return counter


def funnel():
    header, rows, dates = load("App_Downloads_Standard")
    if not rows:
        print("no data — run pull.py first")
        return None

    print("=== DOWNLOADS ===")
    print(f"{dates[0]} .. {dates[-1]}")
    show("by type", total(rows, header, ["Download Type"]))
    show("by territory", total(rows, header, ["Territory"]))
    first_time = [r for r in rows if r[header.index("Download Type")] == "First-time download"]
    installs = sum(total(first_time, header, ["Date"]).values())
    print(f"\nfirst-time downloads: {installs}")

    header2, rows2, dates2 = load("App_Store_Discovery_and_Engagement_Standard")
    if not rows2:
        return installs
    print("\n=== DISCOVERY AND ENGAGEMENT ===")
    print(f"{dates2[0]} .. {dates2[-1]}")
    events = total(rows2, header2, ["Event"])
    impressions = events.get(("Impression",), 0)
    page_views = events.get(("Page view",), 0)
    show("by event", events)
    show("impressions by territory (top 10)", total(
        [r for r in rows2 if r[header2.index("Event")] == "Impression"], header2, ["Territory"]), limit=10)

    if impressions:
        print(f"\npage views / impression:      {page_views / impressions * 100:.1f}%")
        print(f"first-time downloads / impr:  {installs / impressions * 100:.2f}%")
    if page_views:
        print(f"first-time downloads / view:  {installs / page_views * 100:.1f}%")

    # Cumulative rates hide the shape. Reach on these apps moves in spikes that
    # evaporate within two days, so a single high day means nothing on its own.
    daily_impressions = by_date(rows2, header2, "Event", "Impression")
    daily_installs = by_date(rows, header, "Download Type", "First-time download")
    recent = sorted(set(daily_impressions) | set(daily_installs))[-14:]
    if recent:
        print("\n-- last 14 dates --")
        for date in recent:
            print(f"  {date}  impressions {daily_impressions[date]:>5}   first-time {daily_installs[date]:>3}")
    return installs


def purchases():
    header, rows, dates = load("App_Store_Purchases_Standard")
    print("\n=== PURCHASES ===")
    if not rows:
        print("  no instances — either nothing sold, or Apple's privacy volume gate")
        return
    # Apple reports these as row totals, not per-unit prices, so they sum directly.
    sales = sum(float(r[header.index("Sales in USD")] or 0) for r in rows)
    proceeds = sum(float(r[header.index("Proceeds in USD")] or 0) for r in rows)
    count = sum(int(float(r[header.index("Purchases")] or 0)) for r in rows)
    print(f"{dates[0]} .. {dates[-1]}")
    print(f"  {count} purchases, sales ${sales:.2f}, proceeds ${proceeds:.2f}")
    show("by product", total(rows, header, ["Content Name"]))
    show("by territory", total(rows, header, ["Territory"]))
    # Volumes are low enough that every row is worth seeing; $0.00 rows are trial
    # starts, and reading them as sales is the easy mistake.
    print("\n-- every purchase row --")
    for row in rows:
        print(f"  {row[0]}  {row[header.index('Content Name')]:<24} x{row[header.index('Purchases')]:<3}"
              f" sales ${float(row[header.index('Sales in USD')] or 0):>7.2f}"
              f" proceeds ${float(row[header.index('Proceeds in USD')] or 0):>7.2f}"
              f"  {row[header.index('Territory')]}")


def subscriptions():
    header, rows, dates = load("App_Store_Subscription_State_Report_Standard")
    print("\n=== SUBSCRIPTION STATE ===")
    if not rows:
        print("  no instances — no subscriptions, or the privacy volume gate")
        return
    # The state report restates every live subscription every day, so only the
    # newest date is a current picture; summing the file counts one payer many times.
    latest = dates[-1]
    date_index = header.index("Date")
    today = [r for r in rows if r[date_index] == latest]
    print(f"as of {latest}")
    show("by state", total(today, header, ["State Metric"]))
    show("by product", total(today, header, ["Subscription Name"]))
    reasons = total([r for r in today if r[header.index("Cancellation Reason")]],
                    header, ["Cancellation Reason"])
    if reasons:
        show("cancellation reasons", reasons)


def subscription_events():
    """Trial starts vs conversions vs churn — the paywall's actual funnel.

    This is the report whose first column is `Event Date` rather than `Date`; it
    was unreadable until `load()` learned about that.
    """
    header, rows, dates = load("App_Store_Subscription_Event_Report_Standard")
    print("\n=== SUBSCRIPTION EVENTS ===")
    if not rows:
        print("  no instances — no subscriptions, or the privacy volume gate")
        return
    print(f"{dates[0]} .. {dates[-1]}")
    show("by group", total(rows, header, ["Event Group"]))
    show("by event", total(rows, header, ["Event Name"]))
    date_index = header.index("Event Date")
    print("\n-- every event --")
    for row in rows:
        print(f"  {row[date_index]}  {row[header.index('Event Name')]:<32}"
              f" {row[header.index('Subscription Name')]:<20} {row[header.index('Territory')]}")


def usage():
    header, rows, dates = load("App_Store_Installation_and_Deletion_Standard")
    print("\n=== INSTALLS AND DELETES ===")
    if not rows:
        print("  no daily instances — Apple withholds APP_USAGE below a privacy threshold")
        return
    events = total(rows, header, ["Event"])
    show(f"{len(dates)} day(s) of data: {dates[0]} .. {dates[-1]}", events)
    if len(dates) < 14:
        print("\n  too few days to read retention from — do not compute a delete rate yet")


def main():
    if funnel() is None:
        return
    purchases()
    subscriptions()
    subscription_events()
    usage()


if __name__ == "__main__":
    main()
