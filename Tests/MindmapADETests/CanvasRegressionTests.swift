import AppKit
import Testing

@testable import MindMapCore
@testable import MindmapADE

actor MemoryWorkspaceDisk: WorkspacePersistence {
    nonisolated let directory = URL(fileURLWithPath: "/tmp/MindmapADE-tests-\(UUID())")
    private var archive: WorkspaceArchive
    private var fails = false

    init(board: MindMapBoard = MindMapBoard(root: TextNode(text: "Original"))) {
        archive = WorkspaceArchive(boards: [board])
    }

    func load() -> (WorkspaceArchive?, Bool) { (archive, true) }
    func save(_ value: WorkspaceArchive) throws {
        if fails { throw CocoaError(.fileWriteNoPermission) }
        archive = value
    }
    func failWrites(_ value: Bool) { fails = value }
    func snapshot() -> WorkspaceArchive { archive }
}

@MainActor
private final class CanvasFixture {
    let actions = EditorActions()
    let view: MindMapCanvasView
    let window: NSWindow

    init(workspace: WorkspaceStore, session: BoardSession) {
        _ = NSApplication.shared
        view = MindMapCanvasView(session: session, workspace: workspace, actions: actions)
        window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 1000, height: 640),
            styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = view
        view.update(session: session, revision: session.revision)
    }

    func ready() async throws {
        for _ in 0..<100 {
            if !(view.accessibilityChildren() ?? []).isEmpty { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw CocoaError(.coderReadCorrupt)
    }

    var editor: NSTextView? { view.accessibilityChildren()?.compactMap { $0 as? NSTextView }.first }

    func type(_ text: String) throws {
        let textView = try #require(editor)
        textView.string = text
        view.textDidChange(Notification(name: NSText.didChangeNotification, object: textView))
    }

    func close() {
        view.prepareForRemoval()
        window.close()
    }

    func event(_ kind: NSEvent.EventType, at point: CGPoint, modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try #require(
            NSEvent.mouseEvent(
                with: kind, location: view.convert(point, to: nil),
                modifierFlags: modifiers, timestamp: 0, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    }

    func click(_ point: CGPoint, modifiers: NSEvent.ModifierFlags = []) throws {
        view.mouseDown(with: try event(.leftMouseDown, at: point, modifiers: modifiers))
        view.mouseUp(with: try event(.leftMouseUp, at: point, modifiers: modifiers))
    }

    func drag(from: CGPoint, to: CGPoint) throws {
        view.mouseDown(with: try event(.leftMouseDown, at: from))
        view.mouseDragged(with: try event(.leftMouseDragged, at: to))
        view.mouseUp(with: try event(.leftMouseUp, at: to))
    }
}

@Suite(.serialized)
@MainActor
struct CanvasRegressionTests {
    @Test func aNewWindowTakesOverEditingWithoutCancelRevertingAnotherCommit() async throws {
        let workspace = WorkspaceStore(disk: MemoryWorkspaceDisk())
        await workspace.loadIfNeeded()
        let session = try #require(workspace.boards.first)
        let root = session.board.roots[0].id
        let first = CanvasFixture(workspace: workspace, session: session)
        let second = CanvasFixture(workspace: workspace, session: session)
        defer {
            first.close()
            second.close()
        }
        try await first.ready()
        try await second.ready()
        first.view.editSelection()
        let oldEditor = try #require(first.editor)
        try first.type("A draft")
        second.view.editSelection()
        #expect(first.editor == nil)
        #expect(session.board.nodes[root]?.text == "A draft")
        #expect(second.editor?.string == "A draft")
        try second.type("B committed")
        let editor = try #require(second.editor)
        _ = second.view.textView(editor, doCommandBy: #selector(NSResponder.insertNewline(_:)))
        let revision = session.revision
        _ = first.view.textView(oldEditor, doCommandBy: #selector(NSResponder.cancelOperation(_:)))
        #expect(session.board.nodes[root]?.text == "B committed")
        #expect(session.revision == revision)

        first.view.editSelection()
        try first.type("Current A draft")
        first.view.textDidEndEditing(Notification(name: NSText.didEndEditingNotification, object: oldEditor))
        _ = first.view.textView(oldEditor, doCommandBy: #selector(NSResponder.cancelOperation(_:)))
        #expect(first.editor?.string == "Current A draft")
        _ = first.view.textView(try #require(first.editor), doCommandBy: #selector(NSResponder.cancelOperation(_:)))

        second.view.editSelection()
        try second.type("Discard this draft")
        _ = second.view.textView(try #require(second.editor), doCommandBy: #selector(NSResponder.cancelOperation(_:)))
        #expect(session.board.nodes[root]?.text == "B committed")
        #expect(session.revision == revision)
    }

    @Test func staleDraftTokensCannotClearTheCurrentOwnersDraft() async throws {
        let disk = MemoryWorkspaceDisk()
        let workspace = WorkspaceStore(disk: disk)
        await workspace.loadIfNeeded()
        let board = try #require(workspace.boards.first)
        let node = board.board.roots[0].id
        let old = workspace.beginEditing(nodeID: node, boardID: board.id, commit: {})
        let current = workspace.beginEditing(nodeID: node, boardID: board.id, commit: {})
        workspace.rememberDraft("Current draft", nodeID: node, boardID: board.id, token: current)
        workspace.endEditing(nodeID: node, boardID: board.id, token: old)
        workspace.rememberDraft("Stale draft", nodeID: node, boardID: board.id, token: old)
        try await workspace.flush()
        #expect(await disk.snapshot().boards[0].nodes[node]?.text == "Current draft")
        workspace.endEditing(nodeID: node, boardID: board.id, token: current)
        try await workspace.flush()
        #expect(await disk.snapshot().boards[0].nodes[node]?.text == "Original")
    }

    @Test func documentUndoCommitsOtherWindowDraftsBeforeChangingHistory() async throws {
        let workspace = WorkspaceStore(disk: MemoryWorkspaceDisk())
        await workspace.loadIfNeeded()
        let session = try #require(workspace.boards.first)
        let root = session.board.roots[0].id
        let first = CanvasFixture(workspace: workspace, session: session)
        let second = CanvasFixture(workspace: workspace, session: session)
        defer {
            first.close()
            second.close()
        }
        try await first.ready()
        try await second.ready()
        first.view.editSelection()
        try first.type("Pending edit")
        second.view.undoCommand()
        #expect(first.editor == nil)
        #expect(session.board.nodes[root]?.text == "Original")
        second.view.redoCommand()
        #expect(session.board.nodes[root]?.text == "Pending edit")
    }

    @Test func autosaveFailureRemainsFailedUntilAWriteSucceeds() async throws {
        let disk = MemoryWorkspaceDisk()
        let workspace = WorkspaceStore(disk: disk)
        await workspace.loadIfNeeded()
        await disk.failWrites(true)
        let session = try #require(workspace.boards.first)
        let root = session.board.roots[0].id
        session.apply(session.board.replacingText(root, with: "Unsaved edit"), named: "Edit Text")
        #expect(workspace.saveState == .saving)
        for _ in 0..<150 {
            if workspace.saveState == .failed { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(workspace.saveState == .failed)
        #expect(workspace.saveStatusText == "Save Failed")
        #expect(workspace.errorMessage != nil)
        await disk.failWrites(false)
        try await workspace.flush()
        #expect(workspace.saveState == .saved)
        #expect(workspace.saveStatusText == "Saved locally")
        #expect(workspace.errorMessage == nil)
        #expect(await disk.snapshot().boards[0].nodes[root]?.text == "Unsaved edit")
    }

    @Test func multiSelectionDragMovesBothRootsAndUndoesAsOneOperation() async throws {
        var board = MindMapBoard(root: TextNode(text: "Root A"))
        let rootA = board.roots[0].id
        let second = try #require(board.inserting(text: "Root B", parent: nil, position: CGPoint(x: 0, y: 170)))
        board.apply(second.edit)
        let workspace = WorkspaceStore(disk: MemoryWorkspaceDisk(board: board))
        await workspace.loadIfNeeded()
        let session = try #require(workspace.boards.first)
        workspace.cameras[session.id] = MapCamera(translation: CGPoint(x: 100, y: 100))
        let canvas = CanvasFixture(workspace: workspace, session: session)
        defer { canvas.close() }
        try await canvas.ready()
        try canvas.click(CGPoint(x: 148, y: 118))
        try canvas.click(CGPoint(x: 148, y: 288), modifiers: .command)
        try canvas.drag(from: CGPoint(x: 148, y: 118), to: CGPoint(x: 178, y: 143))
        #expect(session.board.roots.first { $0.id == rootA }?.position == CGPoint(x: 30, y: 25))
        #expect(session.board.roots.first { $0.id == second.id }?.position == CGPoint(x: 30, y: 195))
        let selected = canvas.view.accessibilityChildren()?.compactMap { $0 as? NSAccessibilityElement }
            .filter { $0.isAccessibilitySelected() }.count
        #expect(selected == 2)
        canvas.view.undoCommand()
        #expect(session.board == board)
        #expect(!session.undoManager.canUndo)
        canvas.view.redoCommand()
        #expect(session.board.roots[1].position == CGPoint(x: 30, y: 195))
    }

    @Test func droppingABranchOnItsDescendantDoesNotDetachIt() async throws {
        var board = MindMapBoard(root: TextNode(text: "Root"))
        let root = board.roots[0].id
        let branch = try #require(board.inserting(text: "Branch", parent: root))
        board.apply(branch.edit)
        let child = try #require(board.inserting(text: "Child", parent: branch.id))
        board.apply(child.edit)
        let workspace = WorkspaceStore(disk: MemoryWorkspaceDisk(board: board))
        await workspace.loadIfNeeded()
        let session = try #require(workspace.boards.first)
        workspace.cameras[session.id] = MapCamera(translation: CGPoint(x: 100, y: 100))
        let canvas = CanvasFixture(workspace: workspace, session: session)
        defer { canvas.close() }
        try await canvas.ready()
        try canvas.drag(from: CGPoint(x: 308, y: 118), to: CGPoint(x: 468, y: 118))
        #expect(session.board == board)
        #expect(session.board.parents[branch.id] == root)
        #expect(!session.undoManager.canUndo)
    }
}
