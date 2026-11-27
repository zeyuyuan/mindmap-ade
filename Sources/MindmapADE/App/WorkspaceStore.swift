import AppKit
import Darwin
import MindMapCore
import Observation

private nonisolated let boardNodeLimitMessage =
    "A board can have up to \(MindMapBoard.maximumNodeCount.formatted()) topics."

enum AgentMapChange: String {
    case added = "Agent Added Topic"
    case edited = "Agent Edited Topic"
    case moved = "Agent Moved Topic"
    case removed = "Agent Removed Topic"
    case registeredWorktree = "Agent Registered Worktree"
    case registeredGitChanges = "Agent Registered Git Changes"

    var status: String {
        switch self {
        case .added: "Agent added a topic"
        case .edited: "Agent edited a topic"
        case .moved: "Agent moved a topic"
        case .removed: "Agent removed a topic"
        case .registeredWorktree: "Agent updated a worktree topic"
        case .registeredGitChanges: "Agent registered Git changes"
        }
    }
}

@Observable
final class BoardSession: Identifiable {
    struct AgentEditNotice {
        let change: AgentMapChange
        let undoTime: ContinuousClock.Instant
        let expiresAt: ContinuousClock.Instant
    }

    private struct HistoryEntry {
        let edit: BoardEdit
        let previous: BoardEdit
        let action: String
        let agentTopics: Set<UUID>
        let time = ContinuousClock.now

        init(edit: BoardEdit, previous: BoardEdit, action: String, agentTopics: Set<UUID> = []) {
            self.edit = edit
            self.previous = previous
            self.action = action
            self.agentTopics = agentTopics
        }

        func replay(on board: MindMapBoard) -> BoardEdit {
            var replay = edit
            // Draft updates can change fields outside the undo history.
            replay.nodes = zip(edit.nodes, previous.nodes).map { replacement, original in
                guard let target = replacement.node, let source = original.node,
                    var current = board.nodes[replacement.id]
                else { return replacement }
                if source.text != target.text { current.text = target.text }
                if source.content != target.content { current.content = target.content }
                if source.children != target.children { current.children = target.children }
                if source.isCollapsed != target.isCollapsed { current.isCollapsed = target.isCollapsed }
                return NodeReplacement(id: replacement.id, node: current)
            }
            return replay
        }
    }

    struct WorktreeGitState: Equatable {
        let showsGitChanges: Bool
        let trackedExternalDirectories: [String]
    }

    let id: UUID
    private(set) var name: String
    private(set) var revision = 0
    private(set) var layoutRevision = 0
    private(set) var nodeCount: Int
    private(set) var gitProjectLocations: [UUID: ProjectLocation] = [:]
    private(set) var gitChangesNodeIDs: Set<UUID> = []
    private(set) var worktreeGitStates: [UUID: WorktreeGitState] = [:]
    private(set) var agentEditNotice: AgentEditNotice?
    private(set) var agentEditedTopics: [UUID: ContinuousClock.Instant] = [:]
    @ObservationIgnored private(set) var board: MindMapBoard
    @ObservationIgnored private var undoStack: [HistoryEntry] = []
    @ObservationIgnored private var redoStack: [HistoryEntry] = []
    @ObservationIgnored private var agentEditExpiry: Task<Void, Never>?
    @ObservationIgnored var didChange: (() -> Void)?
    @ObservationIgnored var rejectEdit: ((MindMapBoard, BoardEdit) -> String?)?
    @ObservationIgnored var isReadOnly = false
    private(set) var editError: String?
    var canUndo: Bool {
        _ = revision
        return !undoStack.isEmpty
    }
    var canRedo: Bool {
        _ = revision
        return !redoStack.isEmpty
    }

    var lastUndoTime: ContinuousClock.Instant? {
        _ = revision
        return undoStack.last?.time
    }

    var undoTitle: String { undoStack.last.map { "Undo \($0.action)" } ?? "Undo" }
    var redoTitle: String { redoStack.last.map { "Redo \($0.action)" } ?? "Redo" }

    init(_ board: MindMapBoard) {
        self.board = board
        id = board.id
        name = board.name
        nodeCount = board.nodes.count
        for node in board.nodes.values {
            if let location = Self.gitProjectLocation(node) {
                gitProjectLocations[node.id] = location
            }
            if node.content.kind == .gitChanges {
                gitChangesNodeIDs.insert(node.id)
            }
            if let state = Self.worktreeGitState(node) {
                worktreeGitStates[node.id] = state
            }
        }
    }

    @discardableResult
    func apply(_ edit: BoardEdit?, named action: String, recordHistory: Bool = true) -> Bool {
        guard let edit, let inverse = applyChange(edit) else { return false }
        if recordHistory {
            record(HistoryEntry(edit: inverse, previous: edit, action: action))
        }
        didChange?()
        return true
    }

    func applyAgentEdit(_ edit: BoardEdit, change: AgentMapChange, highlighting topics: Set<UUID>) -> Bool {
        guard let inverse = applyChange(edit) else { return false }
        let entry = HistoryEntry(edit: inverse, previous: edit, action: change.rawValue, agentTopics: topics)
        record(entry)
        let duration = CanvasStyle.agentEditHighlightDuration + .seconds(CanvasStyle.agentEditFadeDuration)
        let deadline = entry.time.advanced(by: duration)
        for id in topics { agentEditedTopics[id] = deadline }
        agentEditNotice = AgentEditNotice(change: change, undoTime: entry.time, expiresAt: deadline)
        scheduleAgentEditExpiry()
        didChange?()
        return true
    }

    func undo() {
        guard let entry = undoStack.last else { return }
        let edit = entry.replay(on: board)
        guard let inverse = applyChange(edit) else { return }
        undoStack.removeLast()
        redoStack.append(HistoryEntry(edit: inverse, previous: edit, action: entry.action))
        for id in entry.agentTopics { clearAgentHighlight(for: id) }
        if agentEditNotice?.undoTime == entry.time { agentEditNotice = nil }
        didChange?()
    }

    func redo() {
        guard let entry = redoStack.last else { return }
        let edit = entry.replay(on: board)
        guard let inverse = applyChange(edit) else { return }
        redoStack.removeLast()
        undoStack.append(HistoryEntry(edit: inverse, previous: edit, action: entry.action))
        didChange?()
    }

    private func record(_ entry: HistoryEntry) {
        undoStack.append(entry)
        if undoStack.count > 100 { undoStack.removeFirst() }
        redoStack.removeAll()
    }

    private func applyChange(_ edit: BoardEdit) -> BoardEdit? {
        guard !isReadOnly else { return nil }
        if board.nodes.count + edit.nodes.count > MindMapBoard.maximumNodeCount {
            var existsAfterEdit: [UUID: Bool] = [:]
            for replacement in edit.nodes { existsAfterEdit[replacement.id] = replacement.node != nil }
            let count = existsAfterEdit.reduce(board.nodes.count) { count, replacement in
                count + (replacement.value ? 1 : 0) - (board.nodes[replacement.key] != nil ? 1 : 0)
            }
            guard count <= MindMapBoard.maximumNodeCount else {
                editError = boardNodeLimitMessage
                return nil
            }
        }
        editError = rejectEdit?(board, edit)
        guard editError == nil else { return nil }
        let inverse = board.apply(edit)
        // Progress, project notes, and board names do not affect the canvas geometry.
        var needsLayout = edit.roots != nil && inverse.roots != board.roots
        for (replacement, previous) in zip(edit.nodes, inverse.nodes) {
            if !needsLayout, let before = previous.node, let after = replacement.node {
                needsLayout =
                    before.children != after.children || before.isCollapsed != after.isCollapsed
                    || before.content.kind != after.content.kind || before.title != after.title
                    || before.worktreeNameSuggestion != after.worktreeNameSuggestion
            } else if previous.node == nil || replacement.node == nil {
                needsLayout = true
            }
            let location = Self.gitProjectLocation(replacement.node)
            if gitProjectLocations[replacement.id] != location {
                gitProjectLocations[replacement.id] = location
            }
            if replacement.node?.content.kind == .gitChanges {
                gitChangesNodeIDs.insert(replacement.id)
            } else {
                gitChangesNodeIDs.remove(replacement.id)
            }
            let state = Self.worktreeGitState(replacement.node)
            if worktreeGitStates[replacement.id] != state {
                worktreeGitStates[replacement.id] = state
            }
            if replacement.node == nil { clearAgentHighlight(for: replacement.id) }
        }
        name = board.name
        nodeCount = board.nodes.count
        if needsLayout { layoutRevision += 1 }
        revision += 1
        return inverse
    }

    private func clearAgentHighlight(for id: UUID) {
        if agentEditedTopics[id] != nil { agentEditedTopics.removeValue(forKey: id) }
    }

    private func scheduleAgentEditExpiry() {
        agentEditExpiry?.cancel()
        let deadline = agentEditedTopics.values.min() ?? agentEditNotice?.expiresAt
        agentEditExpiry = deadline.map { deadline in
            Task { [weak self] in
                do { try await ContinuousClock().sleep(until: deadline) } catch { return }
                guard !Task.isCancelled, let self else { return }
                let now = ContinuousClock.now
                let remaining = self.agentEditedTopics.filter { $0.value > now }
                if remaining.count != self.agentEditedTopics.count { self.agentEditedTopics = remaining }
                if let notice = self.agentEditNotice, notice.expiresAt <= now { self.agentEditNotice = nil }
                self.scheduleAgentEditExpiry()
            }
        }
    }

    private static func gitProjectLocation(_ node: MapNode?) -> ProjectLocation? {
        guard case .project(let project) = node?.content, let location = project.location,
            location.gitCommonDirectory != nil
        else { return nil }
        return location
    }

    private static func worktreeGitState(_ node: MapNode?) -> WorktreeGitState? {
        guard case .worktree(let worktree) = node?.content, worktree.location != nil else { return nil }
        return WorktreeGitState(
            showsGitChanges: worktree.showsGitChanges,
            trackedExternalDirectories: worktree.trackedExternalGitChanges.compactMap(\.directory))
    }
}

protocol WorkspacePersistence: Actor {
    nonisolated var directory: URL { get }
    func load() throws -> (WorkspaceArchive?, Bool)
    func save(_ archive: WorkspaceArchive) throws
}

actor WorkspaceDisk: WorkspacePersistence {
    nonisolated let directory: URL
    private var lockDescriptor: Int32 = -1
    private var hasWriteAccess = false

    init(directory: URL) { self.directory = directory }

    deinit {
        if lockDescriptor >= 0 { close(lockDescriptor) }
    }

    func load() throws -> (WorkspaceArchive?, Bool) {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let lockPath = directory.appendingPathComponent("workspace.lock").path
        lockDescriptor = open(lockPath, O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
        hasWriteAccess = lockDescriptor >= 0 && flock(lockDescriptor, LOCK_EX | LOCK_NB) == 0
        let url = directory.appendingPathComponent("workspace.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return (nil, hasWriteAccess) }
        let data = try Data(contentsOf: url)
        return (try JSONDecoder().decode(WorkspaceArchive.self, from: data).validated(), hasWriteAccess)
    }

    func save(_ archive: WorkspaceArchive) throws {
        guard hasWriteAccess else { throw CocoaError(.fileWriteNoPermission) }
        guard archive.boards.allSatisfy({ $0.nodes.count <= MindMapBoard.maximumNodeCount }) else {
            throw WorkspaceIssue(boardNodeLimitMessage)
        }
        let data = try JSONEncoder().encode(archive)
        try data.write(to: directory.appendingPathComponent("workspace.json"), options: .atomic)
    }
}

@Observable
final class WorkspaceStore {
    enum SaveState: Equatable {
        case loading, saved, saving, failed
    }

    private struct EditKey: Hashable {
        let boardID: UUID
        let nodeID: UUID
    }

    private struct EditingSession {
        let token: UUID
        var text: String?
        let commit: () -> Void
    }

    private struct BoardDeletion {
        let session: BoardSession
        let index: Int
        let time = ContinuousClock.now
    }

    private(set) var boards: [BoardSession] = []
    private(set) var isLoading = true
    private(set) var isReadOnly = false
    private(set) var saveState = SaveState.loading
    var saveStatusText: String {
        if isReadOnly { return "Read Only" }
        switch saveState {
        case .loading: return "Loading…"
        case .saved: return "Saved locally"
        case .saving: return "Saving…"
        case .failed: return "Save Failed"
        }
    }
    private(set) var errorMessage: String?
    private var deletedBoard: BoardDeletion?
    var lastBoardDeletionTime: ContinuousClock.Instant? { deletedBoard?.time }
    @ObservationIgnored var cameras: [UUID: MapCamera] = [:]
    @ObservationIgnored private(set) var selections: [UUID: Set<UUID>] = [:]
    @ObservationIgnored var lastSelectedBoardID: UUID?
    @ObservationIgnored private var rightPane: RightPaneState?
    @ObservationIgnored private var rightPaneWindowID: UUID?
    var dataDirectory: URL { disk.directory }
    let git = GitWorkspace()
    let agentFiles: AgentRunFiles
    let interactiveShell: String
    var agentRuns: [NodeAddress: AgentRun] = [:]
    var recoveryIssues: [NodeAddress: AgentRecoveryIssue] = [:]
    var terminals: [NodeAddress: AgentTerminal] = [:]
    var gitChangesSummaries: [GitChangesTarget: GitChangesCardSummary] = [:]
    var connectedMapRuns: Set<UUID> = []
    var operations: Set<NodeAddress> = []
    @ObservationIgnored var isQuitting = false
    @ObservationIgnored var mcpListener: MCPListener?
    @ObservationIgnored var mcpGrants: [String: MCPGrant] = [:]
    let commandCodeConnection: CommandCodeConnection
    @ObservationIgnored var formClosers: [NodeAddress: (UUID, () -> Void)] = [:]
    @ObservationIgnored private let disk: any WorkspacePersistence
    @ObservationIgnored private var loadStarted = false
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    private var editingSessions: [EditKey: EditingSession] = [:]
    @ObservationIgnored private var saveRevision = 0

    init(disk: any WorkspacePersistence, interactiveShell: String = AgentCLI.interactiveShell) {
        self.disk = disk
        self.interactiveShell = interactiveShell
        agentFiles = AgentRunFiles(workspace: disk.directory)
        commandCodeConnection = CommandCodeConnection(directory: disk.directory)
    }

    convenience init(directory: URL? = nil) {
        let args = ProcessInfo.processInfo.arguments
        let destination: URL
        if let directory {
            destination = directory
        } else if let index = args.firstIndex(of: "--data-directory"), args.indices.contains(index + 1) {
            destination = URL(fileURLWithPath: args[index + 1], isDirectory: true)
        } else {
            destination = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("MindmapADE", isDirectory: true)
        }
        self.init(disk: WorkspaceDisk(directory: destination))
    }

    func loadIfNeeded() async {
        guard !loadStarted else { return }
        loadStarted = true
        do {
            let (archive, writable) = try await disk.load()
            let value = archive ?? WorkspaceArchive(boards: [MindMapBoard()])
            var restoredRuns: [NodeAddress: AgentRun] = [:]
            for var run in value.agentRuns ?? [] {
                if run.cli == .commandCode, run.checkout != nil, run.conversationID == nil {
                    run.conversationID = await agentFiles.commandCodeSession(for: run.id)
                }
                if run.state.isActive {
                    run.state = run.state == .stopping ? .stopped : .interrupted
                    run.finishedAt = .now
                }
                restoredRuns[run.address] = run
            }
            if writable {
                let kept = restoredRuns.values.flatMap { run in [run.id, run.previousSnapshotID].compactMap { $0 } }
                await agentFiles.removeUnreferencedFiles(keeping: Set(kept))
            }
            isReadOnly = !writable
            cameras = value.cameras
            selections = value.selections ?? [:]
            lastSelectedBoardID = value.selectedBoardID
            boards = value.boards.map(makeSession)
            rightPane =
                value.rightPane
                ?? value.agentPane.map {
                    RightPaneState(address: $0.address, kind: .terminal, widthShare: $0.widthShare)
                }
            agentRuns = restoredRuns
            saveState = .saved
            if !writable { errorMessage = "This workspace is open in another app instance. Changes are disabled." }
        } catch {
            isReadOnly = true
            saveState = .failed
            errorMessage =
                "Could not open the saved workspace. The original file has been preserved. \(error.localizedDescription)"
        }
        isLoading = false
    }

    func board(_ id: UUID?) -> BoardSession? { boards.first { $0.id == id } }

    @discardableResult
    func createBoard() -> UUID? {
        guard !isReadOnly, !isLoading else { return nil }
        let session = makeSession(MindMapBoard(name: boards.isEmpty ? "Untitled" : "Untitled \(boards.count + 1)"))
        boards.append(session)
        scheduleSave()
        return session.id
    }

    func renameBoard(_ id: UUID, to name: String) {
        let text = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let session = board(id), session.name != text else { return }
        session.apply(BoardEdit(name: text), named: "Rename Board")
    }

    func deleteBoard(_ id: UUID) {
        guard !isReadOnly, let index = boards.firstIndex(where: { $0.id == id }) else { return }
        guard !hasActiveWork(in: id) else { return }
        commitEdits(in: id)
        let session = boards.remove(at: index)
        deletedBoard = BoardDeletion(session: session, index: index)
        scheduleSave()
    }

    func undoDeleteBoard() -> UUID? {
        guard let deletion = deletedBoard else { return nil }
        boards.insert(deletion.session, at: min(deletion.index, boards.count))
        deletedBoard = nil
        scheduleSave()
        return deletion.session.id
    }

    func moveBoards(from offsets: IndexSet, to destination: Int) {
        guard !isReadOnly else { return }
        let moving = offsets.sorted().map { boards[$0] }
        for index in offsets.sorted().reversed() { boards.remove(at: index) }
        let index = destination - offsets.filter { $0 < destination }.count
        boards.insert(contentsOf: moving, at: min(max(index, 0), boards.count))
        scheduleSave()
    }

    func rememberCamera(_ camera: MapCamera, for id: UUID) {
        guard cameras[id] != camera else { return }
        cameras[id] = camera
        scheduleSave()
    }

    func rememberSelection(_ selection: Set<UUID>, for id: UUID) {
        guard selections[id] != selection else { return }
        selections[id] = selection
        scheduleSave()
    }

    func canOpenGitChanges(at address: NodeAddress) -> Bool {
        board(address.boardID)?.board.nodes[address.nodeID]?.content.kind == .gitChanges
    }

    func canOpenRightPane(_ pane: RightPaneState) -> Bool {
        switch pane.kind {
        case .terminal: canOpenAgent(at: pane.address)
        case .gitChanges: canOpenGitChanges(at: pane.address)
        }
    }

    func restoreRightPane(for windowID: UUID) -> RightPaneState? {
        guard rightPaneWindowID == nil, let rightPane,
            rightPane.widthShare.isFinite, (0...1).contains(rightPane.widthShare),
            canOpenRightPane(rightPane)
        else { return nil }
        rightPaneWindowID = windowID
        return rightPane
    }

    func rememberRightPane(_ pane: RightPaneState?, from windowID: UUID) {
        guard pane != nil || rightPaneWindowID == windowID else { return }
        rightPaneWindowID = windowID
        guard rightPane != pane else { return }
        rightPane = pane
        scheduleSave()
    }

    func releaseRightPane(from windowID: UUID) {
        if rightPaneWindowID == windowID { rightPaneWindowID = nil }
    }

    func releaseAgentPane(from windowID: UUID) {
        releaseRightPane(from: windowID)
    }

    func recordGitChangesSnapshot(_ snapshot: GitChangesSnapshot, for target: GitChangesTarget) {
        let summary = GitChangesCardSummary(branchLabel: snapshot.branchLabel, cardDetail: snapshot.cardDetail)
        if gitChangesSummaries[target] != summary {
            gitChangesSummaries[target] = summary
        }
    }

    func defaultGitChangesBaseCommit(for worktreeID: UUID, in session: BoardSession) -> String? {
        guard case .worktree(let tree) = session.board.nodes[worktreeID]?.content else { return nil }
        if let creationCommit = tree.creationCommit, !creationCommit.isEmpty {
            return creationCommit
        }
        let matchingRuns = agentRuns.values.filter { run in
            guard run.address.boardID == session.id, let base = run.baseCommit, !base.isEmpty else { return false }
            return session.board.context(above: run.address.nodeID).worktreeID == worktreeID
        }
        let active = matchingRuns.filter { $0.state.isActive }
        if let earliestActive = active.min(by: { $0.startedAt < $1.startedAt }) {
            return earliestActive.baseCommit
        }
        return matchingRuns.max(by: { $0.startedAt < $1.startedAt })?.baseCommit
    }

    func gitChangesTarget(for nodeID: UUID, in board: MindMapBoard) -> GitChangesTarget? {
        guard case .gitChanges(let topic) = board.nodes[nodeID]?.content else { return nil }
        if let directory = topic.directory, !directory.isEmpty {
            let base = topic.baseCommit.flatMap { $0.isEmpty ? nil : $0 }
            return GitChangesTarget(directory: directory, baseCommit: base)
        }
        let scope = board.context(above: nodeID)
        guard scope.problem == nil, let worktree = scope.worktree else { return nil }
        let base =
            topic.baseCommit.flatMap { $0.isEmpty ? nil : $0 }
            ?? scope.worktreeID.flatMap { id -> String? in
                guard case .worktree(let tree) = board.nodes[id]?.content else { return nil }
                return tree.creationCommit
            }
        return GitChangesTarget(directory: worktree.directory, baseCommit: base)
    }

    func trackedGitChangesDirectories(under worktreeID: UUID, in board: MindMapBoard) -> Set<String> {
        guard let node = board.nodes[worktreeID], case .worktree(let tree) = node.content else { return [] }
        let ownDirectory = tree.location?.directory
        var directories = Set<String>()
        for childID in node.children {
            guard case .gitChanges(let topic) = board.nodes[childID]?.content else { continue }
            if let directory = topic.directory ?? ownDirectory, !directory.isEmpty {
                directories.insert(directory)
            }
        }
        return directories
    }

    func hasDefaultGitChanges(under worktreeID: UUID, in board: MindMapBoard) -> Bool {
        guard let node = board.nodes[worktreeID], case .worktree(let tree) = node.content else { return false }
        let ownDirectory = tree.location?.directory
        return node.children.contains { childID in
            guard case .gitChanges(let topic) = board.nodes[childID]?.content else { return false }
            return topic.directory == nil || (ownDirectory != nil && topic.directory == ownDirectory)
        }
    }

    func hasAnyGitChanges(under worktreeID: UUID, in board: MindMapBoard) -> Bool {
        guard let node = board.nodes[worktreeID], node.content.kind == .worktree else { return false }
        return node.children.contains { board.nodes[$0]?.content.kind == .gitChanges }
    }

    func hasGitChanges(for directory: String, under worktreeID: UUID, in board: MindMapBoard) -> Bool {
        guard let node = board.nodes[worktreeID], case .worktree(let tree) = node.content else { return false }
        let ownDirectory = tree.location?.directory
        return node.children.contains { childID in
            guard case .gitChanges(let topic) = board.nodes[childID]?.content else { return false }
            return (topic.directory ?? ownDirectory) == directory
        }
    }

    func gitChangesInsertIndex(under worktreeID: UUID, isOwnWorktree: Bool, in board: MindMapBoard) -> Int {
        if isOwnWorktree { return 0 }
        return board.nodes[worktreeID]?.children.prefix(while: { board.nodes[$0]?.content.kind == .gitChanges }).count
            ?? 0
    }

    /// Other configured Git projects and worktrees on this board not already tracked under the Worktree.
    func untrackedKnownGitDirectories(
        for worktreeID: UUID, in board: MindMapBoard
    ) -> [(label: String, directory: String)] {
        var seen = trackedGitChangesDirectories(under: worktreeID, in: board)
        if case .worktree(let tree) = board.nodes[worktreeID]?.content, let own = tree.location?.directory {
            seen.insert(own)
        }
        var result: [(label: String, directory: String)] = []
        for node in board.nodes.values {
            let entry: (String, String)?
            switch node.content {
            case .project(let project):
                if let location = project.location, location.gitCommonDirectory != nil {
                    entry = (node.title, location.directory)
                } else {
                    entry = nil
                }
            case .worktree(let worktree):
                if let location = worktree.location {
                    entry = ("\(location.name) (\(location.revisionLabel))", location.directory)
                } else {
                    entry = nil
                }
            case .text, .branch, .agent, .gitChanges:
                entry = nil
            }
            if let (label, directory) = entry, seen.insert(directory).inserted {
                result.append((label: label, directory: directory))
            }
        }
        return result.sorted { $0.label.localizedStandardCompare($1.label) == .orderedAscending }
    }

    func select(_ id: UUID?) {
        guard lastSelectedBoardID != id else { return }
        lastSelectedBoardID = id
        scheduleSave()
    }

    /// A node has one editing owner. Taking over commits the previous owner's native editor first.
    func beginEditing(nodeID: UUID, boardID: UUID, commit: @escaping () -> Void) -> UUID {
        let key = EditKey(boardID: boardID, nodeID: nodeID)
        editingSessions[key]?.commit()
        let token = UUID()
        editingSessions[key] = EditingSession(token: token, commit: commit)
        return token
    }

    func rememberDraft(_ text: String, nodeID: UUID, boardID: UUID, token: UUID) {
        let key = EditKey(boardID: boardID, nodeID: nodeID)
        guard !isReadOnly, var edit = editingSessions[key], edit.token == token, edit.text != text else { return }
        edit.text = text
        editingSessions[key] = edit
        scheduleSave()
    }

    func endEditing(nodeID: UUID, boardID: UUID, token: UUID) {
        let key = EditKey(boardID: boardID, nodeID: nodeID)
        guard let edit = editingSessions[key], edit.token == token else { return }
        editingSessions.removeValue(forKey: key)
        if edit.text != nil { scheduleSave() }
    }

    func isEditing(_ address: NodeAddress) -> Bool {
        formClosers[address] != nil || editingSessions[EditKey(boardID: address.boardID, nodeID: address.nodeID)] != nil
    }

    func hasUnsavedTopicEdit(in boardID: UUID) -> Bool {
        editingSessions.contains { $0.key.boardID == boardID && $0.value.text != nil }
    }

    func commitEdits(in boardID: UUID? = nil) {
        let commits = editingSessions.filter { boardID == nil || $0.key.boardID == boardID }.map { $0.value.commit }
        for commit in commits { commit() }
    }

    func revealData() { NSWorkspace.shared.open(disk.directory) }

    func flush() async throws {
        saveTask?.cancel()
        guard !isReadOnly, !isLoading else { return }
        saveRevision += 1
        saveState = .saving
        try await writeArchive(revision: saveRevision)
    }

    private func makeSession(_ board: MindMapBoard) -> BoardSession {
        let session = BoardSession(board)
        session.isReadOnly = isReadOnly
        session.didChange = { [weak self] in self?.scheduleSave() }
        session.rejectEdit = { [weak self] board, edit in self?.rejection(of: edit, on: board) }
        return session
    }

    private func archive() -> WorkspaceArchive {
        let snapshots = boards.map { session in
            let pending = editingSessions.filter { $0.key.boardID == session.id && $0.value.text != nil }
            guard !pending.isEmpty else { return session.board }
            var board = session.board
            let replacements = pending.compactMap { key, edit -> NodeReplacement? in
                guard let node = board.nodes[key.nodeID], let text = edit.text else { return nil }
                return NodeReplacement(id: key.nodeID, node: node.applyingInlineText(text))
            }
            board.apply(BoardEdit(nodes: replacements))
            return board
        }
        let runs = agentRuns.values.filter { run in
            board(run.address.boardID)?.board.nodes[run.address.nodeID]?.content.kind == .agent
        }
        let savedPane = rightPane.flatMap { canOpenRightPane($0) ? $0 : nil }
        let legacyAgentPane = savedPane.flatMap {
            $0.kind == .terminal ? AgentPaneState(address: $0.address, widthShare: $0.widthShare) : nil
        }
        return WorkspaceArchive(
            boards: snapshots, cameras: cameras, selectedBoardID: lastSelectedBoardID, agentRuns: Array(runs),
            selections: selections.filter { board($0.key) != nil },
            agentPane: legacyAgentPane, rightPane: savedPane)
    }

    func scheduleSave() {
        guard !isReadOnly, !isLoading else { return }
        saveState = .saving
        saveRevision += 1
        let revision = saveRevision
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
            guard let self, !Task.isCancelled, self.saveRevision == revision else { return }
            try? await self.writeArchive(revision: revision)
        }
    }

    private func writeArchive(revision: Int) async throws {
        do {
            try await disk.save(archive())
            if revision == saveRevision {
                errorMessage = nil
                saveState = .saved
            }
        } catch {
            if revision == saveRevision {
                errorMessage = "Changes could not be saved: \(error.localizedDescription)"
                saveState = .failed
            }
            throw error
        }
    }
}

extension MapNode {
    nonisolated var worktreeCreationDraft: WorktreeTopic? {
        guard case .worktree(let draft) = content, draft.location == nil, draft.choice.mode != .existing else {
            return nil
        }
        return draft
    }

    nonisolated var worktreeNameSuggestion: String? {
        guard let draft = worktreeCreationDraft else { return nil }
        return draft.choice.pendingPlan?.branch
            ?? GitWorkspace.names(for: WorktreeChoice(), id: id, title: GitWorkspace.nameSeed(for: self)).branch
    }

    func applyingInlineText(_ text: String) -> MapNode {
        var node = self
        if content.kind == .text {
            node.text = text
        } else if var draft = worktreeCreationDraft, draft.choice.branch != text {
            draft.choice.branch = text
            if draft.choice.pendingPlan?.branch != text.trimmingCharacters(in: .whitespacesAndNewlines) {
                draft.choice.pendingPlan = nil
            }
            node.content = .worktree(draft)
        }
        return node
    }
}
