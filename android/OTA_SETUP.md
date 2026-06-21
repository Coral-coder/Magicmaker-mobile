# MagicMaker Android — OTA via GitHub Releases

Over-the-air updates straight from this repo's **GitHub Releases**. No Firebase.
On launch the app checks the latest release, and if it's newer than what's installed
it prompts to download + install the signed APK. Everything stays private.

```
push tag  ──►  CI builds signed APK  ──►  attached to GitHub Release
                                              │
        app on phone ◄── checks /releases/latest (embedded read-only PAT) ──┘
        prompts "Update vX" → downloads asset → installs
```

## Two one-time prerequisites

### 1. Stable release keystore  (REQUIRED for OTA)
Android refuses an update whose signature differs from the installed build, so every
release must be signed with the **same** key. Generate one you keep:

```bash
keytool -genkeypair -v -keystore magicmaker-release.jks \
  -alias magicmaker -keyalg RSA -keysize 2048 -validity 10000
base64 -i magicmaker-release.jks | tr -d '\n' > keystore.b64
```
> Back this up. Lose it and you can never ship another update to installed builds.
> Until the keystore secrets are set, CI builds a *debug* APK (installable manually,
> but NOT self-updatable — debug keys differ per build).

### 2. Fine-grained read-only PAT  (to download from the private repo)
GitHub → Settings → Developer settings → **Fine-grained tokens** → new token:
- Repository access: **only** `Coral-coder/Magicmaker-mobile`
- Permissions: **Contents: Read-only** (that's all)
- Copy the token.

> ⚠️ This token is **embedded in the APK** so it can read releases. Anyone who
> extracts it from the APK could read this repo's contents. That's the tradeoff of
> the token approach; keep the scope read-only and the repo private.

## GitHub repository secrets
Settings → Secrets and variables → Actions:

| Secret | Value |
|--------|-------|
| `KEYSTORE_BASE64` | contents of `keystore.b64` |
| `KEYSTORE_PASSWORD` | keystore password |
| `KEY_ALIAS` | `magicmaker` |
| `KEY_PASSWORD` | key password |
| `UPDATE_TOKEN` | the fine-grained read-only PAT |

## Ship an update
```bash
git tag v1.0.1 && git push origin v1.0.1
```
CI signs the APK, bakes in the token, attaches it to the release. Next time you open
the app it offers the update.

## Notes
- The updater is **dormant** without `UPDATE_TOKEN` (local/debug builds embed no token).
- Local signed build: export `MM_KEYSTORE_FILE/MM_KEYSTORE_PASSWORD/MM_KEY_ALIAS/MM_KEY_PASSWORD`
  and pass `-PmmUpdateToken=<PAT>` (e.g. via `~/.gradle/gradle.properties`, never committed).
- Version check compares the release `tag_name` to the build's `versionName` (CI sets
  it to the tag), so a new tag = an offered update.
