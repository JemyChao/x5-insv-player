import AVFoundation
import SwiftUI

@MainActor
final class PlayerModel: ObservableObject {
    enum State { case empty, loading, ready, failed
        var label: String { switch self { case .empty: "WAITING"; case .loading: "OPENING"; case .ready: "PREVIEW"; case .failed: "FAILED" } }
    }
    @Published var showImporter = false
    @Published var state: State = .empty
    @Published var captureName = "No file selected"
    @Published var trackInfo = "-"
    @Published var frameSize = "-"
    @Published var message: String?
    @Published var isPlaying = false
    @Published var position: Double = 0
    @Published var duration: Double = 0
    @Published var currentTime = "00:00"
    @Published var totalTime = "00:00"
    @Published var isApproximate = true
    let renderer = PanoramaRenderer()
    private var reader: CaptureReader?
    private var timer: Timer?

    func open(_ result: Result<URL, Error>) {
        guard case .success(let url) = result else { return }
        state = .loading; captureName = url.lastPathComponent
        Task { await load(url) }
    }

    private func load(_ url: URL) async {
        do {
            let capture = try await CaptureReader(url: url)
            reader = capture; trackInfo = "\(capture.videoTrackCount) video tracks"; frameSize = capture.dimensions; duration = capture.duration; totalTime = format(capture.duration); position = 0
            renderer.attach(capture: capture); state = .ready; message = "雙鏡頭已載入；目前為近似校正預覽"; dismissMessage()
        } catch {
            state = .failed; message = error.localizedDescription
        }
    }

    func togglePlayback() { isPlaying.toggle(); isPlaying ? startTimer() : stopTimer() }
    func seek(_ editing: Bool) { guard !editing else { return }; renderer.seek(to: position); updateClock(position) }
    func resetView() { renderer.resetView() }
    private func startTimer() { timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in Task { @MainActor in self?.advance() } } }
    private func stopTimer() { timer?.invalidate(); timer = nil }
    private func advance() { guard let reader else { return }; if let time = renderer.presentNextFrame(from: reader) { position = time; updateClock(time) } else { isPlaying = false; stopTimer() } }
    private func updateClock(_ seconds: Double) { currentTime = format(seconds) }
    private func dismissMessage() { DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.message = nil } }
    private func format(_ seconds: Double) -> String { String(format: "%02d:%02d", Int(seconds) / 60, Int(seconds) % 60) }
}
