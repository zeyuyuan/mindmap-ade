import AppKit
import MindMapCore
import SwiftUI

struct GitChangesPane: View {
    enum Scope: String, CaseIterable, Identifiable {
        case workingTree
        case commits

        var id: String { rawValue }
    }

    let address: NodeAddress
    let session: BoardSession
    let workspace: WorkspaceStore
    let actions: EditorActions

    @State private var scope: Scope = .workingTree
    @State private var snapshot: GitChangesSnapshot?
    @State private var isLoading = false
    @State private var loadError: String?
    @State private var selectedFileID: String?
    @State private var selectedCommitHash: String?
    @State private var commitFilesByHash: [String: [GitCommitFile]] = [:]
    @State private var selectedCommitFilePath: String?
    @State private var diff: GitDiffDocument?
    @State private var isLoadingDiff = false
    @State private var diffError: String?
    @State private var listHeightShare: CGFloat = CanvasStyle.gitChangesListDefaultShare
    @State private var refreshNonce = 0

    private var nodeContext: NodeContext {
        _ = session.revision
        return session.board.context(above: address.nodeID)
    }

    private var target: GitChangesTarget? {
        _ = session.revision
        return workspace.gitChangesTarget(for: address.nodeID, in: session.board)
    }

    private var selectedFile: GitChangedFile? {
        guard let snapshot else { return nil }
        if let selectedFileID, let match = snapshot.files.first(where: { $0.id == selectedFileID }) {
            return match
        }
        return snapshot.files.first
    }

    private var selectedCommit: GitCommitSummary? {
        guard let snapshot else { return nil }
        if let selectedCommitHash, let match = snapshot.commits.first(where: { $0.hash == selectedCommitHash }) {
            return match
        }
        return snapshot.commits.first
    }

    private var selectedCommitFiles: [GitCommitFile] {
        guard let hash = selectedCommit?.hash else { return [] }
        return commitFilesByHash[hash] ?? []
    }

    private var selectedCommitFile: GitCommitFile? {
        let files = selectedCommitFiles
        if let selectedCommitFilePath, let match = files.first(where: { $0.path == selectedCommitFilePath }) {
            return match
        }
        return files.first
    }

    private struct DiffRequest: Equatable {
        let scope: Scope
        let directory: String?
        let file: GitChangedFile?
        let commitHash: String?
        let commitFile: GitCommitFile?
        let refreshNonce: Int
    }

    var body: some View {
        VStack(spacing: 0) {
            GitChangesHeader(
                snapshot: snapshot,
                directory: target?.directory,
                scope: $scope,
                isLoading: isLoading,
                onRefresh: { Task { await refresh(userInitiated: true) } },
                onRevealDirectory: revealWorktreeInFinder,
                onHide: { actions.hideRightPane() }
            )
            Divider()
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color(nsColor: .textBackgroundColor))
        .task(id: target) {
            await refresh(userInitiated: true)
            await watchChanges(for: target)
        }
        .task(id: selectedCommit?.hash) {
            await loadSelectedCommitFiles()
        }
        .task(
            id: DiffRequest(
                scope: scope,
                directory: target?.directory,
                file: scope == .workingTree ? selectedFile : nil,
                commitHash: scope == .commits ? selectedCommit?.hash : nil,
                commitFile: scope == .commits ? selectedCommitFile : nil,
                refreshNonce: refreshNonce
            )
        ) {
            await loadSelectedDiff()
        }
    }

    @ViewBuilder
    private var content: some View {
        if let problem = blockedMessage {
            ContentUnavailableView {
                Label("Git Changes Unavailable", systemImage: NodeKind.gitChanges.symbol)
            } description: {
                Text(problem)
            } actions: {
                if let target {
                    Button("Retry") {
                        Task { await refresh(userInitiated: true, overrideTarget: target) }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let loadError, snapshot == nil {
            ContentUnavailableView {
                Label("Could Not Load Git Status", systemImage: "exclamationmark.triangle")
            } description: {
                Text(loadError)
            } actions: {
                Button("Try Again") { Task { await refresh(userInitiated: true) } }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let snapshot {
            VStack(spacing: 0) {
                if let loadError {
                    HStack(spacing: CanvasStyle.formSpacing) {
                        Label(loadError, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .lineLimit(2)
                        Spacer(minLength: 0)
                        Button("Retry") { Task { await refresh(userInitiated: true) } }
                            .controlSize(.small)
                    }
                    .padding(.horizontal, CanvasStyle.statusHorizontalPadding)
                    .padding(.vertical, CanvasStyle.statusVerticalPadding)
                    .background(.bar)
                    Divider()
                }
                switch scope {
                case .workingTree:
                    workingTreeBody(snapshot)
                case .commits:
                    commitsBody(snapshot)
                }
            }
        } else {
            ProgressView("Loading Git status…")
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func workingTreeBody(_ snapshot: GitChangesSnapshot) -> some View {
        if snapshot.files.isEmpty {
            ContentUnavailableView {
                Label("Working Tree Clean", systemImage: "checkmark.circle")
            } description: {
                Text(
                    snapshot.commits.isEmpty
                        ? "Edits in this worktree will appear here automatically."
                        : "No uncommitted edits. \(snapshot.commits.count) \(snapshot.commits.count == 1 ? "commit" : "commits") recorded since the Agent started."
                )
            } actions: {
                if !snapshot.commits.isEmpty {
                    Button("View Commits") { scope = .commits }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            splitBody {
                GitWorkingTreeList(
                    files: snapshot.files,
                    directory: snapshot.directory,
                    selectedFileID: selectedFile?.id,
                    onSelect: { selectedFileID = $0.id }
                )
            } diff: {
                GitDiffViewer(
                    filePath: selectedFile?.path,
                    originalPath: selectedFile?.originalPath,
                    subtitle: selectedFile.map { "\($0.section.title) · \($0.status.accessibilityName)" },
                    directory: snapshot.directory,
                    isDeleted: selectedFile?.status == .deleted,
                    diff: diff,
                    isLoading: isLoadingDiff,
                    error: diffError
                )
            }
        }
    }

    @ViewBuilder
    private func commitsBody(_ snapshot: GitChangesSnapshot) -> some View {
        if snapshot.commits.isEmpty {
            ContentUnavailableView {
                Label("No Commits Yet", systemImage: "clock")
            } description: {
                Text("Commits created on this branch after the Agent started will appear here.")
            } actions: {
                if !snapshot.files.isEmpty {
                    Button("View Uncommitted Changes") { scope = .workingTree }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            splitBody {
                GitCommitBrowser(
                    commits: snapshot.commits,
                    selectedCommitHash: selectedCommit?.hash,
                    filesForSelectedCommit: selectedCommitFiles,
                    selectedFilePath: selectedCommitFile?.path,
                    directory: snapshot.directory,
                    onSelectCommit: { commit in
                        selectedCommitHash = commit.hash
                        selectedCommitFilePath = commitFilesByHash[commit.hash]?.first?.path
                    },
                    onSelectFile: { file in
                        selectedCommitFilePath = file.path
                    }
                )
            } diff: {
                GitDiffViewer(
                    filePath: selectedCommitFile?.path,
                    originalPath: selectedCommitFile?.originalPath,
                    subtitle: selectedCommit.map { "\($0.shortHash) · \($0.subject)" },
                    directory: snapshot.directory,
                    isDeleted: selectedCommitFile?.status == .deleted,
                    diff: diff,
                    isLoading: isLoadingDiff,
                    error: diffError
                )
            }
        }
    }

    private func splitBody<Top: View, Bottom: View>(
        @ViewBuilder top: () -> Top,
        @ViewBuilder diff: () -> Bottom
    ) -> some View {
        let topView = top()
        let diffView = diff()
        return GeometryReader { geometry in
            let handle = CanvasStyle.terminalResizeHandleWidth
            let available = max(0, geometry.size.height - handle)
            let listHeight = boundedListHeight(available * listHeightShare, available: available)
            VStack(spacing: 0) {
                topView
                    .frame(height: listHeight)
                GitHorizontalDivider(height: listHeight) { proposed in
                    if available > 0 {
                        listHeightShare = boundedListHeight(proposed, available: available) / available
                    }
                }
                .frame(height: handle)
                diffView
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func boundedListHeight(_ proposed: CGFloat, available: CGFloat) -> CGFloat {
        let half = available / 2
        let minimum = min(CanvasStyle.gitChangesListMinimumHeight, half)
        let maximum = available - min(CanvasStyle.gitChangesDiffMinimumHeight, half)
        return min(maximum, max(minimum, proposed))
    }

    private var blockedMessage: String? {
        let scope = nodeContext
        if let problem = scope.problem { return problem.message }
        guard let project = scope.project, project.gitCommonDirectory != nil else {
            return "Choose a Git project above this branch."
        }
        guard scope.worktree != nil else {
            return "Link or create a worktree above this Agent to inspect Git changes."
        }
        return nil
    }

    private func revealWorktreeInFinder() {
        guard let directory = target?.directory else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: directory)])
    }

    private func refresh(userInitiated: Bool, overrideTarget: GitChangesTarget? = nil) async {
        guard let currentTarget = overrideTarget ?? target else {
            snapshot = nil
            diff = nil
            loadError = nil
            return
        }
        if userInitiated { isLoading = true }
        defer { if userInitiated { isLoading = false } }
        do {
            let loaded = try await workspace.git.changesSnapshot(
                in: currentTarget.directory, baseCommit: currentTarget.baseCommit)
            guard !Task.isCancelled else { return }
            snapshot = loaded
            loadError = nil
            workspace.recordGitChangesSnapshot(loaded, for: currentTarget)
            if let current = selectedFileID, !loaded.files.contains(where: { $0.id == current }) {
                selectedFileID = loaded.files.first?.id
            } else if selectedFileID == nil {
                selectedFileID = loaded.files.first?.id
            }
            if let current = selectedCommitHash, !loaded.commits.contains(where: { $0.hash == current }) {
                selectedCommitHash = loaded.commits.first?.hash
                selectedCommitFilePath = nil
            } else if selectedCommitHash == nil {
                selectedCommitHash = loaded.commits.first?.hash
            }
            let validHashes = Set(loaded.commits.map(\.hash))
            commitFilesByHash = commitFilesByHash.filter { validHashes.contains($0.key) }
            refreshNonce += 1
        } catch {
            guard !Task.isCancelled else { return }
            loadError = error.localizedDescription
        }
    }

    private func watchChanges(for target: GitChangesTarget?) async {
        guard let target else { return }
        var paths = [target.directory]
        if let gitDir = try? await workspace.git.gitDirectory(in: target.directory), !gitDir.isEmpty {
            paths.append(gitDir)
        }
        guard !Task.isCancelled else { return }
        let stream = AsyncStream<Void>(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let watcher = GitDirectoryWatcher(paths: paths) {
                continuation.yield(())
            }
            continuation.onTermination = { _ in
                watcher.stop()
            }
        }
        for await _ in stream {
            guard !Task.isCancelled else { break }
            do { try await Task.sleep(for: .milliseconds(350)) } catch { break }
            guard !Task.isCancelled else { break }
            await refresh(userInitiated: false, overrideTarget: target)
        }
    }

    private func loadSelectedCommitFiles() async {
        guard let directory = target?.directory, let hash = selectedCommit?.hash else { return }
        if let cached = commitFilesByHash[hash] {
            if selectedCommitFilePath == nil || !cached.contains(where: { $0.path == selectedCommitFilePath }) {
                selectedCommitFilePath = cached.first?.path
            }
            return
        }
        do {
            let files = try await workspace.git.commitFiles(for: hash, in: directory)
            guard !Task.isCancelled else { return }
            commitFilesByHash[hash] = files
            if selectedCommit?.hash == hash {
                selectedCommitFilePath = files.first?.path
            }
        } catch {
            guard !Task.isCancelled else { return }
            diffError = error.localizedDescription
        }
    }

    private func loadSelectedDiff() async {
        guard let directory = target?.directory else {
            diff = nil
            diffError = nil
            return
        }
        switch scope {
        case .workingTree:
            guard let file = selectedFile else {
                diff = nil
                diffError = nil
                return
            }
            isLoadingDiff = true
            defer { isLoadingDiff = false }
            do {
                let loaded = try await workspace.git.workingTreeDiff(for: file, in: directory)
                guard !Task.isCancelled else { return }
                diff = loaded
                diffError = nil
            } catch {
                guard !Task.isCancelled else { return }
                diff = nil
                diffError = error.localizedDescription
            }
        case .commits:
            guard let commit = selectedCommit, let file = selectedCommitFile else {
                diff = nil
                diffError = nil
                return
            }
            isLoadingDiff = true
            defer { isLoadingDiff = false }
            do {
                let loaded = try await workspace.git.commitFileDiff(commit: commit.hash, file: file, in: directory)
                guard !Task.isCancelled else { return }
                diff = loaded
                diffError = nil
            } catch {
                guard !Task.isCancelled else { return }
                diff = nil
                diffError = error.localizedDescription
            }
        }
    }
}

private struct GitChangesHeader: View {
    let snapshot: GitChangesSnapshot?
    let directory: String?
    @Binding var scope: GitChangesPane.Scope
    let isLoading: Bool
    let onRefresh: () -> Void
    let onRevealDirectory: () -> Void
    let onHide: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: CanvasStyle.formCompactSpacing) {
            HStack(spacing: CanvasStyle.formSpacing) {
                Label("Git Changes", systemImage: NodeKind.gitChanges.symbol)
                    .font(.headline)
                    .lineLimit(1)
                    .help(directory ?? "Git Changes")
                Spacer(minLength: 0)
                if isLoading {
                    ProgressView()
                        .controlSize(.mini)
                        .accessibilityLabel("Refreshing Git changes")
                }
                Button("Refresh", systemImage: "arrow.clockwise", action: onRefresh)
                    .labelStyle(.iconOnly)
                    .help("Refresh Git Changes")
                    .disabled(directory == nil || isLoading)
                if directory != nil {
                    Button("Show in Finder", systemImage: "folder", action: onRevealDirectory)
                        .labelStyle(.iconOnly)
                        .help("Show Worktree in Finder")
                }
                Button("Hide Git Changes", systemImage: "xmark", action: onHide)
                    .labelStyle(.iconOnly)
                    .help("Hide Git Changes")
            }

            if let snapshot {
                HStack(spacing: CanvasStyle.formSpacing) {
                    Label(snapshot.branchLabel, systemImage: NodeKind.worktree.symbol)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(snapshot.directory)
                    if snapshot.ahead > 0 || snapshot.behind > 0 {
                        HStack(spacing: CanvasStyle.formCompactSpacing) {
                            if snapshot.ahead > 0 { Text("↑\(snapshot.ahead)") }
                            if snapshot.behind > 0 { Text("↓\(snapshot.behind)") }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .fixedSize()
                    }
                    Spacer(minLength: 0)
                    if snapshot.totalAdditions > 0 || snapshot.totalDeletions > 0 {
                        HStack(spacing: CanvasStyle.formCompactSpacing) {
                            if snapshot.totalAdditions > 0 {
                                Text("+\(snapshot.totalAdditions)")
                                    .foregroundStyle(Color(nsColor: .systemGreen))
                            }
                            if snapshot.totalDeletions > 0 {
                                Text("-\(snapshot.totalDeletions)")
                                    .foregroundStyle(Color(nsColor: .systemRed))
                            }
                        }
                        .font(.caption.weight(.medium))
                        .monospacedDigit()
                        .fixedSize()
                    }
                }

                Picker("Scope", selection: $scope) {
                    Text(changesTabTitle(snapshot)).tag(GitChangesPane.Scope.workingTree)
                    Text(commitsTabTitle(snapshot)).tag(GitChangesPane.Scope.commits)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.top, CanvasStyle.formCompactSpacing)
            }
        }
        .controlSize(.small)
        .buttonStyle(.borderless)
        .padding(.horizontal, CanvasStyle.statusHorizontalPadding)
        .padding(.vertical, CanvasStyle.statusVerticalPadding)
        .background(.bar)
    }

    private func changesTabTitle(_ snapshot: GitChangesSnapshot) -> String {
        snapshot.uniqueFileCount > 0 ? "Changes (\(snapshot.uniqueFileCount))" : "Changes"
    }

    private func commitsTabTitle(_ snapshot: GitChangesSnapshot) -> String {
        snapshot.commits.isEmpty ? "Commits" : "Commits (\(snapshot.commits.count))"
    }
}

private struct GitWorkingTreeList: View {
    let files: [GitChangedFile]
    let directory: String
    let selectedFileID: String?
    let onSelect: (GitChangedFile) -> Void

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: CanvasStyle.formCompactSpacing) {
                ForEach(GitFileSection.allCases, id: \.self) { section in
                    let sectionFiles = files.filter { $0.section == section }
                    if !sectionFiles.isEmpty {
                        HStack(spacing: CanvasStyle.formCompactSpacing) {
                            Text(section.title)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Text("\(sectionFiles.count)")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                                .monospacedDigit()
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, CanvasStyle.formSpacing)
                        .padding(.top, CanvasStyle.formCompactSpacing)

                        ForEach(sectionFiles) { file in
                            GitFileRow(
                                status: file.status,
                                fileName: file.fileName,
                                directoryPath: file.directoryPath,
                                fullRelativePath: file.path,
                                worktreeDirectory: directory,
                                additions: file.additions,
                                deletions: file.deletions,
                                isBinary: file.isBinary,
                                isSelected: file.id == selectedFileID,
                                onSelect: { onSelect(file) }
                            )
                        }
                    }
                }
            }
            .padding(.horizontal, CanvasStyle.formSpacing)
            .padding(.vertical, CanvasStyle.formCompactSpacing)
        }
        .accessibilityLabel("Changed files")
    }
}

private struct GitCommitBrowser: View {
    let commits: [GitCommitSummary]
    let selectedCommitHash: String?
    let filesForSelectedCommit: [GitCommitFile]
    let selectedFilePath: String?
    let directory: String
    let onSelectCommit: (GitCommitSummary) -> Void
    let onSelectFile: (GitCommitFile) -> Void

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: CanvasStyle.formCompactSpacing) {
                ForEach(commits) { commit in
                    let isSelected = commit.hash == selectedCommitHash
                    Button {
                        onSelectCommit(commit)
                    } label: {
                        HStack(alignment: .firstTextBaseline, spacing: CanvasStyle.formSpacing) {
                            Text(commit.shortHash)
                                .font(.system(.caption, design: .monospaced).weight(.medium))
                                .foregroundStyle(.secondary)
                                .fixedSize()
                            VStack(alignment: .leading, spacing: 2) {
                                Text(commit.subject)
                                    .font(.callout)
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                HStack(spacing: CanvasStyle.formCompactSpacing) {
                                    Text(commit.author)
                                        .lineLimit(1)
                                    if commit.fileCount > 0 {
                                        Text("· \(commit.fileCount) \(commit.fileCount == 1 ? "file" : "files")")
                                    }
                                    if commit.additions > 0 {
                                        Text("+\(commit.additions)")
                                            .foregroundStyle(Color(nsColor: .systemGreen))
                                    }
                                    if commit.deletions > 0 {
                                        Text("-\(commit.deletions)")
                                            .foregroundStyle(Color(nsColor: .systemRed))
                                    }
                                }
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, CanvasStyle.formSpacing)
                        .padding(.vertical, CanvasStyle.formCompactSpacing)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(
                                    isSelected
                                        ? Color(nsColor: .selectedContentBackgroundColor).opacity(
                                            CanvasStyle.findSelectionOpacity)
                                        : .clear)
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("\(commit.shortHash) — \(commit.subject)")
                    .contextMenu {
                        Button("Copy Commit Hash") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(commit.hash, forType: .string)
                        }
                        Button("Copy Commit Subject") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(commit.subject, forType: .string)
                        }
                    }

                    if isSelected {
                        ForEach(filesForSelectedCommit) { file in
                            GitFileRow(
                                status: file.status,
                                fileName: file.fileName,
                                directoryPath: file.directoryPath,
                                fullRelativePath: file.path,
                                worktreeDirectory: directory,
                                additions: file.additions,
                                deletions: file.deletions,
                                isBinary: file.isBinary,
                                isSelected: file.path == selectedFilePath,
                                onSelect: { onSelectFile(file) }
                            )
                            .padding(.leading, CanvasStyle.formGroupSpacing)
                        }
                    }
                }
            }
            .padding(.horizontal, CanvasStyle.formSpacing)
            .padding(.vertical, CanvasStyle.formCompactSpacing)
        }
        .accessibilityLabel("Commits")
    }
}

private struct GitFileRow: View {
    let status: GitFileStatus
    let fileName: String
    let directoryPath: String?
    let fullRelativePath: String
    let worktreeDirectory: String
    let additions: Int?
    let deletions: Int?
    let isBinary: Bool
    let isSelected: Bool
    let onSelect: () -> Void

    private var fileURL: URL {
        URL(fileURLWithPath: worktreeDirectory).appendingPathComponent(fullRelativePath)
    }

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: CanvasStyle.formSpacing) {
                Text(status.rawValue)
                    .font(.system(.caption, design: .monospaced).weight(.semibold))
                    .foregroundStyle(statusColor)
                    .frame(width: 14, alignment: .center)
                    .accessibilityLabel(status.accessibilityName)

                HStack(spacing: CanvasStyle.formCompactSpacing) {
                    Text(fileName)
                        .font(.callout)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .layoutPriority(1)
                    if let directoryPath {
                        Text(directoryPath)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if isBinary {
                    Text("BIN")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                        .fixedSize()
                } else if (additions ?? 0) > 0 || (deletions ?? 0) > 0 {
                    HStack(spacing: CanvasStyle.formCompactSpacing) {
                        if let additions, additions > 0 {
                            Text("+\(additions)")
                                .foregroundStyle(Color(nsColor: .systemGreen))
                        }
                        if let deletions, deletions > 0 {
                            Text("-\(deletions)")
                                .foregroundStyle(Color(nsColor: .systemRed))
                        }
                    }
                    .font(.caption)
                    .monospacedDigit()
                    .fixedSize()
                }
            }
            .padding(.horizontal, CanvasStyle.formSpacing)
            .padding(.vertical, CanvasStyle.formCompactSpacing)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(
                        isSelected
                            ? Color(nsColor: .selectedContentBackgroundColor).opacity(CanvasStyle.findSelectionOpacity)
                            : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(fullRelativePath)
        .contextMenu {
            if status != .deleted {
                Button("Open File") { NSWorkspace.shared.open(fileURL) }
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([fileURL]) }
                Divider()
            }
            Button("Copy Relative Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(fullRelativePath, forType: .string)
            }
            Button("Copy Full Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(fileURL.path, forType: .string)
            }
        }
    }

    private var statusColor: Color {
        switch status {
        case .added, .untracked: Color(nsColor: .systemGreen)
        case .deleted, .unmerged: Color(nsColor: .systemRed)
        case .modified, .renamed, .copied, .typeChanged: Color(nsColor: .systemOrange)
        }
    }
}

private struct GitDiffViewer: View {
    let filePath: String?
    let originalPath: String?
    let subtitle: String?
    let directory: String
    let isDeleted: Bool
    let diff: GitDiffDocument?
    let isLoading: Bool
    let error: String?

    var body: some View {
        VStack(spacing: 0) {
            if let filePath {
                HStack(spacing: CanvasStyle.formSpacing) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(filePath)
                            .font(.caption.weight(.medium))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(originalPath.map { "\($0) → \(filePath)" } ?? filePath)
                        if let subtitle {
                            Text(subtitle)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                    }
                    Spacer(minLength: 0)
                    if let diff, !diff.rawText.isEmpty {
                        Button("Copy Diff", systemImage: "document.on.document") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(diff.rawText, forType: .string)
                        }
                        .labelStyle(.iconOnly)
                        .help("Copy Diff")
                    }
                    if !isDeleted {
                        Button("Show in Finder", systemImage: "arrow.up.right.square") {
                            let url = URL(fileURLWithPath: directory).appendingPathComponent(filePath)
                            NSWorkspace.shared.activateFileViewerSelecting([url])
                        }
                        .labelStyle(.iconOnly)
                        .help("Show File in Finder")
                    }
                }
                .controlSize(.small)
                .buttonStyle(.borderless)
                .padding(.horizontal, CanvasStyle.statusHorizontalPadding)
                .padding(.vertical, CanvasStyle.formCompactSpacing)
                .background(.bar)
                Divider()
            }
            diffBody
        }
    }

    @ViewBuilder
    private var diffBody: some View {
        if let error {
            ContentUnavailableView {
                Label("Could Not Load Diff", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if isLoading && diff == nil {
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let diff {
            if diff.isBinary {
                ContentUnavailableView {
                    Label("Binary File", systemImage: "doc.zipper")
                } description: {
                    Text("Diff preview is unavailable for binary files.")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if diff.isEmpty {
                ContentUnavailableView {
                    Label("No Text Changes", systemImage: "doc.text")
                } description: {
                    Text("This file has no text diff lines to display.")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                GeometryReader { geometry in
                    ScrollView([.horizontal, .vertical]) {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(diff.lines) { line in
                                GitDiffLineRow(line: line)
                            }
                            if diff.isTruncated {
                                Text("Diff truncated after \(GitDiffDocument.maxRenderedLines.formatted()) lines.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, CanvasStyle.statusHorizontalPadding)
                                    .padding(.vertical, CanvasStyle.statusVerticalPadding)
                            }
                        }
                        .frame(minWidth: geometry.size.width, minHeight: geometry.size.height, alignment: .topLeading)
                    }
                    .textSelection(.enabled)
                    .accessibilityLabel("File diff")
                }
            }
        } else {
            ContentUnavailableView {
                Label("Select a File", systemImage: "doc.text.magnifyingglass")
            } description: {
                Text("Choose a changed file above to inspect its diff.")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct GitDiffLineRow: View {
    let line: GitDiffDocument.Line

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            if line.kind == .hunk || line.kind == .meta {
                Text(verbatim: line.text)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, CanvasStyle.formSpacing)
                    .padding(.vertical, 2)
            } else {
                Text(line.oldLineNumber.map(String.init) ?? "")
                    .frame(width: 38, alignment: .trailing)
                    .foregroundStyle(.tertiary)
                    .padding(.trailing, CanvasStyle.formCompactSpacing)
                Text(line.newLineNumber.map(String.init) ?? "")
                    .frame(width: 38, alignment: .trailing)
                    .foregroundStyle(.tertiary)
                    .padding(.trailing, CanvasStyle.formSpacing)
                Text(prefixMarker)
                    .frame(width: 12, alignment: .center)
                    .foregroundStyle(markerColor)
                    .padding(.trailing, CanvasStyle.formCompactSpacing)
                Text(verbatim: line.text.isEmpty ? " " : line.text)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(.trailing, CanvasStyle.statusHorizontalPadding)
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 11, design: .monospaced))
        .monospacedDigit()
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 1)
        .background(backgroundColor)
    }

    private var prefixMarker: String {
        switch line.kind {
        case .addition: "+"
        case .deletion: "-"
        default: " "
        }
    }

    private var markerColor: Color {
        switch line.kind {
        case .addition: Color(nsColor: .systemGreen)
        case .deletion: Color(nsColor: .systemRed)
        default: .secondary
        }
    }

    private var backgroundColor: Color {
        switch line.kind {
        case .addition: Color(nsColor: .systemGreen).opacity(CanvasStyle.diffAdditionOpacity)
        case .deletion: Color(nsColor: .systemRed).opacity(CanvasStyle.diffDeletionOpacity)
        case .hunk: Color(nsColor: .controlAccentColor).opacity(CanvasStyle.diffHunkOpacity)
        case .context, .meta: .clear
        }
    }
}

private struct GitHorizontalDivider: NSViewRepresentable {
    let height: CGFloat
    let resize: (CGFloat) -> Void

    func makeNSView(context: Context) -> Grip {
        let view = Grip()
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.slider)
        view.setAccessibilityLabel("Changed files list height")
        return view
    }

    func updateNSView(_ view: Grip, context: Context) {
        view.listHeight = height
        view.resize = resize
        view.setAccessibilityValue("\(Int(height)) points")
    }

    final class Grip: NSView {
        var listHeight: CGFloat = 0
        var resize: ((CGFloat) -> Void)?
        private var dragOrigin: (y: CGFloat, height: CGFloat)?

        override func draw(_ dirtyRect: NSRect) {
            NSColor.separatorColor.setFill()
            CGRect(x: 0, y: bounds.midY, width: bounds.width, height: CanvasStyle.borderWidth).fill()
        }

        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .rowResize)
        }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func accessibilityPerformIncrement() -> Bool {
            resize?(listHeight + CanvasStyle.terminalResizeStep)
            return resize != nil
        }

        override func accessibilityPerformDecrement() -> Bool {
            resize?(listHeight - CanvasStyle.terminalResizeStep)
            return resize != nil
        }

        override func mouseDown(with event: NSEvent) {
            dragOrigin = (event.locationInWindow.y, listHeight)
        }

        override func mouseDragged(with event: NSEvent) {
            guard let origin = dragOrigin else { return }
            // Window coordinates grow upward, so dragging downward increases the top pane height.
            resize?(origin.height + origin.y - event.locationInWindow.y)
        }

        override func mouseUp(with event: NSEvent) { dragOrigin = nil }
    }
}
