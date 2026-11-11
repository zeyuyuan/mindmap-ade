import AppKit
import MindMapCore
import SwiftUI

struct MindMapCanvas: NSViewRepresentable {
    let session: BoardSession
    let workspace: WorkspaceStore
    let actions: EditorActions
    let revision: Int
    let runtimeDetails: [UUID: String]

    func makeNSView(context: Context) -> MindMapCanvasView {
        MindMapCanvasView(session: session, workspace: workspace, actions: actions)
    }

    func updateNSView(_ view: MindMapCanvasView, context: Context) {
        view.update(session: session, revision: revision)
        view.updateRuntimeDetails(runtimeDetails)
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

final class MindMapCanvasView: NSView, NSTextViewDelegate, NSTextFieldDelegate, NSUserInterfaceValidations,
    NSPopoverDelegate
{
    private static let worktreeNameHint = "Tab uses default · Click away to create"

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
    private var worktreeNameField: NSTextField?
    private var pendingWorktreeCreations = Set<NodeAddress>()
    private var editingTextView: NSTextView? {
        editor ?? (worktreeNameField?.currentEditor() as? NSTextView)
    }
    private var nodePopover: NSPopover?
    private weak var nodeFormModel: NodeFormModel?
    private var formAddress: NodeAddress?
    private var formLease: UUID?
    private var configureAfterLayout: UUID?
    private var runtimeDetails: [UUID: String] = [:]
    private var editorScroll: NSScrollView?
    private var editorBackdrop: NSView?
    private var provisionalEditFrame: CGRect?
    private var revealAfterLayout: UUID?
    private var revealAfterTerminalResize: UUID?
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
    private var terminalClick: TerminalClick?
    private var isMarquee = false
    private var isPanning = false
    private var selectionBeforeMarquee = Set<UUID>()
    private var draggedBranches: [UUID] = []
    private var draggedBranchIDs = Set<UUID>()
    private var draggedRootIDs = Set<UUID>()
    private var draggedResources: [UUID: BranchResources] = [:]
    private var dragOffset = CGSize.zero
    private var forbiddenTargets = Set<UUID>()
    private var dropTarget: DropTarget?
    private var accessibilityNodes: [UUID: TopicAccessibilityElement] = [:]
    private var accessibilityDisclosures: [UUID: TopicDisclosureAccessibilityElement] = [:]
    private var accessibilityOrder: [UUID] = []
    private var accessibilityRevision = -1
    private var accessibilitySelection = Set<UUID>()

    private enum EditingCompletion {
        case blur, submit, keepDraft, cancel
    }

    private enum TerminalClick {
        case pressed, shown
    }

    private enum DropTarget {
        case child(UUID)
        case sibling(UUID, after: Bool)
        case invalid(ResourcePlacementProblem?)
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

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
            closeNodeForm()
            configureAfterLayout = nil
            revealAfterTerminalResize = nil
            finishEditing(restoringFocus: false)
            persistCamera()
            self.session = session
            actions?.hint = EditorActions.defaultHint
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
        if let address = formAddress, session.board.nodes[address.nodeID] == nil { closeNodeForm() }
        if worktreeNameField != nil, let editingID, session.board.nodes[editingID]?.worktreeCreationDraft == nil {
            finishEditing(.cancel)
        }
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
                if let id = self.configureAfterLayout {
                    self.configureAfterLayout = nil
                    self.configureNode(id)
                }
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
        closeNodeForm()
        finishEditing(.keepDraft)
        persistCamera()
        layoutTask?.cancel()
        if actions?.canvas === self { actions?.canvas = nil }
    }

    override func layout() {
        super.layout()
        nativeHost.frame = bounds
        initializeCameraIfNeeded()
        if let id = revealAfterTerminalResize, let frame = mapLayout.nodes[id]?.frame {
            revealAfterTerminalResize = nil
            reveal(frame)
        }
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
                        movedIDs: forbiddenTargets, offset: dragOffset),
                runtimeDetails: runtimeDetails, editingTitleID: worktreeNameField == nil ? nil : editingID
            )
        }
        updateAccessibility()
    }

    func updateRuntimeDetails(_ details: [UUID: String]) {
        guard details != runtimeDetails else { return }
        runtimeDetails = details
        accessibilityRevision = -1
        render()
        updateActions()
    }

    private var canAddProject: Bool {
        guard !session.isReadOnly, selected.count <= 1 else { return false }
        guard let id = selected.first else { return true }
        return session.board.nodes[id]?.content.kind == .text && session.board.canInsertResource(.project, under: id)
    }

    private var selectedWorktreeParent: UUID? {
        guard !session.isReadOnly, selected.count == 1, let id = selected.first,
            let kind = session.board.nodes[id]?.content.kind, kind != .agent
        else { return nil }
        let parent = session.board.context(startingAt: id).worktreeID ?? id
        return session.board.canInsertResource(.worktree, under: parent) ? parent : nil
    }

    private var canAddWorktree: Bool { selectedWorktreeParent != nil }

    private var canLinkWorktree: Bool {
        guard !session.isReadOnly, selected.count == 1, let id = selected.first,
            let kind = session.board.nodes[id]?.content.kind, kind != .agent
        else { return false }
        return session.board.context(startingAt: id).worktreeID == nil
            && session.board.canInsertResource(.worktree, under: id)
    }

    private func updateActions() {
        guard let actions else { return }
        actions.zoomLabel = CanvasStyle.zoomLabel(for: camera.scale)
        actions.canEdit = !selected.isEmpty && !session.isReadOnly
        actions.canAddProject = canAddProject
        actions.canAddWorktree = canAddWorktree
        actions.canLinkWorktree = canLinkWorktree
        let undoManager = editingTextView?.undoManager
        actions.undoTitle = undoManager?.undoMenuItemTitle ?? session.undoTitle
        actions.redoTitle = undoManager?.redoMenuItemTitle ?? session.redoTitle
        actions.isEditingTopic = editingID != nil
        actions.canUndo = undoManager?.canUndo ?? session.canUndo
        actions.canRedo = undoManager?.canRedo ?? session.canRedo
        let node = selected.count == 1 ? selected.first.flatMap { session.board.nodes[$0] } : nil
        actions.canDelete = actions.canEdit
        actions.canCollapse = !session.isReadOnly && node?.children.isEmpty == false
        actions.canDeriveAgent =
            !session.isReadOnly && node?.content.kind == .text
            && !(editor?.string ?? node?.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func changed() {
        update(session: session, revision: session.revision)
        updateActions()
        if let error = session.editError { actions?.hint = error }
    }

    private func persistCamera() {
        guard hasCamera else { return }
        cameraSave?.cancel()
        workspace?.rememberCamera(camera, for: session.id)
    }

    private func cameraChanged() {
        render()
        positionEditor()
        actions?.zoomLabel = CanvasStyle.zoomLabel(for: camera.scale)
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
        if edit { openNode(id) }
    }

    func insertNode(asChild: Bool) {
        finishEditing()
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
        finishEditing()
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
        finishEditing(.keepDraft)
        workspace?.commitEdits(in: session.id)
        guard !session.isReadOnly, !selected.isEmpty else { return }
        let parent = selected.first.flatMap { session.board.parents[$0] }
        if session.apply(session.board.deleting(selected), named: "Delete Topics") {
            selected = Set([parent ?? session.board.roots[0].id])
        }
        changed()
    }

    func toggleCollapse() {
        finishEditing()
        guard let id = selected.first else { return }
        session.apply(session.board.togglingCollapse(id), named: "Fold Branch")
        changed()
    }

    func editSelection() { if let id = selected.first { openNode(id) } }

    func revealTerminalNode(_ address: NodeAddress) {
        guard address.boardID == session.id, session.board.nodes[address.nodeID] != nil else { return }
        selected = [address.nodeID]
        revealAfterTerminalResize = address.nodeID
        if renderedRevision != session.revision { revealAfterLayout = address.nodeID }
        needsLayout = true
        render()
    }

    private func openNode(_ id: UUID) {
        guard let node = session.board.nodes[id] else { return }
        if node.content.kind == .text {
            beginEditing(id)
        } else if node.content.kind == .agent,
            workspace?.terminals[NodeAddress(boardID: session.id, nodeID: id)] != nil
        {
            actions?.showTerminal(at: NodeAddress(boardID: session.id, nodeID: id))
        } else {
            configureNode(id)
        }
    }

    func configureNode(_ id: UUID) {
        finishEditing()
        guard let workspace, !session.isReadOnly,
            let node = session.board.nodes[id], node.content.kind != .text
        else { return }
        let address = NodeAddress(boardID: session.id, nodeID: id)
        if workspace.agentRuns[address]?.state.isActive == true {
            actions?.showTerminal(at: address)
            return
        }
        guard let frame = mapLayout.nodes[id]?.frame else {
            configureAfterLayout = id
            return
        }
        closeNodeForm()
        workspace.formClosers[address]?.1()
        if case .worktree(let worktree) = node.content, worktree.location == nil,
            worktree.choice.mode != .existing || session.board.context(above: id).worktreeID != nil
        {
            guard !pendingWorktreeCreations.contains(address), !workspace.operations.contains(address) else { return }
            if worktree.choice.mode == .existing {
                workspace.updateDraft(at: address, content: .draft(.worktree))
            }
            beginWorktreeNameEditing(id, frame: frame, workspace: workspace)
            return
        }
        reveal(frame)
        selected = [id]
        let lease = UUID()
        formLease = lease
        formAddress = address
        workspace.formClosers[address] = (lease, { [weak self] in self?.closeNodeForm() })
        let model = NodeFormModel(
            address: address, session: session, workspace: workspace,
            close: { [weak self] in
                if self?.formLease == lease { self?.closeNodeForm() }
            },
            showNode: { [weak self] in self?.configureNode($0) },
            showTerminal: { [weak self] in
                if self?.formLease == lease { self?.actions?.showTerminal(at: address) }
            })
        let popover = NSPopover()
        popover.behavior = .applicationDefined
        popover.delegate = self
        popover.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        popover.contentViewController = NSHostingController(rootView: NodeForm(model: model))
        nodePopover = popover
        nodeFormModel = model
        let anchor = viewRect(frame)
        var edge = NSRectEdge.maxX
        if let content = window?.contentView {
            let windowRect = convert(anchor, to: content)
            let right = content.bounds.maxX - windowRect.maxX
            let left = windowRect.minX - content.bounds.minX
            if right < CanvasStyle.formWidth + CanvasStyle.formPadding && left > right {
                edge = .minX
            }
        }
        popover.show(relativeTo: anchor, of: self, preferredEdge: edge)
        render()
        updateActions()
    }

    private func closeNodeForm() {
        let popover = nodePopover
        clearNodeForm()
        popover?.close()
    }

    func popoverDidClose(_ notification: Notification) {
        if notification.object as? NSPopover === nodePopover { clearNodeForm() }
    }

    private func clearNodeForm() {
        if let address = formAddress, workspace?.formClosers[address]?.0 == formLease {
            workspace?.formClosers.removeValue(forKey: address)
        }
        formLease = nil
        formAddress = nil
        nodeFormModel = nil
        nodePopover = nil
    }

    func insertResource(_ kind: NodeKind, at point: CGPoint? = nil, source: UUID? = nil, linkWorktree: Bool = false) {
        guard !session.isReadOnly, kind != .text, kind != .project || canAddProject,
            kind != .worktree || (linkWorktree ? canLinkWorktree : canAddWorktree)
        else { return }
        finishEditing()
        closeNodeForm()
        guard selected.count <= 1 else {
            actions?.hint = "Select one topic to add a resource."
            return
        }
        var parent = selected.first
        let content: NodeContent
        if let source, let text = session.board.nodes[source]?.text {
            content = .agent(AgentTopic(task: text, sourceTextID: source))
            parent = source
        } else if kind == .worktree {
            var worktree = WorktreeTopic()
            if linkWorktree {
                worktree.choice.mode = .existing
            } else {
                guard let worktreeParent = selectedWorktreeParent else { return }
                parent = worktreeParent
            }
            content = .worktree(worktree)
        } else {
            content = .draft(kind)
        }
        let center = camera.worldPoint(CGPoint(x: bounds.midX, y: bounds.midY))
        let position = point ?? CGPoint(x: center.x, y: max(center.y, mapLayout.bounds.maxY + MapMetrics.rootGap))
        guard
            let result = session.board.inserting(
                MapNode(content: content), parent: parent, position: position),
            session.apply(result.edit, named: "Add \(kind.title)")
        else { return }
        selected = [result.id]
        configureAfterLayout = result.id
        revealAfterLayout = result.id
        changed()
    }

    func deriveAgent() {
        guard !session.isReadOnly, editor?.hasMarkedText() != true, selected.count == 1, let id = selected.first,
            session.board.nodes[id]?.content.kind == .text
        else { return }
        finishEditing()
        guard let source = session.board.nodes[id], !source.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return }
        if let draft = source.children.first(where: { child in
            guard case .agent(let agent) = session.board.nodes[child]?.content else { return false }
            return agent.sourceTextID == id && !agent.isConfigured
        }) {
            if source.isCollapsed {
                session.apply(session.board.togglingCollapse(id), named: "Expand Branch")
                configureAfterLayout = draft
                changed()
            } else {
                configureNode(draft)
            }
        } else {
            insertResource(.agent, source: id)
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if event.keyCode == 36 || event.keyCode == 76, modifiers.contains(.command),
            modifiers.intersection([.option, .shift, .control]).isEmpty,
            window?.firstResponder === self || (editor != nil && window?.firstResponder === editor),
            editor?.hasMarkedText() != true, actions?.canDeriveAgent == true
        {
            deriveAgent()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    func moveSelection(by offset: Int) {
        finishEditing()
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
        finishEditing()
        pendingFit = false
        guard !session.isReadOnly, session.board.nodes[id]?.content.kind == .text,
            let frame = mapLayout.nodes[id]?.frame ?? provisionalFrame
        else {
            return
        }
        let token = workspace?.beginEditing(nodeID: id, boardID: session.id) { [weak self] in
            self?.finishEditing()
        }
        guard let node = session.board.nodes[id] else {
            if let token { workspace?.endEditing(nodeID: id, boardID: session.id, token: token) }
            return
        }
        editingToken = token
        provisionalEditFrame = frame
        selected = [id]
        revealForEditing(frame)
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

    private func beginWorktreeNameEditing(_ id: UUID, frame: CGRect, workspace: WorkspaceStore) {
        let token = workspace.beginEditing(nodeID: id, boardID: session.id) { [weak self] in
            self?.finishEditing(.keepDraft)
        }
        guard let node = session.board.nodes[id], let draft = node.worktreeCreationDraft,
            let suggestion = node.worktreeNameSuggestion
        else {
            workspace.endEditing(nodeID: id, boardID: session.id, token: token)
            return
        }
        let field = NSTextField(string: draft.choice.branch)
        field.placeholderString = suggestion
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.cell?.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.delegate = self
        field.setAccessibilityLabel("Worktree name")
        field.setAccessibilityHelp(
            "Tab accepts the suggested name. Press Return or leave the field to create the worktree.")

        editingID = id
        editingToken = token
        originalText = draft.choice.branch
        worktreeNameField = field
        pendingFit = false
        selected = [id]
        nativeHost.addSubview(field)
        revealForEditing(frame)
        positionEditor()
        field.selectText(nil)
        actions?.hint = Self.worktreeNameHint
        render()
        updateActions()
    }

    private func revealForEditing(_ frame: CGRect) {
        let availableWidth = max(bounds.width - CanvasStyle.fitPadding * 2, MapMetrics.minimumNodeWidth)
        let maximumEditingScale = min(1.5, availableWidth / frame.width)
        let editingScale = min(camera.scale < 0.75 ? 1 : camera.scale, maximumEditingScale)
        if editingScale != camera.scale {
            camera.zoom(to: editingScale, around: camera.viewPoint(CGPoint(x: frame.midX, y: frame.midY)))
        }
        reveal(frame)
    }

    private func positionEditor() {
        if let field = worktreeNameField, let id = editingID, let placement = mapLayout.nodes[id] {
            let scale = camera.scale
            let frame = viewRect(placement.frame)
            let padding = MapMetrics.horizontalPadding * scale
            let titleX = frame.minX + padding + MapMetrics.resourceIconInset * scale
            let titleHeight = frame.height - (MapMetrics.resourceDetailHeight + MapMetrics.verticalPadding * 2) * scale
            let fontSize = MapMetrics.fontSize * scale
            if field.font?.pointSize != fontSize {
                field.font = NSFont.systemFont(ofSize: fontSize, weight: .semibold)
            }
            field.frame = CGRect(
                x: titleX, y: frame.minY + MapMetrics.verticalPadding * scale,
                width: max(1, frame.maxX - titleX - padding / 2), height: titleHeight)
            return
        }
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

    private func finishEditing(_ completion: EditingCompletion = .blur, restoringFocus: Bool = true) {
        guard !finishingEdit, let id = editingID else { return }
        finishingEdit = true
        let commit = completion != .cancel
        let field = worktreeNameField
        let text = editingTextView?.string ?? field?.stringValue ?? originalText
        if commit && text != originalText { revealAfterLayout = id }
        editor?.delegate = nil
        field?.delegate = nil
        editor = nil
        worktreeNameField = nil
        editingID = nil
        field?.removeFromSuperview()
        provisionalEditFrame = nil
        editorBackdrop?.removeFromSuperview()
        editorBackdrop = nil
        editorScroll = nil
        if let token = editingToken { workspace?.endEditing(nodeID: id, boardID: session.id, token: token) }
        editingToken = nil
        if commit && text != originalText {
            if field != nil, let node = session.board.nodes[id] {
                let address = NodeAddress(boardID: session.id, nodeID: id)
                workspace?.updateDraft(at: address, content: node.applyingInlineText(text).content)
            } else {
                session.apply(session.board.replacingText(id, with: text), named: "Edit Text")
            }
        }
        if restoringFocus { window?.makeFirstResponder(self) }
        finishingEdit = false
        actions?.hint = EditorActions.defaultHint
        if field != nil { render() }
        changed()
        if field != nil && (completion == .blur || completion == .submit) {
            createWorktree(id, refocusOnFailure: completion == .submit)
        }
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
        finishEditing()
    }

    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard textView === editor, !textView.hasMarkedText() else { return false }
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            if NSApp.currentEvent?.modifierFlags.intersection([.option, .shift]).isEmpty == false { return false }
            finishEditing()
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            finishEditing(.cancel)
            return true
        }
        if commandSelector == #selector(NSResponder.insertTab(_:)) {
            finishEditing()
            insertNode(asChild: true)
            return true
        }
        return false
    }

    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField, field === worktreeNameField,
            let id = editingID, let token = editingToken, editingTextView?.hasMarkedText() != true
        else { return }
        workspace?.rememberDraft(
            editingTextView?.string ?? field.stringValue, nodeID: id, boardID: session.id, token: token)
        actions?.hint = Self.worktreeNameHint
        updateActions()
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField, field === worktreeNameField else { return }
        finishEditing(restoringFocus: false)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy command: Selector) -> Bool {
        guard let field = worktreeNameField, control === field, !textView.hasMarkedText() else { return false }
        switch command {
        case #selector(NSResponder.insertTab(_:)):
            if textView.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                let suggestion = field.placeholderString
            {
                let range = NSRange(location: 0, length: textView.string.utf16.count)
                textView.insertText(suggestion, replacementRange: range)
                textView.selectAll(nil)
            }
        case #selector(NSResponder.insertNewline(_:)):
            if NSApp.currentEvent?.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty != false {
                finishEditing(.submit)
            }
        case #selector(NSResponder.cancelOperation(_:)):
            finishEditing(.cancel)
        default:
            return false
        }
        return true
    }

    private func createWorktree(_ id: UUID, refocusOnFailure: Bool) {
        guard let workspace, let draft = session.board.nodes[id]?.worktreeCreationDraft else { return }
        let address = NodeAddress(boardID: session.id, nodeID: id)
        guard !workspace.operations.contains(address), pendingWorktreeCreations.insert(address).inserted else { return }
        let progress = "Creating Worktree…"
        actions?.hint = progress
        Task { [weak self] in
            let failure: String?
            do {
                try await workspace.saveWorktree(draft, at: address)
                failure = nil
            } catch {
                failure = error.localizedDescription
            }
            guard let self else { return }
            self.pendingWorktreeCreations.remove(address)
            guard self.session.id == address.boardID, self.editingID == nil else { return }
            if let failure {
                if refocusOnFailure, self.selected == [id], self.nodePopover == nil,
                    self.session.board.nodes[id]?.worktreeCreationDraft != nil
                {
                    self.configureNode(id)
                }
                self.actions?.hint = failure
            } else if self.actions?.hint == progress {
                self.actions?.hint = EditorActions.defaultHint
            }
        }
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
        closeNodeForm()
        finishEditing()
        camera.zoom(to: scale, around: CGPoint(x: bounds.midX, y: bounds.midY))
        hasCamera = true
        cameraChanged()
    }

    func fitContent() {
        finishEditing()
        guard !mapLayout.nodes.isEmpty, renderedRevision == session.revision else {
            pendingFit = true
            return
        }
        camera.fit(mapLayout.bounds, in: bounds, padding: CanvasStyle.fitPadding)
        hasCamera = true
        cameraChanged()
    }

    override func scrollWheel(with event: NSEvent) {
        closeNodeForm()
        actions?.activateTarget()
        finishEditing()
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
        closeNodeForm()
        actions?.activateTarget()
        finishEditing()
        camera.zoom(to: camera.scale * (1 + event.magnification), around: localPoint(event))
        hasCamera = true
        cameraChanged()
    }

    override func mouseDown(with event: NSEvent) {
        let terminalWasShown = terminalClick == .shown
        terminalClick = nil
        // Opening the pane can move the topic out from under the second click.
        if terminalWasShown && event.clickCount == 2 && isUnmodifiedLeftButton(event) { return }

        closeNodeForm()
        actions?.activateTarget()
        finishEditing()
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
        if id != nil, !isPanning, event.clickCount == 1, isUnmodifiedLeftButton(event) {
            terminalClick = .pressed
        }
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
                draggedResources = session.board.resources(in: draggedBranches)
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
            if allowsDrop(under: nil) { NSCursor.arrow.set() }
            return
        }
        if forbiddenTargets.contains(id) {
            if !draggedBranchIDs.contains(id) {
                dropTarget = .invalid(nil)
                NSCursor.operationNotAllowed.set()
            } else if allowsDrop(under: nil) {
                NSCursor.arrow.set()
            }
            renderer.showDropTarget(nil)
            return
        }
        let relativeY = (world.y - target.frame.minY) / target.frame.height
        let isSibling = relativeY < 0.25 || relativeY > 0.75
        let parent = isSibling ? session.board.parents[id] : id
        guard allowsDrop(under: parent) else { return }
        NSCursor.arrow.set()
        if isSibling {
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

    private func allowsDrop(under parent: UUID?) -> Bool {
        guard let problem = session.board.resourceMoveProblem(for: draggedResources, to: parent) else { return true }
        dropTarget = .invalid(problem)
        renderer.showDropTarget(nil)
        NSCursor.operationNotAllowed.set()
        return false
    }

    override func mouseUp(with event: NSEvent) {
        let isTerminalClick = terminalClick == .pressed
        terminalClick = nil
        defer {
            dragStart = nil
            lastDrag = nil
            pressedNode = nil
            draggedBranches = []
            draggedBranchIDs = []
            draggedRootIDs = []
            draggedResources = [:]
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
        guard dragStarted else {
            if isTerminalClick { showTerminalForClick(event) }
            return
        }
        guard !draggedBranches.isEmpty else { return }
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
        case .invalid(let problem):
            if let problem { actions?.hint = problem.message }
            return
        case nil:
            edit = session.board.movingBranches(draggedBranchIDs, to: nil, positions: positions)
        }
        if session.apply(edit, named: "Move Branch") { actions?.hint = EditorActions.defaultHint }
        changed()
    }

    private func isUnmodifiedLeftButton(_ event: NSEvent) -> Bool {
        event.buttonNumber == 0 && event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty
    }

    private func showTerminalForClick(_ event: NSEvent) {
        guard isUnmodifiedLeftButton(event), !isSpaceDown, let id = pressedNode, selected == [id],
            session.board.nodes[id]?.content.kind == .agent, let start = dragStart, let workspace, let actions
        else { return }
        let point = localPoint(event)
        guard hypot(point.x - start.x, point.y - start.y) < CanvasStyle.dragThreshold,
            mapLayout.hitTest(camera.worldPoint(point)) == id
        else { return }

        let address = NodeAddress(boardID: session.id, nodeID: id)
        guard let terminal = workspace.terminals[address],
            actions.terminalAddress != address || terminal.owner != actions.windowID
        else { return }
        let paneIsVisible =
            actions.terminalAddress.map { current in
                current.boardID == session.id && session.board.nodes[current.nodeID] != nil
                    && workspace.terminals[current] != nil
            } ?? false
        actions.showTerminal(at: address, revealNode: !paneIsVisible)
        terminalClick = .shown
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
        if let form = nodeFormModel, form.content.kind == .worktree {
            // Nonediting popover controls may leave the canvas as first responder.
            switch event.keyCode {
            case 36, 76:
                if event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty {
                    form.submitWorktree()
                }
            case 53:
                closeNodeForm()
            case 48:
                if let popoverWindow = nodePopover?.contentViewController?.view.window {
                    popoverWindow.makeKey()
                    if event.modifierFlags.contains(.shift) {
                        popoverWindow.selectPreviousKeyView(nil)
                    } else {
                        popoverWindow.selectNextKeyView(nil)
                    }
                }
            default:
                super.keyDown(with: event)
            }
            return
        }
        actions?.activateTarget()
        if event.keyCode == 49 {
            isSpaceDown = true
            NSCursor.openHand.set()
            return
        }
        switch event.keyCode {
        case 48: insertNode(asChild: true)
        case 36, 76:
            if selected.count == 1, let id = selected.first, session.board.nodes[id]?.worktreeCreationDraft != nil {
                configureNode(id)
            } else {
                insertNode(asChild: false)
            }
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
        guard !session.isReadOnly, let id = selected.first, session.board.nodes[id]?.content.kind == .text else {
            return
        }
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
        if let editor = editingTextView {
            editor.undoManager?.undo()
            updateActions()
            return
        }
        workspace?.commitEdits(in: session.id)
        session.undo()
        changed()
    }
    func redoCommand() {
        if let editor = editingTextView {
            editor.undoManager?.redo()
            updateActions()
            return
        }
        workspace?.commitEdits(in: session.id)
        session.redo()
        changed()
    }

    @objc func copy(_ sender: Any?) {
        let text = mapLayout.orderedIDs.filter { selected.contains($0) }.compactMap { session.board.nodes[$0]?.title }
            .joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @objc func paste(_ sender: Any?) {
        guard !session.isReadOnly, let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else {
            return
        }
        finishEditing()
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
    @objc private func addResourceAction(_ item: NSMenuItem) {
        guard let raw = item.representedObject as? String, let kind = NodeKind(rawValue: raw) else { return }
        insertResource(kind, at: contextPoint)
    }
    @objc private func deriveAgentAction(_ sender: Any?) { deriveAgent() }
    @objc private func linkWorktreeAction(_ sender: Any?) { insertResource(.worktree, linkWorktree: true) }
    @objc private func configureResourceAction(_ sender: Any?) {
        if let id = selected.first { configureNode(id) }
    }
    @objc private func showLocationAction(_ sender: Any?) {
        guard let id = selected.first, let node = session.board.nodes[id] else { return }
        let path: String?
        switch node.content {
        case .project(let project): path = project.location?.directory
        case .worktree(let tree): path = tree.location?.directory
        case .agent: path = session.board.context(above: id).worktree?.directory
        case .text, .branch: path = nil
        }
        if let path { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
    }

    @objc private func addChildAction(_ sender: Any?) { insertNode(asChild: true) }
    @objc private func addSiblingAction(_ sender: Any?) { insertNode(asChild: false) }
    @objc private func addRootAction(_ sender: Any?) { insertRoot(at: contextPoint) }
    @objc private func editAction(_ sender: Any?) { editSelection() }
    @objc private func deleteAction(_ sender: Any?) { deleteSelection() }
    @objc private func fitContentAction(_ sender: Any?) { fitContent() }
    @objc private func detachAction(_ sender: Any?) {
        guard let id = selected.first, let frame = mapLayout.nodes[id]?.frame else { return }
        session.apply(session.board.moving(id, to: nil, position: frame.origin), named: "Make Root")
        changed()
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        finishEditing()
        contextPoint = camera.worldPoint(localPoint(event))
        let node = mapLayout.hitTest(contextPoint).flatMap { session.board.nodes[$0] }
        if let node {
            select(node.id)
        } else {
            selected.removeAll()
            updateActions()
        }
        let menu = NSMenu()
        func add(
            _ title: String, _ action: Selector, symbol: String, key: String = "",
            modifiers: NSEvent.ModifierFlags = [], resource: NodeKind? = nil
        ) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers
            item.image = CanvasStyle.contextMenuImage(named: symbol)
            #if compiler(>=6.4)
                if #available(macOS 27.0, *) { item.preferredImageVisibility = .visible }
            #endif
            item.representedObject = resource?.rawValue
            item.target = self
            menu.addItem(item)
        }
        func addResource(_ kind: NodeKind) {
            add("Add \(kind.title)", #selector(addResourceAction(_:)), symbol: kind.symbol, resource: kind)
        }

        if node == nil {
            add(
                "Add Root", #selector(addRootAction(_:)), symbol: "plus.square", key: "r",
                modifiers: [.command, .shift])
        } else {
            add("Add Child", #selector(addChildAction(_:)), symbol: "arrow.turn.down.right", key: "\t")
            add("Add Sibling", #selector(addSiblingAction(_:)), symbol: "plus", key: "\r")
        }
        if canAddProject { addResource(.project) }
        if canAddWorktree { addResource(.worktree) }
        if canLinkWorktree { add("Link Existing Worktree…", #selector(linkWorktreeAction(_:)), symbol: "link") }
        if let node, node.content.kind == .text, !node.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            add(
                "New Agent from Text", #selector(deriveAgentAction(_:)), symbol: NodeKind.agent.symbol, key: "\r",
                modifiers: .command)
        } else {
            addResource(.agent)
        }
        menu.addItem(.separator())
        if let node {
            let kind = node.content.kind
            let editKey = String(UnicodeScalar(NSEvent.SpecialKey.f2.rawValue)!)
            if kind == .text {
                add("Edit Text", #selector(editAction(_:)), symbol: "pencil", key: editKey)
            } else if node.worktreeCreationDraft != nil {
                add("Edit Worktree Name", #selector(editAction(_:)), symbol: "pencil", key: editKey)
            } else {
                let address = NodeAddress(boardID: session.id, nodeID: node.id)
                let opensTerminal = kind == .agent && workspace?.terminals[address] != nil
                if opensTerminal {
                    add("Open Terminal", #selector(editAction(_:)), symbol: NodeKind.agent.symbol, key: editKey)
                }
                if kind != .agent || workspace?.agentRuns[address]?.state.isActive != true {
                    add(
                        "Configure \(kind.title)…",
                        #selector(configureResourceAction(_:)),
                        symbol: "gearshape",
                        key: opensTerminal ? "" : editKey)
                }
                if !node.content.isDraft {
                    add("Show in Finder", #selector(showLocationAction(_:)), symbol: "arrow.up.right.square")
                }
            }
            if session.board.parents[node.id] != nil,
                session.board.resourceMoveProblem(for: session.board.resources(in: [node.id]), to: nil) == nil
            {
                add("Make Root", #selector(detachAction(_:)), symbol: "arrow.up.to.line")
            }
            menu.addItem(.separator())
            if kind == .text {
                add("Copy Text", #selector(copy(_:)), symbol: "doc.on.doc", key: "c", modifiers: .command)
            }
            add(
                "Delete", #selector(deleteAction(_:)), symbol: "trash",
                key: String(UnicodeScalar(NSBackspaceCharacter)!))
        } else {
            add(
                "Fit Content", #selector(fitContentAction(_:)), symbol: "viewfinder", key: "0",
                modifiers: [.command, .shift])
        }
        return menu
    }

    func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(copy(_:)) { return !selected.isEmpty }
        if item.action == #selector(selectAll(_:)) { return !mapLayout.nodes.isEmpty }
        if item.action == #selector(fitContentAction(_:)) { return true }
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
            element.setAccessibilityLabel(node.title)
            element.setAccessibilityRoleDescription(node.content.kind == .project ? "project topic" : "mind map topic")
            let children =
                node.isCollapsed
                ? "Collapsed, \(mapLayout.nodes[id]?.descendantCount ?? 0) hidden topics"
                : "\(node.children.count) children"
            let detail = runtimeDetails[id] ?? node.detail
            element.setAccessibilityValue(detail.map { "\($0), \(children)" } ?? children)
            element.setAccessibilitySelected(selected.contains(id))
            element.setAccessibilityEnabled(!session.isReadOnly)
            accessibilityNodes[id] = element
            if !node.children.isEmpty {
                let disclosure =
                    accessibilityDisclosures[id] ?? TopicDisclosureAccessibilityElement(id: id, canvas: self)
                let title = node.title
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
        if let field = worktreeNameField { return elements + [field] }
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
