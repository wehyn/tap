import Foundation
import TapProbeCore

private final class ReaderCheckState: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var accelerometerSamples = 0
    private(set) var gyroscopeSamples = 0

    func add(_ sample: MotionSample) {
        lock.lock()
        defer { lock.unlock() }
        switch sample.channel {
        case .accelerometer:
            accelerometerSamples += 1
        case .gyroscope:
            gyroscopeSamples += 1
        }
    }

    func snapshot() -> (Int, Int) {
        lock.lock()
        defer { lock.unlock() }
        return (accelerometerSamples, gyroscopeSamples)
    }
}

private let state = ReaderCheckState()
let reader = AppleSPUHIDReader(
    onSample: { sample, _ in
        state.add(sample)
    },
    onStatus: { status in
        print(
            "reader phase=\(status.phase.rawValue) "
                + "devices=\(status.openedDeviceCount) "
                + "descriptors=\(status.descriptors.map(\.product).joined(separator: ","))"
        )
        if let message = status.message {
            print("reader message=\(message)")
        }
    }
)

reader.start()
RunLoop.current.run(until: Date(timeIntervalSinceNow: 3))
reader.stop()

let (accelerometerSamples, gyroscopeSamples) = state.snapshot()
print(
    "reader samples accelerometer=\(accelerometerSamples) "
        + "gyroscope=\(gyroscopeSamples)"
)

guard accelerometerSamples > 0, gyroscopeSamples > 0 else {
    exit(EXIT_FAILURE)
}
