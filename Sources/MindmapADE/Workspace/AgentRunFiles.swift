import Foundation

actor AgentRunFiles {
    nonisolated static let maximumSnapshotBytes = 256 * 1024
    private let directory: URL

    init(workspace: URL) {
        directory = workspace.appendingPathComponent("agent-state", isDirectory: true)
    }

    func commandCodeIntegration(for runID: UUID) throws -> (mod: String, marker: String) {
        try prepareDirectory()
        let url = directory.appendingPathComponent("mindmap-session.mjs")
        let source = """
            import { writeFileSync } from "node:fs";
            export default function (cmd) {
                cmd.hooks({
                    onSessionStart({ sessionId }) {
                        const marker = process.env.MINDMAP_AGENT_SESSION_FILE;
                        if (marker && sessionId) writeFileSync(marker, sessionId, { mode: 0o600 });
                    }
                });
            }
            """
        if (try? String(contentsOf: url, encoding: .utf8)) != source {
            try source.write(to: url, atomically: true, encoding: .utf8)
        }
        return (url.path, markerURL(for: runID).path)
    }

    func commandCodeSession(for runID: UUID) -> UUID? {
        guard let bytes = try? read(markerURL(for: runID), limit: 37), bytes.count == 36 else { return nil }
        return UUID(uuidString: String(decoding: bytes, as: UTF8.self))
    }

    func snapshot(for runID: UUID) -> String? {
        guard let data = try? read(snapshotURL(for: runID), limit: Self.maximumSnapshotBytes), !data.isEmpty else {
            return nil
        }
        return String(decoding: data, as: UTF8.self)
    }

    func saveSnapshot(_ data: Data, for runID: UUID) throws {
        try prepareDirectory()
        try data.write(to: snapshotURL(for: runID), options: .atomic)
    }

    func removeUnreferencedFiles(keeping runIDs: Set<UUID>) {
        let files = FileManager.default
        guard
            let entries = try? files.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])
        else { return }
        for url in entries {
            guard url.pathExtension == "txt" || url.pathExtension == "session",
                let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent), !runIDs.contains(id),
                (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
            else { continue }
            try? files.removeItem(at: url)
        }
    }

    private func prepareDirectory() throws {
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }

    private func markerURL(for id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).session")
    }

    private func snapshotURL(for id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).txt")
    }

    private func read(_ url: URL, limit: Int) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        return try handle.read(upToCount: limit) ?? Data()
    }
}
