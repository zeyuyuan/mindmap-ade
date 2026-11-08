import CryptoKit
import Foundation

/// A private, per-project registration is shared by this app's sessions in the same worktree.
actor CommandCodeConnection {
    private struct Installation {
        let executable: String
        let environment: [String: String]
        var runs: Set<UUID>
    }

    private let name: String
    private var installations: [String: Installation] = [:]

    init(directory: URL) {
        let identity = Data(directory.resolvingSymlinksInPath().path.utf8)
        let suffix = SHA256.hash(data: identity).prefix(6).map { String(format: "%02x", $0) }.joined()
        name = "mindmap-ade-\(suffix)"
    }

    func acquire(
        runID: UUID, directory: String, executable: String, bridge: String, environment: [String: String]
    ) throws {
        if installations[directory] != nil {
            installations[directory]?.runs.insert(runID)
            return
        }
        try command(
            [
                "add", "--scope", "local",
                "--env", "MINDMAP_MCP_SOCKET=${MINDMAP_MCP_SOCKET}",
                "--env", "MINDMAP_MCP_TOKEN=${MINDMAP_MCP_TOKEN}",
                name, "--", bridge, "--mindmap-mcp",
            ], directory: directory, executable: executable, environment: environment)
        installations[directory] = Installation(executable: executable, environment: environment, runs: [runID])
    }

    func release(runID: UUID, directory: String) {
        guard var installation = installations[directory], installation.runs.remove(runID) != nil else { return }
        if installation.runs.isEmpty {
            remove(installation, at: directory)
        } else {
            installations[directory] = installation
        }
    }

    func removeAll() {
        for (directory, installation) in installations { remove(installation, at: directory) }
    }

    private func remove(_ installation: Installation, at directory: String) {
        do {
            try command(
                ["remove", "--scope", "local", name], directory: directory,
                executable: installation.executable, environment: installation.environment)
            installations.removeValue(forKey: directory)
        } catch {
            // Keep the entry for a cleanup retry on exit. It contains only environment placeholders.
            var retry = installation
            retry.runs.removeAll()
            installations[directory] = retry
        }
    }

    private func command(
        _ arguments: [String], directory: String, executable: String, environment: [String: String]
    ) throws {
        let result = try LocalCommand.run(
            executable: executable, arguments: ["--no-auto-update", "mcp"] + arguments,
            directory: directory, environment: environment, timeout: .seconds(8))
        guard result.status == 0 else {
            let reason = result.diagnostic.trimmingCharacters(in: .whitespacesAndNewlines)
            throw WorkspaceIssue("Command Code could not configure map access. \(reason.prefix(800))")
        }
    }
}
