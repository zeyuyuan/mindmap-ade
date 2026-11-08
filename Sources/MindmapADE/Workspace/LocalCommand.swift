import Darwin
import Foundation

nonisolated enum LocalCommand {
    struct Result: Sendable {
        let output: String
        let standardError: String
        let status: Int32

        var diagnostic: String { standardError.isEmpty ? output : standardError }
    }

    private static let maximumOutputSize = 16 * 1024 * 1024

    static func run(
        executable: String, arguments: [String], directory: String, environment: [String: String],
        timeout: DispatchTimeInterval
    ) throws -> Result {
        // Regular files let us read the result after the command exits, even if a
        // background hook or CLI child still has its stdout and stderr open.
        let files = FileManager.default
        let capture = files.temporaryDirectory.appendingPathComponent("mindmap-command-\(UUID().uuidString)")
        try files.createDirectory(
            at: capture, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? files.removeItem(at: capture) }
        let outputURL = capture.appendingPathComponent("stdout")
        let errorURL = capture.appendingPathComponent("stderr")
        let output = try captureHandle(at: outputURL)
        let errors = try captureHandle(at: errorURL)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.currentDirectoryURL = URL(fileURLWithPath: directory, isDirectory: true)
        process.arguments = arguments
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = errors
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        try process.run()
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            if process.isRunning { process.terminate() }
            if exited.wait(timeout: .now() + .seconds(1)) == .timedOut, process.isRunning {
                _ = kill(process.processIdentifier, SIGKILL)
            }
            throw WorkspaceIssue("The local command timed out. Check the project or CLI and retry.")
        }
        return try Result(
            output: readCapture(at: outputURL), standardError: readCapture(at: errorURL),
            status: process.terminationStatus)
    }

    private static func captureHandle(at url: URL) throws -> FileHandle {
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw WorkspaceIssue("Could not capture output from the local command.") }
        return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }

    private static func readCapture(at url: URL) throws -> String {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let data = try file.read(upToCount: maximumOutputSize + 1) ?? Data()
        guard data.count <= maximumOutputSize else {
            throw WorkspaceIssue("The local command produced too much output.")
        }
        return String(decoding: data, as: UTF8.self)
    }
}
