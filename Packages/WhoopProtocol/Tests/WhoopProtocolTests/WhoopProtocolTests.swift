import XCTest
@testable import WhoopProtocol

final class WhoopProtocolTests: XCTestCase {
    func testSampleTypesConstructAndCarryFields() {
        let hr = HRSample(ts: 1000, bpm: 62)
        XCTAssertEqual(hr.ts, 1000)
        XCTAssertEqual(hr.bpm, 62)

        let rr = RRInterval(ts: 1000, rrMs: 820)
        XCTAssertEqual(rr.rrMs, 820)

        let resp = RespSample(ts: 1000, raw: 512)
        XCTAssertEqual(resp.raw, 512)

        let grav = GravitySample(ts: 1000, x: 0.1, y: -0.2, z: 0.98)
        XCTAssertEqual(grav.z, 0.98)

        let step = StepSample(ts: 1000, counter: 4231)
        XCTAssertEqual(step.counter, 4231)

        let skin = SkinTempSample(ts: 1000, raw: 4352)
        // per AnalyticsEngine's documented raw/128 conversion
        XCTAssertEqual(Double(skin.raw) / 128.0, 34.0, accuracy: 0.001)
    }
}
