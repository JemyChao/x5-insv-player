import AVFoundation
import CoreVideo

final class CaptureReader {
    struct FramePair { let left: CVPixelBuffer; let right: CVPixelBuffer; let time: Double }
    let asset: AVURLAsset
    let videoTrackCount: Int
    let dimensions: String
    let duration: Double
    private let tracks: [AVAssetTrack]
    private let scopedAccess: Bool
    private var reader: AVAssetReader?
    private var outputs: [AVAssetReaderTrackOutput] = []

    init(url: URL) async throws {
        guard url.pathExtension.lowercased() == "insv" || ["mp4", "mov"].contains(url.pathExtension.lowercased()) else { throw PlayerError.unsupportedFile }
        scopedAccess = url.startAccessingSecurityScopedResource()
        asset = AVURLAsset(url: url)
        tracks = try await asset.loadTracks(withMediaType: .video)
        guard tracks.count >= 2 else { throw PlayerError.missingLensTracks(found: tracks.count) }
        let first = tracks[0]
        let size = try await first.load(.naturalSize)
        let loadedDuration = try await asset.load(.duration)
        videoTrackCount = tracks.count
        dimensions = "\(Int(size.width)) x \(Int(size.height)) per lens"
        duration = loadedDuration.seconds
        try configureReader(at: .zero)
    }

    deinit { if scopedAccess { asset.url.stopAccessingSecurityScopedResource() } }

    func nextFrame() -> FramePair? {
        guard let reader, reader.status == .reading, outputs.count >= 2,
              let a = outputs[0].copyNextSampleBuffer(), let b = outputs[1].copyNextSampleBuffer(),
              let left = CMSampleBufferGetImageBuffer(a), let right = CMSampleBufferGetImageBuffer(b) else { return nil }
        return FramePair(left: left, right: right, time: CMSampleBufferGetPresentationTimeStamp(a).seconds)
    }

    func seek(to seconds: Double) {
        try? configureReader(at: CMTime(seconds: seconds, preferredTimescale: 600))
    }

    private func configureReader(at start: CMTime) throws {
        reader?.cancelReading()
        let newReader = try AVAssetReader(asset: asset)
        newReader.timeRange = CMTimeRange(start: start, duration: .positiveInfinity)
        let settings: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelBufferMetalCompatibilityKey as String: true]
        outputs = tracks.prefix(2).map { track in
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
            output.alwaysCopiesSampleData = false
            newReader.add(output)
            return output
        }
        guard newReader.startReading() else { throw PlayerError.decoderStart(newReader.error) }
        reader = newReader
    }
}

enum PlayerError: LocalizedError {
    case unsupportedFile, missingLensTracks(found: Int), decoderStart(Error?)
    var errorDescription: String? { switch self {
    case .unsupportedFile: "請選取原始 .insv 影片。"
    case .missingLensTracks(let found): "此檔案只找到 \(found) 個視訊軌；X5 360 原始片段需要兩個鏡頭軌。"
    case .decoderStart(let error): "無法啟動 HEVC 解碼：\(error?.localizedDescription ?? "未知錯誤")"
    } }
}
