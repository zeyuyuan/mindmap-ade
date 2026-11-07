import Foundation

public struct WorkspaceArchive: Codable, Sendable {
    public var schemaVersion: Int
    public var boards: [MindMapBoard]
    public var cameras: [UUID: MapCamera]
    public var selectedBoardID: UUID?

    public init(boards: [MindMapBoard], cameras: [UUID: MapCamera] = [:], selectedBoardID: UUID? = nil) {
        schemaVersion = 1
        self.boards = boards
        self.cameras = cameras
        self.selectedBoardID = selectedBoardID
    }

    public func validated() throws -> Self {
        guard schemaVersion == 1, Set(boards.map(\.id)).count == boards.count else {
            throw BoardValidationError.invalidStructure
        }
        for board in boards { _ = try board.validated() }
        guard
            cameras.values.allSatisfy({
                $0.scale.isFinite && (MapCamera.minimumScale...MapCamera.maximumScale).contains($0.scale)
                    && $0.translation.x.isFinite && $0.translation.y.isFinite
            })
        else { throw BoardValidationError.invalidStructure }
        return self
    }
}
