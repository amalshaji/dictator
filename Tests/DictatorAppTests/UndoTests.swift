import DictatorCore
import Foundation
import XCTest
@testable import Dictator

/// Verifies the `delete…WithUndo` helpers on `AppModel`: the delete happens
/// immediately, and the reinsertion registered with the `UndoManager` restores
/// the entry at its original index when the user undoes.
@MainActor
final class UndoTests: XCTestCase {
    func testDeleteStyleWithUndoRestoresOnUndo() {
        let model = AppModel()
        let first = WritingStyle(name: "Concise", instruction: "Keep it short")
        let second = WritingStyle(name: "Formal", instruction: "Keep it formal")
        model.data.styles = [first, second]
        let undoManager = UndoManager()

        model.deleteStyleWithUndo(second.id, undoManager: undoManager)
        XCTAssertEqual(model.data.styles.map(\.id), [first.id])

        undoManager.undo()
        XCTAssertEqual(model.data.styles.map(\.id), [first.id, second.id])
        XCTAssertEqual(model.data.styles[1], second)
    }

    func testDeleteSnippetWithUndoRestoresOnUndo() {
        let model = AppModel()
        let first = SnippetEntry(trigger: "sig", expansion: "Best, Amal")
        let second = SnippetEntry(trigger: "addr", expansion: "221B Baker Street")
        model.data.snippets = [first, second]
        let undoManager = UndoManager()

        model.deleteSnippetWithUndo(second.id, undoManager: undoManager)
        XCTAssertEqual(model.data.snippets.map(\.id), [first.id])

        undoManager.undo()
        XCTAssertEqual(model.data.snippets.map(\.id), [first.id, second.id])
        XCTAssertEqual(model.data.snippets[1], second)
    }

    func testDeleteVocabularyWithUndoRestoresOnUndo() {
        let model = AppModel()
        let first = VocabularyEntry(value: "Kubernetes")
        let second = VocabularyEntry(value: "Amal")
        model.data.vocabulary = [first, second]
        let undoManager = UndoManager()

        model.deleteVocabularyWithUndo(second.id, undoManager: undoManager)
        XCTAssertEqual(model.data.vocabulary.map(\.id), [first.id])

        undoManager.undo()
        XCTAssertEqual(model.data.vocabulary.map(\.id), [first.id, second.id])
        XCTAssertEqual(model.data.vocabulary[1], second)
    }

    func testDeleteWithUndoSetsADescriptiveActionName() {
        let model = AppModel()
        let style = WritingStyle(name: "Concise", instruction: "Keep it short")
        model.data.styles = [style]
        let undoManager = UndoManager()

        model.deleteStyleWithUndo(style.id, undoManager: undoManager)

        XCTAssertEqual(undoManager.undoActionName, "Delete Style")
    }

    func testDeleteWithNilUndoManagerStillDeletes() {
        let model = AppModel()
        let style = WritingStyle(name: "Concise", instruction: "Keep it short")
        model.data.styles = [style]

        model.deleteStyleWithUndo(style.id, undoManager: nil)

        XCTAssertTrue(model.data.styles.isEmpty)
    }
}
