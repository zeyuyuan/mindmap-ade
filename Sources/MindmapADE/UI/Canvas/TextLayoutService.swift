import CoreGraphics
import CoreText
import Foundation
import MindMapCore

/// Owns Core Text layout objects on one executor; no AppKit views cross this boundary.
actor TextLayoutService {
    private struct Key: Hashable {
        let text: String
        let fontName: String
    }

    private var sizes: [Key: CGSize] = [:]

    func layout(board: MindMapBoard, regularFont: String, rootFont: String) throws -> MapLayout {
        let roots = Set(board.roots.map(\.id))
        var metrics: [UUID: CGSize] = [:]
        for node in board.nodes.values {
            try Task.checkCancellation()
            let key = Key(
                text: node.text.isEmpty ? "New topic" : node.text,
                fontName: roots.contains(node.id) ? rootFont : regularFont
            )
            if let size = sizes[key] {
                metrics[node.id] = size
                continue
            }
            let font = CTFontCreateWithName(key.fontName as CFString, MapMetrics.fontSize, nil)
            let string = NSAttributedString(
                string: key.text,
                attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font]
            )
            let framesetter = CTFramesetterCreateWithAttributedString(string)
            let measured = CTFramesetterSuggestFrameSizeWithConstraints(
                framesetter, CFRange(location: 0, length: 0), nil,
                CGSize(width: MapMetrics.maximumTextWidth, height: .greatestFiniteMagnitude), nil
            )
            let size = CGSize(
                width: max(
                    MapMetrics.minimumNodeWidth,
                    ceil(measured.width) + MapMetrics.horizontalPadding * 2
                ),
                height: max(
                    MapMetrics.minimumNodeHeight,
                    min(MapMetrics.maximumTextHeight, ceil(measured.height)) + MapMetrics.verticalPadding * 2
                )
            )
            sizes[key] = size
            metrics[node.id] = size
        }
        if sizes.count > 20_000 { sizes.removeAll(keepingCapacity: true) }
        return TreeLayout.make(board: board, sizes: metrics)
    }
}
