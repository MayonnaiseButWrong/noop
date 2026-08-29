"""
WHOOP 5.0 / MG message catalogue.

Only decodes what is *publicly documented* by the NOOP project and its
sources (goose, dofek, judes.club). Fields NOT listed here are unknown --
`decode_puffin_payload` returns an UnknownMessage with the raw bytes rather
than guessing, so you don't get silently wrong output.

BLE GATT layout (from NOOP docs):
    0x2A37              standard Heart Rate Measurement char (strap -> app,
                         no bonding required)
    fd4b0002            app -> strap, write 0xAA-framed commands
    fd4b0003/4/5/7      strap -> app, notify 0xAA-framed responses/data/console
"""

from __future__ import annotations

import struct
from dataclasses import dataclass, field as dc_field
from typing import Optional

from .framing import InnerMessage

# --- Known command opcodes (inner `cmd` byte), from Asherlc/dofek + goose ---
CMD_START_DEVICE_CONFIG_KEY_EXCHANGE = 0x73
CMD_SET_FF_VALUE = 0x78          # SET_CONFIG -- one feature-flag write
CMD_GET_HELLO = 0x01              # b3 = 0x01
CMD_GET_DATA_RANGE = 0x02         # b3 = 0x00
CMD_SEND_HISTORICAL_DATA = 0x03   # b3 = 0x00

COMMAND_NAMES = {
    CMD_START_DEVICE_CONFIG_KEY_EXCHANGE: "START_DEVICE_CONFIG_KEY_EXCHANGE",
    CMD_SET_FF_VALUE: "SET_FF_VALUE (SET_CONFIG)",
    CMD_GET_HELLO: "GET_HELLO",
    CMD_GET_DATA_RANGE: "GET_DATA_RANGE",
    CMD_SEND_HISTORICAL_DATA: "SEND_HISTORICAL_DATA",
}

# Inner envelope type byte seen for the puffin command/response wrapper.
PUFFIN_ENVELOPE_TYPE = 0x23

# Historical/streamed record type byte (first byte of payload on the data
# channels), per NOOP's WHOOP5_DEEP_DATA.md -- the "R22" deep biometric
# packet, gated behind the enable_r22_packets feature flag.
RECORD_TYPE_DEEP_BIOMETRIC = 0x2F


@dataclass
class FeatureFlagWrite:
    """A decoded SET_FF_VALUE (cmd 0x78) command body."""
    name: str
    value_char: str
    raw: bytes

    @classmethod
    def decode(cls, payload: bytes) -> "FeatureFlagWrite":
        # 40-byte body: b3(1, already stripped by caller) is separate;
        # payload here = 32-byte ASCII NUL-padded name + 1 value byte + 7 zero pad
        if len(payload) < 33:
            raise ValueError(f"SET_FF_VALUE payload too short: {len(payload)}")
        name_raw = payload[:32]
        name = name_raw.split(b"\x00", 1)[0].decode("ascii", errors="replace")
        value_char = chr(payload[32]) if payload[32] else ""
        return cls(name=name, value_char=value_char, raw=payload)


@dataclass
class DeepBiometricRecord:
    """
    Partial decode of a type-0x2F record.

    Only the two fields the community has actually confirmed are decoded:
      - heart_rate_bpm at payload byte 14 (uint8)
      - accel x/y/z as little-endian float32 at bytes 37/41/45

    Everything else in the record is preserved in `raw` and in `unknown_span`
    so you can diff/annotate it yourself as more of the format gets mapped --
    this is explicitly still an open reverse-engineering question upstream
    (see NOOP issue #174), so treat bytes outside these two fields as opaque.
    """
    heart_rate_bpm: Optional[int]
    accel_x: Optional[float]
    accel_y: Optional[float]
    accel_z: Optional[float]
    raw: bytes

    @classmethod
    def decode(cls, payload: bytes) -> "DeepBiometricRecord":
        hr = payload[14] if len(payload) > 14 else None
        ax = ay = az = None
        if len(payload) >= 49:
            ax, ay, az = struct.unpack_from("<fff", payload, 37)
        return cls(heart_rate_bpm=hr, accel_x=ax, accel_y=ay, accel_z=az, raw=payload)


@dataclass
class UnknownMessage:
    envelope_type: int
    cmd: int
    b3: int
    raw_payload: bytes


DecodedPuffin = object  # FeatureFlagWrite | DeepBiometricRecord | UnknownMessage


def decode_puffin_payload(inner: InnerMessage) -> DecodedPuffin:
    """Dispatch an already-frame-parsed InnerMessage to a field decoder."""
    if inner.type != PUFFIN_ENVELOPE_TYPE:
        return UnknownMessage(inner.type, inner.cmd, inner.b3, inner.payload)

    if inner.cmd == CMD_SET_FF_VALUE:
        try:
            return FeatureFlagWrite.decode(inner.payload)
        except ValueError:
            pass

    if inner.payload and inner.payload[0] == RECORD_TYPE_DEEP_BIOMETRIC:
        return DeepBiometricRecord.decode(inner.payload[1:])

    return UnknownMessage(inner.type, inner.cmd, inner.b3, inner.payload)


# --- Standard BLE Heart Rate Measurement (0x2A37) -- this part is fully
# standardized by the Bluetooth SIG, not WHOOP-specific, and needs no
# reverse engineering. ---

@dataclass
class HeartRateMeasurement:
    bpm: int
    sensor_contact_supported: bool
    sensor_contact_detected: bool
    energy_expended_kj: Optional[int]
    rr_intervals_s: list

    @classmethod
    def decode(cls, data: bytes) -> "HeartRateMeasurement":
        if not data:
            raise ValueError("empty HR measurement")
        flags = data[0]
        hr_16bit = bool(flags & 0x01)
        contact_supported = bool(flags & 0x04)
        contact_detected = bool(flags & 0x02)
        energy_present = bool(flags & 0x08)
        rr_present = bool(flags & 0x10)

        idx = 1
        if hr_16bit:
            bpm = struct.unpack_from("<H", data, idx)[0]
            idx += 2
        else:
            bpm = data[idx]
            idx += 1

        energy = None
        if energy_present:
            energy = struct.unpack_from("<H", data, idx)[0]
            idx += 2

        rr_intervals = []
        if rr_present:
            while idx + 2 <= len(data):
                raw_rr = struct.unpack_from("<H", data, idx)[0]
                rr_intervals.append(raw_rr / 1024.0)  # spec: 1/1024 s units
                idx += 2

        return cls(bpm=bpm, sensor_contact_supported=contact_supported,
                    sensor_contact_detected=contact_detected,
                    energy_expended_kj=energy, rr_intervals_s=rr_intervals)
