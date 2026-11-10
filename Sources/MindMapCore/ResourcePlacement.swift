import Foundation

public enum ResourcePlacementProblem: Equatable, Sendable {
    case projectBelowResource, worktreeSourceChange, missingGitProject, differentRepository
    case agentWorktreeChange, missingAgentWorktree

    public var message: String {
        switch self {
        case .projectBelowResource: "Place projects on separate branches."
        case .worktreeSourceChange: "Keep the worktree with its source checkout."
        case .missingGitProject: "Keep the worktree under a configured Git project."
        case .differentRepository: NodeContext.Problem.differentRepository.message
        case .agentWorktreeChange: "Keep the Agent under its current worktree."
        case .missingAgentWorktree: "Move the Agent under a configured worktree."
        }
    }
}

public struct BranchResources: Sendable {
    fileprivate var hasProject = false
    fileprivate var hasWorktree = false
    fileprivate var requiresGitProject = false
    fileprivate var requiredRepositories = Set<String>()
    fileprivate var usesAncestorSource = false
    fileprivate var hasPreparedWorktree = false
    fileprivate var usesProjectCheckout = false
    fileprivate var worktreeSourceID: UUID?
    fileprivate var agentWorktreeID: UUID?
    fileprivate var requiresAgentWorktree = false

    fileprivate mutating func addWorktree(_ worktree: WorktreeTopic, needsProject: Bool) {
        hasWorktree = true
        guard needsProject else { return }
        requiresGitProject = true
        if let repository = worktree.location?.gitCommonDirectory ?? worktree.choice.pendingPlan?.gitCommonDirectory {
            requiredRepositories.insert(repository)
        }
    }

    fileprivate func projectProblem(gitDirectory: String?) -> ResourcePlacementProblem? {
        guard requiresGitProject else { return nil }
        guard let gitDirectory else { return .missingGitProject }
        return requiredRepositories.contains { $0 != gitDirectory } ? .differentRepository : nil
    }

    fileprivate func sourceID(in context: NodeContext) -> UUID? {
        context.worktreeID ?? (usesProjectCheckout ? context.projectID : nil)
    }
}

extension MindMapBoard {
    public func canInsertResource(_ kind: NodeKind, under parent: UUID?) -> Bool {
        permitsResource(.draft(kind), under: parent)
    }

    func permitsResource(_ content: NodeContent, under parent: UUID?) -> Bool {
        switch content {
        case .project:
            let path = resourceAncestors(of: parent)
            return path.projectCount == 0 && !path.hasSource
        case .branch:
            return false
        case .worktree(let worktree):
            let path = resourceAncestors(of: parent)
            let scope = context(startingAt: parent)
            guard path.projectCount == 1, scope.problem == nil else { return false }
            if let source = scope.worktreeID, parent != source { return false }
            var resources = BranchResources()
            resources.addWorktree(worktree, needsProject: true)
            return resources.projectProblem(gitDirectory: path.gitDirectory) == nil
        case .text, .agent:
            return true
        }
    }

    public func canInsertResourceParent(_ content: NodeContent, above child: UUID) -> Bool {
        guard nodes[child] != nil else { return false }
        switch content {
        case .project(let project):
            guard permitsResource(content, under: parents[child]) else { return false }
            let resources = branchResources(in: child)
            return !resources.hasProject
                && resources.projectProblem(gitDirectory: project.location?.gitCommonDirectory) == nil
        case .worktree:
            guard permitsResource(content, under: parents[child]) else { return false }
            let resources = branchResources(in: child)
            return !resources.hasProject && !resources.hasWorktree && resources.agentWorktreeID == nil
        case .branch:
            return false
        case .text, .agent:
            return true
        }
    }

    public func resources(in branches: [UUID]) -> [UUID: BranchResources] {
        var result: [UUID: BranchResources] = [:]
        for id in branches {
            let resources = branchResources(in: id)
            if resources.hasProject || resources.hasWorktree || resources.agentWorktreeID != nil
                || resources.requiresAgentWorktree || resources.usesAncestorSource
            {
                result[id] = resources
            }
        }
        return result
    }

    public func resourceMoveProblem(
        for branches: [UUID: BranchResources], to parent: UUID?
    ) -> ResourcePlacementProblem? {
        guard !branches.isEmpty else { return nil }
        let path = resourceAncestors(of: parent)
        let context = context(startingAt: parent)
        for (id, resources) in branches where parents[id] != parent {
            if resources.hasProject && (path.projectCount > 0 || path.hasSource) { return .projectBelowResource }
            if resources.requiresGitProject && path.projectCount > 1 { return .projectBelowResource }
            if let problem = resources.projectProblem(gitDirectory: path.gitDirectory) { return problem }
            if resources.usesAncestorSource {
                if let source = context.worktreeID, parent != source || nodes[id]?.content.kind != .worktree {
                    return .worktreeSourceChange
                }
                if resources.sourceID(in: context) != resources.worktreeSourceID
                    && (resources.worktreeSourceID != nil || resources.hasPreparedWorktree || context.problem != nil)
                {
                    return .worktreeSourceChange
                }
            }
            if let worktreeID = resources.agentWorktreeID {
                if context.worktreeID != worktreeID { return .agentWorktreeChange }
            } else if resources.requiresAgentWorktree && (context.worktree == nil || context.problem != nil) {
                return .missingAgentWorktree
            }
        }
        return nil
    }

    public func projectBindingProblem(for id: UUID, to location: ProjectLocation) -> ResourcePlacementProblem? {
        guard let node = nodes[id], case .project(let project) = node.content, project.location != location else {
            return nil
        }
        for child in node.children {
            let resources = branchResources(in: child)
            if let problem = resources.projectProblem(gitDirectory: location.gitCommonDirectory) { return problem }
            if resources.worktreeSourceID == id, let directory = project.location?.directory,
                directory != location.directory
            {
                return .worktreeSourceChange
            }
        }
        return nil
    }

    // Track the resources whose project or worktree is outside the moved branch.
    private func branchResources(in root: UUID) -> BranchResources {
        var result = BranchResources()
        var usesAncestorWorktree = false
        var pending = [(id: root, hasProject: false, hasWorktree: false)]
        while let next = pending.popLast() {
            guard let node = nodes[next.id] else { continue }
            var hasProject = next.hasProject
            var hasWorktree = next.hasWorktree
            switch node.content {
            case .project:
                result.hasProject = true
                hasProject = true
            case .worktree(let worktree):
                result.addWorktree(worktree, needsProject: !hasProject)
                if !hasProject && !hasWorktree {
                    result.usesAncestorSource = true
                    if worktree.location != nil || worktree.choice.pendingPlan != nil {
                        result.hasPreparedWorktree = true
                    }
                    if worktree.creationCommit != nil || worktree.choice.pendingPlan != nil {
                        result.usesProjectCheckout = true
                    }
                }
                hasWorktree = true
            case .agent(let agent) where !hasProject && !hasWorktree:
                usesAncestorWorktree = true
                result.requiresAgentWorktree = result.requiresAgentWorktree || agent.isConfigured
                if let plan = agent.worktreeChoice.pendingPlan {
                    result.usesAncestorSource = true
                    result.hasPreparedWorktree = true
                    result.requiresGitProject = true
                    result.requiredRepositories.insert(plan.gitCommonDirectory)
                }
            case .text, .agent, .branch:
                break
            }
            for child in node.children { pending.append((child, hasProject, hasWorktree)) }
        }
        if usesAncestorWorktree || result.usesAncestorSource {
            let scope = context(above: root)
            if usesAncestorWorktree { result.agentWorktreeID = scope.worktreeID }
            if result.usesAncestorSource { result.worktreeSourceID = result.sourceID(in: scope) }
        }
        return result
    }

    private func resourceAncestors(of parent: UUID?) -> (projectCount: Int, hasSource: Bool, gitDirectory: String?) {
        var result = (projectCount: 0, hasSource: false, gitDirectory: nil as String?)
        var current = parent
        while let id = current, let node = nodes[id] {
            switch node.content {
            case .project(let project):
                if result.projectCount == 0 { result.gitDirectory = project.location?.gitCommonDirectory }
                result.projectCount += 1
            case .worktree:
                result.hasSource = true
            case .text, .agent, .branch:
                break
            }
            current = parents[id]
        }
        return result
    }
}
