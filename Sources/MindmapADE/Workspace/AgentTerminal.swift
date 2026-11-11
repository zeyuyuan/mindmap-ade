import AppKit
import Darwin
import Foundation
import Observation
import SwiftTerm
import os

@Observable
final class AgentTerminal: NSObject, LocalProcessTerminalViewDelegate {
    private struct StopTargets {
        let session: pid_t
        let groups: [pid_t]

        func signal(_ signal: Int32) {
            for group in groups where containsSessionMember(group) {
                _ = kill(-group, signal)
            }
        }

        private func containsSessionMember(_ group: pid_t) -> Bool {
            if getsid(group) == session, getpgid(group) == group { return true }
            // The group can outlive its leader. Verify a surviving member before
            // signalling it, since a PID may now refer to a different process.
            let type = UInt32(PROC_PGRP_ONLY)
            let size = proc_listpids(type, UInt32(group), nil, 0)
            guard size > 0 else { return false }
            let stride = MemoryLayout<pid_t>.stride
            var members = [pid_t](repeating: 0, count: Int(size) / stride + 8)
            let received = members.withUnsafeMutableBytes {
                proc_listpids(type, UInt32(group), $0.baseAddress, Int32($0.count))
            }
            return members.prefix(max(0, Int(received) / stride)).contains {
                $0 > 0 && getsid($0) == session && getpgid($0) == group
            }
        }
    }

    @ObservationIgnored let view: LocalProcessTerminalView
    var owner: UUID?
    @ObservationIgnored var didExit: ((Int32?, String?) -> Void)?
    @ObservationIgnored var recording: Task<Void, Never>?
    @ObservationIgnored private var savedSnapshot: Data?
    @ObservationIgnored private var pendingSnapshot: Data?
    @ObservationIgnored private let outputChanged = OSAllocatedUnfairLock(initialState: false)
    @ObservationIgnored private var stopTargets: StopTargets?
    @ObservationIgnored private var escalation: Task<Void, Never>?

    override init() {
        view = LocalProcessTerminalView(
            frame: CGRect(x: 0, y: 0, width: 720, height: 256),
            font: .monospacedSystemFont(ofSize: 12, weight: .regular),
            options: TerminalOptions())
        super.init()
        view.processDelegate = self
        view.setAccessibilityLabel("Agent terminal")
        view.setProcessOutputHandler { [outputChanged] in outputChanged.withLock { $0 = true } }
    }

    func start(executable: String, arguments: [String], environment: [String: String], directory: String) throws {
        let result = view.process.startProcessChecked(
            executable: executable, args: arguments,
            environment: environment.map { "\($0.key)=\($0.value)" }, currentDirectory: directory)
        if case .failure(let error) = result {
            throw WorkspaceIssue("The terminal could not start: \(error).")
        }
    }

    func stop() {
        let process = view.process!
        let pid = process.shellPid
        guard pid > 0 else { return }
        if getsid(pid) == pid {
            let foreground = process.childfd >= 0 ? tcgetpgrp(process.childfd) : -1
            stopTargets = StopTargets(
                session: pid, groups: foreground > 0 && foreground != pid ? [pid, foreground] : [pid])
            stopTargets?.signal(SIGTERM)
        }
        view.terminate()
        escalation?.cancel()
        escalation = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.forceStop()
        }
    }

    func snapshotToSave() -> Data? {
        let changed = outputChanged.withLock { value in
            let changed = value
            value = false
            return changed
        }
        if changed {
            let bytes = view.getBufferAsData()
            let text = String(decoding: bytes.suffix(AgentRunFiles.maximumSnapshotBytes), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                let snapshot = Data(text.utf8.suffix(AgentRunFiles.maximumSnapshotBytes))
                pendingSnapshot = snapshot == savedSnapshot ? nil : snapshot
            }
        }
        return pendingSnapshot
    }

    func didSaveSnapshot(_ snapshot: Data) {
        savedSnapshot = snapshot
        pendingSnapshot = nil
    }

    private func forceStop() {
        stopTargets?.signal(SIGKILL)
        stopTargets = nil
    }

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        escalation?.cancel()
        forceStop()
        didExit?(exitCode, nil)
    }

    func processFailedToStart(source: TerminalView, error: LocalProcessError) {
        didExit?(nil, "The terminal could not start: \(error).")
    }
}
