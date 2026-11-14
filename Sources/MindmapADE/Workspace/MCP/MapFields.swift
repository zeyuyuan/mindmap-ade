import Foundation
import MindMapCore

struct MapField {
    enum Name: String {
        case text, name, description, branch, task, progress

        var byteLimit: Int {
            switch self {
            case .branch: 255
            case .progress: 400
            default: 24_000
            }
        }
    }

    let name: Name
    let text: String
    let replace: ((String) -> MapNode)?

    var isEditable: Bool { replace != nil }
}

extension MapNode {
    func mapFields(isOrigin: Bool, hasRun: Bool) -> [MapField] {
        func field<T>(
            _ name: MapField.Name, _ value: T, at path: WritableKeyPath<T, String>,
            editable: Bool = true, content: @escaping (T) -> NodeContent
        ) -> MapField {
            let replacement: ((String) -> MapNode)? =
                editable
                ? { text in
                    var value = value
                    value[keyPath: path] = text
                    var node = self
                    node.content = content(value)
                    return node
                } : nil
            return MapField(name: name, text: value[keyPath: path], replace: replacement)
        }

        switch content {
        case .text:
            return [
                MapField(name: .text, text: text) { text in
                    var node = self
                    node.text = text
                    return node
                }
            ]
        case .branch(let branch):
            return [field(.name, branch, at: \.name, content: NodeContent.branch)]
        case .project(let project):
            return [
                field(.name, project, at: \.name, content: NodeContent.project),
                field(.description, project, at: \.details, content: NodeContent.project),
            ]
        case .worktree(let worktree):
            guard worktree.location == nil, worktree.choice.mode != .existing else { return [] }
            return [
                field(
                    .branch, worktree, at: \.choice.branch, editable: worktree.choice.pendingPlan == nil,
                    content: NodeContent.worktree)
            ]
        case .agent(let agent):
            let task = field(
                .task, agent, at: \.task, editable: !agent.isConfigured && !hasRun, content: NodeContent.agent)
            let name = field(.name, agent, at: \.name, content: NodeContent.agent)
            let progress = MapField(name: .progress, text: agent.progress ?? "") { text in
                var agent = agent
                agent.progress = text
                var node = self
                node.content = .agent(agent)
                return node
            }
            return isOrigin ? [progress, task, name] : [task, name, progress]
        }
    }
}
