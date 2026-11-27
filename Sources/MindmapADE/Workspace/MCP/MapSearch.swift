import Foundation
import MindMapCore

nonisolated enum MapSearch {
    struct Traversal: Sendable {
        private enum Level: Sendable {
            case roots(Int)
            case children(UUID, Int)
            case start(UUID)
        }

        // Keep only the next child index per ancestor. No copies of the board or its unvisited nodes.
        private var levels: [Level]
        fileprivate var buffered: Match?

        init(root: UUID?) {
            levels = root.map { [.start($0)] } ?? [.roots(0)]
        }

        mutating func next(in board: MindMapBoard) -> MapNode? {
            while let level = levels.popLast() {
                let id: UUID
                switch level {
                case .roots(let index):
                    guard board.roots.indices.contains(index) else { continue }
                    id = board.roots[index].id
                    if index + 1 < board.roots.count { levels.append(.roots(index + 1)) }
                case .children(let parent, let index):
                    guard let children = board.nodes[parent]?.children, children.indices.contains(index)
                    else { continue }
                    id = children[index]
                    if index + 1 < children.count { levels.append(.children(parent, index + 1)) }
                case .start(let root):
                    id = root
                }
                guard let node = board.nodes[id] else { continue }
                if !node.children.isEmpty { levels.append(.children(id, 0)) }
                return node
            }
            return nil
        }
    }

    struct Match: Identifiable, Sendable {
        let id: UUID
        let snippet: String
    }

    @concurrent static func page(
        for query: String, in board: MindMapBoard, from start: Traversal, pageSize: Int = 8
    ) async throws -> (matches: [Match], next: Traversal?) {
        var traversal = start
        var matches: [Match] = []
        if let first = traversal.buffered {
            matches.append(first)
            traversal.buffered = nil
        }
        while let node = traversal.next(in: board) {
            try Task.checkCancellation()
            guard let (source, range) = match(query, in: node) else { continue }
            let scalars = source.unicodeScalars
            let start =
                scalars.index(range.lowerBound, offsetBy: -64, limitedBy: scalars.startIndex)
                ?? scalars.startIndex
            let excerpt = scalars[start...].prefix(192)
            let leading = start == scalars.startIndex ? "" : "…"
            let trailing = excerpt.endIndex == scalars.endIndex ? "" : "…"
            let match = Match(id: node.id, snippet: leading + String(excerpt) + trailing)
            if matches.count == pageSize {
                traversal.buffered = match
                return (matches, traversal)
            }
            matches.append(match)
        }
        return (matches, nil)
    }

    private static func match(_ query: String, in node: MapNode) -> (String, Range<String.Index>)? {
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        let title = node.title
        if let range = title.range(of: query, options: options) { return (title, range) }
        let text = node.mapToolText
        if text != title, let range = text.range(of: query, options: options) { return (text, range) }
        if case .agent(let agent) = node.content, let progress = agent.progress,
            let range = progress.range(of: query, options: options)
        {
            return (progress, range)
        }
        return nil
    }
}

extension MapNode {
    nonisolated var mapToolText: String {
        switch content {
        case .text: text
        case .project(let project): project.details
        case .agent(let agent): agent.task
        case .worktree(let tree): tree.location?.directory ?? title
        case .gitChanges(let changes): changes.directory ?? title
        case .branch: title
        }
    }
}
