"""Observed fingerprint cadence, not game FPS, scanout, or input latency.

python3 Tests/FramePacingAnalyze.py recording.json [recording.json ...]
Add --summary for readable text instead of one JSON object per file.
Times are seconds. Optional arrival times must use the same clock as time.
Independent capture streams can miss frames and add load. Static or spatially
sparse fingerprints cannot establish rendering cadence. First samples establish
state; only subsequent image changes count toward changes_per_second.
"""
import argparse
import bisect
import collections
import json
import math
import statistics


def distribution(values):
    """Milliseconds, using nearest-rank percentiles and the ordinary median."""
    values = sorted(value * 1000 for value in values)
    if not values:
        return None
    return {
        "count": len(values),
        "p50_ms": statistics.median(values),
        "p95_ms": values[math.ceil(len(values) * .95) - 1],
        "p99_ms": values[math.ceil(len(values) * .99) - 1],
        "max_ms": values[-1],
    }


def stream_summary(frames, duration):
    changes = [frame["time"] for i, frame in enumerate(frames)
               if i == 0 or frame["pixels"] != frames[i - 1]["pixels"]]
    intervals = [b - a for a, b in zip(changes, changes[1:])]
    repeated = len(frames) - len(changes)
    warnings = []
    if duration < 1 or len(intervals) < 20:
        warnings.append("Insufficient sample: need at least 1 second and 20 image changes for a useful cadence summary.")
    if frames and len(changes) == 1:
        warnings.append("Static fingerprint: rendering FPS cannot be inferred.")
    if len({frame["time"] for frame in frames}) < len(frames):
        warnings.append("Duplicate timestamps: zero-length intervals may distort cadence.")
    arrival_offsets = [f["arrival"] - f["time"] for f in frames if "arrival" in f]
    if any(offset < 0 for offset in arrival_offsets):
        warnings.append("Some arrivals precede frame timestamps; timestamp semantics must be checked before interpreting latency.")
    return {
        "samples": len(frames),
        "samples_per_second": len(frames) / duration if duration > 0 else None,
        "distinct_changes": len(intervals),
        "changes_per_second": len(intervals) / duration if duration > 0 else None,
        "repeated_samples": repeated,
        "repeat_fraction": repeated / len(frames) if frames else None,
        "changed_image_intervals": distribution(intervals),
        "arrival_minus_timestamp": distribution(arrival_offsets),
        "sample_sufficient": duration >= 1 and len(intervals) >= 20,
        "warnings": warnings,
    }


def analyze(rows, warmup_seconds=.5):
    if not math.isfinite(warmup_seconds) or warmup_seconds < 0:
        raise ValueError("warmup_seconds must be finite and nonnegative")
    groups = {"source": [], "output": []}
    for index, row in enumerate(rows):
        if not isinstance(row, dict) or type(row.get("source")) is not bool:
            raise ValueError("row %d requires a boolean source" % index)
        for field in ("time", "arrival"):
            if field == "arrival" and field not in row:
                continue
            value = row.get(field)
            if type(value) not in (int, float) or not math.isfinite(value):
                raise ValueError("row %d requires finite numeric %s" % (index, field))
        if not isinstance(row.get("pixels"), list) or not row["pixels"] or any(type(p) is not int for p in row["pixels"]):
            raise ValueError("row %d requires a nonempty integer pixel list" % index)
        groups["source" if row["source"] else "output"].append(row)
    groups = {name: sorted(frames, key=lambda f: f["time"])
              for name, frames in groups.items() if frames}
    result = {
        "measurement": "Observed fingerprint changes; not rendering FPS, physical presentation, or input latency.",
        "warmup_seconds": warmup_seconds,
        "window_start": None, "window_end": None, "duration_seconds": 0,
        "streams": {}, "source_coverage": None, "warnings": [],
    }
    if not groups:
        result["warnings"].append("No samples.")
        return result
    start = max(frames[0]["time"] for frames in groups.values()) + warmup_seconds
    end = min(frames[-1]["time"] for frames in groups.values())
    duration = max(0, end - start)
    result.update(window_start=start, window_end=end, duration_seconds=duration)
    trimmed = {name: [f for f in frames if start <= f["time"] <= end]
               for name, frames in groups.items()}
    result["streams"] = {name: stream_summary(frames, duration) for name, frames in trimmed.items()}
    if duration <= 0:
        result["warnings"].append("No positive observation interval remains after overlap and warmup.")
    if len(groups) == 1:
        result["warnings"].append("Single stream: source-to-output coverage is unavailable.")
        return result
    source = trimmed["source"]
    frequencies = collections.Counter(tuple(f["pixels"]) for f in source)
    output_times = collections.defaultdict(list)
    for frame in trimmed["output"]:
        output_times[tuple(frame["pixels"])].append(frame["time"])
    eligible = [f for f in source if f["time"] <= end - .150]
    ambiguous = sum(frequencies[tuple(f["pixels"])] > 1 for f in eligible)
    unique = [f for f in eligible if frequencies[tuple(f["pixels"])] == 1]
    observed = 0
    for frame in unique:
        times = output_times[tuple(frame["pixels"])]
        left = bisect.bisect_left(times, frame["time"] - .002)
        right = bisect.bisect_right(times, frame["time"] + .150)
        observed += right > left
    warnings = []
    if ambiguous:
        warnings.append("Ambiguous repeated source fingerprints are excluded from coverage.")
    if len(unique) < 20:
        warnings.append("Insufficient unique source fingerprints: fewer than 20 eligible observations.")
    if unique and not observed:
        warnings.append("No exact matches: verify crop, color, clock, and endpoint compatibility before interpreting coverage as frame loss.")
    result["source_coverage"] = {
        "minimum_delay_ms": -2, "maximum_delay_ms": 150, "end_trim_ms": 150,
        "eligible_unique_source_samples": len(unique),
        "ambiguous_source_samples": ambiguous,
        "end_trimmed_source_samples": len(source) - len(eligible),
        "observed_source_samples": observed,
        "unobserved_source_samples": len(unique) - observed,
        "observed_fraction": observed / len(unique) if unique else None,
        "sample_sufficient": duration >= 1 and len(unique) >= 20,
        "warnings": warnings,
        "limitation": "Unobserved fingerprints cannot distinguish mirror drops from observer sampling or crop differences.",
    }
    return result


def readable(result):
    lines = ["%s: %.3f seconds" % (result.get("file", "recording"), result["duration_seconds"])]
    for name, stream in result["streams"].items():
        rate = stream["changes_per_second"]
        gaps = stream["changed_image_intervals"]
        lines.append("  %s: %s changes/s, %d samples, %d repeats%s" % (
            name, "n/a" if rate is None else "%.2f" % rate,
            stream["samples"], stream["repeated_samples"],
            "" if gaps is None else ", gaps p95 %.2f / max %.2f ms" % (gaps["p95_ms"], gaps["max_ms"])))
        lines.extend("  Warning: " + w for w in stream["warnings"])
    coverage = result["source_coverage"]
    if coverage:
        lines.append("  Observed unique source fingerprints: %d/%d" % (
            coverage["observed_source_samples"], coverage["eligible_unique_source_samples"]))
        lines.extend("  Warning: " + w for w in coverage["warnings"])
    lines.extend("  Warning: " + w for w in result["warnings"])
    lines.append("  " + result["measurement"])
    return "\n".join(lines)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("files", nargs="+")
    parser.add_argument("--summary", action="store_true")
    args = parser.parse_args()
    for path in args.files:
        try:
            with open(path) as file:
                result = analyze(json.load(file))
        except (OSError, ValueError, TypeError) as error:
            parser.error("%s: %s" % (path, error))
        result["file"] = path
        print(readable(result) if args.summary else json.dumps(result, allow_nan=False))


if __name__ == "__main__":
    main()
