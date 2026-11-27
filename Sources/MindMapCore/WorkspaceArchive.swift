import Foundation

public struct DeletedBoardRecord: Codable, Sendable {
    public let board: MindMapBoard
    public let index: Int

    public init(board: MindMapBoard, index: Int) {
        self.board = board
        self.index = index
    }
}

public struct WorkspaceArchive: Codable, Sendable {
    private static let worktreeArchiveVersion = 9
    public static let currentVersion = 10

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, boards, deletedBoards, cameras, selectedBoardID, agentRuns, selections, agentPane, rightPane
    }

    private struct UnrecognizedKey: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init?(intValue: Int) { return nil }
        init?(stringValue: String) {
            guard CodingKeys(rawValue: stringValue) == nil else { return nil }
            self.stringValue = stringValue
        }
    }

    public var schemaVersion: Int
    public var boards: [MindMapBoard]
    public var deletedBoards: [DeletedBoardRecord]?
    public var cameras: [UUID: MapCamera]
    public var selectedBoardID: UUID?
    public var agentRuns: [AgentRun]?
    public var selections: [UUID: Set<UUID>]?
    public var agentPane: AgentPaneState?
    public var rightPane: RightPaneState?

    public init(
        boards: [MindMapBoard], cameras: [UUID: MapCamera] = [:], selectedBoardID: UUID? = nil,
        agentRuns: [AgentRun] = [], selections: [UUID: Set<UUID>] = [:], agentPane: AgentPaneState? = nil,
        rightPane: RightPaneState? = nil, deletedBoards: [DeletedBoardRecord] = []
    ) {
        schemaVersion = deletedBoards.isEmpty ? Self.worktreeArchiveVersion : Self.currentVersion
        self.boards = boards
        self.deletedBoards = deletedBoards.isEmpty ? nil : deletedBoards
        self.cameras = cameras
        self.selectedBoardID = selectedBoardID
        self.agentRuns = agentRuns
        self.selections = selections
        self.agentPane = agentPane
        self.rightPane = rightPane
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try values.decode(Int.self, forKey: .schemaVersion)
        // A newer workspace may carry pane or resource state this build cannot round-trip.
        if schemaVersion >= Self.worktreeArchiveVersion,
            !(try decoder.container(keyedBy: UnrecognizedKey.self).allKeys.isEmpty)
        {
            throw BoardValidationError.invalidStructure
        }
        boards = try values.decode([MindMapBoard].self, forKey: .boards)
        deletedBoards = try values.decodeIfPresent([DeletedBoardRecord].self, forKey: .deletedBoards)
        cameras = try values.decode([UUID: MapCamera].self, forKey: .cameras)
        selectedBoardID = try values.decodeIfPresent(UUID.self, forKey: .selectedBoardID)
        agentRuns = try values.decodeIfPresent([AgentRun].self, forKey: .agentRuns)
        selections = try values.decodeIfPresent([UUID: Set<UUID>].self, forKey: .selections)
        agentPane = try values.decodeIfPresent(AgentPaneState.self, forKey: .agentPane)
        rightPane = try values.decodeIfPresent(RightPaneState.self, forKey: .rightPane)
    }

    public func validated() throws -> Self {
        let deleted = deletedBoards ?? []
        let allBoards = boards + deleted.map(\.board)
        guard (1...Self.currentVersion).contains(schemaVersion),
            Set(allBoards.map(\.id)).count == allBoards.count,
            Set(deleted.map(\.index)).count == deleted.count,
            deleted.allSatisfy({ allBoards.indices.contains($0.index) })
        else {
            throw BoardValidationError.invalidStructure
        }
        for board in allBoards { _ = try board.validated() }
        guard
            cameras.values.allSatisfy({
                $0.scale.isFinite && (MapCamera.minimumScale...MapCamera.maximumScale).contains($0.scale)
                    && $0.translation.x.isFinite && $0.translation.y.isFinite
            })
        else { throw BoardValidationError.invalidStructure }
        var migrated = self
        if schemaVersion < 6 {
            migrated.boards = migrated.boards.map { original in
                var board = schemaVersion < 4 ? original.removingLegacyBranchNodes() : original
                board.flattenProjectCheckouts()
                return board
            }
        }
        if schemaVersion < 9 {
            var remappedIDs: [UUID: [UUID: UUID]] = [:]
            migrated.boards = migrated.boards.map { original in
                var board = original
                let remapped = board.migrateGitChangesToWorktrees()
                if !remapped.isEmpty { remappedIDs[board.id] = remapped }
                return board
            }
            if let pane = migrated.rightPane, pane.kind == .gitChanges,
                let replacement = remappedIDs[pane.address.boardID]?[pane.address.nodeID]
            {
                migrated.rightPane = RightPaneState(
                    address: NodeAddress(boardID: pane.address.boardID, nodeID: replacement),
                    kind: pane.kind, widthShare: pane.widthShare)
            }
        }
        migrated.schemaVersion = deleted.isEmpty ? Self.worktreeArchiveVersion : Self.currentVersion
        return migrated
    }
}

extension MindMapBoard {
    /// Moves legacy Git Changes nodes placed under Agents up to their enclosing configured Worktree,
    /// deduplicating by canonical directory and preserving any child notes.
    fileprivate mutating func migrateGitChangesToWorktrees() -> [UUID: UUID] {
        // Visit nodes in deterministic document order so the first card per directory wins.
        var ordered: [UUID] = []
        var stack = roots.reversed().map(\.id)
        while let id = stack.popLast() {
            guard let node = nodes[id] else { continue }
            ordered.append(id)
            stack.append(contentsOf: node.children.reversed())
        }
        var remapped: [UUID: UUID] = [:]
        for id in ordered {
            guard let node = nodes[id], case .gitChanges(let topic) = node.content else { continue }
            if let parentID = parents[id], case .worktree(let tree) = nodes[parentID]?.content, tree.location != nil {
                continue
            }
            let scope = context(above: id)
            guard let worktreeID = scope.worktreeID, var worktreeNode = nodes[worktreeID],
                case .worktree(var worktreeTopic) = worktreeNode.content,
                let worktreeLocation = worktreeTopic.location
            else { continue }

            let directory = topic.directory ?? worktreeLocation.directory
            let existingID = worktreeNode.children.first { childID in
                guard case .gitChanges(let existing) = nodes[childID]?.content else { return false }
                return (existing.directory ?? worktreeLocation.directory) == directory
            }

            var replacements: [NodeReplacement] = []
            if let oldParentID = parents[id], var oldParent = nodes[oldParentID] {
                oldParent.children.removeAll { $0 == id }
                if oldParent.children.isEmpty { oldParent.isCollapsed = false }
                replacements.append(NodeReplacement(id: oldParentID, node: oldParent))
            }

            if let existingID, var existingNode = nodes[existingID] {
                if !node.children.isEmpty {
                    existingNode.children.append(contentsOf: node.children)
                    existingNode.isCollapsed = false
                    replacements.append(NodeReplacement(id: existingID, node: existingNode))
                }
                replacements.append(NodeReplacement(id: id, node: nil))
                remapped[id] = existingID
            } else {
                let isOwnWorktree = topic.directory == nil || topic.directory == worktreeLocation.directory
                let insertIndex =
                    isOwnWorktree
                    ? 0
                    : worktreeNode.children.prefix(while: { nodes[$0]?.content.kind == .gitChanges }).count
                var movedNode = node
                if topic.directory == worktreeLocation.directory {
                    movedNode.content = .gitChanges(GitChangesTopic(baseCommit: topic.baseCommit))
                } else if !isOwnWorktree {
                    worktreeTopic.rememberExternalGitChanges(topic)
                    worktreeNode.content = .worktree(worktreeTopic)
                }
                worktreeNode.children.insert(id, at: insertIndex)
                worktreeNode.isCollapsed = false
                replacements.append(NodeReplacement(id: worktreeID, node: worktreeNode))
                if movedNode != node {
                    replacements.append(NodeReplacement(id: id, node: movedNode))
                }
            }
            apply(BoardEdit(nodes: replacements))
        }
        return remapped
    }
    fileprivate mutating func flattenProjectCheckouts() {
        let legacy = nodes.values.compactMap { node -> UUID? in
            guard case .worktree(let worktree) = node.content, worktree.isProjectDirectory == true else { return nil }
            return node.id
        }
        for id in legacy {
            guard var checkout = nodes[id], case .worktree(var worktree) = checkout.content else { continue }
            worktree.isProjectDirectory = nil
            checkout.content = .worktree(worktree)
            guard let ownerID = parents[id], var owner = nodes[ownerID],
                case .project(let project) = owner.content, let location = worktree.location,
                project.location?.directory == location.directory,
                project.location?.gitCommonDirectory == location.gitCommonDirectory,
                let index = owner.children.firstIndex(of: id)
            else {
                apply(BoardEdit(nodes: [NodeReplacement(id: id, node: checkout)]))
                continue
            }

            // Existing Agents still need a Worktree node for their inherited directory.
            var lifted: [UUID] = []
            var retained: [UUID] = []
            for child in checkout.children {
                if inheritsCheckoutForAgent(child) {
                    if retained.isEmpty { lifted.append(id) }
                    retained.append(child)
                } else {
                    lifted.append(child)
                }
            }
            checkout.children = retained
            owner.children.replaceSubrange(index...index, with: lifted)
            if owner.children.isEmpty { owner.isCollapsed = false }
            apply(
                BoardEdit(nodes: [
                    NodeReplacement(id: ownerID, node: owner),
                    NodeReplacement(id: id, node: retained.isEmpty ? nil : checkout),
                ]))
        }
    }

    private func inheritsCheckoutForAgent(_ root: UUID) -> Bool {
        var pending = [root]
        while let id = pending.popLast(), let node = nodes[id] {
            switch node.content {
            case .agent: return true
            case .project, .worktree: continue
            case .text, .branch, .gitChanges: pending.append(contentsOf: node.children)
            }
        }
        return false
    }

    fileprivate func removingLegacyBranchNodes() -> Self {
        guard nodes.values.contains(where: { if case .branch = $0.content { true } else { false } }) else {
            return self
        }
        var replacements: [NodeReplacement] = []
        var pending = roots.map { (id: $0.id, reference: String?.none) }
        while let item = pending.popLast() {
            guard let original = nodes[item.id] else { continue }
            var node = original
            var childReference = item.reference
            switch original.content {
            case .branch(let branch):
                childReference = branch.reference.isEmpty ? item.reference : branch.reference
                if parents[item.id] != nil {
                    pending.append(contentsOf: original.children.map { ($0, childReference) })
                    replacements.append(NodeReplacement(id: item.id, node: nil))
                    continue
                }
                // Keep the placement of any legacy Branch saved as a root.
                node.content = .text
                if node.text.isEmpty { node.text = branch.name }
            case .project:
                childReference = nil
            case .worktree(var worktree):
                if worktree.choice.baseReference == "HEAD", let reference = item.reference {
                    worktree.choice.base = reference
                    node.content = .worktree(worktree)
                }
                childReference = nil
            case .agent(var agent):
                if agent.worktreeChoice.baseReference == "HEAD", let reference = item.reference {
                    agent.worktreeChoice.base = reference
                    node.content = .agent(agent)
                }
            case .text, .gitChanges:
                break
            }
            pending.append(contentsOf: original.children.map { ($0, childReference) })
            node.children = expandingLegacyBranchChildren(original.children)
            if !original.children.isEmpty && node.children.isEmpty { node.isCollapsed = false }
            if node != original { replacements.append(NodeReplacement(id: item.id, node: node)) }
        }
        var board = self
        board.apply(BoardEdit(nodes: replacements))
        return board
    }

    private func expandingLegacyBranchChildren(_ children: [UUID]) -> [UUID] {
        var result: [UUID] = []
        var pending = Array(children.reversed())
        while let id = pending.popLast(), let child = nodes[id] {
            if case .branch = child.content {
                pending.append(contentsOf: child.children.reversed())
            } else {
                result.append(id)
            }
        }
        return result
    }
}
