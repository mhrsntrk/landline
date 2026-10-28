#!/usr/bin/env python3
"""Minimal App Store Connect API client (ES256 JWT signed by hand)."""
import json, time, base64, sys, urllib.request, urllib.error, gzip, io
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec, utils as asym_utils

CFG = json.load(open("/Users/mhrsntrk/.ascelerate/config.json"))
KEY = serialization.load_pem_private_key(open(CFG["privateKeyPath"], "rb").read(), password=None)


def b64u(b):
    return base64.urlsafe_b64encode(b).rstrip(b"=")


def token():
    now = int(time.time())
    header = {"alg": "ES256", "kid": CFG["keyId"], "typ": "JWT"}
    payload = {"iss": CFG["issuerId"], "iat": now, "exp": now + 900, "aud": "appstoreconnect-v1"}
    signing_input = b64u(json.dumps(header, separators=(",", ":")).encode()) + b"." + \
                    b64u(json.dumps(payload, separators=(",", ":")).encode())
    der = KEY.sign(signing_input, ec.ECDSA(hashes.SHA256()))
    r, s = asym_utils.decode_dss_signature(der)
    raw = r.to_bytes(32, "big") + s.to_bytes(32, "big")
    return (signing_input + b"." + b64u(raw)).decode()


TOK = token()


def get(path, params=None):
    url = path if path.startswith("http") else "https://api.appstoreconnect.apple.com" + path
    if params:
        url += ("&" if "?" in url else "?") + urllib.parse.urlencode(params)
    req = urllib.request.Request(url, headers={"Authorization": "Bearer " + TOK})
    try:
        with urllib.request.urlopen(req) as r:
            return json.loads(r.read())
    except urllib.error.HTTPError as e:
        body = e.read().decode()
        print(f"HTTP {e.code} on {url}\n{body}", file=sys.stderr)
        raise


def send(method, path, payload):
    url = path if path.startswith("http") else "https://api.appstoreconnect.apple.com" + path
    body = json.dumps(payload).encode() if payload is not None else None
    req = urllib.request.Request(url, data=body, method=method,
                                 headers={"Authorization": "Bearer " + TOK,
                                          "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req) as r:
            raw = r.read()
            return json.loads(raw) if raw else {}
    except urllib.error.HTTPError as e:
        print(f"HTTP {e.code} on {method} {url}\n{e.read().decode()}", file=sys.stderr)
        raise


def post(path, payload):
    return send("POST", path, payload)


def patch(path, payload):
    return send("PATCH", path, payload)


def fetch_gz(url, attempts=4):
    """Download a report segment.

    Apple's asset host drops connections partway through a multi-report pull
    often enough that one unlucky segment used to kill the whole run, so this
    retries the transport errors. HTTP errors are not retried: those are real
    answers.
    """
    for attempt in range(attempts):
        try:
            with urllib.request.urlopen(urllib.request.Request(url)) as r:
                data = r.read()
            break
        except urllib.error.HTTPError:
            raise
        except Exception as error:
            if attempt == attempts - 1:
                raise
            wait = 2 ** attempt
            print(f"segment fetch failed ({error}), retrying in {wait}s", file=sys.stderr)
            time.sleep(wait)

    try:
        return gzip.decompress(data).decode()
    except Exception:
        return data.decode()


import urllib.parse  # noqa: E402

if __name__ == "__main__":
    print(json.dumps(get(sys.argv[1]), indent=2)[:8000])
