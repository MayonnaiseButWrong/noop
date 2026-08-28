"""
Full GATT enumeration for a WHOOP 5.0 / MG strap.

Purpose: dump every service and characteristic the strap actually exposes,
not just the fd4b0001-.../0x2A37 ones already documented by NOOP/goose/dofek.
Firmware revisions occasionally add/move characteristics, and there could be
services nobody's publicly written up (e.g. battery, device info, or
something undocumented) that are worth knowing about before you decide
what's worth subscribing to and logging.

This is read-only reconnaissance -- it doesn't write anything to the strap,
just lists what's there and what each characteristic's properties are
(read/write/notify/indicate), which tells you where to point full_capture.py.

Usage:
    pip install bleak
    python -m whoop5_decoder.gatt_dump                  # scan + connect
    python -m whoop5_decoder.gatt_dump AA:BB:CC:DD:EE:FF # connect directly
"""

from __future__ import annotations

import asyncio
import sys
from typing import Optional

try:
    from bleak import BleakClient, BleakScanner
except ImportError:  # pragma: no cover
    BleakClient = None
    BleakScanner = None


def _props_str(char) -> str:
    return ",".join(sorted(char.properties))


async def scan_for_strap(timeout: float = 8.0) -> Optional[str]:
    print(f"Scanning for {timeout}s ... put the strap in range (pairing mode if you want the bonded services too).")
    devices = await BleakScanner.discover(timeout=timeout)
    for d in devices:
        name = (d.name or "").lower()
        if "whoop" in name:
            print(f"Found: {d.name}  {d.address}")
            return d.address
    print("No WHOOP-named device found in scan results. Pass an address explicitly.")
    return None


async def dump(address: Optional[str] = None):
    if BleakClient is None:
        print("bleak is not installed. Run: pip install bleak", file=sys.stderr)
        return

    if address is None:
        address = await scan_for_strap()
        if address is None:
            return

    async with BleakClient(address) as client:
        print(f"\nConnected to {address}\n")
        services = client.services if hasattr(client, "services") else await client.get_services()

        for service in services:
            print(f"Service {service.uuid}  ({service.description or 'no description'})")
            for char in service.characteristics:
                props = _props_str(char)
                print(f"  Characteristic {char.uuid}  props=[{props}]  handle={char.handle}")
                for descriptor in char.descriptors:
                    print(f"    Descriptor {descriptor.uuid}  handle={descriptor.handle}")

                # Opportunistically read anything readable without a bond --
                # bonded/encrypted reads will just error here, which is fine,
                # that tells you it needs the bonding step from BLEManager/
                # the fd4b0002 flow before it'll yield anything.
                if "read" in char.properties:
                    try:
                        value = await client.read_gatt_char(char.uuid)
                        print(f"    -> read {len(value)} bytes: {value.hex()}")
                    except Exception as e:
                        print(f"    -> read failed: {e}")
            print()

        print("Done. Anything with 'notify' or 'indicate' in props is a candidate")
        print("for full_capture.py's subscribe-everything pass.")


if __name__ == "__main__":
    addr = sys.argv[1] if len(sys.argv) > 1 else None
    asyncio.run(dump(addr))
