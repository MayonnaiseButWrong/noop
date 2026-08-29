"""
WHOOP 5.0 / MG ("puffin") BLE frame codec.

Ported from the publicly documented protocol used by the NOOP interoperability
project (github.com/NoopApp/noop) and its cited sources (b-nnett/goose,
Asherlc/dofek, judes.club's WHOOP5 writeup). This only implements the
*framing* layer -- getting bytes off the wire into (type, seq, cmd, b3,
payload) tuples with integrity verified. Field-level meaning of each payload
lives in messages.py, and only covers what's been publicly reverse engineered.

Outer frame:
    0xAA | ver(1) | declLen(2, LE) | field(2, LE, usually 0x0100) | crc16(2, LE)
    -- crc16 is CRC16-MODBUS over the preceding 6 header bytes --
    then declLen bytes of "inner" payload:
        type(1) | seq(1) | cmd(1) | b3(1) | payload(...) | crc32(4, LE)
    -- crc32 is CRC32 (zlib/standard) over [type..payload], i.e. inner minus
       its own trailing 4 crc bytes --

This matches what NOOP calls Framing.puffinCommandFrame.
"""

from __future__ import annotations

import struct
import zlib
from dataclasses import dataclass
from typing import Optional

OUTER_MAGIC = 0xAA
HEADER_LEN = 7          # magic, ver, declLen(2), field(2), crc16(2) minus magic... see below
INNER_MIN_LEN = 4        # type, seq, cmd, b3
CRC_LEN = 4               # trailing crc32


class FrameError(ValueError):
    pass


def crc16_modbus(data: bytes) -> int:
    """CRC16-MODBUS: poly 0xA001 (reflected 0x8005), init 0xFFFF."""
    crc = 0xFFFF
    for b in data:
        crc ^= b
        for _ in range(8):
            if crc & 1:
                crc = (crc >> 1) ^ 0xA001
            else:
                crc >>= 1
    return crc & 0xFFFF


def crc32_std(data: bytes) -> int:
    """Standard zlib CRC-32 over the inner message (type..payload)."""
    return zlib.crc32(data) & 0xFFFFFFFF


@dataclass
class InnerMessage:
    type: int          # e.g. 0x23 for a puffin command/response envelope
    seq: int
    cmd: int
    b3: int             # 0x01 for GET_HELLO/SET_CONFIG, 0x00 for GET_DATA_RANGE/SEND_HISTORICAL
    payload: bytes
    crc32_ok: bool

    def raw_inner(self) -> bytes:
        return bytes([self.type, self.seq, self.cmd, self.b3]) + self.payload


@dataclass
class OuterFrame:
    version: int
    field: int
    header_crc_ok: bool
    inner: InnerMessage
    raw: bytes


def build_command_frame(msg_type: int, seq: int, cmd: int, b3: int,
                         payload: bytes = b"", field: int = 0x0100,
                         version: int = 0x01) -> bytes:
    """Build an outbound 0xAA-framed command, matching puffinCommandFrame."""
    inner = bytes([msg_type, seq, cmd, b3]) + payload
    inner_crc = struct.pack("<I", crc32_std(inner))
    inner_full = inner + inner_crc

    decl_len = len(inner_full)
    header_body = struct.pack("<BH H", version, decl_len, field) if False else (
        bytes([version]) + struct.pack("<H", decl_len) + struct.pack("<H", field)
    )
    header_crc = struct.pack("<H", crc16_modbus(header_body))

    return bytes([OUTER_MAGIC]) + header_body + header_crc + inner_full


def parse_frame(data: bytes) -> OuterFrame:
    """Parse one complete 0xAA-framed message (outer header + inner + crc32)."""
    if len(data) < 9:
        raise FrameError(f"frame too short: {len(data)} bytes")
    if data[0] != OUTER_MAGIC:
        raise FrameError(f"bad magic byte: 0x{data[0]:02x} (expected 0xAA)")

    version = data[1]
    decl_len = struct.unpack_from("<H", data, 2)[0]
    field = struct.unpack_from("<H", data, 4)[0]
    header_crc_rx = struct.unpack_from("<H", data, 6)[0]

    header_body = data[1:6]
    header_crc_ok = crc16_modbus(header_body) == header_crc_rx

    inner_start = 8
    inner_end = inner_start + decl_len
    if len(data) < inner_end:
        raise FrameError(
            f"declared inner length {decl_len} exceeds available bytes "
            f"({len(data) - inner_start})"
        )

    inner_full = data[inner_start:inner_end]
    if len(inner_full) < INNER_MIN_LEN + CRC_LEN:
        raise FrameError("inner payload shorter than type+seq+cmd+b3+crc32")

    inner_body = inner_full[:-CRC_LEN]
    crc_rx = struct.unpack_from("<I", inner_full, len(inner_full) - CRC_LEN)[0]
    crc32_ok = crc32_std(inner_body) == crc_rx

    msg_type, seq, cmd, b3 = inner_body[0], inner_body[1], inner_body[2], inner_body[3]
    payload = inner_body[4:]

    inner = InnerMessage(type=msg_type, seq=seq, cmd=cmd, b3=b3,
                          payload=payload, crc32_ok=crc32_ok)
    return OuterFrame(version=version, field=field, header_crc_ok=header_crc_ok,
                       inner=inner, raw=data[:inner_end])


def iter_frames(buf: bytearray):
    """
    Generator that pulls as many complete frames as possible out of a
    streaming byte buffer (BLE notifications can arrive split across
    multiple packets/MTUs), yielding OuterFrame and trimming consumed
    bytes from `buf` in place. Leaves a trailing partial frame in `buf`.
    """
    while True:
        # find magic byte
        try:
            start = buf.index(OUTER_MAGIC)
        except ValueError:
            buf.clear()
            return
        if start > 0:
            del buf[:start]

        if len(buf) < 8:
            return  # not enough for header yet

        decl_len = struct.unpack_from("<H", buf, 2)[0]
        total_len = 8 + decl_len
        if len(buf) < total_len:
            return  # wait for more bytes

        chunk = bytes(buf[:total_len])
        del buf[:total_len]
        try:
            yield parse_frame(chunk)
        except FrameError:
            # resync: drop the magic byte we just consumed and keep scanning
            continue
