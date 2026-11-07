import SwiftUI

@main
struct MindmapADEApp: App {
    @NSApplicationDelegateAdaptor(MindmapAppDelegate.self) private var delegate
    @State private var workspace = WorkspaceStore()

    var body: some Scene {
        WindowGroup("Mindmap ADE", id: "main") {
            RootView(workspace: workspace)
                .onAppear { delegate.workspace = workspace }
        }
        .defaultSize(width: WindowLayout.defaultWidth, height: WindowLayout.defaultHeight)
        .defaultPosition(.center)
        .commands { MindMapCommands() }
    }
}

final class MindmapAppDelegate: NSObject, NSApplicationDelegate {
    var workspace: WorkspaceStore?

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
            let arguments = ProcessInfo.processInfo.arguments
            if let index = arguments.firstIndex(of: "--appearance"), arguments.indices.contains(index + 1) {
                NSApp.appearance = NSAppearance(named: arguments[index + 1] == "dark" ? .darkAqua : .aqua)
            }
            if arguments.contains("--minimum-window") {
                DispatchQueue.main.async {
                    for window in NSApp.windows where window.canBecomeMain {
                        window.setContentSize(
                            NSSize(width: WindowLayout.minimumWidth, height: WindowLayout.minimumHeight))
                    }
                }
            }
        #endif
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        sender.keyWindow?.makeFirstResponder(nil)
        guard let workspace else { return .terminateNow }
        workspace.commitEdits()
        Task {
            do {
                try await workspace.flush()
                sender.reply(toApplicationShouldTerminate: true)
            } catch {
                let alert = NSAlert()
                alert.messageText = "The workspace could not be saved."
                alert.informativeText = error.localizedDescription
                alert.addButton(withTitle: "Keep Open")
                alert.runModal()
                sender.reply(toApplicationShouldTerminate: false)
            }
        }
        return .terminateLater
    }
}
