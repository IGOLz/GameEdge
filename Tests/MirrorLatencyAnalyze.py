"""Match unique, identical fingerprints. Reject static/ambiguous images.

python3 Tests/MirrorLatencyAnalyze.py build/latency.json [...]
These are WindowServer timestamp differences, not mouse-to-photon timings.
Two concurrent observer streams affect load and have independent sampling phases.
"""
import bisect
import collections
import json
import statistics
import sys


def analyze(rows):
    source = sorted((r for r in rows if r["source"]), key=lambda r: r["time"])
    output = sorted((r for r in rows if not r["source"]), key=lambda r: r["time"])
    stamps = collections.defaultdict(list)
    for frame in source:
        stamps[tuple(frame["pixels"])].append(frame["time"])
    matched, seen = [], set()
    ambiguous = unmatched = 0
    for frame in output[50:]:
        key = tuple(frame["pixels"])
        times = stamps.get(key, [])
        left = bisect.bisect_left(times, frame["time"] - 0.150)
        right = bisect.bisect_right(times, frame["time"] + 0.002)
        if right - left != 1:
            ambiguous += right - left > 1
            unmatched += right == left
            continue
        identity = (key, times[left])
        if identity in seen:
            continue
        seen.add(identity)
        matched.append((frame["time"] - times[left]) * 1000)
    matched.sort()
    return {
        "source_samples": len(source), "output_samples": len(output),
        "unique_exact_matches": len(matched), "ambiguous": ambiguous, "unmatched": unmatched,
        "median_ms": statistics.median(matched) if matched else None,
        "p95_ms": matched[min(len(matched)-1, int(len(matched)*.95))] if matched else None,
        "negative_samples": sum(value < 0 for value in matched),
    }


if __name__ == "__main__":
    for path in sys.argv[1:]:
        with open(path) as file:
            print(json.dumps({"file": path, **analyze(json.load(file))}))
