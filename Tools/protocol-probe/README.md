# whoop5_decoder

A WHOOP 5.0 / MG BLE message decoder, built on the "puffin" protocol as
documented by the NOOP interoperability project (github.com/NoopApp/noop)
and the sources it credits (b-nnett/goose, Asherlc/dofek, judes.club).

## What this actually decodes

**Fully, reliably:**
- The outer frame: `0xAA | ver | declLen | field | crc16-modbus` header
- The inner envelope: `type | seq | cmd | b3 | payload | crc32`
- Standard Bluetooth SIG Heart Rate Measurement (`0x2A37`) — this part isn't
  WHOOP-specific, it's the standard GATT HR profile
- `SET_FF_VALUE` (cmd `0x78`) feature-flag command bodies (32-byte name +
  value char + padding)

**Partially, and only where confirmed:**
- Type-`0x2F` "deep biometric" records: just `heart_rate_bpm` (byte 14) and
  `accel_x/y/z` (float32 @ bytes 37/41/45). The rest of that record's layout
  is still an open question upstream (see NOOP issue #174) — nobody has
  published a full field map for it yet.

**Not decoded — genuinely unknown publicly:**
- Sleep stage records, recovery/strain packets, SpO2/respiratory data,
  skin temperature chunk layout, and most of the historical-sync record
  types. WHOOP computes recovery/strain/sleep scores server-side; no public
  project has reproduced the scoring itself, only some raw sensor inputs.

Anything that doesn't match a known `cmd`/record type comes back as an
`UnknownMessage` with the raw bytes intact, rather than a guessed decode —
so you can log real packets off your own strap and extend `messages.py`
as you map more of them (the CRC checks tell you immediately whether a
candidate decode is even looking at a real frame boundary).

## Files

- `framing.py` — CRC16-Modbus / CRC32, frame build/parse, streaming
  reassembly for notifications split across multiple BLE packets
- `messages.py` — known command IDs and the field decoders above
- `client.py` — a `bleak`-based live client that connects, subscribes to
  the HR characteristic and the four `fd4b000{3,4,5,7}` data channels, and
  prints decoded messages as they arrive
- `test_framing.py` — offline round-trip tests, no hardware needed

## Usage

```bash
pip install bleak
python -m whoop5_decoder.test_framing      # sanity check, no strap needed
python -m whoop5_decoder.client            # scan + connect + stream + decode
python -m whoop5_decoder.client AA:BB:CC:DD:EE:FF   # connect to known address
```

## Known platform caveat (carried over from NOOP)

On macOS, CoreBluetooth can't complete the authenticated bond the command
channel (`fd4b0002`) needs, so *writing* commands (e.g. the feature-flag
unlock sequence) only works on Linux/Windows/mobile with a real bonded
pairing. Live HR via `0x2A37` works everywhere regardless.

## iOS (WhoopKit/) — native iPhone support

`ios/` is a Swift Package, `WhoopKit`, porting the same framing/decoding logic
to CoreBluetooth so it runs natively on iPhone (not through Python).

- `Framing.swift` / `Messages.swift` — same CRC16-Modbus/CRC32 frame codec
  and message decoders as the Python version, kept dependency-free and
  platform-pure (no `import CoreBluetooth`) so they're unit-testable without
  hardware.
- `BLEManager.swift` — a `CBCentralManager`-based client that scans, connects,
  triggers the OS pairing dialog, subscribes to live HR + the four data
  channels, and writes commands.
- `Scoring.swift` — local recovery/strain/sleep **estimates**.

### "Feature parity with the WHOOP app" — what that does and doesn't mean here

WHOOP's actual Recovery %, Strain, and Sleep Performance numbers are computed
in WHOOP's cloud from a proprietary, unpublished model. That algorithm has
never been published or reverse-engineered by anyone publicly, including
NOOP/goose — so no code, including this, reproduces WHOOP's actual scores.

What `Scoring.swift` gives you instead is a **from-scratch estimate** using
established, published sports-science formulas (each cited in the file):
- Recovery: RMSSD (HRV) vs. your own rolling baseline + resting-HR delta
- Strain: Banister's TRIMP (heart-rate-reserve-weighted training load),
  rescaled cosmetically onto a 0–21 band
- Sleep stages: a coarse actigraphy + HR classifier (motion thresholds +
  HR-relative-to-baseline), not a validated PSG-equivalent stager

These will look similar in shape to WHOOP's numbers but won't match them
exactly, and the thresholds/constants need calibrating against a few days of
your own data. That's the honest ceiling of "parity" here — the protocol
layer can be ported faithfully, the proprietary scoring model can't.

### Two hardware constraints that genuinely can't be coded around

1. **One bond at a time.** The strap only holds an encrypted BLE bond with a
   single device. If it's still bonded to the official WHOOP app, you'll see
   "Encryption is insufficient" and the command channel stays closed. Fully
   quit / disconnect the official app (or turn that phone's Bluetooth off)
   and put the strap in pairing mode (repeated firm taps until LEDs flash
   blue) before connecting with your own app.
2. **No explicit "bond" call in CoreBluetooth.** iOS triggers bonding
   automatically the first time you touch a characteristic that requires
   encryption — `BLEManager.swift` does this deliberately by reading the
   command characteristic right after service discovery. This is Apple's
   documented pairing model, not a way around it.

### Xcode setup

- Add `NSBluetoothAlwaysUsageDescription` to Info.plist.
- Enable the "Uses Bluetooth LE accessories" background mode if you want
  data collection to continue while the app is backgrounded.
- No Swift toolchain was available in the sandbox this was written in, so
  `WhoopKitTests` hasn't been compiled/run yet — do that first in Xcode
  before relying on it against real hardware. The logic mirrors the
  already-tested Python version byte-for-byte (same CRC polynomials, same
  frame layout).

## Extending it

If you capture a real packet you can't decode and want to map it:
1. Confirm `header_crc_ok` and `inner.crc32_ok` are both `True` — this tells
   you the frame boundary/parse is correct even before you know the meaning.
2. Log `inner.type`, `inner.cmd`, `inner.b3`, and `payload.hex()`.
3. Correlate against a known trigger (e.g. "I just started a workout", "this
   fired every 60s while sleeping") to narrow down field candidates.
4. Add a dataclass + decode() to `messages.py` and a branch in
   `decode_puffin_payload`, following the pattern of `DeepBiometricRecord`.
