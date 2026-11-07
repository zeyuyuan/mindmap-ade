import AppKit
import CoreText

final class TopicTextView: NSTextView {
    struct ContentLayout {
        let height: CGFloat
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
            return ContentLayout(height: 0, visualBounds: .null)
        }
        var visualBounds = CGRect.null
        manager.enumerateTextLayoutFragments(
            from: range.location, options: [.ensuresLayout, .ensuresExtraLineFragment]
        ) {
            fragment in
            for line in fragment.textLineFragments {
                let lineOrigin = CGPoint(
                    x: fragment.layoutFragmentFrame.minX + line.typographicBounds.minX,
                    y: fragment.layoutFragmentFrame.minY + line.typographicBounds.minY)
                let attributed = line.attributedString.attributedSubstring(from: line.characterRange)
                let coreLine = CTLineCreateWithAttributedString(attributed)
                let ink = CTLineGetBoundsWithOptions(coreLine, [.useGlyphPathBounds])
                let bounds: CGRect
                if ink.isEmpty || ink.isNull {
                    // Empty and trailing lines still need room for the native insertion point.
                    bounds = line.typographicBounds.offsetBy(
                        dx: fragment.layoutFragmentFrame.minX, dy: fragment.layoutFragmentFrame.minY)
                } else {
                    bounds = CGRect(
                        x: lineOrigin.x + line.glyphOrigin.x + ink.minX,
                        y: lineOrigin.y + line.glyphOrigin.y - ink.maxY,
                        width: ink.width, height: ink.height)
                }
                visualBounds = visualBounds.union(bounds)
            }
            return true
        }

        return ContentLayout(height: manager.usageBoundsForTextContainer.maxY, visualBounds: visualBounds)
    }

    @discardableResult
    func centerContentVertically(using layout: ContentLayout, in viewportHeight: CGFloat, padding: CGFloat) -> Bool {
        let documentHeight = max(viewportHeight, ceil(layout.height + padding * 2))
        if frame.height != documentHeight { setFrameSize(NSSize(width: frame.width, height: documentHeight)) }
        let fits = layout.height + padding * 2 <= viewportHeight
        let originY = fits && !layout.visualBounds.isNull ? viewportHeight / 2 - layout.visualBounds.midY : padding
        if centeredOriginY != originY {
            centeredOriginY = originY
            invalidateTextContainerOrigin()
            needsDisplay = true
        }
        return fits
    }
}
