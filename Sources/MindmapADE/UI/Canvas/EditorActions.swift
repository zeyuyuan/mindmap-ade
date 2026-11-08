import AppKit
import MindMapCore
import Observation
import SwiftUI

@Observable
final class EditorActions {
    static let defaultHint = "Double-click to edit · Tab to add a child · Drag the canvas to pan"

    @ObservationIgnored weak var canvas: MindMapCanvasView?
    @ObservationIgnored weak var workspace: WorkspaceStore?
    var targetBoardID: UUID?
    let windowID = UUID()
    var terminalAddress: NodeAddress?
    var requestedBoardID: UUID?
    var canAddProject = false
    var canAddWorktree = false
    var canLinkWorktree = false
    var canDeriveAgent = false
    var zoomLabel = "100%"
    var canEdit = false
    var canDelete = false
    var undoTitle = "Undo"
    var redoTitle = "Redo"
    var canUndo = false
    var canRedo = false
    var isEditingTopic = false
    var canCollapse = false
    var hint = defaultHint

    func activateTarget() {
        guard let id = targetBoardID, let session = workspace?.board(id), canvas?.session !== session else { return }
        canvas?.update(session: session, revision: session.revision)
    }

    private var activeCanvas: MindMapCanvasView? {
        activateTarget()
        return canvas
    }

    func newBoard() {
        targetBoardID = workspace?.createBoard()
        requestedBoardID = targetBoardID
    }
    func showTerminal(at address: NodeAddress) {
        guard let terminal = workspace?.terminals[address] else { return }
        if terminalAddress != address { hideTerminal() }
        terminalAddress = address
        terminal.owner = windowID
        canvas?.revealTerminalNode(address)
    }

    func hideTerminal() {
        if let address = terminalAddress, workspace?.terminals[address]?.owner == windowID {
            workspace?.terminals[address]?.owner = nil
        }
        terminalAddress = nil
    }

    func add(_ kind: NodeKind) { activeCanvas?.insertResource(kind) }
    func linkWorktree() { activeCanvas?.insertResource(.worktree, linkWorktree: true) }
    func deriveAgent() { activeCanvas?.deriveAgent() }

    func addChild() { activeCanvas?.insertNode(asChild: true) }
    func addSibling() { activeCanvas?.insertNode(asChild: false) }
    func addRoot() { activeCanvas?.insertRoot() }
    func edit() { activeCanvas?.editSelection() }
    func delete() { activeCanvas?.deleteSelection() }
    func collapse() { activeCanvas?.toggleCollapse() }
    func zoomIn() { activeCanvas?.zoom(by: 1.2) }
    func zoomOut() { activeCanvas?.zoom(by: 1 / 1.2) }
    func actualSize() { activeCanvas?.setZoom(1) }
    func fit() { activeCanvas?.fitContent() }
    var shouldUndoBoardDeletion: Bool {
        guard !isEditingTopic, let deletion = workspace?.lastBoardDeletionTime else { return false }
        guard let mapEdit = workspace?.board(targetBoardID)?.lastUndoTime else { return true }
        return deletion >= mapEdit
    }

    func undo() {
        if shouldUndoBoardDeletion, let id = workspace?.undoDeleteBoard() {
            targetBoardID = id
            requestedBoardID = id
        } else {
            activeCanvas?.undoCommand()
        }
    }
    func redo() { activeCanvas?.redoCommand() }
    func moveUp() { activeCanvas?.moveSelection(by: -1) }
    func moveDown() { activeCanvas?.moveSelection(by: 1) }
}

private struct EditorActionsKey: FocusedValueKey {
    typealias Value = EditorActions
}

extension FocusedValues {
    var editorActions: EditorActions? {
        get { self[EditorActionsKey.self] }
        set { self[EditorActionsKey.self] = newValue }
    }
}

struct MindMapCommands: Commands {
    @FocusedValue(\.editorActions) private var actions
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Board") { actions?.newBoard() }
                .keyboardShortcut("n")
                .disabled(actions?.workspace?.isReadOnly != false)
            Button("New Window") { openWindow(id: "main") }
                .keyboardShortcut("n", modifiers: [.command, .shift])
        }
        CommandGroup(replacing: .undoRedo) {
            let restoresBoard = actions?.shouldUndoBoardDeletion == true
            Button(restoresBoard ? "Undo Delete Board" : (actions?.undoTitle ?? "Undo")) { actions?.undo() }
                .keyboardShortcut("z")
                .disabled(!restoresBoard && (actions?.canvas == nil || actions?.canUndo != true))
            Button(actions?.redoTitle ?? "Redo") { actions?.redo() }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(actions?.canRedo != true)
        }
        CommandMenu("Node") {
            Button("Add Child") { actions?.addChild() }.disabled(actions?.canEdit != true)
            Button("Add Sibling") { actions?.addSibling() }.disabled(actions?.canEdit != true)
            Button("Add Root") { actions?.addRoot() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(actions?.canvas == nil || actions?.workspace?.isReadOnly != false)
            Menu("Add Resource") {
                Button("Project", systemImage: NodeKind.project.symbol) { actions?.add(.project) }
                    .disabled(actions?.canAddProject != true)
                Button("Worktree", systemImage: NodeKind.worktree.symbol) { actions?.add(.worktree) }
                    .disabled(actions?.canAddWorktree != true)
                Button("Agent", systemImage: NodeKind.agent.symbol) { actions?.add(.agent) }
            }
            .disabled(actions?.canvas == nil || actions?.workspace?.isReadOnly != false)
            Button("Link Existing Worktree…", systemImage: "link") { actions?.linkWorktree() }
                .disabled(actions?.canLinkWorktree != true)
            Button("New Agent from Text") { actions?.deriveAgent() }
                .disabled(actions?.canDeriveAgent != true)
            Divider()
            Button("Edit or Open Node") { actions?.edit() }.disabled(actions?.canEdit != true)
            Button("Collapse or Expand") { actions?.collapse() }
                .keyboardShortcut(".", modifiers: [.command, .option])
                .disabled(actions?.canCollapse != true)
            Divider()
            Button("Move Up") { actions?.moveUp() }
                .keyboardShortcut(.upArrow, modifiers: [.command, .option])
                .disabled(actions?.canEdit != true)
            Button("Move Down") { actions?.moveDown() }
                .keyboardShortcut(.downArrow, modifiers: [.command, .option])
                .disabled(actions?.canEdit != true)
            Button("Delete") { actions?.delete() }.disabled(actions?.canDelete != true)
        }
        CommandGroup(after: .toolbar) {
            Divider()
            Button("Zoom In") { actions?.zoomIn() }.keyboardShortcut("+")
            Button("Zoom Out") { actions?.zoomOut() }.keyboardShortcut("-")
            Button("Actual Size") { actions?.actualSize() }.keyboardShortcut("0")
            Button("Fit Content") { actions?.fit() }.keyboardShortcut("0", modifiers: [.command, .shift])
        }
        SidebarCommands()
        ToolbarCommands()
    }
}
