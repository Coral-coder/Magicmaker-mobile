# Making this repo public: checklist

Public repositories get GitHub Actions minutes on standard GitHub-hosted runners for free.
That covers the Android build, the ESP32 firmware build and the macOS runner the TestFlight
build uses. Private repositories draw on a monthly quota, which is what ran out.

> **The repo is already public.** On 2026-11-24 at about 18:15 UTC the GitHub API reported
> `Coral-coder/Magicmaker-mobile` as `"visibility": "public"`. Do step 1 **now**. Every old
> release APK, plus the workflow artifacts from the last few days, can be downloaded by anyone
> and contains the old `UPDATE_TOKEN`. Skip step 2 unless you made the repo private again.

## What was in the old APKs

Release builds up to and including **v1.3.14** were built with `-PmmUpdateToken` and
`-PmmBackupToken`. Gradle writes those values into `BuildConfig` as plain strings, and any
APK decompiler shows them.

| Token | In the old APKs? | What it can do |
|---|---|---|
| `UPDATE_TOKEN` | **Yes.** The build logs of v1.3.8, v1.3.14 and the failed v1.3.15 all show the secret as set. | If it was made as `android/OTA_SETUP.md` said (this repo only, Contents read-only), it can only read this repo, which is now public anyway. If it was made with wider access, it can read everything that access covers. |
| `BACKUP_TOKEN` | **Not in the builds checked.** The secret was empty for v1.3.8, v1.3.14 and v1.3.15. Builds older than v1.3.8 (before 2026-10-04) were not checked. | Write access to `magicmaker-backups`. |

From this change on, the release APK contains **no token**:

- The **updater** reads the public Releases with no token.
- The **cloud dictionary token** is typed in on the phone and stays there (step 6).

## 1. Revoke the old tokens (do this first)

- [ ] On github.com, click your profile picture → **Settings** → **Developer settings** →
      **Personal access tokens** → **Fine-grained tokens** (also check **Tokens (classic)**).
- [ ] Find the token you made for `UPDATE_TOKEN` (read-only, `Magicmaker-mobile`) and click
      **Revoke**.
- [ ] Revoke every token you have **ever** used as `BACKUP_TOKEN` (write access to
      `magicmaker-backups`), even if you think it was never in a build.
- [ ] In this repo, go to **Settings** → **Secrets and variables** → **Actions** and delete
      the `UPDATE_TOKEN` and `BACKUP_TOKEN` secrets. Nothing reads them any more.
- [ ] Make a **new** token for the cloud dictionary: **Fine-grained tokens** →
      **Generate new token**. Set **Repository access** to *Only select repositories* →
      `magicmaker-backups`, and **Permissions** to **Contents: Read and write**. Choose an
      expiry and set yourself a reminder. Keep the token for step 6. **Do not** put it in this
      repo or in an Actions secret.
- [ ] Optional: delete the old **Releases**, or just their `app-release.apk` assets, and the
      recent `magicmaker-apk` workflow artifacts (Actions → a run → Artifacts → delete). Once
      the tokens are revoked these only hold dead strings, so this is just tidying up. If you
      delete old releases you also lose the old APKs to roll back to.

**Side effect:** an installed app at v1.3.14 or older still sends the revoked token when it
checks for updates. GitHub answers 401, so **that app will not offer the next update**.
Install the next release once by hand (step 6). After that, updates work with no token.
If you are certain `UPDATE_TOKEN` was scoped exactly as `OTA_SETUP.md` describes, it gives
nobody anything beyond the public repo. In that case you may wait to revoke **that one token**
until your phone has taken the next update over the air. If you are not sure, revoke it now.

## 2. Change the visibility (only if it is private again)

- [ ] Repo → **Settings** → **General** → scroll to the bottom → **Danger Zone** →
      **Change repository visibility** → **Change visibility** → **Change to public**. Read
      the warnings, confirm, and type the repo name when asked.
- Once the repo is public, anyone can read the code and the **full git history**, Issues,
  Releases and their assets, the logs of **past** Actions runs, and any workflow artifacts
  that have not expired yet.

A workflow cannot flip the visibility for you. Its `GITHUB_TOKEN` has no admin rights, and
only a repo admin can change visibility (in Settings, as above).

## 3. What stays secret, and why

- **Actions secrets** stay encrypted and hidden in a public repo, exactly as in a private one.
  Nobody can read them, you included. They are: `KEYSTORE_BASE64`, `KEYSTORE_PASSWORD`,
  `KEY_ALIAS`, `KEY_PASSWORD`, `APPLE_TEAM_ID`, `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_P8`,
  `DEV_CERT_P12`, `DEV_CERT_PASSWORD`, `SECRETS_TOKEN` and the rest. Only workflows running in
  this repo receive them:
  - A pull request from a **fork** runs without secrets and with a read-only `GITHUB_TOKEN`.
  - The **Run workflow** buttons (TestFlight, Share secrets, Android release) work only for
    people with write access to this repo: you, plus any collaborators you add.
- **Public logs mask secrets.** GitHub replaces every secret's exact value with `***` in run
  logs. That is why the release log prints the artifact name as `***-apk`: the `KEY_ALIAS`
  value is `magicmaker`, so every `magicmaker` in that job's log is masked. Masking only
  catches the exact string. The workflows here decode the keystore and the `.p8` key into
  files on the runner and never print them. Keep it that way: never `echo` a decoded or
  reshaped secret.
- **Android keystore:** it lives only in the secrets. The APK is *signed* with it but does not
  *contain* it. The signing certificate inside an APK is public by design. Nobody else can
  produce an APK that installs over yours as an update.
- **TestFlight / App Store Connect keys and certificates:** these are secrets too. They are
  written to `$RUNNER_TEMP` on a throw-away runner that is destroyed after the job.
- **Cloud dictionary token:** it is now only on your phone (step 6).

**Can someone else build or publish your app?** They can fork the repo and build *their own*
copy on *their own* minutes. They cannot sign it with your keystore, publish to your Releases,
upload to your TestFlight, or read your secrets. Encrypting the source is not needed for any
of that.

Recommended settings once the repo is public:

- [ ] **Settings** → **Actions** → **General** → *Approval for running fork pull request
      workflows* → **Require approval for all external contributors**. `android-ci.yml` runs on
      `pull_request`, so with this setting a stranger's PR runs nothing until you approve it.
- [ ] **Settings** → **Advanced Security** (on some accounts it is called **Code security**) →
      make sure **Secret scanning** and **Push protection** are on. Both are free for public
      repos. Secret scanning also checks the full history, which this review could not (see
      the scan below).

## 4. The v1.3.15 release failure: 403 "Resource not accessible by integration"

Run #54 (commit `16ed2dd`) built and signed the APK. It then failed at
**Publish APK to GitHub Release** with this:

```
Creating new GitHub release for tag v1.3.15-20261124-1734 using commit "16ed2dd…"
GitHub release failed with status: 403
{"message":"Resource not accessible by integration", … "#create-a-release"}
```

The usual suspects, and what the evidence shows:

1. **Workflow permissions setting.** Repo → **Settings** → **Actions** → **General** →
   **Workflow permissions** sets the *default* rights of `GITHUB_TOKEN`. The release workflow
   overrides that default with `permissions: contents: write`. The failed job's log shows
   *Set up job → GITHUB_TOKEN Permissions → Contents: write*, the same as the successful
   v1.3.14 run. So this setting was **not** the cause. You can still pick
   **Read and write permissions** there as a fallback; it does no harm.
2. **Repository rules on tag creation.** A ruleset that targets tags (for example `v*` or
   *All tags*) with **Restrict creations** blocks the release step, which has to create the
   tag. To check: Repo → **Settings** → **Rules** → **Rulesets**, and look at any ruleset
   whose target is *Tags*. Older repos may also have **Settings → Tags** (protected tags,
   now migrated into rulesets). To fix: remove *Restrict creations* for release tags, or
   exclude `v*` from that ruleset's target. On 2026-11-24 the API listed **no** rulesets on
   this repo, so this is unlikely to be the cause here.
3. **Most likely cause: a workflow file changed on `main` during the build.** The run started
   at 17:34 for `16ed2dd`. At 17:38 commit `cad065b` changed
   `.github/workflows/esp32-firmware.yml` on `main`. At 17:41 the release step asked GitHub to
   create a new tag on the *older* commit `16ed2dd`, whose workflow files no longer matched
   `main`. `GITHUB_TOKEN` can never have the `workflows` permission, so GitHub refuses to let
   it create a ref that brings in different workflow files, and the error shows as this 403.
   No earlier release had a workflow edit land in the middle of its build.
   - **Fixed in `android-release.yml`.** The workflow now creates the tag in a new step,
     *Create the release tag before the build*, a few seconds after the push. The Release step
     then finds the tag already there.
   - **Re-running run #54 will not help.** It would tag the same old commit again. To publish
     v1.3.15, change `.github/RELEASE_VERSION` and push, or use **Actions** →
     **Android Release & OTA** → **Run workflow**. The date stamp makes every tag unique, and
     a public repo pays nothing for the run.
   - If the *Create the release tag* step itself fails with 403, check items 1 and 2 above.

## 5. Release checklist after this change

- [ ] Push this change (it has no secrets in it).
- [ ] Bump `.github/RELEASE_VERSION` (or **Run workflow**). In the run, check that
      *Build APK* no longer lists `UPDATE_TOKEN` / `BACKUP_TOKEN`, and that the release has a
      single `app-release.apk`. The *Upload APK as workflow artifact* step now runs only when
      there is no Release to hold the APK (no version to publish, or publishing failed after a
      good build, so a signed APK is never lost). On a normal release it shows as skipped.

## 6. On the phone, after updating

- [ ] **Install the new release.** On the phone, open the repo's **Releases** page → the
      newest release → `app-release.apk` → open it → **Update**. It is signed with the same
      key, so it installs over the old app and keeps your data. Do this by hand once if the
      old app does not offer the update (step 1). Later updates arrive in the app as usual.
- [ ] **Enter the cloud token** (the new one from step 1):
  - Standard theme: **SETTINGS** tab → **CLOUD DICTIONARY** → paste it into
    **Cloud dictionary token** → **SAVE**.
  - VFD theme: **SETTINGS** → **CLOUD DICTIONARY** → **SET TOKEN** → paste → **OK**.
  - Both fields mask what you type, and the token is never shown again afterwards.
  - The section then shows `TOKEN: SET ON THIS PHONE`. A sync starts right away, and the
    **LOGS** tab shows `CLOUD: …` with **SYNC NOW**.
- Where the token is kept: the app's private storage, in a prefs file of its own
  (`magicmaker_secrets`). It is never written to `/sdcard/MagicMaker/magicmaker_library.json`
  or to an EXPORT, and it is left out of Android's own backup (Google backup and
  phone-to-phone transfer), so a new or restored phone needs it entered again. **CLEAR**
  removes it. Uninstalling the app removes it too. The app never logs it, and a sync error
  shows `***` in its place.
- If the status reads `token rejected (401)`, the token was revoked or has expired. Make a new
  one (step 1) and set it again.

## 7. Scan of the working tree: what goes public

Checked: all 272 tracked files, plus the local git history (178 commits back to 2026-10-03;
the local clone is shallow, so older history was **not** checked here). The search covered
token and key patterns (`github_pat_`, `ghp_`, AWS and Google keys, private-key blocks, URLs
with embedded credentials), key and certificate files (`.jks`, `.keystore`, `.p8`, `.p12`,
`.pem`, `.mobileprovision`, `.env`), e-mail addresses, MAC addresses, IP addresses,
coordinates and `.claude/`.

| # | Finding | Where | Risk | Action |
|---|---|---|---|---|
| 1 | Old release APKs (≤ v1.3.14) and recent `magicmaker-apk` artifacts contain `UPDATE_TOKEN` | GitHub Releases / Actions artifacts (not in git) | Credential exposure | Step 1 |
| 2 | No committed tokens, private keys, keystores, certificates or `.env` files. History matches are placeholders only (`github_pat_…`, `ghp_xxx` in docs) | whole tree + local history | none | Let secret scanning check the older history (step 3) |
| 3 | Relay Wi-Fi hotspot credentials are hard-coded: SSID `MagicMaker`, password `magic123`. The relay HTTP server on :8765 has no authentication | `android/.../relay/HotspotManager.kt:188-189`, `RelayHttpServer.kt` | Anyone nearby who knows the password can join the phone's relay hotspot while it is on, and send relay commands | Follow-up: a random password per phone (shown in the app's pairing QR) and a pairing key on the HTTP API |
| 4 | Apple Team ID `9BQDEVHKJZ` | `ios/MagicMaker.xcodeproj/project.pbxproj` | not secret (it is inside every app you sign) | none |
| 5 | Repo names `Coral-coder/Magicmaker-mobile` and `Coral-coder/magicmaker-backups`, and bundle IDs `com.lightwave.*` | `android/app/build.gradle.kts`, docs, iOS project | reveals the (private) backup repo's name only | none |
| 6 | `.claude/` holds AI-agent working notes: iOS port rules and architecture, `parity_map.json`, workflow scripts, the `vfd-theme` skill. Container paths like `/home/user/…`. No credentials or personal data | `.claude/` | low (internal notes become public) | Keep, or delete `.claude/` if you would rather not publish them |
| 7 | Commit messages contain `Claude-Session: https://claude.ai/code/session_…` links | git history | those pages need your login; not secrets | none |
| 8 | `share-secrets.yml` can copy your Apple and Android secrets to other repos you own | `.github/workflows/` | only someone with write access can start it, and the values are never printed | none; never add a `pull_request_target` trigger to it |
| 9 | The firmware flasher docs and scripts still say "PRIVATE repo" and suggest `-Token` / `--token` | `firmware/esp32-transmitter/README.md`, `flash.ps1`, `flash.sh` | none: downloads now work without a token | Tidy the wording later |
| 10 | TestFlight dSYM artifacts (7-day retention) become downloadable | Actions artifacts | debug symbols only | none |
| 11 | Only placeholder MAC (`7C:9E:BD:12:34:56`), hotspot IPs and no GPS coordinates or e-mail addresses. Capture logs and libraries live on the phone, not in git | whole tree | none | none |
| 12 | The iOS TestFlight run logs print the signing certificate's name: `Apple Development: <the name on your Apple developer account>`. Only the Team ID in it is masked | Actions logs of `ios-testflight.yml` (steps *Signing certificate* and *Archive*), past runs and future ones | your name is readable by anyone; not a credential | If you mind: open each such run → **⋯** → **Delete all logs**. Future runs print it again unless the workflow is changed to hide it |
