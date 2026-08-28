"""
Offline self-test: builds frames and parses them back, and decodes a
synthetic SET_FF_VALUE command and a standard HR measurement. Doesn't need
a strap -- run with:  python -m whoop5_decoder.test_framing
"""

from .framing import build_command_frame, parse_frame, iter_frames
from .messages import (
    decode_puffin_payload, FeatureFlagWrite, HeartRateMeasurement,
    CMD_SET_FF_VALUE, PUFFIN_ENVELOPE_TYPE,
)


def test_roundtrip_get_hello():
    frame_bytes = build_command_frame(
        msg_type=PUFFIN_ENVELOPE_TYPE, seq=1, cmd=0x01, b3=0x01, payload=b""
    )
    parsed = parse_frame(frame_bytes)
    assert parsed.header_crc_ok
    assert parsed.inner.crc32_ok
    assert parsed.inner.cmd == 0x01
    print("GET_HELLO round-trip OK:", frame_bytes.hex())


def test_set_ff_value_decode():
    name = b"enable_r22_packets" + b"\x00" * (32 - len(b"enable_r22_packets"))
    payload = name + b"1" + b"\x00" * 7
    frame_bytes = build_command_frame(
        msg_type=PUFFIN_ENVELOPE_TYPE, seq=5, cmd=CMD_SET_FF_VALUE, b3=0x01,
        payload=payload,
    )
    parsed = parse_frame(frame_bytes)
    decoded = decode_puffin_payload(parsed.inner)
    assert isinstance(decoded, FeatureFlagWrite)
    assert decoded.name == "enable_r22_packets"
    assert decoded.value_char == "1"
    print("SET_FF_VALUE decode OK:", decoded)


def test_streaming_reassembly():
    f1 = build_command_frame(PUFFIN_ENVELOPE_TYPE, 1, 0x01, 0x01, b"")
    f2 = build_command_frame(PUFFIN_ENVELOPE_TYPE, 2, 0x02, 0x00, b"\x00")
    combined = f1 + f2  # simulate two frames arriving back-to-back
    buf = bytearray(combined)
    seqs = [f.inner.seq for f in iter_frames(buf)]
    assert seqs == [1, 2], seqs
    assert len(buf) == 0
    print("Streaming multi-frame reassembly OK:", seqs)


def test_standard_hr_decode():
    # flags=0x10 (RR present, 8-bit HR, no contact bits, no energy), bpm=62,
    # one RR interval of 1000/1024 s
    raw = bytes([0x10, 62]) + (1000).to_bytes(2, "little")
    hr = HeartRateMeasurement.decode(raw)
    assert hr.bpm == 62
    assert abs(hr.rr_intervals_s[0] - (1000 / 1024)) < 1e-6
    print("Standard HR decode OK:", hr)


if __name__ == "__main__":
    test_roundtrip_get_hello()
    test_set_ff_value_decode()
    test_streaming_reassembly()
    test_standard_hr_decode()
    print("\nAll offline tests passed.")
