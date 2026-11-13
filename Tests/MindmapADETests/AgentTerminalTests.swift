import AppKit
import Darwin
import Foundation
import Testing
import os

@testable import MindmapADE

struct AgentTerminalTests {
    @Test func nativePTYReportsExecFailureBeforeStarting() async throws {
        let pty = AgentPTY()
        await #expect(throws: POSIXError(.ENOENT)) {
            try await pty.start(
                executable: "/nonexistent-mindmap-ade-pty-fixture", arguments: [], environment: [:],
                directory: "/", output: { _ in }, backlog: { 0 }, onExit: { _ in })
        }
    }

    @Test func concurrentPTYsHaveControllingTerminalsAndReapImmediateExits() async throws {
        let terminals = (0..<12).map { _ in AgentPTY() }
        defer { for terminal in terminals { terminal.stop() } }
        let output = OSAllocatedUnfairLock(initialState: [Int: Data]())
        let statuses = OSAllocatedUnfairLock(initialState: [Int: Int32]())
        try await withThrowingTaskGroup(of: Void.self) { group in
            for (index, terminal) in terminals.enumerated() {
                group.addTask {
                    terminal.resize(to: .init(rows: 31, columns: UInt16(90 + index)))
                    try await terminal.start(
                        executable: "/bin/sh", arguments: ["-c", "/bin/stty size </dev/tty; exit 23"],
                        environment: [:], directory: "/",
                        output: { bytes in output.withLock { $0[index, default: Data()].append(bytes) } },
                        backlog: { 0 },
                        onExit: { status in statuses.withLock { $0[index] = status.code ?? -1 } })
                }
            }
            try await group.waitForAll()
        }
        try await waitUntil { statuses.withLock { $0.count == terminals.count } }
        for index in terminals.indices {
            #expect(statuses.withLock { $0[index] } == 23)
            let bytes = output.withLock { $0[index] ?? Data() }
            #expect(String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .newlines) == "31 \(90 + index)")
        }
    }

    @Test func outputBackpressurePausesAndDrainsBeforeExit() async throws {
        let pty = AgentPTY()
        defer { pty.stop() }
        let received = OSAllocatedUnfairLock(initialState: 0)
        let pending = OSAllocatedUnfairLock(initialState: 0)
        let exit = OSAllocatedUnfairLock(initialState: Int32?.none)
        let length = 512 * 1024
        try await pty.start(
            executable: "/bin/sh", arguments: ["-c", "exec /bin/dd if=/dev/zero bs=32768 count=16 2>/dev/null"],
            environment: [:], directory: "/",
            output: { bytes in
                pending.withLock { $0 += bytes.count }
                received.withLock { $0 += bytes.count }
            },
            backlog: { pending.withLock { $0 } },
            onExit: { status in exit.withLock { $0 = status.code ?? -1 } })

        while exit.withLock({ $0 == nil }) {
            try await waitUntil {
                pending.withLock { $0 >= AgentPTY.outputHighWater } || exit.withLock { $0 != nil }
            }
            #expect(pending.withLock { $0 } <= AgentPTY.outputHighWater + 32 * 1024)
            pending.withLock { $0 = 0 }
            pty.resumeOutput()
            if received.withLock({ $0 }) >= length { break }
        }

        try await waitUntil { exit.withLock { $0 != nil } }
        #expect(received.withLock { $0 } == length)
        #expect(exit.withLock { $0 } == 0)
    }

    @Test func naturalExitCleansBackgroundJobsInSeparateProcessGroups() async throws {
        let pty = AgentPTY()
        defer { pty.stop() }
        let output = OSAllocatedUnfairLock(initialState: Data())
        let exit = OSAllocatedUnfairLock(initialState: Int32?.none)
        let script = #"""
            set -m
            /bin/sh -c 'trap "" HUP TERM; printf "job %s\n" "$$"; exec /bin/sleep 60' &
            IFS= read -r line
            exit 17
            """#
        try await pty.start(
            executable: "/bin/sh", arguments: ["-c", script], environment: [:], directory: "/",
            output: { bytes in output.withLock { $0.append(bytes) } }, backlog: { 0 },
            onExit: { result in exit.withLock { $0 = result.code ?? -1 } })
        var job: pid_t?
        try await waitUntil {
            let text = output.withLock { String(decoding: $0, as: UTF8.self) }
            let fields = text.split(whereSeparator: \.isWhitespace)
            guard fields.count >= 2, fields[0] == "job" else { return false }
            job = pid_t(fields[1])
            return job != nil
        }
        let background = try #require(job)
        let session = getsid(background)
        #expect(session > 0)
        #expect(getpgid(background) == background)
        #expect(getpgid(background) != session)
        defer {
            if session > 0, getsid(background) == session { _ = kill(background, SIGKILL) }
        }
        pty.send(Data([0x0a]))
        try await waitUntil { exit.withLock { $0 != nil } }
        #expect(exit.withLock { $0 } == 17)
        try await waitUntil { getsid(background) != session }
    }

    @Test func hiddenGhosttySurfaceKeepsScrollbackAndAcceptsInputAfterMovingWindows() async throws {
        _ = NSApplication.shared
        let terminal = AgentTerminal()
        defer { terminal.stop() }
        var exit: Int32?
        terminal.didExit = { status, _ in exit = status }

        let script = #"""
            /usr/bin/awk 'BEGIN { for (i=0; i<3000; ++i) printf "%05d 中文 output from the hidden terminal\n", i }'
            printf '\033[32mREADY\033[0m\n'
            IFS= read -r input
            printf 'FINAL %s\n' "$input"
            exit 23
            """#
        try await terminal.start(
            executable: "/bin/sh", arguments: ["-c", script],
            environment: AgentCLI.environment(executable: "/bin/sh"), directory: "/")

        try await waitUntil {
            guard let snapshot = await terminal.snapshotToSave() else { return false }
            let text = String(decoding: snapshot, as: UTF8.self)
            return text.contains("READY") && text.contains("00000 中文 output")
        }

        let frame = NSRect(x: 0, y: 0, width: 640, height: 320)
        let first = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        let second = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        let firstContent = try #require(first.contentView)
        let host = NSView()
        firstContent.addSubview(host)
        terminal.attach(to: host)
        host.frame = firstContent.bounds
        firstContent.layoutSubtreeIfNeeded()
        #expect(terminal.view.frame == host.bounds)
        terminal.park()
        terminal.attach(to: try #require(second.contentView))
        #expect(terminal.view.window === second)
        #expect(terminal.view.paste(text: "原样 'quoted'"))
        #expect(terminal.view.sendKey(.enter))

        try await waitUntil { exit != nil }
        #expect(exit == 23)
        let snapshot = try #require(await terminal.snapshotToSave())
        let text = String(decoding: snapshot, as: UTF8.self)
        #expect(snapshot.count <= AgentRunFiles.maximumSnapshotBytes)
        #expect(text.contains("00000 中文 output"))
        #expect(text.hasSuffix("FINAL 原样 'quoted'"))
        #expect(!text.contains("\u{1b}"))
        terminal.park()
    }

    private func waitUntil(_ condition: () async -> Bool) async throws {
        for _ in 0..<400 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw WorkspaceIssue("Timed out waiting for the terminal fixture.")
    }
}
