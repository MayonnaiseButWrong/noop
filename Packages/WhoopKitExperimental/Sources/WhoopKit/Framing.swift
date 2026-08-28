//
//  Framing.swift
//  WhoopKit
//
//  Swift port of the Python framing.py codec for the WHOOP 5.0 / MG
//  "puffin" protocol. Platform-pure (no CoreBluetooth import) so it's
//  testable without hardware, matching NOOP's own architecture.
//
//  Outer frame:
//      0xAA | ver(1) | declLen(2 LE) | field(2 LE) | crc16(2 LE, CRC16-MODBUS
//      of the preceding 5 bytes)
//      then declLen bytes of inner: type | seq | cmd | b3 | payload | crc32(4 LE)
//

import Foundation

public enum FrameError: Error, CustomStringConvertible {
    case tooShort(Int)
    case badMagic(UInt8)
    case declaredLengthExceedsBuffer(declared: Int, available: Int)
    case innerTooShort

    public var description: String {
        switch self {
        case .tooShort(let n): return "frame too short: \(n) bytes"
        case .badMagic(let b): return String(format: "bad magic byte: 0x%02x (expected 0xAA)", b)
        case .declaredLengthExceedsBuffer(let d, let a):
            return "declared inner length \(d) exceeds available bytes (\(a))"
        case .innerTooShort: return "inner payload shorter than type+seq+cmd+b3+crc32"
        }
    }
}

public enum Framing {
    public static let outerMagic: UInt8 = 0xAA

    /// CRC16-MODBUS: poly 0xA001 (reflected 0x8005), init 0xFFFF.
    public static func crc16Modbus<D: Sequence>(_ data: D) -> UInt16 where D.Element == UInt8 {
        var crc: UInt16 = 0xFFFF
        for b in data {
            crc ^= UInt16(b)
            for _ in 0..<8 {
                if crc & 1 != 0 {
                    crc = (crc >> 1) ^ 0xA001
                } else {
                    crc >>= 1
                }
            }
        }
        return crc
    }

    /// Standard CRC-32 (same polynomial zlib/gzip use), computed without
    /// linking zlib so this stays portable across all Apple platforms.
    private static let crc32Table: [UInt32] = {
        (0...255).map { i -> UInt32 in
            var c = UInt32(i)
            for _ in 0..<8 {
                c = (c & 1 != 0) ? (0xEDB88320 ^ (c >> 1)) : (c >> 1)
            }
            return c
        }
    }()

    public static func crc32Std<D: Sequence>(_ data: D) -> UInt32 where D.Element == UInt8 {
        var crc: UInt32 = 0xFFFFFFFF
        for b in data {
            let idx = Int((crc ^ UInt32(b)) & 0xFF)
            crc = crc32Table[idx] ^ (crc >> 8)
        }
        return crc ^ 0xFFFFFFFF
    }
}

public struct InnerMessage: Equatable {
    public let type: UInt8
    public let seq: UInt8
    public let cmd: UInt8
    public let b3: UInt8
    public let payload: Data
    public let crc32OK: Bool

    public init(type: UInt8, seq: UInt8, cmd: UInt8, b3: UInt8, payload: Data, crc32OK: Bool) {
        self.type = type; self.seq = seq; self.cmd = cmd; self.b3 = b3
        self.payload = payload; self.crc32OK = crc32OK
    }
}

public struct OuterFrame {
    public let version: UInt8
    public let field: UInt16
    public let headerCRCOK: Bool
    public let inner: InnerMessage
    public let raw: Data
}

/// Build an outbound 0xAA-framed command (matches puffinCommandFrame).
public func buildCommandFrame(msgType: UInt8, seq: UInt8, cmd: UInt8, b3: UInt8,
                               payload: Data = Data(), field: UInt16 = 0x0100,
                               version: UInt8 = 0x01) -> Data {
    var inner = Data([msgType, seq, cmd, b3])
    inner.append(payload)
    let innerCRC = Framing.crc32Std(inner)

    var headerBody = Data([version])
    headerBody.append(contentsOf: withUnsafeBytes(of: UInt16(inner.count + 4).littleEndian) { Data($0) })
    headerBody.append(contentsOf: withUnsafeBytes(of: field.littleEndian) { Data($0) })
    let headerCRC = Framing.crc16Modbus(headerBody)

    var out = Data([Framing.outerMagic])
    out.append(headerBody)
    out.append(contentsOf: withUnsafeBytes(of: headerCRC.littleEndian) { Data($0) })
    out.append(inner)
    out.append(contentsOf: withUnsafeBytes(of: innerCRC.littleEndian) { Data($0) })
    return out
}

/// Parse one complete 0xAA-framed message.
public func parseFrame(_ data: Data) throws -> OuterFrame {
    guard data.count >= 9 else { throw FrameError.tooShort(data.count) }
    let bytes = [UInt8](data)
    guard bytes[0] == Framing.outerMagic else { throw FrameError.badMagic(bytes[0]) }

    let version = bytes[1]
    let declLen = UInt16(bytes[2]) | (UInt16(bytes[3]) << 8)
    let field = UInt16(bytes[4]) | (UInt16(bytes[5]) << 8)
    let headerCRCRx = UInt16(bytes[6]) | (UInt16(bytes[7]) << 8)

    let headerBody = bytes[1..<6]
    let headerCRCOK = Framing.crc16Modbus(headerBody) == headerCRCRx

    let innerStart = 8
    let innerEnd = innerStart + Int(declLen)
    guard bytes.count >= innerEnd else {
        throw FrameError.declaredLengthExceedsBuffer(declared: Int(declLen),
                                                       available: bytes.count - innerStart)
    }

    let innerFull = Array(bytes[innerStart..<innerEnd])
    guard innerFull.count >= 4 + 4 else { throw FrameError.innerTooShort }

    let innerBody = innerFull[0..<(innerFull.count - 4)]
    let crcBytes = innerFull[(innerFull.count - 4)...]
    let crcRx = UInt32(crcBytes[crcBytes.startIndex]) |
        (UInt32(crcBytes[crcBytes.startIndex + 1]) << 8) |
        (UInt32(crcBytes[crcBytes.startIndex + 2]) << 16) |
        (UInt32(crcBytes[crcBytes.startIndex + 3]) << 24)
    let crc32OK = Framing.crc32Std(innerBody) == crcRx

    let msgType = innerBody[innerBody.startIndex]
    let seq = innerBody[innerBody.startIndex + 1]
    let cmd = innerBody[innerBody.startIndex + 2]
    let b3 = innerBody[innerBody.startIndex + 3]
    let payload = Data(innerBody[(innerBody.startIndex + 4)...])

    let inner = InnerMessage(type: msgType, seq: seq, cmd: cmd, b3: b3,
                              payload: payload, crc32OK: crc32OK)
    return OuterFrame(version: version, field: field, headerCRCOK: headerCRCOK,
                       inner: inner, raw: Data(bytes[0..<innerEnd]))
}

/// Streaming reassembler: feed it bytes as BLE notifications arrive (they
/// can be split across MTUs), get back any complete frames found so far.
/// Consumed bytes are removed from `buffer`; a trailing partial frame is
/// left in place for the next call.
public final class FrameReassembler {
    private var buffer = Data()

    public init() {}

    public func feed(_ chunk: Data) -> [OuterFrame] {
        buffer.append(chunk)
        var frames: [OuterFrame] = []

        while true {
            guard let magicIdx = buffer.firstIndex(of: Framing.outerMagic) else {
                buffer.removeAll()
                break
            }
            if magicIdx > buffer.startIndex {
                buffer.removeSubrange(buffer.startIndex..<magicIdx)
            }
            guard buffer.count >= 8 else { break }

            let b = [UInt8](buffer)
            let declLen = Int(UInt16(b[2]) | (UInt16(b[3]) << 8))
            let totalLen = 8 + declLen
            guard buffer.count >= totalLen else { break }

            let chunkData = buffer.prefix(totalLen)
            buffer.removeFirst(totalLen)

            do {
                frames.append(try parseFrame(Data(chunkData)))
            } catch {
                // Resync: drop the magic byte we just consumed and keep scanning.
                continue
            }
        }
        return frames
    }
}
