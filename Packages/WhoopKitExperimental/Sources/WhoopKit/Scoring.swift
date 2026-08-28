//
//  Scoring.swift
//  WhoopKit
//
//  IMPORTANT SCOPE NOTE, read before using this file:
//
//  WHOOP's actual Recovery %, Strain (0-21), and Sleep Performance scores
//  are computed by WHOOP's cloud from proprietary, unpublished models. No
//  public project -- including NOOP and goose, which this whole codebase
//  is built on -- has reproduced those exact numbers, and this file doesn't
//  either. What's below are independent estimates from established,
//  published sports-science formulas (cited per function), computed
//  entirely on-device from your own sensor stream. Treat the output as
//  "a reasonable recovery/strain/sleep estimate", not as "WHOOP's number".
//
//  This is the same honesty NOOP itself states in its own docs: "Recovery/
//  strain/sleep scores are computed in WHOOP's cloud and no public project
//  has reproduced them."
//

import Foundation

// MARK: - Recovery (HRV/RMSSD based)

/// Estimates a 0-100 recovery-style score from RMSSD (root mean square of
/// successive R-R interval differences, a standard HRV metric) relative to
/// the person's own rolling baseline, plus resting heart rate delta.
/// Method: Bravata/Plews-style HRV-relative-to-baseline scoring, widely
/// published in the sports-science literature (e.g. Plews et al., "Training
/// Adaptation and Heart Rate Variability in Elite Endurance Athletes",
/// Sports Med 2013) -- NOT WHOOP's model.
public enum RecoveryEstimator {
    public struct Input {
        public let rrIntervalsSeconds: [Double]     // from an overnight/resting HR window
        public let baselineRMSSDMs: Double?          // rolling N-day average, nil if not enough history
        public let baselineRestingHR: Double?
        public let currentRestingHR: Double?

        public init(rrIntervalsSeconds: [Double], baselineRMSSDMs: Double?,
                    baselineRestingHR: Double?, currentRestingHR: Double?) {
            self.rrIntervalsSeconds = rrIntervalsSeconds
            self.baselineRMSSDMs = baselineRMSSDMs
            self.baselineRestingHR = baselineRestingHR
            self.currentRestingHR = currentRestingHR
        }
    }

    public struct Result {
        public let rmssdMs: Double
        public let score0to100: Int
        public let note: String
    }

    public static func rmssd(fromRRSeconds rr: [Double]) -> Double? {
        guard rr.count >= 2 else { return nil }
        let msValues = rr.map { $0 * 1000.0 }
        var sumSquaredDiffs = 0.0
        for i in 1..<msValues.count {
            let d = msValues[i] - msValues[i - 1]
            sumSquaredDiffs += d * d
        }
        return (sumSquaredDiffs / Double(msValues.count - 1)).squareRoot()
    }

    public static func estimate(_ input: Input) -> Result? {
        guard let rmssd = rmssd(fromRRSeconds: input.rrIntervalsSeconds) else { return nil }

        guard let baseline = input.baselineRMSSDMs, baseline > 0 else {
            return Result(rmssdMs: rmssd, score0to100: 50,
                           note: "No RMSSD baseline yet (need several days of overnight data) -- neutral placeholder score.")
        }

        // Percent deviation from baseline, mapped onto a 0-100 band centered
        // at 50 for "at baseline". This mapping (not the RMSSD math itself)
        // is a reasonable heuristic, not a published constant -- tune it
        // against your own data if it doesn't feel right.
        let pctDelta = (rmssd - baseline) / baseline
        var score = 50.0 + (pctDelta * 150.0)

        if let baseRHR = input.baselineRestingHR, let curRHR = input.currentRestingHR, baseRHR > 0 {
            let rhrDeltaPct = (curRHR - baseRHR) / baseRHR
            score -= rhrDeltaPct * 100.0  // elevated resting HR drags recovery down
        }

        let clamped = max(0, min(100, Int(score.rounded())))
        return Result(rmssdMs: rmssd, score0to100: clamped,
                       note: "Estimate from RMSSD vs your own rolling baseline + resting HR delta. Not WHOOP's proprietary score.")
    }
}

// MARK: - Strain (heart-rate-zone / TRIMP based)

/// Estimates a cumulative daily "strain-like" load using Banister's TRIMP
/// (Training Impulse) method -- exercise duration weighted by heart-rate
/// reserve fraction, exponentially weighted toward higher intensity.
/// Reference: Banister, E.W. (1991), "Modeling Elite Athletic Performance".
/// Rescaled onto roughly a 0-21 band to be visually comparable to WHOOP's
/// display range -- this rescaling is a cosmetic choice, not a claim that
/// the numbers mean the same thing WHOOP's do.
public enum StrainEstimator {
    public struct Sample {
        public let heartRateBPM: Int
        public let durationSeconds: Double
        public init(heartRateBPM: Int, durationSeconds: Double) {
            self.heartRateBPM = heartRateBPM
            self.durationSeconds = durationSeconds
        }
    }

    /// - Parameters:
    ///   - samples: HR samples across the day/session with the duration each one represents.
    ///   - restingHR: your resting HR.
    ///   - maxHR: your max HR (measured, or 220-age as a rough fallback -- the
    ///     220-age formula itself is a well-known population average with
    ///     wide individual error bars, not a precise figure).
    ///   - genderWeightingFemale: Banister's original TRIMP exponential
    ///     weighting constant differs slightly by sex in the published
    ///     literature; pass whichever you want to use, or leave the default.
    public static func dailyStrain(samples: [Sample], restingHR: Double, maxHR: Double,
                                    genderWeightingFemale: Bool = false) -> Double {
        guard maxHR > restingHR else { return 0 }
        let k = genderWeightingFemale ? 1.67 : 1.92
        var trimp = 0.0
        for s in samples {
            let hrr = (Double(s.heartRateBPM) - restingHR) / (maxHR - restingHR)
            let hrrClamped = max(0, min(1, hrr))
            let minutes = s.durationSeconds / 60.0
            trimp += minutes * hrrClamped * 0.64 * exp(k * hrrClamped)
        }
        // Cosmetic rescale toward a 0-21-ish band; tune the divisor against
        // your own typical daily TRIMP totals rather than trusting this
        // constant blindly.
        let rescaled = min(21.0, log(1 + trimp) * 3.5)
        return rescaled
    }
}

// MARK: - Sleep staging (actigraphy + HR based)

/// A coarse sleep-stage classifier from accelerometer motion intensity and
/// heart rate, following the general approach of published actigraphy
/// sleep-staging literature (e.g. Cole-Kripke-style movement thresholds,
/// combined with HR-based REM/deep heuristics as in more recent wearable
/// research). This is a simplified estimate, not a validated PSG-equivalent
/// classifier, and won't match WHOOP's own (also HR+motion-based, but
/// separately tuned and unpublished) sleep stager exactly.
public enum SleepStageEstimator {
    public enum Stage: String { case awake, light, deep, rem }

    public struct Epoch {
        public let motionMagnitude: Double   // e.g. sqrt(ax^2+ay^2+az^2) variance over the epoch
        public let heartRateBPM: Int
        public let epochSeconds: Double
        public init(motionMagnitude: Double, heartRateBPM: Int, epochSeconds: Double = 30) {
            self.motionMagnitude = motionMagnitude
            self.heartRateBPM = heartRateBPM
            self.epochSeconds = epochSeconds
        }
    }

    /// Classifies one 30s-ish epoch. Thresholds are starting points from
    /// the general actigraphy literature -- expect to calibrate them
    /// against a few nights of your own data (e.g. against how you actually
    /// felt, or against another validated device) before trusting them.
    public static func classify(_ epoch: Epoch, restingHR: Double, sleepHRBaseline: Double) -> Stage {
        let highMotion = epoch.motionMagnitude > 0.15
        if highMotion {
            return .awake
        }
        let hrDelta = Double(epoch.heartRateBPM) - sleepHRBaseline
        if hrDelta > 8 {
            return .rem            // REM shows HR variability/elevation vs deep sleep baseline
        }
        if hrDelta < -3 {
            return .deep            // deep sleep tends to show the lowest, most stable HR
        }
        return .light
    }

    public static func classifyNight(_ epochs: [Epoch], restingHR: Double) -> [Stage] {
        guard !epochs.isEmpty else { return [] }
        let sleepBaseline = epochs.map { Double($0.heartRateBPM) }.sorted()[epochs.count / 2] // median as a robust baseline
        return epochs.map { classify($0, restingHR: restingHR, sleepHRBaseline: sleepBaseline) }
    }

    public static func summarize(_ stages: [Stage], epochSeconds: Double = 30) -> [Stage: TimeInterval] {
        var totals: [Stage: TimeInterval] = [:]
        for s in stages {
            totals[s, default: 0] += epochSeconds
        }
        return totals
    }
}
