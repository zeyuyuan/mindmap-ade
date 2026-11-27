import AppKit
import Foundation
import MindMapCore

extension WorkspaceStore {
    func runtimeDetails(in boardID: UUID) -> [UUID: String] {
        var details: [UUID: String] = [:]
        for (address, run) in agentRuns where address.boardID == boardID {
            details[address.nodeID] = "Agent · \(run.state.title)"
        }
        for address in operations where address.boardID == boardID {
            details[address.nodeID] = "Preparing…"
        }
        if let session = board(boardID) {
            for id in session.gitChangesNodeIDs where details[id] == nil {
                guard case .gitChanges(let topic) = session.board.nodes[id]?.content else { continue }
                if let target = gitChangesTarget(for: id, in: session.board) {
                    if let summary = gitChangesSummaries[target] {
                        details[id] = topic.directory == nil ? summary.cardDetail : summary.externalCardDetail
                    }
                } else {
                    details[id] = "No worktree"
                }
            }
        }
        return details
    }

    func activeRunCount(in boardID: UUID) -> Int {
        agentRuns.values.reduce(0) { count, run in
            count + (run.address.boardID == boardID && run.state.isActive ? 1 : 0)
        }
    }

    func agentRunStates(in boardID: UUID) -> [UUID: AgentRun.State] {
        Dictionary(
            uniqueKeysWithValues: agentRuns.values.lazy.filter { $0.address.boardID == boardID }
                .map { ($0.address.nodeID, $0.state) })
    }

    func hasActiveWork(in boardID: UUID? = nil) -> Bool {
        operations.contains { boardID == nil || $0.boardID == boardID }
            || agentRuns.values.contains { $0.state.isActive && (boardID == nil || $0.address.boardID == boardID) }
            || terminals.contains { $0.value.isShell && (boardID == nil || $0.key.boardID == boardID) }
    }

    func rejection(of edit: BoardEdit, on board: MindMapBoard) -> String? {
        let active = agentRuns.values.filter {
            $0.address.boardID == board.id && ($0.state.isActive || terminals[$0.address]?.isShell == true)
        }
        guard !active.isEmpty else { return nil }
        var candidate = board
        candidate.apply(edit)
        for run in active {
            let context = candidate.context(above: run.address.nodeID)
            guard case .agent(let agent) = candidate.nodes[run.address.nodeID]?.content,
                agent.isConfigured, !run.state.isActive || agent.cli == run.cli, context.problem == nil,
                context.worktree?.directory == run.directory,
                context.worktree?.gitCommonDirectory == run.gitCommonDirectory
            else {
                return run.state.isActive
                    ? "Stop the running conversation before removing it or changing its worktree."
                    : "Exit the shell before removing its Agent or changing its worktree."
            }
        }
        return nil
    }

    func updateDraft(at address: NodeAddress, content: NodeContent) {
        guard !operations.contains(address), let session = board(address.boardID),
            session.board.nodes[address.nodeID]?.content.isDraft == true
        else { return }
        session.apply(
            session.board.replacingContent(address.nodeID, with: content), named: "Edit Draft", recordHistory: false)
    }

    func saveProject(_ draft: ProjectTopic, at address: NodeAddress) async throws {
        let session = try beginOperation(address)
        defer { operations.remove(address) }
        let original = try node(at: address, in: session)
        let location = try await git.project(at: draft.directory)
        try checkUnchanged(original, address: address, session: session)
        if let problem = session.board.projectBindingProblem(for: address.nodeID, to: location) {
            if problem == .worktreeSourceChange {
                throw WorkspaceIssue(
                    "This project has worktrees based on its checkout. Add another Project to use a different directory."
                )
            }
            throw WorkspaceIssue(
                "Remove this project's worktree references before binding a different repository.")
        }
        var project = draft
        project.directory = location.directory
        project.location = location
        if let edit = session.board.replacingContent(address.nodeID, with: .project(project)) {
            try apply(edit, in: session, action: "Bind Project")
        }
    }

    func attachProject(at path: String, above address: NodeAddress) async throws {
        let session = try beginOperation(address)
        defer { operations.remove(address) }
        let original = try node(at: address, in: session)
        let parent = session.board.parents[address.nodeID]
        guard session.board.context(above: address.nodeID).problem == .missingProject else {
            throw WorkspaceIssue("Configure the existing project above this node.")
        }
        let location = try await git.project(at: path)
        guard location.gitCommonDirectory != nil else {
            throw WorkspaceIssue("Choose a folder inside a Git repository.")
        }
        try checkUnchanged(original, address: address, session: session)
        guard session.board.parents[address.nodeID] == parent,
            session.board.context(above: address.nodeID).problem == .missingProject
        else { throw WorkspaceIssue("This node moved. Review its project and try again.") }
        var project = ProjectTopic()
        project.directory = location.directory
        project.location = location
        let parentNode = MapNode(content: .project(project))
        guard let edit = session.board.insertingParent(parentNode, above: address.nodeID) else {
            throw WorkspaceIssue("The project could not be added above this node.")
        }
        try apply(edit, in: session, action: "Add Project")
    }

    func saveWorktree(_ draft: WorktreeTopic, at address: NodeAddress) async throws {
        let session = try beginOperation(address)
        defer { operations.remove(address) }
        let original = try node(at: address, in: session)
        let context = session.board.context(above: address.nodeID)
        let project = try validProject(in: context)
        if case .worktree(let current) = original.content, current.location != nil,
            context.worktreeID != nil || hasDerivedWorktrees(address.nodeID, in: session.board)
        {
            throw WorkspaceIssue("This worktree is part of a branch route. Create a new node for a different checkout.")
        }
        var worktree = draft
        let prepared: (location: WorktreeLocation, creationCommit: String?)
        if draft.choice.mode == .existing {
            prepared = try await prepareWorktree(
                draft.choice, for: original, at: address, in: session, context: context, project: project)
        } else {
            prepared = try await prepareDerivedWorktree(
                draft.choice, for: original, at: address, in: session, context: context, project: project)
        }
        if prepared.location.directory == project.directory, draft.location?.directory != project.directory {
            throw WorkspaceIssue("This checkout is already shown on the Project node.")
        }
        worktree.location = prepared.location
        worktree.creationCommit = prepared.creationCommit
        worktree.choice = WorktreeChoice(mode: .existing)
        worktree.choice.existingDirectory = worktree.location?.directory ?? ""
        try replace(.worktree(worktree), at: address, in: session, action: "Bind Worktree")
        try await flush()
    }

    func launchAgent(
        _ draft: AgentTopic, at address: NodeAddress,
        detectCLI: @MainActor (AgentCLIKind) async -> AgentCLI.Executable? = { await AgentCLI.detected($0) }
    ) async throws {
        let session = try beginOperation(address)
        defer { operations.remove(address) }
        let original = try node(at: address, in: session)
        let context = session.board.context(above: address.nodeID)
        let project = try validProject(in: context)
        if context.worktree == nil,
            !session.board.canInsertResourceParent(.draft(.worktree), above: address.nodeID)
        {
            throw WorkspaceIssue(
                "Move the existing resource nodes to a separate branch before creating a worktree here.")
        }
        guard let executable = await detectCLI(draft.cli), AgentCLI.isExecutableFile(executable.path) else {
            throw WorkspaceIssue(AgentCLI.unavailable(draft.cli))
        }
        try checkUnchanged(original, address: address, session: session, context: context)
        var agent = draft
        let prepared: (location: WorktreeLocation, creationCommit: String?)
        if let inherited = context.worktree {
            if case .agent(let current) = original.content { agent.worktreeChoice = current.worktreeChoice }
            prepared = (try await git.existing(inherited.directory, in: project), nil)
            try checkUnchanged(original, address: address, session: session, context: context)
        } else {
            prepared = try await prepareWorktree(
                agent.worktreeChoice, for: try node(at: address, in: session), at: address, in: session,
                context: context,
                project: project)
        }

        agent.worktreeChoice.pendingPlan = nil
        agent.isConfigured = true
        let location = prepared.location
        try bindAgent(agent, to: location, creationCommit: prepared.creationCommit, address: address, session: session)
        let checkout = try await git.agentCheckout(location.directory, in: project)
        try await startAgentProcess(
            agent, at: address, in: session, checkout: checkout, project: project, executable: executable)
    }

    func resumeAgent(
        at address: NodeAddress, owner: UUID? = nil, confirmedCheckout: String? = nil,
        detectCLI: @MainActor (AgentCLIKind) async -> AgentCLI.Executable? = { await AgentCLI.detected($0) }
    ) async throws {
        let session = try beginOperation(address)
        defer { operations.remove(address) }
        let original = try node(at: address, in: session)
        guard let previous = savedConversation(at: address), case .agent(let agent) = original.content
        else { throw WorkspaceIssue("This Agent has no saved conversation to continue.") }
        let context = session.board.context(above: address.nodeID)
        let project = try validProject(in: context)
        guard let inherited = context.worktree, inherited.directory == previous.directory,
            inherited.gitCommonDirectory == previous.gitCommonDirectory
        else { throw WorkspaceIssue("The original worktree is no longer linked to this Agent.") }

        let checkout = try await git.agentCheckout(inherited.directory, in: project)
        try validateAgentCheckout(checkout, for: previous, confirmedCheckout: confirmedCheckout)
        guard let executable = await detectCLI(agent.cli), AgentCLI.isExecutableFile(executable.path) else {
            throw WorkspaceIssue(AgentCLI.unavailable(agent.cli))
        }
        try checkUnchanged(original, address: address, session: session, context: context)
        try await startAgentProcess(
            agent, at: address, in: session, checkout: checkout, project: project, executable: executable,
            previous: previous, owner: owner)
    }

    func openAgentShell(at address: NodeAddress, owner: UUID) async throws {
        let session = try beginOperation(address)
        defer { operations.remove(address) }
        let original = try node(at: address, in: session)
        guard original.content.kind == .agent, let run = agentRuns[address], terminals[address] == nil else { return }
        try await startAgentShell(for: run, owner: owner)
    }

    /// Toggles whether `worktreeID` shows Git Changes child nodes.
    /// Turning it off preserves tracked external repositories on the Worktree while removing childless cards.
    @discardableResult
    func setWorktreeShowsGitChanges(_ shows: Bool, for worktreeID: UUID, in session: BoardSession) -> Bool {
        guard !isReadOnly, !isQuitting, board(session.id) === session,
            var worktreeNode = session.board.nodes[worktreeID],
            case .worktree(var topic) = worktreeNode.content,
            topic.location != nil,
            topic.showsGitChanges != shows
        else { return false }

        if !shows {
            for childID in worktreeNode.children {
                if case .gitChanges(let gitTopic) = session.board.nodes[childID]?.content {
                    topic.rememberExternalGitChanges(gitTopic)
                }
            }
        }
        topic.showsGitChanges = shows
        worktreeNode.content = .worktree(topic)

        var replacements: [NodeReplacement] = []
        if !shows {
            let removable = Set(
                worktreeNode.children.filter { childID in
                    guard let child = session.board.nodes[childID] else { return false }
                    return child.content.kind == .gitChanges && child.children.isEmpty
                })
            if !removable.isEmpty {
                worktreeNode.children.removeAll { removable.contains($0) }
                if worktreeNode.children.isEmpty { worktreeNode.isCollapsed = false }
                for id in removable {
                    replacements.append(NodeReplacement(id: id, node: nil))
                }
            }
        }
        replacements.append(NodeReplacement(id: worktreeID, node: worktreeNode))
        return session.apply(
            BoardEdit(nodes: replacements),
            named: shows ? "Show Git Changes" : "Hide Git Changes")
    }

    /// Resolves a Git repository or worktree at `path` and attaches (or reuses) a Git Changes card under `worktreeID`.
    /// Rejects directories with no Git changes so clean repositories do not add empty cards.
    func attachGitChanges(
        directory path: String, under worktreeID: UUID, in session: BoardSession
    ) async throws -> (id: UUID, created: Bool, directory: String) {
        guard !isReadOnly, !isQuitting, board(session.id) === session,
            let initialNode = session.board.nodes[worktreeID],
            case .worktree(let initialTopic) = initialNode.content,
            let ownLocation = initialTopic.location
        else { throw WorkspaceIssue("This Worktree is no longer available for editing.") }
        let location = try await git.project(at: path)
        guard let common = location.gitCommonDirectory else {
            throw WorkspaceIssue("Choose a folder inside a Git repository.")
        }
        let isOwnWorktree = ownLocation.directory == location.directory
        let existingChild = initialNode.children.first(where: { childID in
            guard case .gitChanges(let topic) = session.board.nodes[childID]?.content else { return false }
            return (topic.directory ?? ownLocation.directory) == location.directory
        })
        let existingBase: String? =
            if let existingChild, case .gitChanges(let topic) = session.board.nodes[existingChild]?.content {
                topic.baseCommit
            } else {
                initialTopic.trackedExternalGitChanges.first(where: { $0.directory == location.directory })?.baseCommit
            }
        let baseCommit =
            existingBase ?? (isOwnWorktree ? defaultGitChangesBaseCommit(for: worktreeID, in: session) : nil)
        let snapshot = try await git.changesSnapshot(in: location.directory, baseCommit: baseCommit)
        guard board(session.id) === session, var worktreeNode = session.board.nodes[worktreeID],
            case .worktree(var worktreeTopic) = worktreeNode.content,
            worktreeTopic.location?.directory == ownLocation.directory
        else { throw WorkspaceIssue("This Worktree is no longer available.") }
        let headCommit = isOwnWorktree ? baseCommit : (baseCommit ?? snapshot.headCommit)
        let target = GitChangesTarget(directory: location.directory, baseCommit: headCommit)
        recordGitChangesSnapshot(snapshot, for: target)
        guard snapshot.hasChanges else {
            let name = URL(fileURLWithPath: location.directory).lastPathComponent
            throw WorkspaceIssue("No Git changes in \(name.isEmpty ? location.directory : name).")
        }

        let topic = GitChangesTopic(
            directory: isOwnWorktree ? nil : location.directory,
            gitCommonDirectory: isOwnWorktree ? nil : common,
            baseCommit: headCommit)
        if let existing = worktreeNode.children.first(where: { childID in
            guard case .gitChanges(let existingTopic) = session.board.nodes[childID]?.content else { return false }
            return (existingTopic.directory ?? ownLocation.directory) == location.directory
        }) {
            let beforeTopic = worktreeTopic
            if !worktreeTopic.showsGitChanges { worktreeTopic.showsGitChanges = true }
            if !isOwnWorktree { worktreeTopic.rememberExternalGitChanges(topic) }
            if worktreeTopic != beforeTopic {
                worktreeNode.content = .worktree(worktreeTopic)
                try apply(
                    BoardEdit(nodes: [NodeReplacement(id: worktreeID, node: worktreeNode)]), in: session,
                    action: "Show Git Changes")
            }
            return (id: existing, created: false, directory: location.directory)
        }
        let index = gitChangesInsertIndex(under: worktreeID, isOwnWorktree: isOwnWorktree, in: session.board)
        guard
            var insertion = session.board.inserting(
                MapNode(content: .gitChanges(topic)), parent: worktreeID, at: index)
        else {
            throw WorkspaceIssue("Git Changes could not be added under this Worktree.")
        }
        if !worktreeTopic.showsGitChanges || !isOwnWorktree {
            insertion.edit.nodes = insertion.edit.nodes.map { replacement in
                guard replacement.id == worktreeID, var updated = replacement.node,
                    case .worktree(var updatedTree) = updated.content
                else { return replacement }
                updatedTree.showsGitChanges = true
                if !isOwnWorktree { updatedTree.rememberExternalGitChanges(topic) }
                updated.content = .worktree(updatedTree)
                return NodeReplacement(id: worktreeID, node: updated)
            }
        }
        try apply(insertion.edit, in: session, action: "Add Git Changes")
        return (id: insertion.id, created: true, directory: location.directory)
    }

    /// Synchronizes Git Changes cards on `session` with real Git state:
    /// shows each enabled Worktree's own and tracked external cards only when changes exist,
    /// and removes clean or disabled leaf cards automatically while preserving tracked external metadata.
    func syncGitChanges(in session: BoardSession) async {
        guard board(session.id) === session else { return }
        var targets = Set<GitChangesTarget>()
        for nodeID in session.gitChangesNodeIDs {
            if let target = gitChangesTarget(for: nodeID, in: session.board) {
                targets.insert(target)
            }
        }
        for (worktreeID, state) in session.worktreeGitStates where state.showsGitChanges {
            guard case .worktree(let tree) = session.board.nodes[worktreeID]?.content,
                let location = tree.location,
                session.board.context(above: worktreeID).problem == nil
            else { continue }
            if !hasDefaultGitChanges(under: worktreeID, in: session.board) {
                let baseCommit = defaultGitChangesBaseCommit(for: worktreeID, in: session)
                targets.insert(GitChangesTarget(directory: location.directory, baseCommit: baseCommit))
            }
            for external in tree.trackedExternalGitChanges {
                guard let directory = external.directory, !directory.isEmpty,
                    !hasGitChanges(for: directory, under: worktreeID, in: session.board)
                else { continue }
                let base = external.baseCommit.flatMap { $0.isEmpty ? nil : $0 }
                targets.insert(GitChangesTarget(directory: directory, baseCommit: base))
            }
        }
        guard !targets.isEmpty else { return }

        var snapshots: [GitChangesTarget: GitChangesSnapshot] = [:]
        for target in targets {
            guard !Task.isCancelled else { return }
            if let snapshot = try? await git.changesSnapshot(in: target.directory, baseCommit: target.baseCommit) {
                snapshots[target] = snapshot
            }
        }
        guard !Task.isCancelled, board(session.id) === session else { return }
        for (target, snapshot) in snapshots {
            recordGitChangesSnapshot(snapshot, for: target)
        }
        guard !isReadOnly, !isQuitting else { return }

        // Remove clean or disabled Git Changes nodes that have no child notes,
        // harvesting any external GitChangesTopic onto the parent Worktree first.
        var toRemove = Set<UUID>()
        var rememberedExternals: [UUID: [GitChangesTopic]] = [:]
        for nodeID in session.gitChangesNodeIDs {
            guard let node = session.board.nodes[nodeID], node.children.isEmpty else { continue }
            let isDisabled: Bool =
                if let parentID = session.board.parents[nodeID],
                    case .worktree(let tree) = session.board.nodes[parentID]?.content
                {
                    !tree.showsGitChanges
                } else {
                    false
                }
            let isClean: Bool =
                if let target = gitChangesTarget(for: nodeID, in: session.board),
                    let snapshot = snapshots[target]
                {
                    !snapshot.hasChanges
                } else {
                    false
                }
            guard isDisabled || isClean else { continue }
            if case .gitChanges(let gitTopic) = node.content, gitTopic.directory != nil,
                let parentID = session.board.parents[nodeID]
            {
                rememberedExternals[parentID, default: []].append(gitTopic)
            }
            toRemove.insert(nodeID)
        }
        if !toRemove.isEmpty, var edit = session.board.deleting(toRemove) {
            if !rememberedExternals.isEmpty {
                edit.nodes = edit.nodes.map { replacement in
                    guard let externals = rememberedExternals[replacement.id],
                        var updated = replacement.node,
                        case .worktree(var updatedTree) = updated.content
                    else { return replacement }
                    for topic in externals { updatedTree.rememberExternalGitChanges(topic) }
                    updated.content = .worktree(updatedTree)
                    return NodeReplacement(id: replacement.id, node: updated)
                }
            }
            _ = session.apply(edit, named: "Sync Git Changes", recordHistory: false)
        }

        // Attach default and tracked external Git Changes cards at the front of each enabled Worktree with changes.
        for (worktreeID, state) in session.worktreeGitStates where state.showsGitChanges {
            guard case .worktree(let tree) = session.board.nodes[worktreeID]?.content,
                tree.showsGitChanges, let location = tree.location,
                session.board.context(above: worktreeID).problem == nil
            else { continue }
            if !hasDefaultGitChanges(under: worktreeID, in: session.board) {
                let baseCommit = defaultGitChangesBaseCommit(for: worktreeID, in: session)
                let target = GitChangesTarget(directory: location.directory, baseCommit: baseCommit)
                if snapshots[target]?.hasChanges == true {
                    let node = MapNode(content: .gitChanges(GitChangesTopic(baseCommit: baseCommit)))
                    if let insertion = session.board.inserting(node, parent: worktreeID, at: 0) {
                        _ = session.apply(insertion.edit, named: "Sync Git Changes", recordHistory: false)
                    }
                }
            }
            for external in tree.trackedExternalGitChanges {
                guard let directory = external.directory, !directory.isEmpty,
                    !hasGitChanges(for: directory, under: worktreeID, in: session.board)
                else { continue }
                let base = external.baseCommit.flatMap { $0.isEmpty ? nil : $0 }
                let target = GitChangesTarget(directory: directory, baseCommit: base)
                guard snapshots[target]?.hasChanges == true else { continue }
                let index = gitChangesInsertIndex(under: worktreeID, isOwnWorktree: false, in: session.board)
                let node = MapNode(content: .gitChanges(external))
                if let insertion = session.board.inserting(node, parent: worktreeID, at: index) {
                    _ = session.apply(insertion.edit, named: "Sync Git Changes", recordHistory: false)
                }
            }
        }
    }

    func reconcileGitChangesNode(at address: NodeAddress, snapshot: GitChangesSnapshot) {
        guard !isReadOnly, !isQuitting, !snapshot.hasChanges,
            let session = board(address.boardID),
            let node = session.board.nodes[address.nodeID],
            case .gitChanges(let gitTopic) = node.content, node.children.isEmpty,
            var edit = session.board.deleting([address.nodeID])
        else { return }
        if gitTopic.directory != nil, let parentID = session.board.parents[address.nodeID] {
            edit.nodes = edit.nodes.map { replacement in
                guard replacement.id == parentID, var updated = replacement.node,
                    case .worktree(var updatedTree) = updated.content
                else { return replacement }
                updatedTree.rememberExternalGitChanges(gitTopic)
                updated.content = .worktree(updatedTree)
                return NodeReplacement(id: parentID, node: updated)
            }
        }
        _ = session.apply(edit, named: "Sync Git Changes", recordHistory: false)
    }

    private func beginOperation(_ address: NodeAddress) throws -> BoardSession {
        guard !isReadOnly, !isQuitting, let session = board(address.boardID),
            session.board.nodes[address.nodeID] != nil
        else {
            throw WorkspaceIssue("This node is no longer available for editing.")
        }
        guard agentRuns[address]?.state.isActive != true, operations.insert(address).inserted else {
            throw WorkspaceIssue("This node already has an operation in progress.")
        }
        return session
    }

    private func node(at address: NodeAddress, in session: BoardSession) throws -> MapNode {
        guard let node = session.board.nodes[address.nodeID] else { throw WorkspaceIssue("The node was removed.") }
        return node
    }

    private func checkUnchanged(
        _ original: MapNode, address: NodeAddress, session: BoardSession, context: NodeContext? = nil
    ) throws {
        guard board(address.boardID) === session, session.board.nodes[address.nodeID]?.content == original.content,
            context == nil || session.board.context(above: address.nodeID) == context
        else {
            throw WorkspaceIssue("This node or its project changed. Review the current configuration and try again.")
        }
    }

    private func validProject(in context: NodeContext) throws -> ProjectLocation {
        if let problem = context.problem { throw WorkspaceIssue(problem.message) }
        guard let project = context.project, project.gitCommonDirectory != nil else {
            throw WorkspaceIssue("Choose a Git project before using worktrees.")
        }
        return project
    }

    func hasDerivedWorktrees(_ id: UUID, in board: MindMapBoard) -> Bool {
        board.nodes[id]?.children.contains { board.nodes[$0]?.content.kind == .worktree } == true
    }

    private func prepareDerivedWorktree(
        _ draft: WorktreeChoice, for original: MapNode, at address: NodeAddress, in session: BoardSession,
        context: NodeContext, project: ProjectLocation
    ) async throws -> (location: WorktreeLocation, creationCommit: String?) {
        guard original.content.isDraft else {
            throw WorkspaceIssue("Add a child Worktree to create another checkout.")
        }
        if let plan = draft.pendingPlan {
            let recovered = try await git.preparedCheckout(plan, in: project)
            try checkUnchanged(original, address: address, session: session, context: context)
            if let recovered { return (recovered, plan.commit) }
        }
        var choice = WorktreeChoice()
        choice.branch = draft.branch
        if let source = context.worktreeID, session.board.parents[original.id] != source {
            throw WorkspaceIssue("Add this worktree directly under its source Worktree.")
        }
        return try await prepareWorktree(
            choice, for: original, at: address, in: session, context: context, project: project)
    }

    private func prepareWorktree(
        _ choice: WorktreeChoice, for original: MapNode, at address: NodeAddress, in session: BoardSession,
        context: NodeContext, project: ProjectLocation
    ) async throws -> (location: WorktreeLocation, creationCommit: String?) {
        if choice.mode == .existing {
            guard context.worktreeID == nil else {
                throw WorkspaceIssue("Link existing worktrees from the project. This route creates a new worktree.")
            }
            let location = try await git.existing(choice.existingDirectory, in: project)
            try checkUnchanged(original, address: address, session: session, context: context)
            return (location, nil)
        }
        let plan: WorktreePlan
        if let pending = choice.pendingPlan {
            plan = pending
        } else {
            plan = try await git.plan(
                choice, id: original.id, title: GitWorkspace.nameSeed(for: original), project: project,
                dataDirectory: dataDirectory,
                source: context.worktree)
        }
        try checkUnchanged(original, address: address, session: session, context: context)
        let planned: NodeContent
        switch original.content {
        case .worktree(var value):
            value.choice = choice
            value.choice.pendingPlan = plan
            planned = .worktree(value)
        case .agent(var value):
            value.worktreeChoice = choice
            value.worktreeChoice.pendingPlan = plan
            planned = .agent(value)
        default: throw WorkspaceIssue("This node cannot prepare a worktree.")
        }
        if original.content != planned {
            try replace(planned, at: address, in: session, action: "Prepare Worktree", recordHistory: false)
        }
        let staged = try node(at: address, in: session)
        try await flush()
        try checkUnchanged(staged, address: address, session: session, context: context)
        let result = try await git.create(plan, in: project, resuming: choice.pendingPlan != nil)
        try checkUnchanged(staged, address: address, session: session, context: context)
        return (result, plan.commit)
    }

    private func bindAgent(
        _ agent: AgentTopic, to location: WorktreeLocation, creationCommit: String?,
        address: NodeAddress, session: BoardSession
    ) throws {
        let original = session.board
        var candidate = original
        var touched: [UUID] = []
        var seen = Set<UUID>()
        func record(_ edit: BoardEdit) {
            for replacement in edit.nodes where seen.insert(replacement.id).inserted {
                touched.append(replacement.id)
            }
        }
        if let contentEdit = candidate.replacingContent(address.nodeID, with: .agent(agent)) {
            candidate.apply(contentEdit)
            record(contentEdit)
        }
        let scope = candidate.context(above: address.nodeID)
        if scope.worktree == nil {
            let siblings =
                candidate.parents[address.nodeID].flatMap { candidate.nodes[$0]?.children }
                ?? candidate.roots.map(\.id)
            let reusable = siblings.first { id in
                guard case .worktree(let worktree) = candidate.nodes[id]?.content else { return false }
                return worktree.location?.directory == location.directory
                    && worktree.location?.gitCommonDirectory == location.gitCommonDirectory
            }
            let parentEdit =
                reusable.flatMap { candidate.moving(address.nodeID, to: $0) }
                ?? candidate.insertingParent(
                    MapNode(content: .worktree(WorktreeTopic(location: location, creationCommit: creationCommit))),
                    above: address.nodeID)
            guard let parentEdit else { throw WorkspaceIssue("The worktree could not be attached to this node.") }
            candidate.apply(parentEdit)
            record(parentEdit)
        }
        let replacements = touched.compactMap { id -> NodeReplacement? in
            original.nodes[id] == candidate.nodes[id] ? nil : NodeReplacement(id: id, node: candidate.nodes[id])
        }
        let roots = candidate.roots == original.roots ? nil : candidate.roots
        if !replacements.isEmpty || roots != nil {
            try apply(BoardEdit(nodes: replacements, roots: roots), in: session, action: "Configure Conversation")
        }
    }

    private func replace(
        _ content: NodeContent, at address: NodeAddress, in session: BoardSession, action: String,
        recordHistory: Bool = true
    ) throws {
        if session.board.nodes[address.nodeID]?.content == content { return }
        try apply(
            session.board.replacingContent(address.nodeID, with: content), in: session, action: action,
            recordHistory: recordHistory)
    }

    private func apply(
        _ edit: BoardEdit?, in session: BoardSession, action: String, recordHistory: Bool = true
    ) throws {
        guard session.apply(edit, named: action, recordHistory: recordHistory) else {
            throw WorkspaceIssue(session.editError ?? "The node could not be updated.")
        }
    }
}
