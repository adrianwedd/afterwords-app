# Security Review — afterwords-app

**Date:** 2026-05-29
**Reviewer:** Automated security review (Claude Code `/security-review`)
**Scope:** Whole repository — all Swift source (~1,400 LOC), Sparkle update chain,
build/release tooling, CI workflow, entitlements, and the web docs site.
**Commit reviewed:** `5737ac6` (branch `main`)

## Summary

**Overall posture: strong.** The two areas that would be *critical* if
misconfigured — the Sparkle auto-update chain and subprocess execution — are both
handled correctly. No high or critical vulnerabilities were found. All findings
below are hardening / defense-in-depth.

| # | Severity | Finding | Status |
|---|----------|---------|--------|
| 1 | LOW  | Unvalidated, UserDefaults-controlled executable path runs in an unsandboxed app | ✅ Fixed (2026-05-29) |
| 2 | LOW  | Distribution DMG is unsigned and un-notarized | Open (roadmap) |
| 3 | LOW  | CI uses mutable action/tool versions; no explicit least-privilege `permissions` | ✅ Fixed (2026-05-29) |
| 4 | INFO | No response-size bound on localhost fetches | Open (optional) |
| 5 | INFO | Web docs load Google Fonts without SRI | Open (optional) |

## What's done right (verified, not assumed)

- **Sparkle update integrity is correct.** `SUFeedURL` is HTTPS
  (`raw.githubusercontent.com`) and `SUPublicEDKey` is set
  (`Afterwords/Info.plist:29-32`), so EdDSA signature verification is enforced on
  every downloaded update. `appcast.xml` is intentionally empty until a signed
  item exists, and `RELEASING.md` documents the `sign_update` flow. This is the
  single most important control in an auto-updating unsigned app, and it is right.
- **No shell, no command injection.** `CLIExecutor`
  (`Afterwords/Services/CLIExecutor.swift:142-158`) uses `Process` with
  `executableURL` plus a fixed argument array (`["start"]`, `["stop"]`,
  `["restart"]`) — never `/bin/sh -c`. No user-controlled data flows into the
  argument vector.
- **No URL / query injection.** `SamplePlayer.synthesizeURL`
  (`Afterwords/Services/SamplePlayer.swift:82-93`) builds requests via
  `URLComponents` / `URLQueryItem`, which percent-encode `text` / `voice`. The
  temp-file / path-traversal class is deliberately avoided by decoding WAV
  in-memory (documented at `SamplePlayer.swift:16-19`).
- **No secrets in the repo.** A pattern scan across Swift / yml / plist / md /
  html / xml surfaced only the *public* EdDSA key (correct to commit) — no API
  keys, tokens, or private keys.

## Findings

### 1. LOW — Unvalidated, UserDefaults-controlled executable path runs in an unsandboxed app

`CLIExecutor.resolvedCLIPath` (`Afterwords/Services/CLIExecutor.swift:98-104`)
reads `cliPathOverride` from `UserDefaults` and executes it directly;
`resolvedPATH` (`CLIExecutor.swift:107-114`) similarly prepends `additionalPath`.
The app ships with App Sandbox disabled (`Afterwords/Afterwords.entitlements`,
`project.yml:36`). Because `~/Library/Preferences/com.afterwords.app.plist` is
writable by any process running as the same user, a local malicious process could
point `cliPathOverride` at an arbitrary binary, which Afterwords then executes on
the next Start/Stop/Restart — or *silently on launch* if `autoStartServer` is
enabled (`Afterwords/Services/HealthMonitor.swift:238-241`).

**Boundary note:** this does not cross a privilege boundary — anything that can
write your `UserDefaults` can already run code as you. Real-world severity is
therefore low. It is cheap defense-in-depth.

**Recommendation:** validate the resolved path before executing — e.g. require
the binary's filename to be `afterwords` and/or that it resides in a known-good
directory, rejecting paths outside `/usr/local/bin`, `/opt/homebrew/{bin,sbin}`,
`/usr/bin`. Sandboxing is incompatible with subprocess spawning (correctly noted
in `CLAUDE.md`), so path validation is the practical mitigation.

**✅ Resolved (2026-05-29):** `CLIExecutor.validationError(forCLIPath:)` now
refuses any path whose basename isn't `afterwords` or that isn't an executable
file, and `run()` calls it before spawning — covering the manual Start/Stop and
the silent auto-start path. The basename rule breaks no legitimate use (every
path the app generates ends in `/afterwords`) while blocking the casual
"repurpose the override" attack. Covered by four tests in `CLIExecutorTests`.

### 2. LOW — Distribution DMG is unsigned and un-notarized

`project.yml:14` sets `CODE_SIGN_ID: ""` and `RELEASING.md:38-41` confirms
`make dmg` produces an unsigned DMG (users right-click → Open). Auto-*updates*
are protected by Sparkle's EdDSA verification, but the **initial download** has no
Developer ID signature or notarization, so Gatekeeper cannot detect a tampered
first install, and the on-disk binary can be modified without detection. This is
a known, documented limitation, not a regression.

**Recommendation:** wire up Developer ID signing + notarization for release
builds when feasible (already on the roadmap). Until then, publish the DMG's
SHA-256 alongside each GitHub Release so users can verify the download.

### 3. LOW — CI uses mutable action/tool versions (supply-chain)

`.github/workflows/ci.yml` pins `actions/checkout@v6` and
`maxim-lobanov/setup-xcode@v1` (mutable major tags) and runs
`brew install xcodegen` (always latest). Xcode itself is correctly pinned
(`16.2`). The job only builds/tests and uses no secrets, so blast radius is
limited to build integrity, but a compromised action tag could still tamper with
build output.

**Recommendation:** pin third-party actions to a full commit SHA, and add an
explicit least-privilege block to the workflow (there is currently no
`permissions:` block, so it inherits repo defaults):

```yaml
permissions:
  contents: read
```

**✅ Resolved (2026-05-29):** `.github/workflows/ci.yml` now declares
`permissions: contents: read` and pins both third-party actions to full commit
SHAs (`actions/checkout@de0fac2…` / `maxim-lobanov/setup-xcode@ed7a3b1…`), each
with a trailing `# v6` / `# v1` comment for readable version bumps.

### 4. INFO — No response-size bound on localhost fetches

`SamplePlayer.fetchAndPlay` (`Afterwords/Services/SamplePlayer.swift:99`) uses
`URLSession.shared.data(from:)` and `HealthMonitor`
(`Afterwords/Services/HealthMonitor.swift:190`) decodes JSON, both loading the
full response into memory with no size cap. A buggy or compromised local server
could return a very large body and exhaust memory. The threat model is "your own
local server," and `HealthMonitor` has a 3s timeout, so impact is minimal.
`NSSound(data:)` also parses attacker-influenced audio, but the trust boundary is
the user's own loopback server.

**Recommendation:** optional — cap accepted `Content-Length` / bytes for the
sample fetch.

### 5. INFO — Web docs load Google Fonts without SRI

`docs/index.html:19` pulls a stylesheet from `fonts.googleapis.com`. It is a
static marketing page with no script and no user input (no XSS surface), so this
is purely a third-party / privacy note (visitor IPs to Google) with no Subresource
Integrity on the CSS.

**Recommendation:** optional — self-host the two fonts to remove the third-party
dependency.

## Non-issues (checked and cleared)

- The `id-token: write` permission found by the scan is in an **untracked
  planning doc** (`docs/superpowers/plans/...`) describing a Pages workflow that
  was subsequently created and then **removed** (commit `5737ac6`, migrated to
  Cloudflare Pages). No active workflow grants elevated permissions.
- Cleartext `http://localhost` (`HealthMonitor`, `PopoverView`, `SettingsView`)
  is fine — loopback only; no ATS exception is needed or present.

## Suggested next steps

1. **Finding 1** — add executable-path validation in `CLIExecutor` (highest value, small change).
2. **Finding 3** — pin CI actions to SHAs and add `permissions: contents: read`.
3. **Finding 2** — Developer ID signing + notarization (longer-term, roadmap item); publish DMG SHA-256 in the interim.
