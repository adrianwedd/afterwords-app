# Afterwords for macOS

A native macOS menu-bar **control panel** for the locally-running
[Afterwords](https://adrianwedd.github.io/afterwords/) text-to-speech server.

[![CI](https://github.com/adrianwedd/afterwords-app/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/adrianwedd/afterwords-app/actions/workflows/ci.yml)
![macOS 13.0+](https://img.shields.io/badge/macOS-13.0%2B-blue)
![Apple Silicon](https://img.shields.io/badge/arch-Apple%20Silicon-lightgrey)
![Swift 5.9](https://img.shields.io/badge/Swift-5.9-orange)
![Sparkle 2](https://img.shields.io/badge/updates-Sparkle%202-green)

Website: <https://afterwords-app.pages.dev/>

## What it is

Afterwords is a small SwiftUI menu-bar app that lets you start, stop, and watch
a separate **Afterwords TTS server** running on your Mac. It is a *control
panel*, not the server.

The app does **not** run or own the server process — `launchd` does. The app
issues `afterwords start` / `stop` / `restart` CLI commands (fire-and-forget)
and polls `GET /health` as the single source of truth for whether the server is
up. Everything you see in the menu bar — the status colour, the voice list — is
derived from those health polls.

This repository is **only the menu-bar app**. It is distinct from two related
but separate sibling projects, which it does not bundle or manage:

- **Afterwords (local)** — the TTS server itself.
  Repo: <https://github.com/adrianwedd/afterwords> ·
  Site: <https://adrianwedd.github.io/afterwords/>
- **Afterwords Cloud** — the hosted offering.
  Site: <https://afterwords-cloud.pages.dev/>

## Features

- **Menu-bar status icon** that reflects the server's live state at a glance:
  Stopped (grey), Starting (yellow), Running (green), Error (red). Polling
  starts at launch, so a server that was already running shows green without
  any interaction.
- **Start / Stop / Restart** buttons in the popover. Buttons enable and disable
  themselves based on the current state (e.g. Stop is only active while
  Running).
- **Logs** button — opens `/tmp/claude-tts-server.log` in Console.app.
- **API** button — opens `http://localhost:<port>` in your browser.
- **Voices window** — a flat, alphabetical, searchable list of the server's
  voices (populated only while the server is Running).
  - **Single-click** a voice to hear a short, fixed-phrase sample
    (`"Hello. This is the <voice> voice."`) fetched from `GET /synthesize` and
    played via `NSSound`.
  - **Double-click or right-click** to set a default/preferred voice, persisted
    in `UserDefaults` (`preferredVoice`) and shown in the popover.
- **Settings**
  - *Launch at Login* (via `SMAppService`).
  - *Auto-start Server* — issues a single `afterwords start` the first time a
    poll confirms the server is stopped.
  - *CLI Path* override with an Auto-detect button.
  - *Server Port* — **UI-only**: it only changes which URL the app polls; it
    does **not** reconfigure the running server's bind port.
- **Auto-updates** via Sparkle 2 with an EdDSA-signed appcast
  (*Check for Updates…* in the popover).

### What it does *not* do

Sample playback is the **only** audio the app produces. It is deliberately not a
general TTS tool: there is **no** arbitrary text-to-speech from the menu bar,
**no** synthesis history / recent-synthesis list, **no** dictation, and **no**
system-wide TTS. To synthesize speech from your own text, talk to the Afterwords
server directly (e.g. its `/synthesize` HTTP endpoint).

## What it looks like

There is no embedded screenshot in this repo. In short:

- The **popover** (click the menu-bar icon) shows a status line, the
  Start/Stop/Restart row, the Logs/API row, a backend/voice count when Running,
  the default voice (if set), and buttons for *Voices…*, *Settings…*, and
  *Check for Updates…*.
- The **Voices window** is a search box over an alphabetical voice list with a
  footer reminder: "Click to play a sample. Double-click or right-click to set
  as default."

## Requirements

- **macOS 13.0+ (Ventura)**, Apple Silicon.
- The **Afterwords TTS server** installed locally and exposing `GET /health`
  and `GET /synthesize` on the configured port (default **7860**). The sample
  feature depends on `/synthesize`.
- For building from source: **Xcode 15+ / Swift 5.9** (CI builds with Xcode
  16.2 on `macos-15`).

The `afterwords` binary does **not** need to be on your shell `PATH` — the app
injects its own PATH and probes well-known locations
(`/usr/local/bin`, `/opt/homebrew/bin`, `/opt/homebrew/sbin`, `/usr/bin`). If
your binary lives elsewhere, set an explicit **CLI Path** override in Settings.

## Install (end users)

Download the DMG (or build it yourself with `make dmg`, which produces
`build/Release/Afterwords.dmg`), then drag **Afterwords.app** to `/Applications`.

> **First launch:** the DMG is currently **unsigned and un-notarized**, so
> Gatekeeper will block a normal double-click. Right-click the app and choose
> **Open**, then confirm. You only need to do this once.

App **updates** are integrity-protected: Sparkle verifies each update against an
EdDSA (Ed25519) signature, so the unsigned first install does not weaken the
update channel.

## Build from source

1. Install [XcodeGen](https://github.com/yonaskolb/XcodeGen):
   ```bash
   brew install xcodegen
   ```
2. Open in Xcode (regenerates the project and opens it), then press **Cmd+R**
   inside Xcode to run:
   ```bash
   make open
   ```
   …or build headlessly:
   ```bash
   make build
   ```

`Afterwords.xcodeproj/project.pbxproj` **is** committed to the repo, but it is
regenerated from `project.yml` by `make project`. Run `make project` after any
edit to `project.yml`; do **not** hand-edit the `.xcodeproj`.

## Commands

```bash
make project    # Regenerate Afterwords.xcodeproj from project.yml
make open       # Regenerate and open in Xcode (then Cmd+R to run)
make build      # Debug build (xcodebuild)
make test       # Run XCTest suite
make dmg        # Release build + unsigned DMG at build/Release/Afterwords.dmg
make clean      # Remove the generated .xcodeproj and build/
```

## Architecture

```
AfterwordsApp (@main entry point)
  ├── MenuBarExtra(.window) → PopoverView   (Status, Start/Stop/Restart,
  │                                           Logs, API, Voices…, Settings…,
  │                                           Check for Updates…)
  ├── Settings              → SettingsView  (General + Advanced tabs)
  └── Window("Voices")      → VoiceListView (searchable voice list, samples)

Services (all @MainActor final class, injected via @EnvironmentObject):
  ├── CLIExecutor       — runs `afterwords` via Foundation.Process with explicit
  │                       PATH injection + CLI-path validation
  ├── HealthMonitor     — polls GET /health; owns the ServerState machine
  ├── SamplePlayer      — fetches GET /synthesize, plays the WAV via NSSound
  └── UpdaterController — wraps SPUStandardUpdaterController (Sparkle 2)
```

**Key principle:** the app delegates server lifecycle to the `afterwords` CLI;
`launchd` owns the actual server process. `HealthMonitor` polling `/health` is
the single source of truth for server state — CLI commands are fire-and-forget,
and the app never assumes a command succeeded; it waits for the next poll to
confirm.

### State machine

`ServerState` has four cases: `.stopped`, `.starting(since:)`,
`.running(HealthInfo)`, `.error(message:)`.

```
.stopped  ──notifyStartAttempt()──►  .starting(since: Date)
.starting ──health 200────────────►  .running(HealthInfo)
.starting ──90s startup timeout───►  .error("Server did not become healthy within 90s")
.running  ──health 200────────────►  .running(HealthInfo)   (self-loop; success resets failures)
.running  ──3 CONSECUTIVE failures►  .error("Server crashed: …")
.running  ──notifyStopAttempt()───►  .stopped
.error    ──notifyStartAttempt()──►  .starting(since: Date)
```

Notes (all from `HealthMonitor.swift`):

- **Poll cadence:** every **5s** while `.running`, every **2s** while
  `.starting`; each request has a **3s** timeout.
- **Crash detection is consecutive, not cumulative** — any successful poll
  resets `consecutiveFailures` to 0. It takes 3 failures in a row to declare an
  error.
- **First-poll auto-start:** if *Auto-start Server* is enabled and the first
  poll confirms the server is stopped, the app issues exactly one
  `afterwords start`.

## Testing

```bash
make test
```

Runs the `XCTest` suite in `AfterwordsTests/` (covers `ServerState`,
`HealthInfo` decoding, `HealthMonitor`, `CLIExecutor`, and `SamplePlayer`).
`HealthMonitor` exposes `simulateHealthResult(info:error:)` under `#if DEBUG` so
state-machine transitions can be driven without real network calls. Run
`make test` after any change to services or models.

## Design decisions

- **No App Sandbox** — subprocess spawning requires it disabled
  (`ENABLE_APP_SANDBOX: NO` in `project.yml`).
- **Explicit PATH injection** — macOS GUI apps don't inherit the shell PATH, so
  every `Foundation.Process` gets
  `/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin`
  plus any user override.
- **CLI-path validation** — defense-in-depth on the unsandboxed subprocess
  surface: the app refuses to launch any binary whose name is not `afterwords`.
- **launchd owns the server** — *Quit* does **not** stop the server.
- **Port is UI-only** — changing the port in Settings only affects which URL
  `HealthMonitor` polls; it does not reconfigure the server's bind port.
- **Sparkle 2** is the only third-party dependency (via Swift Package Manager).

## Troubleshooting

- **Voices window is empty / disabled** — the list is only available while the
  server is Running. Start the server first.
- **Logs button says "Log file not found"** — `/tmp/claude-tts-server.log` is
  created by the server at start. Start the server, then try again.
- **Status stuck on Error / health failing after changing the port** — the port
  in Settings is UI-only. Reconfigure the server's actual bind port (its
  `launchd` plist or `--port`) and restart the server; then set the matching
  port in the app.
- **"Refusing to run … the CLI path must point to a binary named afterwords"**
  — fix the CLI Path override in Settings (Auto-detect helps).
- **Launch at Login needs approval** — enable it in
  **System Settings > General > Login Items**.

## Releasing

See [`RELEASING.md`](RELEASING.md) for the version-bump / DMG / Sparkle appcast
EdDSA-signing workflow. `appcast.xml` is intentionally an empty (but valid)
channel until a signed release is published — Sparkle silently rejects items
without a valid `sparkle:edSignature`.

## Contributing

- Coding conventions: Swift 5.9, macOS 13 deployment target (use
  `onChange(of:perform:)`, not the two-argument macOS 14 form); all service
  types are `@MainActor final class`; conventional-commit scopes
  (`fix(settings):`, `feat(monitor):`, `test:`, `chore:`).
- See [`CLAUDE.md`](CLAUDE.md), [`AGENTS.md`](AGENTS.md), and
  [`GEMINI.md`](GEMINI.md) for the full contributor/agent guides.
- Run `make test` before opening a PR, and regenerate the project with
  `make project` rather than editing `project.pbxproj` by hand.

## License

[MIT](LICENSE) — Copyright © 2026 Adrian Wedd.
