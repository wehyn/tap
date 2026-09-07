import Foundation
import TapProbeCore

private struct Options {
    let leftURLs: [URL]
    let rightURLs: [URL]
    let outputURL: URL
    let calibrationSeconds: TimeInterval
    let sensitivity: TapSensitivity
    let thresholdG: Double

    static func parse(arguments: [String]) -> Options? {
        var leftPaths: [String] = []
        var rightPaths: [String] = []
        var outputPath = "/tmp/tap-side-profile.json"
        var calibrationSeconds = 2.0
        var sensitivity: TapSensitivity = .high
        var thresholdG: Double?
        var index = 1

        while index < arguments.count {
            switch arguments[index] {
            case "--left":
                guard index + 1 < arguments.count else {
                    print("--left requires a file path")
                    return nil
                }
                leftPaths.append(arguments[index + 1])
                index += 2
            case "--right":
                guard index + 1 < arguments.count else {
                    print("--right requires a file path")
                    return nil
                }
                rightPaths.append(arguments[index + 1])
                index += 2
            case "--output":
                guard index + 1 < arguments.count else {
                    print("--output requires a file path")
                    return nil
                }
                outputPath = arguments[index + 1]
                index += 2
            case "--calibrate":
                guard index + 1 < arguments.count,
                      let value = TimeInterval(arguments[index + 1]),
                      value > 0 else {
                    print("--calibrate requires a positive number of seconds")
                    return nil
                }
                calibrationSeconds = value
                index += 2
            case "--sensitivity":
                guard index + 1 < arguments.count,
                      let value = TapSensitivity(rawValue: arguments[index + 1].lowercased()) else {
                    print("--sensitivity must be low, medium, or high")
                    return nil
                }
                sensitivity = value
                thresholdG = nil
                index += 2
            case "--threshold-g":
                guard index + 1 < arguments.count,
                      let value = Double(arguments[index + 1]),
                      value > 0 else {
                    print("--threshold-g requires a positive number")
                    return nil
                }
                thresholdG = value
                index += 2
            case "--help", "-h":
                printUsage()
                exit(0)
            default:
                print("Unknown argument: \(arguments[index])")
                printUsage()
                return nil
            }
        }

        guard !leftPaths.isEmpty, !rightPaths.isEmpty else {
            print("--left and --right are required")
            printUsage()
            return nil
        }

        return Options(
            leftURLs: leftPaths.map(URL.init(fileURLWithPath:)),
            rightURLs: rightPaths.map(URL.init(fileURLWithPath:)),
            outputURL: URL(fileURLWithPath: outputPath),
            calibrationSeconds: calibrationSeconds,
            sensitivity: sensitivity,
            thresholdG: thresholdG ?? sensitivity.minimumDynamicAccelerationG
        )
    }
}

private func printUsage() {
    print("""
    TapTrain — build a left/right side profile from labeled TapProbe traces

    Usage:
      TapTrain --left PATH [--left PATH ...] --right PATH [--right PATH ...]
               [--output PATH]
               [--calibrate SECONDS]
               [--sensitivity low|medium|high | --threshold-g VALUE]

    Options:
      --left PATH         Left-side trace; repeat for multiple recordings.
      --right PATH        Right-side trace; repeat for multiple recordings.
      --output PATH       JSON side profile output. Default: /tmp/tap-side-profile.json.
      --calibrate SECONDS Quiet baseline duration. Default: 2.
      --sensitivity LEVEL Detector sensitivity. Default: high.
      --threshold-g VALUE Custom detector threshold; overrides sensitivity.
      --help              Show this help.
    """)
}

private func loadEvents(
    from url: URL,
    calibrationSeconds: TimeInterval,
    thresholdG: Double
) throws -> [TapEvent] {
    let contents = try String(contentsOf: url, encoding: .utf8)
    let decoder = JSONDecoder()
    var records: [TraceRecord] = []

    for line in contents.split(whereSeparator: \.isNewline) {
        records.append(try decoder.decode(TraceRecord.self, from: Data(line.utf8)))
    }

    records.sort { $0.timestampNanoseconds < $1.timestampNanoseconds }
    guard let firstTimestamp = records.first?.timestampNanoseconds else {
        return []
    }

    let calibrationDuration = UInt64(calibrationSeconds * 1_000_000_000)
    let calibrationEnd = firstTimestamp + calibrationDuration
    var calibrator = MotionCalibrator()
    for record in records where record.timestampNanoseconds < calibrationEnd {
        calibrator.add(record.motionSample)
    }

    let profile = calibrator.makeProfile(calibratedAtNanoseconds: calibrationEnd)
    var detector = TapDetector(
        calibration: profile,
        configuration: TapDetectorConfiguration(
            minimumDynamicAccelerationG: thresholdG
        )
    )
    var events: [TapEvent] = []
    for record in records where record.timestampNanoseconds >= calibrationEnd {
        if let event = detector.process(record.motionSample) {
            events.append(event)
        }
    }
    return events
}

private struct TrainingClassificationReport {
    var total = 0
    var correct = 0
    var unknown = 0
    var incorrect = 0

    mutating func add(_ classification: TapSideClassification, expected: TapSide) {
        total += 1
        switch classification.side {
        case expected:
            correct += 1
        case .unknown:
            unknown += 1
        default:
            incorrect += 1
        }
    }
}

private func makeProfile(
    leftEvents: [TapEvent],
    rightEvents: [TapEvent]
) -> TapSideProfile {
    var trainer = TapSideClassifier()
    for event in leftEvents {
        trainer.add(event: event, labeled: .left)
    }
    for event in rightEvents {
        trainer.add(event: event, labeled: .right)
    }
    return trainer.makeProfile(
        calibratedAtNanoseconds: max(
            leftEvents.last?.timestampNanoseconds ?? 0,
            rightEvents.last?.timestampNanoseconds ?? 0
        )
    )
}

private func evaluate(
    profile: TapSideProfile,
    leftEvents: [TapEvent],
    rightEvents: [TapEvent]
) -> TrainingClassificationReport {
    let classifier = TapSideClassifier(profile: profile)
    var report = TrainingClassificationReport()
    for event in leftEvents {
        report.add(classifier.classify(event), expected: .left)
    }
    for event in rightEvents {
        report.add(classifier.classify(event), expected: .right)
    }
    return report
}

private func leaveOneOutEvaluate(
    leftEvents: [TapEvent],
    rightEvents: [TapEvent]
) -> TrainingClassificationReport {
    var report = TrainingClassificationReport()

    for (heldOutIndex, event) in leftEvents.enumerated() {
        let trainingLeft = leftEvents.enumerated()
            .filter { $0.offset != heldOutIndex }
            .map(\.element)
        let profile = makeProfile(leftEvents: trainingLeft, rightEvents: rightEvents)
        report.add(TapSideClassifier(profile: profile).classify(event), expected: .left)
    }

    for (heldOutIndex, event) in rightEvents.enumerated() {
        let trainingRight = rightEvents.enumerated()
            .filter { $0.offset != heldOutIndex }
            .map(\.element)
        let profile = makeProfile(leftEvents: leftEvents, rightEvents: trainingRight)
        report.add(TapSideClassifier(profile: profile).classify(event), expected: .right)
    }

    return report
}

guard let options = Options.parse(arguments: CommandLine.arguments) else {
    exit(EXIT_FAILURE)
}

do {
    let leftEvents = try options.leftURLs.flatMap { url in
        try loadEvents(
            from: url,
            calibrationSeconds: options.calibrationSeconds,
            thresholdG: options.thresholdG
        )
    }
    let rightEvents = try options.rightURLs.flatMap { url in
        try loadEvents(
            from: url,
            calibrationSeconds: options.calibrationSeconds,
            thresholdG: options.thresholdG
        )
    }

    let profile = makeProfile(leftEvents: leftEvents, rightEvents: rightEvents)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(profile)
    let parent = options.outputURL.deletingLastPathComponent()
    try FileManager.default.createDirectory(
        at: parent,
        withIntermediateDirectories: true
    )
    try data.write(to: options.outputURL, options: .atomic)

    let trainingReport = evaluate(
        profile: profile,
        leftEvents: leftEvents,
        rightEvents: rightEvents
    )
    let leaveOneOutReport = leaveOneOutEvaluate(
        leftEvents: leftEvents,
        rightEvents: rightEvents
    )

    print(
        "trained leftEvents=\(leftEvents.count) rightEvents=\(rightEvents.count) "
            + "sensitivity=\(options.sensitivity.rawValue) threshold="
            + String(format: "%.2fg", options.thresholdG)
    )
    print("saved side profile to \(options.outputURL.path)")
    print(
        "training separation: correct=\(trainingReport.correct)/\(trainingReport.total) "
            + "unknown=\(trainingReport.unknown) incorrect=\(trainingReport.incorrect)"
    )
    print(
        "leave-one-out separation: correct=\(leaveOneOutReport.correct)/\(leaveOneOutReport.total) "
            + "unknown=\(leaveOneOutReport.unknown) incorrect=\(leaveOneOutReport.incorrect)"
    )
    if profile.isUsable {
        print("side profile is usable for classification")
    } else {
        print("warning: need at least 3 accepted events per side before classification is enabled")
    }
    if trainingReport.incorrect > 0 || trainingReport.unknown > trainingReport.total / 2
            || leaveOneOutReport.incorrect > 0
            || leaveOneOutReport.unknown > leaveOneOutReport.total / 2 {
        print(
            "warning: labeled events are not cleanly separable; keep the profile conservative "
                + "and capture more consistent side examples before shipping it"
        )
    }
} catch {
    print("Unable to train side profile: \(error)")
    exit(EXIT_FAILURE)
}
