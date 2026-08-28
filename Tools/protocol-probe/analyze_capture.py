"""
Offline analysis of a full_capture.py JSONL log. No hardware needed --
run this against a capture file to see what's worth investigating next.

Usage:
    python -m whoop5_decoder.analyze_capture whoop5_capture.jsonl
"""

from __future__ import annotations

import json
import sys
from collections import Counter, defaultdict


def analyze(path: str):
    counts_by_decoded_as = Counter()
    counts_by_cmd = Counter()
    unknown_examples: dict[tuple, str] = {}
    crc_failures = 0
    total = 0

    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            total += 1
            rec = json.loads(line)
            decoded_as = rec.get("decoded_as", "n/a")
            counts_by_decoded_as[decoded_as] += 1

            if rec.get("frame_parsed"):
                if not rec.get("header_crc_ok", True) or not rec.get("inner_crc_ok", True):
                    crc_failures += 1
                key = (rec.get("type"), rec.get("cmd"), rec.get("b3"))
                counts_by_cmd[key] += 1
                if decoded_as == "unknown" and key not in unknown_examples:
                    unknown_examples[key] = rec.get("raw_hex", "")

    print(f"Total events: {total}")
    print(f"CRC failures (frame parsed but a checksum didn't match -- treat these as noise/resync, not data): {crc_failures}\n")

    print("By decode outcome:")
    for k, v in counts_by_decoded_as.most_common():
        print(f"  {k:20s} {v}")

    print("\nUnknown (type, cmd, b3) combinations worth investigating, with one example frame each:")
    print("(the more often one of these repeats, especially correlated with something you")
    print(" did at a known time, the better a candidate it is to map next)\n")
    for key, example in sorted(unknown_examples.items(), key=lambda kv: -counts_by_cmd[kv[0]]):
        t, cmd, b3 = key
        n = counts_by_cmd[key]
        print(f"  type=0x{t:02x} cmd=0x{cmd:02x} b3=0x{b3:02x}  seen {n}x  e.g. {example}")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print("Usage: python -m whoop5_decoder.analyze_capture <capture.jsonl>", file=sys.stderr)
        sys.exit(1)
    analyze(sys.argv[1])
