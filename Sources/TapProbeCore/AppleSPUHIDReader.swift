import CoreFoundation
import Foundation
import IOKit
import IOKit.hid

nonisolated(unsafe) private let tapHIDRunLoopMode: CFString = CFRunLoopMode.defaultMode.rawValue

/// The small amount of device metadata that is useful to the app and safe to
/// show in diagnostics. Hardware serial numbers are intentionally excluded.
public struct SensorDescriptor: Codable, Equatable, Sendable, Identifiable {
    public let product: String
    public let usagePage: UInt32
    public let usage: UInt32
    public let reportSize: Int
    public let transport: String

    public init(
        product: String,
        usagePage: UInt32,
        usage: UInt32,
        reportSize: Int,
        transport: String
    ) {
        self.product = product
        self.usagePage = usagePage
        self.usage = usage
        self.reportSize = reportSize
        self.transport = transport
    }

    public var id: String {
        "\(product)-\(usagePage)-\(usage)-\(transport)"
    }
}

public enum SensorReaderPhase: String, Codable, Equatable, Sendable {
    case idle
    case starting
    case streaming
    case stopped
    case noSensors
    case failed
}

public struct SensorReaderStatus: Codable, Equatable, Sendable {
    public let phase: SensorReaderPhase
    public let descriptors: [SensorDescriptor]
    public let openedDeviceCount: Int
    public let parsedSampleCount: Int
    public let parseErrorCount: Int
    public let message: String?

    public init(
        phase: SensorReaderPhase,
        descriptors: [SensorDescriptor] = [],
        openedDeviceCount: Int = 0,
        parsedSampleCount: Int = 0,
        parseErrorCount: Int = 0,
        message: String? = nil
    ) {
        self.phase = phase
        self.descriptors = descriptors
        self.openedDeviceCount = openedDeviceCount
        self.parsedSampleCount = parsedSampleCount
        self.parseErrorCount = parseErrorCount
        self.message = message
    }
}

/// Direct, unprivileged access to the Apple SPU HID motion devices.
///
/// This is deliberately a replaceable boundary. AppleSPUHIDDevice is an
/// undocumented implementation detail, so the product process should depend
/// on this reader's typed sample/status callbacks rather than on IOKit types.
/// The callbacks are invoked on the run loop on which `start()` is called.
public final class AppleSPUHIDReader: @unchecked Sendable {
    public typealias SampleHandler = @Sendable (MotionSample, ParsedReport) -> Void
    public typealias StatusHandler = @Sendable (SensorReaderStatus) -> Void

    private static let reportBufferLength = 4096

    private let manager: IOHIDManager
    private let sampleHandler: SampleHandler
    private let statusHandler: StatusHandler
    private let lock = NSLock()

    private var devices: [(IOHIDDevice, DeviceContext)] = []
    private var parsedSampleCount = 0
    private var parseErrorCount = 0
    private var started = false
    private var sensorServiceLost = false
    private var descriptors: [SensorDescriptor] = []

    public init(
        onSample: @escaping SampleHandler,
        onStatus: @escaping StatusHandler = { _ in }
    ) {
        manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        sampleHandler = onSample
        statusHandler = onStatus
    }

    deinit {
        stop()
    }

    public func start() {
        lock.lock()
        guard !started else {
            lock.unlock()
            return
        }
        started = true
        lock.unlock()

        publishStatus(phase: .starting)
        wakeSPUSensors()

        // Some AppleSPUHIDDevice instances expose only their primary usage in
        // the live IOHID property dictionary. Enumerate broadly, then apply
        // the product/usage filter locally.
        IOHIDManagerSetDeviceMatching(manager, nil)
        IOHIDManagerRegisterDeviceRemovalCallback(
            manager,
            tapDeviceRemovalCallback,
            Unmanaged.passUnretained(self).toOpaque()
        )
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetCurrent(), tapHIDRunLoopMode)

        let managerStatus = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        guard managerStatus == kIOReturnSuccess else {
            publishStatus(
                phase: .failed,
                message: "Unable to open the HID manager (\(statusDescription(managerStatus)))."
            )
            return
        }

        guard let deviceSet = IOHIDManagerCopyDevices(manager) else {
            publishStatus(phase: .noSensors, message: "No HID devices were discovered.")
            return
        }

        let candidates = (deviceSet as NSSet).allObjects.map { $0 as! IOHIDDevice }
        var opened: [(IOHIDDevice, DeviceContext)] = []
        var foundDescriptors: [SensorDescriptor] = []
        var openFailures: [(SensorDescriptor, IOReturn)] = []

        for device in candidates {
            guard let descriptor = makeDescriptor(for: device) else {
                continue
            }
            foundDescriptors.append(descriptor)

            let openStatus = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
            guard openStatus == kIOReturnSuccess else {
                openFailures.append((descriptor, openStatus))
                continue
            }

            let context = DeviceContext(reader: self, descriptor: descriptor, device: device)
            IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetCurrent(), tapHIDRunLoopMode)
            IOHIDDeviceRegisterInputReportWithTimeStampCallback(
                device,
                context.reportBuffer,
                Self.reportBufferLength,
                tapReportTimestampCallback,
                Unmanaged.passUnretained(context).toOpaque()
            )
            opened.append((device, context))
        }

        lock.lock()
        descriptors = foundDescriptors
        devices = opened
        sensorServiceLost = false
        lock.unlock()

        guard opened.count >= 2 else {
            let message: String
            if let firstFailure = openFailures.first {
                let failedProducts = openFailures.map { $0.0.product }.joined(separator: ", ")
                let status = statusDescription(firstFailure.1)
                if openFailures.contains(where: { $0.1 == kIOReturnNotPermitted }) {
                    message = "macOS denied access to the \(failedProducts) HID sensor(s) (\(status)). "
                        + "Allow Tap in System Settings > Privacy & Security > Input Monitoring, then retry."
                } else {
                    message = "Could not open the \(failedProducts) HID sensor(s) (\(status))."
                }
            } else {
                message = "Both the accelerometer and gyroscope are required; only "
                    + "\(opened.count) supported sensor device(s) could be opened."
            }
            publishStatus(
                phase: .noSensors,
                message: message
            )
            return
        }

        publishStatus(phase: .streaming)
    }

    public func stop() {
        lock.lock()
        guard started else {
            lock.unlock()
            return
        }
        started = false
        let devices = self.devices
        self.devices.removeAll(keepingCapacity: false)
        lock.unlock()

        for (device, context) in devices {
            IOHIDDeviceUnscheduleFromRunLoop(device, CFRunLoopGetCurrent(), tapHIDRunLoopMode)
            IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
            _ = Unmanaged.passUnretained(context)
        }
        IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetCurrent(), tapHIDRunLoopMode)
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        publishStatus(phase: .stopped)
    }

    fileprivate func handle(
        channel: SensorChannel,
        report: UnsafeMutablePointer<UInt8>,
        length: CFIndex
    ) {
        guard length > 0, length <= Self.reportBufferLength else {
            lock.lock()
            parseErrorCount += 1
            lock.unlock()
            return
        }

        let bytes = Array(UnsafeBufferPointer(start: report, count: length))
        do {
            let parsed = try IMUReportParser().parse(channel: channel, bytes: bytes)
            let timestamp = DispatchTime.now().uptimeNanoseconds

            lock.lock()
            parsedSampleCount += 1
            lock.unlock()

            let sample = MotionSample(timestampNanoseconds: timestamp, parsed: parsed)
            sampleHandler(sample, parsed)
        } catch {
            lock.lock()
            parseErrorCount += 1
            lock.unlock()
        }
    }

    fileprivate func handleDeviceRemoval(_ device: IOHIDDevice) {
        guard makeDescriptor(for: device) != nil else {
            return
        }
        lock.lock()
        sensorServiceLost = true
        lock.unlock()
        publishStatus(
            phase: .noSensors,
            message: "A motion sensor service disappeared; retrying the connection."
        )
    }

    private func publishStatus(phase: SensorReaderPhase, message: String? = nil) {
        lock.lock()
        let status = SensorReaderStatus(
            phase: phase,
            descriptors: descriptors,
            openedDeviceCount: sensorServiceLost ? 0 : devices.count,
            parsedSampleCount: parsedSampleCount,
            parseErrorCount: parseErrorCount,
            message: message
        )
        lock.unlock()
        statusHandler(status)
    }

    fileprivate final class DeviceContext: @unchecked Sendable {
        let reader: AppleSPUHIDReader
        let descriptor: SensorDescriptor
        let device: IOHIDDevice
        let reportBuffer: UnsafeMutablePointer<UInt8>

        init(reader: AppleSPUHIDReader, descriptor: SensorDescriptor, device: IOHIDDevice) {
            self.reader = reader
            self.descriptor = descriptor
            self.device = device
            reportBuffer = .allocate(capacity: AppleSPUHIDReader.reportBufferLength)
            reportBuffer.initialize(
                repeating: 0,
                count: AppleSPUHIDReader.reportBufferLength
            )
        }

        deinit {
            reportBuffer.deinitialize(count: AppleSPUHIDReader.reportBufferLength)
            reportBuffer.deallocate()
        }
    }
}

nonisolated(unsafe) private let tapReportTimestampCallback: IOHIDReportWithTimeStampCallback = {
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

    let deviceContext = Unmanaged<AppleSPUHIDReader.DeviceContext>
        .fromOpaque(context)
        .takeUnretainedValue()
    deviceContext.reader.handle(
        channel: deviceContext.descriptor.usage == 9 ? .gyroscope : .accelerometer,
        report: report,
        length: reportLength
    )
}

nonisolated(unsafe) private let tapDeviceRemovalCallback: IOHIDDeviceCallback = {
    context,
    result,
    _,
    device in
    guard result == kIOReturnSuccess,
          let context else {
        return
    }
    let reader = Unmanaged<AppleSPUHIDReader>
        .fromOpaque(context)
        .takeUnretainedValue()
    reader.handleDeviceRemoval(device)
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
    (property(device, key: key) as? NSNumber)?.uint32Value
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
        return
    }

    var iterator: io_iterator_t = 0
    guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
        return
    }
    defer { IOObjectRelease(iterator) }

    let requests: [(String, NSNumber)] = [
        ("SensorPropertyReportingState", NSNumber(value: 1)),
        ("SensorPropertyPowerState", NSNumber(value: 1)),
        ("ReportInterval", NSNumber(value: 1_000)),
    ]

    while true {
        let service = IOIteratorNext(iterator)
        guard service != 0 else {
            break
        }
        for (key, value) in requests {
            _ = IORegistryEntrySetCFProperty(service, key as CFString, value)
        }
        IOObjectRelease(service)
    }
}

private func statusDescription(_ status: IOReturn) -> String {
    "IOReturn 0x\(String(status, radix: 16, uppercase: true))"
}
