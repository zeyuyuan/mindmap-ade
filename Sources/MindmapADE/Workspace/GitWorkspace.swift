import CryptoKit
import Darwin
import Foundation
import MindMapCore

struct WorkspaceIssue: LocalizedError, Sendable {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// All Git operations for a workspace run away from the UI, including checkout.
actor GitWorkspace {
    struct AgentCheckout: Sendable {
        let location: WorktreeLocation
        let identity: String
        let directoryIdentity: String
    }

    func project(at path: String) throws -> ProjectLocation {
        let directory = try availableDirectory(path)
        let root: String
        do {
            root = try git(["rev-parse", "--show-toplevel"], in: directory)
        } catch let error as WorkspaceIssue where error.message.contains("not a git repository") {
            return ProjectLocation(directory: directory)
        }
        let common = try git(["rev-parse", "--path-format=absolute", "--git-common-dir"], in: directory)
        return ProjectLocation(directory: canonical(root), gitCommonDirectory: canonical(common))
    }

    func checkoutLabel(for project: ProjectLocation) throws -> String {
        _ = try verify(project)
        let prefix = "refs/heads/"
        if let reference = try? git(["symbolic-ref", "--quiet", "HEAD"], in: project.directory),
            reference.hasPrefix(prefix)
        {
            return String(reference.dropFirst(prefix.count))
        }
        let commit = try resolveCommit("HEAD", in: project.directory)
        return "Detached at \(commit.prefix(8))"
    }

    func worktrees(for project: ProjectLocation) throws -> [WorktreeLocation] {
        let common = try verify(project)
        let output = try git(["worktree", "list", "--porcelain", "-z"], in: project.directory)
        return output.components(separatedBy: "\0\0").enumerated().compactMap { index, record in
            let fields = record.split(separator: "\0").map(String.init)
            guard let path = fields.first, path.hasPrefix("worktree "),
                let head = fields.first(where: { $0.hasPrefix("HEAD ") }),
                !fields.contains("bare"), !fields.contains(where: { $0.hasPrefix("prunable") })
            else { return nil }
            let directory = canonical(String(path.dropFirst("worktree ".count)))
            let branch = fields.first { $0.hasPrefix("branch refs/heads/") }.map {
                String($0.dropFirst("branch refs/heads/".count))
            }
            return WorktreeLocation(
                directory: directory, gitCommonDirectory: common, branch: branch,
                commit: String(head.dropFirst("HEAD ".count)), isPrimary: index == 0)
        }
    }

    func existing(_ path: String, in project: ProjectLocation) throws -> WorktreeLocation {
        let directory = try availableDirectory(path)
        guard let tree = try worktrees(for: project).first(where: { $0.directory == directory }),
            try self.project(at: directory).gitCommonDirectory == tree.gitCommonDirectory
        else { throw WorkspaceIssue("Choose a worktree registered with this repository.") }
        return tree
    }

    func agentCheckout(_ path: String, in project: ProjectLocation) throws -> AgentCheckout {
        let location = try existing(path, in: project)
        let gitDirectory = try git(["rev-parse", "--absolute-git-dir"], in: location.directory)
        // Git can reuse both paths when a checkout is removed and created again.
        let folderIdentity = try directoryIdentity(location.directory)
        let gitIdentity = try directoryIdentity(gitDirectory)
        return AgentCheckout(
            location: location, identity: "\(folderIdentity):\(gitIdentity)", directoryIdentity: folderIdentity)
    }

    func plan(
        _ choice: WorktreeChoice, id: UUID, title: String, project: ProjectLocation, dataDirectory: URL,
        source: WorktreeLocation? = nil
    ) throws -> WorktreePlan {
        let common = try verify(project)
        let names = Self.names(for: choice, id: id, title: title)
        guard Self.isValidFolderName(names.name) else { throw WorkspaceIssue(Self.folderNameHelp) }
        guard !names.branch.hasPrefix("-"),
            (try? git(["check-ref-format", "refs/heads/\(names.branch)"], in: project.directory)) != nil
        else { throw WorkspaceIssue("Enter a valid Git branch name.") }
        let commit: String
        if let source {
            let checkout = try existing(source.directory, in: project)
            commit = try resolveCommit("HEAD", in: checkout.directory)
        } else {
            commit = try resolveCommit(choice.baseReference, in: project.directory)
        }
        let directory = Self.targetDirectory(common: common, name: names.name, dataDirectory: dataDirectory)
        guard !pathExists(directory) else {
            throw WorkspaceIssue(
                "A folder already exists at this path. Choose it from the worktree list or use another name.")
        }
        guard
            (try? git(["show-ref", "--verify", "--quiet", "refs/heads/\(names.branch)"], in: project.directory)) == nil
        else { throw WorkspaceIssue("That branch already exists. Choose its worktree or enter a new branch name.") }
        return WorktreePlan(
            directory: directory, gitCommonDirectory: common, branch: names.branch, commit: commit)
    }

    func preparedCheckout(_ plan: WorktreePlan, in project: ProjectLocation) throws -> WorktreeLocation? {
        guard plan.gitCommonDirectory == project.gitCommonDirectory else {
            throw WorkspaceIssue("The project changed. Prepare the worktree again.")
        }
        guard pathExists(plan.directory) else { return nil }
        guard let tree = try? existing(plan.directory, in: project),
            tree.branch == plan.branch, tree.commit == plan.commit
        else {
            throw WorkspaceIssue("The prepared checkout has changed. Use Link Existing Worktree to bind it.")
        }
        return tree
    }

    func create(
        _ plan: WorktreePlan, in project: ProjectLocation, resuming: Bool
    ) throws -> WorktreeLocation {
        guard plan.gitCommonDirectory == (try verify(project)) else {
            throw WorkspaceIssue("The project changed. Prepare the worktree again.")
        }
        let files = FileManager.default
        if pathExists(plan.directory) {
            if resuming, let tree = try? existing(plan.directory, in: project),
                tree.branch == plan.branch, tree.commit == plan.commit
            {
                return tree
            }
            throw WorkspaceIssue(
                "A folder already exists at this path. Choose it from the existing worktree list or use another name.")
        }
        try files.createDirectory(
            at: URL(fileURLWithPath: plan.directory).deletingLastPathComponent(),
            withIntermediateDirectories: true)
        _ = try git(
            ["worktree", "add", "-b", plan.branch, "--", plan.directory, plan.commit],
            in: project.directory)
        return try existing(plan.directory, in: project)
    }

    nonisolated static let folderNameHelp = "Use 1–64 letters, numbers, hyphens, periods, or underscores."

    nonisolated static func isValidFolderName(_ name: String) -> Bool {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return !name.isEmpty && name.count <= 64 && !name.hasPrefix(".")
            && name.allSatisfy { $0.isLetter || $0.isNumber || "-_.".contains($0) }
    }

    nonisolated static func nameSeed(for node: MapNode) -> String {
        node.content.kind == .worktree ? "worktree" : node.title
    }

    nonisolated static func names(for choice: WorktreeChoice, id: UUID, title: String) -> (name: String, branch: String)
    {
        let name: String
        if choice.mode == .named {
            name = choice.name.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            let words = title.lowercased().split { !$0.isASCII || (!$0.isLetter && !$0.isNumber) }
            let slug = String(words.joined(separator: "-").prefix(32)).trimmingCharacters(
                in: CharacterSet(charactersIn: "-"))
            name = "\(slug.isEmpty ? "task" : slug)-\(id.uuidString.prefix(8).lowercased())"
        }
        let branch = choice.branch.trimmingCharacters(in: .whitespacesAndNewlines)
        return (name, branch.isEmpty ? "mindmap/\(name)" : branch)
    }

    nonisolated static func targetDirectory(common: String, name: String, dataDirectory: URL) -> String {
        let id = SHA256.hash(data: Data(common.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
        return dataDirectory.appendingPathComponent("Worktrees/\(id)/\(name)").path
    }

    private func verify(_ project: ProjectLocation) throws -> String {
        guard let common = project.gitCommonDirectory else {
            throw WorkspaceIssue("This project is a folder. Choose a Git repository to use worktrees.")
        }
        guard try self.project(at: project.directory).gitCommonDirectory == common else {
            throw WorkspaceIssue("The repository at the project path has changed. Bind the project again.")
        }
        return common
    }

    private func resolveCommit(_ reference: String, in directory: String) throws -> String {
        do {
            return try git(["rev-parse", "--verify", "--end-of-options", "\(reference)^{commit}"], in: directory)
        } catch {
            throw WorkspaceIssue("The starting branch or commit is unavailable. Check the repository and try again.")
        }
    }

    private func availableDirectory(_ path: String) throws -> String {
        var directory: ObjCBool = false
        guard path.hasPrefix("/"), FileManager.default.fileExists(atPath: path, isDirectory: &directory),
            directory.boolValue, FileManager.default.isReadableFile(atPath: path)
        else { throw WorkspaceIssue("The selected folder is unavailable or unreadable.") }
        return canonical(path)
    }

    private func directoryIdentity(_ path: String) throws -> String {
        var info = stat()
        guard stat(path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else {
            throw WorkspaceIssue("The original worktree or its Git directory is unavailable.")
        }
        return Self.directoryIdentity(info)
    }

    nonisolated static func directoryIdentity(_ info: stat) -> String {
        let birth = info.st_birthtimespec
        return "\(info.st_ino)/\(birth.tv_sec)/\(birth.tv_nsec)"
    }

    private func pathExists(_ path: String) -> Bool {
        let files = FileManager.default
        return files.fileExists(atPath: path) || (try? files.destinationOfSymbolicLink(atPath: path)) != nil
    }

    private func canonical(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }

    private func git(_ arguments: [String], in directory: String) throws -> String {
        var environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("GIT_") }
        environment["LC_ALL"] = "C"
        environment["GIT_TERMINAL_PROMPT"] = "0"
        let result = try LocalCommand.run(
            executable: "/usr/bin/git", arguments: ["--no-pager"] + arguments,
            directory: directory, environment: environment,
            timeout: .seconds(arguments.starts(with: ["worktree", "add"]) ? 60 : 12))
        var text = result.output
        guard result.status == 0 else {
            let reason = result.diagnostic.trimmingCharacters(in: .whitespacesAndNewlines)
            throw WorkspaceIssue(
                reason.isEmpty ? "Git exited with status \(result.status)." : String(reason.prefix(1200)))
        }
        if text.last == "\n" { text.removeLast() }
        return text
    }
}
