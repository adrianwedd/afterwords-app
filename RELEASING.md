# Releasing Afterwords

This runbook covers cutting a versioned release of the **Afterwords menu-bar
app** (the macOS control panel for the separate, locally-running Afterwords TTS
server) and publishing it through the Sparkle 2 auto-updater.

Updates are delivered via an **EdDSA (Ed25519)** signed appcast. Sparkle
silently rejects any `<item>` that lacks a valid `sparkle:edSignature`, so every
step below must be completed and the resulting `appcast.xml` committed to `main`
for existing installs to ever see the release.

The user-facing feed lives at:

```
https://raw.githubusercontent.com/adrianwedd/afterwords-app/main/appcast.xml
```

This URL is the `SUFeedURL` baked into `Afterwords/Info.plist`. **Whatever ships
on `main`'s `appcast.xml` is what existing installs offer.** Download links
ultimately surface on the canonical site, https://afterwords-app.pages.dev/,
and on the GitHub Releases page.

Throughout this document, the EdDSA key pair is referred to using Sparkle's own
naming: the public half is `SUPublicEDKey` in `Info.plist`, and the per-asset
signature attribute in the appcast is `sparkle:edSignature`.

---

## Current distribution reality (read this first)

Be honest with yourself and with users about what protects a release today:

- **Release DMGs are UNSIGNED and UN-NOTARIZED.** `project.yml` sets
  `CODE_SIGN_ID: ""`, and the App Sandbox is disabled (`ENABLE_APP_SANDBOX: NO`)
  because the app spawns the `afterwords` CLI as a subprocess. There is **no
  Developer ID signature and no notarization**. On first launch users must
  right-click → **Open** (or clear the quarantine flag) to get past Gatekeeper.
- **Auto-updates ARE integrity-protected.** Once a user is running the app,
  Sparkle verifies every downloaded update's `sparkle:edSignature` against the
  `SUPublicEDKey` compiled into their installed copy. A tampered or unsigned
  update is rejected.
- **The INITIAL download is NOT cryptographically verified by the OS.** Because
  there is no notarization, Gatekeeper cannot detect a tampered first install.
  To compensate, **publish the DMG's SHA-256 in each GitHub Release body** so
  users can verify the bytes they downloaded by hand. This is a documented
  recommendation from `docs/security-review-2026-05-29.md` (Finding 2).

Developer ID signing + notarization are **roadmap items**, not something that
exists today. Do not document signing/notarization steps as if they are wired
up — they are not.

---

## Prerequisites

Before cutting a release, confirm all of the following:

- [ ] **Xcode 15+ and XcodeGen** installed (`make project` / `make dmg` rely on
      both).
- [ ] **`gh` CLI authenticated** (`gh auth status`) with push access to
      `adrianwedd/afterwords-app`.
- [ ] **Clean working tree on `main`** (`git status` clean,
      `git rev-parse --abbrev-ref HEAD` → `main`), pulled up to date.
- [ ] **The EdDSA private key is present in the macOS Keychain** — account
      `ed25519` under the service `https://sparkle-project.org`. This is the
      private half of the published `SUPublicEDKey`
      (`FeOcV5PkLWfalq0xh+eMPzFNYDU3rQso95Ix+RvLl9U=`). Without it you cannot
      sign the DMG, and an unsigned item is silently rejected by every install.
      See **Key loss / recovery** if it is missing.
- [ ] **Release notes prepared** (a short summary of changes — used in the
      GitHub Release body; see the note in step 7 on where it lives).

---

## One-time setup

Sparkle ships two command-line tools, `sign_update` (signs a file and prints the
`sparkle:edSignature` + `length`) and `generate_keys` (creates a new key pair).
They are **not** on your `PATH` — they come down as part of Sparkle's Swift
Package Manager artifact bundle.

`make dmg` builds with `-derivedDataPath build/DerivedData` (see `Makefile`), so
after a build the tools live in the **repo-local** artifact bundle, roughly:

```
build/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update
build/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys
```

To locate them robustly (repo-local first, then the global DerivedData as a
fallback for older checkouts), run:

```bash
find build/DerivedData ~/Library/Developer/Xcode/DerivedData \
    -name sign_update -type f 2>/dev/null
```

Export the resulting directory for convenience in this shell session:

```bash
SPARKLE_BIN="$(dirname "$(find build/DerivedData ~/Library/Developer/Xcode/DerivedData \
    -name sign_update -type f 2>/dev/null | head -n1)")"
echo "$SPARKLE_BIN"
```

**First-time key generation only.** If no EdDSA key pair exists yet, run
`generate_keys`; it creates and stores the private key in the Keychain and
prints the public key. That printed public key **must equal** the `SUPublicEDKey`
value already in `Afterwords/Info.plist`:

```bash
"$SPARKLE_BIN/generate_keys"
# prints the public key — must match SUPublicEDKey in Afterwords/Info.plist
```

If you are generating a *new* key (e.g. after key loss), see **Key loss /
recovery** — you cannot simply swap the key and ship through Sparkle.

---

## Cutting a release

The steps are ordered for a **safe, atomic publish**: build → sign → hash →
write the appcast item → tag → create the GitHub Release with the exact signed
asset → and only then commit the appcast. The appcast `length` and
`sparkle:edSignature` must describe the **exact bytes** users download, so
nothing goes live to existing installs until the final commit.

In the examples below, substitute the real version. The current shipped values
are `CFBundleShortVersionString = 1.0` and `CFBundleVersion = 1`, so the first
real release would be `1.0` / `1` (already set) or the next increment.

### 1. Bump the version

Edit `Afterwords/Info.plist` (both values are stored as strings):

- `CFBundleShortVersionString` → the **human** version, e.g. `1.1`. Surfaced in
  the UI and the GitHub Release title.
- `CFBundleVersion` → a **monotonically increasing, integer-encoded string**,
  e.g. `2`. This is what Sparkle compares. It must **strictly exceed** the
  `CFBundleVersion` of the installed build, or Sparkle will report "you're up to
  date." Never reuse a `CFBundleVersion`.

### 2. Build the release DMG

```bash
make dmg
# → build/Release/Afterwords.dmg
```

This DMG is **unsigned and un-notarized** (see *Current distribution reality*).
That is expected today.

### 3. Sign the DMG with `sign_update`

```bash
"$SPARKLE_BIN/sign_update" build/Release/Afterwords.dmg
# → prints, e.g.:
# sparkle:edSignature="aBcD…==" length="12345678"
```

Copy both the `sparkle:edSignature` value and the `length` — you will paste them
verbatim into the appcast `<enclosure>` in step 5.

### 4. Compute and record the SHA-256

Capture the checksum (for the GitHub Release body) and the byte length (to
cross-check against `sign_update`):

```bash
shasum -a 256 build/Release/Afterwords.dmg
stat -f%z build/Release/Afterwords.dmg   # must equal the length from step 3
```

### 5. Write the new appcast `<item>` (do NOT commit yet)

Add an `<item>` inside `<channel>` in `appcast.xml`. Fields:

| Element / attribute | Value |
| --- | --- |
| `<title>` | e.g. `Afterwords 1.1` |
| `<sparkle:version>` | `CFBundleVersion` (the integer string, e.g. `2`) |
| `<sparkle:shortVersionString>` | `CFBundleShortVersionString` (e.g. `1.1`) |
| `<sparkle:minimumSystemVersion>` | `13.0` (optional; matches the deployment target) |
| `<pubDate>` | RFC 822 date — `date -R` or `date -u +'%a, %d %b %Y %H:%M:%S +0000'` |
| `<enclosure url>` | the **GitHub Releases asset download URL** for the DMG (the same bytes signed in step 3 and uploaded in step 7) |
| `<enclosure sparkle:edSignature>` | the signature from step 3 |
| `<enclosure length>` | the `length` from step 3 (== `stat -f%z`) |
| `<enclosure type>` | `application/octet-stream` |

Example:

```xml
<item>
    <title>Afterwords 1.1</title>
    <sparkle:version>2</sparkle:version>
    <sparkle:shortVersionString>1.1</sparkle:shortVersionString>
    <sparkle:minimumSystemVersion>13.0</sparkle:minimumSystemVersion>
    <pubDate>Thu, 29 May 2026 12:00:00 +0000</pubDate>
    <enclosure
        url="https://github.com/adrianwedd/afterwords-app/releases/download/v1.1/Afterwords.dmg"
        sparkle:edSignature="aBcD…=="
        length="12345678"
        type="application/octet-stream" />
</item>
```

**First release:** `appcast.xml` currently has **no `<item>`s** (the empty
channel is intentional — see the header comment in the file) and there are **no
git tags yet**. For this first release you are simply adding the one and only
item.

**Subsequent releases:** keep the previous item(s) below the new one. Sparkle
picks the highest `sparkle:version` it understands, so order is for readability,
not correctness.

### 6. Tag and push

```bash
git tag v1.1
git push origin v1.1
```

(There are no tags yet — `v1.1` would be the first. Match the tag to
`CFBundleShortVersionString`.)

### 7. Create the GitHub Release with the exact signed DMG

Attach the **same** `build/Release/Afterwords.dmg` you signed and hashed, and
put the SHA-256 in the body so users can verify the (unsigned, un-notarized)
download:

```bash
gh release create v1.1 build/Release/Afterwords.dmg \
    --title "Afterwords 1.1" \
    --notes "$(cat <<'EOF'
## Afterwords 1.1

<your release notes here>

---
**Verify your download** (the DMG is unsigned/un-notarized):

```
shasum -a 256 Afterwords.dmg
```
Expected: `<paste the SHA-256 from step 4>`
EOF
)"
```

Notes on the release body:
- There is **no tracked `release-notes-*.md` file** in the repo. Either pass the
  notes inline with `--notes` (as above) or write an ad-hoc file and use
  `--notes-file` — but don't commit that file.
- After creating the release, **confirm the `<enclosure url>` you wrote in
  step 5 matches the asset's actual download URL** on the Releases page (it
  takes the form
  `https://github.com/adrianwedd/afterwords-app/releases/download/<tag>/Afterwords.dmg`).

### 8. Commit and push `appcast.xml` to `main` (the final publish)

```bash
git add appcast.xml Afterwords/Info.plist
git commit -m "chore(release): Afterwords 1.1"
git push origin main
```

This is the moment the release goes live. Existing installs poll the feed on
launch (and on **Check for Updates…**) and will offer the update.

---

## Verifying

Do the **positive checks first** — these catch the common silent failures:

1. **Length matches the published bytes.** The `<enclosure length>` in
   `appcast.xml` must equal `stat -f%z` of the DMG that is actually attached to
   the GitHub Release. A mismatched length is a frequent silent-failure cause.

   ```bash
   # download the published asset, then:
   stat -f%z Afterwords.dmg   # compare to length="…" in appcast.xml
   ```

2. **SHA-256 matches the value posted in the release.**

   ```bash
   shasum -a 256 Afterwords.dmg   # compare to the release body
   ```

3. **End-to-end update offer.** Launch a *previous* build from `/Applications`,
   click **Check for Updates…**, and confirm the new version is offered and
   installs.

If Sparkle reports "you're up to date" when it shouldn't, the usual causes are:

- The installed app's `CFBundleVersion` is **≥** the `sparkle:version` in the
  appcast (bump it — step 1).
- The `sparkle:edSignature` is wrong or missing — Sparkle **rejects the item
  without surfacing why** in the UI (re-run step 3 and re-check the value).
- A stale `raw.githubusercontent.com` CDN/browser cache of the feed — wait a
  minute, or append `?nocache=$(date +%s)` while testing.

For diagnostics, check `~/Library/Logs/DiagnosticReports/` or run:

```bash
log stream --predicate 'process == "Afterwords"'
```

---

## Troubleshooting

**`sign_update`: command not found.**
It is not on `PATH`. Re-run the locate step in *One-time setup* (it lives in the
repo-local `build/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin/`
after `make dmg`, not in the global DerivedData).

**Update never appears ("up to date").**
Triage in this order: (1) installed `CFBundleVersion` vs appcast
`sparkle:version`; (2) `sparkle:edSignature` correct/present; (3) feed cache
(`?nocache=…`). See the *Verifying* failure-mode list above.

**Gatekeeper blocks the first launch.**
Expected — the DMG is unsigned/un-notarized. Users should right-click the app →
**Open**, or clear the quarantine flag:

```bash
xattr -d com.apple.quarantine /Applications/Afterwords.app
```

**Appcast change isn't picked up.**
Confirm `appcast.xml` is committed and pushed to **`main`** (the feed reads from
`main`, not from a tag or a release asset), and that the URL matches `SUFeedURL`
in `Info.plist`.

---

## Rollback

To withdraw a bad release, **supersede it rather than just deleting it** — users
may have already cached the appcast or downloaded the asset:

1. Build and ship a **fixed build with a higher `CFBundleVersion`** following the
   full release flow above. This is the reliable fix; Sparkle will move installs
   forward to it.
2. Remove or supersede the bad `<item>` in `appcast.xml` on `main` so new
   updaters don't see it.
3. Optionally delete the bad GitHub Release / asset (`gh release delete v1.x`)
   so the download stops surfacing.

**Never reuse a `CFBundleVersion`** — even for a rollback, the replacement must
have a strictly higher value.

---

## Key loss / recovery

The EdDSA private key (Keychain account `ed25519` under
`https://sparkle-project.org`) is the **only** thing that can produce a
`sparkle:edSignature` the installed base will accept, because every install only
trusts the `SUPublicEDKey` baked into its own binary.

**If the private key is lost, auto-update cannot recover it.** Existing installs
will not accept updates signed with a new key, and Sparkle has no mechanism to
deliver a new trust root to an old app. Recovery requires going around Sparkle:

1. Generate a new key pair with `generate_keys` (stores a new private key in the
   Keychain, prints a new public key).
2. Update `SUPublicEDKey` in `Afterwords/Info.plist` to the new public key.
3. Build a **bridge release** and distribute it **out-of-band** — users download
   it manually from https://afterwords-app.pages.dev/ or the GitHub Releases
   page. Only once a user is running a build that contains the new
   `SUPublicEDKey` will Sparkle auto-updates signed with the new private key work
   for them again.

In short: a lost private key means a forced, manually-distributed reinstall for
the existing base. Treat the key as a critical, backed-up secret.
