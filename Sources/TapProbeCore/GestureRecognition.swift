import Foundation

public struct TapSideFeatures: Codable, Equatable, Sendable {
    public let onsetDynamicAccelerationDirection: MotionVector
    public let dynamicAccelerationDirection: MotionVector
    public let onsetAngularRateDirection: MotionVector
    public let angularRateDirection: MotionVector
    public let recoveryDurationSeconds: Double

    public init(
        onsetDynamicAccelerationDirection: MotionVector,
        dynamicAccelerationDirection: MotionVector,
        onsetAngularRateDirection: MotionVector,
        angularRateDirection: MotionVector,
        recoveryDurationSeconds: Double
    ) {
        self.onsetDynamicAccelerationDirection = onsetDynamicAccelerationDirection
        self.dynamicAccelerationDirection = dynamicAccelerationDirection
        self.onsetAngularRateDirection = onsetAngularRateDirection
        self.angularRateDirection = angularRateDirection
        self.recoveryDurationSeconds = recoveryDurationSeconds
    }

    public init(event: TapEvent) {
        self.init(
            onsetDynamicAccelerationDirection: Self.normalized(event.onsetDynamicAcceleration),
            dynamicAccelerationDirection: Self.normalized(event.dynamicAcceleration),
            onsetAngularRateDirection: Self.normalized(event.onsetAngularRate),
            angularRateDirection: Self.normalized(event.angularRate),
            recoveryDurationSeconds: Double(event.recoveryDurationNanoseconds) / 1_000_000_000
        )
    }

    private static func normalized(_ vector: MotionVector) -> MotionVector {
        let magnitude = vector.magnitude
        guard magnitude > 0.000001 else {
            return .zero
        }
        return MotionVector(
            x: vector.x / magnitude,
            y: vector.y / magnitude,
            z: vector.z / magnitude
        )
    }

    fileprivate static func scaled(_ vector: MotionVector, by scalar: Double) -> MotionVector {
        MotionVector(
            x: vector.x * scalar,
            y: vector.y * scalar,
            z: vector.z * scalar
        )
    }

    fileprivate static func distance(_ lhs: TapSideFeatures, _ rhs: TapSideFeatures) -> Double {
        let onsetAccelerationDelta = lhs.onsetDynamicAccelerationDirection
            - rhs.onsetDynamicAccelerationDirection
        let accelerationDelta = lhs.dynamicAccelerationDirection - rhs.dynamicAccelerationDirection
        let onsetAngularDelta = lhs.onsetAngularRateDirection - rhs.onsetAngularRateDirection
        let angularDelta = lhs.angularRateDirection - rhs.angularRateDirection
        let recoveryDelta = (lhs.recoveryDurationSeconds - rhs.recoveryDurationSeconds) / 0.15
        return sqrt(
            onsetAccelerationDelta.x * onsetAccelerationDelta.x
                + onsetAccelerationDelta.y * onsetAccelerationDelta.y
                + onsetAccelerationDelta.z * onsetAccelerationDelta.z
                + accelerationDelta.x * accelerationDelta.x
                + accelerationDelta.y * accelerationDelta.y
                + accelerationDelta.z * accelerationDelta.z
                + onsetAngularDelta.x * onsetAngularDelta.x
                + onsetAngularDelta.y * onsetAngularDelta.y
                + onsetAngularDelta.z * onsetAngularDelta.z
                + angularDelta.x * angularDelta.x
                + angularDelta.y * angularDelta.y
                + angularDelta.z * angularDelta.z
                + recoveryDelta * recoveryDelta
        )
    }
}

public struct TapSideCentroid: Codable, Equatable, Sendable {
    public let sampleCount: Int
    public let onsetDynamicAccelerationDirection: MotionVector
    public let dynamicAccelerationDirection: MotionVector
    public let onsetAngularRateDirection: MotionVector
    public let angularRateDirection: MotionVector
    public let recoveryDurationSeconds: Double
    /// Individual calibrated examples let the classifier handle variation
    /// across a broad palm-rest zone instead of comparing every tap only with
    /// one averaged centroid. This is optional for old profile files.
    public let featureSamples: [TapSideFeatures]?

    public init(
        sampleCount: Int,
        onsetDynamicAccelerationDirection: MotionVector,
        dynamicAccelerationDirection: MotionVector,
        onsetAngularRateDirection: MotionVector,
        angularRateDirection: MotionVector,
        recoveryDurationSeconds: Double,
        featureSamples: [TapSideFeatures]? = nil
    ) {
        self.sampleCount = sampleCount
        self.onsetDynamicAccelerationDirection = onsetDynamicAccelerationDirection
        self.dynamicAccelerationDirection = dynamicAccelerationDirection
        self.onsetAngularRateDirection = onsetAngularRateDirection
        self.angularRateDirection = angularRateDirection
        self.recoveryDurationSeconds = recoveryDurationSeconds
        self.featureSamples = featureSamples
    }

    private enum CodingKeys: String, CodingKey {
        case sampleCount
        case onsetDynamicAccelerationDirection
        case dynamicAccelerationDirection
        case onsetAngularRateDirection
        case angularRateDirection
        case recoveryDurationSeconds
        case featureSamples
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.sampleCount = try container.decode(Int.self, forKey: .sampleCount)
        self.dynamicAccelerationDirection = try container.decode(
            MotionVector.self,
            forKey: .dynamicAccelerationDirection
        )
        self.angularRateDirection = try container.decode(
            MotionVector.self,
            forKey: .angularRateDirection
        )
        self.onsetDynamicAccelerationDirection = try container.decodeIfPresent(
            MotionVector.self,
            forKey: .onsetDynamicAccelerationDirection
        ) ?? dynamicAccelerationDirection
        self.onsetAngularRateDirection = try container.decodeIfPresent(
            MotionVector.self,
            forKey: .onsetAngularRateDirection
        ) ?? angularRateDirection
        self.recoveryDurationSeconds = try container.decodeIfPresent(
            Double.self,
            forKey: .recoveryDurationSeconds
        ) ?? 0
        self.featureSamples = try container.decodeIfPresent(
            [TapSideFeatures].self,
            forKey: .featureSamples
        )
    }
}

public struct TapSideProfile: Codable, Equatable, Sendable {
    public let left: TapSideCentroid?
    public let right: TapSideCentroid?
    public let calibratedAtNanoseconds: UInt64

    public init(
        left: TapSideCentroid?,
        right: TapSideCentroid?,
        calibratedAtNanoseconds: UInt64
    ) {
        self.left = left
        self.right = right
        self.calibratedAtNanoseconds = calibratedAtNanoseconds
    }

    public var isUsable: Bool {
        guard let left, let right else {
            return false
        }
        return left.sampleCount >= 3 && right.sampleCount >= 3
    }

    /// A conservative directional fallback for plug-and-play recognition on
    /// the development MacBook Air (Mac16,12).
    ///
    /// Flat-chassis captures showed that the useful fallback evidence is the
    /// relationship between the dominant vertical acceleration and the X-axis
    /// angular-rate response. Right impacts can ring with either acceleration
    /// polarity, so their acceleration centroid stays neutral. This is not a
    /// universal hardware claim: unknown or conflicting events still fail
    /// closed, and additional MacBook models need their own validated profile.
    public static let bundledDefault = TapSideProfile(
        left: TapSideCentroid(
            sampleCount: 3,
            onsetDynamicAccelerationDirection: .zero,
            dynamicAccelerationDirection: MotionVector(x: 0, y: 0, z: 1),
            onsetAngularRateDirection: .zero,
            angularRateDirection: MotionVector(x: -1, y: 0, z: 0),
            recoveryDurationSeconds: 0
        ),
        right: TapSideCentroid(
            sampleCount: 3,
            onsetDynamicAccelerationDirection: .zero,
            dynamicAccelerationDirection: .zero,
            onsetAngularRateDirection: .zero,
            angularRateDirection: MotionVector(x: 1, y: 0, z: 0),
            recoveryDurationSeconds: 0
        ),
        calibratedAtNanoseconds: 0
    )
}

public struct TapSideClassification: Codable, Equatable, Sendable {
    public let side: TapSide
    public let confidence: Double
    public let leftDistance: Double?
    public let rightDistance: Double?

    public init(
        side: TapSide,
        confidence: Double,
        leftDistance: Double?,
        rightDistance: Double?
    ) {
        self.side = side
        self.confidence = confidence
        self.leftDistance = leftDistance
        self.rightDistance = rightDistance
    }
}

public struct TapSideClassifier: Sendable {
    public let minimumSamplesPerSide: Int
    public let minimumDistanceMargin: Double

    private var usesBundledHardwareFallback = false
    private var leftCount = 0
    private var rightCount = 0
    private var leftOnsetDynamicSum = MotionVector.zero
    private var leftDynamicSum = MotionVector.zero
    private var leftOnsetAngularSum = MotionVector.zero
    private var leftAngularSum = MotionVector.zero
    private var leftRecoveryDurationSum = 0.0
    private var leftFeatureSamples: [TapSideFeatures] = []
    private var rightOnsetDynamicSum = MotionVector.zero
    private var rightDynamicSum = MotionVector.zero
    private var rightOnsetAngularSum = MotionVector.zero
    private var rightAngularSum = MotionVector.zero
    private var rightRecoveryDurationSum = 0.0
    private var rightFeatureSamples: [TapSideFeatures] = []

    public init(
        minimumSamplesPerSide: Int = 3,
        minimumDistanceMargin: Double = 0.15
    ) {
        precondition(minimumSamplesPerSide > 0)
        precondition(minimumDistanceMargin > 0 && minimumDistanceMargin < 1)
        self.minimumSamplesPerSide = minimumSamplesPerSide
        self.minimumDistanceMargin = minimumDistanceMargin
    }

    public init(
        profile: TapSideProfile,
        minimumSamplesPerSide: Int = 3,
        minimumDistanceMargin: Double = 0.15
    ) {
        self.init(
            minimumSamplesPerSide: minimumSamplesPerSide,
            minimumDistanceMargin: minimumDistanceMargin
        )
        if let left = profile.left {
            leftCount = left.sampleCount
            leftOnsetDynamicSum = TapSideFeatures.scaled(
                left.onsetDynamicAccelerationDirection,
                by: Double(left.sampleCount)
            )
            leftDynamicSum = TapSideFeatures.scaled(
                left.dynamicAccelerationDirection,
                by: Double(left.sampleCount)
            )
            leftOnsetAngularSum = TapSideFeatures.scaled(
                left.onsetAngularRateDirection,
                by: Double(left.sampleCount)
            )
            leftAngularSum = TapSideFeatures.scaled(
                left.angularRateDirection,
                by: Double(left.sampleCount)
            )
            leftRecoveryDurationSum = left.recoveryDurationSeconds * Double(left.sampleCount)
            leftFeatureSamples = left.featureSamples ?? []
        }
        if let right = profile.right {
            rightCount = right.sampleCount
            rightOnsetDynamicSum = TapSideFeatures.scaled(
                right.onsetDynamicAccelerationDirection,
                by: Double(right.sampleCount)
            )
            rightDynamicSum = TapSideFeatures.scaled(
                right.dynamicAccelerationDirection,
                by: Double(right.sampleCount)
            )
            rightOnsetAngularSum = TapSideFeatures.scaled(
                right.onsetAngularRateDirection,
                by: Double(right.sampleCount)
            )
            rightAngularSum = TapSideFeatures.scaled(
                right.angularRateDirection,
                by: Double(right.sampleCount)
            )
            rightRecoveryDurationSum = right.recoveryDurationSeconds * Double(right.sampleCount)
            rightFeatureSamples = right.featureSamples ?? []
        }
        usesBundledHardwareFallback = profile.calibratedAtNanoseconds == 0
    }

    public mutating func add(event: TapEvent, labeled side: TapSide) {
        let features = TapSideFeatures(event: event)
        switch side {
        case .left:
            leftCount += 1
            leftOnsetDynamicSum = leftOnsetDynamicSum
                + features.onsetDynamicAccelerationDirection
            leftDynamicSum = leftDynamicSum + features.dynamicAccelerationDirection
            leftOnsetAngularSum = leftOnsetAngularSum
                + features.onsetAngularRateDirection
            leftAngularSum = leftAngularSum + features.angularRateDirection
            leftRecoveryDurationSum += features.recoveryDurationSeconds
            leftFeatureSamples.append(features)
        case .right:
            rightCount += 1
            rightOnsetDynamicSum = rightOnsetDynamicSum
                + features.onsetDynamicAccelerationDirection
            rightDynamicSum = rightDynamicSum + features.dynamicAccelerationDirection
            rightOnsetAngularSum = rightOnsetAngularSum
                + features.onsetAngularRateDirection
            rightAngularSum = rightAngularSum + features.angularRateDirection
            rightRecoveryDurationSum += features.recoveryDurationSeconds
            rightFeatureSamples.append(features)
        case .unknown:
            break
        }
    }

    public var leftSampleCount: Int { leftCount }
    public var rightSampleCount: Int { rightCount }

    public func makeProfile(calibratedAtNanoseconds: UInt64) -> TapSideProfile {
        TapSideProfile(
            left: makeCentroid(
                count: leftCount,
                onsetDynamicSum: leftOnsetDynamicSum,
                dynamicSum: leftDynamicSum,
                onsetAngularSum: leftOnsetAngularSum,
                angularSum: leftAngularSum,
                recoveryDurationSum: leftRecoveryDurationSum,
                featureSamples: leftFeatureSamples
            ),
            right: makeCentroid(
                count: rightCount,
                onsetDynamicSum: rightOnsetDynamicSum,
                dynamicSum: rightDynamicSum,
                onsetAngularSum: rightOnsetAngularSum,
                angularSum: rightAngularSum,
                recoveryDurationSum: rightRecoveryDurationSum,
                featureSamples: rightFeatureSamples
            ),
            calibratedAtNanoseconds: calibratedAtNanoseconds
        )
    }

    public func classify(_ event: TapEvent) -> TapSideClassification {
        if usesBundledHardwareFallback {
            return classifyBundledHardwareEvent(event)
        }

        guard let left = centroid(for: .left),
              let right = centroid(for: .right),
              left.sampleCount >= minimumSamplesPerSide,
              right.sampleCount >= minimumSamplesPerSide else {
            return TapSideClassification(
                side: .unknown,
                confidence: 0,
                leftDistance: nil,
                rightDistance: nil
            )
        }

        let eventFeatures = TapSideFeatures(event: event)
        let leftDistance = distance(
            eventFeatures,
            to: left,
            examples: leftFeatureSamples
        )
        let rightDistance = distance(
            eventFeatures,
            to: right,
            examples: rightFeatureSamples
        )
        return classification(leftDistance: leftDistance, rightDistance: rightDistance)
    }

    /// Mac16,12 fallback derived from same-posture flat-desk captures.
    ///
    /// Right-side impacts have two observable first-lobe modes at the current
    /// sensor threshold. Negative-Z events separate by onset gyro X; positive-Z
    /// events separate by peak angular-rate magnitude. Treating those modes as
    /// one centroid caused left taps to be labeled right and vice versa.
    private func classifyBundledHardwareEvent(_ event: TapEvent) -> TapSideClassification {
        let accelerationMagnitude = event.dynamicAcceleration.magnitude
        guard accelerationMagnitude > 0.000001 else {
            return TapSideClassification(
                side: .unknown,
                confidence: 0,
                leftDistance: nil,
                rightDistance: nil
            )
        }

        let normalizedPeakZ = event.dynamicAcceleration.z / accelerationMagnitude
        guard abs(normalizedPeakZ) >= 0.75 else {
            // Taps on the palm rests can transfer more motion through the
            // chassis plane than the older edge-tap fixtures. Use the same
            // measured gyro-magnitude boundary as the positive-Z mode when
            // there is enough side-axis rotational evidence; do not label a
            // flat, low-gyro event just to avoid unknown.
            let sideAxisRate = max(
                abs(event.onsetAngularRate.x),
                abs(event.angularRate.x)
            )
            guard sideAxisRate >= 0.5, event.peakAngularRateDps >= 0.5 else {
                return TapSideClassification(
                    side: .unknown,
                    confidence: 0,
                    leftDistance: nil,
                    rightDistance: nil
                )
            }
            return classification(
                leftDistance: abs(event.peakAngularRateDps - 3.5),
                rightDistance: abs(event.peakAngularRateDps - 7.0)
            )
        }

        if normalizedPeakZ < 0 {
            let onsetGyroX = event.onsetAngularRate.x
            return classification(
                leftDistance: abs(onsetGyroX - 2.5),
                rightDistance: abs(onsetGyroX + 0.5)
            )
        }

        return classification(
            leftDistance: abs(event.peakAngularRateDps - 3.5),
            rightDistance: abs(event.peakAngularRateDps - 7.0)
        )
    }

    private func classification(
        leftDistance: Double,
        rightDistance: Double
    ) -> TapSideClassification {
        let bestDistance = min(leftDistance, rightDistance)
        let otherDistance = max(leftDistance, rightDistance)
        let margin = (otherDistance - bestDistance) / max(otherDistance, 0.000001)

        guard margin >= minimumDistanceMargin else {
            return TapSideClassification(
                side: .unknown,
                confidence: margin,
                leftDistance: leftDistance,
                rightDistance: rightDistance
            )
        }

        return TapSideClassification(
            side: leftDistance < rightDistance ? .left : .right,
            confidence: min(1, margin),
            leftDistance: leftDistance,
            rightDistance: rightDistance
        )
    }

    private func makeCentroid(
        count: Int,
        onsetDynamicSum: MotionVector,
        dynamicSum: MotionVector,
        onsetAngularSum: MotionVector,
        angularSum: MotionVector,
        recoveryDurationSum: Double,
        featureSamples: [TapSideFeatures]
    ) -> TapSideCentroid? {
        guard count > 0 else {
            return nil
        }
        let divisor = Double(count)
        return TapSideCentroid(
            sampleCount: count,
            onsetDynamicAccelerationDirection: normalize(
                TapSideFeatures.scaled(onsetDynamicSum, by: 1 / divisor)
            ),
            dynamicAccelerationDirection: normalize(
                TapSideFeatures.scaled(dynamicSum, by: 1 / divisor)
            ),
            onsetAngularRateDirection: normalize(
                TapSideFeatures.scaled(onsetAngularSum, by: 1 / divisor)
            ),
            angularRateDirection: normalize(
                TapSideFeatures.scaled(angularSum, by: 1 / divisor)
            ),
            recoveryDurationSeconds: recoveryDurationSum / divisor,
            featureSamples: featureSamples.isEmpty ? nil : featureSamples
        )
    }

    private func centroid(for side: TapSide) -> TapSideCentroid? {
        makeCentroid(
            count: side == .left ? leftCount : rightCount,
            onsetDynamicSum: side == .left ? leftOnsetDynamicSum : rightOnsetDynamicSum,
            dynamicSum: side == .left ? leftDynamicSum : rightDynamicSum,
            onsetAngularSum: side == .left ? leftOnsetAngularSum : rightOnsetAngularSum,
            angularSum: side == .left ? leftAngularSum : rightAngularSum,
            recoveryDurationSum: side == .left
                ? leftRecoveryDurationSum
                : rightRecoveryDurationSum,
            featureSamples: side == .left
                ? leftFeatureSamples
                : rightFeatureSamples
        )
    }

    private func distance(
        _ event: TapSideFeatures,
        to centroid: TapSideCentroid,
        examples: [TapSideFeatures]
    ) -> Double {
        let centroidDistance = TapSideFeatures.distance(
            event,
            TapSideFeatures(
                onsetDynamicAccelerationDirection: centroid.onsetDynamicAccelerationDirection,
                dynamicAccelerationDirection: centroid.dynamicAccelerationDirection,
                onsetAngularRateDirection: centroid.onsetAngularRateDirection,
                angularRateDirection: centroid.angularRateDirection,
                recoveryDurationSeconds: centroid.recoveryDurationSeconds
            )
        )
        guard !examples.isEmpty else {
            return centroidDistance
        }
        return min(
            centroidDistance,
            examples.map { TapSideFeatures.distance(event, $0) }.min() ?? centroidDistance
        )
    }

    private func normalize(_ vector: MotionVector) -> MotionVector {
        let magnitude = vector.magnitude
        guard magnitude > 0.000001 else {
            return .zero
        }
        return MotionVector(
            x: vector.x / magnitude,
            y: vector.y / magnitude,
            z: vector.z / magnitude
        )
    }
}

public extension TapEvent {
    func applying(_ classification: TapSideClassification) -> TapEvent {
        TapEvent(
            timestampNanoseconds: timestampNanoseconds,
            side: classification.side,
            dynamicAcceleration: dynamicAcceleration,
            angularRate: angularRate,
            peakDynamicAccelerationG: peakDynamicAccelerationG,
            peakJerkGPerSample: peakJerkGPerSample,
            peakAngularRateDps: peakAngularRateDps,
            confidence: classification.side == .unknown
                ? confidence
                : min(confidence, max(0, classification.confidence)),
            onsetDynamicAcceleration: onsetDynamicAcceleration,
            onsetAngularRate: onsetAngularRate,
            recoveryDurationNanoseconds: recoveryDurationNanoseconds
        )
    }
}

public struct TapSequenceConfiguration: Codable, Equatable, Sendable {
    public var groupingWindowNanoseconds: UInt64
    public var maximumTapCount: Int

    public init(
        groupingWindowNanoseconds: UInt64 = 450_000_000,
        maximumTapCount: Int = 3
    ) {
        precondition(groupingWindowNanoseconds > 0)
        precondition(maximumTapCount > 0)
        self.groupingWindowNanoseconds = groupingWindowNanoseconds
        self.maximumTapCount = maximumTapCount
    }
}

public struct TapGesture: Codable, Equatable, Sendable {
    public let side: TapSide
    public let tapCount: Int
    public let firstTimestampNanoseconds: UInt64
    public let lastTimestampNanoseconds: UInt64
    public let confidence: Double
    public let events: [TapEvent]

    public init(events: [TapEvent]) {
        precondition(!events.isEmpty)
        self.side = Self.resolveSide(events)
        self.tapCount = events.count
        self.firstTimestampNanoseconds = events.first?.timestampNanoseconds ?? 0
        self.lastTimestampNanoseconds = events.last?.timestampNanoseconds ?? 0
        self.confidence = events.map(\.confidence).min() ?? 0
        self.events = events
    }

    private static func resolveSide(_ events: [TapEvent]) -> TapSide {
        let leftEvents = events.filter { $0.side == .left }
        let rightEvents = events.filter { $0.side == .right }

        if leftEvents.count != rightEvents.count {
            return leftEvents.count > rightEvents.count ? .left : .right
        }

        let leftConfidence = leftEvents.reduce(0) { $0 + $1.confidence }
        let rightConfidence = rightEvents.reduce(0) { $0 + $1.confidence }
        let totalConfidence = leftConfidence + rightConfidence
        guard totalConfidence > 0 else {
            return .unknown
        }

        let confidenceMargin = abs(leftConfidence - rightConfidence) / totalConfidence
        guard confidenceMargin >= 0.20 else {
            return .unknown
        }
        return leftConfidence > rightConfidence ? .left : .right
    }
}

public struct TapSequenceAggregator: Sendable {
    public let configuration: TapSequenceConfiguration
    private var pendingEvents: [TapEvent] = []

    public init(configuration: TapSequenceConfiguration = TapSequenceConfiguration()) {
        self.configuration = configuration
    }

    public var pendingTapCount: Int { pendingEvents.count }

    public mutating func process(_ event: TapEvent) -> TapGesture? {
        guard let lastEvent = pendingEvents.last else {
            pendingEvents = [event]
            return nil
        }

        let timeDelta = event.timestampNanoseconds >= lastEvent.timestampNanoseconds
            ? event.timestampNanoseconds - lastEvent.timestampNanoseconds
            : UInt64.max
        // Side classification can jitter between taps because each chassis
        // impulse rings differently. Group by timing first, then let
        // `TapGesture` resolve the side from all events in the sequence.
        let canJoin = timeDelta <= configuration.groupingWindowNanoseconds
            && pendingEvents.count < configuration.maximumTapCount

        guard canJoin else {
            let completed = TapGesture(events: pendingEvents)
            pendingEvents = [event]
            return completed
        }

        pendingEvents.append(event)
        return nil
    }

    public mutating func flush(at timestampNanoseconds: UInt64) -> TapGesture? {
        guard let lastEvent = pendingEvents.last,
              timestampNanoseconds >= lastEvent.timestampNanoseconds,
              timestampNanoseconds - lastEvent.timestampNanoseconds
                >= configuration.groupingWindowNanoseconds else {
            return nil
        }
        return flush()
    }

    public mutating func flush() -> TapGesture? {
        guard !pendingEvents.isEmpty else {
            return nil
        }
        let completed = TapGesture(events: pendingEvents)
        pendingEvents.removeAll(keepingCapacity: true)
        return completed
    }
}
