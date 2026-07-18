import Combine
import Foundation
import XCTest
@testable import Dictator

@MainActor
final class AppUpdaterTests: XCTestCase {
    private final class FakeUpdateEngine: UpdateEngine {
        let canCheckSubject = CurrentValueSubject<Bool, Never>(false)
        var automaticallyChecksForUpdates = true
        var receivesCanaryUpdates = false {
            didSet {
                guard receivesCanaryUpdates != oldValue else { return }
                updateCycleResetCount += 1
            }
        }
        private(set) var checkCount = 0
        private(set) var updateCycleResetCount = 0

        var canCheckForUpdatesPublisher: AnyPublisher<Bool, Never> {
            canCheckSubject.eraseToAnyPublisher()
        }

        func checkForUpdates() {
            checkCount += 1
        }
    }

    func testForwardsAvailabilityAndManualChecks() throws {
        let engine = FakeUpdateEngine()
        let updater = AppUpdater(engine: engine, bundle: try updaterTestBundle())

        XCTAssertFalse(updater.canCheckForUpdates)
        engine.canCheckSubject.send(true)
        XCTAssertTrue(updater.canCheckForUpdates)

        updater.checkForUpdates()
        XCTAssertEqual(engine.checkCount, 1)
        XCTAssertEqual(updater.versionDescription, "Version 1.2.3 (45)")
    }

    func testWritesAutomaticCheckPreferenceToSparkleEngine() throws {
        let engine = FakeUpdateEngine()
        let updater = AppUpdater(engine: engine, bundle: try updaterTestBundle())

        XCTAssertTrue(updater.automaticallyChecksForUpdates)
        updater.automaticallyChecksForUpdates = false
        XCTAssertFalse(engine.automaticallyChecksForUpdates)
    }

    func testPersistsCanaryPreferenceAndResetsUpdateCycle() throws {
        let suiteName = "AppUpdaterTests.canary.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let engine = FakeUpdateEngine()
        let updater = AppUpdater(
            engine: engine,
            bundle: try updaterTestBundle(),
            defaults: defaults
        )

        XCTAssertFalse(updater.receivesCanaryUpdates)
        XCTAssertFalse(engine.receivesCanaryUpdates)

        updater.receivesCanaryUpdates = true

        XCTAssertTrue(engine.receivesCanaryUpdates)
        XCTAssertTrue(defaults.bool(forKey: "receiveCanaryUpdates"))
        XCTAssertEqual(engine.updateCycleResetCount, 1)
    }

    func testRestoresCanaryPreferenceBeforeUse() throws {
        let suiteName = "AppUpdaterTests.canary.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(true, forKey: "receiveCanaryUpdates")
        let engine = FakeUpdateEngine()

        let updater = AppUpdater(
            engine: engine,
            bundle: try updaterTestBundle(),
            defaults: defaults
        )

        XCTAssertTrue(updater.receivesCanaryUpdates)
        XCTAssertTrue(engine.receivesCanaryUpdates)
    }

    func testSparkleDelegateAllowsOnlyOptedInCanaryChannel() {
        let delegate = SparkleUpdateDelegate(receivesCanaryUpdates: false)
        XCTAssertEqual(delegate.allowedChannels, [])

        delegate.receivesCanaryUpdates = true
        XCTAssertEqual(delegate.allowedChannels, ["canary"])
    }

    private func updaterTestBundle() throws -> Bundle {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
            .appending(path: "UpdaterTests.bundle", directoryHint: .isDirectory)
        let contents = root.appending(path: "Contents", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let info: [String: Any] = [
            "CFBundleIdentifier": "ai.dictator.tests.updater",
            "CFBundlePackageType": "BNDL",
            "CFBundleShortVersionString": "1.2.3",
            "CFBundleVersion": "45",
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: contents.appending(path: "Info.plist"))
        return try XCTUnwrap(Bundle(url: root))
    }
}
