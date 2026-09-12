import SwiftUI

@main
struct X5PlayerApp: App {
    var body: some Scene {
        WindowGroup("X5 INSV Player") {
            ContentView()
                .frame(minWidth: 980, minHeight: 650)
        }
        .windowStyle(.hiddenTitleBar)
    }
}
