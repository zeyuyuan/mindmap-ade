import Foundation
import MindMapCore

final class MCPGrant {
    struct Receipt {
        let request: Data
        let result: [String: Any]
    }

    let run: AgentRun
    var pending: Set<String> = []
    var receipts: [String: Receipt] = [:]
    var createdNodes: Set<UUID> = []

    init(run: AgentRun) { self.run = run }
}

private enum MapTool: String, CaseIterable {
    case context = "get_context"
    case list = "list_nodes"
    case create = "create_node"
    case update = "update_node"
    case move = "move_node"
    case delete = "delete_node"
    case register = "register_worktree"

    var changesMap: Bool { self != .context && self != .list }

    var definition: [String: Any] {
        var fields: [String: String] = [:]
        var required: [String] = []
        let description: String
        switch self {
        case .context:
            description = "Read the current conversation, its project and worktree, and the map revision."
        case .list:
            description = "Read a page of direct children in the current conversation branch."
            fields = ["parentId": "string", "offset": "integer"]
        case .create:
            description = "Add a text topic under the current conversation or one of its text topics."
            fields = ["parentId": "string", "text": "string"]
            required = ["text"]
        case .update:
            description = "Edit a text topic or set a short progress summary on this conversation."
            fields = ["nodeId": "string", "text": "string", "expectedRevision": "integer"]
            required = ["nodeId", "text", "expectedRevision"]
        case .move:
            description = "Move a text topic within this conversation branch."
            fields = ["nodeId": "string", "parentId": "string", "expectedRevision": "integer"]
            required = ["nodeId", "parentId", "expectedRevision"]
        case .delete:
            description = "Remove a text leaf created by this run."
            fields = ["nodeId": "string", "expectedRevision": "integer"]
            required = ["nodeId", "expectedRevision"]
        case .register:
            description =
                "Show a real worktree registered with this project. A new conversation draft can be placed under it while this process keeps its original directory."
            fields = ["directory": "string", "task": "string"]
            required = ["directory"]
        }
        if changesMap {
            fields["operationId"] = "string"
            required.append("operationId")
        }
        return [
            "name": rawValue,
            "description": description,
            "inputSchema": [
                "type": "object",
                "properties": fields.mapValues { ["type": $0] },
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
        for key in keys { mcpGrants.removeValue(forKey: key) }
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
                let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
                return result(["content": [["type": "text", "text": String(decoding: data, as: UTF8.self)]]])
            } catch {
                return result(["isError": true, "content": [["type": "text", "text": error.localizedDescription]]])
            }
        default: return failure(-32601, "Unknown MCP method.")
        }
    }

    private func isActive(_ grant: MCPGrant) -> Bool {
        let record = agentRuns[grant.run.address]
        return record?.id == grant.run.id && (record?.state == .starting || record?.state == .running)
    }

    private func call(
        _ tool: MapTool, arguments: [String: Any], grant: MCPGrant, session: BoardSession
    ) async throws -> [String: Any] {
        if !tool.changesMap { return try read(tool, arguments: arguments, grant: grant, session: session) }
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
    ) throws -> [String: Any] {
        let origin = grant.run.address.nodeID
        let board = session.board
        if tool == .context {
            var ancestors: [[String: String]] = []
            var current = board.parents[origin]
            while let id = current, let node = board.nodes[id], ancestors.count < 64 {
                ancestors.append([
                    "id": id.uuidString, "title": String(node.title.prefix(400)), "kind": node.content.kind.rawValue,
                ])
                current = board.parents[id]
            }
            return [
                "boardId": board.id.uuidString, "board": board.name, "agentId": origin.uuidString,
                "directory": grant.run.directory, "revision": session.revision,
                "ancestors": Array(ancestors.reversed()),
            ]
        }
        let parent = try scopedNode(arguments["parentId"], default: origin, grant: grant, in: board)
        let children = board.nodes[parent]?.children ?? []
        let offset = max(0, min(arguments["offset"] as? Int ?? 0, children.count))
        let end = min(offset + 50, children.count)
        let topics = children[offset..<end].compactMap { id -> [String: String]? in
            guard let node = board.nodes[id] else { return nil }
            return ["id": id.uuidString, "title": String(node.title.prefix(1000)), "kind": node.content.kind.rawValue]
        }
        return ["nodes": topics, "nextOffset": end, "total": children.count, "revision": session.revision]
    }

    private func write(
        _ tool: MapTool, arguments: [String: Any], grant: MCPGrant, session: BoardSession
    ) async throws -> [String: Any] {
        guard isActive(grant), !isReadOnly else { throw WorkspaceIssue("This conversation cannot change the map.") }
        let board = session.board
        let origin = grant.run.address.nodeID
        switch tool {
        case .create:
            let parent = try scopedNode(arguments["parentId"], default: origin, grant: grant, in: board)
            let text = try boundedText(arguments["text"], limit: 24_000)
            guard let insertion = board.inserting(text: text, parent: parent),
                session.apply(insertion.edit, named: "Agent Added Topic")
            else { throw WorkspaceIssue("The topic could not be added.") }
            grant.createdNodes.insert(insertion.id)
            return ["nodeId": insertion.id.uuidString]
        case .update, .move, .delete:
            guard arguments["expectedRevision"] as? Int == session.revision else {
                throw WorkspaceIssue("The map changed. Read the latest revision and retry.")
            }
            let id = try scopedNode(arguments["nodeId"], grant: grant, in: board)
            guard !isEditing(NodeAddress(boardID: board.id, nodeID: id)) else {
                throw WorkspaceIssue("This topic is being edited. Retry after editing finishes.")
            }
            let edit: BoardEdit?
            if tool == .update {
                if id == origin, case .agent(var agent) = board.nodes[id]?.content {
                    agent.progress = try boundedText(arguments["text"], limit: 400)
                    edit = board.replacingContent(id, with: .agent(agent))
                } else {
                    edit = board.replacingText(id, with: try boundedText(arguments["text"], limit: 24_000))
                }
                if edit == nil { return ["nodeId": id.uuidString] }
            } else if tool == .move, id != origin, board.nodes[id]?.content.kind == .text {
                let parent = try scopedNode(arguments["parentId"], grant: grant, in: board)
                edit = board.moving(id, to: parent)
            } else if tool == .delete, grant.createdNodes.contains(id), board.nodes[id]?.children.isEmpty == true {
                edit = board.deleting([id])
            } else {
                throw WorkspaceIssue("This change is outside the conversation's write scope.")
            }
            guard session.apply(edit, named: "Agent Updated Map") else {
                throw WorkspaceIssue(session.editError ?? "This change could not be applied.")
            }
            return ["nodeId": id.uuidString]
        case .register:
            return try await register(arguments: arguments, grant: grant, session: session)
        case .context, .list:
            return [:]
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
        guard isActive(grant), session.board.context(above: origin) == scope else {
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
                result["draftAgentId"] = insertion.id.uuidString
            }
        }
        if !edit.nodes.isEmpty, !session.apply(edit, named: "Agent Registered Worktree") {
            throw WorkspaceIssue(session.editError ?? "The worktree could not be registered.")
        }
        return result
    }

    private func scopedNode(
        _ value: Any?, default defaultID: UUID? = nil, grant: MCPGrant, in board: MindMapBoard
    ) throws -> UUID {
        let origin = grant.run.address.nodeID
        let id = (value as? String).flatMap(UUID.init(uuidString:)) ?? (value == nil ? defaultID : nil)
        guard let id else { throw WorkspaceIssue("Provide a topic ID in this conversation branch.") }
        var ancestor: UUID? = id
        while let cursor = ancestor, let node = board.nodes[cursor] {
            if cursor == origin { return id }
            if node.content.kind != .text { break }
            ancestor = board.parents[cursor]
        }
        throw WorkspaceIssue("This topic is outside the conversation's scope.")
    }

    private func boundedText(_ value: Any?, limit: Int) throws -> String {
        guard let text = value as? String, text.utf8.count <= limit, !text.contains("\0") else {
            throw WorkspaceIssue("Provide text within the tool's size limit.")
        }
        return text
    }
}
