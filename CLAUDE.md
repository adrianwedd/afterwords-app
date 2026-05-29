# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A native macOS menu-bar app (Swift/SwiftUI, macOS 13+, Apple Silicon) that is a **control panel** for the separate, locally-running [Afterwords](https://github.com/adrianwedd/afterwords) TTS server. The app does **not** manage the server process — launchd owns that. It issues `afterwords start/stop/restart` CLI commands (fire-and-forget) and uses `HealthMonitor` polling as the single source of truth for server state.

Scope is deliberately narrow: the **only** audio the app plays is fixed-phrase voice *samples* from the Voices window. It does **not** do arbitrary text-to-speech synthesis, a synthesis/history list, dictation, or system-wide TTS — never add or claim those.

**Related but separate projects** (do not conflate with this menu-bar app): the TTS server (https://adrianwedd.github.io/afterwords/), afterwords cloud (https://afterwords-cloud.pages.dev/). This app's own site is https://afterwords-app.pages.dev/.

## Commands

```bash
make project    # Regenerate Afterwords.xcodeproj via XcodeGen (required after editing project.yml)
make build      # Debug build via xcodebuild
make test       # Run XCTest suite on macOS
make open       # Regenerate project and open in Xcode
make dmg        # Release build + unsigned DMG at build/Release/Afterwords.dmg
make clean      # Remove generated .xcodeproj and build/
```

The `.xcodeproj/project.pbxproj` is committed to git (see `.gitignore`). `make project` regenerates it from `project.yml` via XcodeGen — run it after editing `project.yml`, but don't hand-edit `project.pbxproj` directly unless intentionally changing project metadata outside XcodeGen's control.

## Architecture

```
AfterwordsApp (entry point)
  ├── MenuBarExtra → PopoverView
  ├── Settings scene → SettingsView
  └── Window("Voices") → VoiceListView

Services (all @MainActor ObservableObject, owned as @StateObject in AfterwordsApp, injected into views via @EnvironmentObject):
  ├── CLIExecutor        — runs `afterwords` CLI via Foundation.Process with explicit PATH injection
  ├── HealthMonitor      — polls GET /health; owns the ServerState machine
  ├── SamplePlayer       — fetches and plays voice samples via NSSound
  └── UpdaterController  — wraps SPUStandardUpdaterController (Sparkle 2); exposes canCheckForUpdates
```

**State machine** (`ServerState` enum) — canonical; matches `HealthMonitor.swift:5-12`:
```
.stopped → notifyStartAttempt() → .starting(since: Date) → (health 200) → .running(HealthInfo)
.starting → (90s timeout) → .error(message)
.running → (3 consecutive poll failures) → .error(message)
.running → notifyStopAttempt() → .stopped
.error → notifyStartAttempt() → .starting(since: Date)
```

`HealthMonitor` polls every 5s when running, every 2s when starting. State transitions are driven entirely by poll results — CLI commands are fire-and-forget. **Restart** fires `afterwords restart` *and* calls `notifyStartAttempt()`, so it also enters `.starting` (PopoverView.swift:37-44). The `.error → start` edge uses the same `notifyStartAttempt()` path as manual Start/Restart. (The silent auto-start does not traverse `.error → start`; it fires from the `.stopped` branch on the first poll failure (HealthMonitor.swift:233-242), also via `notifyStartAttempt()`.)

**HealthMonitor invariants** (subtle; do not remove or weaken):
- 90s startup timeout before `.starting` → `.error`; 3 consecutive failures before `.running` → `.error`; 3s per-request timeout (a localhost `/health` call responds in ~1ms or not at all, so a hung connection must not mask later polls).
- `pendingStop` guard (HealthMonitor.swift:54/204/234): set by `notifyStopAttempt()`, it drops a stale in-flight 200 that lands after a user Stop, preventing a false `.stopped` → `.running` flip and a bogus "Server crashed" error.

## Key design decisions

- **No App Sandbox** — subprocess spawning requires it be disabled (`ENABLE_APP_SANDBOX: NO` in `project.yml`)
- **PATH injection is for the subprocess, not for discovery** — every spawned `Foundation.Process` gets `PATH` set to the default directories plus any user override (CLIExecutor.swift:132-140/175-183), because macOS GUI apps don't inherit shell PATH and the `afterwords` CLI's own children need it. The app does **not** find the `afterwords` binary on PATH: discovery is via fixed-path probes (`detectCLIPath()` checks four absolute paths) or an explicit Settings override, resolving as override > detected path > hardcoded `/usr/local/bin/afterwords` (CLIExecutor.swift:73-91/124-130)
- **CLI detection is pure FileManager probing — no Process, no shell** — `detectCLIPath()` runs `FileManager.isExecutableFile` over `cliSearchPaths` synchronously in `init()`; `detectedCLIPath` is set before `init()` returns, so the silent `autoStartServer` path on first poll failure always sees the correct path. Do not reintroduce a subprocess or shell into detection (no `which`, no `zsh -c`)
- **CLI-path security guard** — `validationError(forCLIPath:)` refuses to run any binary whose `lastPathComponent` != `afterwords` (CLIExecutor.swift:108-117), defense-in-depth for the unsandboxed-subprocess + UserDefaults-writable-override surface. It is applied on the silent auto-start path too. Do not bypass it
- **Port range 1024-65535, default 7860** — sub-1024 ports are rejected (`setPort` clamps; `loadPort` falls back to `defaultPort`) because the launchd LaunchAgent runs unprivileged and cannot bind privileged ports (CLIExecutor.swift:18-40)
- **Quit does NOT stop the server** — launchd owns the lifecycle; the app only fires `afterwords start/stop/restart` (fire-and-forget) and treats GET /health as the single source of truth. Never add PID/process monitoring or ID tracking; quitting the app does not stop the server
- **Port is UI-only** — changing `CLIExecutor.port` only affects which URL `HealthMonitor` polls; it does not reconfigure the running server's bind port
- **`HealthInfo.loadedBackends`** is decoded from a JSON dict (keyed by backend name), not an array — the custom `Codable` implementation handles this
- **Launch-at-Login toggle uses `Binding(get:set:)`** — programmatic writes to the `launchAtLogin` `@State` property (e.g. from `syncLaunchAtLogin`) never fire the Binding setter; only user interaction through the Toggle does. This avoids re-entrancy with `SMAppService` without requiring a guard flag or `DispatchQueue.main.async` release

## Coding conventions

- Swift 5.9, macOS 13.0+ deployment target — use `onChange(of:perform:)` (pre-macOS 14 API), not the two-argument form
- `UpperCamelCase` types, `lowerCamelCase` methods/properties, four-space indentation
- `@State`/`@EnvironmentObject` for UI state; Sparkle 2 (via SPM) is the only third-party dependency
- All service types are `@MainActor final class`; use `Task.detached` for blocking work then `await MainActor.run` to publish results
- Combine publishers feeding `@MainActor` `@Published` properties must use `.receive(on: DispatchQueue.main)` before `.assign(to:)` — Swift concurrency actors don't auto-dispatch Combine pipelines
- Commit messages use conventional scopes: `fix(settings):`, `feat(monitor):`, `test:`, `chore:`

## Testing

Tests live in `AfterwordsTests/` and use `XCTest`. The `HealthMonitor` exposes `simulateHealthResult(info:error:)` under `#if DEBUG` to drive state-machine tests without real network calls. Run `make test` after any change to services or models.

`HealthInfo` uses `decodeIfPresent` (falling back to empty collection) for all three optional fields — `voices`, `loaded_backends`, and `supported_langs` — so a server emitting `null` for any of them does not throw and does not push `HealthMonitor` into `.error`.

**Codable memberwise-init trap**: `HealthInfo` declares a custom `init(from:)`, which suppresses Swift's synthesized memberwise initializer. The explicit `init(status:loadedBackends:voices:)` (HealthInfo.swift:33) exists so test fixtures can construct values directly — keep it; do not delete it when editing the decoder.

## User-facing surface

This is the complete feature set an assistant editing views may touch. Do not add arbitrary-text TTS, a synthesis history, or dictation.

- **Menu-bar status icon** reflects `ServerState`: stopped / starting / running / error.
- **Start / Stop / Restart** buttons (PopoverView).
- **Logs** button opens `/tmp/claude-tts-server.log` in Console.app via `NSWorkspace` (CLIExecutor.openLogs, 147-159); **API** button opens `http://localhost:<port>` in the browser (PopoverView:64-70).
- **Voices window**: flat alphabetical list with a search box. Single-click plays a fixed-phrase sample (`"Hello. This is the <voice> voice."`, SamplePlayer.swift:55) via GET /synthesize; double-click or right-click sets the default/preferred voice (`preferredVoice` in UserDefaults).
- **Settings**: Launch at Login, Auto-start Server, CLI path override, server port (port is UI-only — see Key design decisions).
- **Sparkle 2 auto-updates** via an EdDSA-signed appcast. Distribution today is an unsigned, un-notarized DMG (right-click > Open on first launch); auto-updates are integrity-protected by Sparkle's EdDSA signature.
