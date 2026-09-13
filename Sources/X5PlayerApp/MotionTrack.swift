import Foundation
import simd

/// Turns the raw IMU records from the INSV trailer into a camera orientation
/// the renderer can sample at any media time.
///
/// The IMU axes are not documented, but the accelerometer and the gyro share a
/// body frame, so a single unknown rotation relates them to the optical frame.
/// Averaging the accelerometer over the whole clip gives the gravity direction
/// in that body frame, and aligning it with world down fixes every axis that
/// matters for a level horizon. The one rotation left undetermined is a spin
/// about gravity, which is exactly the yaw the viewer controls anyway.
final class MotionTrack {
    let samples: [MotionSample]
    let sampleRate: Double
    let alignmentDegrees: Float

    private var times: [Double] = []
    private var orientations: [simd_quatf] = []

    static let identity = simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0))

    init?(samples: [MotionSample], invertGyro: Bool = false) {
        guard samples.count > 8 else { return nil }
        let span = samples[samples.count - 1].time - samples[0].time
        guard span > 0 else { return nil }
        self.samples = samples
        self.sampleRate = Double(samples.count - 1) / span

        var meanAccel = SIMD3<Double>(repeating: 0)
        for sample in samples { meanAccel += sample.accel }
        meanAccel /= Double(samples.count)
        let gravity = SIMD3<Float>(Float(meanAccel.x), Float(meanAccel.y), Float(meanAccel.z))
        let alignment: simd_quatf
        if simd_length(gravity) > 0.05 {
            alignment = MotionTrack.shortestArc(from: gravity, to: SIMD3<Float>(0, -1, 0))
        } else {
            alignment = MotionTrack.identity
        }
        self.alignmentDegrees = alignment.angle * 180 / .pi

        times.reserveCapacity(samples.count)
        orientations.reserveCapacity(samples.count)

        // Seed from the first usable gravity reading instead of identity, so the
        // horizon is already level on the first frame rather than converging
        // over the first fraction of a second.
        var orientation = MotionTrack.identity
        for sample in samples {
            let reading = alignment.act(SIMD3<Float>(Float(sample.accel.x), Float(sample.accel.y), Float(sample.accel.z)))
            let magnitude = simd_length(reading)
            if magnitude > 0.4, magnitude < 2.5 {
                orientation = MotionTrack.shortestArc(from: reading / magnitude, to: SIMD3<Float>(0, -1, 0))
                break
            }
        }

        var previousTime = samples[0].time
        let gyroSign: Float = invertGyro ? -1 : 1
        for sample in samples {
            let delta = Float(max(0, min(0.25, sample.time - previousTime)))
            previousTime = sample.time

            let rawGyro = SIMD3<Float>(Float(sample.gyro.x), Float(sample.gyro.y), Float(sample.gyro.z))
            let rate = alignment.act(rawGyro) * gyroSign
            if delta > 0 {
                let angle = simd_length(rate) * delta
                if angle > 1e-7 {
                    let step = simd_quatf(angle: angle, axis: rate / simd_length(rate))
                    orientation = (orientation * step).normalized
                }
            }

            // Complementary correction: nudge the integrated orientation so the
            // measured gravity keeps pointing down, which cancels gyro drift
            // without fighting genuine motion.
            let rawAccel = SIMD3<Float>(Float(sample.accel.x), Float(sample.accel.y), Float(sample.accel.z))
            let measured = alignment.act(rawAccel)
            let magnitude = simd_length(measured)
            if magnitude > 0.4, magnitude < 2.5 {
                let inWorld = orientation.act(measured / magnitude)
                let correction = MotionTrack.shortestArc(from: inWorld, to: SIMD3<Float>(0, -1, 0))
                let eased = simd_slerp(MotionTrack.identity, correction, 0.02)
                orientation = (eased * orientation).normalized
            }

            times.append(sample.time)
            orientations.append(orientation)
        }
    }

    /// Camera orientation at `time`, as a rotation from camera space to world space.
    func orientation(at time: Double) -> simd_quatf {
        guard !orientations.isEmpty else { return MotionTrack.identity }
        if time <= times[0] { return orientations[0] }
        let last = times.count - 1
        if time >= times[last] { return orientations[last] }
        var low = 0
        var high = last
        while high - low > 1 {
            let middle = (low + high) / 2
            if times[middle] <= time { low = middle } else { high = middle }
        }
        let span = times[high] - times[low]
        let fraction = span > 0 ? Float((time - times[low]) / span) : 0
        return simd_slerp(orientations[low], orientations[high], fraction)
    }

    /// The rotation the renderer should apply for the requested lock.
    ///
    /// Full lock is the inverse orientation, and the constant rotation between
    /// the IMU and the camera only reframes it, so it needs no extra input.
    ///
    /// Horizon lock keeps the heading with the camera and removes only the
    /// tilt, which is `q⁻¹ · twist(q)` — cancel the orientation, then put the
    /// heading back. Inverting the tilt on its own is not the same thing: that
    /// rotates about a world-fixed axis instead of a camera-relative one, so it
    /// mixes roll into pitch as soon as the camera pans. Because the result is
    /// a rotation about a horizontal axis, the unknown heading offset between
    /// the IMU and the camera has to be conjugated out of it; getting that wrong
    /// by 90 degrees is worse than no stabilisation at all, which is why it is
    /// exposed rather than assumed.
    func correction(at time: Double, mode: Stabilization, imuYaw: Float) -> simd_quatf {
        switch mode {
        case .off:
            return MotionTrack.identity
        case .full:
            return orientation(at: time).inverse.normalized
        case .horizon:
            let current = orientation(at: time)
            let levelled = (current.inverse * MotionTrack.twist(of: current)).normalized
            guard abs(imuYaw) > 1e-6 else { return levelled }
            let frame = simd_quatf(angle: imuYaw, axis: SIMD3<Float>(0, 1, 0))
            return (frame.inverse * levelled * frame).normalized
        }
    }

    /// The heading part of a rotation: its component about world up.
    static func twist(of orientation: simd_quatf) -> simd_quatf {
        let candidate = simd_quatf(ix: 0, iy: orientation.imag.y, iz: 0, r: orientation.real)
        return simd_length(candidate.vector) < 1e-6 ? identity : candidate.normalized
    }

    /// Everything except the heading.
    static func tilt(of orientation: simd_quatf) -> simd_quatf {
        (orientation * twist(of: orientation).inverse).normalized
    }

    static func shortestArc(from source: SIMD3<Float>, to destination: SIMD3<Float>) -> simd_quatf {
        let a = simd_normalize(source)
        let b = simd_normalize(destination)
        let dot = simd_dot(a, b)
        if dot > 0.999999 { return identity }
        if dot < -0.999999 {
            var axis = simd_cross(SIMD3<Float>(1, 0, 0), a)
            if simd_length(axis) < 1e-4 { axis = simd_cross(SIMD3<Float>(0, 1, 0), a) }
            return simd_quatf(angle: .pi, axis: simd_normalize(axis))
        }
        let axis = simd_cross(a, b)
        return simd_quatf(ix: axis.x, iy: axis.y, iz: axis.z, r: 1 + dot).normalized
    }
}

/// Heading offset between the IMU and the camera's optical frame. The sensor is
/// board-mounted, so the real value is a right angle; which one cannot be told
/// from the IMU alone.
enum IMUYaw: Int, CaseIterable, Identifiable, Codable {
    case zero = 0
    case ninety = 90
    case oneEighty = 180
    case twoSeventy = 270

    var id: Int { rawValue }
    var label: String { "\(rawValue)°" }
    var radians: Float { Float(rawValue) * .pi / 180 }
}

enum Stabilization: String, CaseIterable, Identifiable, Codable {
    case off
    case horizon
    case full

    var id: String { rawValue }

    var label: String {
        switch self {
        case .off: return "Off"
        case .horizon: return "Horizon"
        case .full: return "Full"
        }
    }
}
