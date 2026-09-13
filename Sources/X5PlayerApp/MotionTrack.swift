import Foundation
import simd

/// Turns the raw IMU records from the INSV trailer into a camera orientation
/// the renderer can sample at any media time.
///
/// The IMU axes are not documented, but the accelerometer and the gyro share a
/// body frame, so a single unknown rotation relates them to the optical frame.
/// Averaging the accelerometer over the whole clip gives the gravity direction
/// in that body frame, and aligning it with world down pins two of the three
/// axes. The third, a spin about gravity, cannot be recovered from the IMU at
/// all; it does not affect full lock, which it only reframes, but the horizon
/// correction is a rotation about a horizontal axis and has to be expressed in
/// the camera's heading frame, so `IMUYaw` carries it.
final class MotionTrack {
    let samples: [MotionSample]
    let sampleRate: Double
    let alignmentDegrees: Float
    let smoothingSeconds: Double

    private var times: [Double] = []
    private var orientations: [simd_quatf] = []

    static let identity = simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0))

    /// - Parameter smoothingSeconds: how long the gravity reference is averaged
    ///   over. This is the control that decides whether the horizon is steady
    ///   or shaky, so it is a parameter rather than a constant.
    init?(samples: [MotionSample], smoothingSeconds: Double = 1.5, invertGyro: Bool = false) {
        guard samples.count > 8 else { return nil }
        let span = samples[samples.count - 1].time - samples[0].time
        guard span > 0 else { return nil }
        self.samples = samples
        self.sampleRate = Double(samples.count - 1) / span
        self.smoothingSeconds = smoothingSeconds

        var meanAccel = SIMD3<Double>(repeating: 0)
        for sample in samples { meanAccel += sample.accel }
        meanAccel /= Double(samples.count)
        let gravity = SIMD3<Float>(Float(meanAccel.x), Float(meanAccel.y), Float(meanAccel.z))
        let alignment: simd_quatf = simd_length(gravity) > 0.05
            ? MotionTrack.shortestArc(from: gravity, to: SIMD3<Float>(0, -1, 0))
            : MotionTrack.identity
        self.alignmentDegrees = alignment.angle * 180 / .pi

        // Zero-phase gravity reference. Handheld linear acceleration swamps the
        // raw accelerometer, and correcting towards it directly is what makes
        // stabilisation read as shake. Nothing here is real time, so the average
        // is centred on each sample rather than trailing it: no lag, no phase
        // error, and the reference is smooth enough to steer by.
        var levelled = [SIMD3<Float>]()
        levelled.reserveCapacity(samples.count)
        for sample in samples {
            levelled.append(alignment.act(SIMD3<Float>(Float(sample.accel.x),
                                                       Float(sample.accel.y),
                                                       Float(sample.accel.z))))
        }
        let reference = MotionTrack.centredAverage(levelled,
                                                   window: max(3, Int(smoothingSeconds * sampleRate)))

        times.reserveCapacity(samples.count)
        orientations.reserveCapacity(samples.count)

        var orientation = MotionTrack.shortestArc(from: reference[0], to: SIMD3<Float>(0, -1, 0))
        var previousTime = samples[0].time
        let gyroSign: Float = invertGyro ? -1 : 1
        // Correcting a third of the way into the smoothing window keeps the
        // gyro in charge of anything faster than that.
        let timeConstant = max(smoothingSeconds / 3, 0.02)

        for (index, sample) in samples.enumerated() {
            let delta = max(0, min(0.25, sample.time - previousTime))
            previousTime = sample.time

            let rawGyro = SIMD3<Float>(Float(sample.gyro.x), Float(sample.gyro.y), Float(sample.gyro.z))
            let rate = alignment.act(rawGyro) * gyroSign
            if delta > 0 {
                let angle = simd_length(rate) * Float(delta)
                if angle > 1e-7 {
                    let step = simd_quatf(angle: angle, axis: rate / simd_length(rate))
                    orientation = (orientation * step).normalized
                }
            }

            // Gain from the elapsed time, not a fixed per-sample fraction: this
            // IMU runs at 1 kHz, and a constant would make the filter's actual
            // time constant depend on the sample rate.
            let gain = Float(min(1.0, delta / timeConstant))
            if gain > 0 {
                let measured = reference[index]
                if simd_length(measured) > 0.5 {
                    let inWorld = orientation.act(simd_normalize(measured))
                    let correction = MotionTrack.shortestArc(from: inWorld, to: SIMD3<Float>(0, -1, 0))
                    let eased = simd_slerp(MotionTrack.identity, correction, gain)
                    orientation = (eased * orientation).normalized
                }
            }

            times.append(sample.time)
            orientations.append(orientation)
        }
    }

    /// Moving average centred on each sample, from prefix sums.
    private static func centredAverage(_ values: [SIMD3<Float>], window: Int) -> [SIMD3<Float>] {
        guard !values.isEmpty else { return [] }
        var sums = [SIMD3<Float>](repeating: .zero, count: values.count + 1)
        for index in values.indices { sums[index + 1] = sums[index] + values[index] }
        let half = max(1, window / 2)
        var result = [SIMD3<Float>]()
        result.reserveCapacity(values.count)
        for index in values.indices {
            let low = max(0, index - half)
            let high = min(values.count, index + half + 1)
            let mean = (sums[high] - sums[low]) / Float(high - low)
            result.append(simd_length(mean) > 1e-6 ? simd_normalize(mean) : SIMD3<Float>(0, -1, 0))
        }
        return result
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
