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
