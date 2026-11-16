import AppKit
import MindMapCore
import SwiftUI

struct BoardFindBar: View {
    let session: BoardSession
    let actions: EditorActions
    @State private var query = ""
    @State private var results: Results?
    @State private var selectedID: UUID?
    @State private var moreTask: Task<Void, Never>?

    private struct Request: Equatable {
        let query: String
        let revision: Int
    }

    private struct Results {
        let request: Request
        var matches: [MapSearch.Match]
        var next: MapSearch.Traversal?
    }

    private var request: Request {
        Request(query: query.trimmingCharacters(in: .whitespacesAndNewlines), revision: session.revision)
    }

    private var currentResults: Results? { results?.request == request ? results : nil }

    var body: some View {
        let request = request
        VStack(spacing: 0) {
            HStack(spacing: CanvasStyle.findRowPadding) {
                TopicSearchField(
                    query: $query, focusRequest: actions.findFocusRequest,
                    moveSelection: moveSelection, submit: jumpToSelection, close: actions.closeFind,
                    focusChanged: { actions.findFieldHasFocus = $0 })
                Button("Close Find", systemImage: "xmark", action: actions.closeFind)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help("Close Find (Esc)")
            }
            .padding(CanvasStyle.findBarPadding)
            if !request.query.isEmpty {
                Divider()
                if let currentResults {
                    if currentResults.matches.isEmpty {
                        message("No topics match “\(request.query)”")
                    } else {
                        resultList(currentResults)
                    }
                } else {
                    ProgressView().controlSize(.small).padding(CanvasStyle.findRowPadding)
                }
            }
        }
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
        .task(id: request) {
            moreTask?.cancel()
            moreTask = nil
            selectedID = nil
            guard !request.query.isEmpty,
                let page = try? await MapSearch.page(
                    for: request.query, in: session.board, from: .init(root: nil), pageSize: 32),
                !Task.isCancelled
            else { return }
            results = Results(request: request, matches: page.matches, next: page.next)
            selectedID = page.matches.first?.id
        }
        .onDisappear {
            moreTask?.cancel()
            actions.findFieldHasFocus = false
        }
    }

    private func message(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(CanvasStyle.findBarPadding)
    }

    private func resultList(_ results: Results) -> some View {
        let rowCount = results.matches.count + (results.next == nil ? 0 : 1)
        return ScrollViewReader { scroll in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(results.matches) { match in
                        if let node = session.board.nodes[match.id] {
                            resultRow(node, match: match)
                        }
                    }
                    if results.next != nil {
                        Button("More Results") { loadMore(moveSelection: false) }
                            .buttonStyle(.borderless)
                            .disabled(moreTask != nil)
                            .frame(maxWidth: .infinity, minHeight: CanvasStyle.findResultRowHeight)
                    }
                }
            }
            .frame(
                height: min(CGFloat(rowCount) * CanvasStyle.findResultRowHeight, CanvasStyle.findResultsMaximumHeight)
            )
            .onChange(of: selectedID) { _, id in
                if let id { scroll.scrollTo(id) }
            }
        }
    }

    private func resultRow(_ node: MapNode, match: MapSearch.Match) -> some View {
        let location = path(to: node.id)
        let isSelected = selectedID == match.id
        return Button {
            selectedID = node.id
            actions.showFindResult(node.id)
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                Text(node.title).lineLimit(1)
                if !location.isEmpty {
                    Text(location).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                }
            }
            .padding(.horizontal, CanvasStyle.findBarPadding)
            .frame(maxWidth: .infinity, minHeight: CanvasStyle.findResultRowHeight, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            isSelected
                ? Color(nsColor: .selectedContentBackgroundColor).opacity(CanvasStyle.findSelectionOpacity) : .clear
        )
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .help(match.snippet)
    }

    private func path(to id: UUID) -> String {
        let board = session.board
        let parents = board.parents
        var ancestors: [String] = []
        var parent = parents[id]
        while let id = parent, let node = board.nodes[id], ancestors.count < 4 {
            let title = node.title.split(whereSeparator: \.isNewline).first.map(String.init) ?? node.title
            ancestors.append(String(title.prefix(80)))
            parent = parents[id]
        }
        if parent != nil { ancestors.append("…") }
        return ancestors.reversed().joined(separator: " › ")
    }

    private func moveSelection(_ step: Int) {
        guard let currentResults,
            let index = currentResults.matches.firstIndex(where: { $0.id == selectedID })
        else { return }
        let next = index + step
        if currentResults.matches.indices.contains(next) {
            selectedID = currentResults.matches[next].id
        } else if next == currentResults.matches.count {
            loadMore(moveSelection: true)
        }
    }

    private func jumpToSelection() {
        guard let selectedID, currentResults?.matches.contains(where: { $0.id == selectedID }) == true else { return }
        actions.showFindResult(selectedID)
    }

    private func loadMore(moveSelection: Bool) {
        guard moreTask == nil, let current = currentResults, let next = current.next else { return }
        let board = session.board
        moreTask = Task {
            defer { if !Task.isCancelled { moreTask = nil } }
            guard
                let page = try? await MapSearch.page(
                    for: current.request.query, in: board, from: next, pageSize: 32),
                !Task.isCancelled, current.request == request
            else { return }
            results = Results(request: current.request, matches: current.matches + page.matches, next: page.next)
            if moveSelection, let first = page.matches.first { selectedID = first.id }
        }
    }
}

private struct TopicSearchField: NSViewRepresentable {
    @Binding var query: String
    let focusRequest: Int
    let moveSelection: (Int) -> Void
    let submit: () -> Void
    let close: () -> Void
    let focusChanged: (Bool) -> Void

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = "Find in this board"
        field.setAccessibilityLabel("Find topics")
        field.delegate = context.coordinator
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        if field.stringValue != query { field.stringValue = query }
        guard coordinator.focusRequest != focusRequest else { return }
        coordinator.focusRequest = focusRequest
        DispatchQueue.main.async { [weak field] in field?.selectText(nil) }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent: TopicSearchField
        var focusRequest: Int?

        init(_ parent: TopicSearchField) { self.parent = parent }

        func controlTextDidBeginEditing(_ notification: Notification) { parent.focusChanged(true) }
        func controlTextDidEndEditing(_ notification: Notification) { parent.focusChanged(false) }

        func controlTextDidChange(_ notification: Notification) {
            if let field = notification.object as? NSSearchField { parent.query = field.stringValue }
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard !textView.hasMarkedText() else { return false }
            switch selector {
            case #selector(NSResponder.moveUp(_:)): parent.moveSelection(-1)
            case #selector(NSResponder.moveDown(_:)): parent.moveSelection(1)
            case #selector(NSResponder.insertNewline(_:)): parent.submit()
            case #selector(NSResponder.cancelOperation(_:)): parent.close()
            default: return false
            }
            return true
        }
    }
}
