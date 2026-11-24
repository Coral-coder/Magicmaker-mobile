#!/usr/bin/env python3
"""Check the ESP32 transmitter release images and write their two manifests.

Reads from --dir (default: the current directory):
  magicmaker-esp32.bin, magicmaker-heltec-v3.bin           merged images, flashed at 0x0
  magicmaker-esp32-app.bin, magicmaker-heltec-v3-app.bin   app images (what an OTA update sends)

Checks, per board: the app image is a bootloader-format image for that chip (magic 0xE9 +
chip id), it carries exactly one "MMFW:<version>:<board>" marker naming that board, and it
equals the merged image from offset 0x10000. Both boards must carry the same version.

Writes into --out (default: --dir):
  firmware.json  {"version", "release", "boards": {board: {"merged", "app", "size", "md5",
                  "sha256", "mergedSize", "mergedMd5"}}}; size / md5 / sha256 describe the
                  APP image (what the iPhone sends over BLE, and checks before it does).
  manifest.json  ESP Web Tools manifest for the web flasher: chip family ESP32 -> classic
                  image, ESP32-S3 -> Heltec V3 image, both at offset 0.

Prints the firmware version on stdout (messages go to stderr). Deterministic: the same
images give byte-identical manifests, so an unchanged build commits nothing.

Used by .github/workflows/esp32-firmware.yml; run it by hand to seed web/flasher/.
"""
import argparse
import hashlib
import json
import os
import re
import sys

APP_OFFSET = 0x10000

# board id (MMFW marker / OTA QUERY), file stem, ESP Web Tools chip family, image chip id
BOARDS = [
    ("esp32", "magicmaker-esp32", "ESP32", 0),
    ("heltec-v3", "magicmaker-heltec-v3", "ESP32-S3", 9),
]

MARKER = re.compile(rb"MMFW:([0-9][0-9A-Za-z._+-]{0,23}):(heltec-v3|esp32)(?![0-9A-Za-z_-])")


def fail(msg):
    print("firmware_manifest: " + msg, file=sys.stderr)
    sys.exit(1)


def read(path):
    try:
        with open(path, "rb") as f:
            return f.read()
    except OSError as e:
        fail("cannot read %s: %s" % (path, e))


def write_json(path, obj):
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        json.dump(obj, f, indent=2)
        f.write("\n")


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--dir", default=".", help="folder holding the four images")
    ap.add_argument("--out", help="where to write firmware.json + manifest.json (default: --dir)")
    ap.add_argument("--repo", default=os.environ.get("GITHUB_REPOSITORY") or "Coral-coder/Magicmaker-mobile",
                    help="owner/name, for the release download URL")
    args = ap.parse_args()
    out = args.out or args.dir

    version = None
    boards = {}
    builds = []
    for board, stem, family, chip_id in BOARDS:
        merged_name, app_name = stem + ".bin", stem + "-app.bin"
        merged = read(os.path.join(args.dir, merged_name))
        app = read(os.path.join(args.dir, app_name))

        if len(app) < 64 * 1024 or app[0] != 0xE9 or (app[12] | app[13] << 8) != chip_id:
            fail("%s is not an app image for %s (%d bytes, magic %#04x, chip id %d)"
                 % (app_name, family, len(app), app[0] if app else 0,
                    (app[12] | app[13] << 8) if len(app) > 13 else -1))
        if merged[APP_OFFSET:APP_OFFSET + len(app)] != app or merged[APP_OFFSET + len(app):].strip(b"\xff"):
            fail("%s does not hold %s at offset %#x" % (merged_name, app_name, APP_OFFSET))

        found = set(MARKER.findall(app))
        if len(found) != 1:
            fail("%s: expected one MMFW:<version>:<board> marker, found %s"
                 % (app_name, sorted(m.decode() for m in (b"%s:%s" % f for f in found)) or "none"))
        ver, marker_board = (x.decode("ascii") for x in found.pop())
        if marker_board != board:
            fail("%s is marked for board %s, expected %s" % (app_name, marker_board, board))
        if version is None:
            version = ver
        elif ver != version:
            fail("version mismatch: %s carries %s, the other board %s" % (app_name, ver, version))

        md5 = hashlib.md5(app).hexdigest()
        merged_md5 = hashlib.md5(merged).hexdigest()
        boards[board] = {
            "merged": merged_name,
            "app": app_name,
            "size": len(app),
            "md5": md5,
            "sha256": hashlib.sha256(app).hexdigest(),
            "mergedSize": len(merged),
            "mergedMd5": merged_md5,
        }
        # ?v= busts browser / Pages caches when an image changes under the same name.
        builds.append({"chipFamily": family,
                       "parts": [{"path": "%s?v=%s" % (merged_name, merged_md5[:12]), "offset": 0}]})
        print("%s: %s v%s, app %d bytes md5 %s, merged %d bytes"
              % (board, family, ver, len(app), md5, len(merged)), file=sys.stderr)

    os.makedirs(out, exist_ok=True)
    write_json(os.path.join(out, "firmware.json"), {
        "version": version,
        "release": "https://github.com/%s/releases/download/esp32-firmware/" % args.repo,
        "boards": boards,
    })
    write_json(os.path.join(out, "manifest.json"), {
        "name": "MagicMaker ESP32 transmitter",
        "version": version,
        # The firmware doesn't speak Improv Wi-Fi; don't wait for it after flashing.
        "new_install_improv_wait_time": 0,
        "builds": builds,
    })
    print(version)


if __name__ == "__main__":
    main()
