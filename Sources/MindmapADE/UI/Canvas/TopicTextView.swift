import AppKit
import CoreText

final class TopicTextView: NSTextView {
    struct ContentLayout {
        let height: CGFloat
        let lineCount: Int
        let visualBounds: CGRect
    }

    private let editingUndo = UndoManager()
    private var centeredOriginY: CGFloat?

    override var undoManager: UndoManager? { editingUndo }

    override var textContainerOrigin: NSPoint {
        var origin = super.textContainerOrigin
        if let centeredOriginY { origin.y = centeredOriginY }
        return origin
    }

    func measureContent() -> ContentLayout {
        guard let manager = textLayoutManager, let range = manager.textContentManager?.documentRange else {
            return ContentLayout(height: 0, lineCount: 0, visualBounds: .null)
        }
        var lineCount = 0
        var visualBounds = CGRect.null
        manager.enumerateTextLayoutFragments(
            from: range.location, options: [.ensuresLayout, .ensuresExtraLineFragment]
        ) {
            fragment in
            lineCount += fragment.textLineFragments.count
            for line in fragment.textLineFragments {
                let lineOrigin = CGPoint(
                    x: fragment.layoutFragmentFrame.minX + line.typographicBounds.minX,
                    y: fragment.layoutFragmentFrame.minY + line.typographicBounds.minY)
                let attributed = line.attributedString.attributedSubstring(from: line.characterRange)
                let coreLine = CTLineCreateWithAttributedString(attributed)
                let ink = CTLineGetBoundsWithOptions(coreLine, [.useGlyphPathBounds])
                guard !ink.isEmpty, !ink.isNull else { continue }
                visualBounds = visualBounds.union(
                    CGRect(
                        x: lineOrigin.x + line.glyphOrigin.x + ink.minX,
                        y: lineOrigin.y + line.glyphOrigin.y - ink.maxY,
                        width: ink.width, height: ink.height))
            }
            return true
        }

        return ContentLayout(
            height: manager.usageBoundsForTextContainer.maxY, lineCount: lineCount, visualBounds: visualBounds)
    }

    @discardableResult
    func positionContent(
        using layout: ContentLayout, in viewportHeight: CGFloat, topicHeight: CGFloat, padding: CGFloat
    ) -> Bool {
        let documentHeight = max(viewportHeight, ceil(layout.height + padding * 2))
        if frame.height != documentHeight { setFrameSize(NSSize(width: frame.width, height: documentHeight)) }
        let fits = layout.height + padding * 2 <= viewportHeight
        // The document still includes empty lines for caret movement and scrolling.
        let originY =
            fits && layout.lineCount == 1 && !layout.visualBounds.isNull
            ? topicHeight / 2 - layout.visualBounds.midY : padding
        if centeredOriginY != originY {
            centeredOriginY = originY
            invalidateTextContainerOrigin()
            needsDisplay = true
        }
        return fits
    }
}
