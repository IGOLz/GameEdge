import unittest

from FramePacingAnalyze import analyze


def frames(source=True, start=0, stop=200, step=.01, repeat=1):
    return [dict(source=source, time=i * step, pixels=[i // repeat])
            for i in range(start, stop + 1)]


class FramePacingChecks(unittest.TestCase):
    def test_known_rate_and_arrival(self):
        rows = frames()
        for row in rows:
            row["arrival"] = row["time"] + .003
        result = analyze(rows)
        source = result["streams"]["source"]
        self.assertAlmostEqual(result["duration_seconds"], 1.5)
        self.assertAlmostEqual(source["changes_per_second"], 100)
        self.assertAlmostEqual(source["changed_image_intervals"]["p95_ms"], 10)
        self.assertAlmostEqual(source["arrival_minus_timestamp"]["p50_ms"], 3)
        self.assertTrue(source["sample_sufficient"])
        self.assertIsNone(result["source_coverage"])

    def test_repeats_and_output_only(self):
        result = analyze(frames(source=False, repeat=2))
        output = result["streams"]["output"]
        self.assertAlmostEqual(output["changes_per_second"], 50)
        self.assertEqual(output["repeated_samples"], 75)
        self.assertAlmostEqual(output["repeat_fraction"], 75 / 151)
        self.assertAlmostEqual(output["changed_image_intervals"]["p99_ms"], 20)
        self.assertIsNone(result["source_coverage"])

    def test_unequal_startup_and_unsorted_rows(self):
        rows = frames(stop=300) + frames(source=False, start=100, stop=250)
        result = analyze(list(reversed(rows)))
        self.assertAlmostEqual(result["window_start"], 1.5)
        self.assertAlmostEqual(result["window_end"], 2.5)
        self.assertAlmostEqual(result["duration_seconds"], 1)
        self.assertEqual(result["streams"]["source"]["samples"], 101)
        self.assertAlmostEqual(result["source_coverage"]["observed_fraction"], 1)

    def test_unobserved_source_and_end_trim(self):
        output = frames(source=False)
        for row in output:
            if row["pixels"][0] % 2:
                row["pixels"][0] = -1
        result = analyze(frames() + output)
        coverage = result["source_coverage"]
        self.assertEqual(coverage["eligible_unique_source_samples"], 136)
        self.assertEqual(coverage["observed_source_samples"], 68)
        self.assertEqual(coverage["unobserved_source_samples"], 68)
        self.assertEqual(coverage["end_trimmed_source_samples"], 15)

    def test_static_scene_is_ambiguous(self):
        rows = frames() + frames(source=False)
        for row in rows:
            row["pixels"] = [1]
        result = analyze(rows)
        source = result["streams"]["source"]
        self.assertEqual(source["changes_per_second"], 0)
        self.assertIsNone(source["changed_image_intervals"])
        self.assertFalse(source["sample_sufficient"])
        coverage = result["source_coverage"]
        self.assertEqual(coverage["ambiguous_source_samples"], 136)
        self.assertIsNone(coverage["observed_fraction"])
        self.assertTrue(any("Static" in w for w in source["warnings"]))
        self.assertTrue(any("Ambiguous" in w for w in coverage["warnings"]))

    def test_empty_short_and_nonoverlapping_samples(self):
        self.assertTrue(analyze([])["warnings"])
        result = analyze(frames(stop=10))
        self.assertEqual(result["duration_seconds"], 0)
        self.assertFalse(result["streams"]["source"]["sample_sufficient"])
        result = analyze(frames(stop=100) + frames(source=False, start=200))
        self.assertEqual(result["duration_seconds"], 0)
        self.assertTrue(result["warnings"])

    def test_match_timing_window(self):
        output = frames(source=False)
        for row in output:
            row["time"] += .151
        result = analyze(frames() + output)
        self.assertEqual(result["source_coverage"]["observed_source_samples"], 0)

    def test_invalid_timestamp(self):
        with self.assertRaises(ValueError):
            analyze([dict(source=True, time=float("nan"), pixels=[1])])

    def test_negative_arrival_and_no_matching_pixels_are_flagged(self):
        output = frames(source=False)
        for row in output:
            row["pixels"][0] += 1000
            row["arrival"] = row["time"] - .002
        result = analyze(frames() + output)
        self.assertTrue(any("arrivals precede" in w for w in result["streams"]["output"]["warnings"]))
        self.assertTrue(any("No exact matches" in w for w in result["source_coverage"]["warnings"]))


if __name__ == "__main__":
    unittest.main()
