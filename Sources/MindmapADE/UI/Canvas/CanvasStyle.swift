import AppKit
import MindMapCore

enum CanvasStyle {
    static let nodeRadius: CGFloat = 8
    static let borderWidth: CGFloat = 1
    static let selectedBorderWidth: CGFloat = 2
    static let edgeWidth: CGFloat = 1.5
    static let viewportOverscan: CGFloat = 160
    static let fitPadding: CGFloat = 64
    static let dragThreshold: CGFloat = 4
    static let selectionOpacity: CGFloat = 0.08
    static let resourceIconPointSize: CGFloat = 16
    static let formWidth: CGFloat = 384
    static let formMaximumBodyHeight: CGFloat = 344
    static let formPadding: CGFloat = 16
    static let formFocusInset: CGFloat = 8
    static let formCompactSpacing: CGFloat = 4
    static let formSpacing: CGFloat = 8
    static let formGroupSpacing: CGFloat = 16
    static let canvasMinimumWidth: CGFloat = 160
    static let terminalMinimumWidth: CGFloat = 192
    static let terminalResizeHandleWidth: CGFloat = 8
    static let terminalResizeStep: CGFloat = 32
    static let editorMinimumHeight: CGFloat = 36
    static let editorMaximumHeight: CGFloat = 240
    static let sidebarMinimumWidth: CGFloat = 180
    static let sidebarIdealWidth: CGFloat = 208
    static let sidebarMaximumWidth: CGFloat = 280
    static let statusHorizontalPadding: CGFloat = 16
    static let statusVerticalPadding: CGFloat = 8
    static let textDetailScale: CGFloat = 0.22
    static let overviewBranchExtent: CGFloat = 8
    static let disclosureDiameter: CGFloat = 16
    static let disclosureGap: CGFloat = 8
    static let disclosureHitPadding: CGFloat = 4
    static let disclosureGlyphRadius: CGFloat = 4
    static let disclosureCountFontSize: CGFloat = 10
    static let disclosureCountPadding: CGFloat = 4
    static let disclosureMaximumWidth = MapMetrics.horizontalGap - disclosureGap - disclosureHitPadding * 2
    static let disclosureCountFont = NSFont.monospacedDigitSystemFont(ofSize: disclosureCountFontSize, weight: .medium)
    private static let disclosureDigitWidth = ("0" as NSString).size(withAttributes: [.font: disclosureCountFont]).width

    static func disclosureFrame(for topic: CGRect, hiddenCount: Int = 0) -> CGRect {
        let width =
            hiddenCount > 0
            ? min(
                disclosureMaximumWidth,
                max(
                    disclosureDiameter,
                    ceil(CGFloat(String(hiddenCount).count) * disclosureDigitWidth + disclosureCountPadding * 2)))
            : disclosureDiameter
        return CGRect(
            x: topic.maxX + disclosureGap, y: topic.midY - disclosureDiameter / 2,
            width: width, height: disclosureDiameter)
    }

    static func disclosureHitFrame(for topic: CGRect, hiddenCount: Int = 0) -> CGRect {
        disclosureFrame(for: topic, hiddenCount: hiddenCount).insetBy(
            dx: -disclosureHitPadding, dy: -disclosureHitPadding)
    }

    static func font(root: Bool) -> NSFont {
        .systemFont(ofSize: MapMetrics.fontSize, weight: root ? .semibold : .regular)
    }

    static func resourceIcon(named name: String, color: NSColor, contentsScale: CGFloat) -> CGImage? {
        let configuration = NSImage.SymbolConfiguration(pointSize: resourceIconPointSize, weight: .medium)
            .applying(.init(paletteColors: [color]))
        guard
            let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                .withSymbolConfiguration(configuration)
        else { return nil }

        let size = MapMetrics.resourceIconSize
        let pixels = Int(ceil(size * contentsScale))
        guard
            let context = CGContext(
                data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        let scale = CGFloat(pixels) / size
        context.scaleBy(x: scale, y: scale)
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        symbol.draw(
            in: CGRect(
                x: (size - symbol.size.width) / 2, y: (size - symbol.size.height) / 2,
                width: symbol.size.width, height: symbol.size.height))
        return context.makeImage()
    }

    static func contextMenuImage(named name: String) -> NSImage? {
        guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil) else { return nil }
        // AppKit hides symbol images by default on macOS 27. Template images remain visible with the macOS 26 SDK.
        let image = NSImage(size: symbol.size, flipped: false) { bounds in
            symbol.draw(in: bounds)
            return true
        }
        image.isTemplate = true
        return image
    }

    static func zoomLabel(for scale: CGFloat) -> String {
        let percent = scale * 100
        if percent >= 10 { return "\(Int(percent.rounded()))%" }
        if percent >= 1 { return String(format: "%.1f%%", percent) }
        if percent >= 0.1 { return String(format: "%.2f%%", percent) }
        return String(format: "%.3g%%", percent)
    }
}
