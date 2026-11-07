import AppKit
import MindMapCore
import QuartzCore

struct MapDragPreview {
    let topLevelIDs: Set<UUID>
    let rootIDs: Set<UUID>
    let movedIDs: Set<UUID>
    let offset: CGSize
}

final class TopicLayer {
    let layer = CALayer()
    private let text = TopicTextRenderer()
    private let disclosureLayer = CAShapeLayer()
    private let disclosureGlyph = CAShapeLayer()
    private let disclosureCount = TopicTextRenderer()
    private var previousText: String?
    private var previousRoot = false
    private var previousColor: CGColor?
    private var attributedTitle = NSAttributedString(string: "")
    private var previousCount = -1
    private var previousCountColor: CGColor?
    private var attributedCount = NSAttributedString(string: "")

    init() {
        layer.anchorPoint = .zero
        layer.cornerRadius = CanvasStyle.nodeRadius
        disclosureLayer.lineWidth = CanvasStyle.borderWidth
        disclosureGlyph.fillColor = nil
        disclosureGlyph.lineWidth = CanvasStyle.edgeWidth
        disclosureGlyph.lineCap = .round
        layer.addSublayer(text.layer)
        layer.addSublayer(disclosureLayer)
        layer.addSublayer(disclosureGlyph)
        disclosureLayer.addSublayer(disclosureCount.layer)
    }

    func configure(
        node: TextNode, descendantCount: Int, root: Bool, selected: Bool, scale: CGFloat, backingScale: CGFloat
    ) {
        let title = node.text.isEmpty ? "New topic" : node.text
        let foreground = (node.text.isEmpty ? NSColor.secondaryLabelColor : .labelColor).cgColor
        if previousText != title || previousRoot != root || previousColor != foreground {
            attributedTitle = NSAttributedString(
                string: title,
                attributes: [
                    .font: CanvasStyle.font(root: root), .foregroundColor: NSColor(cgColor: foreground) ?? .labelColor,
                ])
            previousText = title
            previousRoot = root
            previousColor = foreground
        }
        let bounds = layer.bounds
        text.layer.isHidden = scale < CanvasStyle.textDetailScale
        text.configure(
            attributedTitle,
            size: CGSize(width: bounds.width - MapMetrics.horizontalPadding * 2, height: bounds.height),
            contentsScale: backingScale * max(1, ceil(scale)))
        layer.backgroundColor = NSColor.controlBackgroundColor.cgColor
        layer.borderColor =
            (selected ? NSColor.controlAccentColor : root ? NSColor.secondaryLabelColor : .separatorColor).cgColor
        layer.borderWidth = (selected ? CanvasStyle.selectedBorderWidth : CanvasStyle.borderWidth) / max(scale, 0.5)
        let hidesDisclosure = node.children.isEmpty || scale < CanvasStyle.textDetailScale
        disclosureLayer.isHidden = hidesDisclosure
        disclosureGlyph.isHidden = hidesDisclosure || node.isCollapsed
        disclosureCount.layer.isHidden = hidesDisclosure || !node.isCollapsed
        disclosureLayer.fillColor = NSColor.controlBackgroundColor.cgColor
        disclosureLayer.strokeColor = NSColor.separatorColor.cgColor
        disclosureGlyph.strokeColor = NSColor.secondaryLabelColor.cgColor
        if !hidesDisclosure {
            let frame = CanvasStyle.disclosureFrame(for: bounds, hiddenCount: node.isCollapsed ? descendantCount : 0)
            disclosureLayer.frame = frame
            disclosureGlyph.frame = frame
            disclosureLayer.path = CGPath(
                roundedRect: disclosureLayer.bounds,
                cornerWidth: CanvasStyle.disclosureDiameter / 2, cornerHeight: CanvasStyle.disclosureDiameter / 2,
                transform: nil)
            let center = CGPoint(x: frame.width / 2, y: frame.height / 2)
            let path = CGMutablePath()
            path.move(to: CGPoint(x: center.x - CanvasStyle.disclosureGlyphRadius, y: center.y))
            path.addLine(to: CGPoint(x: center.x + CanvasStyle.disclosureGlyphRadius, y: center.y))
            if node.isCollapsed {
                let countColor = NSColor.secondaryLabelColor.cgColor
                if previousCount != descendantCount || previousCountColor != countColor {
                    let paragraph = NSMutableParagraphStyle()
                    paragraph.alignment = .center
                    attributedCount = NSAttributedString(
                        string: String(descendantCount),
                        attributes: [
                            .font: CanvasStyle.disclosureCountFont,
                            .foregroundColor: NSColor(cgColor: countColor) ?? .secondaryLabelColor,
                            .paragraphStyle: paragraph,
                        ])
                    previousCount = descendantCount
                    previousCountColor = countColor
                }
                disclosureCount.configure(
                    attributedCount,
                    size: CGSize(width: frame.width - CanvasStyle.disclosureCountPadding * 2, height: frame.height),
                    contentsScale: backingScale * max(1, ceil(scale)),
                    padding: CGSize(width: CanvasStyle.disclosureCountPadding, height: 0))
            }
            disclosureGlyph.path = path
        }
    }
}

final class MapRenderer {
    private struct EdgeGeometry: Equatable {
        let start: CGPoint
        let end: CGPoint
    }
    private struct BatchKey: Hashable {
        let rootID: UUID
        let index: Int
    }
    private final class ConnectorBatch {
        let layer = CAShapeLayer()
        private var geometry: [EdgeGeometry] = []

        func update(_ segments: ArraySlice<EdgeGeometry>, color: CGColor, width: CGFloat) {
            layer.fillColor = nil
            layer.strokeColor = color
            layer.lineWidth = width
            guard !segments.elementsEqual(geometry) else { return }
            let path = CGMutablePath()
            for segment in segments {
                let bend = (segment.end.x - segment.start.x) / 2
                path.move(to: segment.start)
                path.addCurve(
                    to: segment.end,
                    control1: CGPoint(x: segment.start.x + bend, y: segment.start.y),
                    control2: CGPoint(x: segment.end.x - bend, y: segment.end.y))
            }
            layer.path = path
            geometry = Array(segments)
        }
    }
    // Bound layer count while retaining curved paths and caching batches across camera updates.
    private let edgesPerBatch = 256
    private let world = CALayer()
    private let marquee = CAShapeLayer()
    private let dropIndicator = CAShapeLayer()
    private var trees: [UUID: CALayer] = [:]
    private var topics: [UUID: TopicLayer] = [:]
    private var connectorBatches: [BatchKey: ConnectorBatch] = [:]
    private var reusableTopics: [TopicLayer] = []

    init(layer: CALayer) {
        world.anchorPoint = .zero
        layer.addSublayer(world)
        for overlay in [marquee, dropIndicator] {
            overlay.fillColor = NSColor.controlAccentColor.withAlphaComponent(CanvasStyle.selectionOpacity).cgColor
            overlay.strokeColor = NSColor.controlAccentColor.cgColor
            overlay.lineWidth = CanvasStyle.borderWidth
            layer.addSublayer(overlay)
        }
        dropIndicator.lineDashPattern = [4, 3]
    }

    func render(
        board: MindMapBoard, layout: MapLayout, camera: MapCamera, viewport: CGRect,
        selection: Set<UUID>, backingScale: CGFloat, drag: MapDragPreview? = nil
    ) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        world.position = camera.translation
        world.setAffineTransform(CGAffineTransform(scaleX: camera.scale, y: camera.scale))

        let query = camera.worldRect(
            viewport.insetBy(dx: -CanvasStyle.viewportOverscan, dy: -CanvasStyle.viewportOverscan))
        let minimumExtent =
            camera.scale < CanvasStyle.textDetailScale ? CanvasStyle.overviewBranchExtent / camera.scale : 0
        var visible = Set(layout.visibleNodes(in: query, minimumSubtreeExtent: minimumExtent))
        if let drag {
            visible.subtract(drag.movedIDs)
            let movedQuery = query.offsetBy(dx: -drag.offset.width, dy: -drag.offset.height)
            visible.formUnion(
                layout.visibleNodes(in: movedQuery, minimumSubtreeExtent: minimumExtent).filter {
                    drag.movedIDs.contains($0)
                })
        }
        for id in Set(topics.keys).subtracting(visible) {
            if let topic = topics.removeValue(forKey: id) {
                topic.layer.removeFromSuperlayer()
                if reusableTopics.count < 256 { reusableTopics.append(topic) }
            }
        }
        let rootIndex = Dictionary(uniqueKeysWithValues: layout.roots.map { ($0.id, $0.position) })
        for (index, root) in layout.roots.enumerated() {
            let tree =
                trees[root.id]
                ?? {
                    let value = CALayer()
                    value.anchorPoint = .zero
                    world.addSublayer(value)
                    trees[root.id] = value
                    return value
                }()
            tree.position = CGPoint(
                x: root.position.x + (drag?.rootIDs.contains(root.id) == true ? drag?.offset.width ?? 0 : 0),
                y: root.position.y + (drag?.rootIDs.contains(root.id) == true ? drag?.offset.height ?? 0 : 0)
            )
            tree.zPosition = CGFloat(drag?.rootIDs.contains(root.id) == true ? layout.roots.count + index : index)
        }
        for id in Array(trees.keys) where rootIndex[id] == nil {
            trees.removeValue(forKey: id)?.removeFromSuperlayer()
        }
        for id in visible {
            guard let placement = layout.nodes[id], let node = board.nodes[id],
                let tree = trees[placement.rootID], let origin = rootIndex[placement.rootID]
            else { continue }
            let topic = topics[id] ?? reusableTopics.popLast() ?? TopicLayer()
            if topic.layer.superlayer !== tree {
                topic.layer.removeFromSuperlayer()
                tree.addSublayer(topic.layer)
            }
            topics[id] = topic
            var frame = placement.frame.offsetBy(dx: -origin.x, dy: -origin.y)
            if let drag, drag.movedIDs.contains(id), !drag.rootIDs.contains(placement.rootID) {
                frame = frame.offsetBy(dx: drag.offset.width, dy: drag.offset.height)
            }
            topic.layer.frame = frame
            topic.layer.opacity = drag?.topLevelIDs.contains(id) == true && drag?.rootIDs.contains(id) != true ? 0.7 : 1
            topic.configure(
                node: node, descendantCount: placement.descendantCount, root: placement.depth == 0,
                selected: selection.contains(id),
                scale: camera.scale, backingScale: backingScale
            )
        }

        // Query edges separately: a connector can cross the viewport while both endpoints are outside it.
        var edgesByRoot: [UUID: [EdgeGeometry]] = [:]
        func branchOffset(_ placement: PlacedNode) -> CGSize {
            guard let drag, drag.movedIDs.contains(placement.id), !drag.rootIDs.contains(placement.rootID) else {
                return .zero
            }
            return drag.offset
        }
        var pending = layout.roots.map(\.id)
        while let id = pending.popLast() {
            guard let parent = layout.nodes[id], let rootOrigin = rootIndex[parent.rootID] else { continue }
            let offset = drag?.rootIDs.contains(parent.rootID) == true ? drag?.offset ?? .zero : .zero
            let rootQuery = query.offsetBy(dx: -offset.width, dy: -offset.height)
            let movedQuery = rootQuery.offsetBy(dx: -(drag?.offset.width ?? 0), dy: -(drag?.offset.height ?? 0))
            guard
                parent.subtreeBounds.intersects(rootQuery)
                    || (drag != nil && parent.subtreeBounds.intersects(movedQuery))
            else { continue }
            guard max(parent.subtreeBounds.width, parent.subtreeBounds.height) >= minimumExtent else { continue }
            for childID in parent.children {
                guard let child = layout.nodes[childID] else { continue }
                pending.append(childID)
                let childOffset = branchOffset(child)
                let parentOffset = branchOffset(parent)
                let start = CGPoint(
                    x: parent.frame.maxX + parentOffset.width, y: parent.frame.midY + parentOffset.height)
                let end = CGPoint(x: child.frame.minX + childOffset.width, y: child.frame.midY + childOffset.height)
                let box = CGRect(
                    x: min(start.x, end.x), y: min(start.y, end.y) - CanvasStyle.edgeWidth,
                    width: max(abs(end.x - start.x), 1),
                    height: max(abs(end.y - start.y), 1) + CanvasStyle.edgeWidth * 2
                )
                guard box.intersects(rootQuery), drag?.topLevelIDs.contains(childID) != true else { continue }
                let a = CGPoint(x: start.x - rootOrigin.x, y: start.y - rootOrigin.y)
                let b = CGPoint(x: end.x - rootOrigin.x, y: end.y - rootOrigin.y)
                edgesByRoot[parent.rootID, default: []].append(EdgeGeometry(start: a, end: b))
            }
        }
        var activeBatches = Set<BatchKey>()
        let edgeColor = NSColor.separatorColor.cgColor
        for (rootID, segments) in edgesByRoot {
            guard let tree = trees[rootID] else { continue }
            for start in stride(from: 0, to: segments.count, by: edgesPerBatch) {
                let key = BatchKey(rootID: rootID, index: start / edgesPerBatch)
                activeBatches.insert(key)
                let batch = connectorBatches[key] ?? ConnectorBatch()
                connectorBatches[key] = batch
                if batch.layer.superlayer !== tree {
                    batch.layer.removeFromSuperlayer()
                    tree.insertSublayer(batch.layer, at: 0)
                }
                batch.update(
                    segments[start..<min(start + edgesPerBatch, segments.count)],
                    color: edgeColor, width: CanvasStyle.edgeWidth / camera.scale)
            }
        }
        for key in Set(connectorBatches.keys).subtracting(activeBatches) {
            connectorBatches.removeValue(forKey: key)?.layer.removeFromSuperlayer()
        }
    }

    func showMarquee(_ rect: CGRect?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        marquee.path = rect.map { CGPath(rect: $0, transform: nil) }
        CATransaction.commit()
    }

    func showDropTarget(_ rect: CGRect?, sibling: Bool = false) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let rect {
            if sibling {
                let path = CGMutablePath()
                path.move(to: rect.origin)
                path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
                dropIndicator.path = path
            } else {
                dropIndicator.path = CGPath(
                    roundedRect: rect.insetBy(dx: -4, dy: -4), cornerWidth: CanvasStyle.nodeRadius,
                    cornerHeight: CanvasStyle.nodeRadius, transform: nil
                )
            }
        } else {
            dropIndicator.path = nil
        }
        CATransaction.commit()
    }
}
