import AppKit
import Darwin
import MindMapCore
import Observation

@Observable
final class BoardSession: Identifiable {
    private struct HistoryEntry {
        let edit: BoardEdit
        let action: String
        let time = ContinuousClock.now
    }

    let id: UUID
    private(set) var name: String
    private(set) var revision = 0
    private(set) var nodeCount: Int
    private(set) var gitProjectLocations: [UUID: ProjectLocation] = [:]
    @ObservationIgnored private(set) var board: MindMapBoard
    @ObservationIgnored private var undoStack: [HistoryEntry] = []
    @ObservationIgnored private var redoStack: [HistoryEntry] = []
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
        }
    }

    @discardableResult
    func apply(_ edit: BoardEdit?, named action: String, recordHistory: Bool = true) -> Bool {
        guard let edit, let inverse = applyChange(edit) else { return false }
        if recordHistory {
            undoStack.append(HistoryEntry(edit: inverse, action: action))
            if undoStack.count > 100 { undoStack.removeFirst() }
            redoStack.removeAll()
        }
        didChange?()
        return true
    }

    func undo() {
        guard let entry = undoStack.last, let inverse = applyChange(entry.edit) else { return }
        undoStack.removeLast()
        redoStack.append(HistoryEntry(edit: inverse, action: entry.action))
        didChange?()
    }

    func redo() {
        guard let entry = redoStack.last, let inverse = applyChange(entry.edit) else { return }
        redoStack.removeLast()
        undoStack.append(HistoryEntry(edit: inverse, action: entry.action))
        didChange?()
    }

    private func applyChange(_ edit: BoardEdit) -> BoardEdit? {
        guard !isReadOnly else { return nil }
        editError = rejectEdit?(board, edit)
        guard editError == nil else { return nil }
        let inverse = board.apply(edit)
        for replacement in edit.nodes {
            let location = Self.gitProjectLocation(replacement.node)
            if gitProjectLocations[replacement.id] != location {
                gitProjectLocations[replacement.id] = location
            }
        }
        name = board.name
        nodeCount = board.nodes.count
        revision += 1
        return inverse
    }

    private static func gitProjectLocation(_ node: MapNode?) -> ProjectLocation? {
        guard case .project(let project) = node?.content, let location = project.location,
            location.gitCommonDirectory != nil
        else { return nil }
        return location
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
    @ObservationIgnored var lastSelectedBoardID: UUID?
    var dataDirectory: URL { disk.directory }
    let git = GitWorkspace()
    var agentRuns: [NodeAddress: AgentRun] = [:]
    var terminals: [NodeAddress: AgentTerminal] = [:]
    var connectedMapRuns: Set<UUID> = []
    var operations: Set<NodeAddress> = []
    @ObservationIgnored var mcpListener: MCPListener?
    @ObservationIgnored var mcpGrants: [String: MCPGrant] = [:]
    let commandCodeConnection: CommandCodeConnection
    @ObservationIgnored var formClosers: [NodeAddress: (UUID, () -> Void)] = [:]
    @ObservationIgnored private let disk: any WorkspacePersistence
    @ObservationIgnored private var loadStarted = false
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var editingSessions: [EditKey: EditingSession] = [:]
    @ObservationIgnored private var saveRevision = 0

    init(disk: any WorkspacePersistence) {
        self.disk = disk
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
            isReadOnly = !writable
            let value = archive ?? WorkspaceArchive(boards: [MindMapBoard()])
            cameras = value.cameras
            lastSelectedBoardID = value.selectedBoardID
            boards = value.boards.map(makeSession)
            for var run in value.agentRuns ?? [] {
                if run.state.isActive {
                    run.state = .interrupted
                    run.finishedAt = .now
                }
                agentRuns[run.address] = run
            }
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

    func select(_ id: UUID?) {
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

    func commitEdits(in boardID: UUID? = nil) {
        let commits = editingSessions.filter { boardID == nil || $0.key.boardID == boardID }.map { $0.value.commit }
        for commit in commits { commit() }
    }

    func revealData() { NSWorkspace.shared.open(disk.directory) }

    func flush() async throws {
        saveTask?.cancel()
        guard !isReadOnly, !isLoading else { return }
        saveRevision += 1
        let revision = saveRevision
        saveState = .saving
        do {
            try await disk.save(archive())
            if revision == saveRevision {
                errorMessage = nil
                saveState = .saved
            }
        } catch {
            if revision == saveRevision { recordSaveFailure(error) }
            throw error
        }
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
            boards.contains { $0.id == run.address.boardID && $0.board.nodes[run.address.nodeID] != nil }
        }
        return WorkspaceArchive(
            boards: snapshots, cameras: cameras, selectedBoardID: lastSelectedBoardID, agentRuns: Array(runs))
    }

    func scheduleSave() {
        guard !isReadOnly, !isLoading else { return }
        saveState = .saving
        saveRevision += 1
        let revision = saveRevision
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(350))
                guard let self, !Task.isCancelled, self.saveRevision == revision else { return }
                try await self.disk.save(self.archive())
                guard !Task.isCancelled, self.saveRevision == revision else { return }
                self.errorMessage = nil
                self.saveState = .saved
            } catch is CancellationError {
            } catch {
                guard let self, !Task.isCancelled, self.saveRevision == revision else { return }
                self.recordSaveFailure(error)
            }
        }
    }

    private func recordSaveFailure(_ error: any Error) {
        errorMessage = "Changes could not be saved: \(error.localizedDescription)"
        saveState = .failed
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
