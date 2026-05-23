# Repository Guidelines

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

- Use Swift standard formatting: four-space indentation, `UpperCamelCase` for types, `lowerCamelCase` for methods, properties, and files.
- Prefer small, focused types and keep UI, state, and process execution logic separated by module folder.
- Follow the repository’s existing SwiftUI style: concise view builders, `@State`/`@EnvironmentObject` for local and shared state, and explicit comments only where control flow is non-obvious.
- There is no dedicated formatter or linter checked in; keep changes consistent with nearby code.

## Testing Guidelines

- Tests use `XCTest` in `AfterwordsTests/`.
- Name tests with `test...` and prefer one behavior per test.
- When fixing regressions, add or update a focused unit test alongside the code change.
- For UI and app-lifecycle changes, verify both the build and the live app flow. Use `make build` or `make test`, then manually check the menu bar app, Settings window, and server state transitions when relevant.
- **State-machine tests**: `HealthMonitor` exposes `simulateHealthResult(info:error:)` under `#if DEBUG`. Use it to drive state transitions deterministically without a live server or real network calls. This is the standard path for `HealthMonitorTests`.
- **`HealthInfo` Codable trap**: `HealthInfo` implements a custom `init(from:)` which suppresses Swift's synthesized memberwise initialiser. An explicit `init(status:loadedBackends:voices:)` is declared for this reason — always use it when constructing test fixtures directly. Do not remove it.

## Commit & Pull Request Guidelines

- Commit messages follow conventional lowercase scopes, e.g. `fix(settings): ...`, `test: ...`, `chore(voices): ...`.
- Keep commits narrow and descriptive.
- Pull requests should summarize the user-visible change, mention verification (`make test`, `xcodebuild build`, etc.), and include screenshots for UI changes when relevant.

## Configuration Notes

- The app depends on the external `afterwords` CLI being available on PATH.
- The project intentionally does not use the App Sandbox because it launches subprocesses.
- Sparkle 2 (via SPM) is the only third-party dependency. Combine publishers feeding `@MainActor` `@Published` properties must use `.receive(on: DispatchQueue.main)` before `.assign(to:)` — Swift concurrency actors don't auto-dispatch Combine pipelines.
- Launch-at-login state should read from `SMAppService.mainApp.status`, not a persisted toggle value. If you change `SettingsView.swift`, keep the OS state, UI state, and error handling in sync. The Toggle uses `Binding(get:set:)` rather than binding directly to the `@State` property so that programmatic writes to `launchAtLogin` (e.g. from `syncLaunchAtLogin`) never invoke `SMAppService` re-entrantly — no guard flag is needed.
- `autoStartServer` is separate from login-item registration. Do not conflate the two in code or QA steps.
