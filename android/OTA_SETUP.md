# MagicMaker Android — OTA via GitHub Releases

Over-the-air updates straight from this repo's **GitHub Releases**. No Firebase.
On launch the app checks the latest release, and if it's newer than what's installed
it prompts to download + install the signed APK. The repo is **public**, so the app
reads Releases **without any token** and the APK carries no secrets
(see [`docs/GOING_PUBLIC.md`](../docs/GOING_PUBLIC.md)).

```
push tag  ──►  CI builds signed APK  ──►  attached to GitHub Release (public)
                                              │
        app on phone ◄── checks /releases/latest (anonymous GitHub API) ──┘
        prompts "Update vX" → downloads asset → installs
```

## One-time prerequisite

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

### (No token any more)
Older builds embedded a read-only PAT (`UPDATE_TOKEN`) to read the private repo's
Releases. Release APKs are public downloads now, so CI passes no token and the
`UPDATE_TOKEN` secret is unused — revoke the old token and delete the secret
(`docs/GOING_PUBLIC.md`).

## GitHub repository secrets
Settings → Secrets and variables → Actions:

| Secret | Value |
|--------|-------|
| `KEYSTORE_BASE64` | contents of `keystore.b64` |
| `KEYSTORE_PASSWORD` | keystore password |
| `KEY_ALIAS` | `magicmaker` |
| `KEY_PASSWORD` | key password |

## Ship an update
```bash
git tag v1.0.1 && git push origin v1.0.1
```
CI signs the APK and attaches it to the release. Next time you open the app it offers
the update.

## Notes
- The updater works with no token (public repo; GitHub allows 60 anonymous API calls an
  hour per network, plenty for one check per app open).
- `-PmmUpdateToken=<PAT>` still works for a local build if the repo is ever private again
  (e.g. via `~/.gradle/gradle.properties`, never committed). A rejected token (401) makes the
  app retry anonymously.
- Local signed build: export `MM_KEYSTORE_FILE/MM_KEYSTORE_PASSWORD/MM_KEY_ALIAS/MM_KEY_PASSWORD`.
- Version check compares the release `tag_name` to the build's `versionName` (CI sets
  it to the tag), so a new tag = an offered update.
