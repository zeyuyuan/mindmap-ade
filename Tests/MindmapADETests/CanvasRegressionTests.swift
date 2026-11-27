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

    init(
        workspace: WorkspaceStore, session: BoardSession,
        size: CGSize = CGSize(width: 1000, height: 640)
    ) {
        _ = NSApplication.shared
        view = MindMapCanvasView(session: session, workspace: workspace, actions: actions)
        window = NSWindow(
            contentRect: CGRect(origin: .zero, size: size),
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

    func waitForSelectedTopic(_ title: String) async throws {
        for _ in 0..<100 {
            let topics = view.accessibilityChildren()?.compactMap { $0 as? TopicAccessibilityElement } ?? []
            if topics.contains(where: { $0.accessibilityLabel() == title && $0.isAccessibilitySelected() }) { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("The canvas did not reveal \(title).")
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

    func waitForDraftLayout() async throws {
        let editor = try #require(editor)
        let backdrop = try #require(editor.enclosingScrollView?.superview)
        let font = try #require(editor.font)
        let size = TextLayoutService.topicSize(
            for: NSAttributedString(string: editor.string, attributes: [.font: font]))
        for _ in 0..<100 {
            if backdrop.alphaValue == 1, backdrop.bounds.size == size { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("The tree did not allocate the draft's dimensions.")
    }

    func close() {
        view.prepareForRemoval()
        window.close()
    }

    func event(
        _ kind: NSEvent.EventType, at point: CGPoint, modifiers: NSEvent.ModifierFlags = [], clickCount: Int = 1
    ) throws -> NSEvent {
        try #require(
            NSEvent.mouseEvent(
                with: kind, location: view.convert(point, to: nil),
                modifierFlags: modifiers, timestamp: 0, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: clickCount, pressure: 1))
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
    @Test(arguments: [0.75, 1.04, 1.5])
    func textEditorMatchesTheCanvasFontAndPositionAtDifferentZooms(zoom: Double) async throws {
        let root = MapNode(text: "Hello World")
        let workspace = WorkspaceStore(disk: MemoryWorkspaceDisk(board: MindMapBoard(root: root)))
        await workspace.loadIfNeeded()
        let session = try #require(workspace.boards.first)
        workspace.cameras[session.id] = MapCamera(scale: zoom, translation: CGPoint(x: 200, y: 200))
        let canvas = CanvasFixture(workspace: workspace, session: session)
        defer { canvas.close() }
        try await canvas.ready()
        let topic = try #require(
            canvas.view.accessibilityChildren()?.compactMap { $0 as? TopicAccessibilityElement }.first)
        let frame = canvas.view.convert(canvas.window.convertFromScreen(topic.accessibilityFrame()), from: nil)

        canvas.view.editSelection()
        let editor = try #require(canvas.editor as? TopicTextView)
        let backdrop = try #require(editor.enclosingScrollView?.superview)
        #expect(editor.font == CanvasStyle.font(root: true))
        #expect(abs(backdrop.frame.width - frame.width) < 0.01)
        #expect(abs(backdrop.frame.height - frame.height) < 0.01)
        #expect(abs(backdrop.bounds.width * zoom - frame.width) < 0.01)
        let line = editor.measureContent()
        let lineCenter = canvas.view.convert(
            CGPoint(x: 0, y: editor.textContainerOrigin.y + line.height / 2), from: editor)
        #expect(line.lineCount == 1)
        #expect(abs(lineCenter.y - frame.midY) < 0.01)
    }

    @Test(arguments: [true, false])
    func newTopicKeepsTheSameCaretBaselineFromEmptyToFirstCharacters(asChild: Bool) async throws {
        let workspace = WorkspaceStore(disk: MemoryWorkspaceDisk())
        await workspace.loadIfNeeded()
        let session = try #require(workspace.boards.first)
        let canvas = CanvasFixture(workspace: workspace, session: session)
        defer { canvas.close() }
        try await canvas.ready()
        canvas.view.insertNode(asChild: asChild)
        let editor = try #require(canvas.editor as? TopicTextView)
        let backdrop = try #require(editor.enclosingScrollView?.superview)
        #expect(editor.string.isEmpty)
        let origin = editor.textContainerOrigin.y
        #expect(origin == (backdrop.bounds.height - editor.measureContent().height) / 2)

        for text in [" ", ".", ".a", ".ab", ".abc", "中文", ""] {
            try canvas.type(text)
            #expect(editor.measureContent().lineCount == 1)
            #expect(editor.textContainerOrigin.y == origin)
        }
    }

    @Test(
        arguments: [
            "短一点\nSecond line",
            "短一点\nSecond line\n",
            "中英文混排，这段文字应该自动换行。The line break should stay put after finishing the edit.",
            String(repeating: "Long text\n", count: 20),
        ])
    func multilineTopicKeepsItsDraftHeightAfterCommit(text: String) async throws {
        let root = MapNode(text: "First line\nSecond line\nThird line\nFourth line")
        let workspace = WorkspaceStore(disk: MemoryWorkspaceDisk(board: MindMapBoard(root: root)))
        await workspace.loadIfNeeded()
        let session = try #require(workspace.boards.first)
        let canvas = CanvasFixture(workspace: workspace, session: session)
        defer { canvas.close() }
        try await canvas.ready()
        let topic = try #require(
            canvas.view.accessibilityChildren()?.compactMap { $0 as? TopicAccessibilityElement }.first)
        let originalHeight = topic.accessibilityFrame().height
        canvas.view.editSelection()
        let editor = try #require(canvas.editor as? TopicTextView)
        let scroll = try #require(editor.enclosingScrollView)
        let backdrop = try #require(scroll.superview)

        try canvas.type(text)
        try await canvas.waitForDraftLayout()
        let draftFrame = backdrop.frame
        let content = editor.measureContent()
        let fullHeight = content.height + MapMetrics.verticalPadding * 2
        let maxHeight = MapMetrics.maximumTextHeight + MapMetrics.verticalPadding * 2
        #expect(abs(draftFrame.height - min(fullHeight, maxHeight)) < 0.01)
        #expect(editor.textContainerOrigin.y == MapMetrics.verticalPadding)
        #expect(scroll.hasVerticalScroller == (fullHeight > maxHeight))
        if text == "短一点\nSecond line" {
            #expect(draftFrame.height < originalHeight)
        }
        #expect(canvas.view.textView(editor, doCommandBy: #selector(NSResponder.insertNewline(_:))))
        try await canvas.waitForSelectedTopic(text)
        #expect(abs(topic.accessibilityFrame().height - draftFrame.height) < 0.01)
        #expect(session.board.nodes[root.id]?.text == text)
    }

    @Test func committingAMultilineChildNearTheViewportEdgeKeepsTheCanvasAndTopicInPlace() async throws {
        let root = MapNode(text: "Fixed root")
        var board = MindMapBoard(root: root)
        let parent = try #require(board.inserting(text: "Parent", parent: root.id))
        board.apply(parent.edit)
        let child = try #require(board.inserting(text: "Editable child", parent: parent.id))
        board.apply(child.edit)
        board.apply(try #require(board.inserting(text: "Sibling", parent: parent.id)).edit)
        let workspace = WorkspaceStore(disk: MemoryWorkspaceDisk(board: board))
        await workspace.loadIfNeeded()
        let session = try #require(workspace.boards.first)
        workspace.cameras[session.id] = MapCamera(translation: CGPoint(x: 100, y: 112))
        workspace.rememberSelection([child.id], for: session.id)
        let canvas = CanvasFixture(workspace: workspace, session: session)
        defer { canvas.close() }
        try await canvas.ready()
        let topics = try #require(canvas.view.accessibilityChildren()).compactMap { $0 as? TopicAccessibilityElement }
        let fixedRoot = try #require(topics.first { $0.accessibilityLabel() == root.title })
        let editable = try #require(topics.first { $0.accessibilityLabel() == "Editable child" })
        let sibling = try #require(topics.first { $0.accessibilityLabel() == "Sibling" })
        canvas.view.editSelection()
        let editor = try #require(canvas.editor)
        let backdrop = try #require(editor.enclosingScrollView?.superview)

        let text = "第一行\nSecond line\n第三行\nFourth line\n第五行\n"
        try canvas.type(text)
        try await canvas.waitForDraftLayout()
        let draftFrame = backdrop.frame
        let before = fixedRoot.accessibilityFrame()
        let siblingBefore = sibling.accessibilityFrame()
        let point = CGPoint(x: 8, y: 8)
        canvas.view.mouseDown(with: try canvas.event(.leftMouseDown, at: point))
        try await canvas.waitForSelectedTopic(text)

        #expect(fixedRoot.accessibilityFrame() == before)
        #expect(sibling.accessibilityFrame() == siblingBefore)
        let savedFrame = canvas.view.convert(canvas.window.convertFromScreen(editable.accessibilityFrame()), from: nil)
        #expect(savedFrame == draftFrame)
        canvas.view.mouseUp(with: try canvas.event(.leftMouseUp, at: point))
    }

    @Test func resizingAnInlineEditorReflowsItsTreeBeforeGrowing() async throws {
        let root = MapNode(text: "Root")
        var board = MindMapBoard(root: root)
        board.apply(try #require(board.inserting(text: "Above", parent: root.id)).edit)
        let middle = try #require(board.inserting(text: "Edit me", parent: root.id))
        board.apply(middle.edit)
        board.apply(try #require(board.inserting(text: "Below", parent: root.id)).edit)
        board.apply(try #require(board.inserting(text: "Descendant", parent: middle.id)).edit)
        let workspace = WorkspaceStore(disk: MemoryWorkspaceDisk(board: board))
        await workspace.loadIfNeeded()
        let session = try #require(workspace.boards.first)
        workspace.cameras[session.id] = MapCamera(translation: CGPoint(x: 100, y: 240))
        workspace.rememberSelection([middle.id], for: session.id)
        let canvas = CanvasFixture(workspace: workspace, session: session)
        defer { canvas.close() }
        try await canvas.ready()
        let topics = try #require(canvas.view.accessibilityChildren()).compactMap { $0 as? TopicAccessibilityElement }
        let editedTopic = try #require(topics.first { $0.accessibilityLabel() == "Edit me" })
        let neighbors = topics.filter { ["Above", "Below", "Descendant"].contains($0.accessibilityLabel() ?? "") }
        try #require(neighbors.count == 3)
        let original = neighbors.map { $0.accessibilityFrame() }
        canvas.view.editSelection()
        let editor = try #require(canvas.editor)
        let backdrop = try #require(editor.enclosingScrollView?.superview)
        let editorScreenFrame = {
            canvas.window.convertToScreen(canvas.view.convert(backdrop.frame, to: nil))
        }

        try canvas.type("First draft\nAnother line\nOne more line")
        try canvas.type(String(repeating: "A long replacement line that wraps.\n", count: 14))
        #expect(editorScreenFrame() == editedTopic.accessibilityFrame())
        #expect(original.allSatisfy { !$0.intersects(editorScreenFrame()) })

        try await canvas.waitForDraftLayout()
        #expect(editorScreenFrame() == editedTopic.accessibilityFrame())
        let during = neighbors.map { $0.accessibilityFrame() }
        #expect(zip(original, during).allSatisfy { $0 != $1 })
        #expect(during.allSatisfy { !$0.intersects(editorScreenFrame()) })
        #expect(session.board.nodes[middle.id]?.text == "Edit me")

        #expect(canvas.view.textView(editor, doCommandBy: #selector(NSResponder.cancelOperation(_:))))
        #expect(neighbors.map { $0.accessibilityFrame() } == original)
    }

    @Test func cappedTextFitsBesideAnAlwaysVisibleScrollbar() async throws {
        let workspace = WorkspaceStore(disk: MemoryWorkspaceDisk())
        await workspace.loadIfNeeded()
        let session = try #require(workspace.boards.first)
        let canvas = CanvasFixture(workspace: workspace, session: session)
        defer { canvas.close() }
        try await canvas.ready()
        canvas.view.editSelection()
        let editor = try #require(canvas.editor)
        let scroll = try #require(editor.enclosingScrollView)
        scroll.scrollerStyle = .legacy
        let line = "iiiiiiiiiiiiiiiiiiiiiiiMMMMMMMMMMMMM"
        try canvas.type(String(repeating: line + "\n", count: 20))
        try await canvas.waitForDraftLayout()
        let textWidth = try #require(editor.textContainer?.size.width)

        #expect(scroll.hasVerticalScroller)
        #expect(scroll.contentSize.width >= editor.textContainerInset.width + textWidth)
        let caret = NSRange(location: line.utf16.count, length: 0)
        editor.setSelectedRange(caret)
        editor.scrollRangeToVisible(caret)
        #expect(scroll.contentView.bounds.minX == 0)
    }

    @Test func fractionalZoomDoesNotMoveAWordToTheNextLine() async throws {
        let workspace = WorkspaceStore(disk: MemoryWorkspaceDisk())
        await workspace.loadIfNeeded()
        let session = try #require(workspace.boards.first)
        workspace.cameras[session.id] = MapCamera(scale: 1.04, translation: CGPoint(x: 100.25, y: 90))
        let canvas = CanvasFixture(workspace: workspace, session: session)
        defer { canvas.close() }
        try await canvas.ready()
        canvas.view.editSelection()
        let editor = try #require(canvas.editor)
        let manager = try #require(editor.textLayoutManager)
        try canvas.type("中英文混排，这段文字需要自动换行。The same wrapping should appear after the node is saved.")

        var lines: [String] = []
        manager.enumerateTextLayoutFragments(from: nil, options: [.ensuresLayout]) { fragment in
            for line in fragment.textLineFragments {
                lines.append(line.attributedString.attributedSubstring(from: line.characterRange).string)
            }
            return true
        }
        #expect(lines == ["中英文混排，这段文字需要自动换行。", "The same wrapping should appear ", "after the node is saved."])
    }

    @Test func clickingAwayKeepsTheEditedTextVisibleUntilItsNewLayoutIsReady() async throws {
        let root = MapNode(text: "待办")
        let workspace = WorkspaceStore(disk: MemoryWorkspaceDisk(board: MindMapBoard(root: root)))
        await workspace.loadIfNeeded()
        let session = try #require(workspace.boards.first)
        let canvas = CanvasFixture(workspace: workspace, session: session)
        defer { canvas.close() }
        try await canvas.ready()

        canvas.view.editSelection()
        let editor = try #require(canvas.editor)
        let backdrop = try #require(editor.enclosingScrollView?.superview)
        let text = "整理节点编辑后的排版问题"
        try canvas.type(text)
        let frame = backdrop.frame
        let point = CGPoint(x: 8, y: 8)
        canvas.view.mouseDown(with: try canvas.event(.leftMouseDown, at: point))

        #expect(session.board.nodes[root.id]?.text == text)
        #expect(canvas.editor == nil)
        #expect(canvas.window.firstResponder === canvas.view)
        #expect(backdrop.window === canvas.window)
        #expect(backdrop.frame == frame)
        #expect(canvas.view.hitTest(CGPoint(x: frame.midX, y: frame.midY)) === canvas.view)

        try await canvas.waitForSelectedTopic(text)
        #expect(backdrop.window == nil)
        canvas.view.mouseUp(with: try canvas.event(.leftMouseUp, at: point))
    }

    @Test func committingThePlaceholderTextDoesNotLeaveAnEditorOverTheTopic() async throws {
        let root = MapNode()
        let workspace = WorkspaceStore(disk: MemoryWorkspaceDisk(board: MindMapBoard(root: root)))
        await workspace.loadIfNeeded()
        let session = try #require(workspace.boards.first)
        let canvas = CanvasFixture(workspace: workspace, session: session)
        defer { canvas.close() }
        try await canvas.ready()

        canvas.view.editSelection()
        let editor = try #require(canvas.editor)
        let backdrop = try #require(editor.enclosingScrollView?.superview)
        try canvas.type(root.title)
        #expect(canvas.view.textView(editor, doCommandBy: #selector(NSResponder.insertNewline(_:))))
        #expect(session.board.nodes[root.id]?.text == root.title)
        #expect(backdrop.window == nil)
    }

    @Test func agentRenameKeepsThePreviousTitleAndFrameTogetherUntilRelayout() async throws {
        let root = MapNode(text: "Old")
        let workspace = WorkspaceStore(disk: MemoryWorkspaceDisk(board: MindMapBoard(root: root)))
        await workspace.loadIfNeeded()
        let session = try #require(workspace.boards.first)
        let canvas = CanvasFixture(workspace: workspace, session: session)
        defer { canvas.close() }
        try await canvas.ready()
        let topic = try #require(
            canvas.view.accessibilityChildren()?.compactMap { $0 as? TopicAccessibilityElement }.first)
        let oldFrame = topic.accessibilityFrame()
        let title = "A substantially wider topic title"
        let edit = try #require(session.board.replacingText(root.id, with: title))

        #expect(session.applyAgentEdit(edit, change: .edited, highlighting: [root.id]))
        canvas.view.update(session: session, revision: session.revision)
        canvas.view.layout()
        #expect(topic.accessibilityLabel() == root.title)
        #expect(topic.accessibilityFrame() == oldFrame)

        try await canvas.waitForSelectedTopic(title)
        #expect(topic.accessibilityFrame().width > oldFrame.width)
    }

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

    @Test func undoAndRedoPreserveDraftsDuringStructuralEdits() async throws {
        let root = MapNode(content: .project(ProjectTopic()))
        let board = MindMapBoard(root: root)
        let disk = MemoryWorkspaceDisk(board: board)
        let workspace = WorkspaceStore(disk: disk)
        await workspace.loadIfNeeded()
        let session = try #require(workspace.boards.first)
        let address = NodeAddress(boardID: board.id, nodeID: root.id)
        let insertion = try #require(session.board.inserting(text: "Child", parent: root.id))
        #expect(session.apply(insertion.edit, named: "Add Child"))

        var draft = ProjectTopic()
        draft.name = "Before Undo"
        workspace.updateDraft(at: address, content: .project(draft))
        session.undo()
        #expect(session.board.nodes[root.id]?.content == .project(draft))
        #expect(session.board.nodes[root.id]?.children.isEmpty == true)

        draft.name = "Before Redo"
        workspace.updateDraft(at: address, content: .project(draft))
        session.redo()
        #expect(session.board.nodes[root.id]?.content == .project(draft))
        #expect(session.board.nodes[root.id]?.children == [insertion.id])
        try await workspace.flush()
        #expect(await disk.snapshot().boards[0] == session.board)
    }

    @Test func topicLimitAllowsEditsAndProtectsTheSavedArchive() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MindmapADE-limit-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let disk = WorkspaceDisk(directory: directory)
        _ = try await disk.load()
        var board = MindMapBoard()
        var root = try #require(board.nodes[board.roots[0].id])
        let children = (1..<MindMapBoard.maximumNodeCount).map { _ in MapNode() }
        root.children = children.map(\.id)
        let replacements = children.map { NodeReplacement(id: $0.id, node: $0) }
        board.apply(BoardEdit(nodes: replacements + [NodeReplacement(id: root.id, node: root)]))
        let session = BoardSession(board)
        let extra = try #require(board.inserting(text: "Extra", parent: root.id))
        #expect(!session.apply(extra.edit, named: "Add Child"))
        #expect(session.editError != nil)
        #expect(session.board.nodes.count == MindMapBoard.maximumNodeCount)
        #expect(session.apply(board.replacingText(root.id, with: "Edited at the limit"), named: "Edit Text"))
        #expect(session.editError == nil)

        let saved = WorkspaceArchive(boards: [session.board])
        try await disk.save(saved)
        board.apply(extra.edit)
        await #expect(throws: WorkspaceIssue.self) { try await disk.save(WorkspaceArchive(boards: [board])) }
        let reopened = WorkspaceDisk(directory: directory)
        let (archive, _) = try await reopened.load()
        #expect(archive?.boards.first == saved.boards.first)
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

    @Test func agentSelectionAndExplicitTerminalOpeningAreSeparate() async throws {
        let root = MapNode(text: "Tasks")
        let first = MapNode(content: .agent(AgentTopic(task: "First session")))
        let second = MapNode(content: .agent(AgentTopic(task: "Second session")))
        let draft = MapNode(content: .agent(AgentTopic(task: "Draft")))
        var board = MindMapBoard(root: root)
        for node in [first, second, draft] {
            board.apply(try #require(board.inserting(node, parent: root.id)).edit)
        }
        let workspace = WorkspaceStore(disk: MemoryWorkspaceDisk(board: board))
        await workspace.loadIfNeeded()
        let session = try #require(workspace.boards.first)
        let firstAddress = NodeAddress(boardID: session.id, nodeID: first.id)
        let secondAddress = NodeAddress(boardID: session.id, nodeID: second.id)
        workspace.terminals[firstAddress] = AgentTerminal()
        workspace.terminals[secondAddress] = AgentTerminal()
        let canvas = CanvasFixture(workspace: workspace, session: session)
        defer { canvas.close() }
        canvas.actions.workspace = workspace
        try await canvas.ready()
        canvas.view.fitContent()

        func center(of node: MapNode) throws -> CGPoint {
            let element = try #require(
                canvas.view.accessibilityChildren()?.compactMap { $0 as? TopicAccessibilityElement }
                    .first { $0.accessibilityLabel() == node.title })
            let frame = canvas.view.convert(canvas.window.convertFromScreen(element.accessibilityFrame()), from: nil)
            return CGPoint(x: frame.midX, y: frame.midY)
        }

        let firstPoint = try center(of: first)
        canvas.view.mouseDown(with: try canvas.event(.leftMouseDown, at: firstPoint))
        #expect(canvas.actions.terminalAddress == nil)
        canvas.view.mouseUp(with: try canvas.event(.leftMouseUp, at: firstPoint))
        #expect(canvas.actions.terminalAddress == nil)
        #expect(canvas.view.selected == [first.id])
        #expect(workspace.terminals[firstAddress]?.owner == nil)
        #expect(canvas.window.firstResponder === canvas.view)

        canvas.view.mouseDown(with: try canvas.event(.leftMouseDown, at: firstPoint, clickCount: 2))
        canvas.view.mouseUp(with: try canvas.event(.leftMouseUp, at: firstPoint, clickCount: 2))
        #expect(canvas.actions.terminalAddress == firstAddress)
        #expect(workspace.terminals[firstAddress]?.owner == canvas.actions.windowID)
        #expect(canvas.window.firstResponder === canvas.view)
        #expect(session.board == board)

        let secondPoint = try center(of: second)
        try canvas.click(secondPoint, modifiers: .command)
        #expect(canvas.view.selected == [first.id, second.id])
        #expect(canvas.actions.terminalAddress == firstAddress)
        try canvas.click(secondPoint)
        #expect(canvas.view.selected == [second.id])
        #expect(canvas.actions.terminalAddress == firstAddress)
        #expect(workspace.terminals[firstAddress]?.owner == canvas.actions.windowID)
        #expect(workspace.terminals[secondAddress]?.owner == nil)

        let menu = try #require(canvas.view.menu(for: try canvas.event(.rightMouseDown, at: secondPoint)))
        let openIndex = try #require(menu.items.firstIndex(where: { $0.title == "Open Terminal" }))
        #expect(canvas.actions.terminalAddress == firstAddress)
        menu.performActionForItem(at: openIndex)
        #expect(canvas.actions.terminalAddress == secondAddress)

        canvas.actions.hideTerminal()
        let f2 = try #require(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: canvas.window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "",
                isARepeat: false, keyCode: 120))
        canvas.view.keyDown(with: f2)
        #expect(canvas.actions.terminalAddress == secondAddress)

        try canvas.click(try center(of: root))
        #expect(canvas.actions.terminalAddress == secondAddress)
        try canvas.click(secondPoint)
        #expect(canvas.actions.terminalAddress == secondAddress)
        #expect(canvas.window.firstResponder === canvas.view)
        _ = canvas.view.menu(for: try canvas.event(.rightMouseDown, at: try center(of: first)))
        try canvas.click(try center(of: draft))
        let blank = CGPoint(x: 8, y: 8)
        try canvas.click(blank)
        #expect(canvas.actions.terminalAddress == secondAddress)

        let dragStart = try center(of: first)
        canvas.view.mouseDown(with: try canvas.event(.leftMouseDown, at: dragStart))
        let dragged = CGPoint(x: dragStart.x + 8, y: dragStart.y)
        canvas.view.mouseDragged(with: try canvas.event(.leftMouseDragged, at: dragged))
        canvas.view.mouseUp(with: try canvas.event(.leftMouseUp, at: dragStart))
        #expect(canvas.actions.terminalAddress == secondAddress)
    }

    @Test func releasingTheMouseDoesNotReselectADeletedTopic() async throws {
        let root = MapNode(text: "Root A")
        var board = MindMapBoard(root: root)
        let second = try #require(board.inserting(text: "Root B", parent: nil, position: CGPoint(x: 0, y: 170)))
        board.apply(second.edit)
        let workspace = WorkspaceStore(disk: MemoryWorkspaceDisk(board: board))
        await workspace.loadIfNeeded()
        let session = try #require(workspace.boards.first)
        workspace.cameras[session.id] = MapCamera(translation: CGPoint(x: 100, y: 100))
        let canvas = CanvasFixture(workspace: workspace, session: session)
        defer { canvas.close() }
        try await canvas.ready()

        let point = CGPoint(x: 148, y: 288)
        canvas.view.mouseDown(with: try canvas.event(.leftMouseDown, at: point))
        #expect(canvas.view.selected == [second.id])
        let edit = try #require(session.board.deleting([second.id]))
        #expect(session.applyAgentEdit(edit, change: .removed, highlighting: []))
        canvas.view.mouseUp(with: try canvas.event(.leftMouseUp, at: point))
        #expect(!canvas.view.selected.contains(second.id))
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
        canvas.view.insertNode(asChild: true)
        canvas.view.editSelection()
        #expect(canvas.editor == nil)
        #expect(session.board == board)
        try canvas.drag(from: CGPoint(x: 20, y: 20), to: CGPoint(x: 65, y: 37))
        #expect(canvas.view.selected == [rootA, second.id])
        #expect(session.board == board)
        try canvas.drag(from: CGPoint(x: 193, y: 135), to: CGPoint(x: 223, y: 160))
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

    @Test func agentReadsLiveCanvasSelectionFromItsOwnWindow() async throws {
        let root = MapNode(text: "First topic")
        let longText = String(repeating: "e\u{301} 中文 👩🏽‍💻\n", count: 700)
        let second = MapNode(text: longText)
        let agent = MapNode(content: .agent(AgentTopic(task: "Read the canvas")))
        var board = MindMapBoard(root: root)
        board.apply(try #require(board.inserting(second, parent: nil, position: CGPoint(x: 0, y: 84))).edit)
        board.apply(try #require(board.inserting(agent, parent: nil, position: CGPoint(x: 380, y: 0))).edit)
        for index in 1...51 {
            let position = CGPoint(x: 500, y: index * 64)
            board.apply(try #require(board.inserting(text: "Topic \(index)", parent: nil, position: position)).edit)
        }
        let workspace = WorkspaceStore(disk: MemoryWorkspaceDisk(board: board))
        await workspace.loadIfNeeded()
        let session = try #require(workspace.boards.first)
        workspace.cameras[session.id] = MapCamera(translation: CGPoint(x: 100, y: 100))
        let canvas = CanvasFixture(workspace: workspace, session: session)
        defer { canvas.close() }
        try await canvas.ready()
        let otherWindow = CanvasFixture(workspace: workspace, session: session)
        defer { otherWindow.close() }
        try await otherWindow.ready()

        let address = NodeAddress(boardID: session.id, nodeID: agent.id)
        let terminal = AgentTerminal()
        defer { terminal.park() }
        let checkout = WorktreeLocation(
            directory: "/checkout", gitCommonDirectory: "/project/.git", branch: "test", commit: "sha",
            isPrimary: false)
        var run = AgentRun(address: address, worktree: checkout, cli: .commandCode, executable: "/usr/bin/true")
        run.state = .running
        workspace.agentRuns[address] = run
        workspace.terminals[address] = terminal
        let token = UUID().uuidString
        workspace.mcpGrants[token] = MCPGrant(run: run)
        canvas.actions.workspace = workspace
        canvas.actions.targetBoardID = session.id
        canvas.actions.showTerminal(at: address, revealNode: false)
        terminal.attach(to: canvas.view, editor: canvas.actions)

        func call(_ name: String, arguments: [String: Any] = [:]) async throws -> [String: Any] {
            let message = try JSONSerialization.data(withJSONObject: [
                "jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": ["name": name, "arguments": arguments],
            ])
            let envelope = try JSONEncoder().encode(MCPEnvelope(token: token, message: message))
            let reply = try #require(await workspace.handleMCP(envelope))
            let body = try #require(JSONSerialization.jsonObject(with: reply) as? [String: Any])
            return try #require(body["result"] as? [String: Any])
        }

        func selection(_ arguments: [String: Any] = [:]) async throws -> [String: Any] {
            let result = try await call("get_selection", arguments: arguments)
            let content = try #require(result["content"] as? [[String: String]])
            let payload = try #require(content.first?["text"])
            return try #require(JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any])
        }

        func ids(_ result: [String: Any]) throws -> Set<String> {
            let nodes = try #require(result["nodes"] as? [[String: Any]])
            return Set(nodes.compactMap { $0["id"] as? String })
        }

        try canvas.click(CGPoint(x: 148, y: 118))
        try otherWindow.click(CGPoint(x: 8, y: 8))
        #expect(try ids(await selection()) == [root.id.uuidString])
        let marqueeStart = CGPoint(x: 84, y: 84)
        let marqueeEnd = CGPoint(x: 430, y: 350)
        try canvas.view.mouseDown(with: canvas.event(.leftMouseDown, at: marqueeStart, modifiers: .shift))
        try canvas.view.mouseDragged(with: canvas.event(.leftMouseDragged, at: marqueeEnd, modifiers: .shift))
        try canvas.view.mouseUp(with: canvas.event(.leftMouseUp, at: marqueeEnd, modifiers: .shift))
        #expect(try ids(await selection()) == [root.id.uuidString, second.id.uuidString])
        let first = try await selection(["nodeId": second.id.uuidString])
        #expect(first["hasMore"] as? Bool == true)
        let textCursor = try #require(first["nextCursor"] as? String)
        let rest = try await selection(["cursor": textCursor])
        #expect(rest["hasMore"] as? Bool == false)
        let text = try #require(first["text"] as? String) + (try #require(rest["text"] as? String))
        #expect(text.utf8.elementsEqual(longText.utf8))

        canvas.view.selectAll(nil)
        let firstPage = try await selection()
        let nextPage = try #require(firstPage["nextCursor"] as? String)
        let secondPage = try await selection(["cursor": nextPage])
        #expect(try ids(firstPage).count == 50)
        #expect(try ids(firstPage).isDisjoint(with: ids(secondPage)))
        #expect(try ids(firstPage).union(ids(secondPage)) == Set(board.nodes.keys.map(\.uuidString)))

        let revision = session.revision
        try canvas.click(CGPoint(x: 8, y: 8))
        #expect(session.revision == revision)
        let staleList = try await call("get_selection", arguments: ["cursor": nextPage])
        #expect(staleList["isError"] as? Bool == true)
        let noLongerSelected = try await call("get_selection", arguments: ["cursor": textCursor])
        #expect(noLongerSelected["isError"] as? Bool == true)
        try canvas.click(CGPoint(x: 148, y: 118))
        #expect(try ids(await selection()) == [root.id.uuidString])

        canvas.actions.targetBoardID = UUID()
        #expect(try ids(await selection()).isEmpty)
        canvas.actions.targetBoardID = session.id
        terminal.park()
        #expect(try ids(await selection()).isEmpty)
    }

    @Test func narrowCanvasFitsAnOrdinaryBranchWithoutHidingItsControls() async throws {
        let root = MapNode(text: "Release")
        var board = MindMapBoard(root: root)
        let child = try #require(board.inserting(text: "Checklist", parent: root.id))
        board.apply(child.edit)
        board.apply(try #require(board.inserting(text: "Owner", parent: child.id)).edit)
        let workspace = WorkspaceStore(disk: MemoryWorkspaceDisk(board: board))
        await workspace.loadIfNeeded()
        let session = try #require(workspace.boards.first)
        let canvas = CanvasFixture(workspace: workspace, session: session, size: CGSize(width: 180, height: 440))
        defer { canvas.close() }
        try await canvas.ready()

        canvas.view.fitContent()

        let camera = try #require(workspace.cameras[board.id])
        #expect(camera.scale >= CanvasStyle.textDetailScale)
        let controls = canvas.view.accessibilityChildren()?.compactMap { $0 as? TopicDisclosureAccessibilityElement }
        #expect(controls?.count == 2)
    }

    @Test func droppingNearATopicAttachesAFloatingBranch() async throws {
        var board = MindMapBoard(root: MapNode(text: "Root"))
        let parent = try #require(board.inserting(text: "Target", parent: board.roots[0].id))
        board.apply(parent.edit)
        let floating = try #require(
            board.inserting(text: "Floating", parent: nil, position: CGPoint(x: 420, y: 170)))
        board.apply(floating.edit)
        let workspace = WorkspaceStore(disk: MemoryWorkspaceDisk(board: board))
        await workspace.loadIfNeeded()
        let session = try #require(workspace.boards.first)
        workspace.cameras[session.id] = MapCamera(translation: CGPoint(x: 100, y: 100))
        let canvas = CanvasFixture(workspace: workspace, session: session)
        defer { canvas.close() }
        try await canvas.ready()

        let start = CGPoint(x: 568, y: 288)
        let outsideTarget = CGPoint(x: 374, y: 118)
        canvas.view.mouseDown(with: try canvas.event(.leftMouseDown, at: start))
        canvas.view.mouseDragged(with: try canvas.event(.leftMouseDragged, at: outsideTarget))
        #expect(canvas.actions.dropHint == "Release to attach as a child")
        #expect(session.board == board)
        canvas.view.mouseUp(with: try canvas.event(.leftMouseUp, at: outsideTarget))

        #expect(session.board.parents[floating.id] == parent.id)
        #expect(canvas.actions.dropHint == nil)
        canvas.view.undoCommand()
        #expect(session.board == board)
    }

    @Test func droppingInTheGapBetweenSiblingsInsertsAtTheLine() async throws {
        var board = MindMapBoard(root: MapNode(text: "Root"))
        let root = board.roots[0].id
        var children: [UUID] = []
        for title in ["First", "Second", "Third"] {
            let child = try #require(board.inserting(text: title, parent: root))
            board.apply(child.edit)
            children.append(child.id)
        }
        let workspace = WorkspaceStore(disk: MemoryWorkspaceDisk(board: board))
        await workspace.loadIfNeeded()
        let session = try #require(workspace.boards.first)
        workspace.cameras[session.id] = MapCamera(translation: CGPoint(x: 100, y: 100))
        let canvas = CanvasFixture(workspace: workspace, session: session)
        defer { canvas.close() }
        try await canvas.ready()

        let start = CGPoint(x: 308, y: 170)
        let gap = CGPoint(x: 308, y: 92)
        canvas.view.mouseDown(with: try canvas.event(.leftMouseDown, at: start))
        canvas.view.mouseDragged(with: try canvas.event(.leftMouseDragged, at: gap))
        #expect(canvas.actions.dropHint == "Release to insert at the line")
        canvas.view.mouseUp(with: try canvas.event(.leftMouseUp, at: gap))

        #expect(session.board.nodes[root]?.children == [children[0], children[2], children[1]])
        #expect(session.board.roots == board.roots)
    }

    @Test func releasingInOpenCanvasDetachesAtTheReleasePoint() async throws {
        var board = MindMapBoard(root: MapNode(text: "Root"))
        let root = board.roots[0].id
        let branch = try #require(board.inserting(text: "Branch", parent: root))
        board.apply(branch.edit)
        let descendant = try #require(board.inserting(text: "Descendant", parent: branch.id))
        board.apply(descendant.edit)
        let workspace = WorkspaceStore(disk: MemoryWorkspaceDisk(board: board))
        await workspace.loadIfNeeded()
        let session = try #require(workspace.boards.first)
        workspace.cameras[session.id] = MapCamera(translation: CGPoint(x: 100, y: 100))
        let canvas = CanvasFixture(workspace: workspace, session: session)
        defer { canvas.close() }
        try await canvas.ready()

        let start = CGPoint(x: 308, y: 118)
        let nearParent = CGPoint(x: 210, y: 118)
        let blank = CGPoint(x: 600, y: 300)
        canvas.view.mouseDown(with: try canvas.event(.leftMouseDown, at: start))
        canvas.view.mouseDragged(with: try canvas.event(.leftMouseDragged, at: nearParent))
        #expect(canvas.actions.dropHint == "Release to attach as a child")
        canvas.view.mouseUp(with: try canvas.event(.leftMouseUp, at: blank))

        #expect(session.board.parents[branch.id] == nil)
        #expect(session.board.parents[descendant.id] == branch.id)
        #expect(session.board.roots.last == RootPlacement(id: branch.id, position: CGPoint(x: 452, y: 182)))
        canvas.view.undoCommand()
        #expect(session.board == board)
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

    @Test func findingATopicRevealsNestedFoldsWithoutEditingTheBoard() async throws {
        var board = MindMapBoard(root: MapNode(text: "Planning"))
        let root = board.roots[0].id
        let section = try #require(board.inserting(text: "Release", parent: root))
        board.apply(section.edit)
        let topic = try #require(board.inserting(text: "发布 checklist", parent: section.id))
        board.apply(topic.edit)
        board.apply(try #require(board.togglingCollapse(section.id)))
        board.apply(try #require(board.togglingCollapse(root)))
        let workspace = WorkspaceStore(disk: MemoryWorkspaceDisk(board: board))
        await workspace.loadIfNeeded()
        let session = try #require(workspace.boards.first)
        session.isReadOnly = true
        workspace.cameras[session.id] = MapCamera(scale: 0.15, translation: CGPoint(x: 100, y: 100))
        let canvas = CanvasFixture(workspace: workspace, session: session)
        defer { canvas.close() }
        try await canvas.ready()

        let page = try await MapSearch.page(for: "CHECKLIST", in: session.board, from: .init(root: nil), pageSize: 32)
        #expect(page.matches.map(\.id) == [topic.id])
        canvas.view.jumpToTopic(topic.id)
        try await canvas.waitForSelectedTopic("发布 checklist")
        #expect(canvas.actions.zoomLabel == "100%")
        #expect(session.board == board)
        #expect(!session.canUndo)

        let firstFold = try #require(
            canvas.view.accessibilityChildren()?.compactMap { $0 as? TopicDisclosureAccessibilityElement }
                .first { $0.accessibilityLabel() == "Collapse Planning" })
        #expect(firstFold.accessibilityPerformPress())
        try await canvas.waitForSelectedTopic("Planning")
        #expect(session.board == board)
    }

    @Test func exitingBranchFocusRestoresTheOriginalCamera() async throws {
        var board = MindMapBoard(root: MapNode(text: "Planning"))
        let branch = try #require(board.inserting(text: "Release", parent: board.roots[0].id))
        board.apply(branch.edit)
        let workspace = WorkspaceStore(disk: MemoryWorkspaceDisk(board: board))
        await workspace.loadIfNeeded()
        let session = try #require(workspace.boards.first)
        let camera = MapCamera(scale: 0.5, translation: CGPoint(x: 140, y: 120))
        workspace.cameras[session.id] = camera
        let canvas = CanvasFixture(workspace: workspace, session: session)
        defer { canvas.close() }
        try await canvas.ready()
        try canvas.click(CGPoint(x: 244, y: 129))
        #expect(canvas.view.selected == [branch.id])

        canvas.view.toggleBranchFocus()
        #expect(canvas.actions.isBranchFocused)
        #expect(canvas.actions.zoomLabel != "50%")
        canvas.view.zoom(by: 1.25)
        #expect(workspace.cameras[session.id] == camera)
        canvas.view.toggleBranchFocus()
        #expect(!canvas.actions.isBranchFocused)
        #expect(canvas.actions.zoomLabel == "50%")
        #expect(workspace.cameras[session.id] == camera)
        #expect(session.board == board)
    }

    @Test func aFoldedBranchSummarizesHiddenAgentsAndCanRevealOne() async throws {
        var board = MindMapBoard(root: MapNode(text: "Planning"))
        let root = board.roots[0].id
        let branch = try #require(board.inserting(text: "Release", parent: root))
        board.apply(branch.edit)
        let active = MapNode(content: .agent(AgentTopic(task: "Build")))
        let failed = MapNode(content: .agent(AgentTopic(task: "Checks")))
        for node in [active, failed] {
            board.apply(try #require(board.inserting(node, parent: branch.id)).edit)
        }
        board.apply(try #require(board.togglingCollapse(branch.id)))
        board.apply(try #require(board.togglingCollapse(root)))
        let workspace = WorkspaceStore(disk: MemoryWorkspaceDisk(board: board))
        await workspace.loadIfNeeded()
        let session = try #require(workspace.boards.first)
        let canvas = CanvasFixture(workspace: workspace, session: session)
        defer { canvas.close() }
        try await canvas.ready()

        canvas.view.updatePresentation(
            runtimeDetails: [:], activePaneNodeID: nil, agentRunStates: [active.id: .running, failed.id: .failed])
        let badge = try #require(
            canvas.view.accessibilityChildren()?.compactMap { $0 as? TopicAgentSummaryAccessibilityElement }.first)
        #expect(badge.accessibilityLabel() == "Agents in Planning")
        #expect(badge.isAccessibilityEnabled())
        #expect(badge.accessibilityValue() as? String == "1 active · 1 failed")

        canvas.view.updatePresentation(
            runtimeDetails: [:], activePaneNodeID: nil, agentRunStates: [active.id: .exited, failed.id: .failed])
        #expect(badge.accessibilityValue() as? String == "1 failed")
        #expect(badge.accessibilityPerformPress())
        try await canvas.waitForSelectedTopic("Checks")
        #expect(session.board == board)
    }

    @Test func aStationaryDragAtTheEdgePansAndFindsAnOffscreenTarget() async throws {
        var board = MindMapBoard(root: MapNode(text: "Moving"))
        let moving = board.roots[0].id
        let target = try #require(
            board.inserting(text: "Destination", parent: nil, position: CGPoint(x: 934, y: 0)))
        board.apply(target.edit)
        let workspace = WorkspaceStore(disk: MemoryWorkspaceDisk(board: board))
        await workspace.loadIfNeeded()
        let session = try #require(workspace.boards.first)
        let camera = MapCamera(translation: CGPoint(x: 100, y: 100))
        workspace.cameras[session.id] = camera
        let canvas = CanvasFixture(workspace: workspace, session: session)
        defer { canvas.close() }
        try await canvas.ready()

        let start = CGPoint(x: 148, y: 118)
        let edge = CGPoint(x: 995, y: 118)
        canvas.view.mouseDown(with: try canvas.event(.leftMouseDown, at: start))
        canvas.view.mouseDragged(with: try canvas.event(.leftMouseDragged, at: edge))
        #expect(canvas.actions.dropHint == "Release to move")
        let deadline = ContinuousClock.now + .seconds(2)
        while canvas.actions.dropHint != "Release to attach as a child", ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(canvas.actions.dropHint == "Release to attach as a child")
        canvas.view.mouseUp(with: try canvas.event(.leftMouseUp, at: edge))
        #expect(session.board.parents[moving] == target.id)
        let after = try #require(workspace.cameras[session.id])
        #expect(after.translation.x < camera.translation.x)
        try await Task.sleep(for: .milliseconds(60))
        #expect(workspace.cameras[session.id] == after)
    }

    @Test func gitChangesSelectionAndExplicitOpeningAreSeparate() async throws {
        let fixture = try ScratchRepository()
        defer { fixture.cleanUp() }
        let checkout = fixture.home.appendingPathComponent("Feature Checkout")
        try fixture.git(["worktree", "add", "-b", "feature/git", checkout.path, "HEAD"])
        try "edit\n".write(to: checkout.appendingPathComponent("change.txt"), atomically: true, encoding: .utf8)

        let workspaceGit = GitWorkspace()
        var project = ProjectTopic()
        let projectLocation = try await workspaceGit.project(at: fixture.repository.path)
        project.location = projectLocation
        let root = MapNode(content: .project(project))
        let location = try await workspaceGit.existing(checkout.path, in: projectLocation)
        let worktree = MapNode(content: .worktree(WorktreeTopic(location: location)))
        var topic = AgentTopic(task: "Run task")
        topic.isConfigured = true
        let agent = MapNode(content: .agent(topic))
        let changes = MapNode(content: .gitChanges(GitChangesTopic(baseCommit: location.commit)))
        var board = MindMapBoard(root: root)
        board.apply(try #require(board.inserting(worktree, parent: root.id)).edit)
        board.apply(try #require(board.inserting(changes, parent: worktree.id, at: 0)).edit)
        board.apply(try #require(board.inserting(agent, parent: worktree.id)).edit)

        let disk = MemoryWorkspaceDisk(board: board, directory: fixture.data)
        let workspace = WorkspaceStore(disk: disk)
        await workspace.loadIfNeeded()
        let session = try #require(workspace.boards.first)
        let agentAddress = NodeAddress(boardID: session.id, nodeID: agent.id)
        let changesAddress = NodeAddress(boardID: session.id, nodeID: changes.id)
        let terminal = AgentTerminal()
        workspace.terminals[agentAddress] = terminal

        let canvas = CanvasFixture(workspace: workspace, session: session)
        defer { canvas.close() }
        canvas.actions.workspace = workspace
        try await canvas.ready()
        canvas.view.fitContent()

        func center(of title: String) throws -> CGPoint {
            let element = try #require(
                canvas.view.accessibilityChildren()?.compactMap { $0 as? TopicAccessibilityElement }
                    .first { $0.accessibilityLabel() == title })
            let frame = canvas.view.convert(canvas.window.convertFromScreen(element.accessibilityFrame()), from: nil)
            return CGPoint(x: frame.midX, y: frame.midY)
        }

        // Open the Agent terminal first.
        canvas.actions.showTerminal(at: agentAddress, revealNode: false)
        #expect(canvas.actions.terminalAddress == agentAddress)
        #expect(terminal.owner == canvas.actions.windowID)

        // Single-click selects Git Changes without disturbing the open Agent terminal.
        let changesPoint = try center(of: changes.title)
        try canvas.click(changesPoint)
        #expect(canvas.view.selected == [changes.id])
        #expect(canvas.actions.terminalAddress == agentAddress)
        #expect(canvas.actions.gitChangesAddress == nil)
        #expect(terminal.owner == canvas.actions.windowID)
        #expect(canvas.window.firstResponder === canvas.view)

        // Double-click opens the Git right pane and parks the terminal without closing it.
        canvas.view.mouseDown(with: try canvas.event(.leftMouseDown, at: changesPoint, clickCount: 2))
        canvas.view.mouseUp(with: try canvas.event(.leftMouseUp, at: changesPoint, clickCount: 2))
        #expect(canvas.view.selected == [changes.id])
        #expect(canvas.actions.gitChangesAddress == changesAddress)
        #expect(canvas.actions.terminalAddress == nil)
        #expect(terminal.owner == nil)
        #expect(canvas.window.firstResponder === canvas.view)

        // F2 reopens the Git Changes right pane after hiding it.
        canvas.actions.hideRightPane()
        #expect(canvas.actions.gitChangesAddress == nil)
        let f2 = try #require(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: canvas.window.windowNumber, context: nil, characters: "",
                charactersIgnoringModifiers: "", isARepeat: false, keyCode: 120))
        canvas.view.keyDown(with: f2)
        #expect(canvas.actions.gitChangesAddress == changesAddress)

        // Context menu on Git Changes offers Open Git Changes & Show in Finder, not Configure.
        canvas.actions.hideRightPane()
        let changesMenu = try #require(canvas.view.menu(for: try canvas.event(.rightMouseDown, at: changesPoint)))
        let titles = changesMenu.items.map(\.title)
        #expect(titles.contains("Open Git Changes"))
        #expect(titles.contains("Show in Finder"))
        #expect(!titles.contains(where: { $0.hasPrefix("Configure") }))
        let openIndex = try #require(titles.firstIndex(of: "Open Git Changes"))
        changesMenu.performActionForItem(at: openIndex)
        #expect(canvas.actions.gitChangesAddress == changesAddress)

        // Right pane state persists and restores cleanly.
        try await workspace.flush()
        let restored = WorkspaceStore(disk: disk)
        await restored.loadIfNeeded()
        let restoredActions = EditorActions()
        restoredActions.workspace = restored
        restoredActions.restoreRightPane()
        #expect(restoredActions.gitChangesAddress == changesAddress)

        // Deleting the Worktree's default Git Changes node disables Show Git Changes atomically (undoable).
        canvas.view.deleteSelection()
        #expect(session.board.nodes[changes.id] == nil)
        if case .worktree(let afterDelete) = session.board.nodes[worktree.id]?.content {
            #expect(!afterDelete.showsGitChanges)
        } else {
            Issue.record("Expected configured worktree after deleting Git Changes")
        }

        // Worktree context menu exposes Show Git Changes toggle (currently off) and hides Track Another Repository.
        let worktreePoint = try center(of: worktree.title)
        let worktreeMenuOff = try #require(canvas.view.menu(for: try canvas.event(.rightMouseDown, at: worktreePoint)))
        let toggleItemOff = try #require(worktreeMenuOff.items.first { $0.title == "Show Git Changes" })
        #expect(toggleItemOff.state == .off)
        #expect(!worktreeMenuOff.items.map(\.title).contains("Track Another Repository"))
        #expect(canvas.actions.canToggleWorktreeGitChanges)
        #expect(!canvas.actions.worktreeShowsGitChanges)
        #expect(!canvas.actions.canAddExternalGitChanges)

        // Agent context menu no longer carries Git Changes controls.
        let agentPoint = try center(of: agent.title)
        let agentMenu = try #require(canvas.view.menu(for: try canvas.event(.rightMouseDown, at: agentPoint)))
        #expect(!agentMenu.items.map(\.title).contains("Show Git Changes"))
        #expect(!agentMenu.items.map(\.title).contains("Track Another Repository"))

        // Toggling Show Git Changes back on from the Worktree context menu restores the single Git Changes card
        // at index 0 and exposes Track Another Repository.
        let toggleIndex = try #require(worktreeMenuOff.items.firstIndex(of: toggleItemOff))
        _ = canvas.view.menu(for: try canvas.event(.rightMouseDown, at: worktreePoint))
        worktreeMenuOff.performActionForItem(at: toggleIndex)
        let deadline = ContinuousClock.now + .seconds(5)
        while session.board.nodes[worktree.id]?.children.first == agent.id, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let recreated = try #require(session.board.nodes[worktree.id]?.children.first)
        #expect(session.board.nodes[recreated]?.content.kind == .gitChanges)
        #expect(session.board.nodes[worktree.id]?.children == [recreated, agent.id])

        let worktreeMenuOn = try #require(canvas.view.menu(for: try canvas.event(.rightMouseDown, at: worktreePoint)))
        let toggleItemOn = try #require(worktreeMenuOn.items.first { $0.title == "Show Git Changes" })
        #expect(toggleItemOn.state == .on)
        let trackMenu = try #require(worktreeMenuOn.items.first { $0.title == "Track Another Repository" }?.submenu)
        #expect(trackMenu.items.map(\.title).contains(root.title))
        #expect(trackMenu.items.map(\.title).contains("Choose Folder…"))
        #expect(canvas.actions.canToggleWorktreeGitChanges)
        #expect(canvas.actions.worktreeShowsGitChanges)
        #expect(canvas.actions.canAddExternalGitChanges)

        // Toggling Show Git Changes off again immediately removes the childless Git Changes node,
        // and Undo restores both the preference and the card.
        canvas.actions.toggleWorktreeGitChanges()
        #expect(session.board.nodes[recreated] == nil)
        #expect(session.board.nodes[worktree.id]?.children == [agent.id])
        #expect(!canvas.actions.worktreeShowsGitChanges)
        canvas.actions.undo()
        #expect(session.board.nodes[recreated]?.content.kind == .gitChanges)
        #expect(session.board.nodes[worktree.id]?.children == [recreated, agent.id])
        #expect(canvas.actions.worktreeShowsGitChanges)
    }
}
