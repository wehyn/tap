import Foundation

public struct RecognitionUpdate: Sendable {
    public let calibrationProfile: CalibrationProfile?
    public let calibrationProgress: Double
    public let tapEvent: TapEvent?
    public let completedGestures: [TapGesture]

    public init(
        calibrationProfile: CalibrationProfile? = nil,
        calibrationProgress: Double,
        tapEvent: TapEvent? = nil,
        completedGestures: [TapGesture] = []
    ) {
        self.calibrationProfile = calibrationProfile
        self.calibrationProgress = calibrationProgress
        self.tapEvent = tapEvent
        self.completedGestures = completedGestures
    }
}

/// Thread-safe orchestration of calibration, candidate detection, side
/// classification, and gesture grouping for the product app.
public final class RecognitionSession: @unchecked Sendable {
    public let calibrationSeconds: TimeInterval
    public let sensitivity: TapSensitivity
    public let thresholdG: Double

    private let calibrationDurationNanoseconds: UInt64
    private let sideProfile: TapSideProfile?
    private let detectorConfiguration: TapDetectorConfiguration
    private let sequenceConfiguration: TapSequenceConfiguration
    private let lock = NSLock()

    private var calibrator = MotionCalibrator()
    private var calibrationStartNanoseconds: UInt64?
    private var detector: TapDetector?
    private var sideClassifier: TapSideClassifier?
    private var sequenceAggregator: TapSequenceAggregator?
    private var latestCalibrationProfile: CalibrationProfile?
    private var latestProgress = 0.0

    public init(
        calibrationSeconds: TimeInterval = 2,
        sensitivity: TapSensitivity = .medium,
        thresholdG: Double? = nil,
        sideProfile: TapSideProfile? = nil,
        groupingWindowNanoseconds: UInt64 = 450_000_000,
        cooldownNanoseconds: UInt64 = 120_000_000
    ) {
        precondition(calibrationSeconds > 0)
        precondition(groupingWindowNanoseconds > 0)
        precondition(cooldownNanoseconds > 0)

        self.calibrationSeconds = calibrationSeconds
        self.sensitivity = sensitivity
        self.thresholdG = thresholdG ?? sensitivity.minimumDynamicAccelerationG
        calibrationDurationNanoseconds = UInt64(calibrationSeconds * 1_000_000_000)
        self.sideProfile = sideProfile
        detectorConfiguration = TapDetectorConfiguration(
            minimumDynamicAccelerationG: self.thresholdG,
            refractoryNanoseconds: cooldownNanoseconds
        )
        sequenceConfiguration = TapSequenceConfiguration(
            groupingWindowNanoseconds: groupingWindowNanoseconds
        )
        sideClassifier = sideProfile.map { TapSideClassifier(profile: $0) }
        sequenceAggregator = TapSequenceAggregator(configuration: sequenceConfiguration)
    }

    public func process(_ sample: MotionSample) -> RecognitionUpdate {
        lock.lock()
        defer { lock.unlock() }

        if var sequenceAggregator {
            let expiredGesture = sequenceAggregator.flush(at: sample.timestampNanoseconds)
            self.sequenceAggregator = sequenceAggregator
            if detector != nil {
                return processCalibratedSample(
                    sample,
                    alreadyCompletedGesture: expiredGesture
                )
            }
            if let expiredGesture {
                return RecognitionUpdate(
                    calibrationProgress: latestProgress,
                    completedGestures: [expiredGesture]
                )
            }
        }

        guard let detector else {
            return processCalibrationSample(sample)
        }

        self.detector = detector
        return processCalibratedSample(sample, alreadyCompletedGesture: nil)
    }

    public func flushGesture() -> TapGesture? {
        lock.lock()
        defer { lock.unlock() }
        return sequenceAggregator?.flush()
    }

    public func reset() {
        lock.lock()
        defer { lock.unlock() }
        calibrator = MotionCalibrator()
        calibrationStartNanoseconds = nil
        detector = nil
        sideClassifier = sideProfile.map { TapSideClassifier(profile: $0) }
        sequenceAggregator = TapSequenceAggregator(configuration: sequenceConfiguration)
        latestCalibrationProfile = nil
        latestProgress = 0
    }

    public var calibrationProfile: CalibrationProfile? {
        lock.lock()
        defer { lock.unlock() }
        return latestCalibrationProfile
    }

    public var calibrationProgress: Double {
        lock.lock()
        defer { lock.unlock() }
        return latestProgress
    }

    private func processCalibrationSample(_ sample: MotionSample) -> RecognitionUpdate {
        if calibrationStartNanoseconds == nil {
            calibrationStartNanoseconds = sample.timestampNanoseconds
        }

        guard let calibrationStartNanoseconds else {
            return RecognitionUpdate(calibrationProgress: 0)
        }

        let elapsed = sample.timestampNanoseconds >= calibrationStartNanoseconds
            ? sample.timestampNanoseconds - calibrationStartNanoseconds
            : 0
        latestProgress = min(
            1,
            Double(elapsed) / Double(calibrationDurationNanoseconds)
        )

        guard elapsed < calibrationDurationNanoseconds else {
            let profile = calibrator.makeProfile(
                calibratedAtNanoseconds: sample.timestampNanoseconds
            )
            latestCalibrationProfile = profile
            var newDetector = TapDetector(
                calibration: profile,
                configuration: detectorConfiguration
            )
            let output = processNewDetectorSample(
                sample,
                detector: &newDetector,
                completedGestures: []
            )
            detector = newDetector
            return RecognitionUpdate(
                calibrationProfile: profile,
                calibrationProgress: 1,
                tapEvent: output.tapEvent,
                completedGestures: output.completedGestures
            )
        }

        calibrator.add(sample)
        return RecognitionUpdate(calibrationProgress: latestProgress)
    }

    private func processCalibratedSample(
        _ sample: MotionSample,
        alreadyCompletedGesture: TapGesture?
    ) -> RecognitionUpdate {
        guard var detector else {
            return RecognitionUpdate(
                calibrationProfile: latestCalibrationProfile,
                calibrationProgress: latestProgress,
                completedGestures: alreadyCompletedGesture.map { [$0] } ?? []
            )
        }

        let rawEvent = detector.process(sample)
        self.detector = detector
        var completedGestures = alreadyCompletedGesture.map { [$0] } ?? []
        guard let rawEvent else {
            return RecognitionUpdate(
                calibrationProfile: nil,
                calibrationProgress: 1,
                completedGestures: completedGestures
            )
        }

        let event: TapEvent
        if let sideClassifier {
            event = rawEvent.applying(sideClassifier.classify(rawEvent))
        } else {
            event = rawEvent
        }
        if var sequenceAggregator {
            if let gesture = sequenceAggregator.process(event) {
                completedGestures.append(gesture)
            }
            self.sequenceAggregator = sequenceAggregator
        }
        return RecognitionUpdate(
            calibrationProgress: 1,
            tapEvent: event,
            completedGestures: completedGestures
        )
    }

    private func processNewDetectorSample(
        _ sample: MotionSample,
        detector: inout TapDetector,
        completedGestures: [TapGesture]
    ) -> (tapEvent: TapEvent?, completedGestures: [TapGesture]) {
        let rawEvent = detector.process(sample)
        guard let rawEvent else {
            return (nil, completedGestures)
        }

        let event: TapEvent
        if let sideClassifier {
            event = rawEvent.applying(sideClassifier.classify(rawEvent))
        } else {
            event = rawEvent
        }
        var gestures = completedGestures
        if var sequenceAggregator {
            if let gesture = sequenceAggregator.process(event) {
                gestures.append(gesture)
            }
            self.sequenceAggregator = sequenceAggregator
        }
        return (event, gestures)
    }
}
