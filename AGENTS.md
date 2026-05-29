# Repository Guidelines

> **Canonical reference**: architecture, the `ServerState` machine, key design decisions, and coding conventions live in **`CLAUDE.md`** — follow it. This file covers contribution workflow and the repository map only, and does not restate shared technical content.

## Project Structure & Module Organization

This is a macOS menu-bar app built with SwiftUI and XcodeGen.

- `Afterwords/` contains the app source.
  - `Views/` holds SwiftUI screens such as `PopoverView.swift`, `SettingsView.swift`, and `VoiceListView.swift`.
  - `Services/` contains app logic like `CLIExecutor.swift`, `HealthMonitor.swift`, `SamplePlayer.swift`, and `UpdaterController.swift` (Sparkle 2 auto-update).
  - `Models/` holds lightweight data types such as `HealthInfo.swift` and `ServerState.swift`.
- `AfterwordsTests/` contains XCTest coverage for the app and service layer.
- `Afterwords.xcodeproj/project.pbxproj` is committed to git. `make project` regenerates it from `project.yml` via XcodeGen. Edit `project.yml` for structural changes; do not hand-edit `project.pbxproj` unless intentionally changing project metadata outside XcodeGen's control.
- `Afterwords/Assets.xcassets/` contains icons and other asset catalogs.

## Build, Test, and Development Commands

Use the Makefile targets for the standard workflow:

- `make project` regenerates the Xcode project with XcodeGen.
- `make open` regenerates and opens `Afterwords.xcodeproj` in Xcode.
- `make build` performs a Debug build with `xcodebuild`.
- `make test` runs the XCTest suite on macOS.
- `make dmg` produces an unsigned Release DMG at `build/Release/Afterwords.dmg`.
- `make clean` removes the generated project and local build output.

## Coding Style & Naming Conventions

Naming, indentation, the `@MainActor`/Combine/`onChange` rules, and the rest of the conventions are canonical in **`CLAUDE.md` → Coding conventions**. Contribution-specific notes only:

- Keep UI, state, and process-execution logic separated by module folder (`Views/`, `Services/`, `Models/`).
- There is no dedicated formatter or linter checked in; keep changes consistent with nearby code.

## Testing Guidelines

- Tests use `XCTest` in `AfterwordsTests/`.
- Name tests with `test...` and prefer one behavior per test.
- When fixing regressions, add or update a focused unit test alongside the code change.
- For UI and app-lifecycle changes, verify both the build and the live app flow. Use `make build` or `make test`, then manually check the menu bar app, Settings window, and server state transitions when relevant.
- Drive state-machine tests via `HealthMonitor.simulateHealthResult(info:error:)` (`#if DEBUG`) — no live server or network. The `HealthInfo` Codable memberwise-init trap (use `init(status:loadedBackends:voices:)` for fixtures) is documented in `CLAUDE.md` → Testing.

## Commit & Pull Request Guidelines

- Commit messages follow conventional lowercase scopes, e.g. `fix(settings): ...`, `test: ...`, `chore(voices): ...`.
- Keep commits narrow and descriptive.
- Pull requests should summarize the user-visible change, mention verification (`make test`, `xcodebuild build`, etc.), and include screenshots for UI changes when relevant.

## Configuration Notes

The design decisions behind these — no App Sandbox, PATH-injection vs. discovery, launchd-owns-the-server, the Launch-at-Login `Binding(get:set:)` rationale, port-UI-only — are canonical in `CLAUDE.md` → Key design decisions. Contribution gotchas to keep in mind:

- The app **locates** `afterwords` via fixed-path probes or the Settings override (not via PATH); PATH is injected only into spawned processes. Don't "fix" detection by shelling out to `which` or adding a subprocess — see `CLAUDE.md`.
- `autoStartServer` is separate from login-item registration. Do not conflate the two in code or QA steps.
- When changing `SettingsView.swift`, keep OS state (`SMAppService.mainApp.status`), UI state, and error handling in sync; do not persist a proxy toggle value as the source of truth.
