import Foundation
import MindMapCore

enum AgentRecoveryIssue: LocalizedError, Equatable {
    case checkoutChanged(previous: String, current: String)
    case unavailable(String)

    var checkoutToConfirm: String? {
        if case .checkoutChanged(_, let current) = self { return current }
        return nil
    }

    var errorDescription: String? {
        switch self {
        case .checkoutChanged(let previous, let current):
            "The worktree switched from \(AgentRun.checkoutLabel(previous)) to \(AgentRun.checkoutLabel(current))."
        case .unavailable(let message):
            message
        }
    }
}

extension WorkspaceStore {
    func canOpenAgent(at address: NodeAddress) -> Bool {
        board(address.boardID)?.board.nodes[address.nodeID]?.content.kind == .agent
            && (agentRuns[address] != nil || terminals[address] != nil)
    }

    func savedConversation(at address: NodeAddress) -> AgentRun? {
        guard let run = agentRuns[address], run.conversationID != nil,
            case .agent(let agent) = board(address.boardID)?.board.nodes[address.nodeID]?.content,
            agent.isConfigured, agent.cli == run.cli
        else { return nil }
        return run
    }

    func requestAgentResume(at address: NodeAddress, owner: UUID, automatically: Bool = false) {
        guard !isReadOnly, !isQuitting, !operations.contains(address),
            let run = savedConversation(at: address), !run.state.isActive
        else { return }
        let issue = recoveryIssues[address]
        guard !automatically || (run.state == .interrupted && issue == nil) else { return }
        Task {
            guard !operations.contains(address), agentRuns[address]?.id == run.id else { return }
            do {
                try await resumeAgent(at: address, owner: owner, confirmedCheckout: issue?.checkoutToConfirm)
            } catch {
                if !isQuitting {
                    recoveryIssues[address] = (error as? AgentRecoveryIssue) ?? .unavailable(error.localizedDescription)
                }
            }
        }
    }

    func validateAgentCheckout(
        _ checkout: GitWorkspace.AgentCheckout, for run: AgentRun, confirmedCheckout: String?
    ) throws {
        let worktree = checkout.location
        guard worktree.directory == run.directory, worktree.gitCommonDirectory == run.gitCommonDirectory else {
            throw WorkspaceIssue("The original worktree is unavailable or has changed.")
        }
        if let identity = run.worktreeIdentity, identity != checkout.identity {
            throw WorkspaceIssue("The original worktree was replaced. Start a new conversation for this checkout.")
        }
        let current = AgentRun.checkoutReference(worktree)
        if let previous = run.checkout, previous != current, confirmedCheckout != current {
            throw AgentRecoveryIssue.checkoutChanged(previous: previous, current: current)
        }
    }

    func startAgentProcess(
        _ agent: AgentTopic, at address: NodeAddress, in session: BoardSession, checkout: GitWorkspace.AgentCheckout,
        project: ProjectLocation, executable: AgentCLI.Executable, previous: AgentRun? = nil, owner: UUID? = nil
    ) async throws {
        let worktree = checkout.location
        var environment = AgentCLI.environment(executable: executable.path)
        var conversationID = previous?.conversationID
        if agent.cli == .codex, executable.supportsSessionIntegration {
            if let conversationID {
                try await CodexConversation.verify(
                    conversationID, executable: executable.path, environment: environment, directory: worktree.directory
                )
            } else {
                let name = session.board.nodes[address.nodeID]?.title ?? "Mindmap Agent"
                conversationID = try? await CodexConversation.create(
                    executable: executable.path, environment: environment, directory: worktree.directory, name: name)
            }
        }
        var run = AgentRun(
            address: address, worktree: worktree, cli: agent.cli, executable: executable.path,
            conversationID: conversationID, worktreeIdentity: checkout.identity)
        let lastRun = agentRuns[address]
        if let lastRun {
            run.previousSnapshotID = lastRun.previousSnapshotID
            if lastRun.state != .failed || lastRun.previousSnapshotID == nil,
                await agentFiles.snapshot(for: lastRun.id) != nil
            {
                run.previousSnapshotID = lastRun.id
            }
        }
        let context = session.board.context(above: address.nodeID)
        guard board(address.boardID) === session, session.board.nodes[address.nodeID]?.content == .agent(agent),
            context.project == project, context.worktree?.directory == run.directory,
            context.worktree?.gitCommonDirectory == run.gitCommonDirectory
        else { throw WorkspaceIssue("The Agent or its worktree changed during startup.") }
        recoveryIssues.removeValue(forKey: address)
        agentRuns[address] = run
        do {
            try await flush()
            let connection = try await prepareMCP(for: run, environment: environment)
            environment.merge(connection.environment) { _, new in new }
            var commandCodeMod: String?
            if agent.cli == .commandCode, executable.supportsSessionIntegration {
                let integration = try await agentFiles.commandCodeIntegration(for: run.id)
                commandCodeMod = integration.mod
                environment["MINDMAP_AGENT_SESSION_FILE"] = integration.marker
            }
            let current = try await git.agentCheckout(worktree.directory, in: project)
            try validateAgentCheckout(current, for: run, confirmedCheckout: nil)
            let arguments = try AgentCLI.arguments(
                for: agent, executable: executable, context: promptContext(for: run, in: session),
                mcpBridge: connection.bridge, conversationID: conversationID, isResuming: previous != nil,
                commandCodeMod: commandCodeMod)
            let terminal = AgentTerminal()
            terminal.owner = owner
            let runID = run.id
            terminal.didExit = { [weak self] status, error in
                Task { await self?.finishAgent(at: address, runID: runID, exitCode: status, error: error) }
            }
            try terminal.start(
                executable: executable.path, arguments: arguments, environment: environment, directory: run.directory)
            terminals[address] = terminal
            agentRuns[address]?.state = .running
            recordOutput(of: terminal, for: run)
            scheduleSave()
        } catch {
            if let lastRun {
                agentRuns[address] = lastRun
                releaseMCP(for: run)
                scheduleSave()
            } else {
                await finishAgent(at: address, runID: run.id, exitCode: nil, error: error.localizedDescription)
            }
            throw error
        }
    }

    func stopAgent(at address: NodeAddress) {
        guard let run = agentRuns[address], run.state == .running else { return }
        agentRuns[address]?.state = .stopping
        Task {
            // Persist the user's stop before signaling the process so a relaunch won't resume it.
            try? await flush()
            guard agentRuns[address]?.id == run.id, agentRuns[address]?.state == .stopping else { return }
            terminals[address]?.stop()
        }
    }

    func interruptAllAgents() async throws {
        for (address, run) in agentRuns where run.state == .running {
            agentRuns[address]?.state = .interrupting
            terminals[address]?.stop()
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(4))
        while agentRuns.values.contains(where: { $0.state.isActive }) {
            guard ContinuousClock.now < deadline else {
                throw WorkspaceIssue("An Agent is still stopping. Try quitting again after it exits.")
            }
            try await Task.sleep(for: .milliseconds(40))
        }
        await commandCodeConnection.removeAll()
    }

    private func recordOutput(of terminal: AgentTerminal, for run: AgentRun) {
        terminal.recording = Task { [weak self, weak terminal] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let self, let terminal else { return }
                await self.saveOutput(of: terminal, for: run)
            }
        }
    }

    private func saveOutput(of terminal: AgentTerminal, for run: AgentRun) async {
        guard agentRuns[run.address]?.id == run.id else { return }
        if let snapshot = terminal.snapshotToSave() {
            do {
                try await agentFiles.saveSnapshot(snapshot, for: run.id)
                terminal.didSaveSnapshot(snapshot)
            } catch {
                // The terminal keeps the snapshot for the next recording pass.
            }
        }
        if run.cli == .commandCode, agentRuns[run.address]?.conversationID == nil,
            let id = await agentFiles.commandCodeSession(for: run.id),
            agentRuns[run.address]?.id == run.id, agentRuns[run.address]?.conversationID == nil
        {
            agentRuns[run.address]?.conversationID = id
            scheduleSave()
        }
    }

    private func finishAgent(at address: NodeAddress, runID: UUID, exitCode: Int32?, error: String?) async {
        guard let run = agentRuns[address], run.id == runID, run.state.isActive else { return }
        if let terminal = terminals[address] {
            terminal.recording?.cancel()
            await terminal.recording?.value
            await saveOutput(of: terminal, for: run)
        }
        guard var current = agentRuns[address], current.id == runID, current.state.isActive else { return }
        switch current.state {
        case .stopping: current.state = .stopped
        case .interrupting: current.state = .interrupted
        default: current.state = error != nil || exitCode != 0 ? .failed : .exited
        }
        current.exitCode = exitCode
        current.error = error
        current.finishedAt = .now
        agentRuns[address] = current
        terminals.removeValue(forKey: address)
        releaseMCP(for: current)
        scheduleSave()
    }

    private func promptContext(for run: AgentRun, in session: BoardSession) -> String {
        let scope = session.board.context(above: run.address.nodeID)
        var parts = ["Working directory: \(run.directory)"]
        if let id = scope.projectID, let node = session.board.nodes[id], case .project(let project) = node.content {
            parts.append("Project: \(node.title)")
            if !project.details.isEmpty { parts.append("Project notes:\n\(project.details)") }
        }
        parts.append("Mindmap ADE MCP tools can read this conversation's context and update its map branch.")
        return parts.joined(separator: "\n") + "\n\nTask:\n"
    }
}
