#!/usr/bin/env bash
# Reliable Sparkle release for the UNSIGNED Afterwords DMG.
#
#   make release VERSION=1.1            # dry-run: build, sign, hash, print item
#   make release VERSION=1.1 PUBLISH=1  # go live: tag, release, publish appcast
#
# CFBundleVersion (Sparkle's comparator) is derived as highest+1, so the
# strict-monotonic invariant cannot be violated by operator error. The EdDSA
# private key is read from the local Keychain by sign_update and never leaves
# this machine.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

LIB="scripts/release_lib.py"
APPCAST="appcast.xml"
PLIST="Afterwords/Info.plist"
DMG="build/Release/Afterwords.dmg"
APP_VERSION="${VERSION:?Set VERSION=x.y (e.g. make release VERSION=1.1)}"
PUBLISH="${PUBLISH:-0}"
TAG="v${APP_VERSION}"
ASSET_URL="https://github.com/adrianwedd/afterwords-app/releases/download/${TAG}/Afterwords.dmg"

# Trust anchor for resume: the built DMG's SHA-256, committed to git at original
# publish time. resume_from_published verifies the re-downloaded asset against
# THIS file — never against the mutable GitHub release body (signing-oracle fix).
MANIFEST_DIR="release-manifest"
MANIFEST="${MANIFEST_DIR}/${APP_VERSION}.sha256"

ITEM_FILE=""
trap 'rm -f "$ITEM_FILE"' EXIT

die() { echo "ERROR: $*" >&2; exit 1; }
note() { echo ">>> $*"; }

# ---- Preflight (no build yet) ----------------------------------------------
preflight() {
  note "Preflight"
  [ "$(git rev-parse --abbrev-ref HEAD)" = "main" ] || die "not on main"
  [ -z "$(git status --porcelain --untracked-files=no)" ] || die "uncommitted changes to tracked files"
  git fetch --quiet origin main
  [ "$(git rev-list --count HEAD..origin/main)" = "0" ] \
    || die "local main is behind origin/main — pull first"
  gh auth status >/dev/null 2>&1 || die "gh not authenticated (gh auth login)"

  # Ordering guard: VERSION must be strictly greater than every published
  # short version (this also rejects exact reuse). Empty channel accepts anything.
  python3 "$LIB" version-ok --candidate "$APP_VERSION" "$APPCAST" \
    || die "VERSION $APP_VERSION must be strictly greater than the highest published version (and must not reuse one)"

  HIGHEST="$(python3 "$LIB" highest-version "$APPCAST")"
  BUNDLE=$(( ${HIGHEST:-0} + 1 ))
  note "Derived CFBundleVersion=$BUNDLE (highest was ${HIGHEST:-none})"
}

# ---- Build + sign + hash (produces a single artifact) ----------------------
build_sign_hash() {
  note "Bumping $PLIST to $APP_VERSION / $BUNDLE"
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $APP_VERSION" "$PLIST"
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUNDLE" "$PLIST"

  note "make dmg"
  make dmg > /tmp/afterwords-release-build.log 2>&1 \
    || die "make dmg failed — see /tmp/afterwords-release-build.log"

  SIGN_UPDATE="$(find build/DerivedData ~/Library/Developer/Xcode/DerivedData \
    -name sign_update -type f 2>/dev/null | head -n1)"
  [ -n "$SIGN_UPDATE" ] || die "sign_update not found (did make dmg fetch Sparkle?)"

  local out; out="$("$SIGN_UPDATE" "$DMG")"
  SIGNATURE="$(printf '%s' "$out" | sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p')"
  SIGN_LEN="$(printf '%s' "$out" | sed -n 's/.*length="\([0-9]*\)".*/\1/p')"
  [ -n "$SIGNATURE" ] && [ -n "$SIGN_LEN" ] || die "could not parse sign_update output: $out"

  STAT_LEN="$(stat -f%z "$DMG")"
  SHA256="$(shasum -a 256 "$DMG" | awk '{print $1}')"
  # Byte-identity guard: the signed length must equal the bytes on disk.
  [ "$SIGN_LEN" = "$STAT_LEN" ] || die "byte mismatch sign_update=$SIGN_LEN stat=$STAT_LEN"

  # Persist the canonical SHA-256 to the committed manifest. This is the SINGLE
  # source of truth a later 'resume' run trusts. Written here (build time, where
  # the SHA is first known) and git-committed at the publish step below, so it
  # lands in git history at the tagged commit and cannot be altered by anyone
  # who can only edit the (mutable) GitHub release body.
  mkdir -p "$MANIFEST_DIR"
  printf '%s  Afterwords.dmg\n' "$SHA256" > "$MANIFEST"

  PUBDATE="$(date -u +'%a, %d %b %Y %H:%M:%S +0000')"
  ITEM_FILE="$(mktemp)"
  python3 "$LIB" build-item \
    --short "$APP_VERSION" --bundle "$BUNDLE" --url "$ASSET_URL" \
    --sig "$SIGNATURE" --length "$SIGN_LEN" --pubdate "$PUBDATE" > "$ITEM_FILE"
}

# ---- Recovery: tag pushed but 'gh release create' failed --------------------
# The publish path pushes main+tag atomically, THEN creates the release. If
# release creation fails (network, gh auth expiry), a re-run lands here: the
# tag exists but there is no release to download. Recover by publishing the
# still-local DMG — but only after verifying it against the committed SHA
# manifest, the same trust anchor resume uses. Never publish unverifiable bytes.
recreate_missing_release() {
  note "Tag $TAG exists but the GitHub release is missing — recovering from local DMG"
  [ -f "$MANIFEST" ] || die "no committed SHA manifest at $MANIFEST — cannot verify any local DMG. Delete the remote tag (git push origin :refs/tags/$TAG) and re-run the full release."
  local expected_sha actual_sha
  expected_sha="$(sed -n 's/^\([0-9a-f]\{64\}\) .*/\1/p' "$MANIFEST" | head -n1)"
  [ -n "$expected_sha" ] || die "manifest $MANIFEST contains no valid SHA-256 — cannot verify any local DMG"
  [ -f "$DMG" ] || die "no local DMG at $DMG to publish, and no release asset exists. A rebuild would produce different bytes than the committed manifest; delete the remote tag and re-run the full release to regenerate both together."
  actual_sha="$(shasum -a 256 "$DMG" | awk '{print $1}')"
  [ "$actual_sha" = "$expected_sha" ] || die "local DMG SHA-256 ($actual_sha) does not match the committed manifest $MANIFEST ($expected_sha) — refusing to publish unverifiable bytes"
  gh release create "$TAG" "$DMG" \
    --title "Afterwords $APP_VERSION" \
    --notes "$(printf 'Afterwords %s\n\n---\n**Verify your download** (the DMG is unsigned/un-notarized):\n\n```\nshasum -a 256 Afterwords.dmg\n```\nExpected: `%s`\n' "$APP_VERSION" "$actual_sha")"
  note "Release $TAG recreated from verified local DMG"
}

# ---- Resume: reuse already-published bytes (never rebuild) ------------------
resume_from_published() {
  note "Tag $TAG and release already exist — resuming from published bytes"
  local tmp; tmp="$(mktemp -d)"
  gh release download "$TAG" --pattern "Afterwords.dmg" --dir "$tmp" \
    || die "release $TAG exists but Afterwords.dmg asset is missing — fix manually"
  SIGN_UPDATE="$(find build/DerivedData ~/Library/Developer/Xcode/DerivedData \
    -name sign_update -type f 2>/dev/null | head -n1)"
  [ -n "$SIGN_UPDATE" ] || die "sign_update not found — run 'make dmg' once to fetch Sparkle"
  # Integrity: never sign bytes we can't verify. The trusted SHA-256 is the one
  # the original publish run committed to git at $MANIFEST — NOT the mutable
  # GitHub release body. Reading it from git closes the signing-oracle hole:
  # an attacker who replaces the release asset cannot also rewrite git history,
  # so a tampered asset fails this check and is never signed. Fail closed if the
  # manifest entry is absent or mismatched — no release-body fallback.
  local expected_sha actual_sha
  [ -f "$MANIFEST" ] || die "no committed SHA manifest at $MANIFEST for $TAG — refusing to re-sign unverifiable bytes. The trust anchor lives in git, not the release body; a fresh local build ('make release VERSION=$APP_VERSION') is required to (re)generate it before resuming."
  expected_sha="$(sed -n 's/^\([0-9a-f]\{64\}\) .*/\1/p' "$MANIFEST" | head -n1)"
  [ -n "$expected_sha" ] || die "manifest $MANIFEST exists but contains no valid SHA-256 — refusing to re-sign unverifiable bytes (regenerate via a fresh local build)"
  actual_sha="$(shasum -a 256 "$tmp/Afterwords.dmg" | awk '{print $1}')"
  [ "$actual_sha" = "$expected_sha" ] || die "downloaded DMG SHA-256 ($actual_sha) does not match the committed manifest $MANIFEST ($expected_sha) — possible tampering, aborting"
  local out; out="$("$SIGN_UPDATE" "$tmp/Afterwords.dmg")"
  SIGNATURE="$(printf '%s' "$out" | sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p')"
  SIGN_LEN="$(printf '%s' "$out" | sed -n 's/.*length="\([0-9]*\)".*/\1/p')"
  [ -n "$SIGNATURE" ] && [ -n "$SIGN_LEN" ] || die "could not parse sign_update output: $out"
  SHA256="$actual_sha"
  HIGHEST="$(python3 "$LIB" highest-version "$APPCAST")"
  BUNDLE=$(( ${HIGHEST:-0} + 1 ))
  PUBDATE="$(date -u +'%a, %d %b %Y %H:%M:%S +0000')"
  ITEM_FILE="$(mktemp)"
  python3 "$LIB" build-item \
    --short "$APP_VERSION" --bundle "$BUNDLE" --url "$ASSET_URL" \
    --sig "$SIGNATURE" --length "$SIGN_LEN" --pubdate "$PUBDATE" > "$ITEM_FILE"
  rm -rf "$tmp"
}

# ---- Publish appcast (the go-live commit) ----------------------------------
publish_appcast() {
  note "Re-verify published asset"
  local tmp; tmp="$(mktemp -d)"
  gh release download "$TAG" --pattern "Afterwords.dmg" --dir "$tmp" --clobber
  [ "$(stat -f%z "$tmp/Afterwords.dmg")" = "$SIGN_LEN" ] \
    || die "published asset length != signed length"
  [ "$(shasum -a 256 "$tmp/Afterwords.dmg" | awk '{print $1}')" = "$SHA256" ] \
    || die "published asset SHA-256 != local SHA-256"

  note "Splicing item into $APPCAST"
  python3 "$LIB" insert-item "$APPCAST" "$ITEM_FILE" > "$APPCAST.tmp"
  python3 "$LIB" validate "$APPCAST.tmp" \
    || { rm -f "$APPCAST.tmp"; die "resulting appcast failed validation"; }
  mv "$APPCAST.tmp" "$APPCAST"

  git add "$APPCAST"
  git commit -m "chore(release): publish $APP_VERSION appcast"
  git push origin main
  note "LIVE — existing installs will offer $APP_VERSION"
  rm -rf "$tmp"
}

main() {
  preflight

  if git ls-remote --exit-code --tags origin "$TAG" >/dev/null 2>&1; then
    [ "$PUBLISH" = "1" ] || die "tag $TAG already exists — re-run with PUBLISH=1 to resume"
    gh release view "$TAG" >/dev/null 2>&1 || recreate_missing_release
    resume_from_published
    publish_appcast
    return
  fi

  build_sign_hash

  note "Proposed appcast item:"
  cat "$ITEM_FILE"
  note "SHA-256: $SHA256"

  if [ "$PUBLISH" != "1" ]; then
    note "Dry-run complete. Reverting $PLIST. Re-run with PUBLISH=1 to go live."
    git checkout -- "$PLIST"
    # The manifest is only a trust anchor for a committed release; on dry-run it
    # is uncommitted scratch — discard it so 'git status' stays clean.
    rm -f "$MANIFEST"
    return
  fi

  note "Publishing $APP_VERSION"
  # Commit the version bump AND the SHA manifest in the same commit that gets
  # tagged, so the trusted SHA is anchored in git history at the tag. resume
  # later verifies the re-downloaded asset against this committed file.
  git add "$PLIST" "$MANIFEST"
  git commit -m "chore(release): bump to $APP_VERSION + record DMG SHA-256 manifest"
  if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
    die "local tag $TAG already exists (prior failed push?) — run 'git tag -d $TAG' and retry"
  fi
  git tag "$TAG"
  git push --atomic origin main "$TAG"
  gh release create "$TAG" "$DMG" \
    --title "Afterwords $APP_VERSION" \
    --notes "$(printf 'Afterwords %s\n\n---\n**Verify your download** (the DMG is unsigned/un-notarized):\n\n```\nshasum -a 256 Afterwords.dmg\n```\nExpected: `%s`\n' "$APP_VERSION" "$SHA256")"
  publish_appcast
}

main "$@"
