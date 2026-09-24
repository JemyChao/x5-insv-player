import AVFoundation
import Foundation
import SwiftUI
import simd

@MainActor
final class PlayerModel: ObservableObject {
    enum State {
        case empty, loading, ready, failed

        var label: String {
            switch self {
            case .empty: return "WAITING"
            case .loading: return "OPENING"
            case .ready: return "PREVIEW"
            case .failed: return "FAILED"
            }
        }
    }

    @Published var showImporter = false
    @Published var showInspector = false
    @Published private(set) var state: State = .empty
    @Published private(set) var captureName = "No file selected"
    @Published private(set) var trackInfo = "-"
    @Published private(set) var frameSize = "-"
    @Published private(set) var codecInfo = "-"
    @Published private(set) var trailerInfo = "not parsed"
    @Published private(set) var motionInfo = "none"
    @Published private(set) var captureDate = "-"
    @Published private(set) var captureDateSource = "-"
    @Published private(set) var gpsInfo = "none"
    @Published private(set) var cameraInfo = "-"
    /// Renderer set-up failures stay on screen: they mean nothing draws at all,
    /// and a toast that clears itself is easy to miss.
    @Published private(set) var rendererError: String?
    @Published private(set) var calibrationSource = "built-in approximation"
    @Published private(set) var trailerNotes: [String] = []
    @Published var message: String?
    @Published private(set) var isPlaying = false
    @Published var position: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var currentTime = "00:00"
    @Published private(set) var totalTime = "00:00"
    @Published private(set) var lookInfo = "yaw 0°  pitch 0°  fov 81°"

    @Published var profile: LensProfile {
        didSet {
            renderer.profile = profile
            scheduleProfileSave()
        }
    }
    @Published var projection: ProjectionMode = .rectilinear {
        didSet { renderer.projection = projection }
    }
    @Published var stabilization: Stabilization = .off {
        didSet { renderer.stabilization = stabilization }
    }
    @Published var imuYaw: IMUYaw = .measured {
        didSet { renderer.imuYaw = imuYaw }
    }
    /// Seconds the gravity reference is averaged over. Short is twitchy, long
    /// is steady but slow to re-level after a real tilt.
    @Published var horizonSmoothing: Double = 1.5 {
        didSet { rebuildMotion() }
    }
    /// Seconds the heading is averaged over. Short leaves left-right shake in,
    /// long rounds off a deliberate pan.
    @Published var panSmoothing: Double = 1.2 {
        didSet { rebuildMotion() }
    }
    @Published var showGuides = false {
        didSet { renderer.showGuides = showGuides }
    }
    @Published var seamDebug = false {
        didSet { renderer.seamDebug = seamDebug }
    }
    @Published var showHorizon = false {
        didSet { renderer.showHorizon = showHorizon }
    }
    @Published var exposure: Double = 1 {
        didSet { renderer.exposure = Float(exposure) }
    }
    @Published var tonemapHLG = false {
        didSet { renderer.tonemapHLG = tonemapHLG }
    }
    @Published var volume: Double = 1 {
        didSet { renderer.engine.volume = Float(volume) }
    }

    let renderer = PanoramaRenderer()

    /// True until a real per-capture calibration has been applied.
    @Published private(set) var isApproximate = true
    @Published private(set) var hasMotion = false

    private var motionSamples: [MotionSample] = []
    private var profileSaveWork: DispatchWorkItem?
    private var messageWork: DispatchWorkItem?
    private var isScrubbing = false

    init() {
        let saved = LensProfile.loadSaved() ?? LensProfile()
        profile = saved
        renderer.profile = saved
        renderer.exposure = 1
        renderer.engine.onProgress = { [weak self] time, finished in
            Task { @MainActor in self?.progress(time: time, finished: finished) }
        }
        renderer.onSetupError = { [weak self] text in
            Task { @MainActor in
                self?.rendererError = text
                self?.show(text)
            }
        }
        renderer.onLookChanged = { [weak self] yaw, pitch, fov in
            let described = PlayerModel.describeLook(yaw: yaw, pitch: pitch, fov: fov)
            Task { @MainActor in self?.lookInfo = described }
        }
    }

    // MARK: - Opening

    func open(_ result: Result<URL, Error>) {
        switch result {
        case .success(let url):
            state = .loading
            captureName = url.lastPathComponent
            Task { await load(url) }
        case .failure(let error):
            state = .failed
            show(error.localizedDescription)
        }
    }

    private func load(_ url: URL) async {
        renderer.engine.unload()
        renderer.motion = nil
        hasMotion = false
        motionSamples = []
        isPlaying = false
        captureDate = "-"
        captureDateSource = "-"
        gpsInfo = "none"
        cameraInfo = "-"

        do {
            let capture = try await CaptureReader.open(url: url)
            let info = capture.info
            trackInfo = "\(info.videoTrackCount) video tracks\(info.hasAudio ? " + audio" : "")"
            frameSize = info.lensDescription
            codecInfo = "\(info.codec)  \(String(format: "%.2f", info.frameRate)) fps"
            duration = info.duration
            totalTime = PlayerModel.format(info.duration)
            position = 0
            currentTime = "00:00"
            renderer.useBT2020 = info.wideGamut
            tonemapHLG = info.hlg
            renderer.tonemapHLG = info.hlg

            renderer.engine.load(capture)
            renderer.engine.volume = Float(volume)
            state = .ready

            var opened = "Both lens tracks loaded"
            if info.openedThroughAlias { opened += " (opened through a .mp4 alias)" }
            show(opened)

            await loadTrailer(url: url, duration: info.duration)
        } catch {
            state = .failed
            show(error.localizedDescription)
        }
    }

    private func loadTrailer(url: URL, duration: Double) async {
        let scanned = await Task.detached(priority: .utility) { () -> (INSVTrailer?, CaptureMetadata) in
            let trailer = INSVTrailerReader.read(url: url, videoDuration: duration)
            let container = MP4Reader.read(url: url)
            return (trailer, container)
        }.value

        let parsed = scanned.0
        var container = scanned.1
        container.gpsFixCount = parsed?.gps.count ?? 0
        container.firstFix = parsed?.gps.first
        container.lastFix = parsed?.gps.last
        container.gpsDate = parsed?.gps.first?.time
        container.gpsLayout = parsed?.gpsLayout
        applyDates(container)
        applyGPS(container)

        // Calibration can sit in the container's udta as well as in the
        // trailer, so it is worth looking there even when there is no trailer.
        var udtaNotes: [String] = []
        var udtaProfile: LensProfile?
        if !container.containerText.isEmpty {
            udtaProfile = CalibrationScanner.profile(from: container.containerText, notes: &udtaNotes)
            if udtaProfile != nil { udtaNotes.append("calibration came from the container udta, not the trailer") }
        }

        guard let parsed else {
            trailerInfo = "no INSV metadata trailer found"
            trailerNotes = udtaNotes
            if let udtaProfile {
                profile = udtaProfile
                calibrationSource = udtaProfile.origin
                isApproximate = false
            }
            return
        }

        cameraInfo = parsed.config.summary
        if cameraInfo.isEmpty {
            cameraInfo = [parsed.cameraModel, parsed.firmware, parsed.serialNumber]
                .compactMap { $0 }
                .joined(separator: "  ")
        }
        if cameraInfo.isEmpty { cameraInfo = "-" }

        let names = parsed.blocks.map(\.name).joined(separator: ", ")
        trailerInfo = "\(parsed.blocks.count) blocks: \(names)"
        if parsed.frameTimestamps > 0 {
            trailerInfo += "  (\(parsed.frameTimestamps) frame timestamps)"
        }
        trailerNotes = parsed.notes + udtaNotes

        if let calibration = parsed.calibration {
            profile = calibration
            calibrationSource = calibration.origin
            isApproximate = false
        } else if let udtaProfile {
            profile = udtaProfile
            calibrationSource = udtaProfile.origin
            isApproximate = false
        } else {
            calibrationSource = profile.origin
            isApproximate = true
        }

        applyMotion(parsed)
    }

    private func applyMotion(_ parsed: INSVTrailer) {
        motionSamples = parsed.motion
        rebuildMotion()
    }

    private func rebuildMotion() {
        if let track = MotionTrack(samples: motionSamples,
                                   smoothingSeconds: horizonSmoothing,
                                   panSmoothingSeconds: panSmoothing) {
            renderer.motion = track
            hasMotion = true
            motionInfo = String(format: "%d samples / %.0f Hz / held %.1f° off level",
                                track.samples.count, track.sampleRate, track.alignmentDegrees)
            if stabilization == .off { stabilization = .horizon }
        } else {
            renderer.motion = nil
            hasMotion = false
            motionInfo = motionSamples.isEmpty ? "no gyro data in the trailer" : "too few gyro samples to integrate"
        }
    }

    private func applyDates(_ container: CaptureMetadata) {
        captureDate = CaptureMetadata.describe(container.bestDate)
        var sources: [String] = []
        if container.gpsDate != nil { sources.append("GPS") }
        if container.filenameDate != nil { sources.append("file name") }
        if container.containerCreated != nil { sources.append("mvhd") }
        if sources.isEmpty {
            captureDateSource = "no capture time found"
        } else {
            captureDateSource = sources.joined(separator: " / ")
            if let offset = CaptureMetadata.describeOffset(container.filenameOffsetFromUTC) {
                captureDateSource += "  " + offset
            }
        }
    }

    private func applyGPS(_ container: CaptureMetadata) {
        guard container.gpsFixCount > 0, let first = container.firstFix else {
            gpsInfo = "no GPS fixes"
            return
        }
        var text = String(format: "%d fixes  first %.5f, %.5f", container.gpsFixCount, first.latitude, first.longitude)
        if let altitude = first.altitude {
            text += String(format: "  alt %.0f m", altitude)
        }
        if let last = container.lastFix, last.latitude != first.latitude || last.longitude != first.longitude {
            text += String(format: "\nlast %.5f, %.5f", last.latitude, last.longitude)
        }
        if let layout = container.gpsLayout {
            text += "\n" + layout
        }
        gpsInfo = text
    }

    // MARK: - Transport

    func togglePlayback() {
        guard state == .ready else { return }
        if isPlaying {
            renderer.engine.pause()
            isPlaying = false
        } else {
            if duration > 0, position >= duration - 0.05 {
                renderer.engine.seek(to: 0)
                position = 0
            }
            renderer.engine.play()
            isPlaying = true
        }
    }

    func seek(_ editing: Bool) {
        isScrubbing = editing
        guard !editing else { return }
        renderer.engine.seek(to: position)
        currentTime = PlayerModel.format(position)
    }

    func step(by seconds: Double) {
        guard state == .ready else { return }
        let target = min(max(0, position + seconds), max(duration, 0))
        position = target
        renderer.engine.seek(to: target)
        currentTime = PlayerModel.format(target)
    }

    func resetView() { renderer.resetView() }

    func shutdown() { renderer.engine.shutdown() }

    private func progress(time: Double, finished: Bool) {
        if !isScrubbing {
            position = duration > 0 ? min(time, duration) : time
            currentTime = PlayerModel.format(position)
        }
        if finished, isPlaying {
            isPlaying = false
        }
    }

    // MARK: - Calibration

    func resetProfile() {
        profile = LensProfile()
        calibrationSource = profile.origin
        isApproximate = true
        show("Lens profile reset to the built-in approximation")
    }

    func nudgeFieldOfView(_ delta: Float) {
        renderer.setFieldOfView(renderer.fieldOfView + delta)
    }

    private func scheduleProfileSave() {
        profileSaveWork?.cancel()
        let snapshot = profile
        let work = DispatchWorkItem { snapshot.save() }
        profileSaveWork = work
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1.0, execute: work)
    }

    // MARK: - Helpers

    private func show(_ text: String) {
        message = text
        messageWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in self?.message = nil }
        }
        messageWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.5, execute: work)
    }

    static func format(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "00:00" }
        let whole = Int(seconds)
        return String(format: "%02d:%02d", whole / 60, whole % 60)
    }

    static func describeLook(yaw: Float, pitch: Float, fov: Float) -> String {
        let degrees = { (value: Float) in Int((value * 180 / .pi).rounded()) }
        return "yaw \(degrees(yaw))°  pitch \(degrees(pitch))°  fov \(degrees(fov))°"
    }
}
