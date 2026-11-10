import CoreGraphics
import CoreText
import Foundation
import MindMapCore

/// Owns Core Text layout objects on one executor; no AppKit views cross this boundary.
actor TextLayoutService {
    private struct Key: Hashable {
        let text: String
        let fontName: String
        let resource: Bool
    }

    private var sizes: [Key: CGSize] = [:]

    func layout(board: MindMapBoard, regularFont: String, rootFont: String) throws -> MapLayout {
        let roots = Set(board.roots.map(\.id))
        var metrics: [UUID: CGSize] = [:]
        for node in board.nodes.values {
            try Task.checkCancellation()
            let key = Key(
                text: node.title,
                fontName: roots.contains(node.id) || node.content.kind != .text ? rootFont : regularFont,
                resource: node.content.kind != .text
            )
            var size = measure(key)
            if let suggestion = node.worktreeNameSuggestion {
                size.width = max(
                    size.width, measure(Key(text: suggestion, fontName: key.fontName, resource: true)).width)
            }
            metrics[node.id] = size
        }
        if sizes.count > 20_000 { sizes.removeAll(keepingCapacity: true) }
        return TreeLayout.make(board: board, sizes: metrics)
    }

    private func measure(_ key: Key) -> CGSize {
        if let size = sizes[key] { return size }
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
                key.resource ? MapMetrics.resourceMinimumWidth : MapMetrics.minimumNodeWidth,
                ceil(measured.width) + MapMetrics.horizontalPadding * 2
                    + (key.resource ? MapMetrics.resourceIconInset : 0)
            ),
            height: key.resource
                ? MapMetrics.resourceHeight
                : max(
                    MapMetrics.minimumNodeHeight,
                    min(MapMetrics.maximumTextHeight, ceil(measured.height)) + MapMetrics.verticalPadding * 2
                )
        )
        sizes[key] = size
        return size
    }
}
