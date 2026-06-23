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
- A **SYNC NOW** button (Logs tab) forces an immediate reconcile.
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

> ⚠️ This token is embedded in the APK and can **write** to the backup repo. Keep it
> scoped to *only* that repo. Worst case is a vandalized backup (history recoverable),
> never your code.

### 3. Add the secret
Repo → Settings → Secrets and variables → Actions → **New repository secret**:

| Secret | Value |
|--------|-------|
| `BACKUP_TOKEN` | the write-scoped `github_pat_…` |

### 4. Release
Bump `.github/RELEASE_VERSION` (or push a `v*` tag) — the build bakes the token in and
the feature goes live. Without `BACKUP_TOKEN`, the feature stays dormant (the SYNC row
is hidden).
