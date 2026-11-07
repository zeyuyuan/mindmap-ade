import AppKit
import Observation
import SwiftUI

@Observable
final class EditorActions {
    @ObservationIgnored weak var canvas: MindMapCanvasView?
    @ObservationIgnored weak var workspace: WorkspaceStore?
    @ObservationIgnored var targetBoardID: UUID?
    var requestedBoardID: UUID?
    var zoomLabel = "100%"
    var canEdit = false
    var canUndo = false
    var canRedo = false
    var canCollapse = false
    var hint = "Double-click to edit · Tab to add a child · Drag the canvas to pan"

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
    func undo() { activeCanvas?.undoCommand() }
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
            Button("Undo") { actions?.undo() }
                .keyboardShortcut("z")
                .disabled(actions?.canUndo != true)
            Button("Redo") { actions?.redo() }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(actions?.canRedo != true)
        }
        CommandMenu("Node") {
            Button("Add Child") { actions?.addChild() }.disabled(actions?.canEdit != true)
            Button("Add Sibling") { actions?.addSibling() }.disabled(actions?.canEdit != true)
            Button("Add Root") { actions?.addRoot() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(actions?.canvas == nil || actions?.workspace?.isReadOnly != false)
            Divider()
            Button("Edit Text") { actions?.edit() }.disabled(actions?.canEdit != true)
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
            Button("Delete") { actions?.delete() }.disabled(actions?.canEdit != true)
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
