# Featuring nominations

Apple's editorial team picks App of the Day, Today tab stories, collections and
Editors' Choice from nominations developers file themselves. `ascelerate` has no
command for it, so `nominate.py` drives the App Store Connect API using the
ES256 signer in `../analytics/asc.py`.

```bash
cd scripts/featuring
python3 nominate.py list
python3 nominate.py create nomination-1.5.json    # DRAFT, not sent to Apple
python3 nominate.py update <id> nomination-1.5.json
python3 nominate.py submit <id>                   # irreversible, prompts to confirm
python3 nominate.py delete <id>
```

Nomination content lives in a JSON file so it can be reviewed and diffed before
anything reaches Apple. `create` and `update` always write `submitted: false`;
submitting is a separate command that asks for typed confirmation, because a
submitted nomination goes to the editorial team and cannot be recalled.

## Lead time

Apple asks for a **minimum of three weeks** before the publish date, and says up
to three months for wider consideration. A Today tab story wants roughly eight
weeks, because Apple writes the copy, cuts video and localizes it. Collections
move faster than stories. Nominating a version that has already shipped is
pointless: pick the next release and file against its window.

## Things that will bite

**The endpoint is `/v1/nominations`.** The documentation page is titled
"Featuring nominations" and `/v1/featuringNominations` 404s. Do not trust the
doc slug for the path.

**`filter[state]` is mandatory on GET.** Without it Apple returns
`PARAMETER_ERROR.REQUIRED`. Valid values are `DRAFT`, `SUBMITTED`, `ARCHIVED`,
so listing everything means three requests. Valid `filter[type]` values are
`APP_LAUNCH`, `APP_ENHANCEMENTS`, `NEW_CONTENT`.

**`name` caps at 60 characters** (found on Landline, 2026-11-19). **`description` caps at 1000 characters and `notes` at 500.** Neither cap is in
the documentation; the server rejects with `PARAMETER_ERROR.INVALID` and names
the field. `nominate.py` checks both locally before spending the round trip.

**`submitted` is a required attribute on create,** not an optional flag. Passing
`true` files it immediately, so it is hardcoded to `false` in `load()`.

**Apple rewrites what you send.** Publish dates come back normalized to 11:00Z
and locale codes come back uppercased (`en-US` becomes `EN-US`). Both are
cosmetic; do not chase them.

**Included relationships page at 10 by default.** Reading back
`?include=supportedTerritories` looked like it had silently dropped USA from an
11 territory list. It had not. Pass `limit[supportedTerritories]=50` or read
`relationships.supportedTerritories.meta.paging.total`.

**The relationship sub-resources are not readable.**
`/v1/nominations/<id>/relatedApps` returns 403 `FORBIDDEN_ERROR`, "has no
allowed operations defined". Use `?include=relatedApps` on the nomination
instead.

**Role requirement.** The API key needs Account Holder, Admin, App Manager or
Marketing. Same key as the analytics scripts, at `~/.ascelerate/config.json`.
