import Foundation

public enum NodeKind: String, CaseIterable, Codable, Sendable {
    case text, project, worktree, agent

    public var title: String {
        switch self {
        case .text: "Text"
        case .project: "Project"
        case .worktree: "Worktree"
        case .agent: "Agent"
        }
    }
}

public struct ProjectLocation: Codable, Hashable, Sendable {
    public var directory: String
    public var gitCommonDirectory: String?

    public init(directory: String, gitCommonDirectory: String? = nil) {
        self.directory = directory
        self.gitCommonDirectory = gitCommonDirectory
    }
}

public struct ProjectTopic: Codable, Equatable, Sendable {
    public var name = ""
    public var details = ""
    public var directory = ""
    public var location: ProjectLocation?

    public init() {}
}

/// Compatibility with saved boards that represented Git refs as their own nodes.
public struct LegacyBranchTopic: Codable, Equatable, Sendable {
    public var name = ""
    public var reference = ""

    public init() {}
}

public struct WorktreeLocation: Codable, Equatable, Sendable {
    public var directory: String
    public var gitCommonDirectory: String
    public var branch: String?
    public var commit: String
    public var isPrimary: Bool

    public init(directory: String, gitCommonDirectory: String, branch: String?, commit: String, isPrimary: Bool) {
        self.directory = directory
        self.gitCommonDirectory = gitCommonDirectory
        self.branch = branch
        self.commit = commit
        self.isPrimary = isPrimary
    }

    public var name: String { URL(fileURLWithPath: directory).lastPathComponent }
    public var revisionLabel: String {
        if let branch { return branch }
        return commit.isEmpty ? "Current checkout" : "Detached at \(commit.prefix(8))"
    }
}

public struct WorktreePlan: Codable, Equatable, Sendable {
    public var directory: String
    public var gitCommonDirectory: String
    public var branch: String
    public var commit: String

    public init(directory: String, gitCommonDirectory: String, branch: String, commit: String) {
        self.directory = directory
        self.gitCommonDirectory = gitCommonDirectory
        self.branch = branch
        self.commit = commit
    }
}

public struct WorktreeChoice: Codable, Equatable, Sendable {
    public enum Mode: String, CaseIterable, Codable, Sendable {
        case existing, automatic, named

        public var title: String {
            switch self {
            case .existing: "Choose Existing"
            case .automatic: "Create Automatically"
            case .named: "Create with a Name"
            }
        }
    }

    public var mode: Mode
    public var existingDirectory = ""
    public var name = ""
    public var branch = ""
    public var base = "HEAD"
    public var pendingPlan: WorktreePlan?

    public init(mode: Mode = .automatic) { self.mode = mode }

    public var baseReference: String {
        let reference = base.trimmingCharacters(in: .whitespacesAndNewlines)
        return reference.isEmpty ? "HEAD" : reference
    }
}

public struct WorktreeTopic: Codable, Equatable, Sendable {
    public var choice = WorktreeChoice()
    public var location: WorktreeLocation?
    public var creationCommit: String?
    // Decoded only for migration of archives that synthesized a project checkout node.
    var isProjectDirectory: Bool?

    public init(location: WorktreeLocation? = nil, creationCommit: String? = nil) {
        self.location = location
        self.creationCommit = creationCommit
    }
}

public enum AgentCLIKind: String, CaseIterable, Codable, Sendable {
    case commandCode, codex

    public var title: String {
        switch self {
        case .commandCode: "Command Code"
        case .codex: "Codex"
        }
    }
}

public struct AgentTopic: Codable, Equatable, Sendable {
    public var name = ""
    public var task: String
    public var sourceTextID: UUID?
    public var worktreeChoice = WorktreeChoice()
    public var isConfigured = false
    public var progress: String?
    // Archives without a selection used Command Code.
    private var selectedCLI: AgentCLIKind?

    public var cli: AgentCLIKind {
        get { selectedCLI ?? .commandCode }
        set { selectedCLI = newValue == .commandCode ? nil : newValue }
    }

    public init(task: String = "", sourceTextID: UUID? = nil, cli: AgentCLIKind = .commandCode) {
        self.task = task
        self.sourceTextID = sourceTextID
        self.cli = cli
    }
}

public enum NodeContent: Codable, Equatable, Sendable {
    case text
    case project(ProjectTopic)
    case branch(LegacyBranchTopic)
    case worktree(WorktreeTopic)
    case agent(AgentTopic)

    public var kind: NodeKind {
        switch self {
        case .text, .branch: .text
        case .project: .project
        case .worktree: .worktree
        case .agent: .agent
        }
    }

    public var isDraft: Bool {
        switch self {
        case .text, .branch: false
        case .project(let project): project.location == nil
        case .worktree(let worktree): worktree.location == nil
        case .agent(let agent): !agent.isConfigured
        }
    }

    public static func draft(_ kind: NodeKind) -> NodeContent {
        switch kind {
        case .text: .text
        case .project: .project(ProjectTopic())
        case .worktree: .worktree(WorktreeTopic())
        case .agent: .agent(AgentTopic())
        }
    }
}

public struct NodeContext: Equatable, Sendable {
    public enum Problem: String, Equatable, Sendable {
        case missingProject, unfinishedProject, unfinishedWorktree, differentRepository

        public var message: String {
            switch self {
            case .missingProject: "Choose a project for this branch."
            case .unfinishedProject: "Finish configuring the project above this node."
            case .unfinishedWorktree: "Finish configuring the worktree above this node."
            case .differentRepository: "The worktree belongs to a different repository."
            }
        }
    }

    public var projectID: UUID?
    public var project: ProjectLocation?
    public var worktreeID: UUID?
    public var worktree: WorktreeLocation?
    public var problem: Problem?

    public init() {}
}

extension MindMapBoard {
    public func context(above id: UUID) -> NodeContext {
        context(startingAt: parents[id])
    }

    public func context(startingAt parent: UUID?) -> NodeContext {
        var result = NodeContext()
        var ancestor = parent
        while let id = ancestor, let node = nodes[id] {
            switch node.content {
            case .worktree(let value) where result.worktreeID == nil:
                result.worktreeID = id
                result.worktree = value.location
            case .project(let value):
                result.projectID = id
                result.project = value.location
                if let project = value.location {
                    if result.worktree.map({ $0.gitCommonDirectory != project.gitCommonDirectory }) == true {
                        result.problem = .differentRepository
                    } else if result.worktreeID != nil && result.worktree == nil {
                        result.problem = .unfinishedWorktree
                    }
                } else {
                    result.problem = .unfinishedProject
                }
                return result
            case .text, .agent, .branch, .worktree:
                break
            }
            ancestor = parents[id]
        }
        result.problem = .missingProject
        return result
    }
}
