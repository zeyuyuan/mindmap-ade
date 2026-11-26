import AppKit
import MindMapCore
import SwiftUI

struct RootView: View {
    let workspace: WorkspaceStore
    @State private var selectedBoardID: UUID?
    @State private var didRestoreWorkspace = false
    @State private var actions = EditorActions()
    @State private var renamingID: UUID?
    @State private var boardName = ""

    var body: some View {
        VStack(spacing: 0) {
            boardNavigation
            workspaceError
        }
        .frame(minWidth: WindowLayout.minimumWidth, minHeight: WindowLayout.minimumHeight)
        .focusedSceneValue(\.editorActions, actions)
        .alert("Rename Board", isPresented: Binding(get: { renamingID != nil }, set: { if !$0 { renamingID = nil } })) {
            TextField("Board name", text: $boardName)
            Button("Cancel", role: .cancel) { renamingID = nil }
            Button("Rename") {
                if let id = renamingID { workspace.renameBoard(id, to: boardName) }
                renamingID = nil
            }
        }
        .task {
            actions.workspace = workspace
            await workspace.loadIfNeeded()
        }
        .onChange(of: workspace.isLoading, initial: true) { _, isLoading in
            guard !isLoading, !didRestoreWorkspace else { return }
            actions.workspace = workspace
            selectedBoardID = workspace.board(workspace.lastSelectedBoardID)?.id ?? workspace.boards.first?.id
            actions.targetBoardID = selectedBoardID
            actions.restoreRightPane()
            didRestoreWorkspace = true
        }
        .onChange(of: actions.requestedBoardID) { _, id in
            if let id {
                selectedBoardID = id
                actions.requestedBoardID = nil
            }
        }
        .onChange(of: selectedBoardID) { _, id in
            actions.isFinding = false
            actions.targetBoardID = id
            workspace.select(id)
        }
        .onDisappear {
            actions.detachTerminal()
            workspace.releaseRightPane(from: actions.windowID)
        }
        .onChange(of: workspace.boards.map(\.id)) { _, ids in
            guard didRestoreWorkspace else { return }
            if !ids.contains(where: { $0 == selectedBoardID }) { selectedBoardID = ids.first }
        }
    }

    private var boardNavigation: some View {
        NavigationSplitView {
            List(
                selection: Binding(
                    get: { selectedBoardID },
                    set: { id in
                        actions.targetBoardID = id
                        selectedBoardID = id
                    })
            ) {
                Section("Boards") {
                    ForEach(workspace.boards) { board in
                        Label(board.name, systemImage: "rectangle.stack")
                            .badge(workspace.activeRunCount(in: board.id))
                            .tag(board.id)
                            .contextMenu {
                                Button("Rename…") {
                                    renamingID = board.id
                                    boardName = board.name
                                }
                                .disabled(workspace.isReadOnly)
                                Button("Delete Board", role: .destructive) { workspace.deleteBoard(board.id) }
                                    .disabled(workspace.isReadOnly || workspace.hasActiveWork(in: board.id))
                            }
                    }
                    .onMove { workspace.moveBoards(from: $0, to: $1) }
                    .onDelete { indices in
                        for id in indices.map({ workspace.boards[$0].id }) { workspace.deleteBoard(id) }
                    }
                }
            }
            .navigationSplitViewColumnWidth(
                min: CanvasStyle.sidebarMinimumWidth, ideal: CanvasStyle.sidebarIdealWidth,
                max: CanvasStyle.sidebarMaximumWidth
            )
            .safeAreaInset(edge: .bottom) {
                Button("New Board", systemImage: "plus") { actions.newBoard() }
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(CanvasStyle.statusHorizontalPadding)
                    .disabled(workspace.isReadOnly || workspace.isLoading)
                    .help("Create a board (Command-N)")
            }
        } detail: {
            if let board = workspace.board(selectedBoardID) {
                BoardCanvasContent(session: board, workspace: workspace, actions: actions)
            } else if workspace.isLoading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView {
                    Label("No Board Selected", systemImage: "rectangle.stack")
                } description: {
                    Text("Create a board to start mapping your ideas.")
                } actions: {
                    Button("New Board") { actions.newBoard() }.disabled(workspace.isReadOnly)
                }
            }
        }
    }

    @ViewBuilder
    private var workspaceError: some View {
        if let error = workspace.errorMessage {
            HStack {
                Label(error, systemImage: "exclamationmark.triangle")
                    .lineLimit(2)
                    .help(error)
                Spacer()
                Button("Show Data Folder") { workspace.revealData() }
            }
            .font(.caption)
            .padding(CanvasStyle.statusHorizontalPadding)
            .background(.bar)
            .overlay(alignment: .top) { Divider() }
        }
    }
}

private struct BoardCanvasContent: View {
    let session: BoardSession
    let workspace: WorkspaceStore
    let actions: EditorActions
    @State private var projectCheckoutLabels: [ProjectLocation: String] = [:]
    @State private var activationCount = 0

    private struct CheckoutRefresh: Equatable {
        let boardID: UUID
        let locations: [UUID: ProjectLocation]
        let activationCount: Int
    }

    private struct GitChangesRefresh: Equatable {
        let boardID: UUID
        let targets: [GitChangesTarget]
        let runStates: [UUID: AgentRun.State]
        let activationCount: Int
    }

    var body: some View {
        GeometryReader { geometry in
            let rightPane = visibleRightPane
            HStack(spacing: 0) {
                MindMapCanvas(
                    session: session, workspace: workspace, actions: actions, revision: session.revision,
                    runtimeDetails: runtimeDetails, activePaneNodeID: rightPane?.address.nodeID,
                    agentEditedTopics: session.agentEditedTopics,
                    agentRunStates: workspace.agentRunStates(in: session.id)
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                if let pane = rightPane {
                    let available = max(0, geometry.size.width - CanvasStyle.terminalResizeHandleWidth)
                    let width = boundedPaneWidth(available * actions.paneWidthShare, available: available)
                    TerminalDivider(
                        width: width,
                        label: pane.kind == .gitChanges ? "Git changes width" : "Terminal width"
                    ) { proposed in
                        if available > 0 {
                            actions.resizePane(to: boundedPaneWidth(proposed, available: available) / available)
                        }
                    }
                    .frame(width: CanvasStyle.terminalResizeHandleWidth)
                    switch pane {
                    case .terminal(let address):
                        AgentTerminalPane(address: address, session: session, workspace: workspace, actions: actions)
                            .frame(width: width)
                            .id(address)
                    case .gitChanges(let address):
                        GitChangesPane(address: address, session: session, workspace: workspace, actions: actions)
                            .frame(width: width)
                            .id(address)
                    }
                }
            }
        }
        .navigationTitle(session.name)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Find Topics", systemImage: "magnifyingglass") { actions.showFind() }
                    .help("Find topics in this board (⌘F)")
            }
        }
        .task(
            id: CheckoutRefresh(
                boardID: session.id, locations: session.gitProjectLocations, activationCount: activationCount
            )
        ) {
            await refreshProjectCheckoutLabels()
        }
        .task(
            id: GitChangesRefresh(
                boardID: session.id, targets: gitChangesTargets,
                runStates: workspace.agentRunStates(in: session.id), activationCount: activationCount
            )
        ) {
            await refreshGitChangesSummaries()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            activationCount += 1
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if actions.isFinding {
                BoardFindBar(session: session, actions: actions)
                    .id(session.id)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack {
                if actions.isBranchFocused {
                    Button("Exit Focus", systemImage: "scope") { actions.toggleBranchFocus() }
                        .buttonStyle(.borderless)
                        .help("Exit branch focus (Esc)")
                }
                Text(canvasHint).lineLimit(1).help(canvasHint)
                Spacer(minLength: CanvasStyle.statusHorizontalPadding)
                Text(actions.zoomLabel)
                    .monospacedDigit()
                    .accessibilityLabel("Zoom \(actions.zoomLabel)")
                    .help("Pinch or Command-scroll to zoom")
                Text("\(session.nodeCount) \(session.nodeCount == 1 ? "topic" : "topics")").monospacedDigit()
                Text(workspace.saveStatusText)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, CanvasStyle.statusHorizontalPadding)
            .padding(.vertical, CanvasStyle.statusVerticalPadding)
            .background(.bar)
            .overlay(alignment: .top) { Divider() }
        }
    }

    private var canvasHint: String {
        if let hint = actions.dropHint { return hint }
        guard actions.hint == EditorActions.defaultHint, let notice = session.agentEditNotice else {
            return actions.hint
        }
        let undoTargetsAgentEdit =
            actions.canUndo && !actions.isEditingTopic && !actions.shouldUndoBoardDeletion
            && !workspace.hasUnsavedTopicEdit(in: session.id) && session.lastUndoTime == notice.undoTime
        let status = notice.change.status
        return undoTargetsAgentEdit ? "\(status) · ⌘Z to undo" : status
    }

    private var visibleRightPane: EditorActions.RightPane? {
        guard let pane = actions.rightPane, pane.address.boardID == session.id else { return nil }
        switch pane {
        case .terminal(let address):
            return workspace.canOpenAgent(at: address) ? pane : nil
        case .gitChanges(let address):
            return workspace.canOpenGitChanges(at: address) ? pane : nil
        }
    }

    private var gitChangesTargets: [GitChangesTarget] {
        _ = session.revision
        var targets: [GitChangesTarget] = []
        var seen = Set<GitChangesTarget>()
        for id in session.gitChangesNodeIDs {
            if let target = workspace.gitChangesTarget(for: id, in: session.board), seen.insert(target).inserted {
                targets.append(target)
            }
        }
        return targets.sorted {
            $0.directory == $1.directory
                ? ($0.baseCommit ?? "") < ($1.baseCommit ?? "") : $0.directory < $1.directory
        }
    }

    private var runtimeDetails: [UUID: String] {
        var details = workspace.runtimeDetails(in: session.id)
        for (id, location) in session.gitProjectLocations where details[id] == nil {
            details[id] = projectCheckoutLabels[location]
        }
        return details
    }

    private func refreshProjectCheckoutLabels() async {
        var labels: [ProjectLocation: String] = [:]
        for location in Set(session.gitProjectLocations.values) {
            guard !Task.isCancelled else { return }
            labels[location] = try? await workspace.git.checkoutLabel(for: location)
        }
        if !Task.isCancelled { projectCheckoutLabels = labels }
    }

    private func refreshGitChangesSummaries() async {
        let targets = gitChangesTargets
        guard !targets.isEmpty else { return }
        func pollOnce() async {
            for target in targets {
                guard !Task.isCancelled else { return }
                if let snapshot = try? await workspace.git.changesSnapshot(
                    in: target.directory, baseCommit: target.baseCommit)
                {
                    workspace.recordGitChangesSnapshot(snapshot, for: target)
                }
            }
        }
        await pollOnce()
        while !Task.isCancelled, workspace.activeRunCount(in: session.id) > 0 {
            do { try await Task.sleep(for: .seconds(4)) } catch { return }
            await pollOnce()
        }
    }

    private func boundedPaneWidth(_ proposed: CGFloat, available: CGFloat) -> CGFloat {
        let half = available / 2
        let minimum = min(CanvasStyle.terminalMinimumWidth, half)
        let maximum = available - min(CanvasStyle.canvasMinimumWidth, half)
        return min(maximum, max(minimum, proposed))
    }
}
