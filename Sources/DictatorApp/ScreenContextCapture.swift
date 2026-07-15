import AppKit
import CoreGraphics
import DictatorCore
import Foundation
import ScreenCaptureKit
import UniformTypeIdentifiers

struct FocusedWindowSnapshot: Equatable, Sendable {
    let processIdentifier: pid_t
    let applicationName: String?
    let bundleIdentifier: String?
    let title: String?
    let frame: CGRect
}

struct ScreenWindowDescriptor: Equatable, Sendable {
    let id: CGWindowID
    let processIdentifier: pid_t
    let title: String?
    let frame: CGRect
}

enum ScreenWindowMatcher {
    static func match(
        focused: FocusedWindowSnapshot,
        candidates: [ScreenWindowDescriptor]
    ) -> ScreenWindowDescriptor? {
        let scored = candidates
            .filter { $0.processIdentifier == focused.processIdentifier }
            .map { ($0, score($0, against: focused)) }
            .filter { $0.1 >= 4 }
            .sorted { $0.1 > $1.1 }
        guard let best = scored.first else { return nil }
        guard scored.dropFirst().first?.1 != best.1 else { return nil }
        return best.0
    }

    private static func score(_ candidate: ScreenWindowDescriptor, against focused: FocusedWindowSnapshot) -> Int {
        var value = 0
        if let title = focused.title?.trimmingCharacters(in: .whitespacesAndNewlines),
           !title.isEmpty,
           title == candidate.title?.trimmingCharacters(in: .whitespacesAndNewlines) {
            value += 4
        }
        let intersection = candidate.frame.intersection(focused.frame)
        let unionArea = candidate.frame.width * candidate.frame.height
            + focused.frame.width * focused.frame.height
            - intersection.width * intersection.height
        if unionArea > 0, intersection.width * intersection.height / unionArea >= 0.9 {
            value += 4
        }
        return value
    }
}

struct CapturedScreenContext: Equatable, Sendable {
    let imageData: Data
    let imageMIMEType: String
    let window: FocusedWindowSnapshot
}

@MainActor
protocol ScreenContextCapturing: Sendable {
    var permissionGranted: Bool { get }
    func requestPermission() -> Bool
    func capture(_ window: FocusedWindowSnapshot) async throws -> CapturedScreenContext
}

enum ScreenContextCaptureError: LocalizedError {
    case permissionRequired
    case focusedWindowUnavailable
    case encodingFailed

    var errorDescription: String? {
        switch self {
        case .permissionRequired: "Screen Recording permission is required for screen-aware dictation."
        case .focusedWindowUnavailable: "The focused window could not be identified safely."
        case .encodingFailed: "The focused-window screenshot could not be encoded."
        }
    }
}

@MainActor
enum ScreenAwareConnectionProbe {
    static func request() throws -> ScreenAwareRequest {
        let bytes: [UInt8] = [
            255, 255, 255, 255, 235, 235, 235, 255,
            215, 215, 215, 255, 195, 195, 195, 255,
        ]
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let image = CGImage(
                  width: 2,
                  height: 2,
                  bitsPerComponent: 8,
                  bitsPerPixel: 32,
                  bytesPerRow: 8,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                  provider: provider,
                  decode: nil,
                  shouldInterpolate: false,
                  intent: .defaultIntent
              ),
              let imageData = ScreenContextCaptureService.jpegData(from: image)
        else { throw ScreenContextCaptureError.encodingFailed }

        return ScreenAwareRequest(
            command: "Return the word OK.",
            imageData: imageData,
            imageMIMEType: "image/jpeg"
        )
    }
}

@MainActor
final class ScreenContextCaptureService: ScreenContextCapturing {
    var permissionGranted: Bool { CGPreflightScreenCaptureAccess() }

    func requestPermission() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    func capture(_ window: FocusedWindowSnapshot) async throws -> CapturedScreenContext {
        guard permissionGranted else { throw ScreenContextCaptureError.permissionRequired }
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        let windows = content.windows.filter { $0.windowLayer == 0 && $0.isOnScreen }
        let candidates = windows.map {
            ScreenWindowDescriptor(
                id: $0.windowID,
                processIdentifier: $0.owningApplication?.processID ?? 0,
                title: $0.title,
                frame: $0.frame
            )
        }
        guard let descriptor = ScreenWindowMatcher.match(focused: window, candidates: candidates),
              let matched = windows.first(where: { $0.windowID == descriptor.id })
        else { throw ScreenContextCaptureError.focusedWindowUnavailable }

        let filter = SCContentFilter(desktopIndependentWindow: matched)
        let configuration = SCStreamConfiguration()
        let scale = min(2, 2_048 / max(1, max(matched.frame.width, matched.frame.height)))
        configuration.width = max(1, Int(matched.frame.width * scale))
        configuration.height = max(1, Int(matched.frame.height * scale))
        configuration.captureResolution = .best
        configuration.showsCursor = false
        configuration.ignoreShadowsSingleWindow = true
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        guard let data = Self.jpegData(from: image) else { throw ScreenContextCaptureError.encodingFailed }
        return CapturedScreenContext(imageData: data, imageMIMEType: "image/jpeg", window: window)
    }

    static func jpegData(from image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
