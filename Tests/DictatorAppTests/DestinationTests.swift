import XCTest
@testable import Dictator

final class DestinationTests: XCTestCase {
    func testFourDestinationsWithSequentialKeyboardNumbers() {
        XCTAssertEqual(Destination.allCases.count, 4)
        XCTAssertEqual(Destination.allCases.map(\.keyboardNumber), [1, 2, 3, 4])
    }
}
