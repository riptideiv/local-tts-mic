#!/usr/bin/env python3
"""Compare each generated fragment with an exclusive virtual microphone recording."""
import argparse
import json
from pathlib import Path

import numpy as np
import soundfile as sf
from scipy.signal import correlate, resample_poly


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("report", type=Path)
    parser.add_argument("recording", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    report = json.loads(args.report.read_text())
    samples, rate = sf.read(args.recording, always_2d=True)
    comparison_rate = 4000
    captured = resample_poly(samples[:, 0], comparison_rate, rate)
    fragments = []
    previous_end = 0
    for job in report["jobs"]:
        path = Path(job["output"])
        for fragment in sorted(path.parent.glob(path.stem + "-*.wav"), key=lambda p: int(p.stem.rsplit("-", 1)[1])):
            source, source_rate = sf.read(fragment)
            source = resample_poly(source, comparison_rate, source_rate)
            product = correlate(captured, source, mode="valid", method="fft")
            sums = np.concatenate(([0.0], np.cumsum(captured ** 2)))
            energy = sums[len(source):] - sums[:-len(source)]
            source_energy = float(source @ source)
            similarity = product / np.sqrt(np.maximum(energy * source_energy, 1e-20))
            # Deterministic TTS can produce identical fragments in later jobs.
            # Search forward so an earlier repeat cannot satisfy a later job.
            similarity[:max(0, previous_end - 2)] = -1
            index = int(np.argmax(similarity))
            gain = float(product[index] / source_energy)
            score = float(similarity[index])
            ordered = index >= previous_end - 2
            previous_end = index + len(source)
            fragments.append(dict(file=fragment.name, start=index / comparison_rate, correlation=score, gain=gain,
                                  passed=score > 0.9 and 0.65 < gain < 0.95 and ordered))
    result = dict(passed=bool(fragments) and report["passed"] and all(f["passed"] for f in fragments),
                  fragments=fragments, channelRMS=np.sqrt(np.mean(samples ** 2, axis=0)).tolist())
    args.output.write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result, indent=2))
    raise SystemExit(0 if result["passed"] else 1)


if __name__ == "__main__":
    main()
