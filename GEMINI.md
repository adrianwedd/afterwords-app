# Project Overview

This repository contains a native macOS menu-bar app (Swift/SwiftUI, macOS 13+, Apple Silicon) that is a **control panel** for the separate, locally-running [Afterwords](https://github.com/adrianwedd/afterwords) TTS server. It does not manage the server process — `launchd` owns the lifecycle. The app only issues `afterwords start/stop/restart` (fire-and-forget) and treats GET `/health` as the single source of truth for server state.

The only audio it plays is fixed-phrase voice *samples* from the Voices window — there is no arbitrary text synthesis, history, or dictation.

> **Canonical reference**: the full architecture, the `ServerState` machine, key design decisions, and coding conventions are authoritative in **`CLAUDE.md`** — read and follow it. This file keeps only Gemini-oriented framing and the points below; it does not restate shared technical content.

## Orientation (see `CLAUDE.md` for detail)

- **`AfterwordsApp`** — entry point; `MenuBarExtra` → `PopoverView`, a `Settings` scene, and a `Window("Voices")`.
- **`CLIExecutor`** — invokes the `afterwords` CLI via `Foundation.Process`.
- **`HealthMonitor`** — polls `/health`; owns the `ServerState` machine.
- **`SamplePlayer`** — fetches and plays voice samples via `NSSound`.
- **`UpdaterController`** — wraps `SPUStandardUpdaterController` (Sparkle 2 via SPM).

Services are **owned as `@StateObject` in `AfterwordsApp` and injected into views via `@EnvironmentObject`**; all are `@MainActor final class`.

# Building and Running

The project uses a `Makefile` and `XcodeGen` to manage `Afterwords.xcodeproj/project.pbxproj`. The `project.pbxproj` is committed to version control. Use `make project` to regenerate it from `project.yml`. Direct hand-edits to the Xcode project are only for intentional out-of-XcodeGen changes.

**Prerequisites:**
- Xcode 15.0+
- `brew install xcodegen`

The Makefile targets (`make project | open | build | test | dmg | clean`) and the XcodeGen / committed-`project.pbxproj` workflow are documented in `CLAUDE.md` → Commands. Regenerate the project with `make project` after editing `project.yml`; do not hand-edit `project.pbxproj`.

# Development Conventions

The conventions are canonical in `CLAUDE.md` (`@MainActor final class` services + `Task.detached`, the Combine `.receive(on: DispatchQueue.main)` rule, macOS 13 `onChange(of:perform:)`, naming, commit scopes, and the `HealthInfo` Codable memberwise-init trap). The points Gemini should weigh most heavily when editing:

- **Server lifecycle**: `launchd` owns the lifecycle; the app only fires `afterwords start/stop/restart` (fire-and-forget) and treats GET `/health` as the single source of truth. Never add PID/process monitoring or ID tracking; quitting the app does not stop the server.
- **PATH vs discovery**: the app **locates** `afterwords` via fixed-path probes or the Settings override (not via PATH). PATH is injected only into the spawned subprocess environment. Don't shell out to `which` or add a subprocess to detection — see `CLAUDE.md`.
- **OS State as source of truth**: for macOS-API-backed features (e.g. `SMAppService` for Launch at Login), read the actual OS state rather than persisting an `@AppStorage` proxy. `SettingsView` resyncs via `.onReceive(NSApplication.didBecomeActiveNotification)` and `.task` so external changes (System Settings) reflect in the UI. If an operation fails, revert the UI toggle to match the real OS state. The Launch-at-Login Toggle uses `Binding(get:set:)` so programmatic writes never call `SMAppService` re-entrantly (rationale in `CLAUDE.md`).
- **Testing**: maintain coverage for state machines and UI interactions; run `make test` after changes.
