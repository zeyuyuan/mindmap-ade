import CoreGraphics
import Foundation
import Testing

@testable import MindMapCore

@Test func reversibleEditsPreserveNodeIdentity() throws {
    var board = MindMapBoard()
    let initial = board
    let root = try #require(board.roots.first?.id)
    let insertion = try #require(board.inserting(text: "子节点 👋", parent: root))
    let undo = board.apply(insertion.edit)
    #expect(board.nodes[insertion.id]?.text == "子节点 👋")
    #expect(board.parents[insertion.id] == root)
    _ = try board.validated()
    let redo = board.apply(undo)
    #expect(board == initial)
    board.apply(redo)
    #expect(board.nodes[insertion.id] != nil)
}

@Test func movingBranchesRejectsCyclesAndPreservesOrder() throws {
    var board = MindMapBoard()
    let root = board.roots[0].id
    let a = try #require(board.inserting(text: "A", parent: root))
    board.apply(a.edit)
    let b = try #require(board.inserting(text: "B", parent: root))
    board.apply(b.edit)
    let child = try #require(board.inserting(text: "Child", parent: a.id))
    board.apply(child.edit)
    #expect(board.moving(root, to: child.id) == nil)
    #expect(board.moving(a.id, to: a.id) == nil)
    let before = board
    let move = try #require(board.moving(b.id, to: root, at: 0))
    let inverse = board.apply(move)
    #expect(board.nodes[root]?.children == [b.id, a.id])
    _ = try board.validated()
    board.apply(inverse)
    #expect(board == before)
    board.apply(try #require(board.moving(a.id, to: nil, position: CGPoint(x: 500, y: 200))))
    #expect(board.roots.count == 2)
    #expect(board.parents[child.id] == a.id)
    _ = try board.validated()
}

@Test func overlappingDeletionAndLastRootHaveExactUndo() throws {
    var board = MindMapBoard()
    let root = board.roots[0].id
    let child = try #require(board.inserting(parent: root))
    board.apply(child.edit)
    let grandchild = try #require(board.inserting(parent: child.id))
    board.apply(grandchild.edit)
    let before = board
    let inverse = board.apply(try #require(board.deleting([root, child.id, grandchild.id])))
    #expect(board.nodes.count == 1)
    #expect(board.roots.count == 1)
    #expect(board.roots[0].id != root)
    _ = try board.validated()
    board.apply(inverse)
    #expect(board == before)
}

@Test func variableSizedSubtreesDoNotOverlap() throws {
    var board = MindMapBoard()
    let root = board.roots[0].id
    var children: [UUID] = []
    for text in ["Short", "Long\nMultiline\nTopic", "Last"] {
        let child = try #require(board.inserting(text: text, parent: root))
        board.apply(child.edit)
        children.append(child.id)
    }
    let sizes = [
        root: CGSize(width: 130, height: 40), children[0]: CGSize(width: 96, height: 36),
        children[1]: CGSize(width: 240, height: 140), children[2]: CGSize(width: 120, height: 36),
    ]
    let layout = TreeLayout.make(board: board, sizes: sizes)
    let frames = try children.map { try #require(layout.nodes[$0]?.frame) }
    #expect(frames[0].maxY + MapMetrics.verticalGap <= frames[1].minY)
    #expect(frames[1].maxY + MapMetrics.verticalGap <= frames[2].minY)
    #expect(frames[0].minX == 130 + MapMetrics.horizontalGap)
    #expect(layout.nodes[root]?.subtreeBounds.contains(frames[1]) == true)
    #expect(layout.hitTest(CGPoint(x: frames[1].midX, y: frames[1].midY)) == children[1])
    #expect(layout.visibleNodes(in: frames[1].insetBy(dx: 1, dy: 1)) == [children[1]])
    board.apply(try #require(board.togglingCollapse(root)))
    let folded = TreeLayout.make(board: board, sizes: sizes)
    #expect(folded.nodes.count == 1)
    #expect(board.nodes.count == 4)
}

@Test func cameraKeepsZoomAnchorAndCoordinatesStable() {
    var camera = MapCamera(scale: 0.8, translation: CGPoint(x: -340, y: 120))
    let anchor = CGPoint(x: 420, y: 280)
    let world = camera.worldPoint(anchor)
    camera.zoom(to: 2.4, around: anchor)
    let projected = camera.viewPoint(world)
    #expect(abs(projected.x - anchor.x) < 0.000_001)
    #expect(abs(projected.y - anchor.y) < 0.000_001)
    camera.zoom(to: 0, around: anchor)
    #expect(camera.scale == MapCamera.minimumScale)
    camera.zoom(to: 100, around: anchor)
    #expect(camera.scale == 4)
}

@Test func archiveRoundTripsAndRejectsBrokenGraphs() throws {
    let board = MindMapBoard(name: "Persistence")
    let archive = WorkspaceArchive(boards: [board], cameras: [board.id: MapCamera(scale: 1.5)])
    let data = try JSONEncoder().encode(archive)
    let decoded = try JSONDecoder().decode(WorkspaceArchive.self, from: data).validated()
    #expect(decoded.boards == [board])
    #expect(decoded.cameras[board.id]?.scale == 1.5)
    var invalid = board
    invalid.apply(BoardEdit(nodes: [NodeReplacement(id: board.roots[0].id, node: nil)]))
    #expect(throws: BoardValidationError.self) { try invalid.validated() }
    var cycle = board
    let id = board.roots[0].id
    cycle.apply(BoardEdit(nodes: [NodeReplacement(id: id, node: TextNode(id: id, children: [id]))]))
    #expect(throws: BoardValidationError.self) { try cycle.validated() }
    var future = archive
    future.schemaVersion = 2
    #expect(throws: BoardValidationError.self) { try future.validated() }
}

@Test func tenThousandDeepNodesUseIterativeLayout() throws {
    let ids = (0..<10_000).map { _ in UUID() }
    var board = MindMapBoard(root: TextNode(id: ids[0]))
    let changes = ids.enumerated().map { index, id in
        NodeReplacement(
            id: id,
            node: TextNode(id: id, text: "Topic \(index)", children: index + 1 < ids.count ? [ids[index + 1]] : []))
    }
    board.apply(BoardEdit(nodes: changes))
    _ = try board.validated()
    let clock = ContinuousClock()
    let start = clock.now
    let layout = TreeLayout.make(board: board, sizes: [:])
    let elapsed = start.duration(to: clock.now)
    #expect(layout.nodes.count == 10_000)
    #expect(layout.nodes[ids[9_999]]?.depth == 9_999)
    print("10,000-node iterative layout: \(elapsed)")
    let inverse = board.apply(try #require(board.deleting(Set(ids))))
    #expect(board.nodes.count == 1)
    board.apply(inverse)
    #expect(board.nodes.count == 10_000)
    _ = try board.validated()
}

@Test func fittingLargeContentIncludesEveryEdgeAndPersistsFractionalZoom() throws {
    let content = CGRect(x: -100, y: -200_000, width: 1500, height: 500_000)
    let viewport = CGRect(x: 0, y: 0, width: 800, height: 500)
    var camera = MapCamera()
    camera.fit(content, in: viewport, padding: 64)
    #expect(camera.scale < 0.01)
    let projected = CGRect(
        origin: camera.viewPoint(content.origin),
        size: CGSize(width: content.width * camera.scale, height: content.height * camera.scale))
    #expect(viewport.insetBy(dx: 63, dy: 63).contains(projected))
    let board = MindMapBoard()
    let archive = WorkspaceArchive(boards: [board], cameras: [board.id: camera])
    _ = try JSONDecoder().decode(WorkspaceArchive.self, from: JSONEncoder().encode(archive)).validated()
}

@Test func subtreeCullingMatchesGeometryAcrossAThousandNodes() throws {
    let ids = (0..<1000).map { _ in UUID() }
    var board = MindMapBoard(root: TextNode(id: ids[0]))
    board.apply(
        BoardEdit(
            nodes: ids.enumerated().map { index, id in
                NodeReplacement(id: id, node: TextNode(id: id, children: Array(ids.dropFirst(index * 4 + 1).prefix(4))))
            }))
    let secondRoot = try #require(board.inserting(parent: nil, position: CGPoint(x: -800, y: -1200)))
    board.apply(secondRoot.edit)
    let sizes = Dictionary(
        uniqueKeysWithValues: ids.enumerated().map { index, id in
            (id, CGSize(width: 96 + index % 4 * 40, height: 36 + index % 3 * 16))
        })
    let layout = TreeLayout.make(board: board, sizes: sizes)
    for y in stride(from: -1600, through: 1600, by: 160) {
        let viewport = CGRect(x: -900, y: y, width: 2400, height: 320)
        let expected = Set(layout.nodes.values.filter { $0.frame.intersects(viewport) }.map(\.id))
        #expect(Set(layout.visibleNodes(in: viewport)) == expected)
    }
    let unchanged = layout.nodes[secondRoot.id]?.frame
    board.apply(try #require(board.inserting(parent: ids[0])).edit)
    #expect(TreeLayout.make(board: board, sizes: sizes).nodes[secondRoot.id]?.frame == unchanged)
}
