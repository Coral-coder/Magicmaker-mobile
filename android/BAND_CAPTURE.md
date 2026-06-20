# Band tagging & park capture

This documents the source-address tagging and capture-logging behavior on Android.

## What it does

- **Source address capture.** Every heard Disney (0x0183) advertisement now records
  the **advertiser (source) BLE address** alongside hex/RSSI.
- **"My MagicBand" tagging.** In the **Scan** tab → *MY MAGICBAND* section you can:
  - enter a MAC manually, or
  - tap an address from the live **HEARD** list to TAG/UNTAG it.
  Packets from a tagged address are highlighted in the live list and marked `BAND`.
- **Logging (when LOG is on).** Capture files are written to **app-external storage**
  (`Android/data/com.magicmaker.android/files/scan_sessions/`), retrievable over
  USB/MTP. Each session produces:
  | File | Contents |
  |------|----------|
  | `scan_<ts>.csv` | **Full chronological log** — every frame, in order (replay source) |
  | `scan_<ts>_band.csv` | Only frames from your tagged band address(es) |
  | `scan_<ts>_unique.csv` | **Deduped** list — one row per distinct hex, with count + first/last seen + addresses (written when the session ends) |

  CSV columns (chronological/band): `timestamp_ms,hex,rssi,label,category,type_info,colors,note,source_address,is_band`.

## Important limitations (read this)

1. **A phone only hears broadcast advertisements.** These carry a *source* address
   (who advertised), never a *destination*. So we can tag packets **FROM** your band's
   address — there is no "packets **TO** my band" in advertising data. Capturing the
   addressed, connection-level traffic between the band and park readers requires an
   **external BLE sniffer** (e.g. nRF52840 + Wireshark, Ubertooth). That is out of
   scope for a phone-only app.
2. **The band's MAC rotates.** MagicBand+ typically advertises with a **Resolvable
   Private Address** that changes (~every 15 min), and Android only exposes that
   rotating address. A static MAC you read elsewhere may never match what the phone
   sees — which is why the **HEARD** picker exists: re-tag the current address as it
   rotates (use RSSI to confirm it's yours by moving the phone to your wrist).
3. **Storage location.** `Android/data/.../files` is reachable via USB to a computer
   and via `adb`, but Android 11+ hides it from the on-device Files app and many
   third-party file managers. Pull logs over USB/adb.

## Not included yet (phase 2)

- **Replay** of a recorded chronological session (re-transmit in order with timing).
  The chronological CSV is the data source for this; the replay engine is a separate
  follow-up.
