# QA workplan — afterwords-app (2026-08-06)

> **For agentic workers:** Use superpowers:executing-plans (or subagent-driven-development)
> to run tasks in order. STRATEGY.md invariant applies throughout: NEVER
> `git add -A` / `git add .` in this repo — stage explicit paths only.

**Status:** RESOLVED plan (decisions made 2026-08-06, rationale inline — veto by
editing this doc). Source: read-only QA sweep 2026-08-06.
**Baseline:** main = 012f006 (even with origin), v1.3 released 2026-06-15,
nothing unreleased on main. Build + 63 XCTests + 30 Python tests + appcast
validation + CI: all green. Zero pbxproj/xcodegen drift.

---

## Task 1 — Close #8.2: gitignore Python caches

Verified 2026-08-06: `.gitignore` has no `__pycache__` entry;
`scripts/__pycache__/` shows as untracked.

- [ ] Append to `.gitignore`:
      ```
      __pycache__/
      .pytest_cache/
      ```
- [ ] Done-check: `git status --short` no longer lists `scripts/__pycache__/`.
- [ ] `git add .gitignore && git commit -m "chore: ignore Python caches (#8)" && git push`

## Task 2 — Commit the doctrine pair (CLAUDE.md pointer + STRATEGY.md)

**Resolved: commit both together; HANDOFF.md stays untracked.** Rationale: the
pointer line and STRATEGY.md are one change — the pointer is dead without the
file. STRATEGY.md is finished, load-bearing doctrine (both sibling repos ship
theirs, afterwords' landed via PR #107), and leaving it untracked means every
fresh clone/agent runs without the invariants it encodes — the riskiest state.
HANDOFF.md's own header says "Deliberately untracked; delete once absorbed":
honor that — not committed, not deleted here (deletion is its own judgment call
once its content is confirmed absorbed).

- [ ] `git add CLAUDE.md STRATEGY.md && git commit -m "docs: add STRATEGY.md doctrine + CLAUDE.md pointer" && git push`
- [ ] Done-check: `git status --short` shows neither `M CLAUDE.md` nor
      `?? STRATEGY.md`; HANDOFF.md still listed as untracked.

## Task 3 — Commit the two sprint plans as-is; close #8

**Resolved: commit, verbatim.** Rationale: STRATEGY.md itself classifies
`docs/superpowers/plans/*` as evidence-class ("preserve; never
rewrite/summarize/delete") and flags these two as the untracked exceptions —
tracking them is the consistent endpoint, and untracked evidence is one
`git clean` from gone. No rewriting (evidence-class). #8.3 needs no action —
the issue is itself the record that the Hermes QA claims are stale.

- [ ] `git add docs/superpowers/plans/2026-05-25-sprint2.md docs/superpowers/plans/2026-05-30-sprint5-app.md`
      then `git commit -m "docs: track frozen sprint plans as evidence (#8)" && git push`
- [ ] With Tasks 1+3 done, every actionable #8 item is closed:
      `gh issue close 8 --comment "8.1: both sprint plans committed verbatim (evidence-class). 8.2: __pycache__/ + .pytest_cache/ gitignored. 8.3: no action — the issue itself is the record."`
- [ ] Done-check: `gh issue view 8 --json state` → CLOSED;
      `git status --short` shows only `?? HANDOFF.md`, `?? hermes_qa_2026-06-21.md`,
      and this plan doc (until it too is committed).

## Task 4 — Branch hygiene

All four verified fully merged / superseded (QA sweep; PR #3 merged from
`fix/status-primary-backend`; branch list re-verified against
`git ls-remote` 2026-08-06).

- [ ] `git push origin --delete fix/status-primary-backend security-fixes-2026-06 sprint6-app-redesign`
- [ ] `git branch -D security-fixes-2026-06 sprint5-app-redesign sprint6-app-redesign`
- [ ] Done-check: `git ls-remote --heads origin` lists only `main`;
      `git branch --list` lists only `main`.

## Needs Adrian's access (agents: prep only, per STRATEGY.md escalation rules)

- **#5 — Confirm docs/ deployment:** Cloudflare dashboard → Pages project for
  afterwords-app.pages.dev (production branch, build config). Once the settings
  are pasted into #5, an agent finishes it: document in README/RELEASING.md,
  flip STRATEGY.md §1 INFERRED → OBSERVED.
- **#6 — Sparkle vs Gatekeeper:** observe at next real release window; record
  the answer in RELEASING.md, replacing the TODO.
- **#7 — Developer ID signing + notarization:** blocked on acquiring a cert;
  when done, re-evaluate `ENABLE_APP_SANDBOX: NO`, update RELEASING.md +
  SECURITY.md, keep the SHA-256 manifest flow.

## Non-goals

Tests, CI, release state, docs accuracy: verified clean. Do not touch
`hermes_qa_2026-06-21.md` (evidence, documented-stale) or HANDOFF.md beyond
what Task 2 states.
