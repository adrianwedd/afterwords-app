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
   `unittest` — no new dependency.

## Architecture

Four components, each understandable and testable in isolation.

### 1. `scripts/release_lib.py` — pure logic (no I/O, no network)

The testable core. Functions:

| Function | Purpose |
|---|---|
| `build_item(version, short_version, url, signature, length, pubdate)` | Produce one appcast `<item>` element/string. |
| `insert_item(appcast_xml, item)` | Insert newest-first into `<channel>` via `ElementTree`; return updated XML. |
| `validate_appcast(xml)` | Structural check (see invariants); returns a list of problems (empty = valid). |
| `assert_consistent(sign_update_length, stat_length, dmg_sha)` | Raise if the `sign_update` length ≠ `stat -f%z`; the byte-identity guard. |

**Validation invariants** (`validate_appcast`):
- XML is well-formed and the `sparkle:` namespace is declared.
- An **empty channel (zero `<item>`s) is valid** — the current committed state
  must pass.
- Every `<item>` has: non-empty `sparkle:edSignature`, `length` an integer > 0,
  a non-empty enclosure `url`, a `sparkle:version`, and a
  `sparkle:shortVersionString`.
- `sparkle:version` values are unique and strictly increasing down the channel
  (no reused `CFBundleVersion`).

### 2. `scripts/release.sh` — orchestration (entry point, wired as `make release`)

Thin shell that sequences I/O and calls into `release_lib.py`. Two phases.

**Dry-run (default — `make release VERSION=x.y`):**
1. Preflight: clean working tree on `main`; `gh auth status` OK; `sign_update`
   located (repo-local `build/DerivedData/.../Sparkle/bin` first); `VERSION`
   strictly greater than the highest existing appcast `sparkle:shortVersionString`,
   and the resolved `CFBundleVersion` strictly greater than the highest
   `sparkle:version`.
2. `make dmg` → `build/Release/Afterwords.dmg`.
3. `sign_update` the DMG → capture `sparkle:edSignature` + `length`.
4. Compute SHA-256 (`shasum -a 256`) and `stat -f%z`.
5. `assert_consistent(...)` — fail loudly on any byte mismatch.
6. Print the exact appcast `<item>` to be inserted and the SHA-256. **Stop here.**

**Publish (`make release VERSION=x.y PUBLISH=1`):**
`PUBLISH=1` re-runs the full dry-run pipeline (steps 1–5) fresh in the same
invocation — it does **not** reuse a prior `build/Release/Afterwords.dmg`. The
bytes that get tagged, released, signed, and hashed are therefore guaranteed to
be the same single artifact. It then continues:
7. `git tag vX.Y` and push the tag.
8. `gh release create vX.Y build/Release/Afterwords.dmg` with the SHA-256 in the
   release body (the finding-#2 interim verification path).
9. **Re-download the published asset** and re-verify its length + SHA-256 against
   the values written into the appcast — closes the loop against an upload that
   doesn't match the signed bytes.
10. `insert_item` into `appcast.xml`; `git add appcast.xml Afterwords/Info.plist`;
    commit (`chore(release): Afterwords x.y`); push `main`. **This is go-live.**

Re-running publish must be safe to abort between steps (idempotent preflight:
detect an existing tag/release for the version and refuse rather than duplicate).

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

- **Byte mismatch** (`sign_update` length ≠ `stat`, or re-downloaded asset ≠
  appcast length/SHA): hard failure, nothing committed/pushed.
- **Version not increasing**: preflight rejects before building.
- **Dirty tree / wrong branch / `gh` not authed**: preflight rejects.
- **Tag or release already exists for the version**: refuse (no silent
  overwrite); direct the user to bump or to the rollback section.
- **`sign_update` not found**: actionable message pointing at the locate step
  (it appears only after `make dmg`).

## Testing

- `scripts/release_lib.py` unit tests (stdlib `unittest`): `build_item` output
  shape; `insert_item` newest-first ordering and namespace preservation;
  `validate_appcast` accepts the empty channel and a valid item, rejects each
  invariant violation; `assert_consistent` passes on equal lengths and raises on
  mismatch.
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

## File map

| Action | Path |
|---|---|
| Create | `scripts/release_lib.py` |
| Create | `scripts/test_release_lib.py` |
| Create | `scripts/release.sh` |
| Modify | `Makefile` — add `release` target |
| Modify | `.github/workflows/ci.yml` — add `verify-appcast` step/job |
| Modify | `RELEASING.md` — `make release` happy path + manual appendix |
