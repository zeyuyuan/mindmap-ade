import SwiftUI

@main
enum MindmapEntryPoint {
    static func main() {
        if CommandLine.arguments.dropFirst().first == "--mindmap-mcp" {
            MCPStdioBridge.run()
        } else {
            MindmapADEApp.main()
        }
    }
}

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
        guard let workspace else { return .terminateNow }
        if !workspace.operations.isEmpty {
            let alert = NSAlert()
            alert.messageText = "A workspace operation is still running."
            alert.informativeText = "Wait for the node to finish preparing, then quit again."
            alert.addButton(withTitle: "Keep Open")
            alert.runModal()
            return .terminateCancel
        }
        if workspace.hasActiveWork() {
            let alert = NSAlert()
            alert.messageText = "Stop Agent conversations and quit?"
            alert.informativeText = "Active CLI processes will stop. Their worktree files will remain on disk."
            alert.addButton(withTitle: "Stop and Quit")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
        }
        workspace.commitEdits()
        sender.keyWindow?.makeFirstResponder(nil)
        Task {
            do {
                try await workspace.flush()
                if workspace.hasActiveWork() || workspace.mcpListener != nil { try await workspace.stopAllAgents() }
                if workspace.saveState != .saved { try await workspace.flush() }
                sender.reply(toApplicationShouldTerminate: true)
            } catch {
                let alert = NSAlert()
                alert.messageText = "Mindmap ADE could not quit."
                alert.informativeText = error.localizedDescription
                alert.addButton(withTitle: "Keep Open")
                alert.runModal()
                sender.reply(toApplicationShouldTerminate: false)
            }
        }
        return .terminateLater
    }
}
