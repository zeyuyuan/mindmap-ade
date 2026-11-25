import AppKit

final class TopicTextView: NSTextView {
    struct ContentLayout {
        let height: CGFloat
        let lineCount: Int
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
            return ContentLayout(height: 0, lineCount: 0)
        }
        var lineCount = 0
        manager.enumerateTextLayoutFragments(
            from: range.location, options: [.ensuresLayout, .ensuresExtraLineFragment]
        ) {
            fragment in
            lineCount += fragment.textLineFragments.count
            return true
        }

        return ContentLayout(height: manager.usageBoundsForTextContainer.maxY, lineCount: lineCount)
    }

    @discardableResult
    func positionContent(
        using layout: ContentLayout, in viewportHeight: CGFloat, topicHeight: CGFloat, padding: CGFloat
    ) -> Bool {
        let documentHeight = max(viewportHeight, ceil(layout.height + padding * 2))
        if frame.height != documentHeight { setFrameSize(NSSize(width: frame.width, height: documentHeight)) }
        let fits = layout.height + padding * 2 <= viewportHeight
        // Center the native line box, including the empty line that holds the initial caret.
        let originY = fits && layout.lineCount == 1 ? (topicHeight - layout.height) / 2 : padding
        if centeredOriginY != originY {
            centeredOriginY = originY
            invalidateTextContainerOrigin()
            needsDisplay = true
        }
        return fits
    }
}
