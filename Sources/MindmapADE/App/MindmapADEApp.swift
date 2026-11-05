import SwiftUI

@main
struct MindmapADEApp: App {
    var body: some Scene {
        WindowGroup("Mindmap ADE", id: "main") {
            RootView()
        }
        .defaultSize(width: WindowLayout.defaultWidth, height: WindowLayout.defaultHeight)
        .defaultPosition(.center)
    }
}
