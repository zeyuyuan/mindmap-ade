import Foundation
import Testing

@testable import MindMapCore

@Test func legacyTextArchiveMigratesWithoutChangingTheTree() throws {
    let board = UUID()
    let root = UUID()
    let legacy = """
        {
          "schemaVersion": 1,
          "boards": [{
            "id": "\(board.uuidString)",
            "name": "Original",
            "roots": [{"id": "\(root.uuidString)", "position": [30, 60]}],
            "nodes": ["\(root.uuidString)", {
              "id": "\(root.uuidString)", "text": "Original text", "children": [], "isCollapsed": false
            }]
          }],
          "cameras": []
        }
        """
    let archive = try JSONDecoder().decode(WorkspaceArchive.self, from: Data(legacy.utf8)).validated()
    #expect(archive.schemaVersion == 7)
    #expect(archive.boards.first?.nodes[root]?.content == .text)
    #expect(archive.boards.first?.nodes[root]?.text == "Original text")
    #expect(archive.boards.first?.roots.first?.position == CGPoint(x: 30, y: 60))
}

@Test func legacyBranchNodesFlattenAndKeepExplicitCheckoutBindings() throws {
    let directory = "/project"
    let repository = "/project/.git"
    var project = ProjectTopic()
    project.location = ProjectLocation(directory: directory, gitCommonDirectory: repository)
    let agent = MapNode(content: .agent(AgentTopic(task: "Keep this conversation")))
    let checkout = MapNode(
        children: [agent.id],
        content: .worktree(
            WorktreeTopic(
                location: WorktreeLocation(
                    directory: directory, gitCommonDirectory: repository, branch: "main", commit: "abc", isPrimary: true
                ))))
    let plan = WorktreePlan(directory: "/worktrees/fix", gitCommonDirectory: repository, branch: "fix", commit: "def")
    var draft = WorktreeTopic()
    draft.choice.pendingPlan = plan
    let draftNode = MapNode(content: .worktree(draft))
    let note = MapNode(text: "Keep this task", children: [draftNode.id])
    var branch = LegacyBranchTopic()
    branch.name = "feature/editor"
    branch.reference = "refs/heads/feature/editor"
    let legacy = MapNode(children: [note.id], content: .branch(branch))
    let root = MapNode(children: [legacy.id, checkout.id], content: .project(project))
    var board = MindMapBoard(root: root)
    board.apply(
        BoardEdit(
            nodes: [agent, checkout, draftNode, note, legacy].map {
                NodeReplacement(id: $0.id, node: $0)
            }))
    let camera = MapCamera(scale: 0.5, translation: CGPoint(x: 40, y: 12))
    var archive = WorkspaceArchive(boards: [board], cameras: [board.id: camera], selectedBoardID: board.id)
    archive.schemaVersion = 3

    let migrated = try JSONDecoder().decode(WorkspaceArchive.self, from: JSONEncoder().encode(archive)).validated()
    let result = try #require(migrated.boards.first)
    #expect(migrated.schemaVersion == 7)
    #expect(migrated.selectedBoardID == board.id)
    #expect(migrated.cameras[board.id] == camera)
    #expect(result.roots == board.roots)
    #expect(Set(result.nodes.keys) == Set(board.nodes.keys).subtracting([legacy.id]))
    #expect(result.nodes[root.id]?.children == [note.id, checkout.id])
    #expect(result.nodes[checkout.id] == checkout)
    #expect(result.context(above: agent.id).worktree?.directory == directory)
    #expect(result.nodes[agent.id] == agent)
    guard case .worktree(let migratedDraft) = result.nodes[draftNode.id]?.content else {
        Issue.record("Missing the migrated worktree draft")
        return
    }
    #expect(migratedDraft.choice.base == branch.reference)
    #expect(migratedDraft.choice.pendingPlan == plan)
    let reopened = try JSONDecoder().decode(WorkspaceArchive.self, from: JSONEncoder().encode(migrated)).validated()
    #expect(reopened.boards.first == result)
}

@Test(arguments: [false, true])
func oldProjectCheckoutLiftsBranchesAndKeepsInheritedAgentBindings(hasInheritedAgent: Bool) throws {
    let directory = "/project"
    let common = "/project/.git"
    var project = ProjectTopic()
    project.location = ProjectLocation(directory: directory, gitCommonDirectory: common)
    var agent = AgentTopic(task: "Keep this conversation")
    agent.isConfigured = true
    let inherited = MapNode(content: .agent(agent))
    let inheritedNote = MapNode(text: "Agent plan", children: [inherited.id])
    let derivedAgent = MapNode(content: .agent(agent))
    let derived = MapNode(
        children: [derivedAgent.id],
        content: .worktree(
            WorktreeTopic(
                location: WorktreeLocation(
                    directory: "/feature", gitCommonDirectory: common, branch: "fix", commit: "abc", isPrimary: false),
                creationCommit: "abc")))
    var worktree = WorktreeTopic()
    worktree.choice.branch = "feature/draft"
    let draft = MapNode(content: .worktree(worktree))
    let note = MapNode(text: "Keep this text", children: [draft.id])
    var synthetic = WorktreeTopic(
        location: WorktreeLocation(
            directory: directory, gitCommonDirectory: common, branch: nil, commit: "", isPrimary: false))
    synthetic.isProjectDirectory = true
    let checkout = MapNode(
        children: [derived.id, note.id] + (hasInheritedAgent ? [inheritedNote.id] : []), content: .worktree(synthetic))
    let root = MapNode(children: [checkout.id], content: .project(project))
    var board = MindMapBoard(root: root)
    let descendants =
        [checkout, derived, derivedAgent, note, draft] + (hasInheritedAgent ? [inheritedNote, inherited] : [])
    board.apply(BoardEdit(nodes: descendants.map { NodeReplacement(id: $0.id, node: $0) }))
    var archive = WorkspaceArchive(boards: [board])
    archive.schemaVersion = 5
    let reopened = try JSONDecoder().decode(WorkspaceArchive.self, from: JSONEncoder().encode(archive)).validated()
    let migrated = try #require(reopened.boards.first)
    #expect(migrated.nodes[root.id]?.children == [derived.id, note.id] + (hasInheritedAgent ? [checkout.id] : []))
    #expect(migrated.nodes[derived.id] == derived)
    #expect(migrated.context(above: derivedAgent.id).worktreeID == derived.id)
    #expect(migrated.nodes[draft.id] == draft)
    #expect(migrated.parents[draft.id] == note.id)
    if hasInheritedAgent {
        synthetic.isProjectDirectory = nil
        #expect(migrated.nodes[checkout.id]?.content == .worktree(synthetic))
        #expect(migrated.nodes[checkout.id]?.children == [inheritedNote.id])
        #expect(migrated.nodes[inherited.id] == inherited)
        #expect(migrated.context(above: inherited.id).worktree?.directory == directory)
    } else {
        #expect(migrated.nodes[checkout.id] == nil)
    }
    _ = try migrated.validated()
}

@Test func nearestProjectStopsWorktreeInheritanceAndUnfinishedBindingsBlockFallback() throws {
    let common = "/outer/.git"
    var outer = ProjectTopic()
    outer.location = ProjectLocation(directory: "/outer", gitCommonDirectory: common)
    let root = MapNode(content: .project(outer))
    var board = MindMapBoard(root: root)
    let location = WorktreeLocation(
        directory: "/work", gitCommonDirectory: common, branch: "main", commit: "abc", isPrimary: false)
    let tree = MapNode(content: .worktree(WorktreeTopic(location: location)))
    board.apply(try #require(board.inserting(tree, parent: root.id)).edit)
    let draft = MapNode(content: .project(ProjectTopic()))
    var legacyParent = try #require(board.nodes[tree.id])
    legacyParent.children = [draft.id]
    board.apply(
        BoardEdit(nodes: [
            NodeReplacement(id: tree.id, node: legacyParent), NodeReplacement(id: draft.id, node: draft),
        ]))
    let agent = MapNode(content: .agent(AgentTopic(task: "Original task")))
    board.apply(try #require(board.inserting(agent, parent: draft.id)).edit)
    #expect(board.context(above: agent.id).problem == .unfinishedProject)
    #expect(board.context(above: agent.id).worktree == nil)
    var inner = ProjectTopic()
    inner.location = ProjectLocation(directory: "/inner", gitCommonDirectory: "/inner/.git")
    board.apply(try #require(board.replacingContent(draft.id, with: .project(inner))))
    let archive = try JSONEncoder().encode(WorkspaceArchive(boards: [board]))
    board = try #require(JSONDecoder().decode(WorkspaceArchive.self, from: archive).validated().boards.first)
    #expect(board.context(above: agent.id).project == inner.location)
    #expect(board.context(above: agent.id).worktree == nil)
    board.apply(try #require(board.movingBranches([draft.id], to: nil)))
    #expect(board.parents[draft.id] == nil)
    #expect(board.context(above: agent.id).project == inner.location)
    let moved = try #require(board.moving(agent.id, to: tree.id))
    board.apply(moved)
    #expect(board.context(above: agent.id).worktree == location)
}

@Test func insertingAResourceParentKeepsTheOtherTopicsAndUndoesInOneStep() throws {
    var project = ProjectTopic()
    project.location = ProjectLocation(directory: "/project", gitCommonDirectory: "/project/.git")
    let root = MapNode(content: .project(project))
    var board = MindMapBoard(root: root)
    let agent = MapNode(content: .agent(AgentTopic(task: "Run", sourceTextID: root.id)))
    let sibling = MapNode(text: "Keep this")
    board.apply(try #require(board.inserting(agent, parent: root.id)).edit)
    board.apply(try #require(board.inserting(sibling, parent: root.id)).edit)
    let before = board
    let worktree = MapNode(content: .worktree(WorktreeTopic()))
    let inverse = board.apply(try #require(board.insertingParent(worktree, above: agent.id)))
    #expect(board.nodes[root.id]?.children == [worktree.id, sibling.id])
    #expect(board.parents[agent.id] == worktree.id)
    #expect(board.nodes[agent.id] == agent)
    _ = try board.validated()
    board.apply(inverse)
    #expect(board == before)
}

@Test func resourcePlacementChecksWholeBranchesAndKeepsWorktreesWithTheirRepository() throws {
    var project = ProjectTopic()
    project.location = ProjectLocation(directory: "/project", gitCommonDirectory: "/project/.git")
    var other = ProjectTopic()
    other.location = ProjectLocation(directory: "/other", gitCommonDirectory: "/other/.git")
    var alternate = ProjectTopic()
    alternate.location = ProjectLocation(directory: "/alternate", gitCommonDirectory: "/project/.git")
    let root = MapNode(text: "Workspace")
    var board = MindMapBoard(root: root)
    func insert(_ node: MapNode, under parent: UUID) throws -> UUID {
        let insertion = try #require(board.inserting(node, parent: parent))
        board.apply(insertion.edit)
        return insertion.id
    }
    let first = try insert(MapNode(content: .project(project)), under: root.id)
    let second = try insert(MapNode(content: .project(other)), under: root.id)
    let sameRepository = try insert(MapNode(content: .project(alternate)), under: root.id)
    let group = try insert(MapNode(text: "Tasks"), under: first)
    let tree = WorktreeTopic(
        location: WorktreeLocation(
            directory: "/checkout", gitCommonDirectory: "/project/.git", branch: "task", commit: "abc", isPrimary: false
        ),
        creationCommit: "abc")
    let checkout = try insert(MapNode(content: .worktree(tree)), under: group)
    let sibling = try insert(MapNode(content: .worktree(WorktreeTopic())), under: first)
    board.apply(try #require(board.togglingCollapse(group)))
    #expect(board.nodes[group]?.isCollapsed == true)

    #expect(board.inserting(MapNode(content: .project(ProjectTopic())), parent: group) == nil)
    #expect(board.inserting(MapNode(content: .worktree(WorktreeTopic())), parent: sibling) == nil)
    #expect(board.inserting(MapNode(content: .worktree(WorktreeTopic())), parent: root.id) == nil)
    #expect(board.inserting(MapNode(content: .worktree(tree)), parent: second) == nil)
    #expect(board.moving(first, to: second) == nil)
    #expect(board.movingBranches([group], to: second) == nil)
    #expect(board.movingBranches([group], to: sameRepository) == nil)
    #expect(board.movingBranches([group], to: sibling) == nil)
    #expect(board.movingBranches([group], to: nil) == nil)
    #expect(board.insertingParent(MapNode(content: .worktree(WorktreeTopic())), above: group) == nil)
    #expect(board.projectBindingProblem(for: first, to: try #require(other.location)) == .differentRepository)
    #expect(board.projectBindingProblem(for: first, to: ProjectLocation(directory: "/folder")) == .missingGitProject)
    #expect(board.projectBindingProblem(for: first, to: try #require(alternate.location)) == .worktreeSourceChange)
    #expect(board.projectBindingProblem(for: first, to: try #require(project.location)) == nil)

    let derived = try insert(MapNode(content: .worktree(WorktreeTopic())), under: checkout)
    #expect(board.context(above: derived).worktreeID == checkout)
    #expect(board.moving(derived, to: first) == nil)
    let note = try insert(MapNode(text: "Notes"), under: checkout)
    #expect(board.moving(derived, to: note) == nil)
    let draftFolder = try insert(MapNode(text: "Unstarted tasks"), under: first)
    let draftTree = try insert(MapNode(content: .draft(.worktree)), under: draftFolder)
    #expect(board.movingBranches([draftFolder], to: checkout) == nil)
    #expect(board.moving(draftTree, to: checkout) != nil)
    board.apply(try #require(board.movingBranches([checkout], to: first)))
    #expect(board.parents[checkout] == first)
    #expect(board.parents[derived] == checkout)
    #expect(board.parents[sibling] == first)
    board.apply(try #require(board.movingBranches([first], to: nil)))
    #expect(board.context(above: checkout).project == project.location)
}

@Test func movingAnAgentOrItsTextBranchKeepsTheOriginalWorktree() throws {
    let commonDirectory = "/project/.git"
    var project = ProjectTopic()
    project.location = ProjectLocation(directory: "/project", gitCommonDirectory: commonDirectory)
    let root = MapNode(content: .project(project))
    var board = MindMapBoard(root: root)
    func insert(_ node: MapNode, under parent: UUID?) throws -> UUID {
        let insertion = try #require(board.inserting(node, parent: parent))
        board.apply(insertion.edit)
        return insertion.id
    }
    let location = WorktreeLocation(
        directory: "/checkout", gitCommonDirectory: commonDirectory, branch: "task", commit: "abc", isPrimary: false)
    let original = try insert(MapNode(content: .worktree(WorktreeTopic(location: location))), under: root.id)
    let other = try insert(MapNode(content: .worktree(WorktreeTopic(location: location))), under: root.id)
    let tasks = try insert(MapNode(text: "Tasks"), under: original)
    let destination = try insert(MapNode(text: "Destination"), under: original)
    let group = try insert(MapNode(text: "Worktrees"), under: root.id)
    var agent = AgentTopic(task: "Configured task")
    agent.isConfigured = true
    let conversation = try insert(MapNode(content: .agent(agent)), under: tasks)
    let draft = try insert(MapNode(content: .draft(.agent)), under: original)

    #expect(board.moving(conversation, to: nil) == nil)
    #expect(board.moving(draft, to: root.id) == nil)
    #expect(board.movingBranches([tasks], to: nil) == nil)
    #expect(board.movingBranches([tasks, group], to: other) == nil)
    board.apply(try #require(board.movingBranches([tasks], to: destination)))
    board.apply(try #require(board.movingBranches([original, conversation], to: group)))
    #expect(board.parents[original] == group)
    #expect(board.parents[tasks] == destination)
    #expect(board.context(above: conversation).worktreeID == original)
    #expect(board.context(above: draft).worktreeID == original)

    let unboundDraft = try insert(MapNode(content: .draft(.agent)), under: root.id)
    let unbound = try insert(MapNode(content: .agent(agent)), under: root.id)
    let unfinished = try insert(MapNode(content: .draft(.worktree)), under: root.id)
    #expect(board.moving(unboundDraft, to: nil) != nil)
    #expect(board.moving(unbound, to: nil) == nil)
    #expect(board.moving(unbound, to: unfinished) == nil)
    board.apply(try #require(board.moving(unbound, to: original)))
    #expect(board.moving(unbound, to: root.id) == nil)
}
