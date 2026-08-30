//
//  Samples.swift
//  WhoopProtocol
//
//  IMPORTANT SCOPE NOTE:
//
//  This file contains ONLY the plain data-model types that StrandAnalytics
//  (Packages/StrandAnalytics) declares a dependency on. Their shapes were
//  reconstructed directly from how StrandAnalytics's own source code uses
//  them (field names, types, nullability) -- e.g. `HRVAnalyzer.swift` reads
//  `Double($0.rrMs)` on an `RRInterval`, `Baselines`/`SleepStager` read
//  `.ts` and `.bpm` on `HRSample`, `wornNightlySkinTempC` reads
//  `Double(t.raw) / 128.0` on a `SkinTempSample`, etc. That's a mechanical,
//  low-risk reconstruction of a call-site contract, not a guess.
//
//  This file does NOT contain, and doesn't attempt, BLE decode logic --
//  i.e. nothing here turns raw WHOOP5 packet bytes into these types. That
//  logic isn't present anywhere in this fork (there's no WhoopProtocol
//  package at all currently), and StrandAnalytics's own comments reference
//  specific reverse-engineered details (byte/register offsets like
//  `step_motion_counter@57`, `skin_temp_raw@73`, and a noted scale
//  difference between this decoder and an "Android decoder" for the same
//  register) that aren't recoverable from reading StrandAnalytics's
//  consumption of these types alone. Fabricating that decode logic here
//  would produce code that compiles but silently computes wrong health
//  data, so it's deliberately not attempted -- see full_capture.py /
//  diff_frames.py / gatt_dump.py (Tools/protocol-probe/) for the actual
//  path to recovering it from a real strap.
//

import Foundation

/// One heart-rate reading (1 Hz strap stream). Consumed throughout
/// StrandAnalytics (HRZones, RecoveryScorer, StrainScorer, SleepStager,
/// WorkoutDetector) as `.ts` (unix seconds) and `.bpm`.
public struct HRSample: Equatable, Sendable {
    public let ts: Int
    public let bpm: Int
    public init(ts: Int, bpm: Int) {
        self.ts = ts
        self.bpm = bpm
    }
}

/// One R-R (beat-to-beat) interval in milliseconds. Consumed by
/// HRVAnalyzer (RMSSD/SDNN), SleepStager (RSA-based respiratory rate
/// estimate), and RecoveryScorer indirectly via HRVAnalyzer.
public struct RRInterval: Equatable, Sendable {
    public let ts: Int
    public let rrMs: Int
    public init(ts: Int, rrMs: Int) {
        self.ts = ts
        self.rrMs = rrMs
    }
}

/// One raw respiration-channel sample (WHOOP4-style resp ADC; WHOOP5/MG's
/// wire protocol doesn't carry this, per SleepStager's own comments, which
/// is why it also derives an RSA-based respiratory-rate estimate from RR
/// intervals as a fallback for that generation).
public struct RespSample: Equatable, Sendable {
    public let ts: Int
    public let raw: Int
    public init(ts: Int, raw: Int) {
        self.ts = ts
        self.raw = raw
    }
}

/// One 3-axis gravity/accelerometer reading, used for motion/stillness
/// detection (sleep staging, workout detection).
public struct GravitySample: Equatable, Sendable {
    public let ts: Int
    public let x: Double
    public let y: Double
    public let z: Double
    public init(ts: Int, x: Double, y: Double, z: Double) {
        self.ts = ts
        self.x = x
        self.y = y
        self.z = z
    }
}

/// One cumulative step-counter reading. AnalyticsEngine's own comments
/// document this as a wrapping u16 running counter (see its
/// `stepsTotal` computation) -- this type just carries the raw counter
/// value at a timestamp; the wraparound/reset handling lives in
/// StrandAnalytics, not here.
public struct StepSample: Equatable, Sendable {
    public let ts: Int
    public let counter: Int
    public init(ts: Int, counter: Int) {
        self.ts = ts
        self.counter = counter
    }
}

/// One raw skin-temperature register reading. AnalyticsEngine's own
/// comment on `wornNightlySkinTempC` documents the conversion this
/// decoder is expected to be consistent with: `°C = raw / 128` (its
/// comment explicitly warns this differs from an Android decoder's /100
/// for the "same register" -- worth keeping in mind if you ever compare
/// against another client's numbers).
public struct SkinTempSample: Equatable, Sendable {
    public let ts: Int
    public let raw: Int
    public init(ts: Int, raw: Int) {
        self.ts = ts
        self.raw = raw
    }
}
