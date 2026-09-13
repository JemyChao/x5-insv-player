import Foundation
import simd

/// One IMU reading from the INSV trailer.
struct MotionSample {
    var time: Double            // seconds from the first video frame
    var gyro: SIMD3<Double>     // rad/s
    var accel: SIMD3<Double>    // g
}

/// One GPS fix from the 0x0700 block.
struct GPSFix {
    var time: Date?
    var latitude: Double
    var longitude: Double
    var altitude: Double?
}

struct INSVBlock {
    let id: UInt16
    let offset: Int
    let length: Int
    let data: Data

    var name: String { INSVBlock.knownNames[id] ?? String(format: "unknown 0x%04x", id) }

    static let knownNames: [UInt16: String] = [
        0x0100: "preview image",
        0x0101: "camera info + lens calibration",
        0x0200: "preview stream",
        0x0300: "gyro / accelerometer",
        0x0400: "exposure times",
        0x0600: "frame timestamps",
        0x0700: "gps"
    ]
}

struct INSVTrailer {
    var trailerLength = 0
    var version: UInt32 = 0
    var blocks: [INSVBlock] = []
    var motion: [MotionSample] = []
    var exposures: [(time: Double, value: Double)] = []
    var gps: [GPSFix] = []
    var gpsLayout: String?
    var frameTimestamps = 0
    var textBlobs: [String] = []
    var previewImage: Data?
    var calibration: LensProfile?
    var cameraModel: String?
    var serialNumber: String?
    var firmware: String?
    var notes: [String] = []
}

/// Reads the metadata trailer Insta360 appends after the MP4 data.
///
/// Verified against an Insta360 X5 capture (firmware v1.11.6). The trailer is
/// also exposed as a top-level MP4 box of type `inst`, and ends with a 78 byte
/// footer: the last 32 bytes are the ASCII magic, offset 38 holds the trailer
/// length and offset 2 the size of the block index that sits just in front of
/// the footer. The index is a flat array of ten byte slots, so blocks are found
/// by lookup rather than by walking a chain.
enum INSVTrailerReader {
    static let magic = Array("8db42d694ccc418790edff439fe026bf".utf8)
    static let footerLength = 78
    static let slotLength = 10
    static let maximumBlock = 64 * 1024 * 1024

    static func read(url: URL, videoDuration: Double) -> INSVTrailer? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let fileSize = try? handle.seekToEnd(), fileSize > UInt64(footerLength) else { return nil }

        // Normally the last 32 bytes, but anything appended after the trailer
        // would hide the magic, so the tail is searched before giving up.
        guard let end = locateMagicEnd(handle: handle, fileSize: fileSize),
              end >= UInt64(footerLength) else { return nil }

        try? handle.seek(toOffset: end - UInt64(footerLength))
        guard let footerData = try? handle.read(upToCount: footerLength),
              footerData.count == footerLength else { return nil }
        let footer = [UInt8](footerData)
        guard Array(footer.suffix(32)) == magic else { return nil }

        var result = INSVTrailer()
        if end != fileSize {
            result.notes.append("trailer magic sits \(fileSize - end) bytes before the end of the file")
        }

        let indexSize = Int(u32(footer, 2))
        let length = Int(u32(footer, 38))
        result.version = u32(footer, 42)
        guard length > footerLength, UInt64(length) <= end else {
            result.notes.append("trailer length field read as \(length), which is not usable")
            return result
        }
        result.trailerLength = length
        let trailerStart = end - UInt64(length)

        guard indexSize >= slotLength, indexSize < length,
              let indexData = read(handle, at: end - UInt64(footerLength) - UInt64(indexSize), count: indexSize) else {
            result.notes.append("block index size read as \(indexSize), which is not usable")
            return result
        }

        result.blocks = readIndex([UInt8](indexData), handle: handle, trailerStart: trailerStart,
                                  trailerLength: length, notes: &result.notes)
        guard !result.blocks.isEmpty else {
            result.notes.append("magic and index found but no block slot was usable")
            return result
        }

        var notes = result.notes
        // Exposure records carry one timestamp per video frame on the same
        // clock as the IMU, so the first of them is where video time zero is.
        var origin: UInt64?
        if let exposure = result.blocks.first(where: { $0.id == 0x0400 }), exposure.data.count >= 16 {
            origin = u64([UInt8](exposure.data), 0)
        }

        for block in result.blocks {
            switch block.id {
            case 0x0300:
                result.motion = decodeMotion(block.data, origin: origin, notes: &notes)
            case 0x0400:
                result.exposures = decodeExposures(block.data, origin: origin)
            case 0x0600:
                result.frameTimestamps = block.data.count / 8
            case 0x0700:
                let decoded = decodeGPS(block.data, notes: &notes)
                result.gps = decoded.fixes
                result.gpsLayout = decoded.layout
            case 0x0100, 0x0200:
                if block.data.count > 4, block.data[block.data.startIndex] == 0xFF,
                   block.data[block.data.index(after: block.data.startIndex)] == 0xD8 {
                    result.previewImage = block.data
                }
            default:
                break
            }
            // Pull printable runs rather than testing the whole block: the
            // calibration list is embedded in protobuf, so a ratio test on the
            // block as a whole is the wrong question.
            if block.length <= 1 << 18 {
                result.textBlobs.append(contentsOf: CameraIdentity.strings(in: block.data, minimumLength: 24))
            }
        }

        if let info = result.blocks.first(where: { $0.id == 0x0101 }) {
            let identity = CameraIdentity.scan(info.data)
            result.cameraModel = identity.model
            result.serialNumber = identity.serial
            result.firmware = identity.firmware
        }
        result.calibration = CalibrationScanner.profile(from: result.textBlobs, notes: &notes)
        result.notes = notes
        if videoDuration > 0, let last = result.motion.last, last.time < videoDuration * 0.5 {
            result.notes.append("IMU track covers only \(String(format: "%.1f", last.time)) s of a \(String(format: "%.1f", videoDuration)) s capture")
        }
        return result
    }

    // MARK: - Locating the trailer

    private static func read(_ handle: FileHandle, at offset: UInt64, count: Int) -> Data? {
        guard count > 0, count <= maximumBlock else { return nil }
        try? handle.seek(toOffset: offset)
        guard let data = try? handle.read(upToCount: count), data.count == count else { return nil }
        return data
    }

    private static func locateMagicEnd(handle: FileHandle, fileSize: UInt64) -> UInt64? {
        let magicCount = UInt64(magic.count)
        if fileSize >= magicCount {
            try? handle.seek(toOffset: fileSize - magicCount)
            if let tail = try? handle.read(upToCount: magic.count), Array(tail) == magic {
                return fileSize
            }
        }
        let window: UInt64 = 4 * 1024 * 1024
        let start = fileSize > window ? fileSize - window : 0
        try? handle.seek(toOffset: start)
        guard let data = try? handle.read(upToCount: Int(fileSize - start)), data.count >= magic.count else { return nil }
        let bytes = [UInt8](data)
        var index = bytes.count - magic.count
        while index >= 0 {
            if bytes[index] == magic[0], Array(bytes[index..<(index + magic.count)]) == magic {
                return start + UInt64(index) + magicCount
            }
            index -= 1
        }
        return nil
    }

    /// Ten byte slots: big-endian id, then little-endian length and offset from
    /// the start of the trailer. Empty slots are zero-filled and simply skipped.
    private static func readIndex(_ index: [UInt8], handle: FileHandle, trailerStart: UInt64,
                                  trailerLength: Int, notes: inout [String]) -> [INSVBlock] {
        var blocks: [INSVBlock] = []
        var skipped = 0
        for slot in 0..<(index.count / slotLength) {
            let base = slot * slotLength
            let id = UInt16(index[base]) << 8 | UInt16(index[base + 1])
            let length = Int(u32(index, base + 2))
            let offset = Int(u32(index, base + 6))
            if id == 0, length == 0 { continue }
            guard length > 0, offset >= 0, offset + length <= trailerLength else {
                skipped += 1
                continue
            }
            let payload = length <= maximumBlock
                ? read(handle, at: trailerStart + UInt64(offset), count: length)
                : nil
            blocks.append(INSVBlock(id: id, offset: offset, length: length, data: payload ?? Data()))
            if payload == nil {
                notes.append("block \(String(format: "0x%04x", id)) is \(length) bytes and was not loaded")
            }
        }
        if skipped > 0 { notes.append("\(skipped) index slot(s) did not point inside the trailer") }
        return blocks.sorted { $0.offset < $1.offset }
    }

    // MARK: - Payload decoding

    /// 20 byte records: a microsecond timestamp followed by six 16-bit channels
    /// biased by 0x8000 — accelerometer XYZ then gyro XYZ.
    ///
    /// The scale factors are the sensor's full-scale ranges, both confirmed
    /// against a real capture: mean accelerometer magnitude came out at 1039
    /// counts against the 1024 counts per g that +/-32 g implies, and fitting
    /// integrated gyro rotation to the accelerometer's tilt landed on the
    /// +/-1000 deg/s range.
    static let accelCountsPerG = 1024.0
    static let gyroRadiansPerCount = (1000.0 * Double.pi / 180.0) / 32768.0

    static func decodeMotion(_ data: Data, origin: UInt64?, notes: inout [String]) -> [MotionSample] {
        let bytes = [UInt8](data)
        let recordSize = 20
        guard bytes.count >= recordSize * 2 else { return [] }
        if bytes.count % recordSize != 0 {
            notes.append("IMU block is \(bytes.count) bytes, not a whole number of 20 byte records")
        }
        let count = bytes.count / recordSize
        let zero = origin ?? u64(bytes, 0)
        var samples: [MotionSample] = []
        samples.reserveCapacity(count)
        for index in 0..<count {
            let base = index * recordSize
            let raw = u64(bytes, base)
            let time = (Double(raw) - Double(zero)) / 1_000_000
            let channel = { (slot: Int) -> Double in
                Double(Int(u16(bytes, base + 8 + slot * 2)) - 32768)
            }
            let accel = SIMD3<Double>(channel(0), channel(1), channel(2)) / accelCountsPerG
            let gyro = SIMD3<Double>(channel(3), channel(4), channel(5)) * gyroRadiansPerCount
            samples.append(MotionSample(time: time, gyro: gyro, accel: accel))
        }
        return samples
    }

    /// 16 byte records: a microsecond timestamp and the shutter time in seconds.
    static func decodeExposures(_ data: Data, origin: UInt64?) -> [(time: Double, value: Double)] {
        let bytes = [UInt8](data)
        let recordSize = 16
        guard bytes.count >= recordSize else { return [] }
        let zero = origin ?? u64(bytes, 0)
        var result: [(time: Double, value: Double)] = []
        result.reserveCapacity(bytes.count / recordSize)
        for index in 0..<(bytes.count / recordSize) {
            let base = index * recordSize
            let time = (Double(u64(bytes, base)) - Double(zero)) / 1_000_000
            result.append((time: time, value: f64(bytes, base + 8)))
        }
        return result
    }

    /// The GPS record layout is not documented and no capture to hand contains
    /// one, so rather than hard-coding an offset this searches for the pair of
    /// adjacent doubles that behaves like a coordinate across the whole block.
    static func decodeGPS(_ data: Data, notes: inout [String]) -> (fixes: [GPSFix], layout: String?) {
        let bytes = [UInt8](data)
        guard bytes.count >= 32 else { return ([], nil) }
        let sizes = [53, 56, 52, 48, 64].filter { bytes.count % $0 == 0 && bytes.count / $0 >= 2 }
        for size in sizes {
            let count = bytes.count / size
            guard let coordinate = findCoordinateOffset(bytes, size: size, count: count) else { continue }
            let timeOffset = findTimeOffset(bytes, size: size, count: count, avoiding: coordinate)
            let altitudeOffset = findAltitudeOffset(bytes, size: size, count: count, after: coordinate + 16)
            var fixes: [GPSFix] = []
            for index in 0..<count {
                let base = index * size
                let latitude = f64(bytes, base + coordinate)
                let longitude = f64(bytes, base + coordinate + 8)
                guard latitude.isFinite, longitude.isFinite,
                      abs(latitude) <= 90, abs(longitude) <= 180,
                      !(latitude == 0 && longitude == 0) else { continue }
                var fix = GPSFix(time: nil, latitude: latitude, longitude: longitude, altitude: nil)
                if let timeOffset {
                    fix.time = Date(timeIntervalSince1970: Double(u32(bytes, base + timeOffset)))
                }
                if let altitudeOffset { fix.altitude = f64(bytes, base + altitudeOffset) }
                fixes.append(fix)
            }
            guard !fixes.isEmpty else { continue }
            let layout = "record \(size) B, lat/lon at +\(coordinate)"
                + (timeOffset.map { ", utc u32 at +\($0)" } ?? ", no timestamp found")
                + (altitudeOffset.map { ", altitude at +\($0)" } ?? "")
            notes.append("gps layout detected: \(layout)")
            return (fixes, layout)
        }
        notes.append("gps block present (\(bytes.count) bytes) but no usable coordinate layout was found")
        return ([], nil)
    }

    private static func findCoordinateOffset(_ bytes: [UInt8], size: Int, count: Int) -> Int? {
        var best: (offset: Int, score: Double)?
        for offset in 0...(size - 16) {
            var valid = 0
            var minLatitude = Double.infinity, maxLatitude = -Double.infinity
            var minLongitude = Double.infinity, maxLongitude = -Double.infinity
            for index in 0..<count {
                let base = index * size + offset
                let latitude = f64(bytes, base)
                let longitude = f64(bytes, base + 8)
                guard latitude.isFinite, longitude.isFinite,
                      abs(latitude) <= 90, abs(longitude) <= 180,
                      !(latitude == 0 && longitude == 0) else { continue }
                valid += 1
                minLatitude = min(minLatitude, latitude); maxLatitude = max(maxLatitude, latitude)
                minLongitude = min(minLongitude, longitude); maxLongitude = max(maxLongitude, longitude)
            }
            let fraction = Double(valid) / Double(count)
            guard fraction >= 0.5, valid >= 2 else { continue }
            guard maxLatitude - minLatitude < 5, maxLongitude - minLongitude < 5 else { continue }
            if let current = best {
                if fraction > current.score { best = (offset, fraction) }
            } else {
                best = (offset, fraction)
            }
        }
        return best?.offset
    }

    private static func findTimeOffset(_ bytes: [UInt8], size: Int, count: Int, avoiding coordinate: Int) -> Int? {
        let lower = 1_420_070_400.0
        let upper = 2_051_222_400.0
        for offset in 0...(size - 4) {
            if offset > coordinate - 4, offset < coordinate + 16 { continue }
            var previous = -Double.infinity
            var ok = true
            for index in 0..<count {
                let value = Double(u32(bytes, index * size + offset))
                if value < lower || value > upper || value < previous { ok = false; break }
                previous = value
            }
            if ok { return offset }
        }
        return nil
    }

    private static func findAltitudeOffset(_ bytes: [UInt8], size: Int, count: Int, after start: Int) -> Int? {
        guard start >= 0, start + 8 <= size else { return nil }
        for offset in start...(size - 8) {
            var ok = true
            for index in 0..<count {
                let value = f64(bytes, index * size + offset)
                if !value.isFinite || value < -500 || value > 12000 { ok = false; break }
            }
            if ok { return offset }
        }
        return nil
    }

    static func printableText(_ data: Data) -> String? {
        guard data.count >= 16, data.count <= 1 << 18 else { return nil }
        var printable = 0
        for byte in data where (byte >= 0x20 && byte < 0x7F) || byte == 0x0A || byte == 0x0D || byte == 0x09 {
            printable += 1
        }
        guard Double(printable) / Double(data.count) > 0.35 else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - Little-endian readers

    static func u16(_ bytes: [UInt8], _ index: Int) -> UInt16 {
        guard index >= 0, index + 2 <= bytes.count else { return 0 }
        return UInt16(bytes[index]) | UInt16(bytes[index + 1]) << 8
    }

    static func u32(_ bytes: [UInt8], _ index: Int) -> UInt32 {
        guard index >= 0, index + 4 <= bytes.count else { return 0 }
        var value: UInt32 = 0
        for step in 0..<4 { value |= UInt32(bytes[index + step]) << (8 * UInt32(step)) }
        return value
    }

    static func u64(_ bytes: [UInt8], _ index: Int) -> UInt64 {
        guard index >= 0, index + 8 <= bytes.count else { return 0 }
        var value: UInt64 = 0
        for step in 0..<8 { value |= UInt64(bytes[index + step]) << (8 * UInt64(step)) }
        return value
    }

    static func f64(_ bytes: [UInt8], _ index: Int) -> Double {
        Double(bitPattern: u64(bytes, index))
    }
}
