import AppKit
import MindMapCore
import SwiftUI

struct AgentTerminalPane: View {
    let address: NodeAddress
    let session: BoardSession
    let workspace: WorkspaceStore
    let actions: EditorActions
    @State private var output: String?
    @State private var previousOutput: String?
    @State private var showsPreviousOutput = false

    private var run: AgentRun? { workspace.agentRuns[address] }
    private var recoveryIssue: AgentRecoveryIssue? { workspace.recoveryIssues[address] }
    private var hasSavedConversation: Bool { workspace.savedConversation(at: address) != nil }
    private var isOpening: Bool {
        workspace.operations.contains(address) && (run?.state.isActive != true || run?.state == .starting)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let terminal = workspace.terminals[address], !showsPreviousOutput {
                liveTerminal(terminal)
            } else {
                if run?.state.isActive != true || isOpening {
                    recoveryActions
                    Divider()
                }
                transcript
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task {
            workspace.requestAgentResume(at: address, owner: actions.windowID, automatically: true)
        }
        .task(id: run) {
            guard let run else { return }
            let latest = await workspace.agentFiles.snapshot(for: run.id)
            let earlier =
                if let id = run.previousSnapshotID { await workspace.agentFiles.snapshot(for: id) } else {
                    nil as String?
                }
            guard !Task.isCancelled else { return }
            output = latest
            previousOutput = earlier
            if earlier == nil { showsPreviousOutput = false }
        }
    }

    @ViewBuilder
    private func liveTerminal(_ terminal: AgentTerminal) -> some View {
        if terminal.owner == actions.windowID {
            TerminalAttachment(terminal: terminal)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .layoutPriority(1)
        } else {
            VStack(spacing: CanvasStyle.formSpacing) {
                Text(
                    terminal.owner == nil
                        ? "Open this conversation’s terminal here." : "The terminal is open in another window."
                )
                .multilineTextAlignment(.center)
                Button("Open Here") { actions.showTerminal(at: address, revealNode: false) }
            }
            .padding(CanvasStyle.formSpacing)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var transcript: some View {
        if let text = showsPreviousOutput ? previousOutput : (output ?? previousOutput) {
            ScrollView {
                Text(verbatim: text)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(CanvasStyle.statusHorizontalPadding)
            }
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            .accessibilityLabel("Terminal output")
        } else if !isOpening {
            Text("No terminal output was saved.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var recoveryActions: some View {
        VStack(alignment: .leading, spacing: CanvasStyle.formCompactSpacing) {
            if isOpening {
                HStack(spacing: CanvasStyle.formSpacing) {
                    ProgressView().controlSize(.small)
                    Text("Opening conversation…")
                }
            } else if let run {
                if let message = recoveryIssue?.errorDescription ?? run.error {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .fixedSize(horizontal: false, vertical: true)
                } else if !hasSavedConversation {
                    Text("There is no saved conversation for this Agent configuration.")
                        .foregroundStyle(.secondary)
                }
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: CanvasStyle.formSpacing) {
                        recoveryButtons(for: run)
                    }
                    .fixedSize(horizontal: true, vertical: false)
                    VStack(alignment: .leading, spacing: CanvasStyle.formSpacing) {
                        recoveryButtons(for: run)
                    }
                }
                .disabled(workspace.isReadOnly)
            }
        }
        .font(.callout)
        .controlSize(.small)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, CanvasStyle.statusHorizontalPadding)
        .padding(.vertical, CanvasStyle.statusVerticalPadding)
    }

    @ViewBuilder
    private func recoveryButtons(for run: AgentRun) -> some View {
        if hasSavedConversation {
            Button(recoveryTitle(for: run)) {
                showsPreviousOutput = false
                workspace.requestAgentResume(at: address, owner: actions.windowID)
            }
        }
        if !hasSavedConversation || recoveryIssue != nil || run.state == .failed {
            Button("New Conversation…") { actions.canvas?.configureNode(address.nodeID) }
        }
    }

    private func recoveryTitle(for run: AgentRun) -> String {
        if recoveryIssue?.checkoutToConfirm != nil { return "Continue on This Branch" }
        if recoveryIssue != nil || run.state == .failed { return "Try Again" }
        return run.state == .stopped ? "Restart Terminal" : "Continue Conversation"
    }

    private var header: some View {
        let node = session.board.nodes[address.nodeID]
        let title = node?.title ?? "Agent"
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
                if previousOutput != nil {
                    Button(
                        showsPreviousOutput ? "Show Latest Output" : "Show Previous Output",
                        systemImage: showsPreviousOutput ? "terminal" : "clock.arrow.circlepath"
                    ) { showsPreviousOutput.toggle() }
                    .labelStyle(.iconOnly)
                    .help(showsPreviousOutput ? "Show Latest Output" : "Show Previous Output")
                }
                if run?.state.isActive == true {
                    Button("Stop", systemImage: "stop.circle") { workspace.stopAgent(at: address) }
                        .labelStyle(.iconOnly)
                        .help("Stop Conversation")
                        .disabled(run?.state != .running)
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
