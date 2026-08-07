import SwiftUI
import XCTest
@testable import Dictator

@MainActor
final class SettingsLayoutTests: XCTestCase {
    private let rowWidth: CGFloat = 400

    func testShortcutRecorderPillsShareTheTrailingEdgeRegardlessOfLabelWidth() throws {
        let shortest = try trailingEdge(of: ShortcutRecorder(shortcut: .dictate, allowsFunctionModifier: true) { _ in true })
        let longest = try trailingEdge(of: ShortcutRecorder(shortcut: .openClipboard) { _ in true })

        XCTAssertEqual(shortest, rowWidth, accuracy: 1)
        XCTAssertEqual(longest, rowWidth, accuracy: 1)
    }

    /// Renders `control` trailing-aligned in a `rowWidth` row and returns the x
    /// offset of its right-most drawn pixel.
    private func trailingEdge(of control: some View) throws -> CGFloat {
        let renderer = ImageRenderer(
            content: HStack(spacing: 20) {
                Spacer()
                control
            }
            .frame(width: rowWidth, height: 60)
            .background(Color.black)
        )
        renderer.scale = 1
        let image = try XCTUnwrap(renderer.cgImage)
        let width = image.width
        let height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let context = try XCTUnwrap(
            CGContext(
                data: &pixels,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        )
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        for x in stride(from: width - 1, through: 0, by: -1) {
            for y in 0..<height where pixels[(y * width + x) * 4] > 40 {
                return CGFloat(x + 1) * rowWidth / CGFloat(width)
            }
        }
        XCTFail("Control drew nothing")
        return 0
    }
}
