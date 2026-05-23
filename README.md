# Afterwords Menu-Bar App

A native macOS menu-bar app (Swift/SwiftUI) for managing the
[Afterwords](https://github.com/adrianwedd/afterwords) TTS server.

## Requirements

- macOS 13.0+ (Ventura)
- Xcode 15.0+
- [Afterwords](https://github.com/adrianwedd/afterwords) installed and on `PATH`
  (the app uses the `afterwords` CLI to start/stop/restart the server)

## Setup

1. Install [XcodeGen](https://github.com/yonaskolb/XcodeGen):
   ```bash
   brew install xcodegen
   ```

2. Generate the Xcode project:
   ```bash
   make project
   ```

3. Open in Xcode and run (Cmd+R):
   ```bash
   make open
   ```

`Afterwords.xcodeproj/project.pbxproj` **is** committed to the repo, but it is
regenerated from `project.yml` by `make project`. Run `make project` after any
edit to `project.yml`; don't hand-edit the `.xcodeproj`.

## Architecture

```
AfterwordsApp (entry point)
  ├── MenuBarExtra → PopoverView (Start/Stop/Restart, Logs, API, Voices…)
  ├── Settings    → SettingsView (Launch-at-Login, CLI path, port)
  └── Window      → VoiceListView (browse/preview voices, set default)

Services (all @MainActor, injected via @EnvironmentObject):
  ├── CLIExecutor       — runs `afterwords` CLI with explicit PATH injection
  ├── HealthMonitor     — polls GET /health; owns the ServerState machine
  ├── SamplePlayer      — fetches and plays voice samples via NSSound
  └── UpdaterController — wraps SPUStandardUpdaterController (Sparkle 2)
```

**Key principle:** the app delegates server lifecycle to the `afterwords` CLI;
launchd owns the actual server process. `HealthMonitor` polls `/health` as the
single source of truth for server state — CLI commands are fire-and-forget.

### State machine

```
.stopped ──start──► .starting(since: Date) ──health 200──► .running(HealthInfo)
.running ──3 poll failures──► .error(message)
.running ──stop──► .stopped
.error   ──start──► .starting(since: Date)
.starting ──90s timeout──► .error("Server did not become healthy…")
```

On first poll after launch, if `autoStartServer` is enabled and the server is
confirmed stopped, the app issues a single `afterwords start` automatically.

## Commands

```bash
make project    # Regenerate Afterwords.xcodeproj from project.yml
make open       # Regenerate and open in Xcode
make build      # Debug build (xcodebuild)
make test       # Run XCTest suite
make dmg        # Release build + unsigned DMG at build/Release/Afterwords.dmg
make clean      # Remove the generated .xcodeproj and build/
```

## Releasing

See [`RELEASING.md`](RELEASING.md) for the version-bump / DMG / Sparkle
appcast signing workflow.

## Design decisions

- **No App Sandbox** — subprocess spawning requires it disabled
  (`ENABLE_APP_SANDBOX: NO` in `project.yml`).
- **Explicit PATH injection** — macOS GUI apps don't inherit shell PATH; every
  `Foundation.Process` gets
  `/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin` plus user overrides.
- **launchd owns the server** — `Quit` does *not* stop the server.
- **Port is UI-only** — changing the port in Settings only affects which URL
  `HealthMonitor` polls; it does not reconfigure the server's bind port.
- **Sparkle 2** — the only third-party dependency (via Swift Package Manager).

## License

Private — Copyright 2026 Adrian Wedd
