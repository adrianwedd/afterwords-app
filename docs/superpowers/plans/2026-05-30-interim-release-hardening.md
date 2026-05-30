# Interim Release Hardening Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the manual 8-step Sparkle release runbook with one self-verifying `make release` command (dry-run by default, `PUBLISH=1` to go live), backed by a unit-tested pure-Python appcast helper and a no-secret CI guard, while the app stays unsigned/un-notarized.

**Architecture:** A pure-logic module `scripts/release_lib.py` (appcast parse / validate / item-build / newest-first insert / byte-consistency assert) with a thin argparse CLI, unit-tested with stdlib `unittest`. A `scripts/release.sh` orchestrator sequences I/O (preflight → bump → `make dmg` → `sign_update` → hash → assert → print, then on `PUBLISH=1`: commit-bump → tag → release → re-verify → appcast-commit), resumable from a partial release. CI runs the unit tests plus `validate` against the committed `appcast.xml`. The EdDSA private key never leaves the local macOS Keychain.

**Tech Stack:** Python 3 (stdlib only — `xml.etree.ElementTree`, `argparse`, `unittest`), Bash, Make, GitHub Actions, Sparkle `sign_update`, `gh` CLI, `/usr/libexec/PlistBuddy`.

---

## File structure

| File | Responsibility |
|---|---|
| `scripts/release_lib.py` | Pure appcast logic + CLI dispatch. No git/network/build I/O. |
| `scripts/test_release_lib.py` | `unittest` suite for every pure function. |
| `scripts/release.sh` | Orchestration: preflight, build, sign, hash, assert, publish, resume. |
| `Makefile` | New `release` target forwarding `VERSION` / `PUBLISH`. |
| `.github/workflows/ci.yml` | New `verify-appcast` step (tests + `validate`). |
| `RELEASING.md` | `make release` promoted to happy path; manual steps demoted to appendix; caveats. |

**Key conventions (used across tasks):**
- Sparkle namespace URI: `http://www.andymatuschak.org/xml-namespaces/sparkle`.
- Appcast indentation: `<channel>` at 4 spaces, its children (`<item>`) at 8 spaces, item children at 12 spaces.
- `insert_item` is **string insertion** (not ElementTree re-serialize) so the leading doc-comment and the `xmlns:sparkle` declaration survive untouched. ElementTree is used **read-only** for parsing/validation.
- `CFBundleVersion` (the Sparkle comparator) is **derived**: `highest_sparkle_version + 1`, or `1` when the channel is empty.

---

## Task 1: Create `release_lib.py` skeleton + `assert_consistent` (TDD)

**Files:**
- Create: `scripts/release_lib.py`
- Create: `scripts/test_release_lib.py`

- [ ] **Step 1: Write the failing test**

Create `scripts/test_release_lib.py`:

```python
import unittest

import release_lib


class AssertConsistentTests(unittest.TestCase):
    def test_passes_on_equal_lengths(self):
        release_lib.assert_consistent(12345, 12345)  # no raise

    def test_passes_when_one_is_a_numeric_string(self):
        release_lib.assert_consistent("12345", 12345)  # no raise

    def test_raises_on_mismatch(self):
        with self.assertRaises(ValueError):
            release_lib.assert_consistent(12345, 12344)


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd scripts && python3 -m unittest test_release_lib -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'release_lib'`.

- [ ] **Step 3: Write minimal implementation**

Create `scripts/release_lib.py`:

```python
"""Pure helpers for building and validating the Sparkle appcast.

No git, network, or build I/O lives here — only string/XML logic, so every
function is unit-testable. The CLI at the bottom is the seam release.sh calls.
"""

import argparse
import sys
import xml.etree.ElementTree as ET

SPARKLE_NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"


def _q(tag):
    """Namespace-qualified tag/attr name, e.g. _q('version') for ElementTree."""
    return f"{{{SPARKLE_NS}}}{tag}"


def assert_consistent(sign_update_length, stat_length):
    """Raise ValueError unless the two byte counts are equal.

    Guards the #1 silent-failure: the appcast <enclosure length> and the signed
    bytes must describe the exact same artifact.
    """
    if int(sign_update_length) != int(stat_length):
        raise ValueError(
            f"byte-length mismatch: sign_update={sign_update_length} "
            f"stat={stat_length}"
        )
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd scripts && python3 -m unittest test_release_lib -v`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add scripts/release_lib.py scripts/test_release_lib.py
git commit -m "feat(release): add release_lib skeleton + assert_consistent byte-guard"
```

---

## Task 2: `parse_items` + `validate_appcast` (TDD)

**Files:**
- Modify: `scripts/release_lib.py`
- Modify: `scripts/test_release_lib.py`

- [ ] **Step 1: Write the failing tests**

Append to `scripts/test_release_lib.py` (above the `if __name__` block):

```python
EMPTY_APPCAST = """<?xml version="1.0" encoding="utf-8"?>
<!-- doc comment that must survive -->
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
    <channel>
        <title>Afterwords</title>
        <link>https://example/appcast.xml</link>
        <description>Afterwords release notes</description>
        <language>en</language>
    </channel>
</rss>"""


def _appcast_with(items_xml):
    return EMPTY_APPCAST.replace(
        "        <language>en</language>\n",
        "        <language>en</language>\n" + items_xml,
    )


VALID_ITEM = """        <item>
            <title>Afterwords 1.1</title>
            <sparkle:version>2</sparkle:version>
            <sparkle:shortVersionString>1.1</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>13.0</sparkle:minimumSystemVersion>
            <pubDate>Thu, 29 May 2026 12:00:00 +0000</pubDate>
            <enclosure
                url="https://example/releases/download/v1.1/Afterwords.dmg"
                sparkle:edSignature="abc=="
                length="12345"
                type="application/octet-stream" />
        </item>
"""


class ValidateAppcastTests(unittest.TestCase):
    def test_empty_channel_is_valid(self):
        self.assertEqual(release_lib.validate_appcast(EMPTY_APPCAST), [])

    def test_valid_item_is_valid(self):
        self.assertEqual(
            release_lib.validate_appcast(_appcast_with(VALID_ITEM)), []
        )

    def test_malformed_xml_is_reported(self):
        problems = release_lib.validate_appcast("<rss><channel></rss>")
        self.assertTrue(any("malformed" in p for p in problems))

    def test_empty_signature_is_rejected(self):
        bad = VALID_ITEM.replace('sparkle:edSignature="abc=="',
                                 'sparkle:edSignature=""')
        problems = release_lib.validate_appcast(_appcast_with(bad))
        self.assertTrue(any("edSignature" in p for p in problems))

    def test_zero_length_is_rejected(self):
        bad = VALID_ITEM.replace('length="12345"', 'length="0"')
        problems = release_lib.validate_appcast(_appcast_with(bad))
        self.assertTrue(any("length" in p for p in problems))

    def test_non_decreasing_versions_rejected(self):
        # second item has a HIGHER version below the first -> not newest-first
        older = VALID_ITEM.replace("<sparkle:version>2</sparkle:version>",
                                   "<sparkle:version>3</sparkle:version>")
        problems = release_lib.validate_appcast(_appcast_with(VALID_ITEM + older))
        self.assertTrue(any("decreasing" in p for p in problems))

    def test_doctype_is_rejected(self):
        # billion-laughs / XXE both require a DTD; a real appcast never has one.
        billion = (
            '<?xml version="1.0"?>\n'
            '<!DOCTYPE rss [<!ENTITY a "AAAA">]>\n' + EMPTY_APPCAST.split("\n", 2)[2]
        )
        problems = release_lib.validate_appcast(billion)
        self.assertTrue(any("DOCTYPE" in p for p in problems))
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd scripts && python3 -m unittest test_release_lib -v`
Expected: FAIL — `AttributeError: module 'release_lib' has no attribute 'validate_appcast'`.

- [ ] **Step 3: Write minimal implementation**

Add to `scripts/release_lib.py` (after `assert_consistent`):

```python
def parse_items(appcast_xml):
    """Return one dict per <item>: version, short, url, length, signature.

    The appcast is a trusted, repo-owned file, but we stay stdlib-only (no
    defusedxml dependency) and neutralize the billion-laughs / XXE class the
    cheap way: refuse any input carrying a DTD. A legitimate appcast has none,
    and both attacks require entity declarations in a <!DOCTYPE.
    """
    if "<!DOCTYPE" in appcast_xml:
        raise ValueError("appcast must not contain a DOCTYPE/DTD")
    root = ET.fromstring(appcast_xml)
    channel = root.find("channel")
    items = []
    for it in (channel.findall("item") if channel is not None else []):
        enc = it.find("enclosure")
        ver = it.find(_q("version"))
        short = it.find(_q("shortVersionString"))
        items.append({
            "version": ver.text if ver is not None else None,
            "short": short.text if short is not None else None,
            "url": enc.get("url") if enc is not None else None,
            "length": enc.get("length") if enc is not None else None,
            "signature": enc.get(_q("edSignature")) if enc is not None else None,
        })
    return items


def validate_appcast(appcast_xml):
    """Return a list of human-readable problems; an empty list means valid.

    An empty channel (zero <item>s) is valid. Versions must be unique and
    strictly DECREASING top-to-bottom (newest item first).
    """
    try:
        items = parse_items(appcast_xml)
    except ET.ParseError as exc:
        return [f"malformed XML: {exc}"]
    except ValueError as exc:
        return [str(exc)]  # e.g. DOCTYPE/DTD rejected

    problems = []
    versions = []
    for i, it in enumerate(items):
        label = f"item[{i}]"
        if not it["signature"]:
            problems.append(f"{label}: missing/empty sparkle:edSignature")
        if not it["url"]:
            problems.append(f"{label}: missing enclosure url")
        if not it["short"]:
            problems.append(f"{label}: missing sparkle:shortVersionString")
        if not it["version"]:
            problems.append(f"{label}: missing sparkle:version")
        else:
            try:
                versions.append(int(it["version"]))
            except ValueError:
                problems.append(f"{label}: sparkle:version not an integer")
        try:
            if int(it["length"]) <= 0:
                problems.append(f"{label}: enclosure length must be > 0")
        except (TypeError, ValueError):
            problems.append(f"{label}: enclosure length not an integer")

    if len(versions) != len(set(versions)):
        problems.append("duplicate sparkle:version values")
    for above, below in zip(versions, versions[1:]):
        if not above > below:
            problems.append(
                f"versions not strictly decreasing top-to-bottom: "
                f"{above} !> {below}"
            )
    return problems
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd scripts && python3 -m unittest test_release_lib -v`
Expected: PASS (all tests).

- [ ] **Step 5: Commit**

```bash
git add scripts/release_lib.py scripts/test_release_lib.py
git commit -m "feat(release): parse + validate appcast (empty channel valid, newest-first)"
```

---

## Task 3: `highest_version` + `existing_short_versions` (TDD)

**Files:**
- Modify: `scripts/release_lib.py`
- Modify: `scripts/test_release_lib.py`

- [ ] **Step 1: Write the failing tests**

Append to `scripts/test_release_lib.py`:

```python
class VersionQueryTests(unittest.TestCase):
    def test_highest_version_is_none_for_empty_channel(self):
        self.assertIsNone(release_lib.highest_version(EMPTY_APPCAST))

    def test_highest_version_reads_items(self):
        self.assertEqual(
            release_lib.highest_version(_appcast_with(VALID_ITEM)), 2
        )

    def test_existing_short_versions_empty_channel(self):
        self.assertEqual(release_lib.existing_short_versions(EMPTY_APPCAST), [])

    def test_existing_short_versions_lists_shorts(self):
        self.assertEqual(
            release_lib.existing_short_versions(_appcast_with(VALID_ITEM)),
            ["1.1"],
        )
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd scripts && python3 -m unittest test_release_lib -v`
Expected: FAIL — `AttributeError: ... 'highest_version'`.

- [ ] **Step 3: Write minimal implementation**

Add to `scripts/release_lib.py`:

```python
def highest_version(appcast_xml):
    """Highest integer sparkle:version across items, or None if no items."""
    vers = [
        int(it["version"])
        for it in parse_items(appcast_xml)
        if it["version"] and it["version"].lstrip("-").isdigit()
    ]
    return max(vers) if vers else None


def existing_short_versions(appcast_xml):
    """All sparkle:shortVersionString values present (for reuse detection)."""
    return [it["short"] for it in parse_items(appcast_xml) if it["short"]]
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd scripts && python3 -m unittest test_release_lib -v`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add scripts/release_lib.py scripts/test_release_lib.py
git commit -m "feat(release): highest_version + existing_short_versions queries"
```

---

## Task 4: `build_item` (TDD)

**Files:**
- Modify: `scripts/release_lib.py`
- Modify: `scripts/test_release_lib.py`

- [ ] **Step 1: Write the failing tests**

Append to `scripts/test_release_lib.py`:

```python
class BuildItemTests(unittest.TestCase):
    def _item(self):
        return release_lib.build_item(
            short_version="1.1",
            bundle_version=2,
            url="https://example/releases/download/v1.1/Afterwords.dmg",
            signature="abc==",
            length=12345,
            pubdate="Thu, 29 May 2026 12:00:00 +0000",
        )

    def test_contains_expected_fields(self):
        item = self._item()
        self.assertIn("<title>Afterwords 1.1</title>", item)
        self.assertIn("<sparkle:version>2</sparkle:version>", item)
        self.assertIn("<sparkle:shortVersionString>1.1</sparkle:shortVersionString>", item)
        self.assertIn('sparkle:edSignature="abc=="', item)
        self.assertIn('length="12345"', item)
        self.assertIn("<sparkle:minimumSystemVersion>13.0</sparkle:minimumSystemVersion>", item)

    def test_is_well_formed_inside_a_channel(self):
        # Building an appcast from the item must parse and validate clean.
        appcast = _appcast_with(self._item())
        self.assertEqual(release_lib.validate_appcast(appcast), [])

    def test_eight_space_base_indent(self):
        self.assertTrue(self._item().startswith("        <item>\n"))
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd scripts && python3 -m unittest test_release_lib -v`
Expected: FAIL — `AttributeError: ... 'build_item'`.

- [ ] **Step 3: Write minimal implementation**

Add to `scripts/release_lib.py`:

```python
def build_item(short_version, bundle_version, url, signature, length,
               pubdate, min_system="13.0"):
    """Render one appcast <item> block (8-space base indent, trailing \\n)."""
    return (
        "        <item>\n"
        f"            <title>Afterwords {short_version}</title>\n"
        f"            <sparkle:version>{bundle_version}</sparkle:version>\n"
        f"            <sparkle:shortVersionString>{short_version}"
        "</sparkle:shortVersionString>\n"
        f"            <sparkle:minimumSystemVersion>{min_system}"
        "</sparkle:minimumSystemVersion>\n"
        f"            <pubDate>{pubdate}</pubDate>\n"
        "            <enclosure\n"
        f'                url="{url}"\n'
        f'                sparkle:edSignature="{signature}"\n'
        f'                length="{length}"\n'
        '                type="application/octet-stream" />\n'
        "        </item>\n"
    )
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd scripts && python3 -m unittest test_release_lib -v`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add scripts/release_lib.py scripts/test_release_lib.py
git commit -m "feat(release): build_item renders an indented appcast <item>"
```

---

## Task 5: `insert_item` — newest-first, comment/namespace preserving (TDD)

**Files:**
- Modify: `scripts/release_lib.py`
- Modify: `scripts/test_release_lib.py`

- [ ] **Step 1: Write the failing tests**

Append to `scripts/test_release_lib.py`:

```python
class InsertItemTests(unittest.TestCase):
    def _new_item(self, short, bundle):
        return release_lib.build_item(
            short_version=short, bundle_version=bundle,
            url=f"https://example/releases/download/v{short}/Afterwords.dmg",
            signature="sig==", length=999,
            pubdate="Thu, 29 May 2026 12:00:00 +0000",
        )

    def test_insert_into_empty_channel_validates(self):
        out = release_lib.insert_item(EMPTY_APPCAST, self._new_item("1.0", 1))
        self.assertEqual(release_lib.validate_appcast(out), [])
        self.assertIn("<sparkle:version>1</sparkle:version>", out)

    def test_preserves_leading_comment(self):
        out = release_lib.insert_item(EMPTY_APPCAST, self._new_item("1.0", 1))
        self.assertIn("<!-- doc comment that must survive -->", out)

    def test_preserves_sparkle_namespace_declaration(self):
        out = release_lib.insert_item(EMPTY_APPCAST, self._new_item("1.0", 1))
        self.assertIn(
            'xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"',
            out,
        )

    def test_newest_first_ordering(self):
        once = release_lib.insert_item(EMPTY_APPCAST, self._new_item("1.0", 1))
        twice = release_lib.insert_item(once, self._new_item("1.1", 2))
        # newest (version 2) must appear before older (version 1)
        self.assertLess(twice.index("<sparkle:version>2</sparkle:version>"),
                        twice.index("<sparkle:version>1</sparkle:version>"))
        # and the result is still valid (strictly decreasing)
        self.assertEqual(release_lib.validate_appcast(twice), [])
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd scripts && python3 -m unittest test_release_lib -v`
Expected: FAIL — `AttributeError: ... 'insert_item'`.

- [ ] **Step 3: Write minimal implementation**

Add to `scripts/release_lib.py`:

```python
def insert_item(appcast_xml, item_block):
    """Insert item_block newest-first via string splice (preserving comments
    and the namespace declaration that an ElementTree round-trip would drop).

    Newest-first = before the first existing <item>, else before </channel>.
    """
    first_item = appcast_xml.find("        <item>")
    anchor = first_item if first_item != -1 else appcast_xml.find("    </channel>")
    if anchor == -1:
        raise ValueError("appcast has neither an <item> nor a </channel> anchor")
    return appcast_xml[:anchor] + item_block + appcast_xml[anchor:]
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd scripts && python3 -m unittest test_release_lib -v`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add scripts/release_lib.py scripts/test_release_lib.py
git commit -m "feat(release): insert_item splices newest-first, preserves comments/ns"
```

---

## Task 6: argparse CLI dispatch (the shell seam)

**Files:**
- Modify: `scripts/release_lib.py`
- Modify: `scripts/test_release_lib.py`

- [ ] **Step 1: Write the failing test**

Append to `scripts/test_release_lib.py` (add `import subprocess`, `import os` at the top of the file):

```python
class CliTests(unittest.TestCase):
    def _run(self, *args, input_text=None):
        here = os.path.dirname(os.path.abspath(__file__))
        return subprocess.run(
            ["python3", os.path.join(here, "release_lib.py"), *args],
            input=input_text, capture_output=True, text=True,
        )

    def test_validate_empty_channel_exits_zero(self):
        r = self._run("validate", "-", input_text=EMPTY_APPCAST)
        self.assertEqual(r.returncode, 0, r.stderr)

    def test_validate_bad_appcast_exits_nonzero(self):
        bad = VALID_ITEM.replace('length="12345"', 'length="0"')
        r = self._run("validate", "-", input_text=_appcast_with(bad))
        self.assertEqual(r.returncode, 1)
        self.assertIn("length", r.stdout + r.stderr)

    def test_highest_version_prints_blank_for_empty(self):
        r = self._run("highest-version", "-", input_text=EMPTY_APPCAST)
        self.assertEqual(r.returncode, 0)
        self.assertEqual(r.stdout.strip(), "")
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd scripts && python3 -m unittest test_release_lib -v`
Expected: FAIL — CLI exits non-zero / no dispatch (argparse error or `SystemExit`).

- [ ] **Step 3: Write minimal implementation**

Add to the bottom of `scripts/release_lib.py`:

```python
def _read(path):
    return sys.stdin.read() if path == "-" else open(path, encoding="utf-8").read()


def _main(argv=None):
    parser = argparse.ArgumentParser(description="Appcast helpers for release.sh")
    sub = parser.add_subparsers(dest="cmd", required=True)

    p_val = sub.add_parser("validate", help="exit 1 and print problems if invalid")
    p_val.add_argument("appcast", help="path or - for stdin")

    p_hi = sub.add_parser("highest-version", help="print highest sparkle:version")
    p_hi.add_argument("appcast")

    p_sh = sub.add_parser("short-versions", help="print existing short versions")
    p_sh.add_argument("appcast")

    p_bi = sub.add_parser("build-item", help="print a rendered <item>")
    for flag in ("--short", "--bundle", "--url", "--sig", "--length", "--pubdate"):
        p_bi.add_argument(flag, required=True)

    p_ins = sub.add_parser("insert-item", help="splice an item file into an appcast")
    p_ins.add_argument("appcast")
    p_ins.add_argument("item", help="path to the rendered <item> block")

    args = parser.parse_args(argv)

    if args.cmd == "validate":
        problems = validate_appcast(_read(args.appcast))
        for p in problems:
            print(p)
        return 1 if problems else 0
    if args.cmd == "highest-version":
        hv = highest_version(_read(args.appcast))
        print("" if hv is None else hv)
        return 0
    if args.cmd == "short-versions":
        print("\n".join(existing_short_versions(_read(args.appcast))))
        return 0
    if args.cmd == "build-item":
        print(build_item(args.short, args.bundle, args.url, args.sig,
                         args.length, args.pubdate), end="")
        return 0
    if args.cmd == "insert-item":
        item = open(args.item, encoding="utf-8").read()
        sys.stdout.write(insert_item(_read(args.appcast), item))
        return 0
    return 2


if __name__ == "__main__":
    sys.exit(_main())
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd scripts && python3 -m unittest test_release_lib -v`
Expected: PASS (all suites).

- [ ] **Step 5: Commit**

```bash
git add scripts/release_lib.py scripts/test_release_lib.py
git commit -m "feat(release): argparse CLI (validate/highest-version/build-item/insert-item)"
```

---

## Task 7: `scripts/release.sh` orchestrator (dry-run + publish + resume)

**Files:**
- Create: `scripts/release.sh`

This script is verified by a real dry-run (Step 3), not a unit test — it performs build/git/network I/O. It must never tag, release, or push in dry-run mode.

- [ ] **Step 1: Write the script**

Create `scripts/release.sh`:

```bash
#!/usr/bin/env bash
# Reliable Sparkle release for the UNSIGNED Afterwords DMG.
#
#   make release VERSION=1.1            # dry-run: build, sign, hash, print item
#   make release VERSION=1.1 PUBLISH=1  # go live: tag, release, publish appcast
#
# CFBundleVersion (Sparkle's comparator) is derived as highest+1, so the
# strict-monotonic invariant cannot be violated by operator error. The EdDSA
# private key is read from the local Keychain by sign_update and never leaves
# this machine.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

LIB="scripts/release_lib.py"
APPCAST="appcast.xml"
PLIST="Afterwords/Info.plist"
DMG="build/Release/Afterwords.dmg"
APP_VERSION="${VERSION:?Set VERSION=x.y (e.g. make release VERSION=1.1)}"
PUBLISH="${PUBLISH:-0}"
TAG="v${APP_VERSION}"
ASSET_URL="https://github.com/adrianwedd/afterwords-app/releases/download/${TAG}/Afterwords.dmg"

die() { echo "ERROR: $*" >&2; exit 1; }
note() { echo ">>> $*"; }

# ---- Preflight (no build yet) ----------------------------------------------
preflight() {
  note "Preflight"
  [ "$(git rev-parse --abbrev-ref HEAD)" = "main" ] || die "not on main"
  [ -z "$(git status --porcelain)" ] || die "working tree not clean"
  git fetch --quiet origin main
  [ "$(git rev-list --count HEAD..origin/main)" = "0" ] \
    || die "local main is behind origin/main — pull first"
  gh auth status >/dev/null 2>&1 || die "gh not authenticated (gh auth login)"

  # Reuse guard: short version must not already be published.
  if python3 "$LIB" short-versions "$APPCAST" | grep -qx "$APP_VERSION"; then
    die "version $APP_VERSION already exists in $APPCAST"
  fi

  HIGHEST="$(python3 "$LIB" highest-version "$APPCAST")"
  BUNDLE=$(( ${HIGHEST:-0} + 1 ))
  note "Derived CFBundleVersion=$BUNDLE (highest was ${HIGHEST:-none})"
}

# ---- Build + sign + hash (produces a single artifact) ----------------------
build_sign_hash() {
  note "Bumping $PLIST to $APP_VERSION / $BUNDLE"
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $APP_VERSION" "$PLIST"
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUNDLE" "$PLIST"

  note "make dmg"
  make dmg >/dev/null

  SIGN_UPDATE="$(find build/DerivedData ~/Library/Developer/Xcode/DerivedData \
    -name sign_update -type f 2>/dev/null | head -n1)"
  [ -n "$SIGN_UPDATE" ] || die "sign_update not found (did make dmg fetch Sparkle?)"

  local out; out="$("$SIGN_UPDATE" "$DMG")"
  SIGNATURE="$(printf '%s' "$out" | sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p')"
  SIGN_LEN="$(printf '%s' "$out" | sed -n 's/.*length="\([0-9]*\)".*/\1/p')"
  [ -n "$SIGNATURE" ] && [ -n "$SIGN_LEN" ] || die "could not parse sign_update output: $out"

  STAT_LEN="$(stat -f%z "$DMG")"
  SHA256="$(shasum -a 256 "$DMG" | awk '{print $1}')"
  # Byte-identity guard: the signed length must equal the bytes on disk.
  [ "$SIGN_LEN" = "$STAT_LEN" ] || die "byte mismatch sign_update=$SIGN_LEN stat=$STAT_LEN"

  PUBDATE="$(date -u +'%a, %d %b %Y %H:%M:%S +0000')"
  ITEM_FILE="$(mktemp)"
  python3 "$LIB" build-item \
    --short "$APP_VERSION" --bundle "$BUNDLE" --url "$ASSET_URL" \
    --sig "$SIGNATURE" --length "$SIGN_LEN" --pubdate "$PUBDATE" > "$ITEM_FILE"
}

# ---- Resume: reuse already-published bytes (never rebuild) ------------------
resume_from_published() {
  note "Tag $TAG and release already exist — resuming from published bytes"
  local tmp; tmp="$(mktemp -d)"
  gh release download "$TAG" --pattern "Afterwords.dmg" --dir "$tmp" \
    || die "release $TAG exists but Afterwords.dmg asset is missing — fix manually"
  SIGN_UPDATE="$(find build/DerivedData ~/Library/Developer/Xcode/DerivedData \
    -name sign_update -type f 2>/dev/null | head -n1)"
  [ -n "$SIGN_UPDATE" ] || die "sign_update not found — run 'make dmg' once to fetch Sparkle"
  local out; out="$("$SIGN_UPDATE" "$tmp/Afterwords.dmg")"
  SIGNATURE="$(printf '%s' "$out" | sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p')"
  SIGN_LEN="$(printf '%s' "$out" | sed -n 's/.*length="\([0-9]*\)".*/\1/p')"
  SHA256="$(shasum -a 256 "$tmp/Afterwords.dmg" | awk '{print $1}')"
  HIGHEST="$(python3 "$LIB" highest-version "$APPCAST")"
  BUNDLE=$(( ${HIGHEST:-0} + 1 ))
  PUBDATE="$(date -u +'%a, %d %b %Y %H:%M:%S +0000')"
  ITEM_FILE="$(mktemp)"
  python3 "$LIB" build-item \
    --short "$APP_VERSION" --bundle "$BUNDLE" --url "$ASSET_URL" \
    --sig "$SIGNATURE" --length "$SIGN_LEN" --pubdate "$PUBDATE" > "$ITEM_FILE"
}

# ---- Publish appcast (the go-live commit) ----------------------------------
publish_appcast() {
  note "Re-verify published asset"
  local tmp; tmp="$(mktemp -d)"
  gh release download "$TAG" --pattern "Afterwords.dmg" --dir "$tmp" --clobber
  [ "$(stat -f%z "$tmp/Afterwords.dmg")" = "$SIGN_LEN" ] \
    || die "published asset length != signed length"
  [ "$(shasum -a 256 "$tmp/Afterwords.dmg" | awk '{print $1}')" = "$SHA256" ] \
    || die "published asset SHA-256 != local SHA-256"

  note "Splicing item into $APPCAST"
  python3 "$LIB" insert-item "$APPCAST" "$ITEM_FILE" > "$APPCAST.tmp"
  mv "$APPCAST.tmp" "$APPCAST"
  python3 "$LIB" validate "$APPCAST" || die "resulting appcast failed validation"

  git add "$APPCAST"
  git commit -m "chore(release): publish $APP_VERSION appcast"
  git push origin main
  note "LIVE — existing installs will offer $APP_VERSION"
}

main() {
  preflight

  if git ls-remote --tags origin "$TAG" | grep -q "$TAG"; then
    [ "$PUBLISH" = "1" ] || die "tag $TAG already exists — re-run with PUBLISH=1 to resume"
    resume_from_published
    publish_appcast
    return
  fi

  build_sign_hash

  note "Proposed appcast item:"
  cat "$ITEM_FILE"
  note "SHA-256: $SHA256"

  if [ "$PUBLISH" != "1" ]; then
    note "Dry-run complete. Reverting $PLIST. Re-run with PUBLISH=1 to go live."
    git checkout -- "$PLIST"
    return
  fi

  note "Publishing $APP_VERSION"
  git add "$PLIST"
  git commit -m "chore(release): bump to $APP_VERSION"
  git tag "$TAG"
  git push origin main
  git push origin "$TAG"
  gh release create "$TAG" "$DMG" \
    --title "Afterwords $APP_VERSION" \
    --notes "$(printf 'Afterwords %s\n\n---\n**Verify your download** (the DMG is unsigned/un-notarized):\n\n```\nshasum -a 256 Afterwords.dmg\n```\nExpected: `%s`\n' "$APP_VERSION" "$SHA256")"
  publish_appcast
}

main "$@"
```

- [ ] **Step 2: Make executable and dry-run against the real repo**

```bash
chmod +x scripts/release.sh
VERSION=1.0 bash scripts/release.sh 2>&1 | tail -30
```

Expected: preflight passes, `make dmg` runs, a `<item>` block and a SHA-256 print, the run ends with "Dry-run complete", and `git status` is **clean** (the Info.plist bump was reverted). It must NOT create a tag (`git tag` shows nothing new) or a release.

- [ ] **Step 3: Confirm no side effects**

```bash
git status --porcelain   # expect: only the new untracked scripts/release.sh
git tag                  # expect: no v1.0 tag
gh release list          # expect: empty
```

- [ ] **Step 4: Commit**

```bash
git add scripts/release.sh
git commit -m "feat(release): release.sh orchestrator (dry-run default, PUBLISH=1, resumable)"
```

---

## Task 8: `make release` target

**Files:**
- Modify: `Makefile`

- [ ] **Step 1: Add the target**

In `Makefile`, change the `.PHONY` line and append a `release` target:

Change line 1 from:

```make
.PHONY: project open build test dmg clean
```

to:

```make
.PHONY: project open build test dmg clean release
```

Append at end of file:

```make
release:
	bash scripts/release.sh
```

- [ ] **Step 2: Verify it forwards VERSION and dry-runs**

Run: `make release VERSION=1.0 2>&1 | tail -5`
Expected: ends with "Dry-run complete", `git status` clean.

- [ ] **Step 3: Verify the guard when VERSION is missing**

Run: `make release 2>&1 | tail -3`
Expected: fails with "Set VERSION=x.y".

- [ ] **Step 4: Commit**

```bash
git add Makefile
git commit -m "feat(release): make release target forwarding VERSION/PUBLISH"
```

---

## Task 9: CI `verify-appcast` guard (no secret)

**Files:**
- Modify: `.github/workflows/ci.yml`

- [ ] **Step 1: Add the step**

In `.github/workflows/ci.yml`, after the `Verify GitHub Pages assets` step (currently the last step, ending line 49), append:

```yaml

      - name: Verify appcast + release tooling
        run: |
          python3 -m unittest discover -s scripts -p 'test_*.py' -v
          python3 scripts/release_lib.py validate appcast.xml
          echo "appcast + release_lib: OK"
```

- [ ] **Step 2: Run the same commands locally to confirm green**

```bash
python3 -m unittest discover -s scripts -p 'test_*.py'
python3 scripts/release_lib.py validate appcast.xml && echo "appcast OK"
```

Expected: all tests pass; `appcast OK` (the committed empty channel validates).

- [ ] **Step 3: Confirm permissions stay read-only**

Run: `grep -A1 "^permissions:" .github/workflows/ci.yml`
Expected: `contents: read` (unchanged — this guard needs no secret or write).

- [ ] **Step 4: Commit**

```bash
git add .github/workflows/ci.yml
git commit -m "ci: validate appcast.xml + run release_lib tests (no secret)"
```

---

## Task 10: Rewrite `RELEASING.md` — happy path + appendix + caveats

**Files:**
- Modify: `RELEASING.md`

- [ ] **Step 1: Add the `make release` happy-path section**

In `RELEASING.md`, immediately after the `## Cutting a release` heading (line ~115, before the existing "The steps are ordered..." paragraph), insert:

```markdown
### The fast path: `make release`

The whole flow below is automated by one command. **Dry-run by default:**

```bash
make release VERSION=1.1
```

This bumps `Info.plist`, builds the DMG, signs it, computes the SHA-256,
asserts the signed length matches the bytes on disk, and prints the exact
appcast `<item>` and SHA-256 — then **reverts the version bump and stops**.
Nothing is tagged, released, or pushed. `CFBundleVersion` is derived
automatically as `highest + 1`, so you never hand-pick it.

Review the printed item and SHA-256, then go live:

```bash
make release VERSION=1.1 PUBLISH=1
```

This commits the bump, tags `v1.1` on that commit, creates the GitHub Release
(DMG attached, SHA-256 in the body), re-downloads the published asset to
re-verify its length and SHA-256, then splices the item into `appcast.xml` and
pushes `main`. If a prior run died after the release was created, re-running
with `PUBLISH=1` **resumes from the published bytes** (it re-signs the existing
asset rather than rebuilding) and finishes the appcast.

The manual steps below remain the source of truth the script automates, and the
fallback if it ever breaks.

---
```

- [ ] **Step 2: Add the two caveats**

In the `## Current distribution reality (read this first)` section, append two bullets to the existing list:

```markdown
- **Gatekeeper on auto-update.** TODO during first real release: verify whether
  a Sparkle-delivered update to this unsigned app re-triggers a Gatekeeper
  right-click→Open prompt on *each* update, or only the first manual install.
  Document the observed behaviour here honestly once confirmed; do not assume.
- **Protect the EdDSA key.** It lives in the Keychain under the default account
  `ed25519` / service `https://sparkle-project.org`. Do **not** run
  `generate_keys` again on this machine (e.g. for another Sparkle app) — it can
  overwrite this key, which is unrecoverable for the installed base. Back it up.
```

- [ ] **Step 3: Verify the doc still reads coherently**

Run: `grep -n "make release\|Gatekeeper on auto-update\|generate_keys" RELEASING.md`
Expected: the new fast-path section and both caveats are present; the original numbered steps remain below.

- [ ] **Step 4: Commit**

```bash
git add RELEASING.md
git commit -m "docs(release): document make release fast path + Gatekeeper/key caveats"
```

---

## Final verification

- [ ] **Step 1: Full unit suite**

Run: `python3 -m unittest discover -s scripts -p 'test_*.py' -v`
Expected: all tests PASS.

- [ ] **Step 2: Appcast validates**

Run: `python3 scripts/release_lib.py validate appcast.xml && echo OK`
Expected: `OK`.

- [ ] **Step 3: Swift suite still green (nothing app-side changed, but confirm)**

Run: `make test 2>&1 | grep -E "TEST (SUCCEEDED|FAILED)"`
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 4: End-to-end dry-run leaves the repo clean**

Run: `make release VERSION=1.0 >/dev/null 2>&1; git status --porcelain`
Expected: empty output (no leftover Info.plist change).
