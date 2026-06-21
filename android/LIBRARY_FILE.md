# Library file on shared storage

The packet library is mirrored to a fixed, user-editable file on shared storage so
you can export it, edit it on a computer, and have the app reload it after updates.

- **Path:** `/sdcard/MagicMaker/magicmaker_library.json`
  (`Environment.getExternalStorageDirectory()/MagicMaker/...`)
- **Format:** the full `PersistedState` JSON — everything that wouldn't survive a
  reinstall:
  - **Packets in sections:** `presets`, `learnedColors`, `learnedLibrary`,
    `learnedRaw`, plus `recordings` and `autoRules`.
  - **All app settings** from both SharedPreferences files (`magicmaker` and
    `magicmaker_ui`), captured generically and type-tagged: band addresses, TX
    timings (wakeup/command/starlight), start-on-boot, lab hex/label, starlight
    serial, and UI state like collapsed sections / band menu.

## Behavior

- **Auto-save:** every library change writes both the internal copy and this SD file.
- **Auto-load on launch:** on startup the app loads whichever of {internal, SD file}
  is newer — so edits you make to the SD file (while the app is closed) are picked up.
- **Survives uninstall/update:** because it lives outside `Android/data`, it persists
  across app updates *and* a full uninstall/reinstall. After a reinstall, grant access
  and tap **Import** to load it.
- **Export / Import buttons** (Scan tab → *Library file*): force-write or force-load.

## Access requirement

Writing to a fixed shared path needs **all-files access**:
- Android 11+ (API 30+): `MANAGE_EXTERNAL_STORAGE`, granted via a Settings screen
  (Scan tab → *Library file* → **Grant access**).
- Android 10 and below: legacy `WRITE_EXTERNAL_STORAGE` runtime permission.

## Safety

The app will **not overwrite an existing SD library it hasn't loaded/imported yet**
(`externalAuthoritative` guard). So on a fresh install with your data already on the
card, freshly-seeded defaults won't clobber it before you tap **Import**.
