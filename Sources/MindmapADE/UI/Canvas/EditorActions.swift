import AppKit
import MindMapCore
import Observation
import SwiftUI

@Observable
final class EditorActions {
    enum RightPane: Equatable {
        case terminal(NodeAddress)
        case gitChanges(NodeAddress)

        var address: NodeAddress {
            switch self {
            case .terminal(let address), .gitChanges(let address): address
            }
        }

        var kind: RightPaneKind {
            switch self {
            case .terminal: .terminal
            case .gitChanges: .gitChanges
            }
        }
    }

    static let defaultHint = "Shift-drag to select · Drag to pan · Double-click to edit"

    @ObservationIgnored weak var canvas: MindMapCanvasView?
    @ObservationIgnored weak var workspace: WorkspaceStore?
    var targetBoardID: UUID?
    let windowID = UUID()
    private(set) var rightPane: RightPane?
    private(set) var paneWidthShare: CGFloat = 0.5
    var terminalAddress: NodeAddress? {
        if case .terminal(let address) = rightPane { address } else { nil }
    }
    var gitChangesAddress: NodeAddress? {
        if case .gitChanges(let address) = rightPane { address } else { nil }
    }
    var terminalWidthShare: CGFloat { paneWidthShare }
    var requestedBoardID: UUID?
    var canAddProject = false
    var canAddWorktree = false
    var canLinkWorktree = false
    var canToggleWorktreeGitChanges = false
    var worktreeShowsGitChanges = false
    var canAddExternalGitChanges = false
    var canDeriveAgent = false
    var zoomLabel = "100%"
    var canEdit = false
    var canDelete = false
    var canPromote = false
    var canDemote = false
    var undoTitle = "Undo"
    var redoTitle = "Redo"
    var canUndo = false
    var canRedo = false
    var isEditingTopic = false
    var canCollapse = false
    var canFocusBranch = false
    var isBranchFocused = false
    var isFinding = false
    var findFieldHasFocus = false
    private(set) var findFocusRequest = 0
    var hint = defaultHint
    var dropHint: String?

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
    func showTerminal(at address: NodeAddress, revealNode: Bool = true) {
        guard let workspace, workspace.canOpenAgent(at: address) else { return }
        if terminalAddress != address { detachTerminal() }
        rightPane = .terminal(address)
        workspace.terminals[address]?.owner = windowID
        saveRightPane()
        if revealNode { canvas?.revealRightPaneNode(address) }
    }

    func showGitChanges(at address: NodeAddress, revealNode: Bool = true) {
        guard let workspace, workspace.canOpenGitChanges(at: address) else { return }
        if terminalAddress != nil { detachTerminal() }
        rightPane = .gitChanges(address)
        saveRightPane()
        if revealNode { canvas?.revealRightPaneNode(address) }
    }

    func hideRightPane() {
        detachTerminal()
        rightPane = nil
        saveRightPane()
    }

    func hideTerminal() {
        hideRightPane()
    }

    func detachTerminal() {
        if let address = terminalAddress, workspace?.terminals[address]?.owner == windowID {
            workspace?.terminals[address]?.owner = nil
        }
        if case .terminal = rightPane { rightPane = nil }
    }

    func restoreRightPane() {
        guard let state = workspace?.restoreRightPane(for: windowID) else { return }
        paneWidthShare = state.widthShare
        switch state.kind {
        case .terminal: showTerminal(at: state.address, revealNode: false)
        case .gitChanges: showGitChanges(at: state.address, revealNode: false)
        }
    }

    func restoreTerminalPane() {
        restoreRightPane()
    }

    func resizePane(to share: CGFloat) {
        guard paneWidthShare != share else { return }
        paneWidthShare = share
        saveRightPane()
    }

    func resizeTerminal(to share: CGFloat) {
        resizePane(to: share)
    }

    private func saveRightPane() {
        let state = rightPane.map { RightPaneState(address: $0.address, kind: $0.kind, widthShare: paneWidthShare) }
        workspace?.rememberRightPane(state, from: windowID)
    }

    func add(_ kind: NodeKind) { activeCanvas?.insertResource(kind) }
    func toggleWorktreeGitChanges() { activeCanvas?.toggleWorktreeGitChanges() }
    func addExternalGitChanges() { activeCanvas?.chooseExternalGitChanges() }
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
    func toggleBranchFocus() { activeCanvas?.toggleBranchFocus() }

    func showFind() {
        guard let activeCanvas else { return }
        activeCanvas.prepareForFind()
        isFinding = true
        findFocusRequest += 1
    }

    func closeFind() {
        isFinding = false
        activeCanvas?.focusCanvas()
    }

    func showFindResult(_ id: UUID) { activeCanvas?.jumpToTopic(id, focusingCanvas: false) }

    var shouldUndoBoardDeletion: Bool {
        guard !findFieldHasFocus, !isEditingTopic, let deletion = workspace?.lastBoardDeletionTime else { return false }
        guard let mapEdit = workspace?.board(targetBoardID)?.lastUndoTime else { return true }
        return deletion >= mapEdit
    }

    func undo() {
        if findFieldHasFocus {
            NSApp.keyWindow?.firstResponder?.undoManager?.undo()
        } else if shouldUndoBoardDeletion, let id = workspace?.undoDeleteBoard() {
            targetBoardID = id
            requestedBoardID = id
        } else {
            activeCanvas?.undoCommand()
        }
    }
    func redo() {
        if findFieldHasFocus {
            NSApp.keyWindow?.firstResponder?.undoManager?.redo()
        } else {
            activeCanvas?.redoCommand()
        }
    }
    func groupSelection() { activeCanvas?.groupSelection() }
    func changeLevel(promoting: Bool) { activeCanvas?.changeLevel(promoting: promoting) }
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
                .disabled(
                    actions?.findFieldHasFocus != true && !restoresBoard
                        && (actions?.canvas == nil || actions?.canUndo != true))
            Button(actions?.redoTitle ?? "Redo") { actions?.redo() }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(actions?.findFieldHasFocus != true && actions?.canRedo != true)
        }
        CommandGroup(after: .pasteboard) {
            Button("Find Topics…") { actions?.showFind() }
                .keyboardShortcut("f")
                .disabled(actions?.targetBoardID == nil)
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
                Button("Track Another Repository…", systemImage: NodeKind.gitChanges.symbol) {
                    actions?.addExternalGitChanges()
                }
                .disabled(actions?.canAddExternalGitChanges != true)
            }
            .disabled(actions?.canvas == nil || actions?.workspace?.isReadOnly != false)
            Button("Link Existing Worktree…", systemImage: "link") { actions?.linkWorktree() }
                .disabled(actions?.canLinkWorktree != true)
            Toggle(
                "Show Git Changes",
                isOn: Binding(
                    get: { actions?.worktreeShowsGitChanges == true },
                    set: { _ in actions?.toggleWorktreeGitChanges() }
                )
            )
            .disabled(actions?.canToggleWorktreeGitChanges != true)
            Button("New Agent from Text") { actions?.deriveAgent() }
                .disabled(actions?.canDeriveAgent != true)
            Divider()
            Button("Edit or Open Node") { actions?.edit() }.disabled(actions?.canEdit != true)
            Button("Collapse or Expand") { actions?.collapse() }
                .keyboardShortcut(".", modifiers: [.command, .option])
                .disabled(actions?.canCollapse != true)
            Divider()
            Button("Group Under New Topic") { actions?.groupSelection() }
                .keyboardShortcut("g", modifiers: [.command, .option])
                .disabled(actions?.canDelete != true)
            Button("Promote") { actions?.changeLevel(promoting: true) }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
                .disabled(actions?.canPromote != true)
            Button("Demote") { actions?.changeLevel(promoting: false) }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
                .disabled(actions?.canDemote != true)
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
            Button(actions?.isBranchFocused == true ? "Exit Branch Focus" : "Focus on Branch") {
                actions?.toggleBranchFocus()
            }
            .keyboardShortcut("f", modifiers: [.command, .shift])
            .disabled(actions?.canFocusBranch != true)
        }
        SidebarCommands()
        ToolbarCommands()
    }
}
