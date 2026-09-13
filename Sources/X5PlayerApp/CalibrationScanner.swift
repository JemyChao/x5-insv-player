import Foundation

/// Pulls the camera's own stitch parameters out of block 0x0101.
///
/// The camera stores several representations of the same calibration as
/// underscore-separated number lists. The one this uses, verified on an X5
/// capture, carries sixteen fields per lens:
///
///     <lens count>_ radius_cx_cy_ a0_a1_a2_ tx_ty_tz_ k1_k2_k3_k4_ width_height_code  (x2)  _checksum
///
/// `radius`, `cx` and `cy` are pixels on a canvas `width` x `height` that holds
/// both fisheye circles, and k1...k4 are the radial polynomial in the same form
/// the shader uses: on the X5 sample they sum to 0.996 at the rim, which is the
/// normalised radius the model expects there.
///
/// A shorter `p2_` form carrying only six fields per lens is used as a fallback.
enum CalibrationScanner {
    static let fullFieldsPerLens = 16
    static let compactFieldsPerLens = 6

    /// Maximal runs of digits, dots, minus signs and underscores. The list is
    /// embedded in protobuf, so this isolates it without needing to decode that.
    static func numericRuns(in text: String) -> [[Double]] {
        var runs: [[Double]] = []
        var current = ""
        func flush() {
            defer { current = "" }
            guard current.contains("_") else { return }
            let parts = current.split(separator: "_", omittingEmptySubsequences: true)
            guard parts.count >= 13 else { return }
            let numbers = parts.compactMap { Double($0) }
            guard numbers.count == parts.count else { return }
            runs.append(numbers)
        }
        for character in text {
            if character.isNumber || character == "." || character == "-" || character == "_" {
                current.append(character)
            } else {
                flush()
            }
        }
        flush()
        return runs
    }

    /// Kept for the diagnostic dump, which lists every candidate it finds.
    static func candidates(in text: String) -> [[Double]] { numericRuns(in: text) }

    static func profile(from blobs: [String], notes: inout [String]) -> LensProfile? {
        var fallback: LensProfile?
        for blob in blobs {
            for run in numericRuns(in: blob) {
                let count = Int(run[0])
                guard count == 2 else { continue }
                if run.count == 1 + fullFieldsPerLens * count + 1,
                   let profile = build(run, fieldsPerLens: fullFieldsPerLens, lensCount: count, hasPolynomial: true) {
                    notes.append("lens calibration read from the capture (\(run.count) value list)")
                    return profile
                }
                if fallback == nil, run.count == 1 + compactFieldsPerLens * count + 3,
                   let profile = build(run, fieldsPerLens: compactFieldsPerLens, lensCount: count, hasPolynomial: false) {
                    fallback = profile
                }
            }
        }
        if let fallback {
            notes.append("only the short calibration form was found; radial distortion left at the default")
            return fallback
        }
        if !blobs.isEmpty { notes.append("no recognisable calibration list; using the built-in profile") }
        return nil
    }

    private static func build(_ run: [Double], fieldsPerLens: Int, lensCount: Int, hasPolynomial: Bool) -> LensProfile? {
        // The canvas size trails each lens block in the long form and the whole
        // list in the short one.
        let canvas: (width: Double, height: Double)
        if hasPolynomial {
            canvas = (run[1 + fieldsPerLens - 3], run[1 + fieldsPerLens - 2])
        } else {
            canvas = (run[1 + fieldsPerLens * lensCount], run[1 + fieldsPerLens * lensCount + 1])
        }
        guard canvas.width > 16, canvas.height > 16 else { return nil }

        var geometries: [LensGeometry] = []
        var headings: [Double] = []
        for lens in 0..<lensCount {
            let base = 1 + lens * fieldsPerLens
            let radius = run[base]
            let centreX = run[base + 1]
            let centreY = run[base + 2]
            let roll = run[base + 3]
            let pitch = run[base + 4]
            let heading = run[base + 5]

            // Lanes are side by side on a wide canvas and stacked on a tall one;
            // which lane a lens lives in comes from its own centre.
            let laneWidth = canvas.width > canvas.height ? canvas.width / Double(lensCount) : canvas.width
            let laneHeight = canvas.width > canvas.height ? canvas.height : canvas.height / Double(lensCount)
            let laneX = canvas.width > canvas.height
                ? laneWidth * Double(min(lensCount - 1, max(0, Int(centreX / laneWidth)))) : 0
            let laneY = canvas.width > canvas.height
                ? 0 : laneHeight * Double(min(lensCount - 1, max(0, Int(centreY / laneHeight))))

            var geometry = LensGeometry()
            geometry.centerX = Float((centreX - laneX) / laneWidth)
            geometry.centerY = Float((centreY - laneY) / laneHeight)
            geometry.radiusX = Float(radius / laneWidth)
            geometry.radiusY = Float(radius / laneHeight)
            geometry.rollDegrees = Float(roll)
            geometry.pitchDegrees = Float(pitch)
            if hasPolynomial {
                geometry.k1 = Float(run[base + 9])
                geometry.k2 = Float(run[base + 10])
                geometry.k3 = Float(run[base + 11])
                geometry.k4 = Float(run[base + 12])
            }

            guard (0.2...0.8).contains(geometry.centerX), (0.2...0.8).contains(geometry.centerY),
                  (0.2...0.9).contains(geometry.radiusX) else { return nil }
            geometries.append(geometry)
            headings.append(heading)
        }
        guard geometries.count == 2 else { return nil }

        // The headings share a convention offset of about 90 degrees, so they
        // are made relative to the front lens instead of taken at face value.
        let reference = headings[0]
        geometries[0].yawDegrees = 0
        geometries[1].yawDegrees = Float(headings[1] - reference) + 180

        var profile = LensProfile()
        profile.front = geometries[0]
        profile.back = geometries[1]
        profile.name = "capture calibration"
        profile.origin = hasPolynomial
            ? "capture calibration (centre, radius, quartic)"
            : "capture calibration (centre, radius only)"
        return profile
    }
}

/// Model, serial and firmware live as plain strings at the head of block 0x0101.
enum CameraIdentity {
    /// The literal model string the camera writes into block 0x0101. This is a
    /// value to match against data, not a name this project claims any tie to.
    static let modelPrefix = "Insta360"

    static func scan(_ data: Data) -> (model: String?, serial: String?, firmware: String?) {
        var model: String?
        var serial: String?
        var firmware: String?
        for text in strings(in: data, minimumLength: 5) {
            if model == nil, text.hasPrefix(Self.modelPrefix) { model = text }
            else if firmware == nil, text.hasPrefix("v"), text.contains("_build") {
                firmware = text.split(separator: "*").first.map(String.init) ?? text
            } else if serial == nil, text.count >= 10, text.count <= 24,
                      text.allSatisfy({ $0.isUppercase || $0.isNumber }) {
                serial = text
            }
        }
        return (model, serial, firmware)
    }

    static func strings(in data: Data, minimumLength: Int) -> [String] {
        var found: [String] = []
        var current: [UInt8] = []
        for byte in data {
            if byte >= 0x20, byte < 0x7F {
                current.append(byte)
            } else {
                if current.count >= minimumLength { found.append(String(decoding: current, as: UTF8.self)) }
                current.removeAll(keepingCapacity: true)
            }
        }
        if current.count >= minimumLength { found.append(String(decoding: current, as: UTF8.self)) }
        return found
    }
}
