import AppKit
import MindMapCore

struct AgentBranchSummary {
    struct Entry {
        let id: UUID
        let state: AgentRun.State
    }

    let entries: [Entry]
    let label: String
    let width: CGFloat

    private init(entries: [Entry]) {
        self.entries = entries
        let active = entries.count { $0.state.isActive }
        let failed = entries.count { $0.state == .failed }
        let interrupted = entries.count { $0.state == .interrupted }
        label = [
            active == 0 ? nil : "\(active) active",
            failed == 0 ? nil : "\(failed) failed",
            interrupted == 0 ? nil : "\(interrupted) interrupted",
        ].compactMap { $0 }.joined(separator: " · ")
        width =
            ceil((label as NSString).size(withAttributes: [.font: CanvasStyle.agentSummaryFont]).width)
            + CanvasStyle.agentSummaryPadding * 2
    }

    static func make(
        states: [UUID: AgentRun.State], in board: MindMapBoard, expandedAncestors: Set<UUID>
    ) -> [UUID: Self] {
        let parents = board.parents
        var grouped: [UUID: [Entry]] = [:]
        for (id, state) in states where state.isActive || state == .failed || state == .interrupted {
            var outerFold: UUID?
            var parent = parents[id]
            while let ancestor = parent {
                if board.nodes[ancestor]?.isCollapsed == true, !expandedAncestors.contains(ancestor) {
                    outerFold = ancestor
                }
                parent = parents[ancestor]
            }
            if let outerFold { grouped[outerFold, default: []].append(Entry(id: id, state: state)) }
        }
        return grouped.mapValues { entries in
            Self(
                entries: entries.sorted {
                    let first = board.nodes[$0.id]?.title ?? ""
                    let second = board.nodes[$1.id]?.title ?? ""
                    let order = first.localizedStandardCompare(second)
                    return order == .orderedSame ? $0.id.uuidString < $1.id.uuidString : order == .orderedAscending
                })
        }
    }
}
