"""
Full-capture logger for a WHOOP 5.0 / MG strap.

Subscribes to notifications on EVERY characteristic that supports notify or
indicate (found via gatt_dump.py's enumeration, not just the known fd4b000x
channels), decodes what messages.py already knows how to decode, and writes
every event -- decoded or not -- to a timestamped JSONL file.

This is the tool for the actual "decode everything" work: run it while you
do something specific (start a workout, fall asleep, take it off, tap it
for a stopwatch split, etc.), note the wall-clock time you did that thing,
then grep the JSONL for frames near that timestamp. That's how the known
fields (HR@byte14, accel@37/41/45 in DeepBiometricRecord) were almost
certainly found originally, and it's the only way to extend the decoder
with real confidence instead of guessing.

Output format (one JSON object per line):
    {
      "t": "2026-08-28T10:15:32.482911",
      "channel": "fd4b0003-...",
      "raw_hex": "aa0108000001da60230101012cb41dfc",
      "frame_parsed": true,
      "header_crc_ok": true,
      "inner_crc_ok": true,
      "type": 35, "seq": 1, "cmd": 1, "b3": 1,
      "decoded_as": "unknown",       // or "feature_flag" / "deep_biometric" / "standard_hr"
      "decoded_fields": {...}         // present only when decoded_as != "unknown"
    }

Usage:
    pip install bleak
    python -m whoop5_decoder.full_capture                    # scan + connect
    python -m whoop5_decoder.full_capture AA:BB:CC:DD:EE:FF   # direct
    python -m whoop5_decoder.full_capture --out my_session.jsonl
"""

from __future__ import annotations

import argparse
import asyncio
import json
import sys
from datetime import datetime, timezone
from typing import Optional

from .framing import iter_frames, FrameError
from .messages import (
    decode_puffin_payload,
    HeartRateMeasurement,
    FeatureFlagWrite,
    DeepBiometricRecord,
    UnknownMessage,
)

try:
    from bleak import BleakClient, BleakScanner
except ImportError:  # pragma: no cover
    BleakClient = None
    BleakScanner = None

HR_MEASUREMENT_UUID = "00002a37-0000-1000-8000-00805f9b34fb"


class Capture:
    def __init__(self, out_path: str):
        self._f = open(out_path, "a", buffering=1)  # line-buffered: flush per event
        self._buffers: dict[str, bytearray] = {}

    def close(self):
        self._f.close()

    def _write(self, record: dict):
        record["t"] = datetime.now(timezone.utc).isoformat()
        self._f.write(json.dumps(record) + "\n")

    def on_notify(self, channel_uuid: str, data: bytearray):
        raw = bytes(data)

        if channel_uuid.lower().startswith(HR_MEASUREMENT_UUID[:8]):
            hr = HeartRateMeasurement.decode(raw)
            self._write({
                "channel": channel_uuid,
                "raw_hex": raw.hex(),
                "decoded_as": "standard_hr" if hr else "hr_decode_failed",
                "decoded_fields": (vars(hr) if hr else None),
            })
            return

        # Everything else: try to frame-parse it as a puffin message. Log
        # raw bytes regardless of whether parsing succeeds -- an unparseable
        # chunk is still evidence (e.g. it might be a fragment, or a
        # completely different format on a channel nobody's documented).
        buf = self._buffers.setdefault(channel_uuid, bytearray())
        buf.extend(raw)

        parsed_any = False
        for frame in iter_frames(buf):
            parsed_any = True
            decoded = decode_puffin_payload(frame.inner)
            decoded_as = "unknown"
            decoded_fields = None
            if isinstance(decoded, FeatureFlagWrite):
                decoded_as = "feature_flag"
                decoded_fields = {"name": decoded.name, "value": decoded.value_char}
            elif isinstance(decoded, DeepBiometricRecord):
                decoded_as = "deep_biometric"
                decoded_fields = {
                    "heart_rate_bpm": decoded.heart_rate_bpm,
                    "accel_x": decoded.accel_x, "accel_y": decoded.accel_y, "accel_z": decoded.accel_z,
                }

            self._write({
                "channel": channel_uuid,
                "raw_hex": frame.raw.hex(),
                "frame_parsed": True,
                "header_crc_ok": frame.header_crc_ok,
                "inner_crc_ok": frame.inner.crc32_ok,
                "type": frame.inner.type, "seq": frame.inner.seq,
                "cmd": frame.inner.cmd, "b3": frame.inner.b3,
                "decoded_as": decoded_as,
                "decoded_fields": decoded_fields,
            })

        if not parsed_any and len(buf) > 512:
            # Buffer's grown large without ever finding a complete/valid
            # frame -- this channel probably isn't puffin-framed at all.
            # Log the raw chunk as-is and drop the buffer so it doesn't grow
            # unbounded, rather than silently discarding real data.
            self._write({
                "channel": channel_uuid,
                "raw_hex": bytes(buf).hex(),
                "frame_parsed": False,
                "note": "no valid 0xAA frame found in >512 bytes; channel may not be puffin-framed",
            })
            buf.clear()


async def scan_for_strap(timeout: float = 8.0) -> Optional[str]:
    print(f"Scanning for {timeout}s ... put the strap in range.")
    devices = await BleakScanner.discover(timeout=timeout)
    for d in devices:
        if "whoop" in (d.name or "").lower():
            print(f"Found: {d.name}  {d.address}")
            return d.address
    print("No WHOOP-named device found. Pass an address explicitly.")
    return None


async def run(address: Optional[str], out_path: str):
    if BleakClient is None:
        print("bleak is not installed. Run: pip install bleak", file=sys.stderr)
        return

    if address is None:
        address = await scan_for_strap()
        if address is None:
            return

    capture = Capture(out_path)
    print(f"Logging every event to {out_path}")

    try:
        async with BleakClient(address) as client:
            services = client.services if hasattr(client, "services") else await client.get_services()

            subscribed = []
            for service in services:
                for char in service.characteristics:
                    if "notify" in char.properties or "indicate" in char.properties:
                        try:
                            def _handler(_h, data, _uuid=char.uuid):
                                capture.on_notify(_uuid, data)
                            await client.start_notify(char.uuid, _handler)
                            subscribed.append(char.uuid)
                        except Exception as e:
                            print(f"Could not subscribe to {char.uuid}: {e}")

            print(f"Subscribed to {len(subscribed)} notifying characteristics:")
            for u in subscribed:
                print(f"  {u}")
            print("\nGo do the thing you want to capture (workout, sleep, tap the band, etc).")
            print("Note the wall-clock time so you can correlate later. Ctrl-C to stop.\n")

            while True:
                await asyncio.sleep(1)
    except KeyboardInterrupt:
        pass
    finally:
        capture.close()
        print(f"\nCapture saved to {out_path}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Full-capture logger for a WHOOP 5.0/MG strap")
    parser.add_argument("address", nargs="?", default=None)
    parser.add_argument("--out", default="whoop5_capture.jsonl")
    args = parser.parse_args()
    asyncio.run(run(args.address, args.out))
