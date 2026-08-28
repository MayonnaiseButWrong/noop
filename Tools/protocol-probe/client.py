"""
Live BLE client for a WHOOP 5.0 / MG strap, using `bleak` (cross-platform:
Linux/BlueZ, Windows, macOS -- though see the macOS caveat below).

Usage:
    python -m whoop5_decoder.client            # scan, connect, stream & decode
    python -m whoop5_decoder.client AA:BB:CC:DD:EE:FF   # connect to a known address

Requires: pip install bleak

Channel map (from NOOP docs, service family fd4b0001-...):
    0x2A37    standard Heart Rate Measurement -- notify, no bonding needed
    fd4b0002  command channel -- write with response
    fd4b0003/4/5/7  response/data/console channels -- notify

Caveat carried over from NOOP: on macOS, CoreBluetooth can't complete the
authenticated bond the command channel (fd4b0002) needs, so writing commands
(feature-flag unlock, historical data requests) only works on Linux/Windows/
mobile with a real paired bond. Live HR via 0x2A37 works everywhere.
"""

from __future__ import annotations

import asyncio
import sys
from typing import Optional

from .framing import iter_frames
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

# The fd4b0001... service's per-channel UUIDs follow the same base;
# confirm the exact suffixes against your own strap's GATT table (they can
# shift slightly by firmware rev) -- these are the ones NOOP documents.
CMD_CHAR_UUID = "fd4b0002-0000-1000-8000-00805f9b34fb"
DATA_CHAR_UUIDS = [
    "fd4b0003-0000-1000-8000-00805f9b34fb",
    "fd4b0004-0000-1000-8000-00805f9b34fb",
    "fd4b0005-0000-1000-8000-00805f9b34fb",
    "fd4b0007-0000-1000-8000-00805f9b34fb",
]

_data_buffers: dict[str, bytearray] = {}


def _handle_hr(_handle, data: bytearray):
    try:
        hr = HeartRateMeasurement.decode(bytes(data))
        print(f"[HR]  {hr.bpm} bpm  contact={hr.sensor_contact_detected}  "
              f"rr={hr.rr_intervals_s}")
    except ValueError as e:
        print(f"[HR]  decode error: {e}  raw={data.hex()}")


def _make_data_handler(channel_uuid: str):
    _data_buffers.setdefault(channel_uuid, bytearray())

    def _handler(_handle, data: bytearray):
        buf = _data_buffers[channel_uuid]
        buf.extend(data)
        for frame in iter_frames(buf):
            tag = "hdr-crc-BAD" if not frame.header_crc_ok else "hdr-crc-ok"
            inner_tag = "crc32-BAD" if not frame.inner.crc32_ok else "crc32-ok"
            decoded = decode_puffin_payload(frame.inner)

            prefix = (f"[{channel_uuid[4:8]}] type=0x{frame.inner.type:02x} "
                      f"cmd=0x{frame.inner.cmd:02x} seq={frame.inner.seq} "
                      f"b3=0x{frame.inner.b3:02x} ({tag},{inner_tag})")

            if isinstance(decoded, FeatureFlagWrite):
                print(f"{prefix} SET_FF_VALUE name={decoded.name!r} "
                      f"value={decoded.value_char!r}")
            elif isinstance(decoded, DeepBiometricRecord):
                print(f"{prefix} DEEP_BIOMETRIC hr={decoded.heart_rate_bpm} "
                      f"accel=({decoded.accel_x},{decoded.accel_y},{decoded.accel_z})")
            elif isinstance(decoded, UnknownMessage):
                print(f"{prefix} UNKNOWN payload={decoded.raw_payload.hex()}")

    return _handler


async def scan_for_strap(timeout: float = 8.0) -> Optional[str]:
    print(f"Scanning for {timeout}s ... put the strap in range.")
    devices = await BleakScanner.discover(timeout=timeout)
    for d in devices:
        name = (d.name or "").lower()
        if "whoop" in name:
            print(f"Found: {d.name}  {d.address}")
            return d.address
    print("No WHOOP-named device found. Pass an address explicitly.")
    return None


async def run(address: Optional[str] = None):
    if BleakClient is None:
        print("bleak is not installed. Run: pip install bleak", file=sys.stderr)
        return

    if address is None:
        address = await scan_for_strap()
        if address is None:
            return

    async with BleakClient(address) as client:
        print(f"Connected to {address}. Discovering services...")
        services = await client.get_services() if hasattr(client, "get_services") else client.services

        await client.start_notify(HR_MEASUREMENT_UUID, _handle_hr)
        print("Subscribed to live heart rate (0x2A37).")

        for uuid in DATA_CHAR_UUIDS:
            try:
                await client.start_notify(uuid, _make_data_handler(uuid))
                print(f"Subscribed to data channel {uuid}.")
            except Exception as e:
                print(f"Could not subscribe to {uuid}: {e}")

        print("Streaming. Ctrl-C to stop.")
        try:
            while True:
                await asyncio.sleep(1)
        except KeyboardInterrupt:
            pass


if __name__ == "__main__":
    addr = sys.argv[1] if len(sys.argv) > 1 else None
    asyncio.run(run(addr))
