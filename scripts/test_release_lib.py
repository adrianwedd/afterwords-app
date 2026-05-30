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
