import AVFoundation
import Foundation
import QuartzCore

/// Media clock driven by the host clock. Audio is slaved to it rather than the
/// other way round: a capture can be opened with no audio track at all, and a
/// single clock keeps seeking and pausing behaving the same either way.
final class PlaybackClock {
    private let lock = NSLock()
    private var anchorHost = CACurrentMediaTime()
    private var anchorMedia: Double = 0
    private var running = false

    var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return running
    }

    var time: Double {
        lock.lock(); defer { lock.unlock() }
        return running ? anchorMedia + (CACurrentMediaTime() - anchorHost) : anchorMedia
    }

    func start() {
        lock.lock(); defer { lock.unlock() }
        guard !running else { return }
        anchorHost = CACurrentMediaTime()
        running = true
    }

    func pause() {
        lock.lock(); defer { lock.unlock() }
        guard running else { return }
        anchorMedia += CACurrentMediaTime() - anchorHost
        running = false
    }

    func set(_ seconds: Double) {
        lock.lock(); defer { lock.unlock() }
        anchorMedia = max(0, seconds)
        anchorHost = CACurrentMediaTime()
    }
}

/// Streams the decoded LPCM of the capture into the default output device.
final class AudioOutput {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let lock = NSLock()
    private var format: AVAudioFormat?
    private var attached = false
    private var scheduledSeconds: Double = 0
    private var wantsPlayback = false

    /// Roughly half a second of lead keeps the device fed without making a seek
    /// feel late.
    private let targetLead: Double = 0.5

    var volume: Float = 1 {
        didSet { player.volume = volume }
    }

    func wantsMore() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return wantsPlayback && scheduledSeconds < targetLead
    }

    func enqueue(_ sampleBuffer: CMSampleBuffer) {
        guard let description = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbdPointer = CMAudioFormatDescriptionGetStreamBasicDescription(description) else { return }

        if format == nil {
            var streamDescription = asbdPointer.pointee
            guard let created = AVAudioFormat(streamDescription: &streamDescription) else { return }
            format = created
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: created)
            player.volume = volume
            engine.prepare()
            attached = true
        }
        guard let format else { return }

        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return }
        buffer.frameLength = frames
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(sampleBuffer,
                                                                 at: 0,
                                                                 frameCount: Int32(frames),
                                                                 into: buffer.mutableAudioBufferList)
        guard status == noErr else { return }

        let seconds = Double(frames) / format.sampleRate
        lock.lock()
        scheduledSeconds += seconds
        lock.unlock()

        player.scheduleBuffer(buffer) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.scheduledSeconds = max(0, self.scheduledSeconds - seconds)
            self.lock.unlock()
        }

        if wantsPlayback { startIfNeeded() }
    }

    func play() {
        lock.lock(); wantsPlayback = true; lock.unlock()
        startIfNeeded()
    }

    func pause() {
        lock.lock(); wantsPlayback = false; lock.unlock()
        guard attached, player.isPlaying else { return }
        player.pause()
    }

    /// Drops everything queued, which is what a seek needs.
    func flush() {
        lock.lock()
        wantsPlayback = false
        scheduledSeconds = 0
        lock.unlock()
        guard attached else { return }
        player.stop()
    }

    func shutdown() {
        flush()
        if engine.isRunning { engine.stop() }
    }

    private func startIfNeeded() {
        guard attached else { return }
        if !engine.isRunning {
            do { try engine.start() } catch { return }
        }
        if !player.isPlaying { player.play() }
    }
}

/// Owns the decode side of playback and hands the renderer the frame that
/// belongs on screen right now.
final class PlaybackEngine {
    private(set) var reader: CaptureReader?
    let clock = PlaybackClock()
    private let audio = AudioOutput()
    private let stateLock = NSLock()
    private var playing = false
    private var lastReport: Double = 0

    /// (media time, reached end). Called from the render loop, already throttled.
    var onProgress: ((Double, Bool) -> Void)?

    var isPlaying: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return playing
    }

    var volume: Float {
        get { audio.volume }
        set { audio.volume = newValue }
    }

    func load(_ capture: CaptureReader) {
        unload()
        reader = capture
        capture.audioWanted = { [weak self] in
            guard let self else { return false }
            return self.isPlaying && self.audio.wantsMore()
        }
        capture.onAudioSample = { [weak self] sample in
            self?.audio.enqueue(sample)
        }
        clock.set(0)
        capture.prime()
    }

    func unload() {
        pause()
        audio.flush()
        reader?.invalidate()
        reader = nil
        clock.set(0)
    }

    func play() {
        guard reader != nil else { return }
        stateLock.lock(); playing = true; stateLock.unlock()
        clock.start()
        audio.play()
    }

    func pause() {
        stateLock.lock(); playing = false; stateLock.unlock()
        clock.pause()
        audio.pause()
    }

    func seek(to seconds: Double) {
        let resume = isPlaying
        pause()
        audio.flush()
        clock.set(seconds)
        reader?.seek(to: seconds)
        if resume { play() }
    }

    func shutdown() {
        unload()
        audio.shutdown()
    }

    /// Called once per displayed frame from the Metal view.
    func currentFrame() -> CaptureReader.FramePair? {
        guard let reader else { return nil }
        let time = clock.time
        let frame = reader.frame(at: time)
        let finished = reader.isFinished
        if finished, isPlaying { pause() }

        let now = CACurrentMediaTime()
        if now - lastReport > 0.1 {
            lastReport = now
            onProgress?(time, finished)
        }
        return frame
    }
}
