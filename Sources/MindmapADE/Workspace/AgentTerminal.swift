import AppKit
import Foundation
import GhosttyTerminal
import Observation
import os

@Observable
final class AgentTerminal {
    private struct Transport: Sendable {
        var pty: AgentPTY?
        var grid = AgentPTY.Grid()
    }

    private static let controller = TerminalController {
        $0.withFontSize(12)
        $0.withCustom("scrollback-limit", "4194304")
    }

    // A surface needs an AppKit window to start and to keep draining Ghostty's
    // mailbox. Hidden sessions stay attached here with their rendering paused.
    private static let parkingWindow: NSWindow = {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 256),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.isExcludedFromWindowsMenu = true
        window.isRestorable = false
        return window
    }()

    var owner: UUID?
    private(set) var isShell = false
    @ObservationIgnored let view: AgentTerminalView
    @ObservationIgnored var didExit: ((Int32?, String?) -> Void)? {
        didSet { deliverExit() }
    }
    @ObservationIgnored var recording: Task<Void, Never>?
    @ObservationIgnored private let transport: OSAllocatedUnfairLock<Transport>
    @ObservationIgnored private let session: InMemoryTerminalSession
    @ObservationIgnored private var savedSnapshot: Data?
    @ObservationIgnored private var pendingSnapshot: Data?
    @ObservationIgnored private var pendingExit: AgentPTY.Exit?
    @ObservationIgnored private let outputChanged = OSAllocatedUnfairLock(initialState: false)

    init() {
        let transport = OSAllocatedUnfairLock(initialState: Transport())
        let session = InMemoryTerminalSession(
            write: { bytes in transport.withLock { $0.pty?.send(bytes) } },
            resize: { size in
                guard size.rows > 0, size.columns > 0 else { return }
                transport.withLock {
                    $0.grid = .init(rows: size.rows, columns: size.columns)
                    $0.pty?.resize(to: $0.grid)
                }
            },
            suppressesPixelOnlyResizes: true)
        self.transport = transport
        self.session = session
        view = AgentTerminalView(frame: NSRect(x: 0, y: 0, width: 720, height: 256))
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.textArea)
        view.setAccessibilityLabel("Agent terminal")
        view.controller = Self.controller
        view.configuration = TerminalSurfaceOptions(backend: .inMemory(session))
        session.setOutputBacklogHandler(highWater: AgentPTY.outputHighWater, lowWater: AgentPTY.outputLowWater) {
            backlogged in
            if !backlogged { transport.withLock { $0.pty?.resumeOutput() } }
        }
        park()
    }

    isolated deinit {
        view.removeFromSuperview()
        stop()
    }

    func attach(to container: NSView) {
        guard view.superview !== container else { return }
        view.removeFromSuperview()
        view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            view.topAnchor.constraint(equalTo: container.topAnchor),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        view.setSurfaceVisible(true)
    }

    func park() {
        view.setSurfaceVisible(false)
        guard view.superview !== Self.parkingWindow.contentView else { return }
        view.removeFromSuperview()
        view.translatesAutoresizingMaskIntoConstraints = true
        view.autoresizingMask = []
        Self.parkingWindow.contentView?.addSubview(view)
    }

    func start(executable: String, arguments: [String], environment: [String: String], directory: String) async throws {
        let pty = AgentPTY()
        transport.withLock {
            precondition($0.pty == nil)
            pty.resize(to: $0.grid)
            $0.pty = pty
        }
        do {
            try await pty.start(
                executable: executable, arguments: arguments, environment: environment, directory: directory,
                output: { [weak session, outputChanged] data in
                    session?.receive(data)
                    outputChanged.withLock { $0 = true }
                },
                backlog: { [weak session] in session?.pendingOutputByteCount ?? 0 },
                onExit: { [weak self] status in
                    Task { @MainActor in
                        guard let self else { return }
                        self.transport.withLock { $0.pty = nil }
                        self.pendingExit = status
                        self.deliverExit()
                    }
                })
        } catch {
            transport.withLock { $0.pty = nil }
            throw WorkspaceIssue("The terminal could not start: \(error.localizedDescription)")
        }
    }

    func startShell(executable: String, directory: String, afterAgent: Bool) async throws {
        if afterAgent {
            // Enter then leave the alternate screen so mode 1049 saves the current cursor
            // when the agent already returned to the main screen.
            session.receive(
                "\u{18}\u{1b}[?1049h\u{1b}[?1049l\u{1b}[!p"
                    + "\u{1b}[?1000;1002;1003;1004;1006;2004;2026l\u{1b}[=0u\r\n")
        }
        var environment = AgentCLI.environment(executable: executable)
        environment["SHELL"] = executable
        isShell = true
        do {
            try await start(executable: executable, arguments: ["-i"], environment: environment, directory: directory)
        } catch {
            isShell = false
            throw error
        }
    }

    private func deliverExit() {
        guard let pendingExit, let didExit else { return }
        self.pendingExit = nil
        self.didExit = nil
        didExit(pendingExit.code, pendingExit.error)
    }

    func stop() { transport.withLock { $0.pty?.stop() } }

    func snapshotToSave() async -> Data? {
        let changed = outputChanged.withLock { value in
            let changed = value
            value = false
            return changed
        }
        if changed {
            let snapshot = await Task.detached(priority: .utility) { [session] in
                guard session.waitForPendingOutput() else { return nil as Data? }
                return session.readHistoryTail(maximumBytes: AgentRunFiles.maximumSnapshotBytes)
            }.value
            if let snapshot {
                let text = String(decoding: snapshot, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    let trimmed = Data(text.utf8)
                    pendingSnapshot = trimmed == savedSnapshot ? nil : trimmed
                }
            } else {
                outputChanged.withLock { $0 = true }
            }
        }
        return pendingSnapshot
    }

    func didSaveSnapshot(_ snapshot: Data) {
        savedSnapshot = snapshot
        pendingSnapshot = nil
    }
}
