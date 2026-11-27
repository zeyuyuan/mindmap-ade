import CoreServices
import Foundation
import MindMapCore
import os

nonisolated enum GitFileSection: String, CaseIterable, Hashable, Sendable {
    case staged
    case unstaged
    case untracked

    var title: String {
        switch self {
        case .staged: "Staged"
        case .unstaged: "Changes"
        case .untracked: "Untracked"
        }
    }

    var sortOrder: Int {
        switch self {
        case .staged: 0
        case .unstaged: 1
        case .untracked: 2
        }
    }
}

nonisolated enum GitFileStatus: String, Hashable, Sendable {
    case modified = "M"
    case added = "A"
    case deleted = "D"
    case renamed = "R"
    case copied = "C"
    case typeChanged = "T"
    case unmerged = "U"
    case untracked = "?"

    init(porcelainCode character: Character) {
        switch character {
        case "M": self = .modified
        case "A": self = .added
        case "D": self = .deleted
        case "R": self = .renamed
        case "C": self = .copied
        case "T": self = .typeChanged
        case "U": self = .unmerged
        case "?": self = .untracked
        default: self = .modified
        }
    }

    var accessibilityName: String {
        switch self {
        case .modified: "Modified"
        case .added: "Added"
        case .deleted: "Deleted"
        case .renamed: "Renamed"
        case .copied: "Copied"
        case .typeChanged: "Type changed"
        case .unmerged: "Conflicted"
        case .untracked: "Untracked"
        }
    }
}

nonisolated struct GitChangedFile: Identifiable, Hashable, Sendable {
    let section: GitFileSection
    let status: GitFileStatus
    let path: String
    let originalPath: String?
    let additions: Int?
    let deletions: Int?
    let isBinary: Bool

    var id: String { "\(section.rawValue):\(path)" }

    var fileName: String {
        URL(fileURLWithPath: path).lastPathComponent
    }

    var directoryPath: String? {
        let directory = (path as NSString).deletingLastPathComponent
        return directory == "." || directory == "/" || directory.isEmpty ? nil : directory
    }
}

nonisolated struct GitCommitFile: Identifiable, Hashable, Sendable {
    let status: GitFileStatus
    let path: String
    let originalPath: String?
    let additions: Int?
    let deletions: Int?
    let isBinary: Bool

    var id: String { path }

    var fileName: String {
        URL(fileURLWithPath: path).lastPathComponent
    }

    var directoryPath: String? {
        let directory = (path as NSString).deletingLastPathComponent
        return directory == "." || directory == "/" || directory.isEmpty ? nil : directory
    }
}

nonisolated struct GitCommitSummary: Identifiable, Hashable, Sendable {
    let hash: String
    let shortHash: String
    let subject: String
    let author: String
    let date: Date?
    let fileCount: Int
    let additions: Int
    let deletions: Int

    var id: String { hash }
}

nonisolated struct GitChangesSnapshot: Equatable, Sendable {
    let directory: String
    let branchLabel: String
    let headCommit: String?
    let baseCommit: String?
    let ahead: Int
    let behind: Int
    let files: [GitChangedFile]
    let commits: [GitCommitSummary]
    let totalAdditions: Int
    let totalDeletions: Int

    var uniqueFileCount: Int {
        Set(files.map(\.path)).count
    }

    var hasChanges: Bool {
        !files.isEmpty || !commits.isEmpty
    }

    var cardDetail: String {
        let count = uniqueFileCount
        if count > 0 {
            let fileLabel = count == 1 ? "1 file" : "\(count) files"
            var stats: [String] = []
            if totalAdditions > 0 { stats.append("+\(totalAdditions)") }
            if totalDeletions > 0 { stats.append("-\(totalDeletions)") }
            if stats.isEmpty {
                return commits.isEmpty ? fileLabel : "\(fileLabel) · \(commitCountLabel)"
            }
            return "\(fileLabel) · \(stats.joined(separator: " "))"
        }
        if !commits.isEmpty {
            return "Clean · \(commitCountLabel)"
        }
        return "Clean"
    }

    private var commitCountLabel: String {
        commits.count == 1 ? "1 commit" : "\(commits.count) commits"
    }
}

nonisolated struct GitDiffDocument: Equatable, Sendable {
    static let maxRenderedLines = 2_500
    static let maxUntrackedBytes = 256 * 1024

    enum LineKind: Equatable, Sendable {
        case meta
        case hunk
        case context
        case addition
        case deletion
    }

    struct Line: Identifiable, Equatable, Sendable {
        let id: Int
        let kind: LineKind
        let oldLineNumber: Int?
        let newLineNumber: Int?
        let text: String
    }

    let rawText: String
    let lines: [Line]
    let isBinary: Bool
    let isTruncated: Bool

    var isEmpty: Bool { lines.isEmpty && !isBinary }

    static let empty = GitDiffDocument(rawText: "", lines: [], isBinary: false, isTruncated: false)
    static let binary = GitDiffDocument(rawText: "", lines: [], isBinary: true, isTruncated: false)

    static func parse(_ raw: String, maxLines: Int = maxRenderedLines) -> GitDiffDocument {
        guard !raw.isEmpty else { return .empty }
        var lines: [Line] = []
        lines.reserveCapacity(min(256, maxLines))
        var oldLine: Int?
        var newLine: Int?
        var isBinary = false
        var isTruncated = false
        var inHunk = false
        var index = 0

        for substring in raw.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(substring)
            if line.hasPrefix("Binary files ") && line.hasSuffix(" differ") || line == "GIT binary patch" {
                isBinary = true
                break
            }
            if line.hasPrefix("diff --git ") || line.hasPrefix("index ") || line.hasPrefix("--- ")
                || line.hasPrefix("+++ ")
            {
                inHunk = false
                continue
            }
            if lines.count >= maxLines {
                isTruncated = true
                break
            }
            if line.hasPrefix("@@ ") {
                inHunk = true
                let starts = parseHunkHeader(line)
                oldLine = starts.old
                newLine = starts.new
                lines.append(Line(id: index, kind: .hunk, oldLineNumber: nil, newLineNumber: nil, text: line))
                index += 1
            } else if inHunk {
                if line.hasPrefix("+") {
                    let current = newLine
                    if let value = newLine { newLine = value + 1 }
                    lines.append(
                        Line(
                            id: index, kind: .addition, oldLineNumber: nil, newLineNumber: current,
                            text: String(line.dropFirst())))
                    index += 1
                } else if line.hasPrefix("-") {
                    let current = oldLine
                    if let value = oldLine { oldLine = value + 1 }
                    lines.append(
                        Line(
                            id: index, kind: .deletion, oldLineNumber: current, newLineNumber: nil,
                            text: String(line.dropFirst())))
                    index += 1
                } else if line.hasPrefix(" ") {
                    let oldCurrent = oldLine
                    let newCurrent = newLine
                    if let value = oldLine { oldLine = value + 1 }
                    if let value = newLine { newLine = value + 1 }
                    lines.append(
                        Line(
                            id: index, kind: .context, oldLineNumber: oldCurrent, newLineNumber: newCurrent,
                            text: String(line.dropFirst())))
                    index += 1
                } else if line.hasPrefix("\\ ") {
                    lines.append(Line(id: index, kind: .meta, oldLineNumber: nil, newLineNumber: nil, text: line))
                    index += 1
                }
            } else if !line.isEmpty {
                lines.append(Line(id: index, kind: .meta, oldLineNumber: nil, newLineNumber: nil, text: line))
                index += 1
            }
        }
        if isBinary { return .binary }
        return GitDiffDocument(rawText: raw, lines: lines, isBinary: false, isTruncated: isTruncated)
    }

    static func parseUntrackedFile(at url: URL, maxBytes: Int = maxUntrackedBytes, maxLines: Int = maxRenderedLines)
        -> GitDiffDocument
    {
        let files = FileManager.default
        guard let attributes = try? files.attributesOfItem(atPath: url.path) else { return .empty }
        let fileType = attributes[.type] as? FileAttributeType
        if fileType == .typeSymbolicLink {
            if let destination = try? files.destinationOfSymbolicLink(atPath: url.path) {
                let line = Line(
                    id: 0, kind: .addition, oldLineNumber: nil, newLineNumber: 1, text: destination)
                return GitDiffDocument(rawText: destination, lines: [line], isBinary: false, isTruncated: false)
            }
            return .empty
        }
        guard fileType == .typeRegular, let handle = try? FileHandle(forReadingFrom: url) else { return .empty }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: maxBytes + 1)) ?? Data()
        let byteTruncated = data.count > maxBytes
        let bounded = byteTruncated ? data.prefix(maxBytes) : data
        if bounded.contains(0) { return .binary }
        let text = String(decoding: bounded, as: UTF8.self)
        guard !text.isEmpty else { return .empty }
        var rawLines = text.split(separator: "\n", omittingEmptySubsequences: false)
        if !byteTruncated, text.last == "\n", rawLines.last == "" {
            rawLines.removeLast()
        }
        let lineTruncated = rawLines.count > maxLines
        let slice = lineTruncated ? rawLines.prefix(maxLines) : rawLines[...]
        let lines = slice.enumerated().map { offset, content in
            Line(id: offset, kind: .addition, oldLineNumber: nil, newLineNumber: offset + 1, text: String(content))
        }
        return GitDiffDocument(
            rawText: text, lines: lines, isBinary: false, isTruncated: byteTruncated || lineTruncated)
    }

    private static func parseHunkHeader(_ line: String) -> (old: Int?, new: Int?) {
        // Format: @@ -oldStart[,oldCount] +newStart[,newCount] @@ ...
        let parts = line.split(separator: " ")
        guard parts.count >= 3 else { return (nil, nil) }
        func startNumber(_ token: Substring, prefix: Character) -> Int? {
            guard token.first == prefix else { return nil }
            let body = token.dropFirst()
            let number = body.split(separator: ",", maxSplits: 1).first ?? body
            return Int(number)
        }
        return (startNumber(parts[1], prefix: "-"), startNumber(parts[2], prefix: "+"))
    }
}

private nonisolated struct NumstatEntry: Sendable {
    let additions: Int?
    let deletions: Int?
    let isBinary: Bool
}

extension GitWorkspace {
    func gitDirectory(in directory: String) throws -> String {
        let canonicalDirectory = try availableDirectory(directory)
        return try git(["rev-parse", "--path-format=absolute", "--git-dir"], in: canonicalDirectory)
    }

    func changesSnapshot(in directory: String, baseCommit: String?) throws -> GitChangesSnapshot {
        let canonicalDirectory = try availableDirectory(directory)
        let statusOutput = try git(
            ["status", "--porcelain=v2", "-z", "--branch", "--untracked-files=all"],
            in: canonicalDirectory, trimTrailingNewline: false)
        let parsed = Self.parsePorcelainStatus(statusOutput)

        let unstagedOutput =
            (try? git(["diff", "--numstat", "-z"], in: canonicalDirectory, trimTrailingNewline: false)) ?? ""
        let stagedOutput =
            (try? git(["diff", "--cached", "--numstat", "-z"], in: canonicalDirectory, trimTrailingNewline: false))
            ?? ""
        let unstagedStats = Self.parseNumstat(unstagedOutput)
        let stagedStats = Self.parseNumstat(stagedOutput)

        var files: [GitChangedFile] = []
        files.reserveCapacity(parsed.entries.count)
        var totalAdditions = 0
        var totalDeletions = 0

        for entry in parsed.entries {
            let stats: NumstatEntry?
            switch entry.section {
            case .staged:
                stats = stagedStats[entry.path]
            case .unstaged:
                stats = unstagedStats[entry.path]
            case .untracked:
                let fileURL = URL(fileURLWithPath: canonicalDirectory).appendingPathComponent(entry.path)
                stats = Self.measureUntrackedFile(at: fileURL)
            }
            let additions = stats?.additions
            let deletions = stats?.deletions
            totalAdditions += additions ?? 0
            totalDeletions += deletions ?? 0
            files.append(
                GitChangedFile(
                    section: entry.section, status: entry.status, path: entry.path,
                    originalPath: entry.originalPath, additions: additions, deletions: deletions,
                    isBinary: stats?.isBinary ?? false))
        }

        files.sort { lhs, rhs in
            if lhs.section.sortOrder != rhs.section.sortOrder {
                return lhs.section.sortOrder < rhs.section.sortOrder
            }
            return lhs.path.localizedStandardCompare(rhs.path) == .orderedAscending
        }

        let resolvedBase = baseCommit?.trimmingCharacters(in: .whitespacesAndNewlines)
        let commits: [GitCommitSummary]
        if let base = resolvedBase, !base.isEmpty, let head = parsed.headCommit, base != head,
            (try? git(
                ["rev-parse", "--verify", "--quiet", "--end-of-options", "\(base)^{commit}"], in: canonicalDirectory))
                != nil
        {
            let logOutput =
                (try? git(
                    ["log", "-n", "50", "--format=%x1e%H%x1f%h%x1f%s%x1f%an%x1f%at", "--shortstat", "\(base)..HEAD"],
                    in: canonicalDirectory)) ?? ""
            commits = Self.parseCommitLog(logOutput)
        } else {
            commits = []
        }

        return GitChangesSnapshot(
            directory: canonicalDirectory, branchLabel: parsed.branchLabel, headCommit: parsed.headCommit,
            baseCommit: resolvedBase, ahead: parsed.ahead, behind: parsed.behind, files: files, commits: commits,
            totalAdditions: totalAdditions, totalDeletions: totalDeletions)
    }

    func workingTreeDiff(for file: GitChangedFile, in directory: String) throws -> GitDiffDocument {
        let canonicalDirectory = try availableDirectory(directory)
        switch file.section {
        case .untracked:
            let fileURL = URL(fileURLWithPath: canonicalDirectory).appendingPathComponent(file.path)
            return GitDiffDocument.parseUntrackedFile(at: fileURL)
        case .staged:
            let paths = [file.originalPath, file.path].compactMap { $0 }
            let output = try git(
                ["diff", "--cached", "--no-ext-diff", "-M", "--"] + paths,
                in: canonicalDirectory, trimTrailingNewline: false)
            return GitDiffDocument.parse(output)
        case .unstaged:
            let paths = [file.originalPath, file.path].compactMap { $0 }
            let output = try git(
                ["diff", "--no-ext-diff", "-M", "--"] + paths,
                in: canonicalDirectory, trimTrailingNewline: false)
            return GitDiffDocument.parse(output)
        }
    }

    func commitFiles(for commit: String, in directory: String) throws -> [GitCommitFile] {
        let canonicalDirectory = try availableDirectory(directory)
        let verified = try git(
            ["rev-parse", "--verify", "--end-of-options", "\(commit)^{commit}"], in: canonicalDirectory)
        let statusOutput = try git(
            ["diff-tree", "--root", "--no-commit-id", "--name-status", "-r", "-M", "-z", verified],
            in: canonicalDirectory, trimTrailingNewline: false)
        let numstatOutput = try git(
            ["diff-tree", "--root", "--no-commit-id", "--numstat", "-r", "-M", "-z", verified],
            in: canonicalDirectory, trimTrailingNewline: false)
        let stats = Self.parseNumstat(numstatOutput)
        let entries = Self.parseNameStatus(statusOutput)
        return entries.map { entry in
            let stat = stats[entry.path]
            return GitCommitFile(
                status: entry.status, path: entry.path, originalPath: entry.originalPath,
                additions: stat?.additions, deletions: stat?.deletions, isBinary: stat?.isBinary ?? false)
        }
        .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    func commitFileDiff(commit: String, file: GitCommitFile, in directory: String) throws -> GitDiffDocument {
        let canonicalDirectory = try availableDirectory(directory)
        let verified = try git(
            ["rev-parse", "--verify", "--end-of-options", "\(commit)^{commit}"], in: canonicalDirectory)
        let paths = [file.originalPath, file.path].compactMap { $0 }
        let output = try git(
            ["show", "--format=", "--no-ext-diff", "-M", verified, "--"] + paths,
            in: canonicalDirectory, trimTrailingNewline: false)
        return GitDiffDocument.parse(output)
    }

    private nonisolated struct RawStatusEntry: Sendable {
        let section: GitFileSection
        let status: GitFileStatus
        let path: String
        let originalPath: String?
    }

    private nonisolated struct ParsedStatus: Sendable {
        let branchLabel: String
        let headCommit: String?
        let ahead: Int
        let behind: Int
        let entries: [RawStatusEntry]
    }

    private nonisolated static func parsePorcelainStatus(_ output: String) -> ParsedStatus {
        let tokens = output.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
        var branchHead: String?
        var branchOID: String?
        var ahead = 0
        var behind = 0
        var entries: [RawStatusEntry] = []

        var index = 0
        while index < tokens.count {
            let token = tokens[index]
            index += 1
            guard !token.isEmpty else { continue }

            if token.hasPrefix("# branch.head ") {
                branchHead = String(token.dropFirst("# branch.head ".count))
            } else if token.hasPrefix("# branch.oid ") {
                let oid = String(token.dropFirst("# branch.oid ".count))
                branchOID = oid == "(initial)" ? nil : oid
            } else if token.hasPrefix("# branch.ab ") {
                let parts = token.dropFirst("# branch.ab ".count).split(separator: " ")
                if parts.count >= 2 {
                    ahead = Int(parts[0].dropFirst()) ?? 0
                    behind = Int(parts[1].dropFirst()) ?? 0
                }
            } else if token.hasPrefix("1 ") {
                guard let (xy, path) = splitStatusFields(token, headerFieldCount: 8) else { continue }
                let chars = Array(xy)
                guard chars.count == 2 else { continue }
                if chars[0] != "." {
                    entries.append(
                        RawStatusEntry(
                            section: .staged, status: GitFileStatus(porcelainCode: chars[0]), path: path,
                            originalPath: nil))
                }
                if chars[1] != "." {
                    entries.append(
                        RawStatusEntry(
                            section: .unstaged, status: GitFileStatus(porcelainCode: chars[1]), path: path,
                            originalPath: nil))
                }
            } else if token.hasPrefix("2 ") {
                let originalPath = index < tokens.count ? tokens[index] : nil
                if index < tokens.count { index += 1 }
                guard let (xy, path) = splitStatusFields(token, headerFieldCount: 9) else { continue }
                let chars = Array(xy)
                guard chars.count == 2 else { continue }
                if chars[0] != "." {
                    entries.append(
                        RawStatusEntry(
                            section: .staged, status: GitFileStatus(porcelainCode: chars[0]), path: path,
                            originalPath: originalPath))
                }
                if chars[1] != "." {
                    entries.append(
                        RawStatusEntry(
                            section: .unstaged, status: GitFileStatus(porcelainCode: chars[1]), path: path,
                            originalPath: originalPath))
                }
            } else if token.hasPrefix("u ") {
                guard let (_, path) = splitStatusFields(token, headerFieldCount: 10) else { continue }
                entries.append(RawStatusEntry(section: .unstaged, status: .unmerged, path: path, originalPath: nil))
            } else if token.hasPrefix("? ") {
                let path = String(token.dropFirst(2))
                entries.append(RawStatusEntry(section: .untracked, status: .untracked, path: path, originalPath: nil))
            }
        }

        let label: String
        if let head = branchHead, !head.isEmpty, head != "(detached)" {
            label = head
        } else if let oid = branchOID, !oid.isEmpty {
            label = "Detached at \(oid.prefix(8))"
        } else {
            label = "Current checkout"
        }
        return ParsedStatus(branchLabel: label, headCommit: branchOID, ahead: ahead, behind: behind, entries: entries)
    }

    private nonisolated static func splitStatusFields(_ record: String, headerFieldCount: Int) -> (String, String)? {
        // Record starts with "<type> <XY> ..." where headerFieldCount space-separated fields precede the path.
        var spaceCount = 0
        var xyRangeStart: String.Index?
        var xyRangeEnd: String.Index?
        var pathStart: String.Index?
        var cursor = record.startIndex
        while cursor < record.endIndex {
            if record[cursor] == " " {
                spaceCount += 1
                let next = record.index(after: cursor)
                if spaceCount == 1 { xyRangeStart = next }
                if spaceCount == 2 { xyRangeEnd = cursor }
                if spaceCount == headerFieldCount {
                    pathStart = next
                    break
                }
            }
            cursor = record.index(after: cursor)
        }
        guard let xyRangeStart, let xyRangeEnd, let pathStart, xyRangeStart <= xyRangeEnd else { return nil }
        return (String(record[xyRangeStart..<xyRangeEnd]), String(record[pathStart...]))
    }

    private nonisolated static func parseNumstat(_ output: String) -> [String: NumstatEntry] {
        let tokens = output.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
        var result: [String: NumstatEntry] = [:]
        var index = 0
        while index < tokens.count {
            let token = tokens[index]
            index += 1
            guard !token.isEmpty else { continue }
            let parts = token.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3 else { continue }
            let isBinary = parts[0] == "-" && parts[1] == "-"
            let additions = isBinary ? nil : Int(parts[0])
            let deletions = isBinary ? nil : Int(parts[1])
            let path: String
            if parts[2].isEmpty {
                // Rename/copy format in -z mode: "<add>\t<del>\t\0<origPath>\0<newPath>\0".
                guard index + 1 < tokens.count else { break }
                path = tokens[index + 1]
                index += 2
            } else {
                path = String(parts[2])
            }
            result[path] = NumstatEntry(additions: additions, deletions: deletions, isBinary: isBinary)
        }
        return result
    }

    private nonisolated static func parseNameStatus(_ output: String) -> [(
        status: GitFileStatus, path: String, originalPath: String?
    )] {
        let tokens = output.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
        var result: [(GitFileStatus, String, String?)] = []
        var index = 0
        while index < tokens.count {
            let codeToken = tokens[index]
            index += 1
            guard let first = codeToken.first else { continue }
            let status = GitFileStatus(porcelainCode: first)
            if first == "R" || first == "C" {
                guard index + 1 < tokens.count else { break }
                let orig = tokens[index]
                let dest = tokens[index + 1]
                index += 2
                result.append((status, dest, orig))
            } else {
                guard index < tokens.count else { break }
                let path = tokens[index]
                index += 1
                result.append((status, path, nil))
            }
        }
        return result
    }

    private nonisolated static func parseCommitLog(_ output: String) -> [GitCommitSummary] {
        guard !output.isEmpty else { return [] }
        return output.split(separator: "\u{1e}", omittingEmptySubsequences: true).compactMap { record in
            let lines = record.split(whereSeparator: \.isNewline).map(String.init)
            guard let header = lines.first else { return nil }
            let fields = header.split(separator: "\u{1f}", omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 5, !fields[0].isEmpty else { return nil }
            let date = TimeInterval(fields[4]).map(Date.init(timeIntervalSince1970:))
            let statLine = lines.dropFirst().last { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? ""
            let stats = parseShortstat(statLine)
            return GitCommitSummary(
                hash: fields[0], shortHash: fields[1], subject: fields[2], author: fields[3], date: date,
                fileCount: stats.files, additions: stats.additions, deletions: stats.deletions)
        }
    }

    private nonisolated static func parseShortstat(_ line: String) -> (files: Int, additions: Int, deletions: Int) {
        var files = 0
        var additions = 0
        var deletions = 0
        for part in line.split(separator: ",") {
            let tokens = part.trimmingCharacters(in: .whitespaces).split(separator: " ")
            guard tokens.count >= 2, let count = Int(tokens[0]) else { continue }
            if tokens[1].hasPrefix("file") {
                files = count
            } else if tokens[1].hasPrefix("insertion") {
                additions = count
            } else if tokens[1].hasPrefix("deletion") {
                deletions = count
            }
        }
        return (files, additions, deletions)
    }

    private nonisolated static func measureUntrackedFile(at url: URL) -> NumstatEntry? {
        let files = FileManager.default
        guard let attributes = try? files.attributesOfItem(atPath: url.path) else { return nil }
        guard (attributes[.type] as? FileAttributeType) == .typeRegular else { return nil }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let limit = GitDiffDocument.maxUntrackedBytes
        let data = (try? handle.read(upToCount: limit + 1)) ?? Data()
        let truncated = data.count > limit
        let sample = truncated ? data.prefix(limit) : data
        if sample.contains(0) {
            return NumstatEntry(additions: nil, deletions: nil, isBinary: true)
        }
        if truncated { return NumstatEntry(additions: nil, deletions: nil, isBinary: false) }
        guard !sample.isEmpty else { return NumstatEntry(additions: 0, deletions: 0, isBinary: false) }
        var lines = sample.reduce(0) { $0 + ($1 == 0x0A ? 1 : 0) }
        if sample.last != 0x0A { lines += 1 }
        return NumstatEntry(additions: lines, deletions: 0, isBinary: false)
    }
}

/// Watches a worktree and its Git metadata directory with FSEvents, filtering high-frequency object churn.
nonisolated final class GitDirectoryWatcher: @unchecked Sendable {
    private final class CallbackBox: @unchecked Sendable {
        let onChange: @Sendable () -> Void
        init(_ onChange: @escaping @Sendable () -> Void) { self.onChange = onChange }
    }

    private struct StreamBox: @unchecked Sendable {
        var stream: FSEventStreamRef?
    }

    private let lock = OSAllocatedUnfairLock<StreamBox>(initialState: StreamBox())
    private let queue = DispatchQueue(label: "com.mindmapade.git-directory-watcher", qos: .utility)

    init(paths: [String], onChange: @escaping @Sendable () -> Void) {
        let unique = Array(Set(paths)).filter { !$0.isEmpty }
        guard !unique.isEmpty else { return }
        let box = CallbackBox(onChange)
        let retainCallback: CFAllocatorRetainCallBack = { info in
            guard let info else { return nil }
            _ = Unmanaged<CallbackBox>.fromOpaque(info).retain()
            return info
        }
        let releaseCallback: CFAllocatorReleaseCallBack = { info in
            guard let info else { return }
            Unmanaged<CallbackBox>.fromOpaque(info).release()
        }
        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(box).toOpaque(),
            retain: retainCallback, release: releaseCallback, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, eventCount, eventPaths, _, _ in
            guard let info else { return }
            let pathsArray = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue()
            var relevant = false
            for index in 0..<eventCount {
                let raw = CFArrayGetValueAtIndex(pathsArray, index)
                let path = Unmanaged<CFString>.fromOpaque(raw!).takeUnretainedValue() as String
                if !GitDirectoryWatcher.isNoisyGitPath(path) {
                    relevant = true
                    break
                }
            }
            guard relevant else { return }
            let box = Unmanaged<CallbackBox>.fromOpaque(info).takeUnretainedValue()
            box.onChange()
        }
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
        guard
            let stream = FSEventStreamCreate(
                kCFAllocatorDefault, callback, &context, unique as CFArray,
                FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.35, flags)
        else { return }
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
        let boxToStore = StreamBox(stream: stream)
        lock.withLock { $0 = boxToStore }
    }

    deinit {
        stop()
    }

    func stop() {
        let box = lock.withLock { current -> StreamBox in
            let existing = current
            current = StreamBox()
            return existing
        }
        if let stream = box.stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }

    private static func isNoisyGitPath(_ path: String) -> Bool {
        path.contains("/.git/objects/") || path.contains("/.git/logs/") || path.contains("/logs/refs/")
            || path.hasSuffix(".lock")
    }
}

nonisolated struct GitChangesTarget: Hashable, Sendable {
    let directory: String
    let baseCommit: String?
}

nonisolated struct GitChangesCardSummary: Equatable, Sendable {
    let branchLabel: String
    let cardDetail: String

    var externalCardDetail: String {
        "\(branchLabel) · \(cardDetail)"
    }
}

nonisolated struct UntrackedDirtyRepository: Identifiable, Equatable, Sendable {
    let directory: String
    let name: String
    let branchLabel: String
    let cardDetail: String

    var id: String { directory }
}
