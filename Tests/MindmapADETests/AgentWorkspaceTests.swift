import AppKit
import Carbon.HIToolbox
import Darwin
import Foundation
import Testing

@testable import MindMapCore
@testable import MindmapADE

struct ScratchRepository {
    let home: URL
    let repository: URL
    let data: URL

    init() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("MindmapADE-\(UUID())")
        repository = home.appendingPathComponent("Project 中文")
        data = home.appendingPathComponent("Workspace")
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        try git(["init", "--initial-branch=main"])
        try git([
            "-c", "user.name=Mindmap Tests", "-c", "user.email=qa@example.invalid",
            "-c", "commit.gpgsign=false", "commit", "--allow-empty", "-m", "Seed scratch repository",
        ])
    }

    @discardableResult
    func git(_ arguments: [String]) throws -> String {
        let result = try LocalCommand.run(
            executable: "/usr/bin/git", arguments: arguments, directory: repository.path,
            environment: ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("GIT_") },
            timeout: .seconds(10))
        guard result.status == 0 else { throw WorkspaceIssue(result.diagnostic) }
        return result.output
    }

    fileprivate func commandCodeStub(_ body: String) throws -> URL {
        try cliStub(
            "test-command-code",
            #"""
            #!/bin/sh
            if [ "$2" = mcp ]; then
                printf '%s\n' "$3" >> mcp-commands
                exit 0
            fi
            \#(body)
            """#)
    }

    fileprivate func cliStub(_ name: String, _ script: String) throws -> URL {
        let executable = home.appendingPathComponent(name)
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        return executable
    }

    func cleanUp() { try? FileManager.default.removeItem(at: home) }
}

private actor LaunchTestDisk: WorkspacePersistence {
    nonisolated let directory: URL
    private var value: WorkspaceArchive
    private var rejectStart = false

    init(directory: URL, board: MindMapBoard) {
        self.directory = directory
        value = WorkspaceArchive(boards: [board])
    }

    func load() -> (WorkspaceArchive?, Bool) { (value, true) }

    func save(_ archive: WorkspaceArchive) throws {
        if rejectStart, archive.agentRuns?.contains(where: { $0.state == .starting }) == true {
            throw CocoaError(.fileWriteNoPermission)
        }
        value = archive
    }

    func rejectLaunchSave(_ reject: Bool) { rejectStart = reject }
    func snapshot() -> WorkspaceArchive { value }
}

@Suite(.serialized)
@MainActor
struct AgentWorkspaceTests {
    @Test func gitDiscoversUnicodeLinkedAndDetachedWorktreesAndResumesAnExactPlan() async throws {
        let fixture = try ScratchRepository()
        defer { fixture.cleanUp() }
        let git = GitWorkspace()
        let project = try await git.project(at: fixture.repository.path)
        let detached = fixture.home.appendingPathComponent("Detached notes")
        try fixture.git(["worktree", "add", "--detach", detached.path, "HEAD"])
        let linkedProject = try await git.project(at: detached.path)
        #expect(linkedProject.gitCommonDirectory == project.gitCommonDirectory)
        let existing = try await git.worktrees(for: linkedProject)
        #expect(existing.count == 2)
        #expect(existing.first?.isPrimary == true)
        #expect(existing.last?.branch == nil)

        var choice = WorktreeChoice(mode: .named)
        choice.name = "检查-01"
        choice.branch = "mindmap/verify"
        let id = UUID()
        let plan = try await git.plan(choice, id: id, title: "Verify", project: project, dataDirectory: fixture.data)
        let created = try await git.create(plan, in: project, resuming: false)
        #expect(created.directory.hasSuffix("/检查-01"))
        #expect(created.commit == plan.commit)
        #expect(created.branch == "mindmap/verify")
        await #expect(throws: WorkspaceIssue.self) { try await git.create(plan, in: project, resuming: false) }
        let retried = try await git.create(plan, in: project, resuming: true)
        #expect(retried == created)
        #expect(try await git.worktrees(for: project).count == 3)
        choice.name = "../outside"
        await #expect(throws: WorkspaceIssue.self) {
            try await git.plan(choice, id: id, title: "Verify", project: project, dataDirectory: fixture.data)
        }
    }

    @Test func automaticWorktreeCanUseACustomBranchAndAnEmptyBaseUsesCurrentHead() async throws {
        let fixture = try ScratchRepository()
        defer { fixture.cleanUp() }
        let git = GitWorkspace()
        let project = try await git.project(at: fixture.repository.path)
        let head = try fixture.git(["rev-parse", "HEAD"]).trimmingCharacters(in: .newlines)
        let node = MapNode(content: .draft(.worktree))
        var choice = WorktreeChoice()
        choice.base = ""
        choice.branch = "qa/editor-fix"

        let plan = try await git.plan(
            choice, id: node.id, title: GitWorkspace.nameSeed(for: node), project: project, dataDirectory: fixture.data)
        let location = try await git.create(plan, in: project, resuming: false)
        #expect(location.commit == head)
        #expect(location.branch == "qa/editor-fix")
        #expect(location.name.hasPrefix("worktree-"))
    }

    @Test func failedLaunchSaveRetainsOneWorktreeAndRetryStartsInThatExactDirectory() async throws {
        _ = NSApplication.shared
        let fixture = try ScratchRepository()
        defer { fixture.cleanUp() }
        var project = ProjectTopic()
        project.location = try await GitWorkspace().project(at: fixture.repository.path)
        let root = MapNode(content: .project(project))
        var initial = MindMapBoard(root: root)
        let topic = AgentTopic(task: "Keep the task literal: `quote` $HOME")
        let executable = try fixture.commandCodeStub(
            #"""
            test -t 0 && pwd -P > actual-directory
            printf '%s' "$3" > actual-task
            set -m
            /bin/sh -c 'trap "" TERM HUP; echo $$ > child-pid.tmp; mv child-pid.tmp child-pid; exec /bin/sleep 99' &
            wait
            """#)
        let agent = MapNode(content: .agent(topic))
        initial.apply(try #require(initial.inserting(agent, parent: root.id)).edit)
        let disk = LaunchTestDisk(directory: fixture.data, board: initial)
        let workspace = WorkspaceStore(disk: disk)
        await workspace.loadIfNeeded()
        let session = try #require(workspace.boards.first)
        let address = NodeAddress(boardID: session.id, nodeID: agent.id)
        await disk.rejectLaunchSave(true)
        await #expect(throws: CocoaError.self) {
            try await workspace.launchAgent(topic, at: address, detectCLI: { _ in .init(path: executable.path) })
        }
        #expect(workspace.terminals[address] == nil)
        let binding = try #require(session.board.context(above: agent.id).worktree)
        #expect(session.board.context(above: agent.id).projectID == root.id)
        #expect(workspace.agentRuns[address]?.state == .failed)
        #expect(try await workspace.git.worktrees(for: try #require(project.location)).count == 2)

        await disk.rejectLaunchSave(false)
        try await workspace.launchAgent(topic, at: address, detectCLI: { _ in .init(path: executable.path) })
        defer { workspace.stopAgent(at: address) }
        #expect(workspace.agentRuns[address]?.state == .running)
        #expect(session.board.context(above: agent.id).worktree == binding)
        let path = URL(fileURLWithPath: binding.directory)
        let marker = path.appendingPathComponent("actual-directory")
        let childMarker = path.appendingPathComponent("child-pid")
        try await waitUntil { FileManager.default.fileExists(atPath: childMarker.path) }
        let actual = try String(contentsOf: marker, encoding: .utf8).trimmingCharacters(in: .newlines)
        #expect(URL(fileURLWithPath: actual).resolvingSymlinksInPath().path == binding.directory)
        let task = try String(contentsOf: path.appendingPathComponent("actual-task"), encoding: .utf8)
        #expect(task.hasSuffix(topic.task))
        let childPID = try #require(
            Int32(String(contentsOf: childMarker, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        let childSession = getsid(childPID)
        #expect(getpgid(childPID) != childSession)
        defer {
            if childSession > 0, getsid(childPID) == childSession { _ = kill(childPID, SIGKILL) }
        }
        await #expect(throws: WorkspaceIssue.self) {
            try await workspace.launchAgent(topic, at: address, detectCLI: { _ in .init(path: executable.path) })
        }
        let before = session.board
        let remove = try #require(before.deleting([agent.id]))
        #expect(!session.apply(remove, named: "Delete Active Agent"))
        #expect(session.board == before)
        session.undo()
        #expect(session.board == before)
        #expect(session.canUndo)
        workspace.stopAgent(at: address)
        try await waitUntil { workspace.agentRuns[address]?.state == .stopped && kill(childPID, 0) != 0 }
        try await workspace.flush()
        #expect(await disk.snapshot().agentRuns?.first?.state == .stopped)
        #expect(FileManager.default.fileExists(atPath: binding.directory))
    }

    @Test func projectShowsItsBoundCheckoutAndWorktreesDeriveFromLiveParentHead() async throws {
        _ = NSApplication.shared
        let fixture = try ScratchRepository()
        defer { fixture.cleanUp() }
        let linked = fixture.home.appendingPathComponent("Editor checkout")
        try fixture.git(["worktree", "add", "-b", "feature/editor", linked.path, "HEAD"])
        let author = [
            "-c", "user.name=Mindmap Tests", "-c", "user.email=qa@example.invalid", "-c", "commit.gpgsign=false",
        ]
        let root = MapNode(content: .draft(.project))
        let disk = LaunchTestDisk(directory: fixture.data, board: MindMapBoard(root: root))
        let workspace = WorkspaceStore(disk: disk)
        await workspace.loadIfNeeded()
        let session = try #require(workspace.boards.first)
        func address(_ node: UUID) -> NodeAddress { NodeAddress(boardID: session.id, nodeID: node) }
        func insert(_ content: NodeContent, under parent: UUID) throws -> UUID {
            let result = try #require(session.board.inserting(MapNode(content: content), parent: parent))
            #expect(session.apply(result.edit, named: "Insert test topic"))
            return result.id
        }

        var project = ProjectTopic()
        project.directory = linked.path
        try await workspace.saveProject(project, at: address(root.id))
        let scope = session.board.context(startingAt: root.id)
        let binding = try #require(scope.project)
        #expect(session.board.nodes[root.id]?.children.isEmpty == true)
        #expect(session.gitProjectLocations == [root.id: binding])
        #expect(scope.worktree == nil)
        #expect(binding.directory == linked.resolvingSymlinksInPath().path)
        #expect(try await workspace.git.worktrees(for: binding).count == 2)
        #expect(try await workspace.git.checkoutLabel(for: binding) == "feature/editor")
        try await workspace.saveProject(project, at: address(root.id))
        #expect(session.board.nodes[root.id]?.children.isEmpty == true)

        var conversation = AgentTopic(task: "Use the project's selected checkout")
        let executable = try fixture.commandCodeStub("pwd -P > agent-directory")
        conversation.worktreeChoice = WorktreeChoice(mode: .existing)
        conversation.worktreeChoice.existingDirectory = binding.directory
        let directAgent = try insert(.agent(conversation), under: root.id)
        try await workspace.launchAgent(
            conversation, at: address(directAgent),
            detectCLI: { _ in
                .init(path: executable.path)
            })
        defer { workspace.stopAgent(at: address(directAgent)) }
        let marker = linked.appendingPathComponent("agent-directory")
        try await waitUntil {
            workspace.agentRuns[address(directAgent)]?.state.isActive == false
                && FileManager.default.fileExists(atPath: marker.path)
        }
        let actual = try String(contentsOf: marker, encoding: .utf8).trimmingCharacters(in: .newlines)
        #expect(URL(fileURLWithPath: actual).resolvingSymlinksInPath().path == binding.directory)
        let explicitCheckout = try #require(session.board.parents[directAgent])
        #expect(session.board.parents[explicitCheckout] == root.id)
        #expect(session.board.context(above: directAgent).worktree?.directory == binding.directory)
        #expect(try await workspace.git.worktrees(for: binding).count == 2)

        try fixture.git(["-C", linked.path, "switch", "-c", "feature/editor-next"])
        try fixture.git(["-C", linked.path] + author + ["commit", "--allow-empty", "-m", "Editor commit"])
        #expect(try await workspace.git.checkoutLabel(for: binding) == "feature/editor-next")
        let worktree = try insert(.draft(.worktree), under: root.id)
        var parent = WorktreeTopic()
        parent.choice.mode = .named
        parent.choice.name = "legacy-folder"
        parent.choice.base = "main"
        parent.choice.branch = "feature/undo"
        try await workspace.saveWorktree(parent, at: address(worktree))
        let checkout = try #require(session.board.context(startingAt: worktree).worktree)
        let editorCommit = try fixture.git(["-C", linked.path, "rev-parse", "HEAD"])
            .trimmingCharacters(in: .newlines)
        #expect(checkout.commit == editorCommit)
        #expect(checkout.branch == "feature/undo")
        #expect(checkout.name.hasPrefix("worktree-"))

        try fixture.git(["-C", checkout.directory] + author + ["commit", "--allow-empty", "-m", "Undo commit"])
        let liveParentCommit = try fixture.git(["-C", checkout.directory, "rev-parse", "HEAD"])
            .trimmingCharacters(in: .newlines)
        var derived = WorktreeTopic()
        derived.choice.branch = "fix/undo"
        derived.choice.pendingPlan = WorktreePlan(
            directory: fixture.home.appendingPathComponent("Never created").path,
            gitCommonDirectory: checkout.gitCommonDirectory, branch: "fix/undo", commit: checkout.commit)
        let child = try insert(.worktree(derived), under: worktree)
        try await workspace.saveWorktree(derived, at: address(child))
        let childCheckout = try #require(session.board.context(startingAt: child).worktree)
        #expect(childCheckout.commit == liveParentCommit)
        #expect(childCheckout.commit != checkout.commit)
        #expect(session.board.nodes[child]?.title == "fix/undo")
        #expect(session.board.parents[child] == worktree)
        #expect(session.board.moving(child, to: root.id) == nil)

        let agent = try insert(.draft(.agent), under: child)
        #expect(session.board.context(above: agent).worktreeID == child)
        #expect(session.board.context(above: agent).worktree?.directory == childCheckout.directory)
        #expect(session.board.moving(agent, to: worktree) == nil)
        #expect(session.board.nodes[root.id]?.children == [explicitCheckout, worktree])
        #expect(session.board.parents[worktree] == root.id)
        #expect(try await workspace.git.worktrees(for: binding).count == 4)
    }

    @Test func legacyCustomDraftUsesDetectedCommandCodeAndScopedMapTools() async throws {
        _ = NSApplication.shared
        let fixture = try ScratchRepository()
        defer { fixture.cleanUp() }
        let executable = try fixture.commandCodeStub("exec /bin/sleep 30")
        let original = AgentTopic(task: "Test the map connection")
        let encoded = try JSONEncoder().encode(original)
        var legacy = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let legacyLauncher: [String: Any] = [
            "kind": "custom", "executable": "/bin/false", "arguments": "legacy argument", "mapAccess": false,
        ]
        legacy["launcher"] = legacyLauncher
        legacy["name"] = "Saved conversation"
        let topic = try JSONDecoder().decode(AgentTopic.self, from: JSONSerialization.data(withJSONObject: legacy))
        #expect(topic.task == original.task)
        #expect(topic.name == "Saved conversation")
        #expect(topic.cli == .commandCode)
        let git = GitWorkspace()
        var project = ProjectTopic()
        project.location = try await git.project(at: fixture.repository.path)
        let location = try await git.existing(fixture.repository.path, in: try #require(project.location))
        let root = MapNode(content: .project(project))
        let tree = MapNode(content: .worktree(WorktreeTopic(location: location)))
        let agent = MapNode(content: .agent(topic))
        var board = MindMapBoard(root: root)
        board.apply(try #require(board.inserting(tree, parent: root.id)).edit)
        board.apply(try #require(board.inserting(agent, parent: tree.id)).edit)
        let disk = LaunchTestDisk(directory: fixture.data, board: board)
        let workspace = WorkspaceStore(disk: disk)
        await workspace.loadIfNeeded()
        let session = try #require(workspace.boards.first)
        let address = NodeAddress(boardID: board.id, nodeID: agent.id)
        await #expect(throws: WorkspaceIssue.self) {
            try await workspace.launchAgent(topic, at: address, detectCLI: { _ in nil })
        }
        try await workspace.launchAgent(topic, at: address, detectCLI: { _ in .init(path: executable.path) })
        defer { workspace.stopAgent(at: address) }
        #expect(workspace.agentRuns[address]?.state == .running)
        #expect(workspace.agentRuns[address]?.launcher.executable == executable.path)
        let token = try #require(workspace.mcpGrants.keys.first)
        let connection = try #require(workspace.mcpListener).path
        let commands = fixture.repository.appendingPathComponent("mcp-commands")
        #expect(try String(contentsOf: commands, encoding: .utf8).split(whereSeparator: \.isNewline) == ["add"])

        let initial = try await request(connection, token: token, method: "initialize")
        #expect(initial["result"] != nil)
        let denied = try await request(connection, token: "wrong-token", method: "tools/list")
        #expect(denied["error"] != nil)
        let create: [String: Any] = ["name": "create_node", "arguments": ["text": "Child", "operationId": "add-1"]]
        let first = try await request(connection, token: token, method: "tools/call", params: create)
        let repeated = try await request(connection, token: token, method: "tools/call", params: create)
        #expect(try toolResult(first)["nodeId"] as? String == toolResult(repeated)["nodeId"] as? String)
        #expect(session.board.nodes[agent.id]?.children.count == 1)
        let outside = try await request(
            connection, token: token, method: "tools/call",
            params: [
                "name": "create_node",
                "arguments": ["text": "Outside", "operationId": "outside", "parentId": root.id.uuidString],
            ])
        #expect((outside["result"] as? [String: Any])?["isError"] as? Bool == true)
        let other = fixture.home.appendingPathComponent("New branch")
        try fixture.git(["worktree", "add", "-b", "external", other.path, "HEAD"])
        let register = try await request(
            connection, token: token, method: "tools/call",
            params: [
                "name": "register_worktree",
                "arguments": ["directory": other.path, "operationId": "reg-1", "task": "Follow-up"],
            ])
        #expect(try toolResult(register)["requiresRebind"] as? Bool == true)
        #expect(try toolResult(register)["draftAgentId"] != nil)
        #expect(session.board.context(above: agent.id).worktree?.directory == location.directory)
        #expect(await disk.snapshot().boards[0].nodes.count == 6)
        try await workspace.interruptAllAgents()
        let ended = try await request(connection, token: token, method: "tools/list")
        #expect(ended["error"] != nil)
        #expect(
            try String(contentsOf: commands, encoding: .utf8).split(whereSeparator: \.isNewline) == ["add", "remove"])
    }

    @Test func codexUsesTheBoundWorktreeAndARevocableMapConnection() async throws {
        _ = NSApplication.shared
        let fixture = try ScratchRepository()
        defer { fixture.cleanUp() }
        let executable = try fixture.cliStub(
            "test-codex",
            #"""
            #!/bin/sh
            id=0189aaaa-aaaa-4aaa-aaaa-aaaaaaaaaaaa
            if [ "$1" = app-server ]; then
                transcript="$PWD/codex-session.jsonl"
                while IFS= read -r line; do
                    case "$line" in
                        *'"initialize"'*) printf '{"id":1,"result":{}}\n' ;;
                        *'"thread/start"'*)
                            printf '{"id":2,"result":{"thread":{"id":"%s","path":"%s"}}}\n' "$id" "$transcript"
                            ;;
                        *'"thread/name/set"'*) touch "$transcript"; printf '{"id":3,"result":{}}\n' ;;
                        *'"thread/read"'*)
                            printf '{"id":2,"result":{"thread":{"id":"%s","path":"%s"}}}\n' "$id" "$transcript"
                            ;;
                    esac
                done
                exit 0
            fi
            test -t 0 || exit 21
            [ -S "$MINDMAP_MCP_SOCKET" ] && [ -n "$MINDMAP_MCP_TOKEN" ] || exit 22
            [ "$1" = -c ] && [ "$3" = --no-daemon ] || exit 23
            case "$2" in mcp_servers.mindmap_ade=*--mindmap-mcp*) ;; *) exit 24 ;; esac
            [ "$4" = resume ] && [ "$5" = "$id" ] || exit 25
            pwd -P > codex-directory
            exec /bin/sleep 30
            """#)
        let checkout = fixture.home.appendingPathComponent("Codex Worktree")
        try fixture.git(["worktree", "add", "-b", "codex-test", checkout.path, "HEAD"])
        let git = GitWorkspace()
        var project = ProjectTopic()
        project.location = try await git.project(at: fixture.repository.path)
        let location = try await git.existing(checkout.path, in: try #require(project.location))
        let root = MapNode(content: .project(project))
        let tree = MapNode(content: .worktree(WorktreeTopic(location: location)))
        let topic = AgentTopic(cli: .codex)
        let agent = MapNode(content: .agent(topic))
        var board = MindMapBoard(root: root)
        board.apply(try #require(board.inserting(tree, parent: root.id)).edit)
        board.apply(try #require(board.inserting(agent, parent: tree.id)).edit)
        let disk = LaunchTestDisk(directory: fixture.data, board: board)
        let workspace = WorkspaceStore(disk: disk)
        await workspace.loadIfNeeded()
        let address = NodeAddress(boardID: board.id, nodeID: agent.id)

        let detectCLI: @MainActor (AgentCLIKind) async -> AgentCLI.Executable? = { cli in
            cli == .codex ? .init(path: executable.path, supportsNoDaemon: true, supportsSessionIntegration: true) : nil
        }
        try await workspace.launchAgent(topic, at: address, detectCLI: detectCLI)
        defer { workspace.stopAgent(at: address) }
        let marker = checkout.appendingPathComponent("codex-directory")
        try await waitUntil { FileManager.default.fileExists(atPath: marker.path) }
        let directory = try String(contentsOf: marker, encoding: .utf8).trimmingCharacters(in: .newlines)
        #expect(URL(fileURLWithPath: directory).resolvingSymlinksInPath().path == location.directory)
        let token = try #require(workspace.mcpGrants.keys.first)
        let connection = try #require(workspace.mcpListener).path
        let tools = try await request(connection, token: token, method: "tools/list")
        #expect(tools["result"] != nil)
        try await workspace.interruptAllAgents()
        let ended = try await request(connection, token: token, method: "tools/list")
        #expect(ended["error"] != nil)

        try await workspace.flush()
        let archive = try JSONDecoder().decode(
            WorkspaceArchive.self, from: JSONEncoder().encode(await disk.snapshot()))
        guard case .agent(let saved) = archive.boards.first?.nodes[agent.id]?.content else {
            Issue.record("The saved board lost its Agent node.")
            return
        }
        #expect(saved.cli == .codex)
        let run = try #require(archive.agentRuns?.first)
        #expect(run.cli == .codex)
        #expect(run.state == .interrupted)
        #expect(run.conversationID == UUID(uuidString: "0189aaaa-aaaa-4aaa-aaaa-aaaaaaaaaaaa"))
        try FileManager.default.removeItem(at: marker)
        let restored = WorkspaceStore(disk: disk)
        await restored.loadIfNeeded()
        try await restored.resumeAgent(at: address, detectCLI: detectCLI)
        defer { restored.stopAgent(at: address) }
        try await waitUntil { FileManager.default.fileExists(atPath: marker.path) }
        #expect(restored.agentRuns[address]?.conversationID == run.conversationID)
        #expect(restored.agentRuns[address]?.id != run.id)
        try await restored.interruptAllAgents()
    }

    @Test func agentRecoveryRestoresThePaneAndRequiresConfirmationAfterASwitch() async throws {
        _ = NSApplication.shared
        let fixture = try ScratchRepository()
        defer { fixture.cleanUp() }
        let id = try #require(UUID(uuidString: "4f371e83-3a27-4474-b85d-2fd93212a841"))
        let executable = try fixture.commandCodeStub(
            #"""
            id=4f371e83-3a27-4474-b85d-2fd93212a841
            printf '%s' "$id" > "$MINDMAP_AGENT_SESSION_FILE"
            if [ "$4" = --session ]; then
                [ "$5" = "$id" ] && [ "$#" = 5 ] || exit 25
                echo "Original conversation resumed"
                echo "$id" > resumed
            else
                [ "$4" = -- ] && [ "$#" = 5 ] || exit 26
                echo "Output from the original terminal"
                echo "$id" > started
            fi
            exec /bin/sleep 30
            """#)
        let git = GitWorkspace()
        var project = ProjectTopic()
        let binding = try await git.project(at: fixture.repository.path)
        project.location = binding
        let root = MapNode(content: .project(project))
        let checkout = fixture.home.appendingPathComponent("Recoverable Worktree")
        try fixture.git(["worktree", "add", "-b", "recovery", checkout.path, "HEAD"])
        let location = try await git.existing(checkout.path, in: binding)
        let tree = MapNode(content: .worktree(WorktreeTopic(location: location)))
        let topic = AgentTopic(task: "Initial prompt")
        let node = MapNode(content: .agent(topic))
        var board = MindMapBoard(root: root)
        board.apply(try #require(board.inserting(tree, parent: root.id)).edit)
        board.apply(try #require(board.inserting(node, parent: tree.id)).edit)

        let disk = LaunchTestDisk(directory: fixture.data, board: board)
        let workspace = WorkspaceStore(disk: disk)
        await workspace.loadIfNeeded()
        let address = NodeAddress(boardID: board.id, nodeID: node.id)
        let detectCLI: @MainActor (AgentCLIKind) async -> AgentCLI.Executable? = { _ in
            .init(path: executable.path, supportsSessionIntegration: true)
        }
        try await workspace.launchAgent(topic, at: address, detectCLI: detectCLI)
        defer { workspace.stopAgent(at: address) }
        try await waitUntil { FileManager.default.fileExists(atPath: checkout.appendingPathComponent("started").path) }
        let camera = MapCamera(scale: 1.5, translation: CGPoint(x: 24, y: 52))
        workspace.rememberCamera(camera, for: board.id)
        workspace.rememberSelection([node.id], for: board.id)
        workspace.select(board.id)
        let actions = EditorActions()
        actions.workspace = workspace
        actions.showTerminal(at: address)
        actions.resizeTerminal(to: 0.43)
        try await workspace.interruptAllAgents()
        try await workspace.flush()

        let obsoleteRunID = UUID()
        try await workspace.agentFiles.saveSnapshot(Data("Obsolete output".utf8), for: obsoleteRunID)
        let restored = WorkspaceStore(disk: disk)
        await restored.loadIfNeeded()
        let restoredActions = EditorActions()
        restoredActions.workspace = restored
        restoredActions.restoreTerminalPane()
        #expect(restored.lastSelectedBoardID == board.id)
        #expect(restored.cameras[board.id] == camera)
        #expect(restored.selections[board.id] == [node.id])
        #expect(restoredActions.terminalAddress == address)
        #expect(restoredActions.terminalWidthShare == 0.43)
        let run = try #require(restored.agentRuns[address])
        #expect(run.state == .interrupted)
        #expect(run.conversationID == id)
        #expect(await restored.agentFiles.snapshot(for: run.id) == "Output from the original terminal")
        #expect(await restored.agentFiles.snapshot(for: obsoleteRunID) == nil)

        let secondWindow = EditorActions()
        secondWindow.workspace = restored
        secondWindow.restoreTerminalPane()
        #expect(secondWindow.terminalAddress == nil)
        restoredActions.detachTerminal()
        restored.releaseAgentPane(from: restoredActions.windowID)
        secondWindow.restoreTerminalPane()
        #expect(secondWindow.terminalAddress == address)
        #expect(secondWindow.terminalWidthShare == 0.43)

        await disk.rejectLaunchSave(true)
        await #expect(throws: CocoaError.self) {
            try await restored.launchAgent(topic, at: address, detectCLI: detectCLI)
        }
        await disk.rejectLaunchSave(false)
        #expect(restored.agentRuns[address] == run)
        #expect(await restored.agentFiles.snapshot(for: run.id) == "Output from the original terminal")

        try fixture.git(["-C", checkout.path, "switch", "-c", "switched"])
        let switched = "refs/heads/switched"
        await #expect(throws: AgentRecoveryIssue.checkoutChanged(previous: "refs/heads/recovery", current: switched)) {
            try await restored.resumeAgent(at: address, detectCLI: detectCLI)
        }
        #expect(restored.terminals[address] == nil)
        try await restored.resumeAgent(at: address, confirmedCheckout: switched, detectCLI: detectCLI)
        defer { restored.stopAgent(at: address) }
        let marker = checkout.appendingPathComponent("resumed")
        try await waitUntil { FileManager.default.fileExists(atPath: marker.path) }
        #expect(restored.agentRuns[address]?.conversationID == id)
        #expect(restored.agentRuns[address]?.previousSnapshotID == run.id)
        #expect(restored.agentRuns[address]?.checkout == switched)

        restored.stopAgent(at: address)
        try await restored.interruptAllAgents()
        try await restored.flush()
        let stopped = WorkspaceStore(disk: disk)
        await stopped.loadIfNeeded()
        defer { stopped.stopAgent(at: address) }
        let stoppedRun = try #require(stopped.agentRuns[address])
        stopped.requestAgentResume(at: address, owner: UUID(), automatically: true)
        #expect(stopped.agentRuns[address]?.state == .stopped)
        #expect(stopped.terminals[address] == nil)
        #expect(await stopped.agentFiles.snapshot(for: stoppedRun.id) == "Original conversation resumed")

        try fixture.git(["worktree", "remove", "--force", checkout.path])
        await #expect(throws: WorkspaceIssue.self) {
            try await stopped.resumeAgent(at: address, detectCLI: detectCLI)
        }
        await #expect(throws: WorkspaceIssue.self) {
            try await stopped.openAgentShell(at: address, owner: UUID())
        }
        #expect(stopped.agentRuns[address]?.id == stoppedRun.id)
        #expect(await stopped.agentFiles.snapshot(for: stoppedRun.id) == "Original conversation resumed")

        try fixture.git(["worktree", "add", checkout.path, "switched"])
        let replacement = try await git.agentCheckout(checkout.path, in: binding)
        #expect(replacement.location.directory == stoppedRun.directory)
        #expect(replacement.location.branch == "switched")
        #expect(replacement.identity != stoppedRun.worktreeIdentity)
        await #expect(throws: WorkspaceIssue.self) {
            try await stopped.resumeAgent(at: address, detectCLI: detectCLI)
        }
        #expect(stopped.agentRuns[address]?.id == stoppedRun.id)
        #expect(stopped.terminals[address] == nil)
    }

    @Test func terminalOutputRemainsPendingUntilWritten() async throws {
        _ = NSApplication.shared
        let terminal = AgentTerminal()
        try await terminal.start(
            executable: "/bin/sh", arguments: ["-c", "echo 'Pending output'; exec /bin/sleep 30"],
            environment: AgentCLI.environment(executable: "/bin/sh"), directory: "/")
        defer { terminal.stop() }
        var output: Data?
        try await waitUntil {
            output = await terminal.snapshotToSave()
            return output != nil
        }
        let snapshot = try #require(output)
        #expect(String(decoding: snapshot, as: UTF8.self) == "Pending output")
        #expect(await terminal.snapshotToSave() == snapshot)
        terminal.didSaveSnapshot(snapshot)
        #expect(await terminal.snapshotToSave() == nil)
    }

    @Test(arguments: [false, true])
    func controlCReturnsToAnInteractiveShellInTheSameWorktree(alternateScreen: Bool) async throws {
        _ = NSApplication.shared
        let fixture = try ScratchRepository()
        defer { fixture.cleanUp() }
        let cli = try fixture.commandCodeStub(
            #"""
            printf '%s' 4f371e83-3a27-4474-b85d-2fd93212a841 > "$MINDMAP_AGENT_SESSION_FILE"
            if [ "$4" = --session ]; then
                touch conversation-resumed
                exec /bin/sleep 30
            fi
            trap 'exit 0' INT
            printf 'Original terminal output\nMore terminal output\nFinal terminal output\n'
            if \#(alternateScreen ? "true" : "false"); then printf '\033[?1049h'; fi
            printf '\033[?2004h'
            touch agent-ready
            while IFS= read -r line; do :; done
            """#)
        let shell = try fixture.cliStub(
            "test-shell",
            #"""
            #!/bin/sh
            test "$1" = -i && test -t 0 || exit 40
            test -z "$MINDMAP_MCP_TOKEN$MINDMAP_MCP_SOCKET$MINDMAP_AGENT_SESSION_FILE" || exit 41
            PS1='Mindmap test shell$ ' ENV=/dev/null exec /bin/sh "$@"
            """#)
        var project = ProjectTopic()
        project.location = try await GitWorkspace().project(at: fixture.repository.path)
        let root = MapNode(content: .project(project))
        let topic = AgentTopic()
        let node = MapNode(content: .agent(topic))
        var board = MindMapBoard(root: root)
        board.apply(try #require(board.inserting(node, parent: root.id)).edit)
        let disk = LaunchTestDisk(directory: fixture.data, board: board)
        let workspace = WorkspaceStore(disk: disk, interactiveShell: shell.path)
        await workspace.loadIfNeeded()
        let address = NodeAddress(boardID: board.id, nodeID: node.id)
        let detectCLI: @MainActor (AgentCLIKind) async -> AgentCLI.Executable? = { _ in
            .init(path: cli.path, supportsSessionIntegration: true)
        }
        try await workspace.launchAgent(topic, at: address, detectCLI: detectCLI)
        let terminal = try #require(workspace.terminals[address])
        defer {
            terminal.stop()
            workspace.terminals[address]?.stop()
        }
        let run = try #require(workspace.agentRuns[address])
        let directory = URL(fileURLWithPath: run.directory)
        try await waitUntil {
            FileManager.default.fileExists(atPath: directory.appendingPathComponent("agent-ready").path)
        }
        #expect(terminal.view.sendKey(.c, modifiers: [.ctrl]))

        try await waitUntil { workspace.agentRuns[address]?.state == .exited && terminal.isShell }
        #expect(workspace.terminals[address] === terminal)
        #expect(workspace.agentRuns[address]?.exitCode == 0)
        #expect(workspace.mcpGrants.isEmpty)
        #expect(workspace.savedConversation(at: address) != nil)
        try await waitUntil {
            guard let snapshot = await terminal.snapshotToSave() else { return false }
            let text = String(decoding: snapshot, as: UTF8.self)
            return text.hasPrefix("Original terminal output\nMore terminal output\nFinal terminal output")
                && text.hasSuffix("Mindmap test shell$")
        }
        #expect(terminal.view.paste(text: "pwd -P > shell-directory"))
        let returnKey = try #require(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: terminal.view.window?.windowNumber ?? 0, context: nil,
                characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false,
                keyCode: UInt16(kVK_Return)))
        terminal.view.keyDown(with: returnKey)
        let marker = directory.appendingPathComponent("shell-directory")
        try await waitUntil { FileManager.default.fileExists(atPath: marker.path) }
        let actual = try String(contentsOf: marker, encoding: .utf8).trimmingCharacters(in: .newlines)
        #expect(URL(fileURLWithPath: actual).resolvingSymlinksInPath().path == directory.resolvingSymlinksInPath().path)

        try await workspace.resumeAgent(at: address, detectCLI: detectCLI)
        #expect(workspace.terminals[address] !== terminal)
        try await waitUntil {
            workspace.shellTerminals.isEmpty
                && FileManager.default.fileExists(atPath: directory.appendingPathComponent("conversation-resumed").path)
        }
        workspace.stopAgent(at: address)
        try await waitUntil { workspace.agentRuns[address]?.state == .stopped }
        #expect(workspace.terminals[address] == nil)

        try await workspace.openAgentShell(at: address, owner: UUID())
        #expect(workspace.terminals[address]?.isShell == true)
        try await workspace.interruptAllAgents()
        #expect(workspace.terminals[address] == nil)
        #expect(workspace.agentRuns[address]?.state == .stopped)
    }

    private func waitUntil(_ condition: () async -> Bool) async throws {
        for _ in 0..<200 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw WorkspaceIssue("Timed out waiting for the test process.")
    }

    private func request(
        _ path: String, token: String, method: String, params: [String: Any] = [:]
    ) async throws -> [String: Any] {
        let body = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0", "id": 1, "method": method, "params": params,
        ])
        let response = try await Task.detached {
            let descriptor = try MCPSocket.open()
            defer { Darwin.close(descriptor) }
            guard try MCPSocket.withAddress(path, { connect(descriptor, $0, $1) }) == 0 else {
                throw WorkspaceIssue("Could not connect to the test socket.")
            }
            let bytes = try JSONEncoder().encode(MCPEnvelope(token: token, message: body))
            MCPSocket.writeMessage(bytes, to: descriptor)
            return MCPSocket.readMessage(from: descriptor)
        }.value
        let received = try #require(response)
        return try #require(JSONSerialization.jsonObject(with: received) as? [String: Any])
    }

    private func toolResult(_ response: [String: Any]) throws -> [String: Any] {
        let result = try #require(response["result"] as? [String: Any])
        let content = try #require(result["content"] as? [[String: String]])
        let text = try #require(content.first?["text"])
        return try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }
}
