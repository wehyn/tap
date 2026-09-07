import Foundation

public struct MotionVector: Codable, Equatable, Sendable {
    public let x: Double
    public let y: Double
    public let z: Double

    public init(x: Double, y: Double, z: Double) {
        self.x = x
        self.y = y
        self.z = z
    }

    public static let zero = MotionVector(x: 0, y: 0, z: 0)

    public var magnitude: Double {
        sqrt(x * x + y * y + z * z)
    }

    public static func + (lhs: MotionVector, rhs: MotionVector) -> MotionVector {
        MotionVector(x: lhs.x + rhs.x, y: lhs.y + rhs.y, z: lhs.z + rhs.z)
    }

    public static func - (lhs: MotionVector, rhs: MotionVector) -> MotionVector {
        MotionVector(x: lhs.x - rhs.x, y: lhs.y - rhs.y, z: lhs.z - rhs.z)
    }
}

public struct MotionSample: Codable, Equatable, Sendable {
    public let timestampNanoseconds: UInt64
    public let channel: SensorChannel
    public let vector: MotionVector

    public init(
        timestampNanoseconds: UInt64,
        channel: SensorChannel,
        vector: MotionVector
    ) {
        self.timestampNanoseconds = timestampNanoseconds
        self.channel = channel
        self.vector = vector
    }

    public init(timestampNanoseconds: UInt64, parsed: ParsedReport) {
        self.init(
            timestampNanoseconds: timestampNanoseconds,
            channel: parsed.channel,
            vector: MotionVector(x: parsed.x, y: parsed.y, z: parsed.z)
        )
    }
}

public struct SensorStatistics: Codable, Equatable, Sendable {
    public let sampleCount: Int
    public let mean: MotionVector
    public let standardDeviation: MotionVector

    public init(
        sampleCount: Int,
        mean: MotionVector,
        standardDeviation: MotionVector
    ) {
        self.sampleCount = sampleCount
        self.mean = mean
        self.standardDeviation = standardDeviation
    }
}

public struct CalibrationProfile: Codable, Equatable, Sendable {
    public let accelerometer: SensorStatistics
    public let gyroscope: SensorStatistics
    public let calibratedAtNanoseconds: UInt64

    public init(
        accelerometer: SensorStatistics,
        gyroscope: SensorStatistics,
        calibratedAtNanoseconds: UInt64
    ) {
        self.accelerometer = accelerometer
        self.gyroscope = gyroscope
        self.calibratedAtNanoseconds = calibratedAtNanoseconds
    }

    public var isUsable: Bool {
        accelerometer.sampleCount > 0 && gyroscope.sampleCount > 0
    }
}

private struct RunningStatistics: Sendable {
    private(set) var count = 0
    private var sum = MotionVector.zero
    private var sumSquares = MotionVector.zero

    mutating func add(_ vector: MotionVector) {
        count += 1
        sum = sum + vector
        sumSquares = MotionVector(
            x: sumSquares.x + vector.x * vector.x,
            y: sumSquares.y + vector.y * vector.y,
            z: sumSquares.z + vector.z * vector.z
        )
    }

    func makeSensorStatistics() -> SensorStatistics {
        guard count > 0 else {
            return SensorStatistics(
                sampleCount: 0,
                mean: .zero,
                standardDeviation: .zero
            )
        }

        let divisor = Double(count)
        let mean = MotionVector(
            x: sum.x / divisor,
            y: sum.y / divisor,
            z: sum.z / divisor
        )
        let variance = MotionVector(
            x: max(0, sumSquares.x / divisor - mean.x * mean.x),
            y: max(0, sumSquares.y / divisor - mean.y * mean.y),
            z: max(0, sumSquares.z / divisor - mean.z * mean.z)
        )
        return SensorStatistics(
            sampleCount: count,
            mean: mean,
            standardDeviation: MotionVector(
                x: sqrt(variance.x),
                y: sqrt(variance.y),
                z: sqrt(variance.z)
            )
        )
    }
}

public struct MotionCalibrator: Sendable {
    private var accelerometer = RunningStatistics()
    private var gyroscope = RunningStatistics()

    public init() {}

    public mutating func add(_ sample: MotionSample) {
        switch sample.channel {
        case .accelerometer:
            accelerometer.add(sample.vector)
        case .gyroscope:
            gyroscope.add(sample.vector)
        }
    }

    public var accelerometerSampleCount: Int { accelerometer.count }
    public var gyroscopeSampleCount: Int { gyroscope.count }

    public func makeProfile(calibratedAtNanoseconds: UInt64) -> CalibrationProfile {
        CalibrationProfile(
            accelerometer: accelerometer.makeSensorStatistics(),
            gyroscope: gyroscope.makeSensorStatistics(),
            calibratedAtNanoseconds: calibratedAtNanoseconds
        )
    }
}

public enum TapSensitivity: String, Codable, CaseIterable, Sendable {
    case low
    case medium
    case high

    /// Starting points for the development MacBook. Lower acceleration
    /// thresholds are more sensitive, but are more likely to accept normal
    /// chassis motion. The adaptive calibration noise floor still applies.
    public var minimumDynamicAccelerationG: Double {
        switch self {
        case .low:
            return 0.24
        case .medium:
            return 0.18
        case .high:
            return 0.05
        }
    }

    public var displayName: String {
        rawValue.capitalized
    }
}

public struct TapDetectorConfiguration: Codable, Equatable, Sendable {
    public var minimumDynamicAccelerationG: Double
    public var minimumJerkGPerSample: Double
    public var minimumAngularRateDps: Double
    public var refractoryNanoseconds: UInt64
    public var recoveryAccelerationFactor: Double
    public var maximumImpactWindowNanoseconds: UInt64

    public init(
        minimumDynamicAccelerationG: Double = 0.18,
        minimumJerkGPerSample: Double = 0.02,
        minimumAngularRateDps: Double = 8.0,
        refractoryNanoseconds: UInt64 = 120_000_000,
        recoveryAccelerationFactor: Double = 0.75,
        maximumImpactWindowNanoseconds: UInt64 = 150_000_000
    ) {
        precondition(minimumDynamicAccelerationG > 0)
        precondition(minimumJerkGPerSample > 0)
        precondition(minimumAngularRateDps >= 0)
        precondition(refractoryNanoseconds > 0)
        precondition(recoveryAccelerationFactor > 0 && recoveryAccelerationFactor < 1)
        precondition(maximumImpactWindowNanoseconds > 0)
        self.minimumDynamicAccelerationG = minimumDynamicAccelerationG
        self.minimumJerkGPerSample = minimumJerkGPerSample
        self.minimumAngularRateDps = minimumAngularRateDps
        self.refractoryNanoseconds = refractoryNanoseconds
        self.recoveryAccelerationFactor = recoveryAccelerationFactor
        self.maximumImpactWindowNanoseconds = maximumImpactWindowNanoseconds
    }

    public init(
        sensitivity: TapSensitivity,
        minimumJerkGPerSample: Double = 0.02,
        minimumAngularRateDps: Double = 8.0,
        refractoryNanoseconds: UInt64 = 120_000_000,
        recoveryAccelerationFactor: Double = 0.75,
        maximumImpactWindowNanoseconds: UInt64 = 150_000_000
    ) {
        self.init(
            minimumDynamicAccelerationG: sensitivity.minimumDynamicAccelerationG,
            minimumJerkGPerSample: minimumJerkGPerSample,
            minimumAngularRateDps: minimumAngularRateDps,
            refractoryNanoseconds: refractoryNanoseconds,
            recoveryAccelerationFactor: recoveryAccelerationFactor,
            maximumImpactWindowNanoseconds: maximumImpactWindowNanoseconds
        )
    }
}

public enum TapSide: String, Codable, CaseIterable, Sendable {
    case left
    case right
    case unknown
}

public struct TapEvent: Codable, Equatable, Sendable {
    public let timestampNanoseconds: UInt64
    public let side: TapSide
    public let onsetDynamicAcceleration: MotionVector
    public let dynamicAcceleration: MotionVector
    public let onsetAngularRate: MotionVector
    public let angularRate: MotionVector
    public let peakDynamicAccelerationG: Double
    public let peakJerkGPerSample: Double
    public let peakAngularRateDps: Double
    public let recoveryDurationNanoseconds: UInt64
    public let confidence: Double

    public init(
        timestampNanoseconds: UInt64,
        side: TapSide,
        dynamicAcceleration: MotionVector,
        angularRate: MotionVector,
        peakDynamicAccelerationG: Double,
        peakJerkGPerSample: Double,
        peakAngularRateDps: Double,
        confidence: Double,
        onsetDynamicAcceleration: MotionVector? = nil,
        onsetAngularRate: MotionVector? = nil,
        recoveryDurationNanoseconds: UInt64 = 0
    ) {
        self.timestampNanoseconds = timestampNanoseconds
        self.side = side
        self.onsetDynamicAcceleration = onsetDynamicAcceleration ?? dynamicAcceleration
        self.dynamicAcceleration = dynamicAcceleration
        self.onsetAngularRate = onsetAngularRate ?? angularRate
        self.angularRate = angularRate
        self.peakDynamicAccelerationG = peakDynamicAccelerationG
        self.peakJerkGPerSample = peakJerkGPerSample
        self.peakAngularRateDps = peakAngularRateDps
        self.recoveryDurationNanoseconds = recoveryDurationNanoseconds
        self.confidence = confidence
    }
}

public struct TapDetector: Sendable {
    private struct PendingCandidate: Sendable {
        let startTimestampNanoseconds: UInt64
        var peakTimestampNanoseconds: UInt64
        let onsetDynamicAcceleration: MotionVector
        let onsetAngularRate: MotionVector
        var dynamicAcceleration: MotionVector
        var angularRate: MotionVector
        var peakDynamicAccelerationG: Double
        var peakJerkGPerSample: Double
        var peakAngularRateDps: Double
    }

    public let calibration: CalibrationProfile
    public let configuration: TapDetectorConfiguration

    private var lastAngularRate = MotionVector.zero
    private var lastDynamicAcceleration: MotionVector?
    private var candidateArmed = true
    private var pendingCandidate: PendingCandidate?
    private var lastEventTimestamp: UInt64?

    public init(
        calibration: CalibrationProfile,
        configuration: TapDetectorConfiguration = TapDetectorConfiguration()
    ) {
        self.calibration = calibration
        self.configuration = configuration
    }

    private var effectiveMinimumDynamicAccelerationG: Double {
        // A calibration made while the chassis is moving should fail closed
        // instead of turning that motion into a stream of tap candidates.
        // Keep the user threshold as the floor, then raise it from the
        // measured quiet-window noise when that noise is unusually high.
        max(
            configuration.minimumDynamicAccelerationG,
            calibration.accelerometer.standardDeviation.magnitude * 4
        )
    }

    public mutating func process(_ sample: MotionSample) -> TapEvent? {
        switch sample.channel {
        case .gyroscope:
            lastAngularRate = sample.vector - calibration.gyroscope.mean
            return nil
        case .accelerometer:
            let dynamicAcceleration = sample.vector - calibration.accelerometer.mean
            let dynamicMagnitude = dynamicAcceleration.magnitude
            guard let lastDynamicAcceleration else {
                self.lastDynamicAcceleration = dynamicAcceleration
                return nil
            }
            let previousDynamicMagnitude = lastDynamicAcceleration.magnitude
            let jerk = dynamicAcceleration - lastDynamicAcceleration
            self.lastDynamicAcceleration = dynamicAcceleration
            let jerkMagnitude = jerk.magnitude
            let minimumDynamicAccelerationG = effectiveMinimumDynamicAccelerationG

            let angularMagnitude = lastAngularRate.magnitude

            if var pendingCandidate {
                if dynamicMagnitude > pendingCandidate.peakDynamicAccelerationG {
                    pendingCandidate.peakDynamicAccelerationG = dynamicMagnitude
                    pendingCandidate.dynamicAcceleration = dynamicAcceleration
                    pendingCandidate.peakTimestampNanoseconds = sample.timestampNanoseconds
                }
                pendingCandidate.peakJerkGPerSample = max(
                    pendingCandidate.peakJerkGPerSample,
                    jerkMagnitude
                )
                if angularMagnitude > pendingCandidate.peakAngularRateDps {
                    pendingCandidate.peakAngularRateDps = angularMagnitude
                    pendingCandidate.angularRate = lastAngularRate
                }

                let elapsed = sample.timestampNanoseconds >= pendingCandidate.startTimestampNanoseconds
                    ? sample.timestampNanoseconds - pendingCandidate.startTimestampNanoseconds
                    : 0
                if elapsed > configuration.maximumImpactWindowNanoseconds {
                    // A sustained movement can leave the candidate pending
                    // until the impact window expires. If the signal has at
                    // least fallen back below the rising-edge threshold,
                    // allow the next real tap to arm without requiring the
                    // much stricter deep-recovery level first.
                    self.pendingCandidate = nil
                    candidateArmed = dynamicMagnitude < minimumDynamicAccelerationG
                    return nil
                }

                let recoveryThreshold = minimumDynamicAccelerationG
                    * configuration.recoveryAccelerationFactor
                guard dynamicMagnitude <= recoveryThreshold else {
                    self.pendingCandidate = pendingCandidate
                    return nil
                }

                self.pendingCandidate = nil
                candidateArmed = true

                let recoveryDurationNanoseconds = sample.timestampNanoseconds
                    - pendingCandidate.startTimestampNanoseconds
                // At the lowest threshold, a real palm-rest tap can be
                // spread across several samples of the ~800 Hz stream. Its
                // consecutive-sample jerk is lower than the normal sharp
                // impulse floor, but a short rise-and-recover pulse is still
                // useful evidence. Keep this path explicitly opt-in through
                // the low threshold and the short recovery bound so ordinary
                // sustained motion continues to fail closed.
                let lightImpulseEvidence = minimumDynamicAccelerationG <= 0.03
                    && pendingCandidate.peakDynamicAccelerationG
                        >= minimumDynamicAccelerationG * 1.25
                    && pendingCandidate.peakJerkGPerSample
                        >= configuration.minimumJerkGPerSample * 0.25
                    && recoveryDurationNanoseconds <= 80_000_000

                guard pendingCandidate.peakJerkGPerSample
                        >= configuration.minimumJerkGPerSample
                        || lightImpulseEvidence else {
                    return nil
                }

                // Gyro evidence supports a real acceleration impulse; it is
                // not sufficient by itself because ordinary chassis rotation
                // can produce large angular-rate readings.
                guard pendingCandidate.peakAngularRateDps >= configuration.minimumAngularRateDps
                        || pendingCandidate.peakJerkGPerSample
                            >= configuration.minimumJerkGPerSample * 1.5
                        || lightImpulseEvidence else {
                    return nil
                }

                if let lastEventTimestamp,
                   pendingCandidate.peakTimestampNanoseconds
                        < lastEventTimestamp + configuration.refractoryNanoseconds {
                    return nil
                }

                let accelerationConfidence = pendingCandidate.peakDynamicAccelerationG
                    / (minimumDynamicAccelerationG * 2)
                let jerkConfidence = pendingCandidate.peakJerkGPerSample
                    / (configuration.minimumJerkGPerSample * 2)
                let angularConfidence = configuration.minimumAngularRateDps > 0
                    ? pendingCandidate.peakAngularRateDps
                        / (configuration.minimumAngularRateDps * 2)
                    : 0
                let confidence = min(
                    1,
                    max(accelerationConfidence, max(jerkConfidence, angularConfidence))
                )
                lastEventTimestamp = pendingCandidate.peakTimestampNanoseconds

                return TapEvent(
                    timestampNanoseconds: pendingCandidate.peakTimestampNanoseconds,
                    side: .unknown,
                    dynamicAcceleration: pendingCandidate.dynamicAcceleration,
                    angularRate: pendingCandidate.angularRate,
                    peakDynamicAccelerationG: pendingCandidate.peakDynamicAccelerationG,
                    peakJerkGPerSample: pendingCandidate.peakJerkGPerSample,
                    peakAngularRateDps: pendingCandidate.peakAngularRateDps,
                    confidence: confidence,
                    onsetDynamicAcceleration: pendingCandidate.onsetDynamicAcceleration,
                    onsetAngularRate: pendingCandidate.onsetAngularRate,
                    recoveryDurationNanoseconds: recoveryDurationNanoseconds
                )
            }

            let recoveryThreshold = minimumDynamicAccelerationG
                * configuration.recoveryAccelerationFactor
            if dynamicMagnitude <= recoveryThreshold {
                candidateArmed = true
            }

            guard dynamicMagnitude >= minimumDynamicAccelerationG else {
                return nil
            }

            // Only evaluate the rising edge of an impulse. A chassis tilt or
            // sustained vibration can remain above the threshold for many
            // samples; it must not generate a candidate on every gyro update.
            guard candidateArmed,
                  previousDynamicMagnitude < minimumDynamicAccelerationG else {
                return nil
            }
            candidateArmed = false
            pendingCandidate = PendingCandidate(
                startTimestampNanoseconds: sample.timestampNanoseconds,
                peakTimestampNanoseconds: sample.timestampNanoseconds,
                onsetDynamicAcceleration: dynamicAcceleration,
                onsetAngularRate: lastAngularRate,
                dynamicAcceleration: dynamicAcceleration,
                angularRate: lastAngularRate,
                peakDynamicAccelerationG: dynamicMagnitude,
                peakJerkGPerSample: jerkMagnitude,
                peakAngularRateDps: angularMagnitude
            )
            return nil
        }
    }
}

public extension TraceRecord {
    var motionSample: MotionSample {
        MotionSample(
            timestampNanoseconds: timestampNanoseconds,
            channel: channel,
            vector: MotionVector(x: x, y: y, z: z)
        )
    }
}
