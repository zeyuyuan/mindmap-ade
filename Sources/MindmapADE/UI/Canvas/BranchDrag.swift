import CoreGraphics
import Foundation
import MindMapCore

struct BranchDrag {
    enum Target {
        case root
        case child(UUID)
        case sibling(UUID, after: Bool)
        case invalid(ResourcePlacementProblem?)
    }

    let ids: Set<UUID>
    let rootIDs: Set<UUID>
    private let movedIDs: Set<UUID>
    private let resources: [UUID: BranchResources]
    var offset = CGSize.zero
    var target: Target?
    var didPan = false

    init?(selection: Set<UUID>, board: MindMapBoard) {
        let branches = board.topLevelSelection(selection)
        guard !branches.isEmpty else { return nil }
        ids = Set(branches)
        rootIDs = ids.intersection(board.roots.map(\.id))
        movedIDs = branches.reduce(into: Set<UUID>()) { $0.formUnion(board.descendants(of: $1)) }
        resources = board.resources(in: branches)
    }

    var preview: MapDragPreview {
        MapDragPreview(topLevelIDs: ids, rootIDs: rootIDs, movedIDs: movedIDs, offset: offset)
    }

    func target(at world: CGPoint, layout: MapLayout, board: MindMapBoard, scale: CGFloat) -> Target {
        let hit = layout.hitTest(world, excluding: ids)
        if let hit, movedIDs.contains(hit) { return .invalid(nil) }
        guard
            let node = hit.flatMap({ layout.nodes[$0] })
                ?? nearbyNode(at: world, layout: layout, board: board, scale: scale)
        else {
            return validated(.root, under: nil, in: board)
        }
        let relativeY = (world.y - node.frame.minY) / node.frame.height
        let parent = board.parents[node.id]
        if (parent != nil || hit != nil) && (relativeY < 0.25 || relativeY > 0.75) {
            return validated(.sibling(node.id, after: relativeY > 0.75), under: parent, in: board)
        }
        return validated(.child(node.id), under: node.id, in: board)
    }

    private func nearbyNode(at world: CGPoint, layout: MapLayout, board: MindMapBoard, scale: CGFloat) -> PlacedNode? {
        // Keep the reach comfortable at regular zoom and local to the branch at overview zoom.
        let dx = min(CanvasStyle.dropHorizontalReach / scale, MapMetrics.horizontalGap / 2)
        let dy = min(CanvasStyle.dropVerticalReach / scale, MapMetrics.verticalGap)
        let query = CGRect(x: world.x - dx, y: world.y - dy, width: dx * 2, height: dy * 2)
        var nearest: PlacedNode?
        var nearestDistance = CGFloat.infinity
        for id in layout.visibleNodes(in: query).reversed() {
            guard !movedIDs.contains(id), board.nodes[id] != nil, let node = layout.nodes[id] else { continue }
            let frame = node.frame
            let distance = hypot(
                max(frame.minX - world.x, world.x - frame.maxX, 0),
                max(frame.minY - world.y, world.y - frame.maxY, 0))
            guard distance < nearestDistance else { continue }
            nearest = node
            nearestDistance = distance
        }
        return nearest
    }

    private func validated(_ target: Target, under parent: UUID?, in board: MindMapBoard) -> Target {
        if let problem = board.resourceMoveProblem(for: resources, to: parent) {
            return .invalid(problem)
        }
        return target
    }
}
