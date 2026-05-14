# Afterwords Menu-Bar App

A native macOS menu-bar app for managing the [Afterwords](https://github.com/adrianwedd/afterwords) TTS server.

## Requirements

- macOS 13.0+ (Ventura)
- Xcode 15.0+
- [Afterwords](https://github.com/adrianwedd/afterwords) installed and on PATH

## Setup

1. Install [XcodeGen](https://github.com/yonaskolb/XcodeGen):
   ```bash
   brew install xcodegen
   ```

2. Generate the Xcode project:
   ```bash
   make project
   ```

3. Open in Xcode:
   ```bash
   make open
   ```

4. Build and run from Xcode (Cmd+R).

## Architecture

```
Afterwords.app
  ├── MenuBarExtra (popover UI)
  ├── CLIExecutor (Foundation.Process + PATH injection)
  ├── HealthMonitor (GET /health polling → ServerState)
  └── AppDelegate (SMAppService for launch-at-login)
```

**Key principle:** The app delegates server lifecycle to the `afterwords` CLI. It does not manage the server process directly — launchd owns that. HealthMonitor polls `/health` as the single source of truth for server state.

### State Machine

```
.stopped → (start) → .starting(since: Date) → (health 200) → .running(HealthInfo)
.running → (3 poll failures) → .error(message)
.running → (stop) → .stopped
.error → (start) → .starting(since: Date)
.starting → (90s timeout) → .error("Server did not become healthy…")
```

## Development

```bash
# Generate Xcode project
make project

# Open in Xcode
make open

# Build from command line
make build

# Run tests
make test
```

## Design Decisions

- **No App Sandbox** — the app spawns subprocesses, which sandbox blocks
- **Explicit PATH injection** — macOS GUI apps don't inherit shell PATH; every `Foundation.Process` gets `/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin` plus user overrides
- **launchd owns server lifecycle** — the app calls `afterwords start/stop/restart` and trusts the CLI; HealthMonitor detects results
- **Quit does NOT stop server** — the server is managed by launchd and should stay running for Claude Code hooks

## License

Private — Copyright 2026 Adrian Wedd