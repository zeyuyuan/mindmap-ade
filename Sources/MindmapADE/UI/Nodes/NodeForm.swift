import AppKit
import MindMapCore
import Observation
import SwiftUI

@Observable
final class NodeFormModel {
    let address: NodeAddress
    let session: BoardSession
    let workspace: WorkspaceStore
    var content: NodeContent {
        didSet { if content != oldValue { workspace.updateDraft(at: address, content: content) } }
    }
    var error: String?
    var worktreesReady = false
    let close: () -> Void
    let showNode: (UUID) -> Void
    let showTerminal: () -> Void

    init(
        address: NodeAddress, session: BoardSession, workspace: WorkspaceStore,
        close: @escaping () -> Void, showNode: @escaping (UUID) -> Void, showTerminal: @escaping () -> Void
    ) {
        self.address = address
        self.session = session
        self.workspace = workspace
        self.close = close
        self.showNode = showNode
        self.showTerminal = showTerminal
        let stored = session.board.nodes[address.nodeID]?.content ?? .text
        if case .worktree(var worktree) = stored {
            if let location = worktree.location {
                worktree.choice = WorktreeChoice(mode: .existing)
                worktree.choice.existingDirectory = location.directory
            }
            content = .worktree(worktree)
        } else {
            content = stored
        }
    }

    var context: NodeContext {
        _ = session.revision
        return session.board.context(above: address.nodeID)
    }
    var isBusy: Bool { workspace.operations.contains(address) }
    var isDraft: Bool { content.isDraft }
    var showsWorktreeDetails: Bool {
        worktree.location != nil
            && (context.worktreeID != nil || workspace.hasDerivedWorktrees(address.nodeID, in: session.board))
    }

    var worktreeProject: ProjectLocation? {
        let context = context
        guard content.kind == .worktree, !showsWorktreeDetails, context.problem == nil,
            let project = context.project, project.gitCommonDirectory != nil
        else { return nil }
        return project
    }

    var canSaveWorktree: Bool {
        worktreeProject != nil && selectionIsComplete(worktree.choice)
    }

    func selectionIsComplete(_ choice: WorktreeChoice) -> Bool {
        switch choice.mode {
        case .existing: worktreesReady && context.worktreeID == nil && !choice.existingDirectory.isEmpty
        case .automatic: true
        case .named: GitWorkspace.isValidFolderName(choice.name)
        }
    }

    func submitWorktree() {
        guard canSaveWorktree, !isBusy else { return }
        Task { await save() }
    }

    var project: ProjectTopic {
        get { if case .project(let value) = content { value } else { ProjectTopic() } }
        set { content = .project(newValue) }
    }
    var worktree: WorktreeTopic {
        get { if case .worktree(let value) = content { value } else { WorktreeTopic() } }
        set { content = .worktree(newValue) }
    }
    var agent: AgentTopic {
        get { if case .agent(let value) = content { value } else { AgentTopic() } }
        set { content = .agent(newValue) }
    }

    var worktreeChoice: WorktreeChoice {
        get { content.kind == .agent ? agent.worktreeChoice : worktree.choice }
        set {
            guard newValue != worktreeChoice else { return }
            var updated = newValue
            updated.pendingPlan = nil
            if content.kind == .agent {
                agent.worktreeChoice = updated
            } else {
                worktree.choice = updated
            }
            error = nil
        }
    }

    func worktreeNames(for choice: WorktreeChoice) -> (name: String, branch: String) {
        GitWorkspace.names(
            for: choice, id: address.nodeID,
            title: GitWorkspace.nameSeed(for: MapNode(id: address.nodeID, content: content)))
    }

    func chooseFolder(forProject: Bool) {
        let panel = NSOpenPanel()
        panel.title = "Choose Project Folder"
        panel.prompt = "Choose"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if forProject, !project.directory.isEmpty { panel.directoryURL = URL(fileURLWithPath: project.directory) }
        panel.begin { [weak self] response in
            guard response == .OK, let path = panel.url?.path, let self else { return }
            if forProject {
                project.directory = path
                error = nil
            } else {
                Task { await attachProject(path) }
            }
        }
    }

    func save() async {
        guard !isBusy else { return }
        error = nil
        do {
            switch content {
            case .project(let project):
                try await workspace.saveProject(project, at: address)
            case .worktree(let worktree):
                try await workspace.saveWorktree(worktree, at: address)
            case .agent(let agent):
                try await workspace.launchAgent(agent, at: address)
                showTerminal()
            case .text, .branch:
                return
            }
            close()
        } catch {
            // The Git operation may have succeeded even if saving or starting the CLI failed.
            // Reload the binding and pending plan so a retry uses the same worktree.
            if let current = session.board.nodes[address.nodeID]?.content {
                switch (content, current) {
                case (.worktree(var draft), .worktree(let saved)):
                    draft.choice.base = saved.choice.base
                    draft.choice.pendingPlan = saved.choice.pendingPlan
                    if let location = saved.location { draft.location = location }
                    content = .worktree(draft)
                case (.agent(var draft), .agent(let saved)):
                    draft.worktreeChoice.base = saved.worktreeChoice.base
                    draft.worktreeChoice.pendingPlan = saved.worktreeChoice.pendingPlan
                    draft.isConfigured = saved.isConfigured
                    content = .agent(draft)
                default:
                    break
                }
            }
            self.error = error.localizedDescription
        }
    }

    private func attachProject(_ path: String) async {
        error = nil
        do { try await workspace.attachProject(at: path, above: address) } catch {
            self.error = error.localizedDescription
        }
    }

    func discard() {
        guard !isBusy, let node = session.board.nodes[address.nodeID], node.content.isDraft, node.children.isEmpty
        else {
            return
        }
        if session.apply(session.board.deleting([address.nodeID]), named: "Discard Draft") { close() }
    }
}

extension NodeKind {
    var symbol: String {
        switch self {
        case .text: "text.alignleft"
        case .project: "folder"
        case .worktree: "arrow.triangle.branch"
        case .agent: "terminal"
        }
    }
}

struct NodeForm: View {
    @Bindable var model: NodeFormModel
    @State private var preview: ProjectLocation?
    @State private var previewError: String?
    @State private var cliAvailability: [AgentCLIKind: Bool] = [:]
    @State private var formBodyHeight: CGFloat = 180

    var body: some View {
        VStack(alignment: .leading, spacing: CanvasStyle.formSpacing) {
            formHeader
            scrollableFields
            if let error = model.error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .lineLimit(3)
                    .help(error)
                    .textSelection(.enabled)
            }
            Divider()
            HStack(spacing: CanvasStyle.formSpacing) {
                if model.isBusy {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Preparing")
                } else if model.content.kind != .agent, model.isDraft,
                    model.session.board.nodes[model.address.nodeID]?.children.isEmpty == true
                {
                    if model.worktreeProject != nil {
                        Button("Discard Draft", role: .destructive) { model.discard() }
                            .buttonStyle(.borderless)
                    } else {
                        Button("Discard Draft", role: .destructive) { model.discard() }
                    }
                }
                Spacer(minLength: 0)
                Button(model.worktreeProject != nil && model.isDraft && !model.isBusy ? "Keep Draft" : "Close") {
                    model.close()
                }
                .keyboardShortcut(.cancelAction)
                if showsSave {
                    Button(actionTitle) { Task { await model.save() } }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(model.worktreeProject != nil ? .defaultAction : nil)
                        .disabled(model.isBusy || !canSave)
                }
            }
        }
        .padding(CanvasStyle.formPadding)
        .frame(width: CanvasStyle.formWidth)
        .fixedSize(horizontal: true, vertical: true)
        .task(id: model.agent.cli) {
            guard model.content.kind == .agent else { return }
            let cli = model.agent.cli
            let available = await AgentCLI.detected(cli) != nil
            if !Task.isCancelled { cliAvailability[cli] = available }
        }
        .task(id: model.project.directory) {
            preview = nil
            previewError = nil
            let directory = model.project.directory
            guard model.content.kind == .project, !directory.isEmpty else { return }
            do {
                let location = try await model.workspace.git.project(at: directory)
                if !Task.isCancelled { preview = location }
            } catch {
                if !Task.isCancelled { previewError = error.localizedDescription }
            }
        }
    }

    private var scrollableFields: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: CanvasStyle.formGroupSpacing) {
                switch model.content {
                case .project:
                    projectFields
                case .worktree:
                    if model.showsWorktreeDetails, let location = model.worktree.location {
                        LabeledContent("Branch", value: location.revisionLabel)
                        pathLabel(location.directory)
                    } else if let project = model.worktreeProject {
                        WorktreeFields(model: model, project: project)
                    } else {
                        contextFields
                    }
                case .agent:
                    agentFields
                case .text, .branch:
                    EmptyView()
                }
            }
            .padding(CanvasStyle.formFocusInset)
            .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { formBodyHeight = $0 }
            .disabled(model.isBusy)
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(height: min(formBodyHeight, CanvasStyle.formMaximumBodyHeight))
        // Widen the scroll clip for focus rings while keeping the fields aligned with the form.
        .padding(.horizontal, -CanvasStyle.formFocusInset)
    }

    private var formHeader: some View {
        VStack(alignment: .leading, spacing: CanvasStyle.formCompactSpacing) {
            Label(formTitle, systemImage: model.content.kind.symbol)
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            if let project = model.worktreeProject, let id = model.context.projectID {
                Text(model.session.board.nodes[id]?.title ?? URL(fileURLWithPath: project.directory).lastPathComponent)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    private var formTitle: String {
        if model.worktreeProject != nil && model.isDraft && model.worktree.choice.mode == .existing {
            return "Link Worktree"
        }
        if !showsSave { return "\(model.content.kind.title) Details" }
        return model.isDraft ? "New \(model.content.kind.title)" : "\(model.content.kind.title) Settings"
    }

    private var showsSave: Bool {
        switch model.content {
        case .worktree: !model.showsWorktreeDetails
        default: true
        }
    }

    private var actionTitle: String {
        switch model.content {
        case .project: "Save Project"
        case .worktree: "Link Worktree"
        case .agent: "Start"
        case .text, .branch: "Save"
        }
    }

    private var canSave: Bool {
        switch model.content {
        case .project: !model.project.directory.isEmpty && previewError == nil
        case .worktree:
            model.canSaveWorktree
        case .agent:
            model.context.problem == nil && model.context.project?.gitCommonDirectory != nil
                && (model.context.worktree != nil || model.selectionIsComplete(model.worktreeChoice))
                && cliAvailability[model.agent.cli] == true
        case .text, .branch: false
        }
    }

    private var projectFields: some View {
        VStack(alignment: .leading, spacing: CanvasStyle.formSpacing) {
            Button(model.project.directory.isEmpty ? "Choose Folder…" : "Change Folder…", systemImage: "folder") {
                model.chooseFolder(forProject: true)
            }
            if let preview {
                pathLabel(preview.directory)
                Text(preview.gitCommonDirectory == nil ? "Local folder" : "Git checkout")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if let previewError {
                Text(previewError).font(.callout)
            } else if !model.project.directory.isEmpty {
                pathLabel(model.project.directory)
            }
            TextField("Project Name (Optional)", text: $model.project.name)
            TextField("Description (Optional)", text: $model.project.details, axis: .vertical)
                .lineLimit(2...4)
        }
    }

    private var agentFields: some View {
        let scope = model.context
        return VStack(alignment: .leading, spacing: CanvasStyle.formSpacing) {
            TextField("Conversation Name (Optional)", text: $model.agent.name)
            TextField("Task (Optional)", text: $model.agent.task, axis: .vertical)
                .lineLimit(2...4)
            Picker("CLI", selection: $model.agent.cli) {
                ForEach(AgentCLIKind.allCases, id: \.self) { cli in Text(cli.title).tag(cli) }
            }
            .pickerStyle(.menu)
            .onChange(of: model.agent.cli) { model.error = nil }
            if cliAvailability[model.agent.cli] == false {
                Text(AgentCLI.unavailable(model.agent.cli))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if scope.problem == nil, let project = scope.project, project.gitCommonDirectory != nil {
                if let tree = scope.worktree {
                    LabeledContent("Worktree", value: tree.revisionLabel)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(tree.directory)
                } else {
                    WorktreeFields(model: model, project: project)
                }
            } else {
                contextFields
            }
            if scope.problem == nil, scope.project?.gitCommonDirectory != nil, scope.worktreeID == nil,
                model.worktreeChoice.mode != .existing
            {
                DisclosureGroup("Options") {
                    VStack(alignment: .leading, spacing: CanvasStyle.formSpacing) {
                        LabeledContent("Base") {
                            TextField("Base Branch or Commit", text: $model.worktreeChoice.base, prompt: Text("HEAD"))
                        }
                        LabeledContent("Branch") {
                            let choice = model.worktreeChoice
                            let branch = choice.pendingPlan?.branch ?? model.worktreeNames(for: choice).branch
                            TextField("New Branch Name", text: $model.worktreeChoice.branch, prompt: Text(branch))
                        }
                    }
                    .padding(.top, CanvasStyle.formSpacing)
                }
            }
        }
    }

    private var contextFields: some View {
        VStack(alignment: .leading, spacing: CanvasStyle.formSpacing) {
            let scope = model.context
            if let project = scope.project, let id = scope.projectID {
                if model.content.kind != .agent {
                    LabeledContent("Project", value: model.session.board.nodes[id]?.title ?? project.directory)
                }
                if project.gitCommonDirectory == nil {
                    Text("Bind a Git repository to this project.").font(.callout)
                    Button("Configure Project") { model.showNode(id) }
                }
            }
            if let problem = scope.problem {
                Text(problem.message).font(.callout)
                if problem == .missingProject {
                    Button("Choose Git Project…", systemImage: "folder") { model.chooseFolder(forProject: false) }
                } else if let id = ancestorToConfigure(for: problem, in: scope) {
                    Button("Configure Ancestor") { model.showNode(id) }
                }
            }
        }
    }

    private func ancestorToConfigure(for problem: NodeContext.Problem, in scope: NodeContext) -> UUID? {
        switch problem {
        case .unfinishedProject: scope.projectID
        case .unfinishedWorktree: scope.worktreeID
        default: nil
        }
    }
}

func pathLabel(_ path: String) -> some View {
    Text((path as NSString).abbreviatingWithTildeInPath)
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(2)
        .truncationMode(.middle)
        .textSelection(.enabled)
        .help(path)
}
