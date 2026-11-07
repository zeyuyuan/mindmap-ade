import AppKit
import MindMapCore
import SwiftUI

struct MindMapCanvas: NSViewRepresentable {
    let session: BoardSession
    let workspace: WorkspaceStore
    let actions: EditorActions
    let revision: Int

    func makeNSView(context: Context) -> MindMapCanvasView {
        MindMapCanvasView(session: session, workspace: workspace, actions: actions)
    }

    func updateNSView(_ view: MindMapCanvasView, context: Context) {
        view.update(session: session, revision: revision)
    }

    static func dismantleNSView(_ view: MindMapCanvasView, coordinator: ()) {
        view.prepareForRemoval()
    }
}

/// A separate native host keeps future terminal surfaces independent of lightweight drawing layers.
final class NativeNodeHostView: NSView {
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }
}

final class MindMapCanvasView: NSView, NSTextViewDelegate, NSUserInterfaceValidations {
    private(set) var session: BoardSession
    private weak var workspace: WorkspaceStore?
    private weak var actions: EditorActions?
    private let layoutService = TextLayoutService()
    private var layoutTask: Task<Void, Never>?
    private var appliedRevision = -1
    private var renderedRevision = -1
    private var pendingFit = false
    private var mapLayout = MapLayout.empty
    private var renderer: MapRenderer!
    private let nativeHost = NativeNodeHostView()
    private var camera = MapCamera()
    private var hasCamera = false
    private var cameraSave: DispatchWorkItem?
    private var selected = Set<UUID>()
    private var editor: TopicTextView?
    private var editorScroll: NSScrollView?
    private var editorBackdrop: NSView?
    private var provisionalEditFrame: CGRect?
    private var revealAfterLayout: UUID?
    private var editingID: UUID?
    private var editingToken: UUID?
    private var originalText = ""
    private var finishingEdit = false
    private var contextPoint = CGPoint.zero
    private var tracking: NSTrackingArea?
    private var isSpaceDown = false
    private var dragStart: CGPoint?
    private var lastDrag: CGPoint?
    private var pressedNode: UUID?
    private var dragStarted = false
    private var isMarquee = false
    private var isPanning = false
    private var selectionBeforeMarquee = Set<UUID>()
    private var draggedBranches: [UUID] = []
    private var draggedBranchIDs = Set<UUID>()
    private var draggedRootIDs = Set<UUID>()
    private var dragOffset = CGSize.zero
    private var forbiddenTargets = Set<UUID>()
    private var dropTarget: DropTarget?
    private var accessibilityNodes: [UUID: TopicAccessibilityElement] = [:]
    private var accessibilityDisclosures: [UUID: TopicDisclosureAccessibilityElement] = [:]
    private var accessibilityOrder: [UUID] = []
    private var accessibilityRevision = -1
    private var accessibilitySelection = Set<UUID>()

    private enum DropTarget {
        case child(UUID)
        case sibling(UUID, after: Bool)
        case invalid
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var undoManager: UndoManager? { session.undoManager }

    init(session: BoardSession, workspace: WorkspaceStore, actions: EditorActions) {
        self.session = session
        self.workspace = workspace
        self.actions = actions
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
        renderer = MapRenderer(layer: layer!)
        addSubview(nativeHost)
        if let saved = workspace.cameras[session.id] {
            camera = saved
            hasCamera = true
        }
        selected = Set(session.board.roots.prefix(1).map(\.id))
        actions.canvas = self
        setAccessibilityRole(.group)
        setAccessibilityLabel("Mind map canvas")
        setAccessibilityHelp("Use Tab to add a child, Return to add a sibling, and arrow keys to navigate topics.")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(session: BoardSession, revision: Int) {
        if self.session !== session {
            finishEditing(commit: true)
            persistCamera()
            self.session = session
            appliedRevision = -1
            renderedRevision = -1
            pendingFit = false
            mapLayout = .empty
            camera = workspace?.cameras[session.id] ?? MapCamera()
            hasCamera = workspace?.cameras[session.id] != nil
            selected = Set(session.board.roots.prefix(1).map(\.id))
            accessibilityNodes.removeAll()
            accessibilityDisclosures.removeAll()
        }
        actions?.canvas = self
        guard appliedRevision != revision else { return }
        appliedRevision = revision
        layoutTask?.cancel()
        let board = session.board
        let regular = CanvasStyle.font(root: false).fontName
        let root = CanvasStyle.font(root: true).fontName
        layoutTask = Task { [weak self, layoutService] in
            do {
                let result = try await layoutService.layout(board: board, regularFont: regular, rootFont: root)
                guard let self, !Task.isCancelled, self.session.id == board.id,
                    self.session.revision == revision
                else { return }
                self.mapLayout = result
                self.renderedRevision = revision
                self.selected.formIntersection(result.nodes.keys)
                if self.selected.isEmpty, let first = board.roots.first { self.selected = [first.id] }
                self.initializeCameraIfNeeded()
                self.render()
                self.positionEditor()
                if let id = self.editingID ?? self.revealAfterLayout, let frame = result.nodes[id]?.frame {
                    self.reveal(frame)
                }
                self.revealAfterLayout = nil
                self.updateActions()
                if self.pendingFit {
                    self.pendingFit = false
                    self.fitContent()
                }
            } catch is CancellationError {
            } catch {
                self?.actions?.hint = "The map could not be laid out."
            }
        }
    }

    func prepareForRemoval() {
        finishEditing(commit: true)
        persistCamera()
        layoutTask?.cancel()
        if actions?.canvas === self { actions?.canvas = nil }
    }

    override func layout() {
        super.layout()
        nativeHost.frame = bounds
        initializeCameraIfNeeded()
        render()
        positionEditor()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
            render()
        }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        render()
    }

    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.activeInKeyWindow, .mouseMoved, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
        super.updateTrackingAreas()
    }

    private func initializeCameraIfNeeded() {
        guard !hasCamera, bounds.width > 0, let root = mapLayout.roots.first,
            let frame = mapLayout.nodes[root.id]?.frame
        else { return }
        camera.translation = CGPoint(x: bounds.midX - frame.midX, y: bounds.midY - frame.midY)
        hasCamera = true
    }

    private func render() {
        guard renderer != nil else { return }
        effectiveAppearance.performAsCurrentDrawingAppearance {
            renderer.render(
                board: session.board, layout: mapLayout, camera: camera, viewport: bounds,
                selection: selected, backingScale: window?.backingScaleFactor ?? 2,
                drag: draggedBranches.isEmpty
                    ? nil
                    : MapDragPreview(
                        topLevelIDs: draggedBranchIDs, rootIDs: draggedRootIDs,
                        movedIDs: forbiddenTargets, offset: dragOffset)
            )
        }
        updateAccessibility()
    }

    private func updateActions() {
        guard let actions else { return }
        actions.zoomLabel = CanvasStyle.zoomLabel(for: camera.scale)
        actions.canEdit = !selected.isEmpty && !session.isReadOnly
        actions.canUndo = editor?.undoManager?.canUndo ?? session.undoManager.canUndo
        actions.canRedo = editor?.undoManager?.canRedo ?? session.undoManager.canRedo
        let node = selected.count == 1 ? selected.first.flatMap { session.board.nodes[$0] } : nil
        actions.canCollapse = !session.isReadOnly && node?.children.isEmpty == false
    }

    private func changed() {
        update(session: session, revision: session.revision)
        updateActions()
    }

    private func persistCamera() {
        guard hasCamera else { return }
        cameraSave?.cancel()
        workspace?.rememberCamera(camera, for: session.id)
    }

    private func cameraChanged() {
        render()
        positionEditor()
        updateActions()
        cameraSave?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.persistCamera() }
        cameraSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    private func localPoint(_ event: NSEvent) -> CGPoint { convert(event.locationInWindow, from: nil) }

    fileprivate func select(_ id: UUID, edit: Bool = false) {
        selected = [id]
        window?.makeFirstResponder(self)
        render()
        updateActions()
        if edit { beginEditing(id) }
    }

    func insertNode(asChild: Bool) {
        finishEditing(commit: true)
        guard !session.isReadOnly, let current = selected.first else {
            insertRoot()
            return
        }
        let parent = asChild ? current : session.board.parents[current]
        let old = mapLayout.nodes[current]
        let position = CGPoint(
            x: old?.frame.minX ?? camera.worldPoint(CGPoint(x: bounds.midX, y: bounds.midY)).x,
            y: (old?.subtreeBounds.maxY ?? 0) + MapMetrics.rootGap
        )
        guard let result = session.board.inserting(parent: parent, after: asChild ? nil : current, position: position)
        else { return }
        session.apply(result.edit, named: asChild ? "Add Child" : "Add Sibling")
        selected = [result.id]
        changed()
        let frame = CGRect(
            x: asChild ? (old?.frame.maxX ?? position.x) + MapMetrics.horizontalGap : position.x,
            y: asChild ? (old?.frame.minY ?? position.y) : position.y,
            width: MapMetrics.minimumNodeWidth, height: MapMetrics.minimumNodeHeight
        )
        beginEditing(result.id, provisionalFrame: frame)
    }

    func insertRoot(at point: CGPoint? = nil) {
        finishEditing(commit: true)
        guard !session.isReadOnly else { return }
        let center = camera.worldPoint(CGPoint(x: bounds.midX, y: bounds.midY))
        let position = point ?? CGPoint(x: center.x, y: max(center.y, mapLayout.bounds.maxY + MapMetrics.rootGap))
        guard let result = session.board.inserting(parent: nil, position: position) else { return }
        session.apply(result.edit, named: "Add Root")
        selected = [result.id]
        changed()
        beginEditing(
            result.id,
            provisionalFrame: CGRect(
                origin: position, size: CGSize(width: MapMetrics.minimumNodeWidth, height: MapMetrics.minimumNodeHeight)
            ))
    }

    func deleteSelection() {
        finishEditing(commit: true)
        workspace?.commitEdits(in: session.id)
        guard !session.isReadOnly, !selected.isEmpty else { return }
        let parent = selected.first.flatMap { session.board.parents[$0] }
        session.apply(session.board.deleting(selected), named: "Delete Topics")
        selected = Set([parent ?? session.board.roots[0].id])
        changed()
    }

    func toggleCollapse() {
        finishEditing(commit: true)
        guard let id = selected.first else { return }
        session.apply(session.board.togglingCollapse(id), named: "Fold Branch")
        changed()
    }

    func editSelection() { if let id = selected.first { beginEditing(id) } }

    func moveSelection(by offset: Int) {
        finishEditing(commit: true)
        guard selected.count == 1, let id = selected.first, !session.isReadOnly else { return }
        let parent = session.board.parents[id]
        let siblings = parent.flatMap { session.board.nodes[$0]?.children } ?? session.board.roots.map(\.id)
        guard let current = siblings.firstIndex(of: id), siblings.indices.contains(current + offset) else { return }
        if parent == nil {
            var roots = session.board.roots
            let position = roots[current].position
            roots[current].position = roots[current + offset].position
            roots[current + offset].position = position
            roots.swapAt(current, current + offset)
            session.apply(BoardEdit(roots: roots), named: "Reorder Root")
        } else {
            session.apply(session.board.moving(id, to: parent, at: current + offset), named: "Reorder Branch")
        }
        changed()
    }

    private func beginEditing(_ id: UUID, provisionalFrame: CGRect? = nil) {
        finishEditing(commit: true)
        pendingFit = false
        guard !session.isReadOnly, session.board.nodes[id] != nil,
            let frame = mapLayout.nodes[id]?.frame ?? provisionalFrame
        else {
            return
        }
        let token = workspace?.beginEditing(nodeID: id, boardID: session.id) { [weak self] in
            self?.finishEditing(commit: true)
        }
        guard let node = session.board.nodes[id] else {
            if let token { workspace?.endEditing(nodeID: id, boardID: session.id, token: token) }
            return
        }
        editingToken = token
        provisionalEditFrame = frame
        selected = [id]
        let availableWidth = max(bounds.width - CanvasStyle.fitPadding * 2, MapMetrics.minimumNodeWidth)
        let maximumEditingScale = min(1.5, availableWidth / frame.width)
        let editingScale = min(camera.scale < 0.75 ? 1 : camera.scale, maximumEditingScale)
        if editingScale != camera.scale {
            camera.zoom(to: editingScale, around: camera.viewPoint(CGPoint(x: frame.midX, y: frame.midY)))
        }
        reveal(frame)
        let text = TopicTextView(usingTextLayoutManager: true)
        text.isRichText = false
        text.importsGraphics = false
        text.allowsUndo = true
        text.isVerticallyResizable = true
        text.isHorizontallyResizable = false
        text.drawsBackground = true
        text.backgroundColor = .controlBackgroundColor
        text.textColor = .labelColor
        text.insertionPointColor = .controlAccentColor
        text.font = NSFont.systemFont(
            ofSize: MapMetrics.fontSize * camera.scale,
            weight: session.board.roots.contains(where: { $0.id == id }) ? .semibold : .regular)
        text.string = node.text
        text.delegate = self
        text.setAccessibilityLabel("Topic text")
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.documentView = text
        let backdrop = NSView()
        backdrop.wantsLayer = true
        backdrop.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        backdrop.layer?.cornerRadius = CanvasStyle.nodeRadius * camera.scale
        backdrop.layer?.borderWidth = CanvasStyle.selectedBorderWidth
        backdrop.layer?.borderColor = NSColor.controlAccentColor.cgColor
        backdrop.layer?.masksToBounds = true
        backdrop.addSubview(scroll)
        editingID = id
        originalText = node.text
        editor = text
        editorScroll = scroll
        editorBackdrop = backdrop
        nativeHost.addSubview(backdrop)
        positionEditor()
        window?.makeFirstResponder(text)
        text.setSelectedRange(NSRange(location: text.string.utf16.count, length: 0))
        actions?.hint = "Return to finish · Option-Return for a new line · Escape to cancel"
        render()
        updateActions()
    }

    private func positionEditor() {
        guard let editor, let scroll = editorScroll, let backdrop = editorBackdrop, let id = editingID,
            let worldFrame = mapLayout.nodes[id]?.frame ?? provisionalEditFrame
        else { return }
        let frame = viewRect(worldFrame)
        let inset = NSSize(
            width: MapMetrics.horizontalPadding * camera.scale, height: MapMetrics.verticalPadding * camera.scale)
        editor.textContainerInset = inset
        editor.textContainer?.lineFragmentPadding = 0
        let measured = NSAttributedString(
            string: editor.string.isEmpty ? " " : editor.string,
            attributes: [.font: editor.font ?? CanvasStyle.font(root: false)]
        ).boundingRect(
            with: CGSize(width: MapMetrics.maximumTextWidth * camera.scale, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        let availableWidth = max(bounds.width - CanvasStyle.fitPadding * 2, MapMetrics.minimumNodeWidth)
        let baseWidth = min(availableWidth, max(frame.width, ceil(measured.width) + inset.width * 2))
        let availableHeight = max(CanvasStyle.editorMinimumHeight, bounds.height - CanvasStyle.fitPadding * 2)
        let maximumHeight = min(availableHeight, CanvasStyle.editorMaximumHeight)

        // Measure without a stale scrollbar gutter before deciding whether scrolling is needed.
        scroll.hasVerticalScroller = false
        scroll.frame = CGRect(x: 0, y: 0, width: baseWidth, height: maximumHeight)
        scroll.tile()
        editor.setFrameSize(NSSize(width: scroll.contentSize.width, height: maximumHeight))
        let measuredTextWidth = max(scroll.contentSize.width - inset.width * 2, 1)
        editor.textContainer?.containerSize = CGSize(
            width: measuredTextWidth, height: .greatestFiniteMagnitude)
        var content = editor.measureContent()
        let height = min(
            maximumHeight, max(frame.height, CanvasStyle.editorMinimumHeight, ceil(content.height + inset.height * 2)))
        let needsScrolling = content.height + inset.height * 2 > height
        let gutter =
            needsScrolling && NSScroller.preferredScrollerStyle == .legacy
            ? NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy) : 0
        let width = min(availableWidth, baseWidth + gutter)
        backdrop.frame = CGRect(x: frame.minX, y: frame.minY, width: width, height: height)
        scroll.hasVerticalScroller = needsScrolling
        scroll.frame = backdrop.bounds
        scroll.tile()
        editor.setFrameSize(
            NSSize(width: scroll.contentSize.width, height: max(height, content.height + inset.height * 2)))
        let finalTextWidth = max(scroll.contentSize.width - inset.width * 2, 1)
        if editor.textContainer?.containerSize.width != finalTextWidth {
            editor.textContainer?.containerSize = CGSize(width: finalTextWidth, height: .greatestFiniteMagnitude)
        }
        if finalTextWidth != measuredTextWidth {
            content = editor.measureContent()
        }
        if editor.centerContentVertically(using: content, in: scroll.contentSize.height, padding: inset.height) {
            scroll.contentView.scroll(to: .zero)
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        reveal(
            CGRect(origin: worldFrame.origin, size: CGSize(width: width / camera.scale, height: height / camera.scale)))
    }

    private func finishEditing(commit: Bool) {
        guard !finishingEdit, let editor, let id = editingID else { return }
        finishingEdit = true
        let text = editor.string
        if commit && text != originalText { revealAfterLayout = id }
        editor.delegate = nil
        self.editor = nil
        editingID = nil
        provisionalEditFrame = nil
        editorBackdrop?.removeFromSuperview()
        editorBackdrop = nil
        editorScroll = nil
        if let token = editingToken { workspace?.endEditing(nodeID: id, boardID: session.id, token: token) }
        editingToken = nil
        if commit && text != originalText {
            session.apply(session.board.replacingText(id, with: text), named: "Edit Text")
        }
        window?.makeFirstResponder(self)
        finishingEdit = false
        actions?.hint = "Double-click to edit · Tab to add a child · Drag the canvas to pan"
        changed()
    }

    func textDidChange(_ notification: Notification) {
        guard let source = notification.object as? NSTextView, source === editor else { return }
        positionEditor()
        if let editor { editor.scrollRangeToVisible(editor.selectedRange()) }
        if let editor, let id = editingID, let token = editingToken, !editor.hasMarkedText() {
            workspace?.rememberDraft(editor.string, nodeID: id, boardID: session.id, token: token)
        }
        updateActions()
    }
    func textDidEndEditing(_ notification: Notification) {
        guard let source = notification.object as? NSTextView, source === editor else { return }
        finishEditing(commit: true)
    }

    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard textView === editor, !textView.hasMarkedText() else { return false }
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            if NSApp.currentEvent?.modifierFlags.intersection([.option, .shift]).isEmpty == false { return false }
            finishEditing(commit: true)
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            finishEditing(commit: false)
            return true
        }
        if commandSelector == #selector(NSResponder.insertTab(_:)) {
            finishEditing(commit: true)
            insertNode(asChild: true)
            return true
        }
        return false
    }

    private func reveal(_ frame: CGRect) {
        let projected = viewRect(frame)
        let inset = bounds.insetBy(dx: CanvasStyle.fitPadding, dy: CanvasStyle.fitPadding)
        var delta = CGPoint.zero
        if projected.width > inset.width {
            delta.x = inset.midX - projected.midX
        } else if projected.minX < inset.minX {
            delta.x = inset.minX - projected.minX
        } else if projected.maxX > inset.maxX {
            delta.x = inset.maxX - projected.maxX
        }
        if projected.height > inset.height {
            delta.y = inset.midY - projected.midY
        } else if projected.minY < inset.minY {
            delta.y = inset.minY - projected.minY
        } else if projected.maxY > inset.maxY {
            delta.y = inset.maxY - projected.maxY
        }
        guard abs(delta.x) > 0.5 || abs(delta.y) > 0.5 else { return }
        camera.translation.x += delta.x
        camera.translation.y += delta.y
        cameraChanged()
    }

    fileprivate func viewRect(_ world: CGRect) -> CGRect {
        CGRect(
            origin: camera.viewPoint(world.origin),
            size: CGSize(width: world.width * camera.scale, height: world.height * camera.scale))
    }

    func zoom(by factor: CGFloat) { setZoom(camera.scale * factor) }
    func setZoom(_ scale: CGFloat) {
        finishEditing(commit: true)
        camera.zoom(to: scale, around: CGPoint(x: bounds.midX, y: bounds.midY))
        hasCamera = true
        cameraChanged()
    }

    func fitContent() {
        finishEditing(commit: true)
        guard !mapLayout.nodes.isEmpty, renderedRevision == session.revision else {
            pendingFit = true
            return
        }
        camera.fit(mapLayout.bounds, in: bounds, padding: CanvasStyle.fitPadding)
        hasCamera = true
        cameraChanged()
    }

    override func scrollWheel(with event: NSEvent) {
        actions?.activateTarget()
        finishEditing(commit: true)
        if event.modifierFlags.contains(.command) {
            camera.zoom(to: camera.scale * exp(event.scrollingDeltaY * 0.01), around: localPoint(event))
        } else {
            let multiplier: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 12
            camera.translation.x += event.scrollingDeltaX * multiplier
            camera.translation.y += event.scrollingDeltaY * multiplier
        }
        hasCamera = true
        cameraChanged()
    }

    override func magnify(with event: NSEvent) {
        actions?.activateTarget()
        finishEditing(commit: true)
        camera.zoom(to: camera.scale * (1 + event.magnification), around: localPoint(event))
        hasCamera = true
        cameraChanged()
    }

    override func mouseDown(with event: NSEvent) {
        actions?.activateTarget()
        finishEditing(commit: true)
        window?.makeFirstResponder(self)
        let point = localPoint(event)
        let world = camera.worldPoint(point)
        contextPoint = world
        if let id = disclosureHitTest(world) {
            selected = [id]
            toggleCollapse()
            return
        }
        let id = mapLayout.hitTest(world)
        if event.clickCount == 2 {
            if let id { select(id, edit: true) } else { insertRoot(at: world) }
            return
        }
        dragStart = point
        lastDrag = point
        pressedNode = id
        dragStarted = false
        isPanning = isSpaceDown || event.buttonNumber == 2 || (id == nil && !event.modifierFlags.contains(.shift))
        isMarquee = id == nil && event.modifierFlags.contains(.shift)
        selectionBeforeMarquee = selected
        if let id, !isPanning {
            if event.modifierFlags.contains(.command) {
                if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
            } else if !selected.contains(id) {
                selected = [id]
            }
        } else if id == nil && !isMarquee && !isSpaceDown {
            selected.removeAll()
        }
        render()
        updateActions()
    }

    override func otherMouseDown(with event: NSEvent) { mouseDown(with: event) }
    override func otherMouseDragged(with event: NSEvent) { mouseDragged(with: event) }
    override func otherMouseUp(with event: NSEvent) { mouseUp(with: event) }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStart, let previous = lastDrag else { return }
        let point = localPoint(event)
        let distance = hypot(point.x - start.x, point.y - start.y)
        guard dragStarted || distance >= CanvasStyle.dragThreshold else { return }
        if !dragStarted {
            dragStarted = true
            if !isPanning && !isMarquee, !session.isReadOnly, let id = pressedNode {
                if !selected.contains(id) { selected = [id] }
                draggedBranches = session.board.topLevelSelection(selected)
                draggedBranchIDs = Set(draggedBranches)
                draggedRootIDs = draggedBranchIDs.intersection(session.board.roots.map(\.id))
                forbiddenTargets = []
                for branch in draggedBranches { forbiddenTargets.formUnion(session.board.descendants(of: branch)) }
            }
        }
        if isPanning {
            camera.translation.x += point.x - previous.x
            camera.translation.y += point.y - previous.y
            hasCamera = true
            cameraChanged()
            NSCursor.closedHand.set()
        } else if isMarquee {
            let rect = CGRect(
                x: min(start.x, point.x), y: min(start.y, point.y), width: abs(point.x - start.x),
                height: abs(point.y - start.y))
            selected = selectionBeforeMarquee.union(mapLayout.visibleNodes(in: camera.worldRect(rect)))
            renderer.showMarquee(rect)
            render()
            updateActions()
        } else if !draggedBranches.isEmpty {
            dragOffset = CGSize(width: (point.x - start.x) / camera.scale, height: (point.y - start.y) / camera.scale)
            updateDropTarget(at: camera.worldPoint(point))
            render()
        }
        lastDrag = point
    }

    private func updateDropTarget(at world: CGPoint) {
        dropTarget = nil
        guard let id = mapLayout.hitTest(world), let target = mapLayout.nodes[id] else {
            renderer.showDropTarget(nil)
            NSCursor.arrow.set()
            return
        }
        if forbiddenTargets.contains(id) {
            if !draggedBranchIDs.contains(id) {
                dropTarget = .invalid
                NSCursor.operationNotAllowed.set()
            } else {
                NSCursor.arrow.set()
            }
            renderer.showDropTarget(nil)
            return
        }
        NSCursor.arrow.set()
        let relativeY = (world.y - target.frame.minY) / target.frame.height
        if relativeY < 0.25 || relativeY > 0.75 {
            dropTarget = .sibling(id, after: relativeY > 0.75)
            var line = viewRect(target.frame)
            line.origin.y = relativeY > 0.75 ? line.maxY + 8 : line.minY - 8
            line.size.height = 1
            renderer.showDropTarget(line, sibling: true)
        } else {
            dropTarget = .child(id)
            renderer.showDropTarget(viewRect(target.frame))
        }
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            dragStart = nil
            lastDrag = nil
            pressedNode = nil
            draggedBranches = []
            draggedBranchIDs = []
            draggedRootIDs = []
            forbiddenTargets = []
            dragStarted = false
            dragOffset = .zero
            dropTarget = nil
            renderer.showMarquee(nil)
            renderer.showDropTarget(nil)
            NSCursor.arrow.set()
            render()
            updateActions()
        }
        guard dragStarted, !draggedBranches.isEmpty else { return }
        let positions = Dictionary(
            uniqueKeysWithValues: draggedBranches.compactMap { id -> (UUID, CGPoint)? in
                guard let placement = mapLayout.nodes[id] else { return nil }
                return (
                    id, CGPoint(x: placement.frame.minX + dragOffset.width, y: placement.frame.minY + dragOffset.height)
                )
            })
        let edit: BoardEdit?
        switch dropTarget {
        case .child(let parent):
            edit = session.board.movingBranches(draggedBranchIDs, to: parent)
        case .sibling(let target, let after):
            let parent = session.board.parents[target]
            let siblings = parent.flatMap { session.board.nodes[$0]?.children } ?? session.board.roots.map(\.id)
            let filtered = siblings.filter { !draggedBranchIDs.contains($0) }
            let index = (filtered.firstIndex(of: target) ?? filtered.count) + (after ? 1 : 0)
            edit = session.board.movingBranches(draggedBranchIDs, to: parent, at: index, positions: positions)
        case .invalid:
            return
        case nil:
            edit = session.board.movingBranches(draggedBranchIDs, to: nil, positions: positions)
        }
        session.apply(edit, named: "Move Branch")
        changed()
    }

    override func mouseMoved(with event: NSEvent) {
        let point = camera.worldPoint(localPoint(event))
        if isSpaceDown {
            NSCursor.openHand.set()
        } else if disclosureHitTest(point) != nil {
            NSCursor.pointingHand.set()
        } else {
            NSCursor.arrow.set()
        }
    }

    private func disclosureHitTest(_ point: CGPoint) -> UUID? {
        guard !session.isReadOnly, camera.scale >= CanvasStyle.textDetailScale else { return nil }
        let reach = CanvasStyle.disclosureGap + CanvasStyle.disclosureMaximumWidth + CanvasStyle.disclosureHitPadding
        let query = CGRect(x: point.x - reach, y: point.y - 1, width: reach + 1, height: 2)
        return mapLayout.visibleNodes(in: query).last { id in
            guard let placement = mapLayout.nodes[id], session.board.nodes[id]?.children.isEmpty == false else {
                return false
            }
            let count = session.board.nodes[id]?.isCollapsed == true ? placement.descendantCount : 0
            return CanvasStyle.disclosureHitFrame(for: placement.frame, hiddenCount: count).contains(point)
        }
    }

    override func keyDown(with event: NSEvent) {
        actions?.activateTarget()
        if event.keyCode == 49 {
            isSpaceDown = true
            NSCursor.openHand.set()
            return
        }
        switch event.keyCode {
        case 48: insertNode(asChild: true)
        case 36, 76: insertNode(asChild: false)
        case 51, 117: deleteSelection()
        case 53: window?.makeFirstResponder(self)
        case 120: editSelection()
        case 123, 124, 125, 126: navigate(keyCode: event.keyCode)
        default: interpretKeyEvents([event])
        }
    }

    override func keyUp(with event: NSEvent) {
        if event.keyCode == 49 {
            isSpaceDown = false
            NSCursor.arrow.set()
        } else {
            super.keyUp(with: event)
        }
    }

    override func resignFirstResponder() -> Bool {
        isSpaceDown = false
        return super.resignFirstResponder()
    }

    override func insertText(_ insertString: Any) {
        guard !session.isReadOnly, let id = selected.first else { return }
        beginEditing(id)
        editor?.selectAll(nil)
        if let text = insertString as? String {
            editor?.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
        }
    }

    private func navigate(keyCode: UInt16) {
        guard let id = selected.first, let node = session.board.nodes[id] else {
            if let first = session.board.roots.first { select(first.id) }
            return
        }
        if keyCode == 123 {
            if !node.children.isEmpty && !node.isCollapsed {
                toggleCollapse()
            } else if let parent = session.board.parents[id] {
                select(parent)
            }
        } else if keyCode == 124 {
            if node.isCollapsed { toggleCollapse() } else if let child = node.children.first { select(child) }
        } else if let index = mapLayout.orderedIDs.firstIndex(of: id) {
            let target = index + (keyCode == 125 ? 1 : -1)
            if mapLayout.orderedIDs.indices.contains(target) { select(mapLayout.orderedIDs[target]) }
        }
        if let current = selected.first.flatMap({ mapLayout.nodes[$0]?.frame }) { reveal(current) }
    }

    func undoCommand() {
        if let editor {
            editor.undoManager?.undo()
            updateActions()
            return
        }
        workspace?.commitEdits(in: session.id)
        session.undoManager.undo()
        changed()
    }
    func redoCommand() {
        if let editor {
            editor.undoManager?.redo()
            updateActions()
            return
        }
        workspace?.commitEdits(in: session.id)
        session.undoManager.redo()
        changed()
    }

    @objc func copy(_ sender: Any?) {
        let text = mapLayout.orderedIDs.filter { selected.contains($0) }.compactMap { session.board.nodes[$0]?.text }
            .joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @objc func paste(_ sender: Any?) {
        guard !session.isReadOnly, let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else {
            return
        }
        finishEditing(commit: true)
        let parent = selected.first
        guard
            let result = session.board.inserting(
                text: text, parent: parent, position: camera.worldPoint(CGPoint(x: bounds.midX, y: bounds.midY)))
        else { return }
        session.apply(result.edit, named: "Paste Topic")
        selected = [result.id]
        changed()
    }

    override func selectAll(_ sender: Any?) {
        selected = Set(mapLayout.orderedIDs)
        render()
        updateActions()
    }
    @objc private func addChildAction(_ sender: Any?) { insertNode(asChild: true) }
    @objc private func addSiblingAction(_ sender: Any?) { insertNode(asChild: false) }
    @objc private func addRootAction(_ sender: Any?) { insertRoot(at: contextPoint) }
    @objc private func editAction(_ sender: Any?) { editSelection() }
    @objc private func deleteAction(_ sender: Any?) { deleteSelection() }
    @objc private func foldAction(_ sender: Any?) { toggleCollapse() }
    @objc private func moveUpAction(_ sender: Any?) { moveSelection(by: -1) }
    @objc private func moveDownAction(_ sender: Any?) { moveSelection(by: 1) }
    @objc private func actualSizeAction(_ sender: Any?) { setZoom(1) }
    @objc private func fitContentAction(_ sender: Any?) { fitContent() }
    @objc private func detachAction(_ sender: Any?) {
        guard let id = selected.first, let frame = mapLayout.nodes[id]?.frame else { return }
        session.apply(session.board.moving(id, to: nil, position: frame.origin), named: "Make Root")
        changed()
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        finishEditing(commit: true)
        contextPoint = camera.worldPoint(localPoint(event))
        if let id = mapLayout.hitTest(contextPoint) {
            select(id)
        } else {
            selected.removeAll()
            updateActions()
        }
        let menu = NSMenu()
        func add(_ title: String, _ action: Selector) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        add("Add Root", #selector(addRootAction(_:)))
        if selected.isEmpty {
            menu.addItem(.separator())
            add("Actual Size", #selector(actualSizeAction(_:)))
            add("Fit Content", #selector(fitContentAction(_:)))
        } else {
            add("Add Child", #selector(addChildAction(_:)))
            add("Add Sibling", #selector(addSiblingAction(_:)))
            menu.addItem(.separator())
            add("Edit Text", #selector(editAction(_:)))
            if let id = selected.first, session.board.nodes[id]?.children.isEmpty == false {
                add(
                    session.board.nodes[id]?.isCollapsed == true ? "Expand Branch" : "Collapse Branch",
                    #selector(foldAction(_:)))
            }
            if let id = selected.first, session.board.parents[id] != nil {
                add("Make Root", #selector(detachAction(_:)))
            }
            add("Move Up", #selector(moveUpAction(_:)))
            add("Move Down", #selector(moveDownAction(_:)))
            menu.addItem(.separator())
            add("Copy Text", #selector(copy(_:)))
            add("Delete", #selector(deleteAction(_:)))
        }
        return menu
    }

    func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(copy(_:)) { return !selected.isEmpty }
        if item.action == #selector(selectAll(_:)) { return !mapLayout.nodes.isEmpty }
        if item.action == #selector(actualSizeAction(_:)) || item.action == #selector(fitContentAction(_:)) {
            return true
        }
        return !session.isReadOnly
    }

    private func updateAccessibility() {
        let minimumExtent =
            camera.scale < CanvasStyle.textDetailScale ? CanvasStyle.overviewBranchExtent / camera.scale : 0
        let visible = mapLayout.visibleNodes(in: camera.worldRect(bounds), minimumSubtreeExtent: minimumExtent)
        guard
            visible != accessibilityOrder || accessibilityRevision != session.revision
                || accessibilitySelection != selected
        else { return }
        accessibilityOrder = visible
        accessibilityRevision = session.revision
        accessibilitySelection = selected
        let ids = Set(visible)
        for id in Set(accessibilityNodes.keys).subtracting(ids) { accessibilityNodes.removeValue(forKey: id) }
        for id in Set(accessibilityDisclosures.keys).subtracting(ids) {
            accessibilityDisclosures.removeValue(forKey: id)
        }
        for id in visible {
            guard let node = session.board.nodes[id] else { continue }
            let element = accessibilityNodes[id] ?? TopicAccessibilityElement(id: id, canvas: self)
            element.setAccessibilityLabel(node.text.isEmpty ? "New topic" : node.text)
            element.setAccessibilityValue(
                node.isCollapsed
                    ? "Collapsed, \(mapLayout.nodes[id]?.descendantCount ?? 0) hidden topics"
                    : "\(node.children.count) children")
            element.setAccessibilitySelected(selected.contains(id))
            element.setAccessibilityEnabled(!session.isReadOnly)
            accessibilityNodes[id] = element
            if !node.children.isEmpty {
                let disclosure =
                    accessibilityDisclosures[id] ?? TopicDisclosureAccessibilityElement(id: id, canvas: self)
                let title = node.text.isEmpty ? "New topic" : node.text
                disclosure.setAccessibilityLabel(
                    node.isCollapsed
                        ? "Expand \(title), \(mapLayout.nodes[id]?.descendantCount ?? 0) hidden topics"
                        : "Collapse \(title)")
                disclosure.setAccessibilityEnabled(!session.isReadOnly)
                accessibilityDisclosures[id] = disclosure
            } else {
                accessibilityDisclosures.removeValue(forKey: id)
            }
        }
    }

    override func accessibilityChildren() -> [Any]? {
        let elements: [Any] = accessibilityOrder.flatMap { id -> [Any] in
            guard let topic = accessibilityNodes[id] else { return [] }
            if camera.scale >= CanvasStyle.textDetailScale, let disclosure = accessibilityDisclosures[id] {
                return [topic, disclosure]
            }
            return [topic]
        }
        return editor.map { elements + [$0] } ?? elements
    }

    fileprivate func accessibilityFrame(for id: UUID) -> CGRect {
        guard let window, let frame = mapLayout.nodes[id]?.frame else { return .zero }
        return window.convertToScreen(convert(viewRect(frame), to: nil))
    }

    fileprivate func accessibilityDisclosureFrame(for id: UUID) -> CGRect {
        guard let window, let placement = mapLayout.nodes[id] else { return .zero }
        let count = session.board.nodes[id]?.isCollapsed == true ? placement.descendantCount : 0
        return window.convertToScreen(
            convert(viewRect(CanvasStyle.disclosureFrame(for: placement.frame, hiddenCount: count)), to: nil))
    }

    fileprivate func toggleDisclosure(_ id: UUID) {
        selected = [id]
        window?.makeFirstResponder(self)
        toggleCollapse()
    }
}

nonisolated final class TopicDisclosureAccessibilityElement: NSAccessibilityElement {
    private let id: UUID
    private weak var canvas: MindMapCanvasView?

    init(id: UUID, canvas: MindMapCanvasView) {
        self.id = id
        self.canvas = canvas
        super.init()
        setAccessibilityRole(.button)
        setAccessibilityParent(canvas)
    }

    override func accessibilityFrame() -> NSRect {
        let owner = canvas
        let nodeID = id
        return MainActor.assumeIsolated { owner?.accessibilityDisclosureFrame(for: nodeID) ?? .zero }
    }

    override func accessibilityPerformPress() -> Bool {
        let owner = canvas
        let nodeID = id
        return MainActor.assumeIsolated {
            owner?.toggleDisclosure(nodeID)
            return owner != nil
        }
    }
}

nonisolated final class TopicAccessibilityElement: NSAccessibilityElement {
    private let id: UUID
    private weak var canvas: MindMapCanvasView?

    init(id: UUID, canvas: MindMapCanvasView) {
        self.id = id
        self.canvas = canvas
        super.init()
        setAccessibilityRole(.button)
        setAccessibilityRoleDescription("mind map topic")
        setAccessibilityParent(canvas)
    }

    override func accessibilityFrame() -> NSRect {
        let owner = canvas
        let nodeID = id
        return MainActor.assumeIsolated { owner?.accessibilityFrame(for: nodeID) ?? .zero }
    }
    override func accessibilityPerformPress() -> Bool {
        let owner = canvas
        let nodeID = id
        return MainActor.assumeIsolated {
            owner?.select(nodeID, edit: true)
            return owner != nil
        }
    }
}
