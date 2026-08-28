"""
Byte-diff helper for mapping unknown WHOOP 5 record types from real
captures. This is the tool for the step after analyze_capture.py flags a
repeating unknown (type, cmd, b3) -- pull several example payloads of that
same kind and see, byte by byte, what's constant (framing/padding) vs what
varies (candidate data fields).

Two ways to feed it:

1. Point it at a capture JSONL + a specific (type, cmd, b3) key, and it
   pulls every matching payload automatically:

       python -m whoop5_decoder.diff_frames sleep.jsonl --type 0x23 --cmd 0x99 --b3 0x00

2. Or paste hex strings directly (e.g. copied out of chat/a notebook):

       python -m whoop5_decoder.diff_frames --hex \\
           aa010b000001da242302990011223364f661f7 \\
           aa010b000001da2423039900112233c1253d3c \\
           aa010b000001da242304990011223379153821

Output marks each payload-byte column as CONST (identical across every
sample -- likely framing/padding/a fixed opcode) or VARY (changes --
candidate for a real field), and for VARY columns shows the raw
observed values so you can eyeball whether it looks like a counter
(steadily incrementing), a timestamp, a sensor reading, or noise.
"""

from __future__ import annotations

import argparse
import json
import sys
from typing import List, Optional

from .framing import parse_frame, FrameError


def collect_from_jsonl(path: str, msg_type: Optional[int], cmd: Optional[int],
                        b3: Optional[int]) -> List[bytes]:
    payloads = []
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            rec = json.loads(line)
            if not rec.get("frame_parsed"):
                continue
            if msg_type is not None and rec.get("type") != msg_type:
                continue
            if cmd is not None and rec.get("cmd") != cmd:
                continue
            if b3 is not None and rec.get("b3") != b3:
                continue
            raw_hex = rec.get("raw_hex")
            if not raw_hex:
                continue
            try:
                frame = parse_frame(bytes.fromhex(raw_hex))
            except FrameError:
                continue
            payloads.append(frame.inner.payload)
    return payloads


def collect_from_hex(hex_frames: List[str]) -> List[bytes]:
    payloads = []
    for h in hex_frames:
        try:
            frame = parse_frame(bytes.fromhex(h.strip()))
            payloads.append(frame.inner.payload)
        except FrameError as e:
            print(f"Skipping unparseable frame ({e}): {h}", file=sys.stderr)
    return payloads


def diff(payloads: List[bytes]):
    if len(payloads) < 2:
        print(f"Need at least 2 samples to diff, got {len(payloads)}.", file=sys.stderr)
        return

    lengths = {len(p) for p in payloads}
    if len(lengths) > 1:
        print(f"Warning: samples have different lengths {sorted(lengths)} -- "
              f"this itself might be meaningful (e.g. a variable-length record), "
              f"comparing up to the shortest common length.\n")
    min_len = min(lengths)

    print(f"{len(payloads)} samples, comparing {min_len} bytes each.\n")
    print("offset  status  values")
    print("------  ------  ------")

    for i in range(min_len):
        col = [p[i] for p in payloads]
        if len(set(col)) == 1:
            status = "CONST"
            values_str = f"0x{col[0]:02x} (all samples)"
        else:
            status = "VARY "
            hex_vals = [f"0x{v:02x}" for v in col]
            values_str = " ".join(hex_vals)
            # flag if it looks monotonically increasing -- classic counter/seq/timestamp tell
            if all(col[j] <= col[j + 1] for j in range(len(col) - 1)) and len(set(col)) > 1:
                values_str += "   (monotonically non-decreasing -- possible counter/seq/timestamp)"
        print(f"{i:6d}  {status}  {values_str}")

    print("\nTip: a run of VARY bytes that, read as a little-endian uint16/uint32")
    print("or float32, tracks something you did during capture (HR, motion,")
    print("elapsed time) is your strongest signal. Constant runs are probably")
    print("framing, opcodes, or unused/reserved padding.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__,
                                      formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("jsonl", nargs="?", help="capture JSONL file (omit if using --hex)")
    parser.add_argument("--type", type=lambda x: int(x, 0), default=None)
    parser.add_argument("--cmd", type=lambda x: int(x, 0), default=None)
    parser.add_argument("--b3", type=lambda x: int(x, 0), default=None)
    parser.add_argument("--hex", nargs="+", default=None,
                         help="one or more raw frame hex strings instead of a JSONL file")
    args = parser.parse_args()

    if args.hex:
        payloads = collect_from_hex(args.hex)
    elif args.jsonl:
        payloads = collect_from_jsonl(args.jsonl, args.type, args.cmd, args.b3)
    else:
        parser.error("provide either a JSONL file (with --type/--cmd/--b3) or --hex frames")

    diff(payloads)
