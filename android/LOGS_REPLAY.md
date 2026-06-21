# Logs tab & replay

## Always-on capture
Logging is now **automatic while scanning** — a session log starts when you start a
scan and ends when you stop it. No more missed data from forgetting to toggle LOG.

## Where logs live
- New logs: `/sdcard/MagicMaker/logs/scan_<timestamp>.csv` (when all-files access is
  granted; otherwise the app's external folder).
- **Old logs are never lost:** the Logs tab reads from *all* historical locations —
  the SD folder, the app external files dir (band-tagging era), and internal storage
  (oldest) — so previously captured sessions still show up.

Each session writes three files (chronological `scan_*.csv`, `_band.csv`, `_unique.csv`);
the Logs tab lists the chronological one.

## Logs tab
- Lists every capture log (name, packet count, size), newest first; **Refresh**.
- Tap a log to expand: filter by **type** (categories present in the log), by a
  **source MAC**, and/or **band only** — then **Replay** or **Delete**.

## Replay
- Re-broadcasts the (optionally filtered) packets **in recorded order**, each on air
  for the **real gap to the next packet** (raw bytes + recorded cadence), clamped to
  60ms–10s per step so BLE advertising stays practical.
- Scanning + the GATT relay pause during replay and resume after.
- A progress banner (`REPLAYING n/total`) with **Stop** shows while it runs.

### Limits
- Sub-60ms gaps are clamped, and each advertise has a small radio-settle overhead, so
  cadence is a close approximation, not microsecond-exact.
- Replay transmits the exact captured bytes; it does not re-derive wakeup/command
  framing (that's the point — it reproduces what was heard).
