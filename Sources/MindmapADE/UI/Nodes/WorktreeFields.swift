import MindMapCore
import SwiftUI

struct WorktreeFields: View {
    @Bindable var model: NodeFormModel
    let project: ProjectLocation
    @State private var trees: [WorktreeLocation] = []
    @State private var loadError: String?
    @State private var refresh = 0

    private var choice: WorktreeChoice { model.worktreeChoice }
    private var isAgent: Bool { model.content.kind == .agent }
    private var showsExisting: Bool { !isAgent || choice.mode == .existing }
    private var linkableTrees: [WorktreeLocation] {
        guard !isAgent, model.worktree.location?.directory != project.directory else { return trees }
        return trees.filter { $0.directory != project.directory }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: CanvasStyle.formSpacing) {
            if isAgent {
                Picker("Worktree", selection: linkMode) {
                    Text("Create New").tag(false)
                    Text("Use Existing").tag(true)
                }
                .pickerStyle(.segmented)
            }
            if showsExisting {
                existingFields
                if let loadError {
                    Label(loadError, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                    Button("Retry", systemImage: "arrow.clockwise") { refresh += 1 }
                }
            } else {
                nameField
            }
        }
        .task(id: LoadKey(project: project, showsExisting: showsExisting, refresh: refresh)) {
            if showsExisting { await loadWorktrees() }
        }
    }

    private var nameField: some View {
        let suggestion =
            choice.pendingPlan.map { URL(fileURLWithPath: $0.directory).lastPathComponent }
            ?? model.worktreeNames(for: WorktreeChoice()).name
        return VStack(alignment: .leading, spacing: CanvasStyle.formCompactSpacing) {
            TextField("Worktree Name (Optional)", text: newName, prompt: Text(suggestion))
                .textFieldStyle(.roundedBorder)
                .help("Leave blank to use the suggested worktree name.")
            if choice.mode == .named && !GitWorkspace.isValidFolderName(choice.name) {
                Text(GitWorkspace.folderNameHelp).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var existingFields: some View {
        if model.worktreesReady {
            if linkableTrees.isEmpty {
                Label("No other worktrees to link", systemImage: "folder").fontWeight(.medium)
                Text("Create a worktree first, then refresh this list.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                refreshButton
            } else if isAgent {
                HStack(spacing: CanvasStyle.formSpacing) {
                    worktreePicker
                        .labelsHidden()
                        .help(choice.existingDirectory.isEmpty ? "Select a worktree" : choice.existingDirectory)
                    refreshButton.labelStyle(.iconOnly)
                }
                if let tree = linkableTrees.first(where: { $0.directory == choice.existingDirectory }),
                    tree.isPrimary || tree.directory == project.directory
                {
                    Text("Agent changes will affect this checkout.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                worktreePicker
                if !choice.existingDirectory.isEmpty { pathLabel(choice.existingDirectory) }
                refreshButton
            }
        } else if loadError == nil {
            HStack(spacing: CanvasStyle.formSpacing) {
                ProgressView().controlSize(.small)
                Text("Finding worktrees…").foregroundStyle(.secondary)
            }
        }
    }

    private var worktreePicker: some View {
        Picker("Worktree", selection: $model.worktreeChoice.existingDirectory) {
            Text("Select a worktree").tag("")
            ForEach(linkableTrees, id: \.directory) { tree in
                Text("\(name(of: tree)) · \(tree.revisionLabel)").tag(tree.directory)
            }
        }
    }

    private var refreshButton: some View {
        Button("Refresh", systemImage: "arrow.clockwise") { refresh += 1 }
            .buttonStyle(.borderless)
            .help("Refresh worktrees")
    }

    private func name(of tree: WorktreeLocation) -> String {
        if tree.directory == project.directory { return "Current checkout" }
        return tree.isPrimary ? "Main worktree" : tree.name
    }

    private var linkMode: Binding<Bool> {
        Binding(
            get: { choice.mode == .existing },
            set: { useExisting in
                let hasName = !choice.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                let mode: WorktreeChoice.Mode = useExisting ? .existing : (hasName ? .named : .automatic)
                guard choice.mode != mode else { return }
                model.worktreesReady = false
                model.worktreeChoice.mode = mode
            })
    }

    private var newName: Binding<String> {
        Binding(
            get: { choice.mode == .named ? choice.name : "" },
            set: { name in
                var updated = choice
                let isEmpty = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                updated.name = isEmpty ? "" : name
                updated.mode = isEmpty ? .automatic : .named
                model.worktreeChoice = updated
            })
    }

    private func loadWorktrees() async {
        model.worktreesReady = false
        loadError = nil
        do {
            let result = try await model.workspace.git.worktrees(for: project)
            guard !Task.isCancelled else { return }
            trees = result
            if !linkableTrees.contains(where: { $0.directory == choice.existingDirectory }) {
                model.worktreeChoice.existingDirectory = ""
            }
            model.worktreesReady = true
        } catch {
            guard !Task.isCancelled else { return }
            trees = []
            loadError = error.localizedDescription
        }
    }

    private struct LoadKey: Equatable {
        let project: ProjectLocation
        let showsExisting: Bool
        let refresh: Int
    }
}
