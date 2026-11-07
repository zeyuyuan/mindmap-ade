import CoreGraphics
import Foundation

public enum MapMetrics {
    public static let fontSize: CGFloat = 13
    public static let minimumNodeWidth: CGFloat = 96
    public static let maximumTextWidth: CGFloat = 220
    public static let minimumNodeHeight: CGFloat = 36
    public static let maximumTextHeight: CGFloat = 144
    public static let horizontalPadding: CGFloat = 12
    public static let verticalPadding: CGFloat = 8
    public static let horizontalGap: CGFloat = 64
    public static let verticalGap: CGFloat = 16
    public static let rootGap: CGFloat = 64
}

public struct PlacedNode: Sendable {
    public let id: UUID
    public let rootID: UUID
    public let frame: CGRect
    public let subtreeBounds: CGRect
    public let depth: Int
    public let children: [UUID]
    public let descendantCount: Int
}

public struct MapLayout: Sendable {
    public var nodes: [UUID: PlacedNode]
    public var orderedIDs: [UUID]
    public var roots: [RootPlacement]
    public var bounds: CGRect

    public static let empty = MapLayout(nodes: [:], orderedIDs: [], roots: [], bounds: .zero)

    /// Walks subtree bounds rather than scanning every node during pointer and camera updates.
    public func visibleNodes(in rect: CGRect, minimumSubtreeExtent: CGFloat = 0) -> [UUID] {
        var pending = roots.reversed().map(\.id)
        var result: [UUID] = []
        while let id = pending.popLast() {
            guard let node = nodes[id], node.subtreeBounds.intersects(rect) else { continue }
            if node.frame.intersects(rect) { result.append(id) }
            if max(node.subtreeBounds.width, node.subtreeBounds.height) >= minimumSubtreeExtent {
                pending.append(contentsOf: node.children.reversed())
            }
        }
        return result
    }

    public func hitTest(_ point: CGPoint, excluding excluded: Set<UUID> = []) -> UUID? {
        let rect = CGRect(x: point.x - 1, y: point.y - 1, width: 2, height: 2)
        return visibleNodes(in: rect).last { !excluded.contains($0) && nodes[$0]?.frame.contains(point) == true }
    }
}

public enum TreeLayout {
    /// Iterative passes support very deep maps without recursive stack growth.
    public static func make(board: MindMapBoard, sizes: [UUID: CGSize]) -> MapLayout {
        // Include folded branches once per snapshot; pointer and camera updates reuse these totals.
        var allIDs: [UUID] = []
        var uncounted = board.roots.map(\.id)
        while let id = uncounted.popLast() {
            guard let node = board.nodes[id] else { continue }
            allIDs.append(id)
            uncounted.append(contentsOf: node.children)
        }
        var descendantCounts: [UUID: Int] = [:]
        for id in allIDs.reversed() {
            descendantCounts[id] = board.nodes[id]?.children.reduce(0) { $0 + 1 + (descendantCounts[$1] ?? 0) } ?? 0
        }

        var traversal: [(UUID, UUID, Int)] = []
        var pending = board.roots.reversed().map { ($0.id, $0.id, 0) }
        while let (id, root, depth) = pending.popLast() {
            guard let node = board.nodes[id] else { continue }
            traversal.append((id, root, depth))
            if !node.isCollapsed {
                pending.append(contentsOf: node.children.reversed().map { ($0, root, depth + 1) })
            }
        }

        let fallback = CGSize(width: MapMetrics.minimumNodeWidth, height: MapMetrics.minimumNodeHeight)
        var heights: [UUID: CGFloat] = [:]
        for (id, _, _) in traversal.reversed() {
            guard let node = board.nodes[id] else { continue }
            let children = node.isCollapsed ? [] : node.children
            let total =
                children.reduce(CGFloat.zero) { $0 + (heights[$1] ?? fallback.height) }
                + CGFloat(max(0, children.count - 1)) * MapMetrics.verticalGap
            heights[id] = max((sizes[id] ?? fallback).height, total)
        }

        var frames: [UUID: CGRect] = [:]
        for root in board.roots {
            let size = sizes[root.id] ?? fallback
            frames[root.id] = CGRect(origin: root.position, size: size)
        }
        for (id, _, _) in traversal {
            guard let frame = frames[id], let node = board.nodes[id], !node.isCollapsed else { continue }
            let total =
                node.children.reduce(CGFloat.zero) { $0 + (heights[$1] ?? fallback.height) }
                + CGFloat(max(0, node.children.count - 1)) * MapMetrics.verticalGap
            var y = frame.midY - total / 2
            for child in node.children {
                let size = sizes[child] ?? fallback
                let height = heights[child] ?? size.height
                frames[child] = CGRect(
                    x: frame.maxX + MapMetrics.horizontalGap, y: y + (height - size.height) / 2,
                    width: size.width, height: size.height
                )
                y += height + MapMetrics.verticalGap
            }
        }

        var placed: [UUID: PlacedNode] = [:]
        for (id, root, depth) in traversal.reversed() {
            guard let frame = frames[id], let node = board.nodes[id] else { continue }
            let children = node.isCollapsed ? [] : node.children
            var bounds = frame
            for child in children {
                if let subtree = placed[child]?.subtreeBounds { bounds = bounds.union(subtree) }
            }
            placed[id] = PlacedNode(
                id: id, rootID: root, frame: frame, subtreeBounds: bounds, depth: depth, children: children,
                descendantCount: descendantCounts[id] ?? 0
            )
        }
        let bounds = board.roots.compactMap { placed[$0.id]?.subtreeBounds }.reduce(CGRect.null) { $0.union($1) }
        return MapLayout(
            nodes: placed, orderedIDs: traversal.map { $0.0 }, roots: board.roots,
            bounds: bounds.isNull ? .zero : bounds
        )
    }
}

public struct MapCamera: Codable, Equatable, Sendable {
    public static let minimumScale: CGFloat = 0.000_001
    public static let maximumScale: CGFloat = 4
    public var scale: CGFloat
    public var translation: CGPoint

    public init(scale: CGFloat = 1, translation: CGPoint = .zero) {
        self.scale = scale
        self.translation = translation
    }

    public func viewPoint(_ world: CGPoint) -> CGPoint {
        CGPoint(x: world.x * scale + translation.x, y: world.y * scale + translation.y)
    }

    public func worldPoint(_ view: CGPoint) -> CGPoint {
        CGPoint(x: (view.x - translation.x) / scale, y: (view.y - translation.y) / scale)
    }

    public func worldRect(_ view: CGRect) -> CGRect {
        CGRect(origin: worldPoint(view.origin), size: CGSize(width: view.width / scale, height: view.height / scale))
    }

    public mutating func zoom(to value: CGFloat, around anchor: CGPoint) {
        let world = worldPoint(anchor)
        scale = min(Self.maximumScale, max(Self.minimumScale, value))
        translation = CGPoint(x: anchor.x - world.x * scale, y: anchor.y - world.y * scale)
    }

    public mutating func fit(_ content: CGRect, in viewport: CGRect, padding: CGFloat, maximumZoom: CGFloat = 1.5) {
        let available = viewport.insetBy(dx: padding, dy: padding)
        guard available.width > 0, available.height > 0, !content.isNull else { return }
        let target = min(available.width / max(content.width, 1), available.height / max(content.height, 1))
        scale = min(maximumZoom, max(Self.minimumScale, target))
        translation = CGPoint(x: viewport.midX - content.midX * scale, y: viewport.midY - content.midY * scale)
    }
}
