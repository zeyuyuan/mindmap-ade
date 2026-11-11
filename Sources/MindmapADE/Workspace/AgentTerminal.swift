import AppKit
import Foundation
import GhosttyTerminal
import Observation
import os

@Observable
final class AgentTerminal {
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
    @ObservationIgnored let view: AgentTerminalView
    @ObservationIgnored var didExit: ((Int32?, String?) -> Void)? {
        didSet { deliverExit() }
    }
    @ObservationIgnored var recording: Task<Void, Never>?
    @ObservationIgnored private let pty: AgentPTY
    @ObservationIgnored private let session: InMemoryTerminalSession
    @ObservationIgnored private var savedSnapshot: Data?
    @ObservationIgnored private var pendingSnapshot: Data?
    @ObservationIgnored private var pendingExit: AgentPTY.Exit?
    @ObservationIgnored private let outputChanged = OSAllocatedUnfairLock(initialState: false)

    init() {
        let pty = AgentPTY()
        let session = InMemoryTerminalSession(
            write: { pty.send($0) },
            resize: { pty.resize(to: .init(rows: $0.rows, columns: $0.columns)) },
            suppressesPixelOnlyResizes: true)
        self.pty = pty
        self.session = session
        view = AgentTerminalView(frame: NSRect(x: 0, y: 0, width: 720, height: 256))
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.textArea)
        view.setAccessibilityLabel("Agent terminal")
        view.controller = Self.controller
        view.configuration = TerminalSurfaceOptions(backend: .inMemory(session))
        session.setOutputBacklogHandler(highWater: AgentPTY.outputHighWater, lowWater: AgentPTY.outputLowWater) {
            [weak pty] backlogged in
            if !backlogged { pty?.resumeOutput() }
        }
        park()
    }

    isolated deinit {
        view.removeFromSuperview()
        pty.stop()
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
                        self?.pendingExit = status
                        self?.deliverExit()
                    }
                })
        } catch {
            throw WorkspaceIssue("The terminal could not start: \(error.localizedDescription)")
        }
    }

    private func deliverExit() {
        guard let pendingExit, let didExit else { return }
        self.pendingExit = nil
        didExit(pendingExit.code, pendingExit.error)
    }

    func stop() { pty.stop() }

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
