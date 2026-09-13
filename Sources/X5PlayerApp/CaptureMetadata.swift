import Foundation

/// Everything the player can say about when and where a capture was made.
struct CaptureMetadata {
    /// From the MP4 movie header. Usually UTC.
    var containerCreated: Date?
    var containerModified: Date?
    /// From the camera's own file name. Usually the camera's local time.
    var filenameDate: Date?
    /// From the first GPS fix. Always UTC.
    var gpsDate: Date?
    var gpsFixCount: Int = 0
    var firstFix: GPSFix?
    var lastFix: GPSFix?
    var gpsLayout: String?
    /// Free-form strings found in the container's `udta` boxes.
    var containerText: [String] = []
    var topLevelBoxes: [String] = []

    /// The timestamp to show, preferring the one that is least likely to have
    /// been rewritten by a copy or an edit.
    var bestDate: Date? { gpsDate ?? filenameDate ?? containerCreated }

    /// Local wall-clock time minus UTC, when both are known. This is the number
    /// the file name carries and the container does not.
    var filenameOffsetFromUTC: TimeInterval? {
        guard let filenameDate, let reference = gpsDate ?? containerCreated else { return nil }
        return filenameDate.timeIntervalSince(reference)
    }
}

/// Minimal big-endian MP4 box reader.
///
/// Only enough of the container is walked to reach `mvhd` for the capture date
/// and `udta` for the free-form strings the camera leaves there, so opening an
/// 8K capture costs a few seeks rather than a full read.
enum MP4Reader {
    /// Seconds between the QuickTime epoch (1904-01-01) and the Unix epoch.
    static let epochOffset: TimeInterval = 2_082_844_800
    static let maximumMoov = 64 * 1024 * 1024

    static func read(url: URL) -> CaptureMetadata {
        var metadata = CaptureMetadata()
        metadata.filenameDate = dateFromFilename(url.lastPathComponent)

        guard let handle = try? FileHandle(forReadingFrom: url) else { return metadata }
        defer { try? handle.close() }
        guard let fileSize = try? handle.seekToEnd() else { return metadata }

        var offset: UInt64 = 0
        var moov: (offset: UInt64, size: UInt64)?
        while offset + 8 <= fileSize {
            try? handle.seek(toOffset: offset)
            guard let header = try? handle.read(upToCount: 16), header.count >= 8 else { break }
            let bytes = [UInt8](header)
            var size = UInt64(be32(bytes, 0))
            var headerSize: UInt64 = 8
            let type = fourCharacterCode(bytes, 4)
            if size == 1 {
                guard bytes.count >= 16 else { break }
                size = be64(bytes, 8)
                headerSize = 16
            } else if size == 0 {
                size = fileSize - offset
            }
            guard size >= headerSize, offset + size <= fileSize else { break }
            metadata.topLevelBoxes.append(type)
            if type == "moov" { moov = (offset + headerSize, size - headerSize) }
            offset += size
        }

        guard let moov, moov.size > 0, moov.size <= UInt64(maximumMoov) else { return metadata }
        try? handle.seek(toOffset: moov.offset)
        guard let body = try? handle.read(upToCount: Int(moov.size)), body.count > 0 else { return metadata }
        walk([UInt8](body), into: &metadata)
        return metadata
    }

    /// Recursive descent through the boxes that can contain what we want.
    private static func walk(_ bytes: [UInt8], into metadata: inout CaptureMetadata) {
        // Deliberately not mdia/minf/stbl: the sample tables are large, and
        // nothing we want lives under them.
        let containers: Set<String> = ["moov", "trak", "udta", "meta", "ilst"]
        var cursor = 0
        while cursor + 8 <= bytes.count {
            var size = Int(be32(bytes, cursor))
            var headerSize = 8
            let type = fourCharacterCode(bytes, cursor + 4)
            if size == 1 {
                guard cursor + 16 <= bytes.count else { return }
                size = Int(be64(bytes, cursor + 8))
                headerSize = 16
            } else if size == 0 {
                size = bytes.count - cursor
            }
            guard size >= headerSize, cursor + size <= bytes.count else { return }

            let payload = Array(bytes[(cursor + headerSize)..<(cursor + size)])
            if type == "mvhd" {
                readMovieHeader(payload, into: &metadata)
            } else if type == "udta" {
                collectText(payload, into: &metadata)
                walk(payload, into: &metadata)
            } else if containers.contains(type) {
                walk(payload, into: &metadata)
            } else if let text = INSVTrailerReader.printableText(Data(payload)) {
                metadata.containerText.append(text)
            }
            cursor += size
        }
    }

    private static func readMovieHeader(_ bytes: [UInt8], into metadata: inout CaptureMetadata) {
        guard bytes.count >= 20 else { return }
        let version = bytes[0]
        if version == 1 {
            guard bytes.count >= 28 else { return }
            metadata.containerCreated = date(from: Double(be64(bytes, 4)))
            metadata.containerModified = date(from: Double(be64(bytes, 12)))
        } else {
            metadata.containerCreated = date(from: Double(be32(bytes, 4)))
            metadata.containerModified = date(from: Double(be32(bytes, 8)))
        }
    }

    private static func collectText(_ bytes: [UInt8], into metadata: inout CaptureMetadata) {
        guard let text = INSVTrailerReader.printableText(Data(bytes)) else { return }
        metadata.containerText.append(text)
    }

    private static func date(from quickTimeSeconds: Double) -> Date? {
        guard quickTimeSeconds > epochOffset else { return nil }
        return Date(timeIntervalSince1970: quickTimeSeconds - epochOffset)
    }

    /// The camera names its files `VID_20250913_143022_00_001.insv`, in the
    /// camera's local time, which is the only place that offset survives.
    static func dateFromFilename(_ name: String) -> Date? {
        let digits = Array(name)
        var index = 0
        while index + 15 <= digits.count {
            let datePart = String(digits[index..<(index + 8)])
            let separator = digits[index + 8]
            let timePart = String(digits[(index + 9)..<(index + 15)])
            if separator == "_", datePart.allSatisfy(\.isNumber), timePart.allSatisfy(\.isNumber) {
                var components = DateComponents()
                components.year = Int(datePart.prefix(4))
                components.month = Int(datePart.dropFirst(4).prefix(2))
                components.day = Int(datePart.dropFirst(6).prefix(2))
                components.hour = Int(timePart.prefix(2))
                components.minute = Int(timePart.dropFirst(2).prefix(2))
                components.second = Int(timePart.dropFirst(4).prefix(2))
                if let year = components.year, year >= 2015, year <= 2100,
                   let month = components.month, month >= 1, month <= 12,
                   let day = components.day, day >= 1, day <= 31 {
                    var calendar = Calendar(identifier: .gregorian)
                    // The name carries no zone, so it is read as wall-clock UTC
                    // and compared against the container date to expose the offset.
                    calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
                    return calendar.date(from: components)
                }
            }
            index += 1
        }
        return nil
    }

    // MARK: - Big-endian readers

    static func be32(_ bytes: [UInt8], _ index: Int) -> UInt32 {
        guard index >= 0, index + 4 <= bytes.count else { return 0 }
        var value: UInt32 = 0
        for step in 0..<4 { value = (value << 8) | UInt32(bytes[index + step]) }
        return value
    }

    static func be64(_ bytes: [UInt8], _ index: Int) -> UInt64 {
        guard index >= 0, index + 8 <= bytes.count else { return 0 }
        var value: UInt64 = 0
        for step in 0..<8 { value = (value << 8) | UInt64(bytes[index + step]) }
        return value
    }

    static func fourCharacterCode(_ bytes: [UInt8], _ index: Int) -> String {
        guard index >= 0, index + 4 <= bytes.count else { return "????" }
        let characters = bytes[index..<(index + 4)].map { byte -> Character in
            (byte >= 0x20 && byte < 0x7F) ? Character(UnicodeScalar(byte)) : "?"
        }
        return String(characters)
    }
}

extension CaptureMetadata {
    static let displayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()

    static func describe(_ date: Date?) -> String {
        guard let date else { return "-" }
        return displayFormatter.string(from: date) + " UTC"
    }

    static func describeOffset(_ interval: TimeInterval?) -> String? {
        guard let interval, abs(interval) >= 60 else { return nil }
        let minutes = Int((interval / 60).rounded())
        let sign = minutes >= 0 ? "+" : "-"
        return String(format: "file name time = UTC %@%02d:%02d", sign, abs(minutes) / 60, abs(minutes) % 60)
    }
}
