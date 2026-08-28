import XCTest
@testable import WhoopKit

final class WhoopKitTests: XCTestCase {
    func testGetHelloRoundTrip() throws {
        let frameBytes = buildCommandFrame(msgType: puffinEnvelopeType, seq: 1,
                                            cmd: Command.getHello, b3: 0x01)
        let parsed = try parseFrame(frameBytes)
        XCTAssertTrue(parsed.headerCRCOK)
        XCTAssertTrue(parsed.inner.crc32OK)
        XCTAssertEqual(parsed.inner.cmd, Command.getHello)
    }

    func testSetFFValueDecode() throws {
        var body = Data(repeating: 0, count: 40)
        let name = Array("enable_r22_packets".utf8)
        body.replaceSubrange(0..<name.count, with: name)
        body[32] = Character("1").asciiValue!

        let frameBytes = buildCommandFrame(msgType: puffinEnvelopeType, seq: 5,
                                            cmd: Command.setFFValue, b3: 0x01, payload: body)
        let parsed = try parseFrame(frameBytes)
        guard case .featureFlag(let ff) = decodePuffinPayload(parsed.inner) else {
            XCTFail("expected featureFlag"); return
        }
        XCTAssertEqual(ff.name, "enable_r22_packets")
        XCTAssertEqual(ff.valueChar, "1")
    }

    func testStreamingReassembly() {
        let f1 = buildCommandFrame(msgType: puffinEnvelopeType, seq: 1, cmd: Command.getHello, b3: 0x01)
        let f2 = buildCommandFrame(msgType: puffinEnvelopeType, seq: 2, cmd: Command.getDataRange, b3: 0x00,
                                    payload: Data([0x00]))
        var combined = f1
        combined.append(f2)

        let reassembler = FrameReassembler()
        // Simulate two separate BLE notification chunks arriving.
        let frames1 = reassembler.feed(combined.prefix(10))
        let frames2 = reassembler.feed(combined.suffix(from: 10))
        let seqs = (frames1 + frames2).map { $0.inner.seq }
        XCTAssertEqual(seqs, [1, 2])
    }

    func testStandardHRDecode() {
        // flags=0x10 (RR present, 8-bit HR), bpm=62, one RR of 1000/1024s
        var raw = Data([0x10, 62])
        raw.append(contentsOf: withUnsafeBytes(of: UInt16(1000).littleEndian) { Data($0) })
        guard let hr = HeartRateMeasurement.decode(raw) else { XCTFail("decode failed"); return }
        XCTAssertEqual(hr.bpm, 62)
        XCTAssertEqual(hr.rrIntervalsSeconds.first!, 1000.0 / 1024.0, accuracy: 1e-6)
    }

    func testRecoveryEstimatorNeutralWithoutBaseline() {
        let input = RecoveryEstimator.Input(rrIntervalsSeconds: [0.8, 0.82, 0.79, 0.81],
                                             baselineRMSSDMs: nil, baselineRestingHR: nil,
                                             currentRestingHR: nil)
        let result = RecoveryEstimator.estimate(input)
        XCTAssertEqual(result?.score0to100, 50)
    }

    func testStrainEstimatorMonotonic() {
        let lowSamples = [StrainEstimator.Sample(heartRateBPM: 90, durationSeconds: 600)]
        let highSamples = [StrainEstimator.Sample(heartRateBPM: 170, durationSeconds: 600)]
        let low = StrainEstimator.dailyStrain(samples: lowSamples, restingHR: 55, maxHR: 190)
        let high = StrainEstimator.dailyStrain(samples: highSamples, restingHR: 55, maxHR: 190)
        XCTAssertLessThan(low, high)
    }
}
