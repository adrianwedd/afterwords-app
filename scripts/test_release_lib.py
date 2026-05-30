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


if __name__ == "__main__":
    unittest.main()
