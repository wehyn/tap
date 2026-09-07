import Foundation
import TapProbeCore

private struct Options {
    let traceURL: URL
    let calibrationSeconds: TimeInterval
    let sensitivity: TapSensitivity
    let thresholdG: Double
    let sideProfileURL: URL?
    let useBundledSideProfile: Bool
    let groupGestures: Bool
    let verbose: Bool

    static func parse(arguments: [String]) -> Options? {
        var tracePath: String?
        var calibrationSeconds = 2.0
        var sensitivity: TapSensitivity = .medium
        var thresholdG: Double?
        var sideProfilePath: String?
        var useBundledSideProfile = false
        var groupGestures = false
        var verbose = false
        var index = 1

        while index < arguments.count {
            switch arguments[index] {
            case "--trace":
                guard index + 1 < arguments.count else {
                    print("--trace requires a file path")
                    return nil
                }
                tracePath = arguments[index + 1]
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
            case "--threshold-g":
                guard index + 1 < arguments.count,
                      let value = Double(arguments[index + 1]),
                      value > 0 else {
                    print("--threshold-g requires a positive number")
                    return nil
                }
                thresholdG = value
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
            case "--side-profile":
                guard index + 1 < arguments.count else {
                    print("--side-profile requires a file path")
                    return nil
                }
                sideProfilePath = arguments[index + 1]
                index += 2
            case "--bundled-side-profile":
                useBundledSideProfile = true
                index += 1
            case "--group":
                groupGestures = true
                index += 1
            case "--verbose":
                verbose = true
                index += 1
            case "--help", "-h":
                printUsage()
                exit(0)
            default:
                print("Unknown argument: \(arguments[index])")
                printUsage()
                return nil
            }
        }

        guard let tracePath else {
            print("--trace is required")
            printUsage()
            return nil
        }

        return Options(
            traceURL: URL(fileURLWithPath: tracePath),
            calibrationSeconds: calibrationSeconds,
            sensitivity: sensitivity,
            thresholdG: thresholdG ?? sensitivity.minimumDynamicAccelerationG,
            sideProfileURL: sideProfilePath.map(URL.init(fileURLWithPath:)),
            useBundledSideProfile: useBundledSideProfile,
            groupGestures: groupGestures,
            verbose: verbose
        )
    }
}

private func printUsage() {
    print("""
    TapReplay — replay a local TapProbe NDJSON trace

    Usage:
      TapReplay --trace PATH [--calibrate SECONDS]
                 [--sensitivity low|medium|high | --threshold-g VALUE]
                 [--side-profile PATH | --bundled-side-profile] [--group] [--verbose]

    Options:
      --trace PATH        NDJSON trace created by TapProbe.
      --calibrate SECONDS Use the initial quiet window as the resting baseline. Default: 2.
      --sensitivity LEVEL  Use low, medium, or high sensitivity. Default: medium.
      --threshold-g VALUE Custom dynamic-acceleration threshold; overrides sensitivity.
      --side-profile PATH  JSON profile produced by TapTrain for left/right classification.
      --bundled-side-profile  Use the same plug-and-play side profile as Tap.app.
      --group              Emit one/two/three-tap grouped gestures.
      --verbose            Include event vectors and recovery duration in candidate output.
      --help              Show this help.
    """)
}

guard let options = Options.parse(arguments: CommandLine.arguments) else {
    exit(EXIT_FAILURE)
}

do {
    let contents = try String(contentsOf: options.traceURL, encoding: .utf8)
    let decoder = JSONDecoder()
    var records: [TraceRecord] = []

    for line in contents.split(whereSeparator: \.isNewline) {
        do {
            records.append(try decoder.decode(TraceRecord.self, from: Data(line.utf8)))
        } catch {
            print("Skipping malformed trace line: \(error)")
        }
    }

    records.sort { $0.timestampNanoseconds < $1.timestampNanoseconds }
    guard let firstTimestamp = records.first?.timestampNanoseconds else {
        print("Trace contains no records")
        exit(EXIT_FAILURE)
    }

    let calibrationDuration = UInt64(options.calibrationSeconds * 1_000_000_000)
    let calibrationEnd = firstTimestamp + calibrationDuration
    var calibrator = MotionCalibrator()

    for record in records where record.timestampNanoseconds < calibrationEnd {
        calibrator.add(record.motionSample)
    }

    let profile = calibrator.makeProfile(calibratedAtNanoseconds: calibrationEnd)
    print(
        "calibrated accelSamples=\(profile.accelerometer.sampleCount) "
            + "gyroSamples=\(profile.gyroscope.sampleCount) "
            + String(
                format: "rest=(%.4f,%.4f,%.4f)g",
                profile.accelerometer.mean.x,
                profile.accelerometer.mean.y,
                profile.accelerometer.mean.z
            )
    )
    print(
        String(
            format: "detector sensitivity=%@ threshold=%.2fg",
            options.sensitivity.rawValue,
            options.thresholdG
        )
    )

    var detector = TapDetector(
        calibration: profile,
        configuration: TapDetectorConfiguration(
            minimumDynamicAccelerationG: options.thresholdG
        )
    )
    var sideClassifier: TapSideClassifier?
    if options.useBundledSideProfile {
        sideClassifier = TapSideClassifier(profile: .bundledDefault)
    } else if let sideProfileURL = options.sideProfileURL {
        let data = try Data(contentsOf: sideProfileURL)
        let sideProfile = try JSONDecoder().decode(TapSideProfile.self, from: data)
        sideClassifier = TapSideClassifier(profile: sideProfile)
        if !sideProfile.isUsable {
            print("warning: side profile needs at least 3 accepted events per side; side remains unknown")
        }
    } else {
        sideClassifier = nil
    }
    var sequenceAggregator: TapSequenceAggregator?
    if options.groupGestures {
        sequenceAggregator = TapSequenceAggregator()
    } else {
        sequenceAggregator = nil
    }
    var eventCount = 0

    for record in records where record.timestampNanoseconds >= calibrationEnd {
        if let event = detector.process(record.motionSample) {
            eventCount += 1
            let classification = sideClassifier?.classify(event)
            let classifiedEvent = classification.map(event.applying) ?? event
            var line = String(
                format: "tap candidate #%d t=%lluns side=%@ dynamic=%.3fg jerk=%.3fg/sample gyro=%.3fdeg/s confidence=%.2f",
                eventCount,
                event.timestampNanoseconds,
                classifiedEvent.side.rawValue,
                event.peakDynamicAccelerationG,
                event.peakJerkGPerSample,
                event.peakAngularRateDps,
                classifiedEvent.confidence
            )
            if let classification,
               let leftDistance = classification.leftDistance,
               let rightDistance = classification.rightDistance {
                line += String(
                    format: " distances=(left %.3f, right %.3f, margin %.3f)",
                    leftDistance,
                    rightDistance,
                    classification.confidence
                )
            }
            if options.verbose {
                line += String(
                    format: " onsetAccel=(%.3f,%.3f,%.3f) peakAccel=(%.3f,%.3f,%.3f) onsetGyro=(%.3f,%.3f,%.3f) peakGyro=(%.3f,%.3f,%.3f) recovery=%.1fms",
                    event.onsetDynamicAcceleration.x,
                    event.onsetDynamicAcceleration.y,
                    event.onsetDynamicAcceleration.z,
                    event.dynamicAcceleration.x,
                    event.dynamicAcceleration.y,
                    event.dynamicAcceleration.z,
                    event.onsetAngularRate.x,
                    event.onsetAngularRate.y,
                    event.onsetAngularRate.z,
                    event.angularRate.x,
                    event.angularRate.y,
                    event.angularRate.z,
                    Double(event.recoveryDurationNanoseconds) / 1_000_000
                )
            }
            print(line)

            if let gesture = sequenceAggregator?.process(classifiedEvent) {
                printGesture(gesture)
            }
        }
    }

    if let gesture = sequenceAggregator?.flush() {
        printGesture(gesture)
    }

    print("replayed \(records.count) records; tapCandidates=\(eventCount)")
} catch {
    print("Unable to replay \(options.traceURL.path): \(error)")
    exit(EXIT_FAILURE)
}

private func printGesture(_ gesture: TapGesture) {
    print(
        String(
            format: "tap gesture side=%@ taps=%d first=%lluns last=%lluns confidence=%.2f",
            gesture.side.rawValue,
            gesture.tapCount,
            gesture.firstTimestampNanoseconds,
            gesture.lastTimestampNanoseconds,
            gesture.confidence
        )
    )
}
