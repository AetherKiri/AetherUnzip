import SwiftUI

@main
struct AetherUnzipApp: App {
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var phase
    @AppStorage(CachePreferences.automaticCleanupKey) private var automaticallyClearCache = true

    var body: some Scene {
        WindowGroup {
            WorkspaceView(model: model)
                .modifier(WorkspaceAccent())
                .task(id: phase) {
                    if phase == .active, automaticallyClearCache {
                        _ = try? await PreviewCache.shared.usage(clearing: true)
                    }
                }
                #if os(macOS)
                .frame(minWidth: 700, minHeight: 460)
                #endif
        }
        #if os(macOS)
        .defaultSize(width: 1000, height: 620)
        #endif
    }
}
