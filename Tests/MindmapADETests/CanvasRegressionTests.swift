import AppKit
import Testing

@testable import MindMapCore
@testable import MindmapADE

actor MemoryWorkspaceDisk: WorkspacePersistence {
    nonisolated let directory: URL
    private var archive: WorkspaceArchive
    private var fails = false

    init(
        board: MindMapBoard = MindMapBoard(root: MapNode(text: "Original")),
        directory: URL = URL(fileURLWithPath: "/tmp/MindmapADE-tests-\(UUID())")
    ) {
        self.directory = directory
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

    func worktreeNameField() async throws -> NSTextField {
        for _ in 0..<100 {
            if let field = view.accessibilityChildren()?.compactMap({ $0 as? NSTextField }).first { return field }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw CocoaError(.coderReadCorrupt)
    }

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
    @Test func resourceMenusAndCommandsRespectProjectAndWorktreePlacement() async throws {
        var project = ProjectTopic()
        project.location = ProjectLocation(directory: "/project", gitCommonDirectory: "/project/.git")
        let root = MapNode(content: .project(project))
        var board = MindMapBoard(root: root)
        func insert(_ node: MapNode, under parent: UUID?, y: CGFloat = 0) throws {
            board.apply(try #require(board.inserting(node, parent: parent, position: CGPoint(x: 0, y: y))).edit)
        }

        let group = MapNode(text: "Features")
        let task = MapNode(text: "Login")
        try insert(group, under: root.id)
        try insert(task, under: group.id)
        let worktree = MapNode(content: .worktree(WorktreeTopic()))
        try insert(worktree, under: root.id)
        try insert(MapNode(text: "Inside Draft"), under: worktree.id)
        let location = WorktreeLocation(
            directory: "/checkout", gitCommonDirectory: "/project/.git", branch: "feature/test", commit: "abc",
            isPrimary: false)
        let ready = MapNode(content: .worktree(WorktreeTopic(location: location)))
        try insert(ready, under: root.id)
        try insert(MapNode(text: "Inside Worktree"), under: ready.id)
        var folder = ProjectTopic()
        folder.location = ProjectLocation(directory: "/folder")
        let nonGit = MapNode(content: .project(folder))
        try insert(nonGit, under: nil, y: 192)
        try insert(MapNode(text: "Inside Folder"), under: nonGit.id)
        try insert(MapNode(content: .project(ProjectTopic())), under: nil, y: 280)
        try insert(MapNode(text: "Loose Topic"), under: nil, y: 360)

        let disk = MemoryWorkspaceDisk(board: board)
        let workspace = WorkspaceStore(disk: disk)
        await workspace.loadIfNeeded()
        let session = try #require(workspace.boards.first)
        let canvas = CanvasFixture(workspace: workspace, session: session)
        defer { canvas.close() }
        try await canvas.ready()
        canvas.view.fitContent()

        func menuTitles(on title: String?) throws -> [String] {
            var point = CGPoint(x: 8, y: 8)
            if let title {
                let element = try #require(
                    canvas.view.accessibilityChildren()?.compactMap { $0 as? TopicAccessibilityElement }
                        .first { $0.accessibilityLabel() == title })
                let frame = canvas.view.convert(
                    canvas.window.convertFromScreen(element.accessibilityFrame()), from: nil)
                point = CGPoint(x: frame.midX, y: frame.midY)
            }
            let event = try canvas.event(.rightMouseDown, at: point)
            return canvas.view.menu(for: event)?.items.map(\.title) ?? []
        }

        let blocked: [String?] = [
            nil, "Loose Topic", "Choose a project", nonGit.title, "Inside Folder", worktree.title, "Inside Draft",
        ]
        for title in blocked {
            let menu = try menuTitles(on: title)
            let canAddProject = title == nil || title == "Loose Topic"
            #expect(menu.contains("Add Project") == canAddProject)
            #expect(canvas.actions.canAddProject == canAddProject)
            #expect(!menu.contains("Add Worktree"))
            #expect(!canvas.actions.canAddWorktree)
            #expect(!menu.contains("Link Existing Worktree…"))
            #expect(!canvas.actions.canLinkWorktree)
            if !canAddProject { canvas.actions.add(.project) }
            canvas.actions.add(.worktree)
            #expect(session.board == board)
        }
        for title in [root.title, task.title, ready.title, "Inside Worktree"] {
            let menu = try menuTitles(on: title)
            #expect(menu.contains("Add Worktree"))
            #expect(!menu.contains("Add Project"))
            #expect(canvas.actions.canAddWorktree)
            let canLink = title == root.title || title == task.title
            #expect(menu.contains("Link Existing Worktree…") == canLink)
            #expect(canvas.actions.canLinkWorktree == canLink)
            canvas.actions.add(.project)
            #expect(session.board == board)
        }
        canvas.actions.add(.worktree)
        let child = try #require(session.board.nodes[ready.id]?.children.last)
        #expect(session.board.nodes[child]?.content == .worktree(WorktreeTopic()))

        let field = try await canvas.worktreeNameField()
        let fieldEditor = try #require(field.currentEditor() as? NSTextView)
        let suggestion = try #require(field.placeholderString)
        #expect(canvas.window.firstResponder === fieldEditor)
        #expect(fieldEditor.string.isEmpty)
        #expect(suggestion.hasPrefix("mindmap/worktree-"))
        #expect(canvas.view.control(field, textView: fieldEditor, doCommandBy: #selector(NSResponder.insertTab(_:))))
        #expect(fieldEditor.string == suggestion)
        #expect(fieldEditor.selectedRange().length == suggestion.utf16.count)
        try await workspace.flush()
        #expect(await disk.snapshot().boards.first?.nodes[child]?.worktreeCreationDraft?.choice.branch == suggestion)
        #expect(
            canvas.view.control(field, textView: fieldEditor, doCommandBy: #selector(NSResponder.cancelOperation(_:))))

        _ = try menuTitles(on: task.title)
        canvas.actions.linkWorktree()
        let linked = try #require(session.board.nodes[task.id]?.children.first)
        var linkDraft = WorktreeTopic()
        linkDraft.choice.mode = .existing
        #expect(session.board.nodes[linked]?.content == .worktree(linkDraft))
    }

    @Test func clickingAwayFromAnEmptyWorktreeNameCreatesTheSuggestedCheckout() async throws {
        let fixture = try ScratchRepository()
        defer { fixture.cleanUp() }
        let workspaceGit = GitWorkspace()
        let location = try await workspaceGit.project(at: fixture.repository.path)
        var project = ProjectTopic()
        project.location = location
        let root = MapNode(content: .project(project))
        let workspace = WorkspaceStore(
            disk: MemoryWorkspaceDisk(board: MindMapBoard(root: root), directory: fixture.data))
        await workspace.loadIfNeeded()
        let session = try #require(workspace.boards.first)
        let canvas = CanvasFixture(workspace: workspace, session: session)
        defer { canvas.close() }
        try await canvas.ready()
        canvas.actions.add(.worktree)
        let draft = try #require(session.board.nodes[root.id]?.children.first)
        let field = try await canvas.worktreeNameField()
        let suggestion = try #require(field.placeholderString)
        #expect(field.stringValue.isEmpty)

        try canvas.click(CGPoint(x: 8, y: 8))

        let deadline = ContinuousClock.now + .seconds(5)
        let address = NodeAddress(boardID: session.id, nodeID: draft)
        while session.board.nodes[draft]?.worktreeCreationDraft != nil || workspace.operations.contains(address) {
            guard ContinuousClock.now < deadline else {
                Issue.record("The worktree did not finish creating after the canvas click.")
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        let checkout = try #require(session.board.context(startingAt: draft).worktree)
        #expect(checkout.branch == suggestion)
        #expect(session.board.parents[draft] == root.id)
        #expect(try await workspace.git.worktrees(for: location).contains(checkout))
        #expect(canvas.view.accessibilityChildren()?.contains { $0 is NSTextField } == false)
    }

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

    @Test func undoRestoresADeletedBoardAfterUndoingNewerMapEdits() async throws {
        let workspace = WorkspaceStore(disk: MemoryWorkspaceDisk())
        await workspace.loadIfNeeded()
        let original = try #require(workspace.boards.first)
        let id = try #require(workspace.createBoard())
        let session = try #require(workspace.board(id))
        let canvas = CanvasFixture(workspace: workspace, session: session)
        defer { canvas.close() }
        canvas.actions.workspace = workspace
        canvas.actions.targetBoardID = id

        let root = session.board.roots[0].id
        #expect(session.apply(session.board.replacingText(root, with: "Before deletion"), named: "Edit Text"))
        workspace.deleteBoard(original.id)
        #expect(canvas.actions.shouldUndoBoardDeletion)
        #expect(session.apply(session.board.replacingText(root, with: "After deletion"), named: "Edit Text"))

        canvas.actions.undo()
        #expect(session.board.nodes[root]?.text == "Before deletion")
        #expect(workspace.board(original.id) == nil)

        canvas.actions.undo()
        #expect(workspace.boards.first === original)
        #expect(canvas.actions.requestedBoardID == original.id)
        #expect(session.board.nodes[root]?.text == "Before deletion")
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
        var board = MindMapBoard(root: MapNode(text: "Root A"))
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
        #expect(!session.canUndo)
        canvas.view.redoCommand()
        #expect(session.board.roots[1].position == CGPoint(x: 30, y: 195))
    }

    @Test func droppingABranchOnItsDescendantDoesNotDetachIt() async throws {
        var board = MindMapBoard(root: MapNode(text: "Root"))
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
        #expect(!session.canUndo)
    }
}
