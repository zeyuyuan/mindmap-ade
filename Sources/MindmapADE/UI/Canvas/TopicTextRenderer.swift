import AppKit
import CoreText
import MindMapCore
import QuartzCore

/// Core Animation retains the rasterized text; camera movement does not retypeset it.
final class TopicTextRenderer: NSObject, @MainActor CALayerDelegate {
    let layer = CALayer()
    private var previousString: NSAttributedString?
    private var previousSize = CGSize.zero
    private var previousPadding = CGSize.zero
    private var lines: [CTLine] = []
    private var origins: [CGPoint] = []

    override init() {
        super.init()
        layer.anchorPoint = .zero
        layer.delegate = self
    }

    func configure(
        _ string: NSAttributedString, size: CGSize, contentsScale: CGFloat,
        padding: CGSize = CGSize(width: MapMetrics.horizontalPadding, height: MapMetrics.verticalPadding)
    ) {
        let changed = previousString != string || previousSize != size || previousPadding != padding
        let resolutionChanged = layer.contentsScale != contentsScale
        layer.frame = CGRect(x: padding.width, y: 0, width: size.width, height: size.height)
        layer.contentsScale = contentsScale
        if changed {
            previousString = string
            previousSize = size
            previousPadding = padding
            let framesetter = CTFramesetterCreateWithAttributedString(string)
            let path = CGPath(
                rect: CGRect(
                    x: 0, y: 0, width: size.width,
                    height: max(1, size.height - padding.height * 2)), transform: nil)
            let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), path, nil)
            lines = CTFrameGetLines(frame) as? [CTLine] ?? []
            origins = Array(repeating: .zero, count: lines.count)
            if !lines.isEmpty { CTFrameGetLineOrigins(frame, CFRange(location: 0, length: 0), &origins) }
            let visible = CTFrameGetVisibleStringRange(frame)
            if visible.location + visible.length < string.length, let last = lines.last {
                let range = CTLineGetStringRange(last)
                let tail = NSMutableAttributedString(
                    attributedString: string.attributedSubstring(
                        from: NSRange(location: range.location, length: range.length)))
                let token = NSAttributedString(
                    string: "…", attributes: string.attributes(at: range.location, effectiveRange: nil))
                tail.append(token)
                let candidate = CTLineCreateWithAttributedString(tail)
                lines[lines.count - 1] =
                    CTLineCreateTruncatedLine(
                        candidate, Double(size.width), .end, CTLineCreateWithAttributedString(token))
                    ?? candidate
            }
        }
        if changed || resolutionChanged { layer.setNeedsDisplay() }
    }

    func draw(_ layer: CALayer, in context: CGContext) {
        context.saveGState()
        defer { context.restoreGState() }
        context.textMatrix = .identity
        var ink = CGRect.null
        for (line, origin) in zip(lines, origins) {
            // Glyph bounds include fallback fonts, so mixed scripts share the same visual center.
            let bounds = CTLineGetImageBounds(line, context)
            if !bounds.isNull && !bounds.isEmpty { ink = ink.union(bounds.offsetBy(dx: origin.x, dy: origin.y)) }
        }
        guard !ink.isNull else { return }
        context.translateBy(x: 0, y: layer.bounds.midY + ink.midY)
        context.scaleBy(x: 1, y: -1)
        for (line, origin) in zip(lines, origins) {
            context.textPosition = origin
            CTLineDraw(line, context)
        }
    }
}
