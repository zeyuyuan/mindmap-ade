import CoreGraphics
import CoreText
import Foundation
import MindMapCore

/// Owns Core Text layout objects on one executor; no AppKit views cross this boundary.
actor TextLayoutService {
    private var measurements = TopicMeasurements()

    func layout(
        board: MindMapBoard, regularFont: String, rootFont: String, expandedAncestors: Set<UUID> = [],
        draft: (id: UUID, size: CGSize, baseline: MapLayout?)? = nil
    ) throws -> MapLayout {
        if let draft, let baseline = draft.baseline {
            return try TreeLayout.resizing(draft.id, to: draft.size, in: baseline, parents: board.parents)
        }
        return try measurements.layout(
            board: board, regularFont: regularFont, rootFont: rootFont,
            expandedAncestors: expandedAncestors, draftSize: draft.map { ($0.id, $0.size) },
            checkCancellation: { try Task.checkCancellation() })
    }

    nonisolated fileprivate static func measureText(_ string: NSAttributedString) -> CGSize {
        let framesetter = CTFramesetterCreateWithAttributedString(string)
        return CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter, CFRange(location: 0, length: 0), nil,
            CGSize(width: MapMetrics.maximumTextWidth, height: .greatestFiniteMagnitude), nil
        )
    }

    nonisolated static func topicSize(for string: NSAttributedString) -> CGSize {
        let measured = measureText(includingFinalEmptyLine(in: string))
        let height = max(
            MapMetrics.minimumNodeHeight,
            min(MapMetrics.maximumTextHeight, ceil(measured.height)) + MapMetrics.verticalPadding * 2)
        return CGSize(
            width: max(
                MapMetrics.minimumNodeWidth,
                min(MapMetrics.maximumTextWidth, ceil(measured.width)) + MapMetrics.horizontalPadding
                    + MapMetrics.textTrailingPadding(at: height)),
            height: height)
    }

    nonisolated static func includingFinalEmptyLine(in string: NSAttributedString) -> NSAttributedString {
        switch string.string.utf16.last {
        case 0x000A, 0x000D, 0x0085, 0x2028, 0x2029:
            // Core Text omits the final empty line unless there is a character after the break.
            let padded = NSMutableAttributedString(attributedString: string)
            padded.append(
                NSAttributedString(
                    string: "\u{200B}", attributes: string.attributes(at: string.length - 1, effectiveRange: nil)))
            return padded
        default:
            return string
        }
    }
}

nonisolated struct TopicMeasurements {
    private struct Key: Hashable {
        let text: String
        let fontName: String
        let resource: Bool
    }

    private var sizes: [Key: CGSize] = [:]

    mutating func layout(
        board: MindMapBoard, regularFont: String, rootFont: String, expandedAncestors: Set<UUID> = [],
        draftSize: (id: UUID, size: CGSize)? = nil, checkCancellation: () throws -> Void
    ) rethrows -> MapLayout {
        let roots = Set(board.roots.map(\.id))
        var metrics: [UUID: CGSize] = [:]
        var pending = board.roots.map(\.id)
        while let id = pending.popLast() {
            try checkCancellation()
            guard let node = board.nodes[id] else { continue }
            pending.append(contentsOf: node.displayedChildren(expandedAncestors: expandedAncestors))
            if let draft = draftSize, draft.id == id {
                metrics[id] = draft.size
                continue
            }
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
            metrics[id] = size
        }
        if sizes.count > 20_000 { sizes.removeAll(keepingCapacity: true) }
        return TreeLayout.make(board: board, sizes: metrics, expandedAncestors: expandedAncestors)
    }

    private mutating func measure(_ key: Key) -> CGSize {
        if let size = sizes[key] { return size }
        let font = CTFontCreateWithName(key.fontName as CFString, MapMetrics.fontSize, nil)
        let string = NSAttributedString(
            string: key.text,
            attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font]
        )
        let size: CGSize
        if key.resource {
            size = CGSize(
                width: max(
                    MapMetrics.resourceMinimumWidth,
                    ceil(TextLayoutService.measureText(string).width) + MapMetrics.horizontalPadding * 2
                        + MapMetrics.resourceIconInset),
                height: MapMetrics.resourceHeight)
        } else {
            size = TextLayoutService.topicSize(for: string)
        }
        sizes[key] = size
        return size
    }

}
