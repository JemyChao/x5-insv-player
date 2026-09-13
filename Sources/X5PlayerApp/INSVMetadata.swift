import Foundation
import simd

/// The capture settings the camera writes into trailer record 1.
///
/// These are the numbers that were previously guessed or fitted. Reading them
/// matters: the gyro's full-scale range was assumed to be +/-1000 deg/s and is
/// actually +/-2000, and video time zero was taken from the first exposure
/// record and is actually `firstFrameTimestamp`, three quarters of a second
/// later, which pulled every orientation lookup that far out of step.
struct CaptureConfig {
    var cameraModel: String?
    var firmware: String?
    /// Microseconds on the same clock as the IMU and exposure records.
    var firstFrameTimestamp: UInt64 = 0
    var gyroTimestampMilliseconds: Double = 0
    var hasGyroTimestamp = false
    /// Selects the IMU record encoding: packed 16-bit, or 64-bit floats.
    var isRawGyro = true
    var accelRangeG: Double = 32
    var gyroRangeDegreesPerSecond: Double = 2000
    /// Six doubles whose split between gyro and accelerometer is not settled,
    /// so they are reported and not applied. A constant gyro bias is what the
    /// complementary filter exists to absorb; applying the wrong triple would
    /// inject an error the filter then has to fight.
    var calibrationBias: [Double] = []
    var lensWidth = 0
    var lensHeight = 0
    var calibrationV2: String?
    var calibrationV3: String?
    var flowStateOnline = false
    var rollingShutterMilliseconds: Double = 0

    var accelCountsPerG: Double { accelRangeG > 0 ? 32768 / accelRangeG : 1024 }
    var gyroRadiansPerCount: Double { (gyroRangeDegreesPerSecond * .pi / 180) / 32768 }
    var gyroOffsetSeconds: Double { hasGyroTimestamp ? gyroTimestampMilliseconds / 1000 : 0 }

    static func parse(_ data: Data) -> CaptureConfig {
        var config = CaptureConfig()
        for field in Protobuf.fields(in: [UInt8](data)) {
            switch field.number {
            case 2: config.cameraModel = field.string
            case 3: config.firmware = field.string
            case 19:
                for sub in Protobuf.fields(in: field.bytes) {
                    if sub.number == 1 { config.lensWidth = Int(sub.varint) }
                    if sub.number == 2 { config.lensHeight = Int(sub.varint) }
                }
            case 24: config.firstFrameTimestamp = field.varint
            case 25: config.rollingShutterMilliseconds = field.double
            case 28: config.gyroTimestampMilliseconds = field.double
            case 29: config.hasGyroTimestamp = field.varint != 0
            case 31: config.calibrationBias = field.packedDoubles
            case 42: config.flowStateOnline = field.varint != 0
            case 53: config.calibrationV2 = field.string
            case 54: config.calibrationV3 = field.string
            case 62: config.isRawGyro = field.varint != 0
            case 65:
                for sub in Protobuf.fields(in: field.bytes) {
                    if sub.number == 1, sub.varint > 0 { config.accelRangeG = Double(sub.varint) }
                    if sub.number == 2, sub.varint > 0 { config.gyroRangeDegreesPerSecond = Double(sub.varint) }
                }
            default: break
            }
        }
        return config
    }

    var summary: String {
        var parts: [String] = []
        if let cameraModel { parts.append(cameraModel) }
        if let firmware { parts.append(firmware) }
        parts.append(String(format: "±%.0f g / ±%.0f °/s", accelRangeG, gyroRangeDegreesPerSecond))
        if lensWidth > 0 { parts.append("\(lensWidth)x\(lensHeight)") }
        return parts.joined(separator: "  ")
    }
}

/// Just enough protobuf to read the record, with no schema and no dependency.
enum Protobuf {
    struct Field {
        let number: Int
        let wireType: Int
        let varint: UInt64
        let bytes: [UInt8]

        var string: String? {
            guard wireType == 2, !bytes.isEmpty else { return nil }
            return String(bytes: bytes, encoding: .utf8)
        }

        var double: Double {
            guard wireType == 1, bytes.count == 8 else { return 0 }
            var raw: UInt64 = 0
            for step in 0..<8 { raw |= UInt64(bytes[step]) << (8 * UInt64(step)) }
            return Double(bitPattern: raw)
        }

        /// A length-delimited run of little-endian doubles, which is how the
        /// bias field is written — it is not a nested message.
        var packedDoubles: [Double] {
            guard wireType == 2, bytes.count >= 8 else { return [] }
            return (0..<(bytes.count / 8)).map { index in
                var raw: UInt64 = 0
                for step in 0..<8 { raw |= UInt64(bytes[index * 8 + step]) << (8 * UInt64(step)) }
                return Double(bitPattern: raw)
            }
        }
    }

    static func fields(in bytes: [UInt8]) -> [Field] {
        var result: [Field] = []
        var index = 0
        while index < bytes.count, result.count < 4096 {
            guard let (key, afterKey) = varint(bytes, index) else { break }
            index = afterKey
            let number = Int(key >> 3)
            let wire = Int(key & 7)
            guard number > 0 else { break }
            switch wire {
            case 0:
                guard let (value, after) = varint(bytes, index) else { return result }
                index = after
                result.append(Field(number: number, wireType: wire, varint: value, bytes: []))
            case 1:
                guard index + 8 <= bytes.count else { return result }
                result.append(Field(number: number, wireType: wire, varint: 0,
                                    bytes: Array(bytes[index..<(index + 8)])))
                index += 8
            case 2:
                guard let (length, after) = varint(bytes, index), length < (1 << 28) else { return result }
                let end = after + Int(length)
                guard end <= bytes.count else { return result }
                result.append(Field(number: number, wireType: wire, varint: length,
                                    bytes: Array(bytes[after..<end])))
                index = end
            case 5:
                guard index + 4 <= bytes.count else { return result }
                result.append(Field(number: number, wireType: wire, varint: 0,
                                    bytes: Array(bytes[index..<(index + 4)])))
                index += 4
            default:
                return result
            }
        }
        return result
    }

    private static func varint(_ bytes: [UInt8], _ start: Int) -> (UInt64, Int)? {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        var index = start
        while index < bytes.count, shift < 64 {
            let byte = bytes[index]
            result |= UInt64(byte & 0x7F) << shift
            index += 1
            if byte & 0x80 == 0 { return (result, index) }
            shift += 7
        }
        return nil
    }
}
