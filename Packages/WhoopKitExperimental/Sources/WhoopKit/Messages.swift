//
//  Messages.swift
//  WhoopKit
//
//  Same scope note as the Python version: only decodes what's publicly
//  documented (NOOP + goose + dofek + judes.club). Unknown frames come back
//  as .unknown with raw bytes rather than a guessed decode.
//

import Foundation

public enum Command {
    public static let startDeviceConfigKeyExchange: UInt8 = 0x73
    public static let setFFValue: UInt8 = 0x78          // SET_CONFIG
    public static let getHello: UInt8 = 0x01              // b3 = 0x01
    public static let getDataRange: UInt8 = 0x02          // b3 = 0x00
    public static let sendHistoricalData: UInt8 = 0x03    // b3 = 0x00
}

public let puffinEnvelopeType: UInt8 = 0x23
public let recordTypeDeepBiometric: UInt8 = 0x2F

// The 15 feature flags NOOP sends on the opt-in "unlock deep data" path.
// Values are the ASCII characters the strap expects; see NOOP's
// Whoop5Config.swift for the golden-tested canonical list -- reproduce that
// exact list from your own capture/NOOP checkout before relying on it, this
// is deliberately left as a name-only stub so you don't ship unverified
// values against your own hardware.
public let knownFeatureFlagNames: [String] = [
    "enable_r22_packets",
    // ... remaining 14 flags: pull from your own verified capture or from
    // NOOP's Whoop5Config.swift rather than trusting a hardcoded guess here.
]

public struct FeatureFlagWrite {
    public let name: String
    public let valueChar: Character?
    public let raw: Data

    public static func decode(_ payload: Data) -> FeatureFlagWrite? {
        guard payload.count >= 33 else { return nil }
        let bytes = [UInt8](payload)
        let nameBytes = bytes[0..<32]
        let nameEnd = nameBytes.firstIndex(of: 0) ?? 32
        let name = String(bytes: nameBytes[0..<nameEnd], encoding: .ascii) ?? "<invalid>"
        let valueByte = bytes[32]
        let valueChar = valueByte != 0 ? Character(UnicodeScalar(valueByte)) : nil
        return FeatureFlagWrite(name: name, valueChar: valueChar, raw: payload)
    }
}

public struct DeepBiometricRecord {
    /// byte 14 of the record payload -- confirmed by community captures.
    public let heartRateBPM: UInt8?
    /// little-endian float32 at bytes 37/41/45 -- confirmed by community captures.
    public let accelX: Float?
    public let accelY: Float?
    public let accelZ: Float?
    public let raw: Data

    public static func decode(_ payload: Data) -> DeepBiometricRecord {
        let bytes = [UInt8](payload)
        let hr: UInt8? = bytes.count > 14 ? bytes[14] : nil

        var ax: Float?, ay: Float?, az: Float?
        if bytes.count >= 49 {
            ax = readFloatLE(bytes, at: 37)
            ay = readFloatLE(bytes, at: 41)
            az = readFloatLE(bytes, at: 45)
        }
        return DeepBiometricRecord(heartRateBPM: hr, accelX: ax, accelY: ay, accelZ: az, raw: payload)
    }

    private static func readFloatLE(_ bytes: [UInt8], at offset: Int) -> Float {
        let slice = bytes[offset..<offset + 4]
        let bits = UInt32(slice[slice.startIndex]) |
            (UInt32(slice[slice.startIndex + 1]) << 8) |
            (UInt32(slice[slice.startIndex + 2]) << 16) |
            (UInt32(slice[slice.startIndex + 3]) << 24)
        return Float(bitPattern: bits)
    }
}

public enum DecodedPuffin {
    case featureFlag(FeatureFlagWrite)
    case deepBiometric(DeepBiometricRecord)
    case unknown(type: UInt8, cmd: UInt8, b3: UInt8, payload: Data)
}

public func decodePuffinPayload(_ inner: InnerMessage) -> DecodedPuffin {
    guard inner.type == puffinEnvelopeType else {
        return .unknown(type: inner.type, cmd: inner.cmd, b3: inner.b3, payload: inner.payload)
    }
    if inner.cmd == Command.setFFValue, let ff = FeatureFlagWrite.decode(inner.payload) {
        return .featureFlag(ff)
    }
    if let first = inner.payload.first, first == recordTypeDeepBiometric {
        return .deepBiometric(DeepBiometricRecord.decode(inner.payload.dropFirst()))
    }
    return .unknown(type: inner.type, cmd: inner.cmd, b3: inner.b3, payload: inner.payload)
}

// --- Standard Bluetooth SIG Heart Rate Measurement (0x2A37) --------------
// Fully standardized, not WHOOP-specific.

public struct HeartRateMeasurement {
    public let bpm: Int
    public let sensorContactSupported: Bool
    public let sensorContactDetected: Bool
    public let energyExpendedKJ: Int?
    public let rrIntervalsSeconds: [Double]

    public static func decode(_ data: Data) -> HeartRateMeasurement? {
        guard !data.isEmpty else { return nil }
        let bytes = [UInt8](data)
        let flags = bytes[0]
        let hr16 = flags & 0x01 != 0
        let contactSupported = flags & 0x04 != 0
        let contactDetected = flags & 0x02 != 0
        let energyPresent = flags & 0x08 != 0
        let rrPresent = flags & 0x10 != 0

        var idx = 1
        let bpm: Int
        if hr16 {
            guard bytes.count >= idx + 2 else { return nil }
            bpm = Int(bytes[idx]) | (Int(bytes[idx + 1]) << 8)
            idx += 2
        } else {
            guard bytes.count > idx else { return nil }
            bpm = Int(bytes[idx])
            idx += 1
        }

        var energy: Int?
        if energyPresent {
            guard bytes.count >= idx + 2 else { return nil }
            energy = Int(bytes[idx]) | (Int(bytes[idx + 1]) << 8)
            idx += 2
        }

        var rr: [Double] = []
        if rrPresent {
            while idx + 2 <= bytes.count {
                let raw = Int(bytes[idx]) | (Int(bytes[idx + 1]) << 8)
                rr.append(Double(raw) / 1024.0)
                idx += 2
            }
        }

        return HeartRateMeasurement(bpm: bpm, sensorContactSupported: contactSupported,
                                     sensorContactDetected: contactDetected,
                                     energyExpendedKJ: energy, rrIntervalsSeconds: rr)
    }
}
