# Releasing Afterwords

This document describes how to cut a new release. Sparkle 2 enforces Ed25519
signing on the appcast — an item without a valid `sparkle:edSignature` is
silently rejected by the auto-updater, so the steps below must all be
completed and the resulting `appcast.xml` committed to `main`.

The user-facing feed lives at
`https://raw.githubusercontent.com/adrianwedd/afterwords-app/main/appcast.xml`
(referenced by `SUFeedURL` in `Afterwords/Info.plist`). Whatever ships on
`main` is what existing installs see.

## One-time setup

You need the Ed25519 **private key** that pairs with `SUPublicEDKey` in
`Afterwords/Info.plist`. It lives in the macOS Keychain under
`https://sparkle-project.org` (account: `ed25519`). If you lose it you must
generate a new pair and publish a 1.x bridge release — there is no recovery.

If you've never set it up:

```bash
# Sparkle ships sign_update + generate_keys in its Resources/ directory.
# After `make build`, locate them under build/DerivedData (or in the SPM checkout):
find ~/Library/Developer/Xcode/DerivedData -name sign_update -type f
```

## Cutting a release

1. **Bump the version**. Edit `Afterwords/Info.plist`:
   - `CFBundleShortVersionString` → human version, e.g. `1.1`
   - `CFBundleVersion` → monotonic integer, e.g. `2`

2. **Build the signed DMG**.
   ```bash
   make dmg
   # → build/Release/Afterwords.dmg
   ```
   Note: `make dmg` produces an **unsigned** DMG today. Until Developer ID
   signing is wired up, users will need to right-click → Open the first time.

3. **Tag and push**.
   ```bash
   git tag v1.1
   git push origin v1.1
   ```

4. **Create the GitHub Release** with `gh`, attaching the DMG:
   ```bash
   gh release create v1.1 build/Release/Afterwords.dmg \
       --title "Afterwords 1.1" \
       --notes-file release-notes-1.1.md
   ```

5. **Sign the DMG with Sparkle's `sign_update`**:
   ```bash
   sign_update build/Release/Afterwords.dmg
   # → prints: sparkle:edSignature="…" length="…"
   ```

6. **Update `appcast.xml`** with a new `<item>` block:
   - `<sparkle:version>` → `CFBundleVersion` (integer)
   - `<sparkle:shortVersionString>` → `CFBundleShortVersionString`
   - `<pubDate>` → RFC 822 date (`date -R` or `date -u +'%a, %d %b %Y %H:%M:%S +0000'`)
   - `<enclosure url>` → the GitHub Releases asset URL for the DMG
   - `<enclosure sparkle:edSignature>` → from step 5
   - `<enclosure length>` → from step 5 (or `stat -f%z build/Release/Afterwords.dmg`)

   Keep the previous item(s) below the new one; Sparkle picks the highest
   `sparkle:version` it understands.

7. **Commit and push `appcast.xml`** to `main`. Existing installs poll the feed
   on launch and will offer the update.

## Verifying

After pushing the appcast, launch a previous version of the app from `/Applications`
and click "Check for Updates…". You should see the new version offered. If
Sparkle silently reports "you're up to date," the most common causes are:

- `CFBundleVersion` in the installed app ≥ `sparkle:version` in the appcast
- `sparkle:edSignature` is incorrect or missing — Sparkle rejects the item without surfacing why in the UI
- Browser/CDN cache of `raw.githubusercontent.com` is stale — wait a minute or
  pass `?nocache=…` while testing.

Check `~/Library/Logs/DiagnosticReports/` or run `log stream --predicate
'process == "Afterwords"'` for Sparkle's diagnostic output.
