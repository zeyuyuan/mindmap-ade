import CoreGraphics
import Foundation
import Testing

@testable import MindMapCore

@Test func movingMultipleRootsPreservesTheirSpacingAndHasOneInverse() throws {
    var board = MindMapBoard()
    let first = board.roots[0].id
    let second = try #require(board.inserting(parent: nil, position: CGPoint(x: 20, y: 180)))
    board.apply(second.edit)
    let before = board
    let edit = try #require(
        board.movingBranches(
            [first, second.id], to: nil,
            positions: [
                first: CGPoint(x: 40, y: 25), second.id: CGPoint(x: 60, y: 205),
            ]))
    let inverse = board.apply(edit)
    #expect(board.roots.map(\.id) == before.roots.map(\.id))
    #expect(board.roots[1].position.y - board.roots[0].position.y == 180)
    #expect(board.roots[1].position.x - board.roots[0].position.x == 20)
    board.apply(inverse)
    #expect(board == before)
}

@Test func groupedBranchesPreserveOrderAndMoveSelectedDescendantsOnlyOnce() throws {
    var board = MindMapBoard()
    let root = board.roots[0].id
    let a = try #require(board.inserting(text: "A", parent: root))
    board.apply(a.edit)
    let b = try #require(board.inserting(text: "B", parent: root))
    board.apply(b.edit)
    let child = try #require(board.inserting(text: "Child", parent: a.id))
    board.apply(child.edit)
    let target = try #require(board.inserting(parent: nil, position: CGPoint(x: 0, y: 300)))
    board.apply(target.edit)
    #expect(board.topLevelSelection([b.id, child.id, a.id]) == [a.id, b.id])
    let original = board
    let undo = board.apply(try #require(board.movingBranches([b.id, a.id, child.id], to: target.id)))
    #expect(board.nodes[target.id]?.children == [a.id, b.id])
    #expect(board.parents[child.id] == a.id)
    #expect(board.nodes[root]?.children.isEmpty == true)
    _ = try board.validated()
    board.apply(undo)
    #expect(board == original)
    #expect(board.movingBranches([a.id, b.id], to: child.id) == nil)

    board.apply(try #require(board.movingBranches([b.id], to: root, at: 0)))
    #expect(board.nodes[root]?.children == [b.id, a.id])
    let decoded = try JSONDecoder().decode(MindMapBoard.self, from: JSONEncoder().encode(board))
    #expect(decoded.parents == board.parents)
    #expect(decoded == board)
}
