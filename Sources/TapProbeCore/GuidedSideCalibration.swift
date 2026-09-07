import Foundation

public enum GuidedCalibrationPhase: String, Codable, Equatable, Sendable {
    case idle
    case preparing
    case left
    case right
    case complete
}

/// Collects a small, explicit left/right tap sample set for first-run setup.
/// It deliberately does not alter the recognizer or accept ambiguous events;
/// it only labels the already accepted TapEvent waveform features.
public struct GuidedSideCalibration: Sendable {
    public let requiredSamplesPerSide: Int
    public private(set) var phase: GuidedCalibrationPhase = .idle
    public private(set) var leftSampleCount = 0
    public private(set) var rightSampleCount = 0
    public private(set) var profile: TapSideProfile?

    private var classifier: TapSideClassifier

    public init(requiredSamplesPerSide: Int = 3) {
        precondition(requiredSamplesPerSide > 0)
        self.requiredSamplesPerSide = requiredSamplesPerSide
        classifier = TapSideClassifier(minimumSamplesPerSide: requiredSamplesPerSide)
    }

    public var isActive: Bool {
        phase == .preparing || phase == .left || phase == .right
    }

    public mutating func start() {
        classifier = TapSideClassifier(minimumSamplesPerSide: requiredSamplesPerSide)
        phase = .preparing
        leftSampleCount = 0
        rightSampleCount = 0
        profile = nil
    }

    public mutating func cancel() {
        phase = .idle
        profile = nil
    }

    /// Moves from the quiet-window phase to the first guided side prompt.
    public mutating func markCalibrationComplete() {
        guard phase == .preparing else {
            return
        }
        phase = .left
    }

    /// Adds one detector-accepted event to the currently prompted side.
    /// Events are never accepted outside an active left/right prompt.
    public mutating func add(event: TapEvent) {
        let side: TapSide
        switch phase {
        case .left:
            side = .left
        case .right:
            side = .right
        case .idle, .preparing, .complete:
            return
        }

        classifier.add(event: event, labeled: side)
        switch side {
        case .left:
            leftSampleCount += 1
            if leftSampleCount >= requiredSamplesPerSide {
                phase = .right
            }
        case .right:
            rightSampleCount += 1
            if rightSampleCount >= requiredSamplesPerSide {
                profile = classifier.makeProfile(
                    calibratedAtNanoseconds: event.timestampNanoseconds
                )
                phase = .complete
            }
        case .unknown:
            break
        }
    }
}
