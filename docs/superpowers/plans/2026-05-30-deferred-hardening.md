# Deferred Hardening + Sparkle Auto-Check Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a byte-size cap on localhost responses, remove the third-party Google Fonts dependency from the web docs, and give Sparkle automatic background update checks with a Settings toggle.

**Architecture:** Three independent changes. (#4) A pure, unit-tested `ResponseLimit.exceeds(...)` predicate is applied as a reject-before-decode guard in `SamplePlayer` and `HealthMonitor`. (#5) Delete one `<link>` from `docs/index.html` (system font stacks already lead). (Sparkle) Two Info.plist keys plus a published proxy on `UpdaterController` and a `Binding(get:set:)` Settings toggle, mirroring the existing Launch-at-Login idiom.

**Tech Stack:** Swift 5.9, SwiftUI, macOS 13+, XCTest, Sparkle 2 (SPM), XcodeGen.

**Design spec:** `docs/superpowers/specs/2026-05-29-deferred-hardening-design.md`

**Build/test commands (this repo):**
- `make project` — regenerate `.xcodeproj` from `project.yml` (REQUIRED after adding new source files so XcodeGen includes them).
- `make build` — debug build via xcodebuild.
- `make test` — run the XCTest suite.

---

## File Structure

| File | Responsibility | Task |
| --- | --- | --- |
| `Afterwords/Services/ResponseLimit.swift` | **New.** Byte caps + pure `exceeds(...)` predicate | 1 |
| `AfterwordsTests/ResponseLimitTests.swift` | **New.** Unit tests for the predicate | 1 |
| `Afterwords/Services/HealthMonitor.swift` | Nil-check rewrite, size guard, DEBUG seam | 2 |
| `Afterwords/Services/SamplePlayer.swift` | Size guard before `NSSound(data:)` | 2 |
| `AfterwordsTests/HealthMonitorTests.swift` | Oversize-body call-site test | 2 |
| `docs/index.html` | Remove `fonts.googleapis.com` `<link>` | 3 |
| `Afterwords/Info.plist` | `SUEnableAutomaticChecks` + `SUScheduledCheckInterval` | 4 |
| `Afterwords/Services/UpdaterController.swift` | Published `automaticallyChecksForUpdates` + setter | 5 |
| `Afterwords/AfterwordsApp.swift` | Inject `updaterController` into Settings scene | 6 |
| `Afterwords/Views/SettingsView.swift` | "Automatically check for updates" toggle | 6 |

The three features are independent; tasks may be done in any feature order, but within the Sparkle feature do 4 → 5 → 6.

---

## Task 1: `ResponseLimit` pure predicate (#4)

**Files:**
- Create: `Afterwords/Services/ResponseLimit.swift`
- Test: `AfterwordsTests/ResponseLimitTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `AfterwordsTests/ResponseLimitTests.swift`:

```swift
import XCTest
@testable import Afterwords

final class ResponseLimitTests: XCTestCase {

    private let limit = 1000

    func testUnderLimitByBothMeasuresIsAccepted() {
        XCTAssertFalse(ResponseLimit.exceeds(advertisedContentLength: 500, byteCount: 500, limit: limit))
    }

    func testByteCountOverLimitIsRejected() {
        XCTAssertTrue(ResponseLimit.exceeds(advertisedContentLength: -1, byteCount: limit + 1, limit: limit))
    }

    func testAdvertisedLengthOverLimitIsRejected() {
        // Advertised length over the cap is rejected even if byteCount is small.
        XCTAssertTrue(ResponseLimit.exceeds(advertisedContentLength: Int64(limit + 1), byteCount: 10, limit: limit))
    }

    func testUnknownAdvertisedLengthFallsBackToByteCount() {
        // -1 (NSURLResponseUnknownLength) is ignored; byteCount under limit → accepted.
        XCTAssertFalse(ResponseLimit.exceeds(advertisedContentLength: -1, byteCount: limit, limit: limit))
    }

    func testByteCountEqualToLimitIsAccepted() {
        XCTAssertFalse(ResponseLimit.exceeds(advertisedContentLength: -1, byteCount: limit, limit: limit))
    }

    func testAdvertisedLengthEqualToLimitIsAccepted() {
        XCTAssertFalse(ResponseLimit.exceeds(advertisedContentLength: Int64(limit), byteCount: 10, limit: limit))
    }

    func testRealCapsArePositive() {
        XCTAssertGreaterThan(ResponseLimit.health, 0)
        XCTAssertGreaterThan(ResponseLimit.sample, ResponseLimit.health)
    }
}
```

- [ ] **Step 2: Create a compiling stub so the test target builds**

Create `Afterwords/Services/ResponseLimit.swift` with a deliberately-wrong stub (returns `false` always) so we see a genuine red:

```swift
import Foundation

/// Byte-size caps for accepted localhost responses, plus a pure predicate that
/// callers apply before decoding/playing a fetched body. Defense-in-depth for a
/// localhost-only threat model (security review 2026-05-29, finding #4).
enum ResponseLimit {
    /// Cap for the /health JSON body. Real payloads are tens of KB.
    static let health = 5 * 1024 * 1024      // 5 MiB

    /// Cap for a /synthesize WAV sample. Fixed-phrase samples are ~30–100 KB.
    static let sample = 25 * 1024 * 1024     // 25 MiB

    static func exceeds(advertisedContentLength: Int64, byteCount: Int, limit: Int) -> Bool {
        return false // STUB — implemented in Step 5
    }
}
```

- [ ] **Step 3: Regenerate the Xcode project to include the new files**

Run: `make project`
Expected: regenerates `Afterwords.xcodeproj` with no errors; the two new files are now in the `Afterwords` / `AfterwordsTests` targets (XcodeGen globs those directories per `project.yml`).

- [ ] **Step 4: Run the tests to verify they fail**

Run: `make test`
Expected: FAIL — `testByteCountOverLimitIsRejected` and `testAdvertisedLengthOverLimitIsRejected` fail (stub returns `false`). The other tests pass.

- [ ] **Step 5: Implement the real predicate**

Replace the `exceeds` body in `Afterwords/Services/ResponseLimit.swift`:

```swift
    /// True when the response should be rejected as too large.
    ///
    /// `byteCount` is the real enforcement point — the body has already been
    /// buffered by the time callers have it, so the received count is
    /// authoritative. `advertisedContentLength` is an advisory fast-path: it
    /// short-circuits a server that honestly advertises an oversized body
    /// (present only when >= 0; a negative value means chunked/unknown and is
    /// ignored). Equality (count == limit) is accepted, not rejected.
    static func exceeds(advertisedContentLength: Int64, byteCount: Int, limit: Int) -> Bool {
        if advertisedContentLength >= 0 && advertisedContentLength > Int64(limit) { return true }
        return byteCount > limit
    }
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `make test`
Expected: PASS — all `ResponseLimitTests` green; rest of the suite still green.

- [ ] **Step 7: Commit**

```bash
git add Afterwords/Services/ResponseLimit.swift AfterwordsTests/ResponseLimitTests.swift Afterwords.xcodeproj/project.pbxproj
git commit -m "feat(security): add ResponseLimit byte-cap predicate (finding #4)"
```

---

## Task 2: Wire the size guard into `HealthMonitor` and `SamplePlayer` (#4)

**Files:**
- Modify: `Afterwords/Services/HealthMonitor.swift` (DEBUG seam ~line 109-119; `handleHealthResponse` lines 176-195)
- Modify: `Afterwords/Services/SamplePlayer.swift` (`fetchAndPlay`, after the 200 guard at lines 119-126)
- Test: `AfterwordsTests/HealthMonitorTests.swift`

- [ ] **Step 1: Add the DEBUG test seam to `HealthMonitor`**

In `Afterwords/Services/HealthMonitor.swift`, inside the existing `// MARK: - Testing` `#if DEBUG` region, add a second seam right after the closing brace of `simulateHealthResult(...)` (before `#endif` at line 119):

```swift
    /// Drive handleHealthResponse directly for tests (e.g. the oversize-body
    /// guard, which simulateHealthResult cannot reach because it takes a decoded
    /// HealthInfo). For unit tests only.
    func simulateHealthResponse(data: Data?, response: URLResponse?, error: Error?) {
        handleHealthResponse(data: data, response: response, error: error)
    }
```

- [ ] **Step 2: Write the failing call-site test**

In `AfterwordsTests/HealthMonitorTests.swift`, add this test before the final closing brace (after `testStopResetsConsecutiveFailures`):

```swift
    // MARK: - Oversize response guard (finding #4)

    @MainActor
    func testOversizeHealthBodyIsRejectedBeforeDecode() {
        monitor.notifyStartAttempt()
        XCTAssertTrue(monitor.state.isStarting)

        // A VALID HealthInfo JSON body padded past the cap. Without the guard
        // this decodes successfully and flips .starting → .running; the guard
        // must intercept it first, so the oversize poll is treated as a
        // not-yet-healthy failure and the state stays .starting.
        let pad = String(repeating: "a", count: ResponseLimit.health)
        let json = "{\"status\":\"ok\",\"pad\":\"\(pad)\"}".data(using: .utf8)!
        XCTAssertGreaterThan(json.count, ResponseLimit.health)

        let url = URL(string: "http://localhost:7860/health")!
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
        monitor.simulateHealthResponse(data: json, response: response, error: nil)

        XCTAssertTrue(monitor.state.isStarting,
            "Oversize body must be rejected before decode and leave state .starting (not .running)")
    }
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `make test`
Expected: FAIL — `testOversizeHealthBodyIsRejectedBeforeDecode` fails because the oversize-but-valid JSON currently decodes to `HealthInfo(status: "ok")`, transitioning `.starting → .running`.

- [ ] **Step 4: Rewrite the nil-check and add the size guard in `HealthMonitor`**

Replace the body of `handleHealthResponse` (lines 176-195) in `Afterwords/Services/HealthMonitor.swift` with:

```swift
    private func handleHealthResponse(data: Data?, response: URLResponse?, error: Error?) {
        // Bind data locally so the precondition is explicit (no later force-unwrap).
        guard error == nil, let data = data else {
            handleHealthFailure(error: error?.localizedDescription ?? "No response")
            return
        }

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            handleHealthFailure(error: "HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
            return
        }

        // Reject an oversized body before decoding it (security finding #4).
        if ResponseLimit.exceeds(advertisedContentLength: httpResponse.expectedContentLength,
                                 byteCount: data.count,
                                 limit: ResponseLimit.health) {
            handleHealthFailure(error: "Health response too large")
            return
        }

        do {
            let info = try JSONDecoder().decode(HealthInfo.self, from: data)
            handleHealthSuccess(info)
        } catch {
            handleHealthFailure(error: "Invalid JSON: \(error.localizedDescription)")
        }
    }
```

- [ ] **Step 5: Add the size guard in `SamplePlayer`**

In `Afterwords/Services/SamplePlayer.swift`, inside `fetchAndPlay`, insert this block immediately after the `httpResponse.statusCode == 200` guard (ends line 126) and before `guard let sound = NSSound(data: data)` (line 128):

```swift
        if ResponseLimit.exceeds(advertisedContentLength: httpResponse.expectedContentLength,
                                 byteCount: data.count,
                                 limit: ResponseLimit.sample) {
            await applyIfCurrent(token) {
                self.playingVoice = nil
                self.lastError = "Server response too large to play."
            }
            return
        }

```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `make test`
Expected: PASS — `testOversizeHealthBodyIsRejectedBeforeDecode` now green (state stays `.starting`); full suite green (the nil-check rewrite is behavior-preserving).

- [ ] **Step 7: Commit**

```bash
git add Afterwords/Services/HealthMonitor.swift Afterwords/Services/SamplePlayer.swift AfterwordsTests/HealthMonitorTests.swift
git commit -m "feat(security): cap accepted localhost response size (finding #4)"
```

---

## Task 3: Remove Google Fonts from the web docs (#5)

**Files:**
- Modify: `docs/index.html` (line 29)

- [ ] **Step 1: Delete the third-party stylesheet link**

In `docs/index.html`, delete the entire line 29:

```html
  <link href="https://fonts.googleapis.com/css2?family=Inter:wght@400;500&family=JetBrains+Mono:wght@400;500&display=swap" rel="stylesheet">
```

Leave the CSS variables (`--mono`, `--sans`) untouched — `"Inter"` / `"JetBrains Mono"` remain as harmless named fallbacks. Do not edit anything else.

- [ ] **Step 2: Verify no third-party font reference remains**

Run: `grep -i "googleapis\|gstatic" docs/index.html`
Expected: no output (exit status 1).

- [ ] **Step 3: Commit**

```bash
git add docs/index.html
git commit -m "fix(security): drop third-party Google Fonts dependency (finding #5)"
```

---

## Task 4: Sparkle automatic-check Info.plist keys

**Files:**
- Modify: `Afterwords/Info.plist` (insert after `SUPublicEDKey` at line 32)

- [ ] **Step 1: Add the two Sparkle keys**

In `Afterwords/Info.plist`, insert these four lines immediately after the `SUPublicEDKey` `<string>...</string>` (line 32) and before the closing `</dict>` (line 33):

```xml
    <key>SUEnableAutomaticChecks</key>
    <true/>
    <key>SUScheduledCheckInterval</key>
    <integer>86400</integer>
```

`SUEnableAutomaticChecks=true` turns automatic checking on by default and suppresses the permission prompt Sparkle otherwise shows on the *second* launch. `86400` is once-daily (kept explicit for self-documentation, though it matches Sparkle's built-in default).

- [ ] **Step 2: Verify the plist still builds**

Run: `make project && make build`
Expected: build succeeds (a malformed plist would fail the build).

- [ ] **Step 3: Commit**

```bash
git add Afterwords/Info.plist Afterwords.xcodeproj/project.pbxproj
git commit -m "feat(updater): enable Sparkle automatic update checks (daily)"
```

---

## Task 5: Expose the auto-check preference on `UpdaterController`

**Files:**
- Modify: `Afterwords/Services/UpdaterController.swift`

- [ ] **Step 1: Add the published proxy and setter**

Replace the full contents of `Afterwords/Services/UpdaterController.swift` with:

```swift
import Combine
import Sparkle

@MainActor final class UpdaterController: ObservableObject {
    private let controller: SPUStandardUpdaterController

    @Published var canCheckForUpdates = false
    @Published var automaticallyChecksForUpdates = false

    init() {
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        controller.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: DispatchQueue.main)
            .assign(to: &$canCheckForUpdates)
        // automaticallyChecksForUpdates is KVO-observable on SPUUpdater; mirror
        // it so the Settings toggle reflects the current (possibly user-changed
        // or plist-defaulted) value.
        controller.updater.publisher(for: \.automaticallyChecksForUpdates)
            .receive(on: DispatchQueue.main)
            .assign(to: &$automaticallyChecksForUpdates)
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }

    /// Toggle background update checks. Sparkle persists this in UserDefaults,
    /// overriding the SUEnableAutomaticChecks plist default.
    func setAutomaticallyChecksForUpdates(_ enabled: Bool) {
        controller.updater.automaticallyChecksForUpdates = enabled
    }
}
```

- [ ] **Step 2: Verify it builds**

Run: `make build`
Expected: build succeeds. (No unit test: `UpdaterController` starts a real `SPUStandardUpdaterController`, matching the existing no-test status of this type.)

- [ ] **Step 3: Commit**

```bash
git add Afterwords/Services/UpdaterController.swift
git commit -m "feat(updater): expose automaticallyChecksForUpdates proxy + setter"
```

---

## Task 6: Add the Settings toggle

**Files:**
- Modify: `Afterwords/AfterwordsApp.swift` (Settings scene, lines 40-43)
- Modify: `Afterwords/Views/SettingsView.swift` (env object near line 5; toggle in `GeneralTab` after line 69)

- [ ] **Step 1: Inject the updater into the Settings scene**

In `Afterwords/AfterwordsApp.swift`, change the `Settings` scene (lines 40-43) to also inject the updater:

```swift
        Settings {
            SettingsView()
                .environmentObject(cliExecutor)
                .environmentObject(updaterController)
        }
```

- [ ] **Step 2: Add the environment object to `SettingsView`**

In `Afterwords/Views/SettingsView.swift`, add this line immediately after the existing `@EnvironmentObject var cliExecutor: CLIExecutor` (line 5):

```swift
    @EnvironmentObject var updaterController: UpdaterController
```

- [ ] **Step 3: Add the toggle to the General tab**

In `Afterwords/Views/SettingsView.swift`, inside `GeneralTab()`, insert this toggle immediately after the "Auto-start Server" `Toggle` block (lines 68-69), before the `LabeledContent("CLI Path")`:

```swift
            // Binding(get:set:) mirrors the Launch-at-Login idiom: the setter
            // only fires on user interaction, so the KVO-driven @Published
            // updates from UpdaterController don't re-enter it. Do not replace
            // with .onChange without a re-entrancy guard.
            Toggle("Automatically check for updates", isOn: Binding(
                get: { updaterController.automaticallyChecksForUpdates },
                set: { updaterController.setAutomaticallyChecksForUpdates($0) }
            ))
            .help("Let Afterwords check for new versions in the background (about once a day).")
```

- [ ] **Step 4: Verify it builds and the suite passes**

Run: `make build && make test`
Expected: build succeeds; full XCTest suite green.

- [ ] **Step 5: Manual verification**

Launch the app (`open build/Debug/Afterwords.app` after a build, or run from Xcode), open **Settings → General**:
- The "Automatically check for updates" toggle appears and reflects the current state (on by default via `SUEnableAutomaticChecks`).
- Toggling it off then relaunching the app shows it still off (Sparkle persisted the choice).
- "Check for Updates…" in the menu still works.

- [ ] **Step 6: Commit**

```bash
git add Afterwords/AfterwordsApp.swift Afterwords/Views/SettingsView.swift
git commit -m "feat(updater): add 'Automatically check for updates' Settings toggle"
```

---

## Final verification (whole change set)

- [ ] **Run the full pipeline**

```bash
make project
make build
make test
grep -i "googleapis\|gstatic" docs/index.html   # must print nothing
```
Expected: build succeeds; all tests green (including `ResponseLimitTests` and `testOversizeHealthBodyIsRejectedBeforeDecode`); the grep is silent.

## Out of scope (do not implement)

- Security finding #2 (Developer ID signing + notarization) — needs an Apple Developer Program membership; deferred.
- Approach B for #4 (mid-stream streaming cap / shared `BoundedFetch`) — disproportionate for an INFO finding.
- Self-hosting fonts — commits binaries for an audience that never loads them.
