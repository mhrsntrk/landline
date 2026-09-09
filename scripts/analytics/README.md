# App Store analytics

`ascelerate` has no analytics command, so these hit the App Store Connect API
directly using the key already at `~/.ascelerate/config.json`.

```bash
cd scripts/analytics
python3 pull.py            # ongoing series (2026-09-09 onward, pre-launch)
python3 pull.py --snapshot # whatever Apple holds from before that
python3 report.py          # deduped funnel summary
```

`data/` is gitignored — it is a local cache of Apple's TSVs.

## Read this before trusting a number

**The requests were created 2026-09-09, while 1.0 was still WAITING_FOR_REVIEW.**
Nothing is lost: the ongoing series starts before the first download, which is
the opposite of what happened to Tramontana. The snapshot request is expected to
stay empty — there is no history predating it.

**Backfill is slow.** A freshly created request has zero instances for days. An
empty report on day one is not a failure.

**The report request dies if nobody reads it.** Apple stops an ONGOING request
after 30 days without a fetch. Running `pull.py` resets that timer, and it warns
if Apple has already stopped the request. A new request cannot recover the gap.
Pull at least monthly even while the numbers are all zero.

**Daily instances restate a trailing window of dates.** Concatenating every
instance triple-counts. `report.py` keeps, per date, only the rows from the
newest processing date that covers it. Raw sums ran about 2.5x high on the Bino
apps.

**Some reports stay empty at low volume.** `App Sessions Standard` and `App
Store Installation and Deletion Standard` return zero instances until the app
clears Apple's privacy threshold. That is a volume gate, not a configuration
mistake — requesting them again changes nothing, and retention is unmeasurable
until they fill.

**The three commerce reports will never fill.** Landline is free with no
in-app purchases. They are in `WANTED` so the series already exists the day that
changes; the numbers to read here are downloads and discovery.

**The JWT is signed by hand.** The key is ES256 and `pyjwt` is not installed on
this machine; `cryptography` is. `asc.py` builds the header and payload, signs
with `ec.ECDSA(SHA256)`, then converts the DER signature to the raw r||s form
Apple wants (32 bytes each). Do not swap in a library without checking that.

## Ids

App `com.landlineclient.app`, Apple ID `6808344753`.

    ONGOING           2b0f2739-76e1-4465-80f2-7f5bcedc614b
    ONE_TIME_SNAPSHOT 55f42de6-5bb5-45cd-a004-a06407b019ed

`asc.py` and `report.py` are copies of the ones in
`tramontana/scripts/analytics`; only `pull.py` differs — the two request ids and
the report list.
