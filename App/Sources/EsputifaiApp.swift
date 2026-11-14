import SwiftUI

@main
struct EsputifaiApp: App {
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // Covers and avatars are fetched over and over while scrolling: keep them around.
        URLCache.shared = URLCache(memoryCapacity: 50_000_000, diskCapacity: 300_000_000)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                // Shared playlists: esputifai://import?d=<data>, opened from the link's web page.
                .onOpenURL { model.receiveShared($0.absoluteString) }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { model.becameActive() }
        }
    }
}
