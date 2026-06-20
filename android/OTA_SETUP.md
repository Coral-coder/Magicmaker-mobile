# MagicMaker Android — OTA + CI setup

This wires up **over-the-air updates** (Firebase App Distribution) and a
**cloud build pipeline** (GitHub Actions). Everything stays **private and free**:

- GitHub Actions is free on private repos (~2,000 min/month; a build is ~5–10 min).
- App Distribution only delivers to **testers you invite** (your Google account).
- The signing key and Firebase service account live as **GitHub secrets**, never in git.

## Quick start — manual install, ZERO setup (current mode)

You don't need Firebase or a keystore to get started. With no secrets configured,
pushing a version tag builds a **debug APK** and attaches it to a **GitHub
Release** you can download and sideload:

```bash
git tag v1.0.1 && git push origin v1.0.1
```

Then: repo → **Releases** → download `app-debug.apk` → install on the phone.

Notes:
- Release assets are **private** (you must be signed into GitHub to download —
  e.g. open the release in your phone's browser while logged in).
- A debug APK is fine for manual installs. **Heads-up:** when you later switch to
  signed release builds (below), the signature changes, so you'll have to
  **uninstall the debug build once** before installing the release one.
- The in-app updater stays dormant until Firebase is configured — the app runs
  normally without it.

## Full OTA mode — set up when you're ready

Once configured, releasing a new build is just:

```bash
git tag v1.0.1 && git push origin v1.0.1
```

CI builds a signed APK, attaches it to the GitHub Release, ships it to App
Distribution, and your device gets an in-app "Update available" prompt the next
time you open the app. The workflow detects the secrets automatically — add them
and the next tag upgrades from debug→signed and turns on OTA.

---

## What is already implemented (in this branch)

- `app/build.gradle.kts` — release signing config (reads env vars, no secrets in
  repo), CI-overridable `versionCode`/`versionName`, Firebase App Distribution
  dependencies, and conditional Google Services plugin.
- `MainActivity.onResume()` → `AppUpdater.checkForUpdate(this)` — checks for a
  newer build whenever the app is foregrounded.
- `update/AppUpdater.kt` — guarded so the app runs fine before Firebase is set up.
- `AndroidManifest.xml` — `REQUEST_INSTALL_PACKAGES` for the in-app installer.
- `.github/workflows/android-release.yml` — the cloud pipeline.
- `.gitignore` — excludes `google-services.json`, keystores, `keystore.properties`.

## What you need to do (one time)

### 1. Generate a release keystore (you keep the master copy)

```bash
keytool -genkeypair -v \
  -keystore magicmaker-release.jks \
  -alias magicmaker \
  -keyalg RSA -keysize 2048 -validity 10000

# Then base64-encode it for the GitHub secret:
base64 -i magicmaker-release.jks | tr -d '\n' > keystore.b64
```

> ⚠️ Back this file up somewhere safe. If you lose it you can never ship an
> update to already-installed builds — Android rejects a different signature.

### 2. Create the Firebase project

1. https://console.firebase.google.com → **Add project** (no Analytics needed).
2. **Add app → Android**, package name **`com.magicmaker.android`**.
3. Download **`google-services.json`**.
4. In the console, open **Release & Monitor → App Distribution**, and under
   **Testers & Groups** create a group named **`testers`** and add your email.
   Accept the invite on your phone and install the **Firebase App Tester** app
   (first install is via the invite link; after that, updates come in-app).
5. Find the **App ID** (Project settings → Your apps): looks like
   `1:1234567890:android:abcdef…`.

### 3. Create a service account for CI uploads

1. Google Cloud Console → IAM & Admin → **Service Accounts** → create one.
2. Grant role **Firebase App Distribution Admin**.
3. Create a **JSON key** and download it.

### 4. Add GitHub repository secrets

Repo → **Settings → Secrets and variables → Actions → New repository secret**:

| Secret | Value |
|--------|-------|
| `KEYSTORE_BASE64` | contents of `keystore.b64` from step 1 |
| `KEYSTORE_PASSWORD` | keystore password you chose |
| `KEY_ALIAS` | `magicmaker` (or your alias) |
| `KEY_PASSWORD` | key password (often same as keystore password) |
| `GOOGLE_SERVICES_JSON` | full contents of `google-services.json` |
| `FIREBASE_APP_ID` | the App ID from step 2.5 |
| `FIREBASE_SERVICE_ACCOUNT` | full contents of the service account JSON |

> For **local** release builds you can instead export `MM_KEYSTORE_FILE`,
> `MM_KEYSTORE_PASSWORD`, `MM_KEY_ALIAS`, `MM_KEY_PASSWORD` and drop
> `google-services.json` into `android/app/`. Both are gitignored.

### 5. Ship it

```bash
git tag v1.0.1
git push origin v1.0.1
```

Watch the **Actions** tab. On success your device gets the update prompt.

---

## Notes / tuning

- **versionCode** is set to the GitHub run number in CI, so it always increases.
  Local builds default to `1` unless you pass `-PmmVersionCode=N`.
- The App Distribution SDK artifacts are **beta** (`16.0.0-beta14`); if Google
  publishes a newer one, bump it in `app/build.gradle.kts`. CI will surface any
  incompatibility.
- The in-app check runs on every foreground (`onResume`). If that feels too
  frequent, gate it behind a button or a once-per-day timestamp in `AppUpdater`.
- Debug builds via `./tools/deploy.sh` are unaffected and need no Firebase setup.
