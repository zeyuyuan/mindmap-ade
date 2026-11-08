import Darwin
import Foundation
import Testing

@testable import MindmapADE

@Test nonisolated func localCommandReturnsWhenABackgroundChildKeepsItsOutputOpen() throws {
    let files = FileManager.default
    let directory = files.temporaryDirectory.appendingPathComponent("MindmapCommandTest-\(UUID().uuidString)")
    try files.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? files.removeItem(at: directory) }
    let marker = directory.appendingPathComponent("child-pid")
    defer {
        if let value = try? String(contentsOf: marker, encoding: .utf8),
            let pid = Int32(value.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 0
        {
            _ = kill(pid, SIGTERM)
        }
    }
    let started = ContinuousClock.now
    let result = try LocalCommand.run(
        executable: "/bin/sh",
        arguments: [
            "-c",
            #"""
            /bin/sleep 10 &
            printf '%s\n' "$!" > child-pid
            printf '%s\n' 'checkout-path'
            printf '%s\n' 'warning from git' >&2
            """#,
        ],
        directory: directory.path, environment: ProcessInfo.processInfo.environment, timeout: .seconds(3))
    #expect(started.duration(to: .now) < .seconds(8))
    #expect(result.status == 0)
    #expect(result.output == "checkout-path\n")
    #expect(result.standardError == "warning from git\n")
}

@Test nonisolated func localCommandReportsATimeoutWhenTheProcessDoesNotExit() throws {
    do {
        _ = try LocalCommand.run(
            executable: "/bin/sleep", arguments: ["10"], directory: "/",
            environment: [:], timeout: .milliseconds(100))
        Issue.record("A command that exceeded its deadline returned normally.")
    } catch let issue as WorkspaceIssue {
        #expect(issue.message.contains("timed out"))
    }
}
