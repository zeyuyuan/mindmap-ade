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
            workspaceNotices
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
        .onChange(of: actions.requestedBoardID) { _, id in if let id { selectedBoardID = id } }
        .onChange(of: selectedBoardID) { _, id in
            actions.targetBoardID = id
            workspace.select(id)
        }
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
                            .tag(board.id)
                            .contextMenu {
                                Button("Rename…") {
                                    renamingID = board.id
                                    boardName = board.name
                                }
                                .disabled(workspace.isReadOnly)
                                Button("Delete Board", role: .destructive) { workspace.deleteBoard(board.id) }
                                    .disabled(workspace.isReadOnly)
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
    private var workspaceNotices: some View {
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
        if let name = workspace.deletedBoardName {
            HStack {
                Text("Deleted “\(name)”.")
                Button("Undo") { workspace.undoDeleteBoard() }
                Spacer()
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

    var body: some View {
        MindMapCanvas(session: session, workspace: workspace, actions: actions, revision: session.revision)
            .navigationTitle(session.name)
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
}
