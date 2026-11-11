import Darwin
import Foundation

/// Reserve a durable Codex thread before starting its interactive terminal.
/// A new thread is normally saved lazily. Naming it makes even an empty conversation resumable.
nonisolated enum CodexConversation {
    @concurrent
    static func create(
        executable: String, environment: [String: String], directory: String, name: String
    ) async throws -> UUID {
        try withServer(executable: executable, environment: environment, directory: directory) { server in
            let result = try server.request("thread/start", ["cwd": directory, "ephemeral": false])
            guard let thread = result["thread"] as? [String: Any], let rawID = thread["id"] as? String,
                let id = UUID(uuidString: rawID), let path = thread["path"] as? String
            else { throw WorkspaceIssue("Codex did not return a local conversation.") }
            if !FileManager.default.fileExists(atPath: path) {
                _ = try server.request("thread/name/set", ["threadId": rawID, "name": String(name.prefix(120))])
            }
            guard FileManager.default.isReadableFile(atPath: path) else {
                throw WorkspaceIssue("Codex did not save the new conversation.")
            }
            return id
        }
    }

    @concurrent
    static func verify(
        _ id: UUID, executable: String, environment: [String: String], directory: String
    ) async throws {
        try withServer(executable: executable, environment: environment, directory: directory) { server in
            let result = try server.request(
                "thread/read", ["threadId": id.uuidString.lowercased(), "includeTurns": false])
            guard let thread = result["thread"] as? [String: Any],
                (thread["id"] as? String).flatMap(UUID.init(uuidString:)) == id,
                let path = thread["path"] as? String, FileManager.default.isReadableFile(atPath: path)
            else { throw WorkspaceIssue("The original Codex conversation is no longer available.") }
        }
    }

    private static func withServer<T>(
        executable: String, environment: [String: String], directory: String, body: (Server) throws -> T
    ) throws -> T {
        var sockets = [Int32](repeating: -1, count: 2)
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets) == 0 else {
            throw WorkspaceIssue("Could not connect to the local Codex session service.")
        }
        let channel = FileHandle(fileDescriptor: sockets[0], closeOnDealloc: true)
        let child = FileHandle(fileDescriptor: sockets[1], closeOnDealloc: true)
        _ = fcntl(sockets[0], F_SETFD, FD_CLOEXEC)
        _ = fcntl(sockets[1], F_SETFD, FD_CLOEXEC)
        var enabled: Int32 = 1
        _ = setsockopt(sockets[0], SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["app-server"]
        process.currentDirectoryURL = URL(fileURLWithPath: directory, isDirectory: true)
        process.environment = environment
        process.standardInput = child
        process.standardOutput = child
        process.standardError = FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        try process.run()
        defer {
            _ = shutdown(channel.fileDescriptor, SHUT_RDWR)
            if exited.wait(timeout: .now() + .milliseconds(250)) == .timedOut {
                if process.isRunning { process.terminate() }
                if exited.wait(timeout: .now() + .milliseconds(750)) == .timedOut, process.isRunning {
                    _ = kill(process.processIdentifier, SIGKILL)
                }
            }
        }
        try child.close()

        let server = Server(channel: channel)
        _ = try server.request("initialize", ["clientInfo": ["name": "mindmap-ade", "version": "1"]])
        try server.send(["method": "initialized"])
        return try body(server)
    }

    private final class Server {
        private let channel: FileHandle
        private let deadline = ContinuousClock.now.advanced(by: .seconds(6))
        private var unread = Data()
        private var nextID = 0

        init(channel: FileHandle) { self.channel = channel }

        func send(_ message: [String: Any]) throws {
            var bytes = try JSONSerialization.data(withJSONObject: message, options: .withoutEscapingSlashes)
            bytes.append(10)
            try channel.write(contentsOf: bytes)
        }

        func request(_ method: String, _ params: [String: Any]) throws -> [String: Any] {
            nextID += 1
            try send(["id": nextID, "method": method, "params": params])
            var descriptor = pollfd(fd: channel.fileDescriptor, events: Int16(POLLIN), revents: 0)
            var bytes = [UInt8](repeating: 0, count: 8192)
            while ContinuousClock.now < deadline {
                try Task.checkCancellation()
                while let newline = unread.firstIndex(of: 10) {
                    let message = (try? JSONSerialization.jsonObject(with: unread[..<newline])) as? [String: Any]
                    unread.removeSubrange(...newline)
                    guard message?["id"] as? Int == nextID else { continue }
                    if let result = message?["result"] as? [String: Any] { return result }
                    let error = (message?["error"] as? [String: Any])?["message"] as? String
                    throw WorkspaceIssue(
                        error.map { String($0.prefix(240)) } ?? "Codex could not open this conversation.")
                }
                let ready = poll(&descriptor, 1, 100)
                if ready < 0, errno != EINTR { break }
                guard ready > 0 else { continue }
                let count = read(channel.fileDescriptor, &bytes, bytes.count)
                guard count > 0, unread.count + count <= 2 * 1024 * 1024 else { break }
                unread.append(contentsOf: bytes.prefix(count))
            }
            throw WorkspaceIssue("The local Codex session service did not respond.")
        }
    }
}
