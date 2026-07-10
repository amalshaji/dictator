import XCTest
@testable import DictatorCore

final class LocalStoreTests: XCTestCase {
    func testStorePersistsAndPrunesPrivateClipboard() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString).appending(path: "data.json")
        let store = LocalStore(fileURL: url)
        let old = ClipboardEntry(createdAt: Date(timeIntervalSinceNow: -40 * 86_400), text: "old", rawText: "old")
        let recent = (0..<55).map { ClipboardEntry(createdAt: Date(timeIntervalSinceNow: TimeInterval(-$0)), text: "item \($0)", rawText: "item \($0)") }
        try await store.save(PersistedData(clipboard: [old] + recent))
        let loaded = try await store.load()
        XCTAssertEqual(loaded.clipboard.count, 50)
        XCTAssertFalse(loaded.clipboard.contains { $0.text == "old" })
    }
}

