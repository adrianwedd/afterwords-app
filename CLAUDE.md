# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A native macOS menu-bar app (Swift/SwiftUI) that acts as a UI layer for the [Afterwords](https://github.com/adrianwedd/afterwords) TTS server. The app does **not** manage the server process — launchd owns that. It issues `afterwords start/stop/restart` CLI commands and uses `HealthMonitor` polling as the single source of truth for server state.

## Commands

```bash
make project    # Regenerate Afterwords.xcodeproj via XcodeGen (required after editing project.yml)
make build      # Debug build via xcodebuild
make test       # Run XCTest suite on macOS
make open       # Regenerate project and open in Xcode
make clean      # Remove generated .xcodeproj and build/
```

The `.xcodeproj/project.pbxproj` is committed to git (see `.gitignore`). `make project` regenerates it from `project.yml` via XcodeGen — run it after editing `project.yml`, but don't hand-edit `project.pbxproj` directly unless intentionally changing project metadata outside XcodeGen's control.

## Architecture

```
AfterwordsApp (entry point)
  ├── MenuBarExtra → PopoverView
  ├── Settings scene → SettingsView
  └── Window("Voices") → VoiceListView

Services (all @MainActor ObservableObject, injected via @EnvironmentObject):
  ├── CLIExecutor   — runs `afterwords` CLI via Foundation.Process with explicit PATH injection
  ├── HealthMonitor — polls GET /health; owns the ServerState machine
  └── SamplePlayer  — fetches and plays voice samples via NSSound
```

**State machine** (`ServerState` enum):
```
.stopped → notifyStartAttempt() → .starting(since: Date) → (health 200) → .running(HealthInfo)
.starting → (90s timeout) → .error(message)
.running → (3 consecutive poll failures) → .error(message)
.running → notifyStopAttempt() → .stopped
```

`HealthMonitor` polls every 5s when running, every 2s when starting. State transitions are driven entirely by poll results — CLI commands are fire-and-forget.

## Key design decisions

- **No App Sandbox** — subprocess spawning requires it be disabled (`ENABLE_APP_SANDBOX: NO` in `project.yml`)
- **Explicit PATH injection** — every `Foundation.Process` gets `/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin` plus user overrides, because macOS GUI apps don't inherit shell PATH
- **Quit does NOT stop the server** — launchd owns the server; the app is just a control panel
- **Port is UI-only** — changing `CLIExecutor.port` only affects which URL `HealthMonitor` polls; it does not reconfigure the running server's bind port
- **`HealthInfo.loadedBackends`** is decoded from a JSON dict (keyed by backend name), not an array — the custom `Codable` implementation handles this

## Coding conventions

- Swift 5.9, macOS 13.0+ deployment target — use `onChange(of:perform:)` (pre-macOS 14 API), not the two-argument form
- `UpperCamelCase` types, `lowerCamelCase` methods/properties, four-space indentation
- `@State`/`@EnvironmentObject` for UI state; no third-party dependencies
- All service types are `@MainActor final class`; use `Task.detached` for blocking work then `await MainActor.run` to publish results
- Commit messages use conventional scopes: `fix(settings):`, `feat(monitor):`, `test:`, `chore:`

## Testing

Tests live in `AfterwordsTests/` and use `XCTest`. The `HealthMonitor` exposes `simulateHealthResult(info:error:)` under `#if DEBUG` to drive state-machine tests without real network calls. Run `make test` after any change to services or models.
