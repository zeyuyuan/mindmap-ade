import CoreGraphics
import Foundation

public struct MapNode: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var text: String
    public var children: [UUID]
    public var isCollapsed: Bool
    public var content: NodeContent

    public init(
        id: UUID = UUID(), text: String = "", children: [UUID] = [], isCollapsed: Bool = false,
        content: NodeContent = .text
    ) {
        self.id = id
        self.text = text
        self.children = children
        self.isCollapsed = isCollapsed
        self.content = content
    }

    private enum CodingKeys: String, CodingKey { case id, text, children, isCollapsed, content }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        text = try values.decode(String.self, forKey: .text)
        children = try values.decode([UUID].self, forKey: .children)
        isCollapsed = try values.decode(Bool.self, forKey: .isCollapsed)
        content = try values.decodeIfPresent(NodeContent.self, forKey: .content) ?? .text
    }

    public var title: String {
        switch content {
        case .text:
            return text.isEmpty ? "New topic" : text
        case .project(let value):
            let name = value.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty { return name }
            let directory = value.location?.directory ?? value.directory
            return directory.isEmpty ? "Choose a project" : URL(fileURLWithPath: directory).lastPathComponent
        case .branch(let value):
            return value.name.isEmpty ? "Choose a branch" : value.name
        case .worktree(let value):
            if let location = value.location { return location.revisionLabel }
            if value.choice.mode == .existing { return "Choose a worktree" }
            let branch = value.choice.branch.trimmingCharacters(in: .whitespacesAndNewlines)
            return branch.isEmpty ? "New Worktree" : branch
        case .agent(let value):
            let name = value.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty { return name }
            let line = value.task.split(whereSeparator: \.isNewline).first?.trimmingCharacters(in: .whitespaces)
            return line.flatMap { $0.isEmpty ? nil : String($0.prefix(100)) } ?? "New conversation"
        }
    }

    public var detail: String? {
        switch content {
        case .text, .branch: nil
        case .project(let value):
            value.location == nil ? "Draft" : nil
        case .worktree(let value):
            value.location.map { $0.isPrimary ? "Main worktree · \($0.name)" : "Worktree · \($0.name)" }
                ?? "Worktree · Draft"
        case .agent(let value):
            value.isConfigured ? "Agent · \(value.cli.title)" : "Agent · Draft"
        }
    }

}

public struct RootPlacement: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var position: CGPoint

    public init(id: UUID, position: CGPoint = .zero) {
        self.id = id
        self.position = position
    }
}

public struct NodeReplacement: Sendable {
    public let id: UUID
    public let node: MapNode?

    public init(id: UUID, node: MapNode?) {
        self.id = id
        self.node = node
    }
}

/// An undoable delta. Removed subtrees are retained only by their undo entry.
public struct BoardEdit: Sendable {
    public var nodes: [NodeReplacement]
    public var roots: [RootPlacement]?
    public var name: String?

    public init(nodes: [NodeReplacement] = [], roots: [RootPlacement]? = nil, name: String? = nil) {
        self.nodes = nodes
        self.roots = roots
        self.name = name
    }
}

public enum BoardValidationError: Error, Equatable {
    case invalidStructure
}

public struct MindMapBoard: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public private(set) var roots: [RootPlacement]
    public private(set) var nodes: [UUID: MapNode]
    private var parentIndex: [UUID: UUID] = [:]

    private enum CodingKeys: String, CodingKey { case id, name, roots, nodes }

    public init(id: UUID = UUID(), name: String = "Untitled", root: MapNode = MapNode()) {
        self.id = id
        self.name = name
        roots = [RootPlacement(id: root.id)]
        nodes = [root.id: root]
        for child in root.children { parentIndex[child] = root.id }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        roots = try container.decode([RootPlacement].self, forKey: .roots)
        nodes = try container.decode([UUID: MapNode].self, forKey: .nodes)
        for node in nodes.values {
            for child in node.children { parentIndex[child] = node.id }
        }
    }

    public var parents: [UUID: UUID] { parentIndex }

    public func descendants(of id: UUID) -> Set<UUID> {
        var result = Set<UUID>()
        var pending = [id]
        while let current = pending.popLast() {
            guard result.insert(current).inserted, let node = nodes[current] else { continue }
            pending.append(contentsOf: node.children)
        }
        return result
    }

    public func validated() throws -> Self {
        guard !roots.isEmpty, nodes.count <= 100_000 else { throw BoardValidationError.invalidStructure }
        var visited = Set<UUID>()
        var pending = roots.map(\.id)
        guard roots.allSatisfy({ $0.position.x.isFinite && $0.position.y.isFinite }) else {
            throw BoardValidationError.invalidStructure
        }
        while let id = pending.popLast() {
            guard visited.insert(id).inserted, let node = nodes[id], node.id == id else {
                throw BoardValidationError.invalidStructure
            }
            pending.append(contentsOf: node.children)
        }
        guard visited.count == nodes.count else { throw BoardValidationError.invalidStructure }
        return self
    }

    @discardableResult
    public mutating func apply(_ edit: BoardEdit) -> BoardEdit {
        let inverse = BoardEdit(
            nodes: edit.nodes.map { NodeReplacement(id: $0.id, node: nodes[$0.id]) },
            roots: edit.roots == nil ? nil : roots,
            name: edit.name == nil ? nil : name
        )
        let linkChanges = edit.nodes.filter { (nodes[$0.id]?.children ?? []) != ($0.node?.children ?? []) }
        for replacement in linkChanges {
            for child in nodes[replacement.id]?.children ?? [] where parentIndex[child] == replacement.id {
                parentIndex.removeValue(forKey: child)
            }
        }
        for replacement in edit.nodes { nodes[replacement.id] = replacement.node }
        for replacement in linkChanges {
            for child in replacement.node?.children ?? [] { parentIndex[child] = replacement.id }
        }
        if let value = edit.roots { roots = value }
        if let value = edit.name { name = value }
        return inverse
    }

    public func inserting(
        text: String = "", parent: UUID?, after sibling: UUID? = nil, position: CGPoint = .zero
    ) -> (edit: BoardEdit, id: UUID)? {
        inserting(MapNode(text: text), parent: parent, after: sibling, position: position)
    }

    public func inserting(
        _ node: MapNode, parent: UUID?, after sibling: UUID? = nil, position: CGPoint = .zero
    ) -> (edit: BoardEdit, id: UUID)? {
        guard nodes[node.id] == nil, node.children.isEmpty, permitsResource(node.content, under: parent) else {
            return nil
        }
        var changes = [NodeReplacement(id: node.id, node: node)]
        if let parent {
            guard var owner = nodes[parent] else { return nil }
            let index = sibling.flatMap { owner.children.firstIndex(of: $0).map { $0 + 1 } } ?? owner.children.count
            owner.children.insert(node.id, at: index)
            owner.isCollapsed = false
            changes.append(NodeReplacement(id: parent, node: owner))
            return (BoardEdit(nodes: changes), node.id)
        }
        var nextRoots = roots
        let index = sibling.flatMap { id in nextRoots.firstIndex { $0.id == id }.map { $0 + 1 } } ?? nextRoots.count
        nextRoots.insert(RootPlacement(id: node.id, position: position), at: index)
        return (BoardEdit(nodes: changes, roots: nextRoots), node.id)
    }

    public func replacingText(_ id: UUID, with text: String) -> BoardEdit? {
        guard var node = nodes[id], node.content.kind == .text, node.text != text else { return nil }
        node.text = text
        return BoardEdit(nodes: [NodeReplacement(id: id, node: node)])
    }

    public func replacingContent(_ id: UUID, with content: NodeContent) -> BoardEdit? {
        guard var node = nodes[id], node.content.kind == content.kind, node.content != content else { return nil }
        node.content = content
        return BoardEdit(nodes: [NodeReplacement(id: id, node: node)])
    }

    /// Insert a configured resource in the child's existing slot, including root placement.
    public func insertingParent(_ parent: MapNode, above childID: UUID) -> BoardEdit? {
        guard nodes[parent.id] == nil, parent.children.isEmpty,
            canInsertResourceParent(parent.content, above: childID)
        else { return nil }
        var parent = parent
        parent.children = [childID]
        parent.isCollapsed = false
        var changes = [NodeReplacement(id: parent.id, node: parent)]
        if let ownerID = parents[childID], var owner = nodes[ownerID],
            let index = owner.children.firstIndex(of: childID)
        {
            owner.children[index] = parent.id
            changes.append(NodeReplacement(id: ownerID, node: owner))
            return BoardEdit(nodes: changes)
        }
        guard let index = roots.firstIndex(where: { $0.id == childID }) else { return nil }
        var placements = roots
        placements[index].id = parent.id
        return BoardEdit(nodes: changes, roots: placements)
    }

    public func togglingCollapse(_ id: UUID) -> BoardEdit? {
        guard var node = nodes[id], !node.children.isEmpty else { return nil }
        node.isCollapsed.toggle()
        return BoardEdit(nodes: [NodeReplacement(id: id, node: node)])
    }

    public func deleting(_ ids: Set<UUID>) -> BoardEdit? {
        let selected = ids.intersection(nodes.keys)
        guard !selected.isEmpty else { return nil }
        var removed = Set<UUID>()
        var pending = Array(selected)
        while let id = pending.popLast() {
            guard removed.insert(id).inserted else { continue }
            pending.append(contentsOf: nodes[id]?.children ?? [])
        }
        let parentIndex = parents
        var changedParents = Set<UUID>()
        for id in removed {
            if let parent = parentIndex[id], !removed.contains(parent) { changedParents.insert(parent) }
        }
        var changes = removed.map { NodeReplacement(id: $0, node: nil) }
        for id in changedParents {
            guard var node = nodes[id] else { continue }
            node.children.removeAll { removed.contains($0) }
            if node.children.isEmpty { node.isCollapsed = false }
            changes.append(NodeReplacement(id: id, node: node))
        }
        var nextRoots = roots.filter { !removed.contains($0.id) }
        if nextRoots.isEmpty {
            let root = MapNode()
            changes.append(NodeReplacement(id: root.id, node: root))
            nextRoots = [RootPlacement(id: root.id, position: roots.first?.position ?? .zero)]
        }
        return BoardEdit(nodes: changes, roots: nextRoots)
    }

    /// A nil parent detaches the subtree as a new root; indices refer to the destination after removal.
    public func moving(_ id: UUID, to parent: UUID?, at index: Int? = nil, position: CGPoint = .zero) -> BoardEdit? {
        guard nodes[id] != nil else { return nil }
        if let parent {
            guard nodes[parent] != nil, !descendants(of: id).contains(parent) else { return nil }
        }
        let oldParent = parents[id]
        guard oldParent == parent || resourceMoveProblem(for: resources(in: [id]), to: parent) == nil else {
            return nil
        }
        var changed: [UUID: MapNode] = [:]
        if let oldParent, var node = nodes[oldParent] {
            node.children.removeAll { $0 == id }
            changed[oldParent] = node
        }
        var nextRoots = roots.filter { $0.id != id }
        if let parent, var owner = changed[parent] ?? nodes[parent] {
            owner.children.insert(id, at: min(max(0, index ?? owner.children.count), owner.children.count))
            owner.isCollapsed = false
            changed[parent] = owner
        } else {
            let target = min(max(0, index ?? nextRoots.count), nextRoots.count)
            nextRoots.insert(RootPlacement(id: id, position: position), at: target)
        }
        return BoardEdit(
            nodes: changed.map { NodeReplacement(id: $0.key, node: $0.value) },
            roots: nextRoots == roots ? nil : nextRoots
        )
    }

    public func movingRoot(_ id: UUID, to position: CGPoint) -> BoardEdit? {
        guard let index = roots.firstIndex(where: { $0.id == id }), roots[index].position != position else {
            return nil
        }
        var next = roots
        next[index].position = position
        return BoardEdit(roots: next)
    }

    /// Returns the selected branches in document order, omitting descendants of selected ancestors.
    public func topLevelSelection(_ selection: Set<UUID>) -> [UUID] {
        guard !selection.isEmpty else { return [] }
        if selection.count == 1, let id = selection.first { return nodes[id] == nil ? [] : [id] }
        var result: [UUID] = []
        var pending = roots.reversed().map(\.id)
        while let id = pending.popLast() {
            guard let node = nodes[id] else { continue }
            if selection.contains(id) {
                result.append(id)
            } else {
                pending.append(contentsOf: node.children.reversed())
            }
        }
        return result
    }

    /// Moves a selection atomically; nil-parent drops preserve the positions and order of existing roots.
    public func movingBranches(
        _ selection: Set<UUID>, to parent: UUID?, at index: Int? = nil, positions: [UUID: CGPoint] = [:]
    ) -> BoardEdit? {
        let ids = topLevelSelection(selection)
        guard !ids.isEmpty else { return nil }
        let moving = Set(ids)
        if let parent {
            guard nodes[parent] != nil else { return nil }
            var ancestor: UUID? = parent
            while let current = ancestor {
                guard !moving.contains(current) else { return nil }
                ancestor = parentIndex[current]
            }
        }
        let reparented = ids.filter { parentIndex[$0] != parent }
        guard resourceMoveProblem(for: resources(in: reparented), to: parent) == nil else { return nil }
        let oldParents = Set(ids.compactMap { parentIndex[$0] })
        var replacements: [UUID: MapNode] = [:]
        for id in oldParents {
            guard var node = nodes[id] else { continue }
            node.children.removeAll { moving.contains($0) }
            if node.children.isEmpty { node.isCollapsed = false }
            replacements[id] = node
        }
        var nextRoots = roots
        if let parent, var owner = replacements[parent] ?? nodes[parent] {
            let destination = min(max(0, index ?? owner.children.count), owner.children.count)
            owner.children.insert(contentsOf: ids, at: destination)
            owner.isCollapsed = false
            replacements[parent] = owner
            nextRoots.removeAll { moving.contains($0.id) }
        } else if let index {
            nextRoots.removeAll { moving.contains($0.id) }
            let originalPositions = Dictionary(uniqueKeysWithValues: roots.map { ($0.id, $0.position) })
            let placements = ids.map {
                RootPlacement(id: $0, position: positions[$0] ?? originalPositions[$0] ?? .zero)
            }
            nextRoots.insert(contentsOf: placements, at: min(max(0, index), nextRoots.count))
        } else {
            let existingRoots = Set(roots.map(\.id))
            for offset in nextRoots.indices where moving.contains(nextRoots[offset].id) {
                if let position = positions[nextRoots[offset].id] { nextRoots[offset].position = position }
            }
            for id in ids where !existingRoots.contains(id) {
                nextRoots.append(RootPlacement(id: id, position: positions[id] ?? .zero))
            }
        }
        let changes = replacements.compactMap { id, node in
            nodes[id] == node ? nil : NodeReplacement(id: id, node: node)
        }
        guard !changes.isEmpty || nextRoots != roots else { return nil }
        return BoardEdit(nodes: changes, roots: nextRoots == roots ? nil : nextRoots)
    }
}
