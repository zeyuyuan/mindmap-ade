import Foundation

public struct NodeAddress: Hashable, Codable, Sendable {
    public let boardID: UUID
    public let nodeID: UUID

    public init(boardID: UUID, nodeID: UUID) {
        self.boardID = boardID
        self.nodeID = nodeID
    }
}

// Retain the nested launcher so runs from older archives can still be decoded.
public struct AgentLauncher: Codable, Equatable, Sendable {
    public let executable: String
}

public struct AgentRun: Identifiable, Codable, Equatable, Sendable {
    public enum State: String, Codable, Sendable {
        case starting, running, stopping, stopped, exited, failed, interrupted

        public var isActive: Bool {
            switch self {
            case .starting, .running, .stopping: true
            case .stopped, .exited, .failed, .interrupted: false
            }
        }

        public var title: String {
            switch self {
            case .starting: "Starting"
            case .running: "Running"
            case .stopping: "Stopping"
            case .stopped: "Stopped"
            case .exited: "Exited"
            case .failed: "Failed"
            case .interrupted: "Interrupted"
            }
        }
    }

    public let id: UUID
    public let address: NodeAddress
    public let directory: String
    public let gitCommonDirectory: String
    public let launcher: AgentLauncher
    private let selectedCLI: AgentCLIKind?
    public let startedAt: Date
    public var finishedAt: Date?
    public var state: State
    public var exitCode: Int32?
    public var error: String?

    public var cli: AgentCLIKind { selectedCLI ?? .commandCode }

    public init(address: NodeAddress, worktree: WorktreeLocation, cli: AgentCLIKind, executable: String) {
        id = UUID()
        self.address = address
        directory = worktree.directory
        gitCommonDirectory = worktree.gitCommonDirectory
        launcher = AgentLauncher(executable: executable)
        selectedCLI = cli == .commandCode ? nil : cli
        startedAt = Date()
        state = .starting
    }
}
