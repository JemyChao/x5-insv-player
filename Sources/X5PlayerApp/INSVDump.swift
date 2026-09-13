import Foundation
import simd

/// Command line inspector for the INSV metadata trailer.
///
/// The trailer layout is reverse engineered rather than documented, so this
/// prints what the parser actually saw. It is the fastest way to find out why a
/// particular capture did not yield calibration or gyro data.
enum INSVDump {
    static func run(paths: [String]) {
        guard !paths.isEmpty else {
            print("usage: X5INSVPlayer --dump <file.insv> [more.insv ...]")
            return
        }
        for path in paths {
            dump(URL(fileURLWithPath: path))
        }
    }

    private static func dump(_ url: URL) {
        print("==== \(url.lastPathComponent) ====")
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = attributes?[.size] as? Int
        print("file size: " + (size != nil ? "\(size!)" : "unknown") + " bytes")

        guard let trailer = INSVTrailerReader.read(url: url, videoDuration: 0) else {
            print("no trailer magic at the end of this file")
            return
        }

        print("trailer length: \(trailer.trailerLength) bytes, version \(trailer.version), \(trailer.blocks.count) blocks")
        let identity = [trailer.cameraModel, trailer.firmware, trailer.serialNumber].compactMap { $0 }
        if !identity.isEmpty { print("camera: " + identity.joined(separator: "  ")) }
        for block in trailer.blocks {
            print(String(format: "  id 0x%04x  offset %9d  %9d bytes  %@",
                         block.id, block.offset, block.length, block.name))
        }

        if !trailer.motion.isEmpty {
            let first = trailer.motion[0]
            let last = trailer.motion[trailer.motion.count - 1]
            let rate = Double(trailer.motion.count - 1) / max(last.time - first.time, 1e-6)
            print(String(format: "motion: %d samples, %.2f s span, %.1f Hz",
                         trailer.motion.count, last.time - first.time, rate))
            print(String(format: "  time range %.3f s to %.3f s relative to the first video frame", first.time, last.time))
            let peakGyro = trailer.motion.reduce(0.0) { max($0, simd_length($1.gyro)) }
            let meanAccel = trailer.motion.reduce(0.0) { $0 + simd_length($1.accel) } / Double(trailer.motion.count)
            print(String(format: "  peak |gyro| %.3f rad/s, mean |accel| %.3f g", peakGyro, meanAccel))
            if let track = MotionTrack(samples: trailer.motion) {
                print(String(format: "  gravity alignment %.2f°", track.alignmentDegrees))
            }
        } else {
            print("motion: none")
        }

        if !trailer.gps.isEmpty {
            print("gps: \(trailer.gps.count) fixes" + (trailer.gpsLayout.map { " (\($0))" } ?? ""))
            let first = trailer.gps[0]
            let last = trailer.gps[trailer.gps.count - 1]
            print(String(format: "  first %.6f, %.6f%@", first.latitude, first.longitude,
                         first.altitude.map { String(format: "  alt %.1f m", $0) } ?? ""))
            print(String(format: "  last  %.6f, %.6f", last.latitude, last.longitude))
            print("  first fix time: " + CaptureMetadata.describe(first.time))
        } else {
            print("gps: none")
        }
        if trailer.frameTimestamps > 0 {
            print("frame timestamps: \(trailer.frameTimestamps)")
        }

        let container = MP4Reader.read(url: url)
        print("container boxes: " + container.topLevelBoxes.joined(separator: " "))
        print("mvhd created:  " + CaptureMetadata.describe(container.containerCreated))
        print("mvhd modified: " + CaptureMetadata.describe(container.containerModified))
        print("filename time: " + CaptureMetadata.describe(container.filenameDate) + " (read as wall clock)")
        var withGPS = container
        withGPS.gpsDate = trailer.gps.first?.time
        if let offset = CaptureMetadata.describeOffset(withGPS.filenameOffsetFromUTC) {
            print("time zone: " + offset)
        }
        for text in container.containerText {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let shown = trimmed.count > 300 ? String(trimmed.prefix(300)) + "…" : trimmed
            print("udta text: \(shown)")
            for numbers in CalibrationScanner.candidates(in: text) {
                print("  numeric list (\(numbers.count)): \(numbers)")
            }
        }

        if !trailer.exposures.isEmpty {
            print("exposure records: \(trailer.exposures.count), first value \(trailer.exposures[0].value)")
        }
        if let preview = trailer.previewImage {
            print("preview image: \(preview.count) bytes of JPEG")
        }

        for blob in trailer.textBlobs {
            let trimmed = blob.trimmingCharacters(in: .whitespacesAndNewlines)
            let shown = trimmed.count > 400 ? String(trimmed.prefix(400)) + "…" : trimmed
            print("text blob: \(shown)")
            for numbers in CalibrationScanner.candidates(in: blob) {
                print("  numeric list (\(numbers.count)): \(numbers)")
            }
        }

        if let calibration = trailer.calibration {
            print("calibration applied: \(calibration.origin)")
            print("  front centre (\(calibration.front.centerX), \(calibration.front.centerY)) radius \(calibration.front.radiusX) fov \(calibration.front.fovDegrees)")
            print("  back  centre (\(calibration.back.centerX), \(calibration.back.centerY)) radius \(calibration.back.radiusX) fov \(calibration.back.fovDegrees)")
        } else {
            print("calibration: not recognised, the built-in profile stays in use")
        }

        for note in trailer.notes {
            print("note: \(note)")
        }
    }
}
