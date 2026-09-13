import Foundation
import simd

/// Fisheye model for one lens of an Insta360 X-series capture.
///
/// Every image-space value is expressed in normalised texture coordinates of
/// that lens' own video track, so the same profile survives a change of
/// recording resolution (5.7K vs 8K) as long as the circle stays centred the
/// same way.
struct LensGeometry: Codable, Equatable {
    /// Centre of the fisheye circle.
    var centerX: Float = 0.5
    var centerY: Float = 0.5
    /// Radius of the circle that maps to `fovDegrees / 2` away from the axis.
    var radiusX: Float = 0.5
    var radiusY: Float = 0.5
    /// Total field of view of the lens. X5 lenses are a little past 190 degrees.
    var fovDegrees: Float = 192.0
    var yawDegrees: Float = 0
    var pitchDegrees: Float = 0
    var rollDegrees: Float = 0
    /// -1 flips the axis. Texture V runs downwards, so -1 is the resting value.
    var mirrorU: Float = 1
    var mirrorV: Float = -1
    /// Brightness trim, used to match the two lenses across the seam.
    var gain: Float = 1
    /// Radial mapping r(t) = k1·t + k2·t² + k3·t³ + k4·t⁴ with t = θ / (fov/2).
    /// The identity (1, 0, 0, 0) is the equidistant lens every fisheye starts from.
    var k1: Float = 1
    var k2: Float = 0
    var k3: Float = 0
    var k4: Float = 0
}

extension LensGeometry {
    var halfFovRadians: Float { fovDegrees * .pi / 360 }

    var rotation: simd_quatf {
        let yaw = simd_quatf(angle: yawDegrees * .pi / 180, axis: SIMD3<Float>(0, 1, 0))
        let pitch = simd_quatf(angle: pitchDegrees * .pi / 180, axis: SIMD3<Float>(1, 0, 0))
        let roll = simd_quatf(angle: rollDegrees * .pi / 180, axis: SIMD3<Float>(0, 0, 1))
        return (yaw * pitch * roll).normalized
    }

    var geometryVector: SIMD4<Float> { SIMD4<Float>(centerX, centerY, radiusX, radiusY) }
    var optionVector: SIMD4<Float> { SIMD4<Float>(halfFovRadians, gain, mirrorU, mirrorV) }
    var polynomialVector: SIMD4<Float> { SIMD4<Float>(k1, k2, k3, k4) }
}

/// The pair of lens models plus the stitch settings that join them.
struct LensProfile: Codable, Equatable {
    var name: String = "X5 approximate"
    var front = LensGeometry()
    var back = LensGeometry(yawDegrees: 180)
    /// Set when the two video tracks arrive in the opposite order.
    var swapTracks: Bool = false
    /// Width of the cross-fade band that hides the seam, measured from the rim inwards.
    var blendDegrees: Float = 8
    /// Where these numbers came from, shown in the UI.
    var origin: String = "built-in approximation"

    var blendRadians: Float { max(blendDegrees, 0.05) * .pi / 180 }
}

extension LensProfile {
    static var storageDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let directory = base.appendingPathComponent("X5INSVPlayer", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    static var storageURL: URL { storageDirectory.appendingPathComponent("lens-profile.json") }

    static func loadSaved() -> LensProfile? {
        guard let data = try? Data(contentsOf: storageURL) else { return nil }
        return try? JSONDecoder().decode(LensProfile.self, from: data)
    }

    func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(self) else { return }
        try? data.write(to: LensProfile.storageURL, options: .atomic)
    }
}
