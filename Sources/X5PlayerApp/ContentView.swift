import SwiftUI
import UniformTypeIdentifiers


extension UTType {
    static let insta360INSV = UTType(exportedAs: "com.insta360.insv", conformingTo: .movie, tagSpecification: [.filenameExtension: "insv"])
}
struct ContentView: View {
    @StateObject private var player = PlayerModel()

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider().overlay(Color.white.opacity(0.14))
            VStack(spacing: 0) {
                header
                ZStack {
                    MetalPanoramaView(player: player)
                        .background(Color.black)
                    if player.state == .empty {
                        welcome
                    }
                    if let message = player.message {
                        VStack { Spacer(); Text(message).font(.caption.monospaced()).padding(10).background(.black.opacity(0.68)).clipShape(RoundedRectangle(cornerRadius: 5)); Spacer().frame(height: 22) }
                    }
                }
                controls
            }
        }
        .background(Color(red: 0.055, green: 0.067, blue: 0.071))
        .preferredColorScheme(.dark)
        .fileImporter(isPresented: $player.showImporter, allowedContentTypes: [.insta360INSV, .movie, .data]) { result in
            player.open(result)
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Circle().stroke(Color(red: 0.82, green: 1, blue: 0.30), lineWidth: 2).frame(width: 24, height: 24).overlay(Circle().stroke(Color(red: 0.82, green: 1, blue: 0.30), lineWidth: 1).padding(6))
                Text("ORBIT X5").font(.headline.weight(.bold)).tracking(1.7)
            }
            Text("RAW INSV PLAYER").font(.caption2.monospaced()).foregroundStyle(.secondary).padding(.top, 8)
            Button(action: { player.showImporter = true }) {
                VStack(spacing: 6) { Image(systemName: "folder.badge.plus").font(.title2); Text("開啟 X5 原始影片").font(.caption.weight(.semibold)); Text(".INSV / HEVC 雙鏡頭軌").font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary) }
                    .frame(maxWidth: .infinity).frame(height: 98)
            }
            .buttonStyle(.bordered)
            .tint(Color(red: 0.70, green: 0.93, blue: 0.26))
            .padding(.top, 38)
            VStack(alignment: .leading, spacing: 16) {
                InfoLine(label: "CAPTURE", value: player.captureName)
                InfoLine(label: "LENS TRACKS", value: player.trackInfo)
                InfoLine(label: "FRAME SIZE", value: player.frameSize)
                InfoLine(label: "STATUS", value: player.state.label)
            }.padding(.top, 34)
            Spacer()
            Text("FIRST LIGHT / X5\nApproximate lens profile\nNo gyro lock in this build")
                .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).lineSpacing(4)
        }
        .padding(24).frame(width: 255, alignment: .leading).background(Color(red: 0.07, green: 0.086, blue: 0.09))
    }

    private var header: some View {
        HStack { Text("LOCAL 360 PREVIEW").font(.system(size: 12, weight: .bold, design: .monospaced)); Spacer(); Text(player.isApproximate ? "APPROXIMATE STITCH" : "READY").font(.system(size: 10, weight: .medium, design: .monospaced)).foregroundStyle(player.isApproximate ? Color.orange : Color(red: 0.82, green: 1, blue: 0.30)) }
            .padding(.horizontal, 26).frame(height: 62).background(Color.black.opacity(0.12))
    }

    private var welcome: some View {
        VStack(spacing: 16) {
            Image(systemName: "viewfinder.circle").font(.system(size: 55, weight: .thin)).foregroundStyle(Color(red: 0.82, green: 1, blue: 0.30))
            Text("載入 X5 的原始視野").font(.title3.weight(.semibold))
            Text("選取未改名的 .insv 開始預覽").font(.caption).foregroundStyle(.secondary)
        }
    }

    private var controls: some View {
        HStack(spacing: 15) {
            Button(action: player.togglePlayback) { Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").frame(width: 18) }.buttonStyle(.bordered)
            Text(player.currentTime).font(.caption.monospaced()).frame(width: 46, alignment: .leading)
            Slider(value: $player.position, in: 0...max(player.duration, 1), onEditingChanged: player.seek)
                .tint(Color(red: 0.82, green: 1, blue: 0.30))
            Text(player.totalTime).font(.caption.monospaced()).frame(width: 46, alignment: .trailing)
            Button(action: player.resetView) { Image(systemName: "view.3d") }.buttonStyle(.bordered).help("重設視角")
        }
        .padding(.horizontal, 26).frame(height: 72).background(Color.black.opacity(0.24))
    }
}

private struct InfoLine: View {
    let label: String; let value: String
    var body: some View { VStack(alignment: .leading, spacing: 4) { Text(label).font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary); Text(value).font(.system(size: 11, design: .monospaced)).lineLimit(2).textSelection(.enabled) } }
}
