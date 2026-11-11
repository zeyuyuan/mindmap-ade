import Foundation

public struct WorkspaceArchive: Codable, Sendable {
    private static let currentVersion = 7

    public var schemaVersion: Int
    public var boards: [MindMapBoard]
    public var cameras: [UUID: MapCamera]
    public var selectedBoardID: UUID?
    public var agentRuns: [AgentRun]?
    public var selections: [UUID: Set<UUID>]?
    public var agentPane: AgentPaneState?

    public init(
        boards: [MindMapBoard], cameras: [UUID: MapCamera] = [:], selectedBoardID: UUID? = nil,
        agentRuns: [AgentRun] = [], selections: [UUID: Set<UUID>] = [:], agentPane: AgentPaneState? = nil
    ) {
        schemaVersion = Self.currentVersion
        self.boards = boards
        self.cameras = cameras
        self.selectedBoardID = selectedBoardID
        self.agentRuns = agentRuns
        self.selections = selections
        self.agentPane = agentPane
    }

    public func validated() throws -> Self {
        guard (1...Self.currentVersion).contains(schemaVersion), Set(boards.map(\.id)).count == boards.count else {
            throw BoardValidationError.invalidStructure
        }
        for board in boards { _ = try board.validated() }
        guard
            cameras.values.allSatisfy({
                $0.scale.isFinite && (MapCamera.minimumScale...MapCamera.maximumScale).contains($0.scale)
                    && $0.translation.x.isFinite && $0.translation.y.isFinite
            })
        else { throw BoardValidationError.invalidStructure }
        var migrated = self
        if schemaVersion < 6 {
            migrated.boards = boards.map { original in
                var board = schemaVersion < 4 ? original.removingLegacyBranchNodes() : original
                board.flattenProjectCheckouts()
                return board
            }
        }
        migrated.schemaVersion = Self.currentVersion
        return migrated
    }
}

extension MindMapBoard {
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
            case .text, .branch: pending.append(contentsOf: node.children)
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
            case .text:
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
