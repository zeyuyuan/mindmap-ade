import CoreFoundation
import CryptoKit
import Foundation
import MindMapCore

final class MCPGrant {
    struct Receipt {
        let request: Data
        let result: [String: Any]
    }

    let run: AgentRun
    private(set) var isRevoked = false
    var pending: Set<String> = []
    var receipts: [String: Receipt] = [:]
    private var pages: [(id: UUID, revision: Int, page: MapReadPage)] = []

    init(run: AgentRun) { self.run = run }

    func revoke() {
        isRevoked = true
        pages.removeAll()
    }

    fileprivate func continuation(for page: MapReadPage, revision: Int) -> String {
        pages.removeAll { $0.revision != revision }
        if pages.count == 16 { pages.removeFirst() }
        let id = UUID()
        pages.append((id, revision, page))
        return id.uuidString
    }

    fileprivate func page(for cursor: String, revision: Int, tool: MapTool) throws -> MapReadPage {
        guard let id = UUID(uuidString: cursor), let entry = pages.first(where: { $0.id == id }),
            entry.revision == revision, entry.page.tool == tool
        else { throw WorkspaceIssue("The page cursor is no longer valid. Start the read again.") }
        return entry.page
    }
}

private enum MapReadPage {
    case search(query: String, traversal: MapSearch.Traversal)
    case node(id: UUID, field: String?, offset: Int)
    case list(parent: UUID?, offset: Int)
    case selection(offset: Int, fingerprint: SHA256.Digest?)
    case selectedNode(id: UUID, offset: Int)

    var tool: MapTool {
        switch self {
        case .search: .search
        case .node: .node
        case .list: .list
        case .selection, .selectedNode: .selection
        }
    }
}

private enum MapTool: String, CaseIterable {
    case context = "get_context"
    case search = "search_nodes"
    case node = "get_node"
    case list = "list_nodes"
    case selection = "get_selection"
    case create = "create_node"
    case update = "update_node"
    case move = "move_node"
    case delete = "delete_node"
    case register = "register_worktree"

    var changesMap: Bool {
        switch self {
        case .context, .search, .node, .list, .selection: false
        case .create, .update, .move, .delete, .register: true
        }
    }

    var definition: [String: Any] {
        var fields: [String: [String: Any]] = [:]
        var required: [String] = []
        let description: String
        switch self {
        case .context:
            description = "Read this conversation's board, Agent ID, ancestors, working directory, and map revision."
        case .search:
            description =
                "Find topics by title or text on this board. Returns up to 8 matches with IDs, paths and excerpts. "
                + "Provide query and optionally rootId to start at that topic and search its descendants."
            fields = ["query": ["type": "string"], "rootId": ["type": "string"]]
        case .node:
            description =
                "Read one topic by ID on this board, including its text, ancestors and editable fields. "
                + "Omit nodeId to read this conversation's Agent."
            fields = [
                "nodeId": ["type": "string"],
                "field": ["type": "string", "description": "Optional field from readableFields."],
            ]
        case .list:
            description =
                "List a page of direct children of a topic on this board. Omit parentId for this Agent's children. "
                + "Pass null for the board's roots."
            fields = ["parentId": ["type": ["string", "null"]]]
        case .selection:
            description =
                "Read the topics currently selected on the board beside this conversation's terminal. "
                + "Omit nodeId to list topics and text previews. "
                + "Pass a selected nodeId to read its full text in chunks."
            fields = ["nodeId": ["type": "string"]]
        case .create:
            description =
                "Add a text topic or a Project, Worktree or Agent draft on this board. "
                + "Omit parentId to add below this Agent. Pass null to add a root. "
                + "Drafts use text as the Project name, proposed Worktree branch, or Agent task."
            fields = [
                "parentId": ["type": ["string", "null"]],
                "kind": ["type": "string", "enum": NodeKind.allCases.filter { $0 != .gitChanges }.map(\.rawValue)],
                "text": ["type": "string"],
                "expectedRevision": ["type": "integer"],
            ]
            required = ["text"]
        case .update:
            description =
                "Edit a topic on this board. Use editableFields from get_node to choose a field. "
                + "Omit field to edit the first listed field, which is progress for this Agent. "
                + "An existing conversation's initial task is read-only."
            fields = [
                "nodeId": ["type": "string"], "text": ["type": "string"], "field": ["type": "string"],
                "expectedRevision": ["type": "integer"],
            ]
            required = ["nodeId", "text", "expectedRevision"]
        case .move:
            description =
                "Move a topic and its descendants on this board. Pass null as parentId to move to the roots. "
                + "Use index for the destination position after removal, starting at zero."
            fields = [
                "nodeId": ["type": "string"], "parentId": ["type": ["string", "null"]],
                "index": ["type": "integer"], "expectedRevision": ["type": "integer"],
            ]
            required = ["nodeId", "parentId", "expectedRevision"]
        case .delete:
            description =
                "Remove a map topic and its descendants. The map edit is undoable and preserves files on disk."
            fields = ["nodeId": ["type": "string"], "expectedRevision": ["type": "integer"]]
            required = ["nodeId", "expectedRevision"]
        case .register:
            description =
                "Show a real worktree registered with this project. A new conversation draft can be placed under it while this process keeps its original directory."
            fields = ["directory": ["type": "string"], "task": ["type": "string"]]
            required = ["directory"]
        }
        if changesMap {
            fields["operationId"] = ["type": "string"]
            required.append("operationId")
        }
        let paginated = !changesMap && self != .context
        if paginated { fields["cursor"] = ["type": "string"] }
        var annotations: [String: Any] = ["readOnlyHint": !changesMap, "openWorldHint": false]
        if changesMap {
            annotations["destructiveHint"] = self == .delete || self == .update || self == .move
            annotations["idempotentHint"] = true
        }
        return [
            "name": rawValue,
            "description": description + (paginated ? " To continue, send nextCursor as cursor by itself." : ""),
            "annotations": annotations,
            "inputSchema": [
                "type": "object",
                "properties": fields,
                "required": required,
                "additionalProperties": false,
            ],
        ]
    }
}

extension WorkspaceStore {
    func prepareMCP(for run: AgentRun, environment: [String: String]) async throws
        -> (bridge: String, environment: [String: String])
    {
        if mcpListener == nil {
            mcpListener = try MCPListener { [weak self] request in await self?.handleMCP(request) }
        }
        guard let listener = mcpListener, let bridge = Bundle.main.executableURL?.path else {
            throw WorkspaceIssue("The map connection is unavailable.")
        }
        if run.cli == .commandCode {
            try await commandCodeConnection.acquire(
                runID: run.id, directory: run.directory, executable: run.launcher.executable,
                bridge: bridge, environment: environment)
        }
        let token = UUID().uuidString + UUID().uuidString
        mcpGrants[token] = MCPGrant(run: run)
        return (bridge, ["MINDMAP_MCP_SOCKET": listener.path, "MINDMAP_MCP_TOKEN": token])
    }

    func releaseMCP(for run: AgentRun) {
        connectedMapRuns.remove(run.id)
        let keys = mcpGrants.compactMap { $0.value.run.id == run.id ? $0.key : nil }
        for key in keys { mcpGrants.removeValue(forKey: key)?.revoke() }
        if run.cli == .commandCode {
            Task { await commandCodeConnection.release(runID: run.id, directory: run.directory) }
        }
    }

    func handleMCP(_ bytes: Data) async -> Data? {
        guard let envelope = try? JSONDecoder().decode(MCPEnvelope.self, from: bytes),
            let request = (try? JSONSerialization.jsonObject(with: envelope.message)) as? [String: Any],
            let id = request["id"],
            let method = request["method"] as? String
        else { return nil }
        func result(_ value: [String: Any]) -> Data? {
            try? JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": id, "result": value])
        }
        func failure(_ code: Int, _ message: String) -> Data? {
            try? JSONSerialization.data(withJSONObject: [
                "jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message],
            ])
        }
        guard let grant = mcpGrants[envelope.token], isActive(grant),
            let session = board(grant.run.address.boardID)
        else { return failure(-32001, "The map session has ended or is unauthorized.") }
        let parameters = request["params"] as? [String: Any] ?? [:]
        switch method {
        case "initialize":
            let requested = parameters["protocolVersion"] as? String
            let supported = ["2024-11-05", "2025-03-26", "2025-06-18", "2025-11-25"]
            let version = requested.flatMap { supported.contains($0) ? $0 : nil } ?? "2025-11-25"
            return result([
                "protocolVersion": version, "capabilities": ["tools": [:]],
                "serverInfo": ["name": "Mindmap ADE", "version": "0.1.0"],
            ])
        case "ping": return result([:])
        case "tools/list":
            connectedMapRuns.insert(grant.run.id)
            return result(["tools": MapTool.allCases.map(\.definition)])
        case "tools/call":
            guard let name = parameters["name"] as? String, let tool = MapTool(rawValue: name) else {
                return failure(-32602, "Unknown map tool.")
            }
            let arguments = parameters["arguments"] as? [String: Any] ?? [:]
            do {
                let value = try await call(tool, arguments: arguments, grant: grant, session: session)
                guard isActive(grant) else { throw WorkspaceIssue("The map session has ended.") }
                let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
                return result(["content": [["type": "text", "text": String(decoding: data, as: UTF8.self)]]])
            } catch {
                return result(["isError": true, "content": [["type": "text", "text": error.localizedDescription]]])
            }
        default: return failure(-32601, "Unknown MCP method.")
        }
    }

    private func isActive(_ grant: MCPGrant) -> Bool {
        guard !grant.isRevoked, !isQuitting else { return false }
        let record = agentRuns[grant.run.address]
        return record?.id == grant.run.id && (record?.state == .starting || record?.state == .running)
    }

    private func call(
        _ tool: MapTool, arguments: [String: Any], grant: MCPGrant, session: BoardSession
    ) async throws -> [String: Any] {
        if !tool.changesMap { return try await read(tool, arguments: arguments, grant: grant, session: session) }
        guard let operation = arguments["operationId"] as? String, !operation.isEmpty, operation.utf8.count <= 120
        else {
            throw WorkspaceIssue("Provide a unique operationId for map changes.")
        }
        let encoded = try JSONSerialization.data(withJSONObject: [tool.rawValue: arguments], options: [.sortedKeys])
        if let receipt = grant.receipts[operation] {
            guard receipt.request == encoded else {
                throw WorkspaceIssue("This operationId was used for a different change.")
            }
            try await flush()
            return receipt.result
        }
        guard grant.receipts.count < 1000, grant.pending.insert(operation).inserted else {
            throw WorkspaceIssue("This operation is already running or the session has reached its map change limit.")
        }
        defer { grant.pending.remove(operation) }
        let value = try await write(tool, arguments: arguments, grant: grant, session: session)
        var output = value
        output["revision"] = session.revision
        grant.receipts[operation] = MCPGrant.Receipt(request: encoded, result: output)
        try await flush()
        return output
    }

    private func read(
        _ tool: MapTool, arguments: [String: Any], grant: MCPGrant, session: BoardSession
    ) async throws -> [String: Any] {
        let origin = grant.run.address.nodeID
        let board = session.board
        let revision = session.revision
        if tool == .context {
            return [
                "boardId": board.id.uuidString, "board": board.name, "agentId": origin.uuidString,
                "directory": grant.run.directory, "revision": revision, "parentId": nullableID(board.parents[origin]),
                "ancestors": ancestors(of: origin, in: board, limit: 64),
            ]
        }
        let page: MapReadPage
        if let value = arguments["cursor"] {
            guard arguments.count == 1, let cursor = value as? String else {
                throw WorkspaceIssue("Send nextCursor as cursor by itself to continue the read.")
            }
            page = try grant.page(for: cursor, revision: revision, tool: tool)
        } else {
            guard arguments["offset"] == nil else {
                throw WorkspaceIssue("Start without an offset, then use nextCursor to continue the read.")
            }
            page = try firstPage(tool, arguments: arguments, origin: origin, board: board)
        }
        let result: [String: Any]
        let next: MapReadPage?
        switch page {
        case .search(let query, let traversal):
            let page = try await MapSearch.page(for: query, in: board, from: traversal)
            try checkMapSnapshot(revision, grant: grant, session: session)
            let matches = page.matches.compactMap { match -> [String: Any]? in
                guard let node = board.nodes[match.id] else { return nil }
                var result: [String: Any] = nodeSummary(node)
                result["parentId"] = nullableID(board.parents[node.id])
                result["ancestors"] = ancestors(of: node.id, in: board, limit: 5)
                result["snippet"] = match.snippet
                return result
            }
            result = ["nodes": matches]
            next = page.next.map { .search(query: query, traversal: $0) }
        case .node(let id, let field, let offset):
            guard let node = board.nodes[id] else { throw WorkspaceIssue("The topic is no longer on this board.") }
            let fields = mapFields(for: node, origin: origin, in: session)
            let text: String
            if let field {
                guard let value = fields.first(where: { $0.name.rawValue == field }) else {
                    throw WorkspaceIssue("Read this topic with get_node without a field to find its readable fields.")
                }
                text = value.text
            } else {
                text = node.mapToolText
            }
            let part = nodeTextPage(text, offset: offset)
            var summary: [String: Any] = nodeSummary(node)
            summary["text"] = part.text
            summary["parentId"] = nullableID(board.parents[id])
            summary["ancestors"] = ancestors(of: id, in: board, limit: 8)
            summary["childCount"] = node.children.count
            summary["readableFields"] = fields.map(\.name.rawValue)
            summary["editableFields"] = fields.filter(\.isEditable).map(\.name.rawValue)
            result = summary
            next = part.next.map { .node(id: id, field: field, offset: $0) }
        case .list(let parent, let offset):
            let count = parent.flatMap { board.nodes[$0]?.children.count } ?? board.roots.count
            let end = min(offset + 50, count)
            let ids =
                parent.flatMap { board.nodes[$0]?.children[offset..<end] }.map(Array.init)
                ?? board.roots[offset..<end].map(\.id)
            result = [
                "nodes": ids.compactMap { board.nodes[$0].map(nodeSummary) },
                "parentId": nullableID(parent), "total": count,
            ]
            next = end < count ? .list(parent: parent, offset: end) : nil
        case .selection(let offset, let fingerprint):
            let selected = terminals[grant.run.address]?.canvasSelection(in: session) ?? []
            (result, next) = try readSelection(selected, offset: offset, matching: fingerprint, board: board)
        case .selectedNode(let id, let offset):
            let selected = terminals[grant.run.address]?.canvasSelection(in: session) ?? []
            guard selected.contains(id), let node = board.nodes[id] else {
                throw WorkspaceIssue("Provide an ID for a topic currently selected on the canvas.")
            }
            let part = nodeTextPage(node.mapToolText, offset: offset)
            result = [
                "boardId": board.id.uuidString, "board": board.name,
                "id": id.uuidString, "kind": node.content.kind.rawValue, "text": part.text,
            ]
            next = part.next.map { .selectedNode(id: id, offset: $0) }
        }
        var output = result
        output["revision"] = revision
        output["hasMore"] = next != nil
        if let next {
            output["nextCursor"] = grant.continuation(for: next, revision: revision)
        }
        return output
    }

    private func firstPage(
        _ tool: MapTool, arguments: [String: Any], origin: UUID, board: MindMapBoard
    ) throws -> MapReadPage {
        switch tool {
        case .search:
            let query = try boundedText(arguments["query"], limit: 256).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !query.isEmpty else { throw WorkspaceIssue("Provide text to search for.") }
            let root = try arguments["rootId"].map { try mapNode($0, in: board).id }
            return .search(query: query, traversal: .init(root: root))
        case .node:
            let id = try mapNode(arguments["nodeId"] ?? origin.uuidString, in: board).id
            let field = try arguments["field"].map { try boundedText($0, limit: 32) }
            return .node(id: id, field: field, offset: 0)
        case .list:
            let parent = try mapParent(arguments["parentId"] ?? origin.uuidString, in: board)
            return .list(parent: parent?.id, offset: 0)
        case .selection:
            if let value = arguments["nodeId"] {
                guard let text = value as? String, let id = UUID(uuidString: text) else {
                    throw WorkspaceIssue("Provide an ID for a topic currently selected on the canvas.")
                }
                return .selectedNode(id: id, offset: 0)
            }
            return .selection(offset: 0, fingerprint: nil)
        default:
            throw WorkspaceIssue("This map tool does not have pages.")
        }
    }

    private func nodeSummary(_ node: MapNode) -> [String: String] {
        [
            "id": node.id.uuidString, "kind": node.content.kind.rawValue,
            "title": String(node.title.unicodeScalars.prefix(200)),
        ]
    }

    private func ancestors(of id: UUID, in board: MindMapBoard, limit: Int) -> [[String: String]] {
        var path: [[String: String]] = []
        var parent = board.parents[id]
        while path.count < limit, let id = parent, let node = board.nodes[id] {
            var item = nodeSummary(node)
            item["title"] = String(node.title.unicodeScalars.prefix(80))
            path.append(item)
            parent = board.parents[id]
        }
        return path.reversed()
    }

    private func nodeTextPage(_ text: String, offset: Int) -> (text: String, next: Int?) {
        let scalars = text.unicodeScalars
        let start = scalars.index(scalars.startIndex, offsetBy: offset, limitedBy: scalars.endIndex) ?? scalars.endIndex
        // Limit the response even when the text requires escaping in both layers of JSON.
        let slice = scalars[start...].prefix(4_000)
        return (String(slice), slice.endIndex == scalars.endIndex ? nil : offset + slice.count)
    }

    private func readSelection(
        _ selected: Set<UUID>, offset: Int, matching fingerprint: SHA256.Digest?, board: MindMapBoard
    ) throws -> ([String: Any], MapReadPage?) {
        let ids = selected.filter { board.nodes[$0] != nil }.sorted()
        let end = min(offset + 50, ids.count)
        var digest: SHA256.Digest?
        if fingerprint != nil || end < ids.count {
            var hash = SHA256()
            for id in ids {
                withUnsafeBytes(of: id.uuid) { hash.update(bufferPointer: $0) }
            }
            digest = hash.finalize()
        }
        if let fingerprint, fingerprint != digest {
            throw WorkspaceIssue("The selection changed. Start the read again.")
        }
        let nodes = ids[offset..<end].compactMap { id -> [String: Any]? in
            guard let node = board.nodes[id] else { return nil }
            let content = node.mapToolText.unicodeScalars
            let preview = content.prefix(200)
            var summary: [String: Any] = nodeSummary(node)
            summary["text"] = String(preview)
            summary["hasMoreText"] = preview.endIndex != content.endIndex
            return summary
        }
        return (
            ["boardId": board.id.uuidString, "board": board.name, "nodes": nodes, "total": ids.count],
            end < ids.count ? .selection(offset: end, fingerprint: digest) : nil
        )
    }

    private func write(
        _ tool: MapTool, arguments: [String: Any], grant: MCPGrant, session: BoardSession
    ) async throws -> [String: Any] {
        guard isActive(grant), !isReadOnly else { throw WorkspaceIssue("This conversation cannot change the map.") }
        let board = session.board
        let revision = session.revision
        let origin = grant.run.address.nodeID
        switch tool {
        case .create:
            if arguments["expectedRevision"] != nil { try checkMapRevision(arguments, in: session) }
            let parent = try mapParent(arguments["parentId"] ?? origin.uuidString, in: board)?.id
            let text = try boundedText(arguments["text"], limit: 24_000)
            let kind: NodeKind
            if let value = arguments["kind"] {
                guard let raw = value as? String, let requested = NodeKind(rawValue: raw), requested != .gitChanges
                else {
                    throw WorkspaceIssue("Choose a topic kind from text, project, worktree, or agent.")
                }
                kind = requested
            } else {
                kind = .text
            }
            let draftText = kind == .worktree ? try await mapBranchName(text) : text
            let node = mapDraft(kind, text: draftText, cli: grant.run.cli)
            let position = parent == nil ? try await appendedRootPosition(for: nil, in: board) : .zero
            try checkMapSnapshot(revision, grant: grant, session: session)
            guard let insertion = board.inserting(node, parent: parent, position: position)
            else { throw WorkspaceIssue("The topic could not be added.") }
            try applyMapEdit(insertion.edit, change: .added, highlighting: [insertion.id], in: session)
            return ["nodeId": insertion.id.uuidString]
        case .update:
            try checkMapRevision(arguments, in: session)
            let node = try mapNode(arguments["nodeId"], in: board)
            let fields = mapFields(for: node, origin: origin, in: session).filter(\.isEditable)
            let field: MapField?
            if let value = arguments["field"] {
                field = fields.first { $0.name.rawValue == value as? String }
            } else {
                field = fields.first
            }
            guard let field, let replace = field.replace else {
                throw WorkspaceIssue("Read this topic with get_node to find its editable fields.")
            }
            let text = try boundedText(arguments["text"], limit: field.name.byteLimit)
            let value = field.name == .branch ? try await mapBranchName(text) : text
            try checkMapSnapshot(revision, grant: grant, session: session)
            try checkEditable(node.id, in: session)
            let updated = replace(value)
            if updated != node {
                let edit = BoardEdit(nodes: [NodeReplacement(id: node.id, node: updated)])
                try applyMapEdit(edit, change: .edited, highlighting: [node.id], in: session)
            }
            return ["nodeId": node.id.uuidString]
        case .move:
            try checkMapRevision(arguments, in: session)
            let node = try mapNode(arguments["nodeId"], in: board)
            let parent = try mapParent(arguments["parentId"], in: board)?.id
            try checkEditable(node.id, in: session)
            let index =
                try arguments["index"].map { try mapInteger($0, named: "index") }
                ?? (parent == nil ? board.roots.count : nil)
            var positions: [UUID: CGPoint] = [:]
            if parent == nil, board.parents[node.id] != nil {
                positions[node.id] = try await appendedRootPosition(for: node.id, in: board)
                try checkMapSnapshot(revision, grant: grant, session: session)
                try checkEditable(node.id, in: session)
            }
            guard let edit = board.movingBranches([node.id], to: parent, at: index, positions: positions) else {
                throw WorkspaceIssue("The topic cannot be moved to that position, or is already there.")
            }
            try applyMapEdit(edit, change: .moved, highlighting: [node.id], in: session)
            return ["nodeId": node.id.uuidString]
        case .delete:
            try checkMapRevision(arguments, in: session)
            let node = try mapNode(arguments["nodeId"], in: board)
            guard let edit = board.deleting([node.id]) else { throw WorkspaceIssue("The topic could not be removed.") }
            try applyMapEdit(edit, change: .removed, in: session)
            return ["nodeId": node.id.uuidString]
        case .register:
            return try await register(arguments: arguments, grant: grant, session: session)
        case .context, .search, .node, .list, .selection:
            throw WorkspaceIssue("Use a map read tool to inspect a topic.")
        }
    }

    private func mapDraft(_ kind: NodeKind, text: String, cli: AgentCLIKind) -> MapNode {
        switch kind {
        case .text:
            return MapNode(text: text)
        case .project:
            var project = ProjectTopic()
            project.name = text
            return MapNode(content: .project(project))
        case .worktree:
            var worktree = WorktreeTopic()
            worktree.choice.branch = text
            return MapNode(content: .worktree(worktree))
        case .agent:
            return MapNode(content: .agent(AgentTopic(task: text, cli: cli)))
        case .gitChanges:
            return MapNode(content: .gitChanges(GitChangesTopic()))
        }
    }

    private func mapFields(for node: MapNode, origin: UUID, in session: BoardSession) -> [MapField] {
        let address = NodeAddress(boardID: session.id, nodeID: node.id)
        return node.mapFields(isOrigin: node.id == origin, hasRun: agentRuns[address] != nil)
    }

    private func mapBranchName(_ text: String) async throws -> String {
        let branch = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !branch.isEmpty {
            _ = try boundedText(branch, limit: MapField.Name.branch.byteLimit)
            try await git.validateBranchName(branch)
        }
        return branch
    }

    private func appendedRootPosition(for movedNodeID: UUID?, in board: MindMapBoard) async throws -> CGPoint {
        let layout = try await TextLayoutService().layout(
            board: board, regularFont: CanvasStyle.font(root: false).fontName,
            rootFont: CanvasStyle.font(root: true).fontName
        )
        if let movedNodeID, board.nodes[movedNodeID]?.children.isEmpty == false {
            // A detached branch can extend above its root. Place it to the right of the existing trees.
            let y = layout.nodes[movedNodeID]?.frame.minY ?? layout.bounds.midY
            return CGPoint(x: layout.bounds.maxX + MapMetrics.rootGap, y: y)
        }
        return CGPoint(x: board.roots.first?.position.x ?? 0, y: layout.bounds.maxY + MapMetrics.rootGap)
    }

    private func checkMapSnapshot(_ revision: Int, grant: MCPGrant, session: BoardSession) throws {
        guard isActive(grant), board(session.id) === session else {
            throw WorkspaceIssue("The map session has ended.")
        }
        guard revision == session.revision else {
            throw WorkspaceIssue("The map changed. Read the latest revision and retry.")
        }
    }

    private func checkMapRevision(_ arguments: [String: Any], in session: BoardSession) throws {
        guard try mapInteger(arguments["expectedRevision"], named: "expectedRevision") == session.revision else {
            throw WorkspaceIssue("The map changed. Read the latest revision and retry.")
        }
    }

    private func checkEditable(_ id: UUID, in session: BoardSession) throws {
        let address = NodeAddress(boardID: session.id, nodeID: id)
        guard !isEditing(address), !operations.contains(address) else {
            throw WorkspaceIssue("A topic affected by this edit is open for editing or is being prepared.")
        }
    }

    private func applyMapEdit(
        _ edit: BoardEdit, change: AgentMapChange, highlighting topics: Set<UUID> = [], in session: BoardSession
    ) throws {
        for replacement in edit.nodes {
            guard let current = session.board.nodes[replacement.id] else { continue }
            if replacement.node?.text != current.text || replacement.node?.content != current.content {
                try checkEditable(replacement.id, in: session)
            }
        }
        guard session.applyAgentEdit(edit, change: change, highlighting: topics) else {
            throw WorkspaceIssue(session.editError ?? "The map could not be updated.")
        }
    }

    private func register(
        arguments: [String: Any], grant: MCPGrant, session: BoardSession
    ) async throws -> [String: Any] {
        let origin = grant.run.address.nodeID
        let scope = session.board.context(above: origin)
        guard let project = scope.project, let parentTree = scope.worktreeID,
            let directory = arguments["directory"] as? String
        else { throw WorkspaceIssue("Provide the full path to a worktree in this project.") }
        let task = try arguments["task"].map { try boundedText($0, limit: 24_000) }
        let location = try await git.existing(directory, in: project)
        guard isActive(grant), board(session.id) === session else {
            throw WorkspaceIssue("The map session has ended.")
        }
        guard session.board.context(above: origin) == scope else {
            throw WorkspaceIssue("The conversation's binding changed. Read its current context.")
        }
        if location.directory == grant.run.directory {
            return ["worktreeId": parentTree.uuidString, "requiresRebind": false]
        }

        let before = session.board
        let parent =
            before.context(above: parentTree).worktreeID == nil
            ? before.parents[parentTree] : scope.projectID
        let siblings = parent.flatMap { before.nodes[$0]?.children } ?? before.roots.map(\.id)
        var candidate = before
        let id: UUID
        var edit = BoardEdit()
        var addedTopics: Set<UUID> = []
        let projectTopics = scope.projectID.map { before.descendants(of: $0) } ?? []
        let otherTopics = projectTopics.subtracting(siblings).sorted { $0.uuidString < $1.uuidString }
        if let existing = (siblings + otherTopics).first(where: {
            guard case .worktree(let topic) = before.nodes[$0]?.content else { return false }
            return topic.location?.directory == location.directory
                && topic.location?.gitCommonDirectory == location.gitCommonDirectory
        }) {
            id = existing
        } else {
            guard
                let insertion = candidate.inserting(
                    MapNode(content: .worktree(WorktreeTopic(location: location))), parent: parent, after: parentTree)
            else { throw WorkspaceIssue("The worktree could not be added to the map.") }
            id = insertion.id
            edit = insertion.edit
            addedTopics.insert(id)
            candidate.apply(edit)
        }
        var result: [String: Any] = ["worktreeId": id.uuidString, "requiresRebind": true]
        if let task {
            let agent = AgentTopic(task: task, cli: grant.run.cli)
            if let insertion = candidate.inserting(MapNode(content: .agent(agent)), parent: id) {
                // Inserting the draft changes the new worktree's children in the same edit.
                let ids = Set(insertion.edit.nodes.map(\.id))
                edit.nodes.removeAll { ids.contains($0.id) }
                edit.nodes.append(contentsOf: insertion.edit.nodes)
                addedTopics.insert(insertion.id)
                result["draftAgentId"] = insertion.id.uuidString
            }
        }
        if !addedTopics.isEmpty {
            try applyMapEdit(edit, change: .registeredWorktree, highlighting: addedTopics, in: session)
        }
        return result
    }

    private func mapNode(_ value: Any?, in board: MindMapBoard) throws -> MapNode {
        guard let raw = value as? String, let id = UUID(uuidString: raw), let node = board.nodes[id] else {
            throw WorkspaceIssue("Provide a topic ID on this conversation's board.")
        }
        return node
    }

    private func mapParent(_ value: Any?, in board: MindMapBoard) throws -> MapNode? {
        if value is NSNull { return nil }
        return try mapNode(value, in: board)
    }

    private func nullableID(_ id: UUID?) -> Any {
        if let id { return id.uuidString }
        return NSNull()
    }

    private func mapInteger(_ value: Any?, named name: String) throws -> Int {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), let value = value as? Int
        else { throw WorkspaceIssue("Provide an integer for \(name).") }
        return value
    }

    private func boundedText(_ value: Any?, limit: Int) throws -> String {
        guard let text = value as? String, text.utf8.count <= limit, !text.contains("\0") else {
            throw WorkspaceIssue("Provide text within the tool's size limit.")
        }
        return text
    }
}
