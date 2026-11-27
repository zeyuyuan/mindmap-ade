import Foundation

extension MindMapBoard {
    /// Keep each selected branch once, including children hidden by a fold.
    public func copiedBranches(_ selection: Set<UUID>) -> MindMapBoard? {
        let ids = topLevelSelection(selection)
        guard let first = ids.first, let root = nodes[first] else { return nil }
        var copies: [NodeReplacement] = []
        var stack = ids
        while let id = stack.popLast(), let node = nodes[id] {
            copies.append(NodeReplacement(id: id, node: node))
            stack.append(contentsOf: node.children)
        }
        var forest = MindMapBoard(root: root)
        forest.apply(BoardEdit(nodes: copies, roots: ids.map { RootPlacement(id: $0) }))
        return forest
    }

    public var textOutline: String {
        var lines: [String] = []
        var stack = roots.reversed().map { ($0.id, 0) }
        while let (id, depth) = stack.popLast(), let node = nodes[id] {
            // Keep the external text representation bounded even for very deep trees.
            let indent = String(repeating: "\t", count: min(depth, 64))
            lines.append(indent + node.title.replacingOccurrences(of: "\n", with: "\n" + indent))
            stack.append(contentsOf: node.children.reversed().map { ($0, depth + 1) })
        }
        return lines.joined(separator: "\n")
    }

    public func pastingBranches(
        _ forest: MindMapBoard, under parent: UUID?, rootPositions: [UUID: CGPoint] = [:]
    ) throws -> (edit: BoardEdit, ids: [UUID]) {
        _ = try forest.validated()
        // A changes card tracks its own worktree. Copy its owner to retain that binding.
        guard !forest.roots.contains(where: { forest.nodes[$0.id]?.content.kind == .gitChanges }) else {
            throw BranchPasteError.missingCopiedWorktree
        }
        let ids = Dictionary(uniqueKeysWithValues: forest.nodes.keys.map { ($0, UUID()) })
        var changes = forest.nodes.values.map { original in
            var node = original
            node.id = ids[original.id]!
            node.children = original.children.map { ids[$0]! }
            switch node.content {
            case .agent(var agent):
                agent.sourceTextID = agent.sourceTextID.flatMap { ids[$0] }
                agent.isConfigured = false
                agent.progress = nil
                agent.worktreeChoice.pendingPlan = nil
                node.content = .agent(agent)
            case .worktree(var worktree):
                worktree.choice.pendingPlan = nil
                if let location = worktree.location {
                    worktree.creationCommit = nil
                    worktree.choice = WorktreeChoice(mode: .existing)
                    worktree.choice.existingDirectory = location.directory
                }
                node.content = .worktree(worktree)
            case .branch:
                node.text = original.title
                node.content = .text
            case .gitChanges(var topic):
                if topic.directory == nil, topic.baseCommit == nil,
                    let owner = forest.parents[original.id], case .worktree(let worktree) = forest.nodes[owner]?.content
                {
                    topic.baseCommit = worktree.creationCommit
                }
                node.content = .gitChanges(topic)
            case .text, .project: break
            }
            return NodeReplacement(id: node.id, node: node)
        }
        let copiedRoots = forest.roots.map { ids[$0.id]! }
        var rootsAfterPaste: [RootPlacement]?
        if let parent {
            guard var owner = nodes[parent] else { throw BoardValidationError.invalidStructure }
            owner.children.append(contentsOf: copiedRoots)
            owner.isCollapsed = false
            changes.append(NodeReplacement(id: parent, node: owner))
        } else {
            rootsAfterPaste =
                roots
                + forest.roots.map {
                    RootPlacement(id: ids[$0.id]!, position: rootPositions[$0.id] ?? $0.position)
                }
        }
        let edit = BoardEdit(nodes: changes, roots: rootsAfterPaste)
        let resources = changes.compactMap(\.node).filter {
            $0.id != parent
                && ($0.content.kind == .project || $0.content.kind == .worktree || $0.content.kind == .gitChanges)
        }
        if !resources.isEmpty {
            var candidate = self
            candidate.apply(edit)
            for node in resources where !candidate.permitsResource(node.content, under: candidate.parents[node.id]) {
                throw BranchPasteError.incompatibleLocation
            }
        }
        return (edit, copiedRoots)
    }

    /// The title takes the position of the first selected branch in document order.
    public func groupingBranches(_ selection: Set<UUID>) -> (edit: BoardEdit, id: UUID)? {
        let selected = topLevelSelection(selection)
        guard let first = selected.first,
            let insertion = inserting(
                parent: parents[first], after: first,
                position: roots.first(where: { $0.id == first })?.position ?? .zero)
        else { return nil }
        var candidate = self
        candidate.apply(insertion.edit)
        guard let move = candidate.movingBranches(Set(selected), to: insertion.id) else { return nil }
        let replaced = Set(move.nodes.map(\.id))
        return (
            BoardEdit(
                nodes: insertion.edit.nodes.filter { !replaced.contains($0.id) } + move.nodes,
                roots: move.roots ?? insertion.edit.roots), insertion.id
        )
    }
}

public enum BranchPasteError: Error {
    case incompatibleLocation, missingCopiedWorktree
}
