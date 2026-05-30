# afterwords-app — Interim Release Hardening (Design)

**Date:** 2026-05-30
**Status:** Approved (brainstorming) — ready for implementation plan
**Author:** Adrian Wedd + Claude Code

## Goal

Turn the manual 8-step release runbook in `RELEASING.md` into one reliable,
self-verifying command; publish a SHA-256 with every release; and add a
no-secret CI guard so a malformed `appcast.xml` can never reach `main`.

The app stays **unsigned and un-notarized** this sprint — Developer ID signing,
notarization, and a Homebrew cask remain blocked on an Apple Developer account
and are explicitly out of scope.

## Background / current state

- Releases today are entirely manual: build → `sign_update` → hash → hand-write
  the appcast `<item>` → tag → `gh release create` → commit `appcast.xml`.
- `RELEASING.md` itself flags the `length`/SHA/`edSignature` byte-identity as
  "a frequent silent-failure cause": the appcast `<enclosure length>` and the
  `sparkle:edSignature` must describe the **exact bytes** the user downloads, or
  Sparkle silently rejects the item with no UI feedback.
- There are no git tags, no GitHub Releases, and `appcast.xml` is an
  intentionally empty channel (valid until the first signed item exists).
- The Sparkle EdDSA private key lives **only** in the user's macOS Keychain
  (account `ed25519`, service `https://sparkle-project.org`).

## Key decisions

1. **Automation runs locally only — no GitHub secret.** The release command runs
   on the user's Mac using the Keychain key. CI never signs and never sees the
   key.
2. **Dry-run by default; explicit publish (approach B).** `make release
   VERSION=x.y` performs everything *up to the irreversible line* and stops.
   `PUBLISH=1` performs the irreversible steps. The publish steps are
   irreversible to the install base — once `appcast.xml` is on `main`, every
   running copy offers the update — so a human gate before them is required.
3. **XML is edited with a parser, never `sed`.** Appcast item generation and
   insertion use Python `ElementTree`. Pure logic is unit-tested with stdlib
   `unittest` — no new dependency. `appcast.xml` opens with a documentation
   comment block that **must survive the rewrite**, so the serializer must
   preserve comments (`ElementTree` with `insert_comments=True`, or a targeted
   string insertion — never a plain re-serialize that drops them).

## Architecture

Four components, each understandable and testable in isolation.

### 1. `scripts/release_lib.py` — pure logic (no I/O, no network)

The testable core. Functions:

| Function | Purpose |
|---|---|
| `build_item(version, short_version, url, signature, length, pubdate)` | Produce one appcast `<item>` element/string. |
| `insert_item(appcast_xml, item)` | Insert newest-first into `<channel>`, **preserving the leading documentation comment**; return updated XML. |
| `validate_appcast(xml)` | Structural check (see invariants); returns a list of problems (empty = valid). |
| `assert_consistent(sign_update_length, stat_length, dmg_sha)` | Raise if the `sign_update` length ≠ `stat -f%z`; the byte-identity guard. |

**Validation invariants** (`validate_appcast`):
- XML is well-formed and the `sparkle:` namespace is declared.
- An **empty channel (zero `<item>`s) is valid** — the current committed state
  must pass.
- Every `<item>` has: non-empty `sparkle:edSignature`, `length` an integer > 0,
  a non-empty enclosure `url`, a `sparkle:version`, and a
  `sparkle:shortVersionString`.
- `sparkle:version` values are unique and **strictly decreasing top-to-bottom**
  (newest item first — matching `insert_item`'s newest-first insertion); no
  reused `CFBundleVersion`.

### 2. `scripts/release.sh` — orchestration (entry point, wired as `make release`)

Thin shell that sequences I/O and calls into `release_lib.py`. Two phases.

**Dry-run (default — `make release VERSION=x.y`):**
1. Preflight (no build yet): clean working tree on `main`; `git fetch origin` and
   assert local `main` is **not behind** `origin/main` (no stale-branch publish);
   `gh auth status` OK; `VERSION` strictly greater than the highest existing
   appcast `sparkle:shortVersionString` **and** the target `CFBundleVersion`
   strictly greater than the highest `sparkle:version` — both vacuously true on
   the empty (first-release) channel.
2. Bump `Afterwords/Info.plist` (`CFBundleShortVersionString`, `CFBundleVersion`)
   in the working tree so the DMG embeds the release version.
3. `make dmg` → `build/Release/Afterwords.dmg`. `sign_update` lives in the
   DerivedData bundle this step produces, so it is resolved **after** the build,
   never in preflight.
4. Resolve `sign_update` from the freshly built bundle; sign the DMG → capture
   `sparkle:edSignature` + `length`.
5. Compute SHA-256 (`shasum -a 256`) and `stat -f%z`; `assert_consistent(...)` —
   fail loudly on any byte mismatch.
6. Build the appcast `<item>` (enclosure URL is deterministic,
   `…/releases/download/vX.Y/Afterwords.dmg`); print it plus the SHA-256, then
   **revert the Info.plist bump** so the tree is clean again. **Stop here.**

**Publish (`make release VERSION=x.y PUBLISH=1`):**
First-run publish repeats steps 1–5 fresh (no reuse of a prior DMG, so the
tagged, released, and signed bytes are one artifact), then:
7. Commit the Info.plist bump (`chore(release): bump to x.y`) and `git tag vX.Y`
   **on that commit** — so the tag captures the correct version — then push the
   commit and tag.
8. `gh release create vX.Y build/Release/Afterwords.dmg` with the SHA-256 in the
   release body (the finding-#2 interim verification path).
9. Re-download the published asset; re-verify its **length** against the value
   written into the appcast `<enclosure>` and its **SHA-256** against the release
   body — closing the loop against an upload that doesn't match the signed bytes.
10. `insert_item` into `appcast.xml`; commit (`chore(release): publish x.y
    appcast`) and push `main`. **This is go-live** — the feed is read from
    `main`'s HEAD, deliberately after the tag.

**Resumable, not just abort-safe.** If `vX.Y`'s tag and release asset already
exist (a prior run died after step 8), publish must **not** rebuild — a rebuild
yields different bytes and a different signature. It instead downloads the
published asset, `sign_update`s *those* bytes, and resumes at step 9/10. Only
when no tag/release exists does it build fresh. A tag that exists with a
missing/garbled asset is a refuse-and-report state, never an auto-overwrite.

### 3. CI job `verify-appcast`

Added to `.github/workflows/ci.yml` (or a small sibling workflow). On every push
and PR: run `release_lib.py`'s unit tests and `validate_appcast(appcast.xml)`.
No secret, no key, no network. Catches the silent-rejection class — malformed
XML, empty/missing `edSignature`, `length="0"`, non-increasing version — before
it can merge to `main`. Keeps the existing read-only `permissions: contents:
read`.

### 4. `RELEASING.md` rewrite

Promote `make release` to the happy path (dry-run, review, `PUBLISH=1`). Demote
the existing 8 manual steps to an **"Under the hood / recovery"** appendix — kept
verbatim as the fallback if the script ever breaks, and as the source of truth
the script automates. The "Current distribution reality", "Key loss / recovery",
and "Rollback" sections stay as-is.

## Data flow

```
VERSION=x.y ─▶ preflight ─▶ make dmg ─▶ sign_update ─▶ {edSignature,length}
                                            │
                shasum -a 256, stat -f%z ───┤
                                            ▼
                              assert_consistent  ──(mismatch)──▶ FAIL, stop
                                            │ ok
                                            ▼
                         print <item> + SHA-256   ◀── dry-run ends here
                                            │ PUBLISH=1
                                            ▼
              tag ─▶ gh release (DMG + SHA in body) ─▶ re-download & re-verify
                                            │
                                            ▼
              insert_item ─▶ commit appcast.xml + Info.plist ─▶ push main (LIVE)
```

## Error handling

- **Byte mismatch** (`sign_update` length ≠ `stat`, or re-downloaded asset's
  length ≠ appcast `<enclosure>` / SHA-256 ≠ release body): hard failure, nothing
  committed/pushed.
- **Local `main` behind `origin/main`**: preflight rejects before any build —
  prevents tagging/releasing from a stale tree.
- **Version not increasing**: preflight rejects before building; the empty
  first-release channel accepts any version.
- **Dirty tree / wrong branch / `gh` not authed**: preflight rejects.
- **Tag + release already exist** (partial prior run): **resume** from the
  published bytes (download → `sign_update` → step 9/10), never rebuild or
  overwrite. Tag without a usable asset: refuse and report.
- **`sign_update` not found**: actionable message — it only appears after
  `make dmg`, so this should fire only if the build failed to fetch Sparkle.

## Testing

- `scripts/release_lib.py` unit tests (stdlib `unittest`): `build_item` output
  shape; `insert_item` newest-first ordering, namespace **and leading-comment
  preservation**; `validate_appcast` accepts the empty channel and a valid item
  and rejects each invariant violation (incl. non-decreasing versions and an
  empty `edSignature`); `assert_consistent` passes on equal lengths and raises on
  mismatch; the version-compare helper treats the empty channel as "any version
  allowed" rather than erroring on `None`.
- CI runs these tests plus `validate_appcast` against the committed
  `appcast.xml`.
- The shell orchestration is verified by a **dry-run against the real repo** (no
  publish) during implementation: confirm it builds, signs, asserts consistency,
  and prints a well-formed item without tagging, releasing, or committing.

## Out of scope (explicit)

- Developer ID signing and notarization.
- Any CI-side signing or a `SPARKLE_PRIVATE_KEY` GitHub secret.
- Homebrew cask.
- Changes to appcast hosting or the `SUFeedURL`.
- The Apple Developer account itself (external blocker).

## Documentation caveats (to verify, then note in `RELEASING.md`)

These are not design requirements — they are claims to confirm and document, not
assert blindly:

- **Gatekeeper on auto-update.** It is *unconfirmed* whether a Sparkle-delivered
  update to this unsigned/un-notarized app re-triggers Gatekeeper quarantine on
  each update (Sparkle 2 generally does not re-prompt for an already-approved
  app). During implementation, verify the actual behaviour and add an honest note
  to `RELEASING.md` — do not state it as fact until checked.
- **EdDSA Keychain account.** `generate_keys` stores the private key under the
  default account `ed25519` / service `https://sparkle-project.org`; running
  `generate_keys` for another Sparkle app on the same Mac could overwrite it.
  The key already exists, so this is a one-line "back up / don't regenerate"
  caveat in the key-setup section — not a code change.

## File map

| Action | Path |
|---|---|
| Create | `scripts/release_lib.py` |
| Create | `scripts/test_release_lib.py` |
| Create | `scripts/release.sh` |
| Modify | `Makefile` — add `release` target |
| Modify | `.github/workflows/ci.yml` — add `verify-appcast` step/job |
| Modify | `RELEASING.md` — `make release` happy path + manual appendix |
