import AppKit
import Darwin
import MindMapCore
import Observation

@Observable
final class BoardSession: Identifiable {
    let id: UUID
    private(set) var name: String
    private(set) var revision = 0
    private(set) var nodeCount: Int
    @ObservationIgnored private(set) var board: MindMapBoard
    @ObservationIgnored let undoManager = UndoManager()
    @ObservationIgnored var didChange: (() -> Void)?
    @ObservationIgnored var isReadOnly = false

    init(_ board: MindMapBoard) {
        self.board = board
        id = board.id
        name = board.name
        nodeCount = board.nodes.count
        undoManager.groupsByEvent = false
        undoManager.levelsOfUndo = 100
    }

    func apply(_ edit: BoardEdit?, named action: String) {
        guard !isReadOnly, let edit else { return }
        let inverse = board.apply(edit)
        let ownsGroup = !undoManager.isUndoing && !undoManager.isRedoing
        if ownsGroup { undoManager.beginUndoGrouping() }
        undoManager.registerUndo(withTarget: self) { target in
            MainActor.assumeIsolated { target.apply(inverse, named: action) }
        }
        undoManager.setActionName(action)
        if ownsGroup { undoManager.endUndoGrouping() }
        name = board.name
        nodeCount = board.nodes.count
        revision += 1
        didChange?()
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
        lockDescriptor = open(lockPath, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
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
    private(set) var deletedBoardName: String?
    @ObservationIgnored var cameras: [UUID: MapCamera] = [:]
    @ObservationIgnored var lastSelectedBoardID: UUID?
    @ObservationIgnored private let disk: any WorkspacePersistence
    @ObservationIgnored private var loadStarted = false
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var deletedBoard: (BoardSession, Int)?
    @ObservationIgnored private var editingSessions: [EditKey: EditingSession] = [:]
    @ObservationIgnored private var saveRevision = 0

    init(disk: any WorkspacePersistence) { self.disk = disk }

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
        commitEdits(in: id)
        let session = boards.remove(at: index)
        deletedBoard = (session, index)
        deletedBoardName = session.name
        scheduleSave()
    }

    func undoDeleteBoard() {
        guard let (session, index) = deletedBoard else { return }
        boards.insert(session, at: min(index, boards.count))
        deletedBoard = nil
        deletedBoardName = nil
        scheduleSave()
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
        return session
    }

    private func archive() -> WorkspaceArchive {
        let snapshots = boards.map { session in
            let pending = editingSessions.filter { $0.key.boardID == session.id && $0.value.text != nil }
            guard !pending.isEmpty else { return session.board }
            var board = session.board
            let replacements = pending.compactMap { key, edit -> NodeReplacement? in
                guard var node = board.nodes[key.nodeID], let text = edit.text else { return nil }
                node.text = text
                return NodeReplacement(id: key.nodeID, node: node)
            }
            board.apply(BoardEdit(nodes: replacements))
            return board
        }
        return WorkspaceArchive(boards: snapshots, cameras: cameras, selectedBoardID: lastSelectedBoardID)
    }

    private func scheduleSave() {
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
