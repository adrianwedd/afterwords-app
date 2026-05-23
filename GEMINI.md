# Project Overview
This repository contains a native macOS menu-bar application, written in Swift and SwiftUI, for managing the [Afterwords](https://github.com/adrianwedd/afterwords) Text-to-Speech (TTS) server.

The application delegates the lifecycle of the server directly to the `afterwords` CLI tool, meaning it does not manage the server process itself (that is owned by `launchd`). It acts primarily as a UI layer for issuing start/stop commands and checking health.

## Core Technologies
- **Platform**: macOS 13.0+ (Ventura)
- **Language**: Swift 5.9
- **Framework**: SwiftUI
- **Project Generation**: XcodeGen (via `project.yml`)
- **Key Concepts**:
  - Unsandboxed app (App Sandbox is disabled to allow spawning subprocesses).
  - Explicit PATH injection to ensure the CLI commands succeed (since macOS GUI apps do not inherit the shell PATH).
  - State machine polling pattern to determine server state via HTTP (`HealthMonitor`).

## Architecture
- **`AfterwordsApp`**: The main application entry point. Sets up `MenuBarExtra` for the popover UI, the `Settings` view, and a separate window for the voice browser.
- **`CLIExecutor`**: Responsible for invoking the `afterwords` CLI via `Foundation.Process`. Handles PATH injection.
- **`HealthMonitor`**: Continuously polls the `/health` endpoint of the TTS server to determine state (running, stopped, starting, error).
- **`SamplePlayer`**: Connects to the server to fetch and play voice samples using `NSSound`.
- **`UpdaterController`**: Wraps `SPUStandardUpdaterController` (Sparkle 2 via SPM); exposes `canCheckForUpdates` for the "Check for Updates…" button in `PopoverView`.

# Building and Running

The project uses a `Makefile` and `XcodeGen` to manage `Afterwords.xcodeproj/project.pbxproj`. The `project.pbxproj` is committed to version control. Use `make project` to regenerate it from `project.yml`. Direct hand-edits to the Xcode project are only for intentional out-of-XcodeGen changes.

**Prerequisites:**
- Xcode 15.0+
- `brew install xcodegen`

**Key Commands:**
```bash
# Generate the Afterwords.xcodeproj file
make project

# Generate the project and open it in Xcode
make open

# Build the project via xcodebuild (Debug configuration)
make build

# Run the test suite via xcodebuild
make test

# Produce an unsigned Release DMG at build/Release/Afterwords.dmg
make dmg

# Clean generated artifacts (removes the .xcodeproj and build directory)
make clean
```

# Development Conventions

- **State Management**: The app uses `@StateObject` and `@EnvironmentObject` to inject core services (`CLIExecutor`, `HealthMonitor`, `SamplePlayer`, `UpdaterController`) into the view hierarchy. All services are `@MainActor final class`. Combine publishers feeding `@MainActor` `@Published` properties must use `.receive(on: DispatchQueue.main)` before `.assign(to:)`.
- **Third-party dependency**: Sparkle 2 (via SPM) is the only one. It is declared in `project.yml` and linked to the `Afterwords` target.
- **OS State as Source of Truth**: For features tied to macOS APIs (e.g., `SMAppService` for Launch at Login), always read the actual OS state instead of persisting a proxy state via `@AppStorage`. Use `.onReceive(NSApplication.didBecomeActiveNotification)` and `.task` to resync the UI if the user changes the setting externally (e.g., in System Settings).
- **Swift Codable**: When implementing a custom `init(from decoder: Decoder)` on a `Codable` struct, Swift suppresses the compiler-synthesized memberwise initializer. Always explicitly re-declare the memberwise `init(...)` to preserve direct construction capabilities for test mocks.
- **Server Lifecycle**: The app only sends commands (e.g., `afterwords start`) and relies exclusively on the `/health` endpoint to reflect reality. Do not implement direct process monitoring or ID tracking for the server inside the app.
- **UI State vs OS State**: If an operation fails (e.g., registering for Launch at Login), the app must revert the UI toggle to match the actual OS state. The Launch-at-Login Toggle in `SettingsView` uses `Binding(get:set:)` — programmatic writes to the `launchAtLogin` `@State` property never fire the Binding setter, so `SMAppService` is never called re-entrantly. No guard flag or `DispatchQueue.main.async` delay is required.
- **Compatibility**: Ensure new APIs are compatible with the `macOS 13.0` deployment target (e.g. using pre-macOS 14 `onChange(of:perform:)` APIs).
- **Testing**: Maintain comprehensive test coverage for state machines and UI interactions. The project uses XCTest. Always run `make test` or test via Xcode after changes.
