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
