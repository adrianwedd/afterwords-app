# afterwords-app — Sprint 2 Design
**Date:** 2026-05-25  
**Status:** Approved — ready for implementation plan  
**Repo:** `adrianwedd/afterwords-app`

---

## Goal

Wire in the app icon (unblocked, prerequisite for any public screenshot or release) and ship the redesigned GitHub Pages site. Best achievable state before the Apple Developer account is in place for signing/notarization.

---

## Part 1 — App icon

### Problem

`Assets.xcassets` has no `AppIcon.appiconset`. Xcode uses a placeholder grid. The Sparkle update dialog also shows the placeholder. The icon must be added before any public-facing screenshot, release note, or Homebrew cask is prepared.

### Source

`afterwords-icon.svg` at the repo root is the master mark — two comma/quotation glyphs forming the "afterwords" logomark. This SVG is used across all three product surfaces.

**Known geometry note (from design system spec):** The lower comma oval may read as circular rather than teardrop at small rendered sizes. Assess at 16×16 and 32×32 after rasterisation. If it looks circular, increase `ry` on the lower ellipse (try `ry=100`) until it reads as a portrait teardrop. This is a cosmetic fix only — do not alter the overall mark proportions.

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
| 1024×1024 | @1x | icon_512x512@2x.png (same file, per Apple convention) |

### Rasterisation

Use `rsvg-convert` (via `brew install librsvg`) for SVG → PNG at each size. Fallback: `sips -z <h> <w> input.svg --out output.png` (macOS built-in, but lower quality for SVG). If neither produces clean output at 16×16, generate 32×32 and downscale with `sips`.

```bash
for size in 16 32 128 256 512; do
  rsvg-convert -w $size -h $size afterwords-icon.svg -o "icon_${size}x${size}.png"
  rsvg-convert -w $((size*2)) -h $((size*2)) afterwords-icon.svg -o "icon_${size}x${size}@2x.png"
done
```

### AppIcon.appiconset

Create `Afterwords/Assets.xcassets/AppIcon.appiconset/` with all PNG files and a `Contents.json` declaring all sizes. The `Contents.json` format follows Apple's asset catalog schema (see existing `Assets.xcassets/Contents.json` for the header format).

### Verification

After running `make project && make build`:
- Xcode shows the correct icon in the project navigator
- The built `.app`'s Dock tile (or menu-bar area) shows the mark
- Sparkle update dialog (if triggered) shows the icon, not the placeholder grid

`make test` must still pass after adding the asset.

### Commit

```
feat(app): add AppIcon.appiconset from afterwords-icon.svg
```

---

## Part 2 — GitHub Pages site (Surface 3)

### What

Implement the redesigned GitHub Pages site at `adrianwedd.github.io/afterwords-app` using the production-ready design handoff from `afterwords/afterwords-redesign/Surface 3 - afterwords app.html`.

### Approach

**Static HTML, no build step.** Identical approach to the afterwords (main) Sprint 2 GitHub Pages work. The handoff HTML is self-contained; no Astro, no npm.

Steps:
1. Create `docs/` at the repo root.
2. Copy `afterwords/afterwords-redesign/Surface 3 - afterwords app.html` → `docs/index.html`.
3. Copy cloud/app favicon assets from `afterwords/afterwords-redesign/favicons/` (`favicon-cloud-*`, `favicon-cloud-180.png`, `favicon-cloud-192.png`) → `docs/favicons/`. (The app shares the cloud favicon set — copper accent, same mark.)
4. Copy `afterwords/afterwords-redesign/afterwords-icon.svg` → `docs/`.
5. Copy `afterwords/afterwords-redesign/favicons/og-app.svg` → `docs/favicons/`.
6. Update relative asset paths in the HTML to match the `docs/` layout.
7. Wire `og-app.svg` into OG meta tags. Note: Twitter/X requires PNG for OG images — add a `<!-- TODO: convert og-app.svg to PNG via Puppeteer/sharp for Twitter -->` comment in the HTML; leave the SVG reference for now.
8. Enable GitHub Pages in repo settings, source: `docs/` on `main`.

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

Add a GitHub Actions step that verifies `docs/index.html` exists and is non-empty. No HTML validation — the handoff is already QA'd.

The existing `make test` CI job is unchanged. Add Pages deployment as a separate job triggered on push to `main`, only if `docs/` changed.

### Commit

```
feat(docs): implement redesigned GitHub Pages site (Surface 3)
```

---

## Out of scope

- App signing and notarization (blocked on Apple Developer account)
- `appcast.xml` population (blocked on signing)
- Homebrew cask (blocked on notarized DMG)
- VoiceListWindow UX improvements (deferred — no blocking reason, but not sprint-scoped)
- Any new app features
