import unittest
from MirrorLatencyAnalyze import analyze


def frame(time, pixels, source):
    return dict(time=time, pixels=pixels, source=source)


def warmup():
    return [frame(i / 1000, [-1], False) for i in range(50)]


class LatencyChecks(unittest.TestCase):
    def test_known_delay(self):
        rows = warmup()
        for i in range(100):
            rows += [frame(1 + i / 100, [i], True), frame(1.01 + i / 100, [i], False)]
        result = analyze(rows)
        self.assertEqual(result['unique_exact_matches'], 100)
        self.assertAlmostEqual(result['median_ms'], 10)

    def test_static_frames_are_ambiguous(self):
        rows = warmup() + [frame(1 + i / 1000, [1], True) for i in range(100)]
        rows += [frame(1.1, [1], False)]
        result = analyze(rows)
        self.assertEqual(result['unique_exact_matches'], 0)
        self.assertEqual(result['ambiguous'], 1)

    def test_repeated_output_counts_first_presentation_only(self):
        rows = warmup() + [frame(1, [1], True), frame(1.01, [1], False), frame(1.02, [1], False)]
        result = analyze(rows)
        self.assertEqual(result['unique_exact_matches'], 1)
        self.assertAlmostEqual(result['median_ms'], 10)

    def test_stale_or_different_pixels_are_rejected(self):
        rows = warmup() + [frame(1, [1], True), frame(1.2, [1], False), frame(1.01, [2], False)]
        self.assertEqual(analyze(rows)['unique_exact_matches'], 0)


if __name__ == '__main__':
    unittest.main()
