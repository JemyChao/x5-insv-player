import SwiftUI
import UniformTypeIdentifiers

private let accent = Color(red: 0.82, green: 1.0, blue: 0.30)
private let panelBackground = Color(red: 0.07, green: 0.086, blue: 0.09)
private let stageBackground = Color(red: 0.055, green: 0.067, blue: 0.071)

struct ContentView: View {
    @StateObject private var player = PlayerModel()

    private var insvType: UTType { UTType(filenameExtension: "insv") ?? .data }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider().overlay(Color.white.opacity(0.14))
            stage
            if player.showInspector {
                Divider().overlay(Color.white.opacity(0.14))
                CalibrationInspector(player: player)
            }
        }
        .background(stageBackground)
        .preferredColorScheme(.dark)
        .fileImporter(isPresented: $player.showImporter,
                      allowedContentTypes: [.movie, insvType, .data]) { result in
            player.open(result)
        }
        .onReceive(NotificationCenter.default.publisher(for: .x5OpenFile)) { _ in
            player.showImporter = true
        }
        .onDisappear { player.shutdown() }
    }

    private var stage: some View {
        VStack(spacing: 0) {
            header
            ZStack {
                MetalPanoramaView(renderer: player.renderer)
                    .background(Color.black)
                if player.state == .empty { welcome }
                if let message = player.message { toast(message) }
            }
            controls
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Mixed case, so the heavy all-caps letterspacing is dialled back.
            Text("X5 Insv Player").font(.headline.weight(.bold)).tracking(0.5)
            Text("RAW DUAL-LENS 360")
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .padding(.top, 8)

            Button(action: { player.showImporter = true }) {
                VStack(spacing: 6) {
                    Image(systemName: "folder.badge.plus").font(.title2)
                    Text("Open X5 capture").font(.caption.weight(.semibold))
                    Text(".INSV / dual HEVC lens tracks")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 98)
            }
            .buttonStyle(.bordered)
            .tint(accent)
            .padding(.top, 26)

            ScrollView {
                VStack(alignment: .leading, spacing: 15) {
                    InfoLine(label: "CAPTURE", value: player.captureName)
                    InfoLine(label: "LENS TRACKS", value: player.trackInfo)
                    InfoLine(label: "FRAME SIZE", value: player.frameSize)
                    InfoLine(label: "CODEC", value: player.codecInfo)
                    InfoLine(label: "STATUS", value: player.state.label)
                    InfoLine(label: "LOOK", value: player.lookInfo)

                    Divider().overlay(Color.white.opacity(0.1))

                    if let failure = player.rendererError {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("RENDERER FAILED")
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(.red)
                            Text(failure)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.red)
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                        }
                    }
                    InfoLine(label: "CAMERA", value: player.cameraInfo)
                    InfoLine(label: "CAPTURED", value: player.captureDate)
                    InfoLine(label: "TIME SOURCE", value: player.captureDateSource)
                    InfoLine(label: "GPS", value: player.gpsInfo)

                    Divider().overlay(Color.white.opacity(0.1))

                    InfoLine(label: "INSV TRAILER", value: player.trailerInfo)
                    InfoLine(label: "CALIBRATION", value: player.calibrationSource)
                    InfoLine(label: "MOTION", value: player.motionInfo)

                    if !player.trailerNotes.isEmpty {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("NOTES").font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary)
                            ForEach(Array(player.trailerNotes.enumerated()), id: \.offset) { _, note in
                                Text("• " + note)
                                    .font(.system(size: 9, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
                .padding(.top, 22)
            }

            stabilizationPicker.padding(.top, 14)
        }
        .padding(24)
        .frame(width: 262, alignment: .leading)
        .background(panelBackground)
    }

    private var stabilizationPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("STABILISATION")
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.secondary)
            Picker("", selection: $player.stabilization) {
                ForEach(Stabilization.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(!player.hasMotion)
            if player.hasMotion {
                if player.stabilization == .horizon || player.showHorizon {
                    Text("IMU HEADING")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)
                    Picker("", selection: $player.imuYaw) {
                        ForEach(IMUYaw.allCases) { yaw in
                            Text(yaw.label).tag(yaw)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    Text("180° is measured on an X5. If the horizon tips the wrong way, try the other three.")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Tweak(label: "SMOOTHING s", value: $player.horizonSmoothing,
                          range: 0.3...4.0, format: "%.2f")
                        .padding(.top, 6)
                }
                Toggle("Horizon overlay", isOn: $player.showHorizon)
                    .font(.system(size: 10, design: .monospaced))
                    .padding(.top, 6)
                if player.showHorizon {
                    Text("Red: where the IMU says level is. Green: the window's centre. Switch stabilisation OFF and check the red line against the real horizon in the footage.")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text("Needs the gyro track from the trailer")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Header and overlays

    private var header: some View {
        HStack(spacing: 14) {
            Text("LOCAL 360 PREVIEW").font(.system(size: 12, weight: .bold, design: .monospaced))
            Picker("", selection: $player.projection) {
                ForEach(ProjectionMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 368)
            Spacer()
            Text(player.isApproximate ? "APPROXIMATE STITCH" : "CAPTURE CALIBRATION")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(player.isApproximate ? Color.orange : accent)
            Button(action: { player.showInspector.toggle() }) {
                Image(systemName: "slider.horizontal.3")
            }
            .buttonStyle(.bordered)
            .help("Lens calibration")
        }
        .padding(.horizontal, 22)
        .frame(height: 62)
        .background(Color.black.opacity(0.12))
    }

    private var welcome: some View {
        VStack(spacing: 16) {
            Image(systemName: "viewfinder.circle")
                .font(.system(size: 55, weight: .thin))
                .foregroundStyle(accent)
            Text("Load a raw X5 capture").font(.title3.weight(.semibold))
            Text("Pick an unrenamed .insv to start").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func toast(_ text: String) -> some View {
        VStack {
            Spacer()
            Text(text)
                .font(.caption.monospaced())
                .padding(10)
                .background(.black.opacity(0.68))
                .clipShape(RoundedRectangle(cornerRadius: 5))
            Spacer().frame(height: 22)
        }
    }

    // MARK: - Transport

    private var controls: some View {
        HStack(spacing: 13) {
            Button(action: { player.step(by: -5) }) {
                Image(systemName: "gobackward.5").frame(width: 18)
            }
            .buttonStyle(.bordered)
            .disabled(player.state != .ready)

            Button(action: player.togglePlayback) {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").frame(width: 18)
            }
            .buttonStyle(.bordered)
            .keyboardShortcut(.space, modifiers: [])
            .disabled(player.state != .ready)

            Button(action: { player.step(by: 5) }) {
                Image(systemName: "goforward.5").frame(width: 18)
            }
            .buttonStyle(.bordered)
            .disabled(player.state != .ready)

            Text(player.currentTime).font(.caption.monospaced()).frame(width: 46, alignment: .leading)
            Slider(value: $player.position, in: 0...max(player.duration, 1), onEditingChanged: player.seek)
                .tint(accent)
                .disabled(player.state != .ready)
            Text(player.totalTime).font(.caption.monospaced()).frame(width: 46, alignment: .trailing)

            Image(systemName: "speaker.wave.2.fill").font(.system(size: 10)).foregroundStyle(.secondary)
            Slider(value: $player.volume, in: 0...1).tint(accent).frame(width: 78)

            Button(action: player.resetView) {
                Image(systemName: "view.3d")
            }
            .buttonStyle(.bordered)
            .help("Recentre the view")
        }
        .padding(.horizontal, 22)
        .frame(height: 72)
        .background(Color.black.opacity(0.24))
    }
}

// MARK: - Calibration inspector

private struct CalibrationInspector: View {
    @ObservedObject var player: PlayerModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("LENS CALIBRATION")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                Text("Align centre and radius in the Raw lenses view, then switch back to Perspective to check the seam. Changes are saved automatically.")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Toggle("Swap lens tracks", isOn: $player.profile.swapTracks)
                Toggle("Show guide circles", isOn: $player.showGuides)
                Toggle("Tint the back lens", isOn: $player.seamDebug)
                Toggle("HLG to SDR", isOn: $player.tonemapHLG)

                Tweak(label: "SEAM BLEND °", value: $player.profile.blendDegrees, range: 0.5...25, format: "%.1f")
                Tweak(label: "EXPOSURE", value: $player.exposure, range: 0.2...3.0, format: "%.2f")

                LensEditor(title: "FRONT LENS", geometry: $player.profile.front)
                LensEditor(title: "BACK LENS", geometry: $player.profile.back)

                Button("Reset to built-in profile") { player.resetProfile() }
                    .buttonStyle(.bordered)
                    .frame(maxWidth: .infinity)
            }
            .padding(18)
        }
        .frame(width: 268)
        .background(panelBackground)
    }
}

private struct LensEditor: View {
    let title: String
    @Binding var geometry: LensGeometry

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider().overlay(Color.white.opacity(0.1))
            Text(title).font(.system(size: 10, weight: .bold, design: .monospaced))
            Tweak(label: "CENTRE X", value: $geometry.centerX, range: 0.3...0.7)
            Tweak(label: "CENTRE Y", value: $geometry.centerY, range: 0.3...0.7)
            Tweak(label: "RADIUS X", value: $geometry.radiusX, range: 0.25...0.75)
            Tweak(label: "RADIUS Y", value: $geometry.radiusY, range: 0.25...0.75)
            Tweak(label: "FOV °", value: $geometry.fovDegrees, range: 150...230, format: "%.1f")
            Tweak(label: "YAW °", value: $geometry.yawDegrees, range: -200...200, format: "%.2f")
            Tweak(label: "PITCH °", value: $geometry.pitchDegrees, range: -20...20, format: "%.2f")
            Tweak(label: "ROLL °", value: $geometry.rollDegrees, range: -200...200, format: "%.2f")
            Tweak(label: "GAIN", value: $geometry.gain, range: 0.5...1.8, format: "%.3f")
            Tweak(label: "k2", value: $geometry.k2, range: -0.35...0.35)
            Tweak(label: "k3", value: $geometry.k3, range: -0.35...0.35)
            HStack {
                Toggle("Mirror U", isOn: mirror($geometry.mirrorU))
                Toggle("Mirror V", isOn: mirror($geometry.mirrorV))
            }
            .font(.system(size: 10, design: .monospaced))
        }
    }

    private func mirror(_ binding: Binding<Float>) -> Binding<Bool> {
        Binding(get: { binding.wrappedValue < 0 }, set: { binding.wrappedValue = $0 ? -1 : 1 })
    }
}

private struct Tweak<Value: BinaryFloatingPoint>: View where Value.Stride: BinaryFloatingPoint {
    let label: String
    @Binding var value: Value
    let range: ClosedRange<Value>
    var format: String = "%.3f"

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack {
                Text(label).font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary)
                Spacer()
                Text(String(format: format, Double(value))).font(.system(size: 9, design: .monospaced))
            }
            Slider(value: $value, in: range)
        }
    }
}

private struct InfoLine: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 11, design: .monospaced))
                .lineLimit(4)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
    }
}
