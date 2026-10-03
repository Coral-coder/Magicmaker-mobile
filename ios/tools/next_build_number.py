#!/usr/bin/env python3
"""Print the next TestFlight build number for a marketing version.

Build numbers restart at 1 for each new marketing version and climb by one per
build within it. The count is not stored anywhere in this repo, because the repo
is not the authority on it — App Store Connect is. It knows every build number it
has already accepted for 1.3.0, including ones uploaded by hand from Xcode, and
it is the thing that rejects a duplicate. So ask it.

That makes the number self-healing in the cases a counter is worst at: a re-run
of a failed job does not skip a number, a build uploaded outside CI does not
collide, and bumping MARKETING_VERSION resets the count with nothing to
remember.

Stdlib only, deliberately — `openssl` signs the token and `urllib` makes the
calls, so this needs nothing installed on the runner.
"""

import argparse
import base64
import json
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

API = "https://api.appstoreconnect.apple.com/v1"


def b64u(data: bytes) -> str:
    """base64url, unpadded — what JWS uses."""
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def der_to_jose(der: bytes, size: int = 32) -> bytes:
    """Convert an ECDSA signature from DER to the raw r||s form JWS wants.

    `openssl dgst -sign` emits DER: SEQUENCE { INTEGER r, INTEGER s }. JWS wants
    the two integers concatenated, each left-padded to the curve size. DER also
    prepends a zero byte to an integer whose top bit is set, so that has to come
    back off before padding.
    """
    if not der or der[0] != 0x30:
        raise ValueError("signature is not a DER sequence")
    i = 2
    if der[1] & 0x80:                      # long-form length
        i = 2 + (der[1] & 0x7F)
    out = b""
    for _ in range(2):
        if der[i] != 0x02:
            raise ValueError("expected a DER integer in the signature")
        length = der[i + 1]
        value = der[i + 2 : i + 2 + length].lstrip(b"\x00")
        if len(value) > size:
            raise ValueError("signature integer wider than the curve")
        out += value.rjust(size, b"\x00")
        i += 2 + length
    return out


def make_token(key_id: str, issuer_id: str, key_path: str) -> str:
    header = {"alg": "ES256", "kid": key_id, "typ": "JWT"}
    now = int(time.time())
    payload = {
        "iss": issuer_id,
        "iat": now,
        # Apple rejects anything over 20 minutes.
        "exp": now + 900,
        "aud": "appstoreconnect-v1",
    }
    signing_input = "{}.{}".format(
        b64u(json.dumps(header, separators=(",", ":")).encode()),
        b64u(json.dumps(payload, separators=(",", ":")).encode()),
    )
    result = subprocess.run(
        ["openssl", "dgst", "-sha256", "-sign", key_path],
        input=signing_input.encode(),
        capture_output=True,
    )
    if result.returncode != 0:
        raise SystemExit(
            "openssl could not sign with {}: {}".format(
                key_path, result.stderr.decode().strip()
            )
        )
    return "{}.{}".format(signing_input, b64u(der_to_jose(result.stdout)))


def get(path: str, token: str) -> dict:
    request = urllib.request.Request(
        API + path, headers={"Authorization": "Bearer " + token}
    )
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            return json.load(response)
    except urllib.error.HTTPError as error:
        body = error.read().decode(errors="replace")[:400]
        raise SystemExit(
            "App Store Connect returned {} for {}\n{}".format(error.code, path, body)
        )


def highest_build(builds: dict) -> int:
    """Largest whole-number build in the response, or 0 if there are none.

    Build numbers are strings and need not be integers — a hand-uploaded build
    could be "1.0.3". Those are skipped rather than guessed at; the worst case is
    starting a version's CI count at 1 alongside them, which App Store Connect
    accepts because "1" and "1.0.3" are different strings.
    """
    seen = []
    for build in builds.get("data", []):
        raw = (build.get("attributes") or {}).get("version") or ""
        if raw.isdigit():
            seen.append(int(raw))
    return max(seen) if seen else 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--key-id", required=True)
    parser.add_argument("--issuer-id", required=True)
    parser.add_argument("--key-path", required=True)
    parser.add_argument("--bundle-id", required=True)
    parser.add_argument("--version", required=True, help="marketing version, e.g. 1.3.0")
    args = parser.parse_args()

    token = make_token(args.key_id, args.issuer_id, args.key_path)

    apps = get(
        "/apps?filter[bundleId]={}&limit=1".format(urllib.parse.quote(args.bundle_id)),
        token,
    )
    if not apps.get("data"):
        # No app record yet. Nothing can have been uploaded, so this is build 1.
        print("No app found for {} — starting at 1".format(args.bundle_id), file=sys.stderr)
        print(1)
        return 0
    app_id = apps["data"][0]["id"]

    builds = get(
        "/builds?filter[app]={}&filter[preReleaseVersion.version]={}&limit=200".format(
            app_id, urllib.parse.quote(args.version)
        ),
        token,
    )
    highest = highest_build(builds)
    print(
        "Version {}: highest existing build is {}".format(
            args.version, highest or "none"
        ),
        file=sys.stderr,
    )
    print(highest + 1)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
