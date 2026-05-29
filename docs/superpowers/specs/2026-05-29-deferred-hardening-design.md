# Design — Deferred hardening + Sparkle auto-check

**Date:** 2026-05-29
**Status:** Approved (approaches A/A/A)
**Scope:** Three small, independent changes deferred from the 2026-05-29 security
review and roadmap. Each ships on its own; there is no ordering dependency
between them.

## Background

The security review (`docs/security-review-2026-05-29.md`) left two findings open
as "optional" hardening, and the roadmap listed "wire up Sparkle." Investigation
during brainstorming established that **Sparkle is already fully wired** (package
dependency, `SUFeedURL` + `SUPublicEDKey`, `UpdaterController`, gated "Check for
Updates…" menu item, valid empty `appcast.xml`, complete `RELEASING.md` runbook,
keypair in Keychain). The only genuine Sparkle gap is that it is **manual-check
only** — there is no automatic background check configured and no user control
for it.

Security finding **#2 (signing/notarization) is explicitly out of scope**: it
requires an Apple Developer Program membership, which is not available. Writing
signing tooling now would be untestable and premature; the interim mitigation
(publish DMG SHA-256 in each Release) is already documented in `RELEASING.md`.

This design covers the three actionable, no-external-dependency items:

1. **#4** — Response-size bound on localhost fetches.
2. **#5** — Remove the third-party Google Fonts dependency from the web docs.
3. **Sparkle** — Automatic update checks with a Settings toggle.

---

## 1. Response-size bound (security finding #4)

### Problem

`SamplePlayer.fetchAndPlay` (`URLSession.shared.data(from:)`) and
`HealthMonitor.handleHealthResponse` (`JSONDecoder().decode`) accept the full
localhost response with no size cap. A buggy or compromised local server could
return an oversized body. Severity is INFO — the trust boundary is the user's own
loopback server, and both paths already sit behind short timeouts (HealthMonitor
uses a 3s `timeoutIntervalForResource`).

### Approach (A — additive guard, no structural refactor)

Add a small, pure, unit-testable guard and apply it at both fetch sites **before**
the expensive second step (JSON decode / `NSSound` decode). We do **not**
restructure HealthMonitor's invariant-heavy `dataTask` / `pollInFlight` / timer
machinery (that was approach B — rejected as regression risk disproportionate to
an INFO finding). The existing resource timeouts remain the transfer backstop;
this guard caps the bytes we will *accept and act on*, matching the review's
literal recommendation ("cap accepted Content-Length / bytes").

**Honest limitation:** because both sites use buffered (non-streaming) loads, the
guard rejects an oversized payload *after* it has been buffered but *before* it is
decoded/played. It does not bound peak transfer memory mid-stream — that is
approach B, deliberately out of scope. The combination of (short resource
timeout) + (reject-before-decode) is the proportionate fix here.

### New file: `Afterwords/Services/ResponseLimit.swift`

```swift
import Foundation

/// Byte-size caps for accepted localhost responses, plus a pure predicate that
/// callers apply before decoding/playing a fetched body. Defense-in-depth for a
/// localhost-only threat model (security review 2026-05-29, finding #4).
enum ResponseLimit {
    /// Cap for the /health JSON body. Real payloads are tens of KB; this is
    /// far above any legitimate response.
    static let health = 5 * 1024 * 1024      // 5 MiB

    /// Cap for a /synthesize WAV sample. Fixed-phrase samples are ~30–100 KB;
    /// this is far above any legitimate response.
    static let sample = 25 * 1024 * 1024     // 25 MiB

    /// True when the response should be rejected as too large.
    ///
    /// Rejects when the advertised Content-Length (present only when >= 0)
    /// exceeds `limit`, OR when the actually-received byte count exceeds
    /// `limit`. A negative/absent Content-Length (chunked or unknown) is not by
    /// itself a rejection — the `byteCount` check still bounds what we accept.
    /// Equality (count == limit) is accepted, not rejected.
    static func exceeds(contentLength: Int64, byteCount: Int, limit: Int) -> Bool {
        if contentLength >= 0 && contentLength > Int64(limit) { return true }
        return byteCount > limit
    }
}
```

### Integration

**`SamplePlayer.fetchAndPlay`** — after the `statusCode == 200` guard and before
`NSSound(data:)`:

```swift
if ResponseLimit.exceeds(contentLength: httpResponse.expectedContentLength,
                         byteCount: data.count,
                         limit: ResponseLimit.sample) {
    await applyIfCurrent(token) {
        self.playingVoice = nil
        self.lastError = "Server response too large to play."
    }
    return
}
```

**`HealthMonitor.handleHealthResponse`** — after the `httpResponse.statusCode ==
200` guard and before `JSONDecoder().decode`:

```swift
if ResponseLimit.exceeds(contentLength: httpResponse.expectedContentLength,
                         byteCount: data!.count,
                         limit: ResponseLimit.health) {
    handleHealthFailure(error: "Health response too large")
    return
}
```

Routing the oversize case through `handleHealthFailure` is intentional: an
oversized body is treated as a failed poll, so it correctly feeds the existing
consecutive-failure / crash-confirm logic rather than introducing a new state
path. No HealthMonitor invariant changes.

### Testing

New `AfterwordsTests/ResponseLimitTests.swift` exercising `exceeds(...)`:

- under limit by both measures → `false`
- `byteCount` over limit → `true`
- advertised `contentLength` over limit → `true`
- unknown `contentLength` (`-1`) with `byteCount` under limit → `false`
- boundary: `byteCount == limit` → `false` (accepted)
- boundary: `contentLength == limit` → `false` (accepted)

The integration sites are not separately unit-tested: `simulateHealthResult`
takes a decoded `HealthInfo`, not raw bytes, so it cannot drive the byte guard;
the pure predicate is the unit under test. The wiring is covered by `make build`
+ `make test` (no regression) and the existing HealthMonitor/SamplePlayer suites.

---

## 2. Remove Google Fonts from web docs (security finding #5)

### Problem

`docs/index.html:29` loads a stylesheet from `fonts.googleapis.com` (Inter +
JetBrains Mono). This is a third-party request (visitor IPs to Google) with no
Subresource Integrity. There is no script and no user input on the page, so there
is no XSS surface — this is purely a privacy / third-party note.

### Approach (A — drop the web fonts, keep system stacks)

Both CSS custom properties already lead with system fonts:

```css
--mono: ui-monospace,"SF Mono","JetBrains Mono",monospace;
--sans: -apple-system,BlinkMacSystemFont,"Inter",sans-serif;
```

On Apple hardware — the entire realistic audience for a macOS-app landing page —
`SF Mono` and the system sans resolve *before* the Google fonts ever apply, so
those fonts only render for non-Apple visitors. Self-hosting (approach B) would
commit ~100–400 KB of woff2 binaries purely for visitors who never see the
product; rejected as YAGNI.

### Change

- Delete the single `<link rel="stylesheet" href="https://fonts.googleapis.com/css2?...">`
  at `docs/index.html:29`.
- **Leave the CSS variables untouched.** `"Inter"` and `"JetBrains Mono"` remain
  as harmless named fallbacks in the font stacks — they do no harm if a visitor
  happens to have them installed locally, and trimming them is needless churn.

No new files; no preconnect lines exist to remove (verified — line 29 is the only
fonts reference).

### Testing

Static page, no automated test. Verify:

- `grep -i "googleapis\|gstatic" docs/index.html` returns nothing.
- The page still renders correctly (system fonts) — visual check.

---

## 3. Sparkle automatic update checks

### Problem

Sparkle is fully wired but **manual-check only**. There is no `SUEnableAutomaticChecks`
configuration, so installs rely on the user clicking "Check for Updates…" (plus
Sparkle's default first-launch prompt). The app already gives users explicit
control over its other background behaviors (Auto-start Server, Launch at Login);
update-checking should match that idiom.

### Approach (A — Info.plist defaults + Settings toggle)

#### Info.plist (`Afterwords/Info.plist`)

Add:

```xml
<key>SUEnableAutomaticChecks</key>
<true/>
<key>SUScheduledCheckInterval</key>
<integer>86400</integer>
```

`SUEnableAutomaticChecks=true` sets automatic checking on by default and
suppresses Sparkle's first-launch "do you want automatic updates?" prompt;
`86400` is a once-daily interval. Once the user toggles the Settings control,
Sparkle persists their choice in `UserDefaults` and that wins over the plist
default.

#### `UpdaterController` (`Afterwords/Services/UpdaterController.swift`)

Expose the preference as a published, settable proxy onto the underlying
`SPUUpdater` (which exposes `automaticallyChecksForUpdates` as a settable,
KVO-observable property):

```swift
@Published var automaticallyChecksForUpdates = false

// in init(), alongside the existing canCheckForUpdates pipeline:
controller.updater.publisher(for: \.automaticallyChecksForUpdates)
    .receive(on: DispatchQueue.main)
    .assign(to: &$automaticallyChecksForUpdates)

func setAutomaticallyChecksForUpdates(_ enabled: Bool) {
    controller.updater.automaticallyChecksForUpdates = enabled
}
```

#### `AfterwordsApp` (`Afterwords/AfterwordsApp.swift`)

Inject the updater into the `Settings` scene (currently it only injects
`cliExecutor`):

```swift
Settings {
    SettingsView()
        .environmentObject(cliExecutor)
        .environmentObject(updaterController)
}
```

#### `SettingsView` (`Afterwords/Views/SettingsView.swift`)

Add the environment object and a toggle in the General tab, using the same
`Binding(get:set:)` pattern as Launch at Login. This pattern is required, not
incidental: programmatic `@Published` updates arriving from the KVO publisher
must not re-fire the setter. Because a `Binding(get:set:)` setter only fires on
user interaction (not on `@Published` writes), no re-entrancy guard is needed —
identical reasoning to the documented Launch-at-Login toggle.

```swift
@EnvironmentObject var updaterController: UpdaterController

// in GeneralTab(), after "Auto-start Server":
Toggle("Automatically check for updates", isOn: Binding(
    get: { updaterController.automaticallyChecksForUpdates },
    set: { updaterController.setAutomaticallyChecksForUpdates($0) }
))
.help("Let Afterwords check for new versions in the background (about once a day).")
```

### Testing

`UpdaterController` instantiates a real `SPUStandardUpdaterController` and has no
existing unit tests; this change keeps that. Verify by:

- `make build` succeeds.
- Launch the app, open Settings → General, confirm the toggle reflects and
  controls Sparkle's `automaticallyChecksForUpdates` (toggling persists across
  relaunch).
- "Check for Updates…" still works (no regression).

---

## Build / verification (whole change set)

New source files (`ResponseLimit.swift`, `ResponseLimitTests.swift`) require the
Xcode project to be regenerated so XcodeGen picks them up:

```bash
make project   # regenerate .xcodeproj to include the new files
make build     # debug build
make test      # full XCTest suite (incl. new ResponseLimitTests)
grep -i "googleapis\|gstatic" docs/index.html   # must return nothing
```

Info.plist-only changes (Sparkle keys) do not by themselves require
`make project`, but it is run regardless because of the new files.

## Out of scope

- **Security finding #2** (Developer ID signing + notarization) — needs an Apple
  Developer Program membership; deferred, interim SHA-256 mitigation already
  documented in `RELEASING.md`.
- **Approach B for #4** (mid-stream streaming cap via a shared `BoundedFetch`
  helper) — disproportionate restructuring of HealthMonitor for an INFO finding.
- **Self-hosting fonts** (approach B for #5) — commits binaries for an audience
  that never loads them.

## Files touched

| File | Change |
| --- | --- |
| `Afterwords/Services/ResponseLimit.swift` | **New** — byte caps + pure `exceeds(...)` predicate |
| `Afterwords/Services/SamplePlayer.swift` | Add size guard before `NSSound(data:)` |
| `Afterwords/Services/HealthMonitor.swift` | Add size guard before JSON decode |
| `AfterwordsTests/ResponseLimitTests.swift` | **New** — unit tests for `exceeds(...)` |
| `docs/index.html` | Remove the `fonts.googleapis.com` `<link>` |
| `Afterwords/Info.plist` | Add `SUEnableAutomaticChecks` + `SUScheduledCheckInterval` |
| `Afterwords/Services/UpdaterController.swift` | Expose `automaticallyChecksForUpdates` + setter |
| `Afterwords/AfterwordsApp.swift` | Inject `updaterController` into `Settings` scene |
| `Afterwords/Views/SettingsView.swift` | Add "Automatically check for updates" toggle |
| `Afterwords.xcodeproj/project.pbxproj` | Regenerated by `make project` |
