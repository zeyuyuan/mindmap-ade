import Foundation
import MindMapCore

nonisolated enum AgentCLI {
    struct Executable: Sendable {
        let path: String
        var supportsNoDaemon = false
    }

    static func unavailable(_ cli: AgentCLIKind) -> String {
        "A working \(cli.title) CLI was not found on this Mac."
    }

    @concurrent
    static func detected(_ cli: AgentCLIKind) async -> Executable? {
        let names = cli == .commandCode ? ["commandcode", "command-code"] : ["codex"]
        var candidates = searchPaths().flatMap { directory in names.map { directory.appendingPathComponent($0) } }
        if cli == .codex { candidates += bundledCodexPaths() }
        var visited = Set<String>()
        for file in candidates {
            guard !Task.isCancelled else { return nil }
            let path = file.deletingLastPathComponent().resolvingSymlinksInPath()
                .appendingPathComponent(file.lastPathComponent).path
            guard visited.insert(path).inserted, isExecutableFile(path) else { continue }
            if cli == .commandCode { return Executable(path: path) }

            // An executable npm shim can survive after its platform binary is removed.
            guard
                let result = try? LocalCommand.run(
                    executable: path, arguments: ["--help"], directory: "/",
                    environment: environment(executable: path), timeout: .seconds(3)),
                result.status == 0, result.output.contains("Codex CLI")
            else { continue }
            return Executable(path: path, supportsNoDaemon: result.output.contains("--no-daemon"))
        }
        return nil
    }

    static func isExecutableFile(_ path: String) -> Bool {
        var directory: ObjCBool = false
        let files = FileManager.default
        return path.hasPrefix("/") && !path.contains("\0")
            && files.fileExists(atPath: path, isDirectory: &directory) && !directory.boolValue
            && files.isExecutableFile(atPath: path)
    }

    static func environment(executable: String) -> [String: String] {
        var values = ProcessInfo.processInfo.environment
        let bin = URL(fileURLWithPath: executable).deletingLastPathComponent()
        var used = Set<String>()
        values["PATH"] = ([bin] + searchPaths()).map(\.path).filter { used.insert($0).inserted }.joined(separator: ":")
        values["TERM"] = "xterm-256color"
        values["COLORTERM"] = "truecolor"
        values["LANG"] = values["LANG"] ?? "en_US.UTF-8"
        values.removeValue(forKey: "MINDMAP_MCP_SOCKET")
        values.removeValue(forKey: "MINDMAP_MCP_TOKEN")
        return values
    }

    static func arguments(for topic: AgentTopic, executable: Executable, context: String, mcpBridge: String) throws
        -> [String]
    {
        var arguments: [String]
        switch topic.cli {
        case .commandCode:
            arguments = ["--no-auto-update"]
        case .codex:
            let encoder = JSONEncoder()
            encoder.outputFormatting = .withoutEscapingSlashes
            let command = String(decoding: try encoder.encode(mcpBridge), as: UTF8.self)
            let transport = #"args=["--mindmap-mcp"],env_vars=["MINDMAP_MCP_SOCKET","MINDMAP_MCP_TOKEN"]"#
            arguments = ["-c", "mcp_servers.mindmap_ade={command=\(command),\(transport)}"]
            // The map grant is in this process's environment, not the shared daemon's.
            if executable.supportsNoDaemon { arguments.append("--no-daemon") }
        }
        if !topic.task.isEmpty { arguments += ["--", context + topic.task] }
        guard arguments.allSatisfy({ !$0.contains("\0") }), arguments.reduce(0, { $0 + $1.utf8.count }) < 96_000
        else { throw WorkspaceIssue("The CLI arguments contain an invalid character or are too long.") }
        return arguments
    }

    private static func bundledCodexPaths() -> [URL] {
        let applications = [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications"),
        ]
        let paths = [
            "ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
            "Codex.app/Contents/Resources/codex",
        ]
        return applications.flatMap { directory in paths.map { directory.appendingPathComponent($0) } }
    }

    private static func searchPaths() -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let inherited = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":").filter { $0.hasPrefix("/") }.map { URL(fileURLWithPath: String($0)) }
        let fnm = home.appendingPathComponent(".local/share/fnm/node-versions")
        let versions = (try? FileManager.default.contentsOfDirectory(at: fnm, includingPropertiesForKeys: nil)) ?? []
        let fnmBins = versions.sorted {
            $0.lastPathComponent.compare($1.lastPathComponent, options: .numeric) == .orderedDescending
        }.map { $0.appendingPathComponent("installation/bin") }
        return inherited + [
            home.appendingPathComponent(".local/bin"),
            home.appendingPathComponent(".volta/bin"),
            URL(fileURLWithPath: "/opt/homebrew/bin"),
            URL(fileURLWithPath: "/usr/local/bin"),
            URL(fileURLWithPath: "/usr/bin"),
            URL(fileURLWithPath: "/bin"),
        ] + fnmBins
    }
}
