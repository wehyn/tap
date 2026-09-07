import Foundation
import TapProbeCore

private func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fatalError(message)
    }
}

private func writeInt32LittleEndian(_ value: Int32, into bytes: inout [UInt8], offset: Int) {
    let bits = UInt32(bitPattern: value)
    bytes[offset] = UInt8(bits & 0xff)
    bytes[offset + 1] = UInt8((bits >> 8) & 0xff)
    bytes[offset + 2] = UInt8((bits >> 16) & 0xff)
    bytes[offset + 3] = UInt8((bits >> 24) & 0xff)
}

var bytes = Array(repeating: UInt8(0), count: IMUReportParser.expectedReportLength)
writeInt32LittleEndian(65_536, into: &bytes, offset: 6)
writeInt32LittleEndian(-131_072, into: &bytes, offset: 10)
writeInt32LittleEndian(32_768, into: &bytes, offset: 14)

let report = try IMUReportParser().parse(channel: .accelerometer, bytes: bytes)
require(report.rawX == 65_536, "x raw value did not parse")
require(report.rawY == -131_072, "y raw value did not parse")
require(report.rawZ == 32_768, "z raw value did not parse")
require(abs(report.x - 1.0) < 0.000001, "x scale did not parse")
require(abs(report.y + 2.0) < 0.000001, "y scale did not parse")
require(abs(report.z - 0.5) < 0.000001, "z scale did not parse")

do {
    _ = try IMUReportParser().parse(
        channel: .gyroscope,
        bytes: Array(repeating: 0, count: IMUReportParser.expectedReportLength - 1)
    )
    fatalError("short reports must be rejected")
} catch let error as ReportParserError {
    require(
        error == .reportTooShort(actual: 21, minimum: IMUReportParser.expectedReportLength),
        "short report returned the wrong parser error"
    )
} catch {
    fatalError("short report returned an unexpected error: \(error)")
}

var calibrator = MotionCalibrator()
for index in 0..<100 {
    let timestamp = UInt64(index) * 1_000_000
    calibrator.add(
        MotionSample(
            timestampNanoseconds: timestamp,
            channel: .accelerometer,
            vector: MotionVector(x: 0, y: 0, z: -1)
        )
    )
    calibrator.add(
        MotionSample(
            timestampNanoseconds: timestamp,
            channel: .gyroscope,
            vector: .zero
        )
    )
}

let profile = calibrator.makeProfile(calibratedAtNanoseconds: 100_000_000)
require(profile.isUsable, "calibration profile should include both channels")
require(abs(profile.accelerometer.mean.z + 1) < 0.000001, "calibration mean did not converge")
require(
    TapSensitivity.high.minimumDynamicAccelerationG
        < TapSensitivity.medium.minimumDynamicAccelerationG,
    "high sensitivity should use a lower threshold"
)
require(
    TapSensitivity.medium.minimumDynamicAccelerationG
        < TapSensitivity.low.minimumDynamicAccelerationG,
    "low sensitivity should use a higher threshold"
)
require(
    TapDetectorConfiguration(sensitivity: .high).minimumDynamicAccelerationG == 0.05,
    "sensitivity preset did not configure its threshold"
)

var detector = TapDetector(calibration: profile)
_ = detector.process(
    MotionSample(
        timestampNanoseconds: 900_000_000,
        channel: .accelerometer,
        vector: MotionVector(x: 0, y: 0, z: -1)
    )
)
let impulseStart = detector.process(
    MotionSample(
        timestampNanoseconds: 1_000_000_000,
        channel: .accelerometer,
        vector: MotionVector(x: 0.25, y: 0, z: -1)
    )
)
require(impulseStart == nil, "tap candidate should wait for impulse recovery")

let firstEvent = detector.process(
    MotionSample(
        timestampNanoseconds: 1_050_000_000,
        channel: .accelerometer,
        vector: MotionVector(x: 0, y: 0, z: -1)
    )
)
require(firstEvent != nil, "synthetic impulse should produce a tap candidate")
require(firstEvent?.side == .unknown, "uncalibrated side should remain unknown")

_ = detector.process(
    MotionSample(
        timestampNanoseconds: 1_100_000_000,
        channel: .accelerometer,
        vector: MotionVector(x: 0.25, y: 0, z: -1)
    )
)
let suppressedEvent = detector.process(
    MotionSample(
        timestampNanoseconds: 1_150_000_000,
        channel: .accelerometer,
        vector: MotionVector(x: 0, y: 0, z: -1)
    )
)
require(suppressedEvent == nil, "refractory period should suppress ringing")

_ = detector.process(
    MotionSample(
        timestampNanoseconds: 1_180_000_000,
        channel: .accelerometer,
        vector: MotionVector(x: 0.25, y: 0, z: -1)
    )
)
let fastSecondTap = detector.process(
    MotionSample(
        timestampNanoseconds: 1_230_000_000,
        channel: .accelerometer,
        vector: MotionVector(x: 0, y: 0, z: -1)
    )
)
require(
    fastSecondTap != nil,
    "a distinct tap after 180 ms should survive the multi-tap refractory window"
)

var timeoutRearmDetector = TapDetector(
    calibration: profile,
    configuration: TapDetectorConfiguration(
        minimumDynamicAccelerationG: 0.10,
        maximumImpactWindowNanoseconds: 20_000_000
    )
)
let restForTimeoutRearm = MotionVector(x: 0, y: 0, z: -1)
_ = timeoutRearmDetector.process(
    MotionSample(
        timestampNanoseconds: 3_000_000_000,
        channel: .accelerometer,
        vector: restForTimeoutRearm
    )
)
_ = timeoutRearmDetector.process(
    MotionSample(
        timestampNanoseconds: 3_010_000_000,
        channel: .accelerometer,
        vector: MotionVector(x: 0.20, y: 0, z: -1)
    )
)
_ = timeoutRearmDetector.process(
    MotionSample(
        timestampNanoseconds: 3_040_000_000,
        channel: .accelerometer,
        vector: MotionVector(x: 0.08, y: 0, z: -1)
    )
)
_ = timeoutRearmDetector.process(
    MotionSample(
        timestampNanoseconds: 3_050_000_000,
        channel: .accelerometer,
        vector: restForTimeoutRearm
    )
)
let secondImpulseStart = timeoutRearmDetector.process(
    MotionSample(
        timestampNanoseconds: 3_060_000_000,
        channel: .accelerometer,
        vector: MotionVector(x: 0.20, y: 0, z: -1)
    )
)
require(
    secondImpulseStart == nil,
    "the detector should re-arm after a timed-out movement"
)
let secondImpulseEvent = timeoutRearmDetector.process(
    MotionSample(
        timestampNanoseconds: 3_075_000_000,
        channel: .accelerometer,
        vector: restForTimeoutRearm
    )
)
require(
    secondImpulseEvent != nil,
    "a real tap after a timed-out movement should not be lost"
)

var lowGyroDetector = TapDetector(
    calibration: profile,
    configuration: TapDetectorConfiguration(minimumDynamicAccelerationG: 0.10)
)
let lowGyroWaveform: [Double] = [0, 0.08, 0.11, 0.145, 0.11, 0.075, 0.04]
let lowGyroEvent = lowGyroWaveform.enumerated().compactMap { index, x in
    lowGyroDetector.process(
        MotionSample(
            timestampNanoseconds: 2_000_000_000 + UInt64(index) * 10_000_000,
            channel: .accelerometer,
            vector: MotionVector(x: x, y: 0, z: -1)
        )
    )
}.first
require(
    lowGyroEvent != nil,
    "a measured-style 0.145g impulse with 0.035g/sample jerk should be accepted without strong gyro"
)

func interleavedSamples(
    accelerometer: [MotionVector],
    angularRate: (Int) -> MotionVector = { _ in .zero }
) -> [MotionSample] {
    accelerometer.enumerated().flatMap { index, vector in
        let timestamp = UInt64(index) * 10_000_000
        return [
            MotionSample(
                timestampNanoseconds: timestamp,
                channel: .gyroscope,
                vector: angularRate(index)
            ),
            MotionSample(
                timestampNanoseconds: timestamp,
                channel: .accelerometer,
                vector: vector
            ),
        ]
    }
}

func candidateCount(
    for samples: [MotionSample],
    configuration: TapDetectorConfiguration = TapDetectorConfiguration(sensitivity: .high)
) -> Int {
    var detector = TapDetector(calibration: profile, configuration: configuration)
    return samples.reduce(into: 0) { count, sample in
        if detector.process(sample) != nil {
            count += 1
        }
    }
}

let fastTripleFixture = interleavedSamples(
    accelerometer: (0..<60).map { index in
        [10, 28, 46].contains(index)
            ? MotionVector(x: 0.25, y: 0, z: -1)
            : MotionVector(x: 0, y: 0, z: -1)
    }
)
require(
    candidateCount(for: fastTripleFixture) == 3,
    "three distinct taps spaced 180 ms apart should all reach grouping"
)

let restVector = MotionVector(x: 0, y: 0, z: -1)
let typingFixture = interleavedSamples(
    accelerometer: [restVector] + (0..<80).map { index in
        MotionVector(
            x: index.isMultiple(of: 2) ? 0.07 : -0.07,
            y: 0.02,
            z: -1
        )
    },
    angularRate: { _ in MotionVector(x: 2, y: 4, z: 1) }
)
require(
    candidateCount(for: typingFixture) == 0,
    "typing-like subthreshold motion should not produce tap candidates"
)

let trackpadFixture = interleavedSamples(
    accelerometer: [restVector] + (0..<120).map { index in
        let phase = Double(index) * 0.08
        return MotionVector(
            x: sin(phase) * 0.08,
            y: cos(phase) * 0.04,
            z: -1
        )
    },
    angularRate: { _ in MotionVector(x: 1, y: 3, z: 1) }
)
require(
    candidateCount(for: trackpadFixture) == 0,
    "trackpad-like low-amplitude motion should not produce tap candidates"
)

let deskVibrationFixture = interleavedSamples(
    accelerometer: [restVector]
        + (0..<40).map { index in
            MotionVector(
                x: index.isMultiple(of: 2) ? 0.13 : 0.11,
                y: 0,
                z: -1
            )
        }
        + [restVector],
    angularRate: { _ in MotionVector(x: 5, y: 6, z: 2) }
)
require(
    candidateCount(for: deskVibrationFixture) == 0,
    "sustained desk vibration should time out instead of producing a tap"
)

var carryingAccelerometer = [restVector]
carryingAccelerometer.append(contentsOf: (1...60).map { index in
    MotionVector(x: Double(index) * 0.003, y: 0, z: -1)
})
carryingAccelerometer.append(contentsOf: (1...60).reversed().map { index in
    MotionVector(x: Double(index) * 0.003, y: 0, z: -1)
})
carryingAccelerometer.append(restVector)
let carryingFixture = interleavedSamples(
    accelerometer: carryingAccelerometer,
    angularRate: { _ in MotionVector(x: 7, y: 5, z: 3) }
)
require(
    candidateCount(for: carryingFixture) == 0,
    "slow carrying motion should not produce tap candidates"
)

let lidMovementFixture = interleavedSamples(
    accelerometer: [restVector]
        + (1...100).map { index in
            let angle = Double(index) / 100 * 0.45
            return MotionVector(x: sin(angle), y: 0, z: -cos(angle))
        },
    angularRate: { _ in MotionVector(x: 0, y: 5, z: 0) }
)
require(
    candidateCount(for: lidMovementFixture) == 0,
    "slow lid movement should not produce tap candidates"
)

var palmContactAccelerometer = [restVector]
palmContactAccelerometer.append(contentsOf: (1...30).map { index in
    MotionVector(x: Double(index) * 0.007, y: 0, z: -1)
})
palmContactAccelerometer.append(contentsOf: (1...30).reversed().map { index in
    MotionVector(x: Double(index) * 0.007, y: 0, z: -1)
})
palmContactAccelerometer.append(restVector)
let palmContactFixture = interleavedSamples(
    accelerometer: palmContactAccelerometer,
    angularRate: { _ in MotionVector(x: 3, y: 4, z: 2) }
)
require(
    candidateCount(for: palmContactFixture) == 0,
    "slow palm contact should not produce tap candidates"
)

let verySensitiveConfiguration = TapDetectorConfiguration(
    minimumDynamicAccelerationG: 0.02
)
let lightImpulseFixture = interleavedSamples(
    accelerometer: [
        restVector,
        MotionVector(x: 0.022, y: 0, z: -1),
        MotionVector(x: 0.030, y: 0, z: -1),
        MotionVector(x: 0.012, y: 0, z: -1),
        restVector,
    ]
)
require(
    candidateCount(
        for: lightImpulseFixture,
        configuration: verySensitiveConfiguration
    ) == 1,
    "very-sensitive mode should accept a short low-energy impulse"
)
require(
    candidateCount(
        for: typingFixture,
        configuration: verySensitiveConfiguration
    ) == 0,
    "very-sensitive mode should still reject sustained typing-like motion"
)
require(
    candidateCount(
        for: trackpadFixture,
        configuration: verySensitiveConfiguration
    ) == 0,
    "very-sensitive mode should still reject sustained trackpad-like motion"
)
require(
    candidateCount(
        for: deskVibrationFixture,
        configuration: verySensitiveConfiguration
    ) == 0,
    "very-sensitive mode should still reject sustained desk vibration"
)
require(
    candidateCount(
        for: carryingFixture,
        configuration: verySensitiveConfiguration
    ) == 0,
    "very-sensitive mode should still reject slow carrying motion"
)
require(
    candidateCount(
        for: lidMovementFixture,
        configuration: verySensitiveConfiguration
    ) == 0,
    "very-sensitive mode should still reject slow lid movement"
)
require(
    candidateCount(
        for: palmContactFixture,
        configuration: verySensitiveConfiguration
    ) == 0,
    "very-sensitive mode should still reject slow palm contact"
)

func syntheticEvent(
    timestamp: UInt64,
    side: TapSide,
    dynamic: MotionVector,
    angular: MotionVector,
    confidence: Double = 0.9,
    onsetDynamic: MotionVector? = nil,
    onsetAngular: MotionVector? = nil,
    recoveryDurationNanoseconds: UInt64 = 0
) -> TapEvent {
    TapEvent(
        timestampNanoseconds: timestamp,
        side: side,
        dynamicAcceleration: dynamic,
        angularRate: angular,
        peakDynamicAccelerationG: dynamic.magnitude,
        peakJerkGPerSample: 0.05,
        peakAngularRateDps: angular.magnitude,
        confidence: confidence,
        onsetDynamicAcceleration: onsetDynamic,
        onsetAngularRate: onsetAngular,
        recoveryDurationNanoseconds: recoveryDurationNanoseconds
    )
}

var sideTrainer = TapSideClassifier(minimumSamplesPerSide: 3)
for index in 0..<3 {
    sideTrainer.add(
        event: syntheticEvent(
            timestamp: UInt64(index),
            side: .unknown,
            dynamic: MotionVector(x: 1, y: 0, z: 0),
            angular: MotionVector(x: 0, y: 1, z: 0),
            onsetDynamic: MotionVector(x: 0.9, y: 0.4, z: 0),
            onsetAngular: MotionVector(x: 0, y: 0.8, z: 0.6),
            recoveryDurationNanoseconds: 50_000_000
        ),
        labeled: .left
    )
    sideTrainer.add(
        event: syntheticEvent(
            timestamp: UInt64(index),
            side: .unknown,
            dynamic: MotionVector(x: -1, y: 0, z: 0),
            angular: MotionVector(x: 0, y: -1, z: 0),
            onsetDynamic: MotionVector(x: -0.9, y: -0.4, z: 0),
            onsetAngular: MotionVector(x: 0, y: -0.8, z: -0.6),
            recoveryDurationNanoseconds: 100_000_000
        ),
        labeled: .right
    )
}
let sideProfile = sideTrainer.makeProfile(calibratedAtNanoseconds: 3)
require(sideProfile.isUsable, "three labeled events per side should enable the profile")
require(
    sideProfile.left?.featureSamples?.count == 3
        && sideProfile.right?.featureSamples?.count == 3,
    "side profiles should retain individual calibrated examples"
)
let sideClassifier = TapSideClassifier(profile: sideProfile)
require(TapSideProfile.bundledDefault.isUsable, "bundled side profile should be usable")
let bundledClassifier = TapSideClassifier(profile: TapSideProfile.bundledDefault)
require(
    bundledClassifier.classify(
        syntheticEvent(
            timestamp: 4,
            side: .unknown,
            dynamic: MotionVector(x: 0.001, y: -0.003, z: 0.106),
            angular: MotionVector(x: -1.300, y: 0.579, z: 0.070),
            onsetDynamic: MotionVector(x: 0.003, y: 0.002, z: 0.064),
            onsetAngular: MotionVector(x: -0.934, y: 0.335, z: 0.193),
            recoveryDurationNanoseconds: 13_100_000
        )
    ).side == .left,
    "bundled side profile should classify the flat-chassis left capture fixture"
)
require(
    bundledClassifier.classify(
        syntheticEvent(
            timestamp: 4,
            side: .unknown,
            dynamic: MotionVector(x: -0.001, y: -0.004, z: 0.083),
            angular: MotionVector(x: 6.814, y: -0.455, z: -1.395),
            onsetDynamic: MotionVector(x: 0.003, y: 0.002, z: 0.050),
            onsetAngular: MotionVector(x: 5.472, y: -1.737, z: -0.907),
            recoveryDurationNanoseconds: 8_800_000
        )
    ).side == .right,
    "bundled side profile should classify the positive-ringing right capture fixture"
)
require(
    bundledClassifier.classify(
        syntheticEvent(
            timestamp: 4,
            side: .unknown,
            dynamic: MotionVector(x: 0.004, y: 0.004, z: -0.171),
            angular: MotionVector(x: 0.833, y: 0.582, z: 0.009),
            onsetDynamic: MotionVector(x: 0.014, y: 0.003, z: -0.072),
            onsetAngular: MotionVector(x: -0.571, y: 0.582, z: -0.052),
            recoveryDurationNanoseconds: 14_000_000
        )
    ).side == .right,
    "bundled side profile should tolerate the opposite acceleration polarity of a firm right tap"
)
require(
    bundledClassifier.classify(
        syntheticEvent(
            timestamp: 4,
            side: .unknown,
            dynamic: MotionVector(x: -0.004, y: -0.001, z: 0.086),
            angular: MotionVector(x: 8.384, y: -0.334, z: -1.080),
            onsetDynamic: MotionVector(x: 0, y: -0.004, z: 0.075),
            onsetAngular: MotionVector(x: 4.783, y: -2.165, z: -0.775),
            recoveryDurationNanoseconds: 6_200_000
        )
    ).side == .right,
    "bundled side profile should classify the high-gyro positive first-lobe right mode"
)
require(
    bundledClassifier.classify(
        syntheticEvent(
            timestamp: 4,
            side: .unknown,
            dynamic: MotionVector(x: -0.001, y: 0.004, z: -0.344),
            angular: MotionVector(x: 3.251, y: 2.618, z: -0.339),
            onsetDynamic: MotionVector(x: 0.001, y: -0.005, z: 0.051),
            onsetAngular: MotionVector(x: 2.458, y: 0.848, z: 0.576),
            recoveryDurationNanoseconds: 35_200_000
        )
    ).side == .left,
    "bundled side profile should classify the firm negative-lobe left mode"
)
require(
    bundledClassifier.classify(
        syntheticEvent(
            timestamp: 4,
            side: .unknown,
            dynamic: MotionVector(x: 0, y: 1, z: 0),
            angular: MotionVector(x: 0, y: 1, z: 0),
            onsetDynamic: MotionVector(x: 0, y: 1, z: 0),
            onsetAngular: MotionVector(x: 0, y: 1, z: 0),
            recoveryDurationNanoseconds: 10_000_000
        )
    ).side == .unknown,
    "bundled side profile should keep non-directional events unknown"
)
require(
    bundledClassifier.classify(
        syntheticEvent(
            timestamp: 4,
            side: .unknown,
            dynamic: MotionVector(x: 0.12, y: 0.04, z: 0.01),
            angular: MotionVector(x: 3.5, y: 0, z: 0)
        )
    ).side == .left,
    "bundled side profile should classify a low-vertical palm-rest impulse"
)
require(
    bundledClassifier.classify(
        syntheticEvent(
            timestamp: 4,
            side: .unknown,
            dynamic: MotionVector(x: -0.12, y: 0.03, z: 0.01),
            angular: MotionVector(x: 7, y: 0, z: 0)
        )
    ).side == .right,
    "bundled side profile should classify a stronger-rotation palm-rest impulse"
)
require(
    bundledClassifier.classify(
        syntheticEvent(
            timestamp: 4,
            side: .unknown,
            dynamic: MotionVector(x: 0.12, y: 0.04, z: 0.01),
            angular: MotionVector(x: 0.2, y: 0, z: 0)
        )
    ).side == .unknown,
    "bundled side profile should keep low-gyro palm-rest motion unknown"
)
let leftClassification = sideClassifier.classify(
    syntheticEvent(
        timestamp: 4,
        side: .unknown,
        dynamic: MotionVector(x: 1, y: 0, z: 0),
        angular: MotionVector(x: 0, y: 1, z: 0),
        onsetDynamic: MotionVector(x: 0.9, y: 0.4, z: 0),
        onsetAngular: MotionVector(x: 0, y: 0.8, z: 0.6),
        recoveryDurationNanoseconds: 50_000_000
    )
)
require(leftClassification.side == .left, "left side profile classified the wrong side")
let ambiguousClassification = sideClassifier.classify(
    syntheticEvent(
        timestamp: 4,
        side: .unknown,
        dynamic: MotionVector(x: 0, y: 1, z: 0),
        angular: MotionVector(x: 1, y: 0, z: 0),
        onsetDynamic: MotionVector(x: 0, y: 1, z: 0),
        onsetAngular: MotionVector(x: 1, y: 0, z: 0),
        recoveryDurationNanoseconds: 75_000_000
    )
)
require(ambiguousClassification.side == .unknown, "ambiguous side features should remain unknown")
let legacyProfileData = Data(
    """
    {
      "calibratedAtNanoseconds": 3,
      "left": {
        "sampleCount": 3,
        "onsetDynamicAccelerationDirection": {"x": 1, "y": 0, "z": 0},
        "dynamicAccelerationDirection": {"x": 1, "y": 0, "z": 0},
        "onsetAngularRateDirection": {"x": 0, "y": 1, "z": 0},
        "angularRateDirection": {"x": 0, "y": 1, "z": 0}
      },
      "right": {
        "sampleCount": 3,
        "onsetDynamicAccelerationDirection": {"x": -1, "y": 0, "z": 0},
        "dynamicAccelerationDirection": {"x": -1, "y": 0, "z": 0},
        "onsetAngularRateDirection": {"x": 0, "y": -1, "z": 0},
        "angularRateDirection": {"x": 0, "y": -1, "z": 0}
      }
    }
    """.utf8
)
let decodedLegacyProfile = try! JSONDecoder().decode(
    TapSideProfile.self,
    from: legacyProfileData
)
require(
    decodedLegacyProfile.left?.recoveryDurationSeconds == 0,
    "legacy side profiles should default recovery duration to zero"
)
let classifiedDetailedEvent = syntheticEvent(
    timestamp: 5,
    side: .unknown,
    dynamic: MotionVector(x: 1, y: 0, z: 0),
    angular: MotionVector(x: 0, y: 1, z: 0),
    onsetDynamic: MotionVector(x: 0.7, y: 0.7, z: 0),
    onsetAngular: MotionVector(x: 0, y: 0.7, z: 0.7),
    recoveryDurationNanoseconds: 75_000_000
).applying(leftClassification)
require(
    classifiedDetailedEvent.onsetDynamicAcceleration
        == MotionVector(x: 0.7, y: 0.7, z: 0),
    "side classification should preserve onset acceleration"
)
require(
    classifiedDetailedEvent.recoveryDurationNanoseconds == 75_000_000,
    "side classification should preserve recovery duration"
)

var guidedCalibration = GuidedSideCalibration(requiredSamplesPerSide: 3)
guidedCalibration.start()
require(
    guidedCalibration.phase == .preparing,
    "guided calibration should begin with a quiet preparation phase"
)
guidedCalibration.markCalibrationComplete()
require(
    guidedCalibration.phase == .left,
    "guided calibration should prompt for the left side first"
)
for index in 0..<3 {
    guidedCalibration.add(
        event: syntheticEvent(
            timestamp: UInt64(10 + index),
            side: .unknown,
            dynamic: MotionVector(x: 1, y: 0, z: 0),
            angular: MotionVector(x: 0, y: 1, z: 0),
            onsetDynamic: MotionVector(x: 0.9, y: 0.4, z: 0),
            onsetAngular: MotionVector(x: 0, y: 0.8, z: 0.6),
            recoveryDurationNanoseconds: 50_000_000
        )
    )
}
require(
    guidedCalibration.phase == .right,
    "guided calibration should switch to the right prompt after left samples"
)
for index in 0..<3 {
    guidedCalibration.add(
        event: syntheticEvent(
            timestamp: UInt64(20 + index),
            side: .unknown,
            dynamic: MotionVector(x: -1, y: 0, z: 0),
            angular: MotionVector(x: 0, y: -1, z: 0),
            onsetDynamic: MotionVector(x: -0.9, y: -0.4, z: 0),
            onsetAngular: MotionVector(x: 0, y: -0.8, z: -0.6),
            recoveryDurationNanoseconds: 100_000_000
        )
    )
}
require(guidedCalibration.phase == .complete, "guided calibration should complete after both sides")
require(guidedCalibration.profile?.isUsable == true, "guided calibration should produce a usable profile")

let firstTap = syntheticEvent(
    timestamp: 1_000_000_000,
    side: .left,
    dynamic: MotionVector(x: 1, y: 0, z: 0),
    angular: MotionVector(x: 0, y: 1, z: 0)
)
var singleTapAggregator = TapSequenceAggregator()
require(singleTapAggregator.process(firstTap) == nil, "single tap should wait for grouping")
let singleGesture = singleTapAggregator.flush(at: 1_500_000_000)
require(singleGesture?.tapCount == 1, "one tap should flush as a one-tap gesture")
require(singleGesture?.side == .left, "one-tap gesture lost its side")

let secondTap = syntheticEvent(
    timestamp: 1_200_000_000,
    side: .left,
    dynamic: MotionVector(x: 1, y: 0, z: 0),
    angular: MotionVector(x: 0, y: 1, z: 0)
)
var doubleTapAggregator = TapSequenceAggregator()
require(doubleTapAggregator.process(firstTap) == nil, "double tap first event should wait")
require(doubleTapAggregator.process(secondTap) == nil, "double tap second event should remain pending")
let doubleGesture = doubleTapAggregator.flush(at: 1_700_000_000)
require(doubleGesture?.tapCount == 2, "two taps should group into one gesture")
require(doubleGesture?.side == .left, "two-tap gesture lost its side")

let thirdTap = syntheticEvent(
    timestamp: 1_400_000_000,
    side: .left,
    dynamic: MotionVector(x: 1, y: 0, z: 0),
    angular: MotionVector(x: 0, y: 1, z: 0)
)
var sequenceAggregator = TapSequenceAggregator()
require(sequenceAggregator.process(firstTap) == nil, "first tap should wait for grouping")
require(sequenceAggregator.process(secondTap) == nil, "second tap should remain pending")
require(sequenceAggregator.process(thirdTap) == nil, "third tap should remain pending")
let groupedGesture = sequenceAggregator.flush(at: 2_000_000_000)
require(groupedGesture?.tapCount == 3, "three taps should group into one gesture")
require(groupedGesture?.side == .left, "grouped gesture lost its side")

let strongRightTap = syntheticEvent(
    timestamp: 2_000_000_000,
    side: .right,
    dynamic: MotionVector(x: -1, y: 0, z: 0),
    angular: .zero,
    confidence: 0.9
)
let weakLeftTap = syntheticEvent(
    timestamp: 2_180_000_000,
    side: .left,
    dynamic: MotionVector(x: 1, y: 0, z: 0),
    angular: .zero,
    confidence: 0.3
)
var jitteredDoubleAggregator = TapSequenceAggregator()
require(
    jitteredDoubleAggregator.process(strongRightTap) == nil,
    "jittered double first event should wait"
)
require(
    jitteredDoubleAggregator.process(weakLeftTap) == nil,
    "a side-label fluctuation should not split a timed double tap"
)
let jitteredDouble = jitteredDoubleAggregator.flush(at: 2_700_000_000)
require(jitteredDouble?.tapCount == 2, "side jitter should still produce a double tap")
require(
    jitteredDouble?.side == .right,
    "a tied double tap should use the stronger side classification"
)

let unknownTap = syntheticEvent(
    timestamp: 2_180_000_000,
    side: .unknown,
    dynamic: .zero,
    angular: .zero,
    confidence: 0.9
)
let rightPlusUnknown = TapGesture(events: [strongRightTap, unknownTap])
require(
    rightPlusUnknown.side == .right,
    "one ambiguous event should not erase a known side in a multi-tap gesture"
)

let secondStrongRightTap = syntheticEvent(
    timestamp: 2_360_000_000,
    side: .right,
    dynamic: MotionVector(x: -1, y: 0, z: 0),
    angular: .zero,
    confidence: 0.8
)
let majorityRightTriple = TapGesture(
    events: [strongRightTap, weakLeftTap, secondStrongRightTap]
)
require(
    majorityRightTriple.side == .right,
    "a three-tap gesture should resolve one inconsistent side by majority"
)

var recognitionSession = RecognitionSession(
    calibrationSeconds: 0.1,
    sensitivity: .high
)
for index in 0..<10 {
    let timestamp = UInt64(index) * 10_000_000
    _ = recognitionSession.process(
        MotionSample(
            timestampNanoseconds: timestamp,
            channel: .accelerometer,
            vector: MotionVector(x: 0, y: 0, z: -1)
        )
    )
    _ = recognitionSession.process(
        MotionSample(
            timestampNanoseconds: timestamp,
            channel: .gyroscope,
            vector: .zero
        )
    )
}
let calibratedUpdate = recognitionSession.process(
    MotionSample(
        timestampNanoseconds: 100_000_000,
        channel: .accelerometer,
        vector: MotionVector(x: 0, y: 0, z: -1)
    )
)
require(
    calibratedUpdate.calibrationProfile?.isUsable == true,
    "recognition session should publish a usable calibration profile"
)
_ = recognitionSession.process(
    MotionSample(
        timestampNanoseconds: 110_000_000,
        channel: .gyroscope,
        vector: .zero
    )
)
_ = recognitionSession.process(
    MotionSample(
        timestampNanoseconds: 200_000_000,
        channel: .accelerometer,
        vector: MotionVector(x: 0, y: 0, z: -1)
    )
)
_ = recognitionSession.process(
    MotionSample(
        timestampNanoseconds: 210_000_000,
        channel: .accelerometer,
        vector: MotionVector(x: 0.30, y: 0, z: -1)
    )
)
let sessionTap = recognitionSession.process(
    MotionSample(
        timestampNanoseconds: 260_000_000,
        channel: .accelerometer,
        vector: MotionVector(x: 0, y: 0, z: -1)
    )
)
require(sessionTap.tapEvent != nil, "recognition session should emit a live tap candidate")
let flushedSessionGesture = recognitionSession.process(
    MotionSample(
        timestampNanoseconds: 800_000_000,
        channel: .gyroscope,
        vector: .zero
    )
)
require(
    flushedSessionGesture.completedGestures.first?.tapCount == 1,
    "recognition session should flush a single-tap gesture after the grouping window"
)

print("TapProbeCoreCheck: parser checks passed")
print("TapProbeCoreCheck: calibration, side classifier, guided calibration, sequence, and app-session checks passed")
