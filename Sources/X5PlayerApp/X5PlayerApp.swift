import AppKit
import SwiftUI

extension Notification.Name {
    static let x5OpenFile = Notification.Name("tv.titanos.x5.openFile")
}

/// Entry point. `--dump` runs the trailer inspector instead of the window, so a
/// real capture can be examined without a GUI round trip.
@main
enum X5Main {
    static func main() {
        let arguments = CommandLine.arguments
        if arguments.count >= 2, arguments[1] == "--dump" {
            INSVDump.run(paths: Array(arguments.dropFirst(2)))
            return
        }
        X5PlayerApp.main()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // A SwiftPM executable has no app bundle, so it starts as an accessory
        // process and its window never takes focus without this.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

struct X5PlayerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup("X5 Insv Player") {
            ContentView()
                .frame(minWidth: 1080, minHeight: 680)
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open .insv\u{2026}") {
                    NotificationCenter.default.post(name: .x5OpenFile, object: nil)
                }
                .keyboardShortcut("o", modifiers: .command)
            }
        }
    }
}
