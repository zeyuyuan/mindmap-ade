import AgentPTYSystem
import Darwin
import Foundation

/// One child and its master descriptor. All mutable state belongs to the I/O queue.
nonisolated final class AgentPTY: @unchecked Sendable {
    struct Grid: Equatable, Sendable {
        var rows: UInt16 = 24
        var columns: UInt16 = 80
    }

    struct Exit: Sendable {
        let code: Int32?
        var error: String? = nil
    }

    static let outputHighWater = 128 * 1024
    static let outputLowWater = 32 * 1024
    private static let ioBudget = 256 * 1024

    private final class Descriptor {
        let fd: Int32

        init(_ fd: Int32) { self.fd = fd }

        deinit { close(fd) }
    }

    private let queue = DispatchQueue(label: "mindmap.agent.pty", qos: .userInitiated)
    private var grid = Grid()
    private var master: Descriptor?
    private var pid: pid_t = 0
    private var reader: DispatchSourceRead?
    private var writer: DispatchSourceWrite?
    private var reaper: DispatchSourceProcess?
    private var readPaused = false
    private var readBuffer = [UInt8](repeating: 0, count: 32 * 1024)
    private var input = Data()
    private var inputOffset = 0
    private var stopRequested = false
    private var leaderExited = false
    private var result: Exit?
    private var output: (@Sendable (Data) -> Void)?
    private var backlog: (@Sendable () -> Int)?
    private var onExit: (@Sendable (Exit) -> Void)?

    deinit {
        if readPaused { reader?.resume() }
        reader?.cancel()
        writer?.cancel()
    }

    func start(
        executable: String, arguments: [String], environment: [String: String], directory: String,
        directoryIdentity: String? = nil,
        output: @escaping @Sendable (Data) -> Void, backlog: @escaping @Sendable () -> Int,
        onExit: @escaping @Sendable (Exit) -> Void
    ) async throws {
        let helper = try Self.launcher()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            queue.async {
                do {
                    guard self.pid == 0, self.result == nil else { throw POSIXError(.EBUSY) }
                    let handle = try Self.spawn(
                        helper: helper, executable: executable, arguments: arguments, environment: environment,
                        directory: directory, directoryIdentity: directoryIdentity, grid: self.grid)
                    self.install(handle, output: output, backlog: backlog, onExit: onExit)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func resize(to size: Grid) {
        guard size.rows > 0, size.columns > 0 else { return }
        queue.async { [self] in
            guard grid != size else { return }
            grid = size
            if let master { _ = agent_pty_resize(master.fd, size.rows, size.columns) }
        }
    }

    func send(_ bytes: Data) {
        guard !bytes.isEmpty else { return }
        queue.async { [self] in
            guard master != nil else { return }
            input.append(bytes)
            if writer == nil { writeInput() }
        }
    }

    func resumeOutput() {
        queue.async { [self] in
            guard readPaused, let reader, (backlog?() ?? 0) <= Self.outputLowWater else { return }
            readPaused = false
            reader.resume()
            drainOutput()
        }
    }

    func stop() {
        queue.async { [self] in
            guard pid > 0, !leaderExited, !stopRequested else { return }
            stopRequested = true
            _ = signalSessionJobs(SIGTERM)
            _ = kill(pid, SIGTERM)
            queue.asyncAfter(deadline: .now() + 1) { [weak self] in
                guard let self, self.pid > 0, !self.leaderExited else { return }
                _ = self.signalSessionJobs(SIGKILL)
                _ = kill(self.pid, SIGKILL)
            }
        }
    }

    private func install(
        _ handle: AgentPTYHandle, output: @escaping @Sendable (Data) -> Void,
        backlog: @escaping @Sendable () -> Int, onExit: @escaping @Sendable (Exit) -> Void
    ) {
        precondition(pid == 0 && master == nil)
        let descriptor = Descriptor(handle.master)
        master = descriptor
        pid = handle.pid
        self.output = output
        self.backlog = backlog
        self.onExit = onExit

        let reader = DispatchSource.makeReadSource(fileDescriptor: descriptor.fd, queue: queue)
        reader.setEventHandler { [weak self] in self?.drainOutput() }
        reader.setCancelHandler { withExtendedLifetime(descriptor) {} }
        self.reader = reader
        reader.activate()

        // Retain the process owner until waitpid, even if its view goes away.
        let reaper = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: queue)
        reaper.setEventHandler { [self] in reap() }
        self.reaper = reaper
        reaper.activate()
        reap(observedExit: false)
    }

    private func drainOutput() {
        guard !readPaused, let master else { return }
        var remaining = Self.ioBudget
        while remaining > 0 {
            let count = readBuffer.withUnsafeMutableBytes {
                Darwin.read(master.fd, $0.baseAddress, min(remaining, $0.count))
            }
            if count > 0 {
                remaining -= count
                output?(Data(readBuffer.prefix(count)))
                if (backlog?() ?? 0) >= Self.outputHighWater, let reader {
                    readPaused = true
                    reader.suspend()
                    return
                }
            } else if count < 0 && errno == EINTR {
                continue
            } else if count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                // A descendant can keep the slave open after the leader exits.
                if result != nil { closeIO() }
                return
            } else {
                closeIO()
                return
            }
        }
        if result != nil {
            // An exact-budget read can exhaust the available output without
            // another readiness event when a descendant keeps the slave open.
            queue.async { [weak self] in self?.drainOutput() }
        }
    }

    private func writeInput() {
        guard let master else { return }
        var remaining = Self.ioBudget
        while inputOffset < input.count && remaining > 0 {
            let count = input.withUnsafeBytes {
                Darwin.write(
                    master.fd, $0.baseAddress?.advanced(by: inputOffset), min(remaining, $0.count - inputOffset))
            }
            if count > 0 {
                inputOffset += count
                remaining -= count
            } else if count < 0 && errno == EINTR {
                continue
            } else if count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                break
            } else {
                inputOffset = input.count
                break
            }
        }

        if inputOffset == input.count {
            input.removeAll(keepingCapacity: false)
            inputOffset = 0
            writer?.cancel()
            writer = nil
        } else {
            if inputOffset >= Self.ioBudget {
                input = Data(input.dropFirst(inputOffset))
                inputOffset = 0
            }
            if writer == nil {
                let source = DispatchSource.makeWriteSource(fileDescriptor: master.fd, queue: queue)
                source.setEventHandler { [weak self] in self?.writeInput() }
                source.setCancelHandler { withExtendedLifetime(master) {} }
                writer = source
                source.activate()
            }
        }
    }

    private func reap(observedExit: Bool = true) {
        guard pid > 0, !leaderExited else { return }
        let exited = agent_pty_has_exited(pid)
        if exited == -EINTR || (exited == 0 && observedExit) {
            // NOTE_EXIT can arrive before the child is waitable.
            queue.asyncAfter(deadline: .now() + .milliseconds(10)) { [weak self] in self?.reap() }
            return
        }
        guard exited != 0 else { return }
        leaderExited = true
        if exited > 0 {
            reapAfterCleaningJobs()
        } else {
            finish(Exit(code: nil, error: String(cString: strerror(-exited))))
        }
    }

    private func reapAfterCleaningJobs() {
        // Keep the exited leader waitable so its PID cannot be reused while we signal its session.
        guard signalSessionJobs(SIGKILL) else {
            queue.asyncAfter(deadline: .now() + .milliseconds(20)) { [weak self] in self?.reapAfterCleaningJobs() }
            return
        }
        var status: Int32 = 0
        let reaped = agent_pty_reap(pid, &status)
        if reaped == -EINTR || reaped == 0 {
            queue.asyncAfter(deadline: .now() + .milliseconds(20)) { [weak self] in self?.reapAfterCleaningJobs() }
            return
        }
        finish(reaped > 0 ? Exit(code: status) : Exit(code: nil, error: String(cString: strerror(-reaped))))
    }

    private func finish(_ exit: Exit) {
        result = exit
        reaper?.cancel()
        reaper = nil
        if master != nil {
            drainOutput()
        } else {
            deliverExit()
        }
    }

    private func closeIO() {
        if readPaused { reader?.resume() }
        reader?.cancel()
        writer?.cancel()
        reader = nil
        writer = nil
        readPaused = false
        input = Data()
        inputOffset = 0
        master = nil
        deliverExit()
    }

    private func deliverExit() {
        guard let result, let onExit else { return }
        self.onExit = nil
        output = nil
        backlog = nil
        pid = 0
        onExit(result)
    }

    /// Signals live jobs in this PTY session and reports whether the scan found it empty.
    private func signalSessionJobs(_ signal: Int32) -> Bool {
        let type = UInt32(PROC_ALL_PIDS)
        let size = proc_listpids(type, 0, nil, 0)
        guard size > 0 else { return false }
        let stride = MemoryLayout<pid_t>.stride
        var processes = [pid_t](repeating: 0, count: Int(size) / stride + 32)
        let received = processes.withUnsafeMutableBytes {
            proc_listpids(type, 0, $0.baseAddress, Int32($0.count))
        }
        guard received > 0, Int(received) < processes.count * stride else { return false }
        var empty = true
        for process in processes.prefix(Int(received) / stride)
        where process > 0 && process != pid && getsid(process) == pid {
            var info = proc_bsdinfo()
            let length = Int32(MemoryLayout<proc_bsdinfo>.size)
            if proc_pidinfo(process, PROC_PIDTBSDINFO, 0, &info, length) == length, info.pbi_status == SZOMB {
                continue
            }
            empty = false
            if getsid(process) == pid { _ = kill(process, signal) }
        }
        return empty
    }

    private static func launcher() throws -> String {
        let app = Bundle.main
        let module = Bundle(for: AgentTerminal.self)
        let url: URL? =
            if app.bundleURL.pathExtension == "app" {
                app.bundleURL.appending(path: "Contents/Helpers/AgentPTYLaunch")
            } else if module.bundleURL.pathExtension == "xctest" {
                module.bundleURL.deletingLastPathComponent().appending(path: "AgentPTYLaunch")
            } else {
                app.executableURL?.deletingLastPathComponent().appending(path: "AgentPTYLaunch")
            }
        guard let url, FileManager.default.isExecutableFile(atPath: url.path) else {
            throw WorkspaceIssue("AgentPTYLaunch is missing from the application build.")
        }
        return url.path
    }

    private static func spawn(
        helper: String, executable: String, arguments: [String], environment: [String: String],
        directory: String, directoryIdentity: String?, grid: Grid
    ) throws -> AgentPTYHandle {
        let arguments = [helper, executable, executable] + arguments
        let environment = environment.map { "\($0.key)=\($0.value)" }
        guard !(arguments + environment + [directory]).contains(where: { $0.utf8.contains(0) }) else {
            throw POSIXError(.EINVAL)
        }
        let workingDirectory = open(directory, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard workingDirectory >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(workingDirectory) }
        if let directoryIdentity {
            var info = stat()
            guard fstat(workingDirectory, &info) == 0, GitWorkspace.directoryIdentity(info) == directoryIdentity else {
                throw WorkspaceIssue("The original worktree was replaced before the terminal started.")
            }
        }
        var argv = arguments.map { value in value.withCString { strdup($0) } }
        var envp = environment.map { value in value.withCString { strdup($0) } }
        defer {
            for value in argv { free(value) }
            for value in envp { free(value) }
        }
        guard !argv.contains(nil), !envp.contains(nil) else { throw POSIXError(.ENOMEM) }
        argv.append(nil)
        envp.append(nil)
        var handle = AgentPTYHandle()
        let error = agent_pty_spawn(workingDirectory, &argv, &envp, grid.rows, grid.columns, &handle)
        guard error == 0 else { throw POSIXError(POSIXErrorCode(rawValue: error) ?? .EIO) }
        return handle
    }
}
