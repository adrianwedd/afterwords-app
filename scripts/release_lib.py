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


def build_item(short_version, bundle_version, url, signature, length,
               pubdate, min_system="13.0"):
    """Render one appcast <item> block (8-space base indent, trailing \n)."""
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
