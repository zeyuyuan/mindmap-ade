import AppKit
import MindMapCore
import SwiftUI

struct RootView: View {
    let workspace: WorkspaceStore
    @State private var selectedBoardID: UUID?
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
            if selectedBoardID == nil {
                selectedBoardID = workspace.board(workspace.lastSelectedBoardID)?.id ?? workspace.boards.first?.id
                actions.targetBoardID = selectedBoardID
            }
        }
        .onChange(of: actions.requestedBoardID) { _, id in
            if let id {
                selectedBoardID = id
                actions.requestedBoardID = nil
            }
        }
        .onChange(of: selectedBoardID) { _, id in
            actions.targetBoardID = id
            workspace.select(id)
        }
        .onDisappear { actions.hideTerminal() }
        .onChange(of: workspace.boards.map(\.id)) { _, ids in
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
    @State private var terminalWidthShare: CGFloat = 0.5
    @State private var projectCheckoutLabels: [ProjectLocation: String] = [:]
    @State private var activationCount = 0

    private struct CheckoutRefresh: Equatable {
        let boardID: UUID
        let locations: [UUID: ProjectLocation]
        let activationCount: Int
    }

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                MindMapCanvas(
                    session: session, workspace: workspace, actions: actions, revision: session.revision,
                    runtimeDetails: runtimeDetails
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                if let address = actions.terminalAddress, address.boardID == session.id,
                    let terminal = workspace.terminals[address], session.board.nodes[address.nodeID] != nil
                {
                    let available = max(0, geometry.size.width - CanvasStyle.terminalResizeHandleWidth)
                    let width = boundedTerminalWidth(available * terminalWidthShare, available: available)
                    TerminalDivider(width: width) { proposed in
                        if available > 0 {
                            terminalWidthShare = boundedTerminalWidth(proposed, available: available) / available
                        }
                    }
                    .frame(width: CanvasStyle.terminalResizeHandleWidth)
                    AgentTerminalPane(
                        address: address, session: session, workspace: workspace, actions: actions, terminal: terminal
                    )
                    .frame(width: width)
                    .id(address)
                }
            }
        }
        .navigationTitle(session.name)
        .task(
            id: CheckoutRefresh(
                boardID: session.id, locations: session.gitProjectLocations, activationCount: activationCount
            )
        ) {
            await refreshProjectCheckoutLabels()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            activationCount += 1
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack {
                Text(actions.hint).lineLimit(1)
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

    private func boundedTerminalWidth(_ proposed: CGFloat, available: CGFloat) -> CGFloat {
        let half = available / 2
        let minimum = min(CanvasStyle.terminalMinimumWidth, half)
        let maximum = available - min(CanvasStyle.canvasMinimumWidth, half)
        return min(maximum, max(minimum, proposed))
    }
}
