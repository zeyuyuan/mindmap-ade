import Darwin
import Foundation

nonisolated struct MCPEnvelope: Codable, Sendable {
    let token: String
    let message: Data
}

nonisolated enum MCPSocket {
    static let maximumMessageSize = 256 * 1024

    static func open() throws -> Int32 {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw WorkspaceIssue("Could not open the local map connection.") }
        configure(descriptor)
        return descriptor
    }

    static func configure(_ descriptor: Int32) {
        _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
        var enabled: Int32 = 1
        var timeout = timeval(tv_sec: 10, tv_usec: 0)
        _ = setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout.size(ofValue: enabled)))
        _ = setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
        _ = setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
    }

    static func withAddress(
        _ path: String, _ action: (UnsafePointer<sockaddr>, socklen_t) -> Int32
    ) throws -> Int32 {
        var address = sockaddr_un()
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path), !bytes.contains(0) else {
            throw WorkspaceIssue("The local map socket path is invalid.")
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: bytes)
        }
        return withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                action($0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
    }

    static func readMessage(from descriptor: Int32) -> Data? {
        var message = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while message.count < maximumMessageSize {
            let count = chunk.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { return count == 0 && !message.isEmpty ? message : nil }
            let received = chunk.prefix(count)
            if let newline = received.firstIndex(of: 10) {
                message.append(contentsOf: received[..<newline])
                return message.count <= maximumMessageSize ? message : nil
            }
            message.append(contentsOf: received)
        }
        return nil
    }

    static func writeMessage(_ payload: Data, to descriptor: Int32) {
        guard payload.count <= maximumMessageSize else { return }
        var message = payload
        message.append(10)
        message.withUnsafeBytes { bytes in
            var sent = 0
            while sent < bytes.count {
                let count = Darwin.write(descriptor, bytes.baseAddress?.advanced(by: sent), bytes.count - sent)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { break }
                sent += count
            }
        }
    }
}

final class MCPListener {
    let path: String
    private let source: any DispatchSourceRead

    init(handle: @escaping @MainActor @Sendable (Data) async -> Data?) throws {
        let directory = "/tmp/mindmap-mcp-\(UUID().uuidString.lowercased())"
        path = directory + "/bridge.sock"
        try FileManager.default.createDirectory(
            atPath: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let descriptor: Int32
        do {
            descriptor = try MCPSocket.open()
        } catch {
            _ = rmdir(directory)
            throw error
        }
        do {
            guard try MCPSocket.withAddress(path, { bind(descriptor, $0, $1) }) == 0,
                listen(descriptor, 8) == 0,
                fcntl(descriptor, F_SETFL, O_NONBLOCK) == 0
            else { throw WorkspaceIssue("Could not listen for local map requests.") }
        } catch {
            Darwin.close(descriptor)
            _ = unlink(path)
            _ = rmdir(directory)
            throw error
        }
        let socketPath = path
        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: .global(qos: .userInitiated))
        source.setCancelHandler { @Sendable in
            Darwin.close(descriptor)
            _ = unlink(socketPath)
            _ = rmdir(directory)
        }
        source.setEventHandler { @Sendable in
            let client = accept(descriptor, nil, nil)
            guard client >= 0 else { return }
            _ = fcntl(client, F_SETFL, 0)
            MCPSocket.configure(client)
            Task.detached {
                defer { Darwin.close(client) }
                guard let message = MCPSocket.readMessage(from: client) else { return }
                if let response = await handle(message) {
                    MCPSocket.writeMessage(response, to: client)
                }
            }
        }
        self.source = source
        source.resume()
    }

    isolated deinit { source.cancel() }
}

nonisolated enum MCPStdioBridge {
    static func run() {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["MINDMAP_MCP_SOCKET"], let token = environment["MINDMAP_MCP_TOKEN"],
            !path.isEmpty, !token.isEmpty
        else { return }
        while let line = readLine() {
            let message = Data(line.utf8)
            guard message.count < MCPSocket.maximumMessageSize / 2 else { continue }
            do {
                if let response = try forward(message, path: path, token: token) {
                    try FileHandle.standardOutput.write(contentsOf: response + Data([10]))
                } else if (try? JSONSerialization.jsonObject(with: message) as? [String: Any])?["id"] != nil {
                    throw WorkspaceIssue("The map request did not receive a response.")
                }
            } catch {
                if let request = (try? JSONSerialization.jsonObject(with: message)) as? [String: Any],
                    let id = request["id"]
                {
                    let reply: [String: Any] = [
                        "jsonrpc": "2.0", "id": id,
                        "error": ["code": -32000, "message": "The Mindmap ADE session connection is unavailable."],
                    ]
                    if let response = try? JSONSerialization.data(withJSONObject: reply) {
                        try? FileHandle.standardOutput.write(contentsOf: response + Data([10]))
                    }
                }
            }
        }
    }

    private static func forward(_ message: Data, path: String, token: String) throws -> Data? {
        let descriptor = try MCPSocket.open()
        defer { Darwin.close(descriptor) }
        guard try MCPSocket.withAddress(path, { connect(descriptor, $0, $1) }) == 0 else {
            throw WorkspaceIssue("The local map session is unavailable.")
        }
        MCPSocket.writeMessage(try JSONEncoder().encode(MCPEnvelope(token: token, message: message)), to: descriptor)
        return MCPSocket.readMessage(from: descriptor)
    }
}
