import Foundation

public enum SensorChannel: String, Codable, CaseIterable, Sendable {
    case accelerometer
    case gyroscope
}

public struct ParsedReport: Codable, Equatable, Sendable {
    public let channel: SensorChannel
    public let rawX: Int32
    public let rawY: Int32
    public let rawZ: Int32
    public let x: Double
    public let y: Double
    public let z: Double

    public init(
        channel: SensorChannel,
        rawX: Int32,
        rawY: Int32,
        rawZ: Int32,
        scale: Double
    ) {
        self.channel = channel
        self.rawX = rawX
        self.rawY = rawY
        self.rawZ = rawZ
        self.x = Double(rawX) / scale
        self.y = Double(rawY) / scale
        self.z = Double(rawZ) / scale
    }
}

public enum ReportParserError: Error, Equatable, Sendable {
    case reportTooShort(actual: Int, minimum: Int)
}

public struct IMUReportParser: Sendable {
    public static let expectedReportLength = 22
    public static let vectorOffset = 6

    public let scale: Double

    public init(scale: Double = 65_536.0) {
        precondition(scale > 0, "Sensor scale must be positive")
        self.scale = scale
    }

    public func parse(channel: SensorChannel, bytes: [UInt8]) throws -> ParsedReport {
        guard bytes.count >= Self.expectedReportLength else {
            throw ReportParserError.reportTooShort(
                actual: bytes.count,
                minimum: Self.expectedReportLength
            )
        }

        let x = readInt32LittleEndian(bytes, offset: Self.vectorOffset)
        let y = readInt32LittleEndian(bytes, offset: Self.vectorOffset + 4)
        let z = readInt32LittleEndian(bytes, offset: Self.vectorOffset + 8)

        return ParsedReport(
            channel: channel,
            rawX: x,
            rawY: y,
            rawZ: z,
            scale: scale
        )
    }

    private func readInt32LittleEndian(_ bytes: [UInt8], offset: Int) -> Int32 {
        let value = UInt32(bytes[offset])
            | (UInt32(bytes[offset + 1]) << 8)
            | (UInt32(bytes[offset + 2]) << 16)
            | (UInt32(bytes[offset + 3]) << 24)
        return Int32(bitPattern: value)
    }
}

public struct TraceRecord: Codable, Equatable, Sendable {
    public let timestampNanoseconds: UInt64
    public let sequence: UInt64
    public let channel: SensorChannel
    public let rawX: Int32
    public let rawY: Int32
    public let rawZ: Int32
    public let x: Double
    public let y: Double
    public let z: Double

    public init(
        timestampNanoseconds: UInt64,
        sequence: UInt64,
        parsed: ParsedReport
    ) {
        self.timestampNanoseconds = timestampNanoseconds
        self.sequence = sequence
        self.channel = parsed.channel
        self.rawX = parsed.rawX
        self.rawY = parsed.rawY
        self.rawZ = parsed.rawZ
        self.x = parsed.x
        self.y = parsed.y
        self.z = parsed.z
    }
}
