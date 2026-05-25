# afterwords-app — Sprint 2 Design
**Date:** 2026-05-25  
**Status:** Revised — ready for implementation plan  
**Repo:** `adrianwedd/afterwords-app`

---

## Goal

Wire in the app icon (unblocked, prerequisite for any public screenshot or release) and ship the redesigned GitHub Pages site. Best achievable state before the Apple Developer account is in place for signing/notarization.

---

## Part 1 — App icon

### Problem

`Assets.xcassets` has no `AppIcon.appiconset`. Xcode uses a placeholder grid. The Sparkle update dialog also shows the placeholder. The icon must be added before any public-facing screenshot, release note, or Homebrew cask is prepared.

### Source

`afterwords-icon.svg` at the repo root is the master mark — two comma/quotation glyphs forming the "afterwords" logomark. If it is not already present in this repo, copy it manually from the sibling local checkout at `../afterwords/afterwords-redesign/afterwords-icon.svg`; do not add a submodule or CI fetch for this sprint.

**Geometry is fixed for this sprint.** Do not tune the SVG by eye during implementation. The accepted source uses the lower oval `ry=92`; if a future visual QA pass changes that geometry, it must update the source SVG and this spec together.

### Required sizes (macOS)

| Size | Scale | Filename |
|------|-------|----------|
| 16×16 | @1x | icon_16x16.png |
| 16×16 | @2x | icon_16x16@2x.png |
| 32×32 | @1x | icon_32x32.png |
| 32×32 | @2x | icon_32x32@2x.png |
| 128×128 | @1x | icon_128x128.png |
| 128×128 | @2x | icon_128x128@2x.png |
| 256×256 | @1x | icon_256x256.png |
| 256×256 | @2x | icon_256x256@2x.png |
| 512×512 | @1x | icon_512x512.png |
| 512×512 | @2x | icon_512x512@2x.png |

### Rasterisation

Use `rsvg-convert` (via `brew install librsvg`) for SVG → PNG at each size. CI must install `librsvg` with Homebrew before any rasterisation check. Fallback for local implementation only: `sips -z <h> <w> input.svg --out output.png` (macOS built-in, but lower quality for SVG).

```bash
for size in 16 32 128 256 512; do
  rsvg-convert -w $size -h $size afterwords-icon.svg -o "icon_${size}x${size}.png"
  rsvg-convert -w $((size*2)) -h $((size*2)) afterwords-icon.svg -o "icon_${size}x${size}@2x.png"
done
```

### AppIcon.appiconset

Create `Afterwords/Assets.xcassets/AppIcon.appiconset/` with all PNG files and the exact `Contents.json` below.

```json
{
  "images": [
    { "idiom": "mac", "size": "16x16", "scale": "1x", "filename": "icon_16x16.png" },
    { "idiom": "mac", "size": "16x16", "scale": "2x", "filename": "icon_16x16@2x.png" },
    { "idiom": "mac", "size": "32x32", "scale": "1x", "filename": "icon_32x32.png" },
    { "idiom": "mac", "size": "32x32", "scale": "2x", "filename": "icon_32x32@2x.png" },
    { "idiom": "mac", "size": "128x128", "scale": "1x", "filename": "icon_128x128.png" },
    { "idiom": "mac", "size": "128x128", "scale": "2x", "filename": "icon_128x128@2x.png" },
    { "idiom": "mac", "size": "256x256", "scale": "1x", "filename": "icon_256x256.png" },
    { "idiom": "mac", "size": "256x256", "scale": "2x", "filename": "icon_256x256@2x.png" },
    { "idiom": "mac", "size": "512x512", "scale": "1x", "filename": "icon_512x512.png" },
    { "idiom": "mac", "size": "512x512", "scale": "2x", "filename": "icon_512x512@2x.png" }
  ],
  "info": {
    "author": "xcode",
    "version": 1
  }
}
```

### Verification

After running `make project && make build`:
- Xcode shows the correct icon in the project navigator
- The built `.app`'s Dock tile (or menu-bar area) shows the mark
- Automated gate: all ten PNG files above exist and are non-empty; `Contents.json` contains exactly the ten image entries above; `make test` passes

Manual visual acceptance: inspect 16×16 and 32×32 rendered PNGs at 100% zoom. They pass if both comma glyphs are visible as separate shapes and the lower glyph is taller than it is wide. Sparkle dialog verification is blocked until signing/appcast work is unblocked and is not a sprint gate.

### Commit

```
feat(app): add AppIcon.appiconset from afterwords-icon.svg
```

---

## Part 2 — GitHub Pages site (Surface 3)

### What

Implement the redesigned GitHub Pages site at `adrianwedd.github.io/afterwords-app` using the production-ready design handoff from the sibling local checkout `../afterwords/afterwords-redesign/Surface 3 - afterwords app.html`.

### Approach

**Static HTML, no build step.** Identical approach to the afterwords (main) Sprint 2 GitHub Pages work. The handoff HTML is self-contained; no Astro, no npm.

Steps:
1. Create `docs/` at the repo root.
2. Copy `../afterwords/afterwords-redesign/Surface 3 - afterwords app.html` → `docs/index.html`.
3. Copy cloud/app favicon assets from `../afterwords/afterwords-redesign/favicons/` (`favicon-cloud-*`, `favicon-cloud-180.png`, `favicon-cloud-192.png`) → `docs/favicons/`. (The app shares the cloud favicon set — copper accent, same mark.)
4. Copy `../afterwords/afterwords-redesign/afterwords-icon.svg` → `docs/`.
5. Convert `../afterwords/afterwords-redesign/favicons/og-app.svg` to `docs/favicons/og-app.png` at 1200×630. Do not ship SVG as `og:image`.
6. Update relative asset paths using this mapping only:
   - `afterwords-icon.svg` → `afterwords-icon.svg`
   - `favicons/*` → `favicons/*`
   - links to `Surface 1 - afterwords local.html` → `https://adrianwedd.github.io/afterwords/`
   - links to `Surface 2a - cloud landing.html`, `Surface 2b - dashboard.html`, or `Surface 2c - api docs.html` → `https://afterwords-cloud.pages.dev/`
7. Wire OG/Twitter image meta tags to the absolute URL `https://adrianwedd.github.io/afterwords-app/favicons/og-app.png`.
8. Enable GitHub Pages in repo settings with source: GitHub Actions.

### Design tokens (invariants — do not change)

The app surface uses the copper accent (`#B87333`) — same as cloud, distinct from afterwords local which has no accent.

```css
--color-bg:          #1C1C1A;
--color-bg-elevated: #222220;
--color-accent:      #B87333;   /* copper — CTAs, active nav */
--color-fg:          #EDE8DF;
--color-fg-muted:    #A09A8F;
--color-border:      #3A3A37;
```

### CI

Add a GitHub Actions step named `Verify GitHub Pages assets` that verifies `docs/index.html` and `docs/favicons/og-app.png` exist and are non-empty. No HTML validation — the handoff is already QA'd.

The existing `make test` CI job is unchanged. Add Pages deployment as a separate job triggered on push to `main`, only if `docs/` changed. Because deployment uses Actions, the repository Pages setting must be `GitHub Actions`, not `docs/` on `main`.

### Commit

```
feat(docs): implement redesigned GitHub Pages site (Surface 3)
```

---

## Out of scope

- App signing and notarization (blocked on Apple Developer account)
- `appcast.xml` population (blocked on signing)
- Sparkle update-dialog icon verification (blocked on signing/appcast)
- Homebrew cask (blocked on notarized DMG)
- VoiceListWindow UX improvements (deferred — no blocking reason, but not sprint-scoped)
- Any new app features
