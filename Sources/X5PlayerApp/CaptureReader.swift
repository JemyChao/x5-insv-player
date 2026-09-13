import AVFoundation
import CoreMedia
import CoreVideo
import Foundation

/// Decodes both lens tracks of an X5 capture and keeps a small queue of
/// presentation-time-aligned frame pairs ready for the renderer.
final class CaptureReader {
    struct FramePair {
        let left: CVPixelBuffer
        let right: CVPixelBuffer
        let time: Double
    }

    struct Info {
        var displayName = "-"
        var lensWidth = 0
        var lensHeight = 0
        var frameRate: Double = 30
        var duration: Double = 0
        var videoTrackCount = 0
        var hasAudio = false
        var codec = "-"
        var wideGamut = false
        var hlg = false
        var openedThroughAlias = false

        var lensDescription: String { "\(lensWidth) x \(lensHeight) per lens" }
    }

    private(set) var info: Info

    private let sourceURL: URL
    private let aliasURL: URL?
    private let scopedAccess: Bool
    private let asset: AVURLAsset
    private let videoTracks: [AVAssetTrack]
    private let audioTrack: AVAssetTrack?

    private let queue = DispatchQueue(label: "tv.titanos.x5.decode", qos: .userInitiated)
    private let lock = NSLock()
    private var pending: [FramePair] = []
    private var reader: AVAssetReader?
    private var videoOutputs: [AVAssetReaderTrackOutput] = []
    private var audioOutput: AVAssetReaderTrackOutput?
    private var pumpTimer: DispatchSourceTimer?
    private var exhausted = false
    private var delivered = false
    private var seekTarget: Double = 0
    private let capacity = 6

    /// Set by the playback engine to drain the audio track at its own pace.
    var onAudioSample: ((CMSampleBuffer) -> Void)?
    var audioWanted: (() -> Bool)?

    // MARK: - Opening

    static func open(url: URL) async throws -> CaptureReader {
        let ext = url.pathExtension.lowercased()
        guard ["insv", "insp", "mp4", "mov", "m4v"].contains(ext) else { throw PlayerError.unsupportedFile }

        let scoped = url.startAccessingSecurityScopedResource()
        let options: [String: Any] = [AVURLAssetPreferPreciseDurationAndTimingKey: true]
        var asset = AVURLAsset(url: url, options: options)
        var tracks = (try? await asset.loadTracks(withMediaType: .video)) ?? []
        var alias: URL?

        // AVFoundation types a file by its extension, and it does not know
        // `.insv`. The container itself is plain MP4, so present it under an
        // `.mp4` name and try again before giving up.
        if tracks.count < 2, let candidate = makeAlias(for: url) {
            let retryAsset = AVURLAsset(url: candidate, options: options)
            let retryTracks = (try? await retryAsset.loadTracks(withMediaType: .video)) ?? []
            if retryTracks.count > tracks.count {
                asset = retryAsset
                tracks = retryTracks
                alias = candidate
            } else {
                try? FileManager.default.removeItem(at: candidate)
            }
        }

        func abandon() {
            if scoped { url.stopAccessingSecurityScopedResource() }
            if let alias { try? FileManager.default.removeItem(at: alias) }
        }

        guard tracks.count >= 2 else {
            abandon()
            throw PlayerError.missingLensTracks(found: tracks.count)
        }

        var info = Info()
        info.displayName = url.lastPathComponent
        info.videoTrackCount = tracks.count
        info.openedThroughAlias = alias != nil

        let size = (try? await tracks[0].load(.naturalSize)) ?? .zero
        info.lensWidth = Int(size.width.rounded())
        info.lensHeight = Int(size.height.rounded())

        let nominal = Double((try? await tracks[0].load(.nominalFrameRate)) ?? 0)
        info.frameRate = nominal > 0.1 ? nominal : 30

        let duration = (try? await asset.load(.duration)) ?? .zero
        info.duration = duration.seconds.isFinite ? max(0, duration.seconds) : 0

        let audio = (try? await asset.loadTracks(withMediaType: .audio))?.first
        info.hasAudio = audio != nil

        let descriptions = (try? await tracks[0].load(.formatDescriptions)) ?? []
        if let description = descriptions.first {
            info.codec = fourCharacterCode(CMFormatDescriptionGetMediaSubType(description))
            if let transfer = CMFormatDescriptionGetExtension(description, extensionKey: kCMFormatDescriptionExtension_TransferFunction) as? String {
                info.hlg = transfer == (kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG as String)
            }
            if let primaries = CMFormatDescriptionGetExtension(description, extensionKey: kCMFormatDescriptionExtension_ColorPrimaries) as? String {
                info.wideGamut = primaries == (kCMFormatDescriptionColorPrimaries_ITU_R_2020 as String)
            }
        }

        return CaptureReader(sourceURL: url,
                             aliasURL: alias,
                             scopedAccess: scoped,
                             asset: asset,
                             videoTracks: Array(tracks.prefix(2)),
                             audioTrack: audio,
                             info: info)
    }

    private init(sourceURL: URL,
                 aliasURL: URL?,
                 scopedAccess: Bool,
                 asset: AVURLAsset,
                 videoTracks: [AVAssetTrack],
                 audioTrack: AVAssetTrack?,
                 info: Info) {
        self.sourceURL = sourceURL
        self.aliasURL = aliasURL
        self.scopedAccess = scopedAccess
        self.asset = asset
        self.videoTracks = videoTracks
        self.audioTrack = audioTrack
        self.info = info
    }

    deinit {
        pumpTimer?.cancel()
        reader?.cancelReading()
        if scopedAccess { sourceURL.stopAccessingSecurityScopedResource() }
        if let aliasURL { try? FileManager.default.removeItem(at: aliasURL) }
    }

    private static func makeAlias(for url: URL) -> URL? {
        let alias = FileManager.default.temporaryDirectory
            .appendingPathComponent("x5-insv-\(UUID().uuidString).mp4")
        do {
            try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: url)
            return alias
        } catch {
            // A sandbox or a filesystem without links: fall back to a real copy.
            do {
                try FileManager.default.copyItem(at: url, to: alias)
                return alias
            } catch {
                return nil
            }
        }
    }

    private static func fourCharacterCode(_ value: FourCharCode) -> String {
        let bytes = [UInt8((value >> 24) & 0xFF), UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
        let scalars = bytes.map { $0 >= 0x20 && $0 < 0x7F ? Character(UnicodeScalar($0)) : "?" }
        return String(scalars)
    }

    // MARK: - Lifecycle

    func prime() {
        queue.async { [weak self] in
            guard let self else { return }
            self.configure(at: 0)
        }
        startPump()
    }

    func invalidate() {
        pumpTimer?.cancel()
        pumpTimer = nil
        queue.sync {
            self.reader?.cancelReading()
            self.reader = nil
            self.videoOutputs = []
            self.audioOutput = nil
        }
        lock.lock()
        pending.removeAll()
        lock.unlock()
        onAudioSample = nil
        audioWanted = nil
    }

    func seek(to seconds: Double) {
        lock.lock()
        pending.removeAll()
        delivered = false
        exhausted = false
        lock.unlock()
        queue.async { [weak self] in
            guard let self else { return }
            self.seekTarget = max(0, seconds)
            // Start a little early: the reader begins at the preceding sync
            // sample and the frames in front of the target are dropped below.
            self.configure(at: max(0, seconds - 0.25))
        }
    }

    /// Latest frame whose presentation time has arrived. `nil` keeps whatever
    /// the renderer is already showing.
    func frame(at time: Double) -> FramePair? {
        lock.lock()
        defer { lock.unlock() }
        var chosen: FramePair?
        while let next = pending.first, next.time <= time + 0.004 {
            chosen = pending.removeFirst()
        }
        if chosen == nil, !delivered, !pending.isEmpty {
            chosen = pending.removeFirst()
        }
        if chosen != nil { delivered = true }
        return chosen
    }

    var isFinished: Bool {
        lock.lock()
        defer { lock.unlock() }
        return exhausted && pending.isEmpty
    }

    var bufferedFrames: Int {
        lock.lock()
        defer { lock.unlock() }
        return pending.count
    }

    // MARK: - Decoding

    private func configure(at start: Double) {
        reader?.cancelReading()
        reader = nil
        videoOutputs = []
        audioOutput = nil

        guard let newReader = try? AVAssetReader(asset: asset) else { return }
        let startTime = CMTime(seconds: max(0, start), preferredTimescale: 600)
        newReader.timeRange = CMTimeRange(start: startTime, duration: .positiveInfinity)

        let videoSettings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferMetalCompatibilityKey as String: true
        ]
        var outputs: [AVAssetReaderTrackOutput] = []
        for track in videoTracks {
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: videoSettings)
            output.alwaysCopiesSampleData = false
            if newReader.canAdd(output) {
                newReader.add(output)
                outputs.append(output)
            }
        }
        guard outputs.count >= 2 else { return }

        var audio: AVAssetReaderTrackOutput?
        if let audioTrack {
            let audioSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: true
            ]
            let output = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: audioSettings)
            output.alwaysCopiesSampleData = false
            if newReader.canAdd(output) {
                newReader.add(output)
                audio = output
            }
        }

        guard newReader.startReading() else { return }
        reader = newReader
        videoOutputs = outputs
        audioOutput = audio
    }

    private func startPump() {
        guard pumpTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(4), leeway: .milliseconds(2))
        timer.setEventHandler { [weak self] in self?.topUp() }
        pumpTimer = timer
        timer.resume()
    }

    /// Runs on the decode queue. Every loop is bounded so one tick can never
    /// monopolise the queue, even while skipping forward after a seek.
    private func topUp() {
        guard let reader else { return }
        if reader.status != .reading {
            markExhausted()
            return
        }

        var iterations = 0
        while iterations < 12, bufferedFrames < capacity, reader.status == .reading {
            iterations += 1
            guard let pair = readPair() else {
                markExhausted()
                break
            }
            if pair.time + 0.002 < seekTarget { continue }
            lock.lock()
            pending.append(pair)
            lock.unlock()
        }

        guard let audioOutput, let wanted = audioWanted, let sink = onAudioSample else { return }
        var audioChunks = 0
        while audioChunks < 16, wanted(), reader.status == .reading {
            audioChunks += 1
            guard let sample = audioOutput.copyNextSampleBuffer() else { break }
            if CMSampleBufferGetPresentationTimeStamp(sample).seconds + 0.05 < seekTarget { continue }
            sink(sample)
        }
    }

    /// Pulls one sample from each lens track and realigns them if the tracks
    /// drift apart, which they do whenever the two encoders start on different
    /// sync samples.
    private func readPair() -> FramePair? {
        guard videoOutputs.count >= 2 else { return nil }
        guard var first = videoOutputs[0].copyNextSampleBuffer(),
              var second = videoOutputs[1].copyNextSampleBuffer() else { return nil }
        var firstTime = CMSampleBufferGetPresentationTimeStamp(first).seconds
        var secondTime = CMSampleBufferGetPresentationTimeStamp(second).seconds
        let tolerance = 0.5 / max(info.frameRate, 1)

        var attempts = 0
        while abs(firstTime - secondTime) > tolerance, attempts < 60 {
            attempts += 1
            if firstTime < secondTime {
                guard let next = videoOutputs[0].copyNextSampleBuffer() else { return nil }
                first = next
                firstTime = CMSampleBufferGetPresentationTimeStamp(first).seconds
            } else {
                guard let next = videoOutputs[1].copyNextSampleBuffer() else { return nil }
                second = next
                secondTime = CMSampleBufferGetPresentationTimeStamp(second).seconds
            }
        }

        guard let left = CMSampleBufferGetImageBuffer(first),
              let right = CMSampleBufferGetImageBuffer(second) else { return nil }
        let time = min(firstTime, secondTime)
        return FramePair(left: left, right: right, time: time.isFinite ? time : 0)
    }

    private func markExhausted() {
        lock.lock()
        exhausted = true
        lock.unlock()
    }
}

enum PlayerError: LocalizedError {
    case unsupportedFile
    case missingLensTracks(found: Int)
    case decoderStart(Error?)

    var errorDescription: String? {
        switch self {
        case .unsupportedFile:
            return "Select an original .insv capture."
        case .missingLensTracks(let found):
            return "Found only \(found) video track\(found == 1 ? "" : "s"). An X5 360 capture needs two lens tracks."
        case .decoderStart(let error):
            return "Could not start HEVC decoding: \(error?.localizedDescription ?? "unknown error")"
        }
    }
}
