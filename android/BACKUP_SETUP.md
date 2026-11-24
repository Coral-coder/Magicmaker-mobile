# MagicMaker — Cloud Packet Dictionary

The app keeps a shared, de-duplicated **`packets.csv`** (hex + function) in a
dedicated private GitHub repo. Any MagicMaker device — or other apps — can read it.

```
columns: hex,function,category,colors
```

**How it behaves**
- On every app open it **pulls** the current list and adds any packets it doesn't have.
- When it detects a packet whose **function is known** and the exact hex isn't on the
  list yet, it **adds** it and pushes (throttled to ~once/minute).
- A **SYNC NOW** button (Logs tab) forces an immediate reconcile. It shows once a token
  is set (step 3).
- Offline-safe: your on-device library is the durable queue — failed syncs just retry
  next time you're online (parks have no Wi-Fi, so it lands when you reconnect).

## One-time setup

### 1. Create the backup repo
New **private** repo named **`magicmaker-backups`** (empty is fine).
(If you use a different name, set the `mmBackupRepo` build property / change the
`BACKUP_REPO` default in `app/build.gradle.kts`.)

### 2. Create a write-scoped token
GitHub → Settings → Developer settings → **Fine-grained tokens** → Generate:
- Resource owner: **Coral-coder**
- Repository access: **Only** `magicmaker-backups`
- Permissions → **Contents: Read and write**
- Copy the `github_pat_…`.

> This token can **write** to the backup repo. Keep it scoped to *only* that repo.

### 3. Enter it on the phone
The app repo is public, so release APKs carry **no** token. Enter it once per phone:
**Settings → CLOUD DICTIONARY → Cloud dictionary token** → paste → **SAVE**
(VFD theme: **SET TOKEN**). It is kept in the app's private storage, in its own prefs
file, and is never written to the library file or an EXPORT. **CLEAR** turns sync off.

Without a token the feature stays dormant (the CLOUD / SYNC NOW row is hidden).
A local private build can still bake one in with `-PmmBackupToken=…` (never committed);
a token entered on the phone wins over it. The old `BACKUP_TOKEN` Actions secret is no
longer used — see `docs/GOING_PUBLIC.md`.
