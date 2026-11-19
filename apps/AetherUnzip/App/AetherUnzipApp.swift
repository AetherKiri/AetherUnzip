import SwiftUI

@main
struct AetherUnzipApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            WorkspaceView(model: model)
                #if os(macOS)
                .frame(minWidth: 700, minHeight: 460)
                #endif
        }
        #if os(macOS)
        .defaultSize(width: 1000, height: 620)
        #endif
    }
}
