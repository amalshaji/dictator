import DictatorCore
import Foundation
import XCTest
@testable import Dictator

@MainActor
final class AppPreferencesTests: XCTestCase {
    func testCleanupCustomInstructionPersistsAndRestores() throws {
        let suiteName = "ai.dictator.tests.cleanup-instruction.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let model = AppModel(
            keychain: AppTestCredentialStore(),
            appleSpeechProvider: nil,
            defaults: defaults,
            connectivity: AppTestConnectivityMonitor()
        )
        XCTAssertEqual(model.cleanupCustomInstruction, "")

        model.setCleanupCustomInstruction("Prefer British spelling")
        XCTAssertEqual(defaults.string(forKey: "cleanupCustomInstruction"), "Prefer British spelling")

        let restored = AppModel(
            keychain: AppTestCredentialStore(),
            appleSpeechProvider: nil,
            defaults: defaults,
            connectivity: AppTestConnectivityMonitor()
        )
        XCTAssertEqual(restored.cleanupCustomInstruction, "Prefer British spelling")
    }

    func testCleanupCustomInstructionIsBoundedToMaximumLength() throws {
        let suiteName = "ai.dictator.tests.cleanup-instruction-bound.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let limit = AppModel.maximumCleanupInstructionLength

        let model = AppModel(
            keychain: AppTestCredentialStore(),
            appleSpeechProvider: nil,
            defaults: defaults,
            connectivity: AppTestConnectivityMonitor()
        )
        model.setCleanupCustomInstruction(String(repeating: "a", count: limit + 500))
        XCTAssertEqual(model.cleanupCustomInstruction.count, limit)
        XCTAssertEqual(defaults.string(forKey: "cleanupCustomInstruction")?.count, limit)

        defaults.set(String(repeating: "b", count: limit + 500), forKey: "cleanupCustomInstruction")
        let restored = AppModel(
            keychain: AppTestCredentialStore(),
            appleSpeechProvider: nil,
            defaults: defaults,
            connectivity: AppTestConnectivityMonitor()
        )
        XCTAssertEqual(restored.cleanupCustomInstruction.count, limit)
    }

    func testSavedProviderCredentialsAreReportedAsConfiguredBeforeExpansion() throws {
        let suiteName = "ai.dictator.tests.provider-status.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let model = AppModel(
            keychain: ConfiguredProviderCredentialStore(),
            appleSpeechProvider: nil,
            defaults: defaults,
            connectivity: AppTestConnectivityMonitor()
        )

        XCTAssertTrue(model.isProviderConfigured(purpose: .cleanup, provider: .groq))
    }

    func testDisabledStyleCannotBeSelected() {
        let model = AppModel()
        let disabled = WritingStyle(name: "Disabled", instruction: "Do not use", isEnabled: false)
        model.data.styles = [disabled]
        model.selectedStyleID = nil
        model.selectStyle(disabled.id)
        XCTAssertNil(model.selectedStyleID)
    }

    func testAppleSpeechSetupIgnoresStaleLocaleReadiness() async throws {
        let provider = DelayedAppleSpeechProvider()
        let coordinator = AppleSpeechCoordinator(
            provider: provider,
            selectedLocaleIdentifier: "en_US",
            persistSelection: { _ in }
        )
        let initialRefresh = Task { await coordinator.refresh() }

        while coordinator.state.locales.isEmpty { await Task.yield() }
        coordinator.selectLocale("fr_FR")
        try await Task.sleep(for: .milliseconds(200))
        await initialRefresh.value

        XCTAssertEqual(coordinator.state.selectedLocaleIdentifier, "fr_FR")
        XCTAssertEqual(
            coordinator.state.readyLocale,
            AppleSpeechLocale(identifier: "fr_FR", engine: .speechTranscriber)
        )
    }
}
