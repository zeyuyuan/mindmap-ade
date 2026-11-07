import AppKit
import QuartzCore
import Testing

@testable import MindMapCore
@testable import MindmapADE

@MainActor
struct RendererRegressionTests {
    private func connectors(in host: CALayer) -> [CAShapeLayer] {
        host.sublayers?.first?.sublayers?.flatMap { tree in
            (tree.sublayers ?? []).compactMap { $0 as? CAShapeLayer }
        } ?? []
    }

    private func segmentCount(in layers: [CAShapeLayer]) -> Int {
        var count = 0
        for layer in layers {
            layer.path?.applyWithBlock { element in
                if element.pointee.type == .moveToPoint { count += 1 }
            }
        }
        return count
    }

    @Test func wideBranchesBatchEveryConnectorAndReusePathsWhilePanning() throws {
        _ = NSApplication.shared
        let ids = (0..<10_000).map { _ in UUID() }
        var board = MindMapBoard(root: TextNode(id: ids[0]))
        board.apply(
            BoardEdit(
                nodes: ids.enumerated().map { index, id in
                    NodeReplacement(
                        id: id,
                        node: TextNode(id: id, text: "Topic", children: index == 0 ? Array(ids.dropFirst()) : []))
                }))
        let layout = TreeLayout.make(board: board, sizes: [:])
        let host = CALayer()
        let renderer = MapRenderer(layer: host)
        let viewport = CGRect(x: 0, y: 0, width: 1000, height: 640)
        let start = ContinuousClock.now
        renderer.render(
            board: board, layout: layout, camera: MapCamera(), viewport: viewport, selection: [], backingScale: 2)
        let elapsed = start.duration(to: .now)
        let original = connectors(in: host)
        #expect(original.count == 40)
        #expect(segmentCount(in: original) == 9_999)
        let paths = try original.map { (ObjectIdentifier($0), try #require($0.path)) }
        renderer.render(
            board: board, layout: layout, camera: MapCamera(translation: CGPoint(x: 1, y: 1)),
            viewport: viewport, selection: [], backingScale: 2)
        let panned = Dictionary(uniqueKeysWithValues: connectors(in: host).map { (ObjectIdentifier($0), $0) })
        for (id, path) in paths {
            #expect(panned[id]?.path === path)
        }
        board.apply(try #require(board.togglingCollapse(ids[0])))
        renderer.render(
            board: board, layout: TreeLayout.make(board: board, sizes: [:]), camera: MapCamera(),
            viewport: viewport, selection: [], backingScale: 2)
        #expect(connectors(in: host).isEmpty)
        print("10,000-node star: \(original.count) connector layers, 9,999 curves; initial layer update \(elapsed)")
    }

    @Test func aConnectorCrossingTheViewportSurvivesWhenBothTopicsAreCulled() throws {
        let parent = TextNode(text: "Parent")
        var board = MindMapBoard(root: parent)
        let child = try #require(board.inserting(text: "Child", parent: parent.id))
        board.apply(child.edit)
        let parentFrame = CGRect(x: 0, y: 0, width: 96, height: 36)
        let childFrame = CGRect(x: 1000, y: 1000, width: 96, height: 36)
        let bounds = parentFrame.union(childFrame)
        let layout = MapLayout(
            nodes: [
                parent.id: PlacedNode(
                    id: parent.id, rootID: parent.id, frame: parentFrame, subtreeBounds: bounds,
                    depth: 0, children: [child.id], descendantCount: 1),
                child.id: PlacedNode(
                    id: child.id, rootID: parent.id, frame: childFrame, subtreeBounds: childFrame,
                    depth: 1, children: [], descendantCount: 0),
            ], orderedIDs: [parent.id, child.id], roots: board.roots, bounds: bounds)
        let viewport = CGRect(x: 0, y: 0, width: 100, height: 100)
        let camera = MapCamera(translation: CGPoint(x: -450, y: -450))
        #expect(layout.visibleNodes(in: camera.worldRect(viewport)).isEmpty)
        let host = CALayer()
        let renderer = MapRenderer(layer: host)
        renderer.render(
            board: board, layout: layout, camera: camera, viewport: viewport, selection: [], backingScale: 2)
        #expect(segmentCount(in: connectors(in: host)) == 1)
    }
}
