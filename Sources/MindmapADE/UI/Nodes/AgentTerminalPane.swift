import AppKit
import MindMapCore
import SwiftUI

struct AgentTerminalPane: View {
    let address: NodeAddress
    let session: BoardSession
    let workspace: WorkspaceStore
    let actions: EditorActions
    let terminal: AgentTerminal

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if terminal.owner == actions.windowID {
                TerminalAttachment(terminal: terminal)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .layoutPriority(1)
            } else {
                VStack(spacing: CanvasStyle.formSpacing) {
                    Text(
                        terminal.owner == nil
                            ? "Open this conversation's terminal here." : "The terminal is open in another window."
                    )
                    .multilineTextAlignment(.center)
                    Button("Open Here") { terminal.owner = actions.windowID }
                }
                .padding(CanvasStyle.formSpacing)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var header: some View {
        let node = session.board.nodes[address.nodeID]
        let title = node?.title ?? "Agent"
        let run = workspace.agentRuns[address]
        return VStack(alignment: .leading, spacing: CanvasStyle.formCompactSpacing) {
            HStack(spacing: CanvasStyle.formSpacing) {
                Label(title, systemImage: "terminal")
                    .font(.headline)
                    .lineLimit(1)
                    .help(title)
                Spacer(minLength: 0)
                Button("Hide Terminal", systemImage: "xmark") { actions.hideTerminal() }
                    .labelStyle(.iconOnly)
                    .help("Hide Terminal")
            }
            HStack(spacing: CanvasStyle.formSpacing) {
                if let run {
                    HStack(spacing: CanvasStyle.formSpacing) {
                        Text(
                            workspace.connectedMapRuns.contains(run.id)
                                ? "\(run.state.title) · Map connected" : run.state.title
                        )
                        .layoutPriority(1)
                        if let code = run.exitCode { Text("Exit \(code)").fixedSize() }
                        Text(run.directory).monospaced().truncationMode(.middle)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help(run.directory)
                }
                Spacer(minLength: 0)
                if case .agent(let agent) = node?.content, !agent.task.isEmpty {
                    Button("Copy Task", systemImage: "document.on.document") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(agent.task, forType: .string)
                    }
                    .labelStyle(.iconOnly)
                    .help("Copy the initial task")
                }
                if run?.state.isActive == true {
                    Button("Stop", systemImage: "stop.circle") { workspace.stopAgent(at: address) }
                        .labelStyle(.iconOnly)
                        .help("Stop Conversation")
                        .disabled(run?.state != .running)
                } else {
                    Button("Start Again", systemImage: "arrow.clockwise") {
                        actions.canvas?.configureNode(address.nodeID)
                    }
                    .labelStyle(.iconOnly)
                    .help("Start Again")
                }
            }
        }
        .controlSize(.small)
        .buttonStyle(.borderless)
        .padding(.horizontal, CanvasStyle.statusHorizontalPadding)
        .padding(.vertical, CanvasStyle.statusVerticalPadding)
        .background(.bar)
    }
}

private struct TerminalAttachment: NSViewRepresentable {
    let terminal: AgentTerminal

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ container: NSView, context: Context) {
        guard terminal.view.superview !== container else { return }
        terminal.view.removeFromSuperview()
        terminal.view.frame = container.bounds
        terminal.view.autoresizingMask = [.width, .height]
        container.addSubview(terminal.view)
    }

    static func dismantleNSView(_ view: NSView, coordinator: ()) {
        for child in view.subviews { child.removeFromSuperview() }
    }
}

struct TerminalDivider: NSViewRepresentable {
    let width: CGFloat
    let resize: (CGFloat) -> Void

    func makeNSView(context: Context) -> Grip {
        let view = Grip()
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.slider)
        view.setAccessibilityLabel("Terminal width")
        return view
    }

    func updateNSView(_ view: Grip, context: Context) {
        view.terminalWidth = width
        view.resize = resize
        view.setAccessibilityValue("\(Int(width)) points")
    }

    final class Grip: NSView {
        var terminalWidth: CGFloat = 0
        var resize: ((CGFloat) -> Void)?
        private var dragOrigin: (x: CGFloat, width: CGFloat)?

        override func draw(_ dirtyRect: NSRect) {
            NSColor.separatorColor.setFill()
            CGRect(x: bounds.midX, y: 0, width: CanvasStyle.borderWidth, height: bounds.height).fill()
        }

        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .columnResize)
        }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func accessibilityPerformIncrement() -> Bool {
            resize?(terminalWidth + CanvasStyle.terminalResizeStep)
            return resize != nil
        }

        override func accessibilityPerformDecrement() -> Bool {
            resize?(terminalWidth - CanvasStyle.terminalResizeStep)
            return resize != nil
        }

        override func mouseDown(with event: NSEvent) {
            dragOrigin = (event.locationInWindow.x, terminalWidth)
        }

        override func mouseDragged(with event: NSEvent) {
            guard let origin = dragOrigin else { return }
            resize?(origin.width + origin.x - event.locationInWindow.x)
        }

        override func mouseUp(with event: NSEvent) { dragOrigin = nil }
    }
}
