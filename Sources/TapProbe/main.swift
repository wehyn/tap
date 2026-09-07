import CoreFoundation
import Foundation
import IOKit
import IOKit.hid
import TapProbeCore

nonisolated(unsafe) private let hidRunLoopMode: CFString = CFRunLoopMode.defaultMode.rawValue

private struct Options {
    var duration: TimeInterval = 10
    var calibrationSeconds: TimeInterval = 2
    var sensitivity: TapSensitivity = .medium
    var thresholdG: Double?
    var sideProfileURL: URL?
    var recordURL: URL?
    var listOnly = false
    var verbose = false
    var detect = false
    var groupGestures = false

    static func parse(arguments: [String]) -> Options? {
        var options = Options()
        var index = 1

        while index < arguments.count {
            switch arguments[index] {
            case "--duration":
                guard index + 1 < arguments.count,
                      let value = TimeInterval(arguments[index + 1]),
                      value >= 0 else {
                    print("--duration requires a non-negative number of seconds")
                    return nil
                }
                options.duration = value
                index += 2
            case "--record":
                guard index + 1 < arguments.count else {
                    print("--record requires a file path")
                    return nil
                }
                options.recordURL = URL(fileURLWithPath: arguments[index + 1])
                index += 2
            case "--calibrate":
                guard index + 1 < arguments.count,
                      let value = TimeInterval(arguments[index + 1]),
                      value > 0 else {
                    print("--calibrate requires a positive number of seconds")
                    return nil
                }
                options.calibrationSeconds = value
                options.detect = true
                index += 2
            case "--threshold-g":
                guard index + 1 < arguments.count,
                      let value = Double(arguments[index + 1]),
                      value > 0 else {
                    print("--threshold-g requires a positive number")
                    return nil
                }
                options.thresholdG = value
                index += 2
            case "--sensitivity":
                guard index + 1 < arguments.count,
                      let value = TapSensitivity(rawValue: arguments[index + 1].lowercased()) else {
                    print("--sensitivity must be low, medium, or high")
                    return nil
                }
                options.sensitivity = value
                options.thresholdG = nil
                index += 2
            case "--side-profile":
                guard index + 1 < arguments.count else {
                    print("--side-profile requires a file path")
                    return nil
                }
                options.sideProfileURL = URL(fileURLWithPath: arguments[index + 1])
                index += 2
            case "--group":
                options.groupGestures = true
                index += 1
            case "--list":
                options.listOnly = true
                index += 1
            case "--verbose":
                options.verbose = true
                index += 1
            case "--detect":
                options.detect = true
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

        return options
    }
}

private func printUsage() {
    print("""
    TapProbe — AppleSPUHIDDevice sensor feasibility probe

    Usage:
      TapProbe [--list] [--duration SECONDS] [--calibrate SECONDS] [--detect]
               [--sensitivity low|medium|high | --threshold-g VALUE]
               [--side-profile PATH] [--group]
               [--record PATH] [--verbose]

    Options:
      --list              Enumerate matching HID devices and exit.
      --duration SECONDS  Stream for SECONDS; use 0 to run until interrupted. Default: 10.
      --calibrate SECONDS Keep the Mac still for this long, then detect tap candidates. Default: 2.
      --detect            Calibrate for the default period, then print tap candidates.
      --sensitivity LEVEL  Use low, medium, or high sensitivity. Default: medium.
      --threshold-g VALUE Custom dynamic-acceleration threshold; overrides sensitivity.
      --side-profile PATH  JSON profile produced by TapTrain for left/right classification.
      --group              Emit one/two/three-tap grouped gestures.
      --record PATH       Write newline-delimited JSON trace records to PATH.
      --verbose            Print the first samples from each channel.
      --help              Show this help.
    """)
}

private struct SensorDescriptor: Sendable {
    let product: String
    let usagePage: UInt32
    let usage: UInt32
    let reportSize: Int
    let transport: String
}

private final class TraceWriter: @unchecked Sendable {
    private let encoder = JSONEncoder()
    private let lock = NSLock()
    private let handle: FileHandle

    init?(url: URL) {
        do {
            let parent = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(
                at: parent,
                withIntermediateDirectories: true
            )
            if !FileManager.default.fileExists(atPath: url.path) {
                guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
                    print("Unable to create trace file \(url.path)")
                    return nil
                }
            }
            let fileHandle = try FileHandle(forWritingTo: url)
            try fileHandle.truncate(atOffset: 0)
            handle = fileHandle
        } catch {
            print("Unable to open trace file \(url.path): \(error)")
            return nil
        }
    }

    func write(_ record: TraceRecord) {
        do {
            let data = try encoder.encode(record)
            lock.lock()
            handle.write(data)
            handle.write(Data([0x0A]))
            lock.unlock()
        } catch {
            fputs("Trace write failed: \(error)\n", stderr)
        }
    }

    func close() {
        lock.lock()
        try? handle.close()
        lock.unlock()
    }
}

private struct RecognitionOutput: Sendable {
    let calibrationProfile: CalibrationProfile?
    let tapEvent: TapEvent?
    let tapGesture: TapGesture?
}

private final class LiveRecognition: @unchecked Sendable {
    let calibrationSeconds: TimeInterval
    let sensitivity: TapSensitivity
    let thresholdG: Double

    private let calibrationDurationNanoseconds: UInt64
    private let lock = NSLock()
    private var calibrator = MotionCalibrator()
    private var calibrationStartNanoseconds: UInt64?
    private var detector: TapDetector?
    private var sideClassifier: TapSideClassifier?
    private var sequenceAggregator: TapSequenceAggregator?

    init(
        calibrationSeconds: TimeInterval,
        sensitivity: TapSensitivity,
        thresholdG: Double?,
        sideProfile: TapSideProfile?,
        groupGestures: Bool
    ) {
        self.calibrationSeconds = calibrationSeconds
        self.sensitivity = sensitivity
        self.thresholdG = thresholdG ?? sensitivity.minimumDynamicAccelerationG
        self.calibrationDurationNanoseconds = UInt64(calibrationSeconds * 1_000_000_000)
        self.sideClassifier = sideProfile.map { TapSideClassifier(profile: $0) }
        self.sequenceAggregator = groupGestures ? TapSequenceAggregator() : nil
    }

    func process(_ sample: MotionSample) -> RecognitionOutput {
        lock.lock()
        defer { lock.unlock() }

        if var detector {
            let rawEvent = detector.process(sample)
            self.detector = detector
            guard let rawEvent else {
                return RecognitionOutput(
                    calibrationProfile: nil,
                    tapEvent: nil,
                    tapGesture: nil
                )
            }
            let classification = sideClassifier?.classify(rawEvent)
            let event = classification.map(rawEvent.applying) ?? rawEvent
            let gesture: TapGesture?
            if var sequenceAggregator {
                gesture = sequenceAggregator.process(event)
                self.sequenceAggregator = sequenceAggregator
            } else {
                gesture = nil
            }
            return RecognitionOutput(
                calibrationProfile: nil,
                tapEvent: event,
                tapGesture: gesture
            )
        }

        if calibrationStartNanoseconds == nil {
            calibrationStartNanoseconds = sample.timestampNanoseconds
        }

        guard let calibrationStartNanoseconds else {
            return RecognitionOutput(
                calibrationProfile: nil,
                tapEvent: nil,
                tapGesture: nil
            )
        }

        let elapsed = sample.timestampNanoseconds >= calibrationStartNanoseconds
            ? sample.timestampNanoseconds - calibrationStartNanoseconds
            : 0
        guard elapsed < calibrationDurationNanoseconds else {
            let profile = calibrator.makeProfile(
                calibratedAtNanoseconds: sample.timestampNanoseconds
            )
            var newDetector = TapDetector(
                calibration: profile,
                configuration: TapDetectorConfiguration(
                    minimumDynamicAccelerationG: thresholdG
                )
            )
            let rawEvent = newDetector.process(sample)
            detector = newDetector
            guard let rawEvent else {
                return RecognitionOutput(
                    calibrationProfile: profile,
                    tapEvent: nil,
                    tapGesture: nil
                )
            }
            let classification = sideClassifier?.classify(rawEvent)
            let event = classification.map(rawEvent.applying) ?? rawEvent
            let gesture: TapGesture?
            if var sequenceAggregator {
                gesture = sequenceAggregator.process(event)
                self.sequenceAggregator = sequenceAggregator
            } else {
                gesture = nil
            }
            return RecognitionOutput(
                calibrationProfile: profile,
                tapEvent: event,
                tapGesture: gesture
            )
        }

        calibrator.add(sample)
        return RecognitionOutput(
            calibrationProfile: nil,
            tapEvent: nil,
            tapGesture: nil
        )
    }

    func flushGesture() -> TapGesture? {
        lock.lock()
        defer { lock.unlock() }
        return sequenceAggregator?.flush()
    }
}

private struct ChannelStats: Sendable {
    var count = 0
    var firstTimestamp: UInt64?
    var lastTimestamp: UInt64?
    var last: ParsedReport?

    var samplesPerSecond: Double? {
        guard let firstTimestamp, let lastTimestamp, lastTimestamp > firstTimestamp else {
            return nil
        }
        let seconds = Double(lastTimestamp - firstTimestamp) / 1_000_000_000
        return seconds > 0 ? Double(count - 1) / seconds : nil
    }
}

private final class ProbeState: @unchecked Sendable {
    let parser = IMUReportParser()
    let traceWriter: TraceWriter?
    let verbose: Bool
    let recognition: LiveRecognition?

    private let lock = NSLock()
    private var nextSequence: UInt64 = 0
    private var stats: [SensorChannel: ChannelStats] = [:]
    private var printedSampleCount: [SensorChannel: Int] = [:]

    init(traceWriter: TraceWriter?, verbose: Bool, recognition: LiveRecognition?) {
        self.traceWriter = traceWriter
        self.verbose = verbose
        self.recognition = recognition
    }

    func handle(channel: SensorChannel, report: UnsafeMutablePointer<UInt8>, length: CFIndex) {
        let bytes = Array(UnsafeBufferPointer(start: report, count: length))

        do {
            let parsed = try parser.parse(channel: channel, bytes: bytes)
            let timestamp = DispatchTime.now().uptimeNanoseconds
            let recognitionOutput = recognition?.process(
                MotionSample(timestampNanoseconds: timestamp, parsed: parsed)
            )

            lock.lock()
            nextSequence += 1
            let sequence = nextSequence
            var channelStats = stats[channel, default: ChannelStats()]
            channelStats.count += 1
            channelStats.firstTimestamp = channelStats.firstTimestamp ?? timestamp
            channelStats.lastTimestamp = timestamp
            channelStats.last = parsed
            stats[channel] = channelStats

            let sampleNumber = printedSampleCount[channel, default: 0]
            printedSampleCount[channel] = sampleNumber + 1
            lock.unlock()

            traceWriter?.write(
                TraceRecord(
                    timestampNanoseconds: timestamp,
                    sequence: sequence,
                    parsed: parsed
                )
            )

            if verbose && sampleNumber < 5 {
                print(
                    "sample channel=\(channel.rawValue) seq=\(sequence) "
                        + "raw=(\(parsed.rawX),\(parsed.rawY),\(parsed.rawZ)) "
                        + String(format: "scaled=(%.5f,%.5f,%.5f)", parsed.x, parsed.y, parsed.z)
                )
            }

            if let profile = recognitionOutput?.calibrationProfile {
                print(
                    "calibrated: accelSamples=\(profile.accelerometer.sampleCount) "
                        + "gyroSamples=\(profile.gyroscope.sampleCount) "
                        + String(
                            format: "rest=(%.4f,%.4f,%.4f)g",
                            profile.accelerometer.mean.x,
                            profile.accelerometer.mean.y,
                            profile.accelerometer.mean.z
                        )
                )
            }

            if let event = recognitionOutput?.tapEvent {
                print(
                    String(
                        format: "tap candidate side=%@ dynamic=%.3fg jerk=%.3fg/sample gyro=%.3fdeg/s confidence=%.2f",
                        event.side.rawValue,
                        event.peakDynamicAccelerationG,
                        event.peakJerkGPerSample,
                        event.peakAngularRateDps,
                        event.confidence
                    )
                )
            }

            if let gesture = recognitionOutput?.tapGesture {
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
        } catch {
            print("Dropped \(channel.rawValue) report length=\(length): \(error)")
        }
    }

    func summary() -> String {
        lock.lock()
        defer { lock.unlock() }

        return SensorChannel.allCases.map { channel in
            let channelStats = stats[channel, default: ChannelStats()]
            let rate = channelStats.samplesPerSecond.map { String(format: "%.1f", $0) } ?? "n/a"
            let last = channelStats.last.map {
                String(format: "(%.5f, %.5f, %.5f)", $0.x, $0.y, $0.z)
            } ?? "n/a"
            return "\(channel.rawValue): samples=\(channelStats.count), rate=\(rate) Hz, last=\(last)"
        }.joined(separator: " | ")
    }

    func totalSampleCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return stats.values.reduce(0) { $0 + $1.count }
    }
}

private final class DeviceContext: @unchecked Sendable {
    private static let reportBufferLength = 4096

    let state: ProbeState
    let descriptor: SensorDescriptor
    let device: IOHIDDevice
    let reportBuffer: UnsafeMutablePointer<UInt8>

    init(
        state: ProbeState,
        descriptor: SensorDescriptor,
        device: IOHIDDevice
    ) {
        self.state = state
        self.descriptor = descriptor
        self.device = device
        self.reportBuffer = .allocate(capacity: Self.reportBufferLength)
        self.reportBuffer.initialize(repeating: 0, count: Self.reportBufferLength)
    }

    deinit {
        reportBuffer.deinitialize(count: Self.reportBufferLength)
        reportBuffer.deallocate()
    }
}

nonisolated(unsafe) private let reportTimestampCallback: IOHIDReportWithTimeStampCallback = {
    context,
    result,
    _,
    _,
    _,
    report,
    reportLength,
    _ in
    guard result == kIOReturnSuccess,
          let context else {
        return
    }

    let deviceContext = Unmanaged<DeviceContext>
        .fromOpaque(context)
        .takeUnretainedValue()

    deviceContext.state.handle(
        channel: channel(for: deviceContext.descriptor.usage),
        report: report,
        length: reportLength
    )
}

private func channel(for usage: UInt32) -> SensorChannel {
    usage == 9 ? .gyroscope : .accelerometer
}

private func property(_ device: IOHIDDevice, key: String) -> Any? {
    guard let value = IOHIDDeviceGetProperty(device, key as CFString) else {
        return nil
    }
    return value
}

private func stringProperty(_ device: IOHIDDevice, key: String) -> String {
    if let value = property(device, key: key) as? String {
        return value
    }
    if let value = property(device, key: key) as? NSString {
        return value as String
    }
    return "unknown"
}

private func numberProperty(_ device: IOHIDDevice, key: String) -> UInt32? {
    if let value = property(device, key: key) as? NSNumber {
        return value.uint32Value
    }
    return nil
}

private func makeDescriptor(for device: IOHIDDevice) -> SensorDescriptor? {
    let usagePage = numberProperty(device, key: kIOHIDPrimaryUsagePageKey)
        ?? numberProperty(device, key: kIOHIDDeviceUsagePageKey)
    let usage = numberProperty(device, key: kIOHIDPrimaryUsageKey)
        ?? numberProperty(device, key: kIOHIDDeviceUsageKey)

    guard let usagePage,
          let usage,
          usagePage == 0xFF00,
          usage == 3 || usage == 9 else {
        return nil
    }

    let product = stringProperty(device, key: kIOHIDProductKey)
    let transport = stringProperty(device, key: kIOHIDTransportKey)

    guard transport == "SPU",
          product.lowercased() == "accel" || product.lowercased() == "gyro" else {
        return nil
    }

    let reportSize = numberProperty(device, key: kIOHIDMaxInputReportSizeKey).map(Int.init) ?? 0

    guard reportSize >= IMUReportParser.expectedReportLength else {
        return nil
    }

    return SensorDescriptor(
        product: product,
        usagePage: usagePage,
        usage: usage,
        reportSize: reportSize,
        transport: transport
    )
}

private func wakeSPUSensors() {
    guard let matching = IOServiceMatching("AppleSPUHIDDriver") else {
        print("Unable to create AppleSPUHIDDriver matching dictionary")
        return
    }

    var iterator: io_iterator_t = 0
    let matchingStatus = IOServiceGetMatchingServices(
        kIOMainPortDefault,
        matching,
        &iterator
    )
    guard matchingStatus == KERN_SUCCESS else {
        print("AppleSPUHIDDriver lookup failed: \(statusDescription(matchingStatus))")
        return
    }
    defer { IOObjectRelease(iterator) }

    let requests: [(String, NSNumber)] = [
        ("SensorPropertyReportingState", NSNumber(value: 1)),
        ("SensorPropertyPowerState", NSNumber(value: 1)),
        ("ReportInterval", NSNumber(value: 1_000)),
    ]

    var driverCount = 0
    var successfulRequests = 0
    while true {
        let service = IOIteratorNext(iterator)
        guard service != 0 else {
            break
        }
        driverCount += 1
        for (key, value) in requests {
            let result = IORegistryEntrySetCFProperty(
                service,
                key as CFString,
                value
            )
            if result == KERN_SUCCESS {
                successfulRequests += 1
            }
        }
        IOObjectRelease(service)
    }

    print(
        "SPU wake request: drivers=\(driverCount), "
            + "successfulProperties=\(successfulRequests)/\(driverCount * requests.count)"
    )
}

private final class ProbeSession: @unchecked Sendable {
    let manager: IOHIDManager
    let state: ProbeState
    let devices: [(IOHIDDevice, DeviceContext)]

    init?(state: ProbeState, openDevices: Bool = true) {
        self.state = state
        self.manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))

        if openDevices {
            wakeSPUSensors()
        }

        // Enumerate all HID devices and apply the sensor filter locally. Some
        // AppleSPUHIDDevice instances expose only their primary usage in the
        // live IOHID property dictionary even though the registry also lists
        // DeviceUsagePairs.
        IOHIDManagerSetDeviceMatching(manager, nil)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetCurrent(), hidRunLoopMode)

        let managerStatus = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        guard managerStatus == kIOReturnSuccess else {
            print("IOHIDManagerOpen failed: \(statusDescription(managerStatus))")
            return nil
        }

        guard let deviceSet = IOHIDManagerCopyDevices(manager) else {
            print("No HID devices matched usage page 0xFF00")
            self.devices = []
            return
        }

        let candidates = (deviceSet as NSSet).allObjects.map { $0 as! IOHIDDevice }
        var opened: [(IOHIDDevice, DeviceContext)] = []

        for device in candidates {
            guard let descriptor = makeDescriptor(for: device) else {
                continue
            }

            let usagePage = String(descriptor.usagePage, radix: 16)
            let deviceSummary = "found product=\(descriptor.product) "
                + "usagePage=0x\(usagePage) "
                + "usage=\(descriptor.usage) "
                + "reportSize=\(descriptor.reportSize) "
                + "transport=\(descriptor.transport)"
            print(deviceSummary)

            guard openDevices else {
                continue
            }

            let openStatus = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
            guard openStatus == kIOReturnSuccess else {
                print(
                    "  open failed product=\(descriptor.product): "
                        + statusDescription(openStatus)
                )
                continue
            }

            let context = DeviceContext(state: state, descriptor: descriptor, device: device)
            IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetCurrent(), hidRunLoopMode)
            IOHIDDeviceRegisterInputReportWithTimeStampCallback(
                device,
                context.reportBuffer,
                4096,
                reportTimestampCallback,
                Unmanaged.passUnretained(context).toOpaque()
            )
            opened.append((device, context))
        }

        self.devices = opened

        if openDevices && opened.isEmpty {
            print("No accelerometer or gyroscope device could be opened.")
        } else if openDevices {
            print("opened \(opened.count) sensor device(s)")
        }
    }

    deinit {
        for (device, context) in devices {
            IOHIDDeviceUnscheduleFromRunLoop(device, CFRunLoopGetCurrent(), hidRunLoopMode)
            IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
            _ = Unmanaged.passUnretained(context)
        }
        IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetCurrent(), hidRunLoopMode)
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
    }
}

private func statusDescription(_ status: IOReturn) -> String {
    let hex = String(status, radix: 16, uppercase: true)
    return "IOReturn 0x\(hex)"
}

private func loadSideProfile(from url: URL) -> TapSideProfile? {
    do {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(TapSideProfile.self, from: data)
    } catch {
        print("Unable to load side profile \(url.path): \(error)")
        exit(EXIT_FAILURE)
    }
}

guard let options = Options.parse(arguments: CommandLine.arguments) else {
    exit(EXIT_FAILURE)
}

let hostName = Host.current().localizedName ?? "unknown Mac"
print("TapProbe starting on \(hostName)")

private let traceWriter: TraceWriter?
if let recordURL = options.recordURL {
    traceWriter = TraceWriter(url: recordURL)
    if traceWriter == nil {
        exit(EXIT_FAILURE)
    }
    print("recording trace to \(recordURL.path)")
} else {
    traceWriter = nil
}

private let sideProfile: TapSideProfile?
if let sideProfileURL = options.sideProfileURL {
    sideProfile = loadSideProfile(from: sideProfileURL)
    if let sideProfile, !sideProfile.isUsable {
        print("warning: side profile needs at least 3 accepted events per side; side remains unknown")
    }
} else {
    sideProfile = nil
}

private let recognition = options.detect
    ? LiveRecognition(
        calibrationSeconds: options.calibrationSeconds,
        sensitivity: options.sensitivity,
        thresholdG: options.thresholdG,
        sideProfile: sideProfile,
        groupGestures: options.groupGestures
    )
    : nil

if let recognition {
    print(
        "tap detection enabled: keep the Mac still for "
            + String(format: "%.1f", recognition.calibrationSeconds)
            + "s, then tap the chassis (sensitivity "
            + recognition.sensitivity.rawValue
            + ", threshold "
            + String(format: "%.2f", recognition.thresholdG)
            + "g)"
    )
}

private let probeState = ProbeState(
    traceWriter: traceWriter,
    verbose: options.verbose,
    recognition: recognition
)

if options.listOnly {
    _ = ProbeSession(state: probeState, openDevices: false)
    traceWriter?.close()
    exit(EXIT_SUCCESS)
}

private let session = ProbeSession(state: probeState)
guard let session else {
    traceWriter?.close()
    exit(EXIT_FAILURE)
}

guard !session.devices.isEmpty else {
    traceWriter?.close()
    exit(EXIT_FAILURE)
}

let startedAt = DispatchTime.now().uptimeNanoseconds
let timer = Timer(timeInterval: 1, repeats: true) { _ in
    print(probeState.summary())

    guard options.duration > 0 else {
        return
    }

    let elapsed = Double(DispatchTime.now().uptimeNanoseconds - startedAt) / 1_000_000_000
    if elapsed >= options.duration {
        CFRunLoopStop(CFRunLoopGetCurrent())
    }
}
RunLoop.current.add(timer, forMode: .default)

print(options.duration > 0 ? "streaming for \(options.duration)s" : "streaming until interrupted")
CFRunLoopRun()

timer.invalidate()
if let gesture = recognition?.flushGesture() {
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
print("final: \(probeState.summary())")
if probeState.totalSampleCount() == 0 {
    print(
        "warning: sensor devices opened but no input reports arrived. "
            + "This process may need the privileged sensor-helper path; do not run the full app as root."
    )
}
traceWriter?.close()
