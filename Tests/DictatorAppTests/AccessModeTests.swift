import Foundation
import XCTest
@testable import Dictator

@MainActor
final class AccessModeTests: XCTestCase {
    func testMenuBarRecordingControlTracksRecordingPhase() {
        XCTAssertEqual(MenuBarRecordingControl(phase: .idle).title, "Start Recording")
        XCTAssertTrue(MenuBarRecordingControl(phase: .idle).isEnabled)
        XCTAssertEqual(MenuBarRecordingControl(phase: .listening).title, "Stop Recording")
        XCTAssertTrue(MenuBarRecordingControl(phase: .listening).isEnabled)
        XCTAssertEqual(MenuBarRecordingControl(phase: .processing).title, "Transcribing…")
        XCTAssertFalse(MenuBarRecordingControl(phase: .processing).isEnabled)
    }

    func testNewInstallationDefaultsToLeastPrivileges() throws {
        let suiteName = "ai.dictator.tests.access-mode-new-install.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let model = AppModel(
            keychain: AppTestCredentialStore(),
            appleSpeechProvider: nil,
            defaults: defaults,
            connectivity: AppTestConnectivityMonitor()
        )

        XCTAssertEqual(model.accessMode, .leastPrivileges)
    }

    func testCompletedInstallationMigratesToSystemWideAccess() throws {
        let suiteName = "ai.dictator.tests.access-mode-migration.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(true, forKey: "onboardingComplete")

        let model = AppModel(
            keychain: AppTestCredentialStore(),
            appleSpeechProvider: nil,
            defaults: defaults,
            connectivity: AppTestConnectivityMonitor()
        )

        XCTAssertEqual(model.accessMode, .systemWide)
        XCTAssertEqual(defaults.string(forKey: "accessMode"), AppAccessMode.systemWide.rawValue)
    }

    func testAccessModePersists() throws {
        let suiteName = "ai.dictator.tests.access-mode-persistence.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let model = AppModel(
            keychain: AppTestCredentialStore(),
            appleSpeechProvider: nil,
            defaults: defaults,
            connectivity: AppTestConnectivityMonitor()
        )

        model.setAccessMode(.systemWide)

        let restored = AppModel(
            keychain: AppTestCredentialStore(),
            appleSpeechProvider: nil,
            defaults: defaults,
            connectivity: AppTestConnectivityMonitor()
        )
        XCTAssertEqual(restored.accessMode, .systemWide)
    }

    func testLeastPrivilegesAccessCapabilitiesAreClipboardOnly() {
        XCTAssertFalse(AppAccessMode.leastPrivileges.allowsGlobalShortcuts)
        XCTAssertFalse(AppAccessMode.leastPrivileges.allowsFocusedInsertion)
        XCTAssertFalse(AppAccessMode.leastPrivileges.allowsScreenAwareDictation)
        XCTAssertTrue(AppAccessMode.leastPrivileges.deliversToClipboard)
    }

    func testAccessModePresentationExplainsItsPermissionBoundary() {
        XCTAssertEqual(AppAccessMode.leastPrivileges.title, "Use with least privileges")
        XCTAssertEqual(AppAccessMode.leastPrivileges.statusTitle, "Microphone only")
        XCTAssertEqual(
            AppAccessMode.leastPrivileges.recordingInstruction,
            "Start from the menu bar, stop from the pill, then press ⌘V to paste."
        )
        XCTAssertEqual(AppAccessMode.systemWide.title, "Use system-wide")
        XCTAssertEqual(AppAccessMode.systemWide.statusTitle, "System-wide enabled")
    }

    func testSwitchingAccessModesPreservesSystemWidePreferences() throws {
        let suiteName = "ai.dictator.tests.access-mode-restriction.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(AppAccessMode.systemWide.rawValue, forKey: "accessMode")
        defaults.set(InsertionMode.insert.rawValue, forKey: "insertionMode")

        let model = AppModel(
            keychain: AppTestCredentialStore(),
            appleSpeechProvider: nil,
            defaults: defaults,
            connectivity: AppTestConnectivityMonitor()
        )
        model.screenAwareEnabled = true

        model.setAccessMode(.leastPrivileges)

        XCTAssertEqual(model.insertionMode, .clipboard)
        XCTAssertEqual(defaults.string(forKey: "insertionMode"), InsertionMode.insert.rawValue)
        XCTAssertTrue(model.screenAwareEnabled)

        model.setAccessMode(.systemWide)

        XCTAssertEqual(model.insertionMode, .insert)
        XCTAssertTrue(model.screenAwareEnabled)
    }

    func testLeastPrivilegesOnboardingRequiresOnlyMicrophone() throws {
        let suiteName = "ai.dictator.tests.onboarding-permissions-least.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let model = AppModel(
            keychain: AppTestCredentialStore(),
            appleSpeechProvider: nil,
            defaults: defaults,
            connectivity: AppTestConnectivityMonitor()
        )
        model.microphoneGranted = true
        model.accessibilityGranted = false
        model.inputMonitoringGranted = false
        model.shortcutsAvailable = false

        XCTAssertTrue(model.onboardingPermissionsReady)
    }

    func testSystemWideOnboardingRequiresPrivilegedPermissions() throws {
        let suiteName = "ai.dictator.tests.onboarding-permissions-system-wide.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let model = AppModel(
            keychain: AppTestCredentialStore(),
            appleSpeechProvider: nil,
            defaults: defaults,
            connectivity: AppTestConnectivityMonitor()
        )
        model.setAccessMode(.systemWide)
        model.microphoneGranted = true
        model.accessibilityGranted = false
        model.inputMonitoringGranted = false
        model.shortcutsAvailable = false

        XCTAssertFalse(model.onboardingPermissionsReady)

        model.accessibilityGranted = true
        model.inputMonitoringGranted = true
        model.shortcutsAvailable = true
        XCTAssertTrue(model.onboardingPermissionsReady)
    }

    func testLeastPrivilegesCannotEnableFocusedInsertion() throws {
        let suiteName = "ai.dictator.tests.least-privilege-insertion.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let model = AppModel(
            keychain: AppTestCredentialStore(),
            appleSpeechProvider: nil,
            defaults: defaults,
            connectivity: AppTestConnectivityMonitor()
        )

        model.setInsertionMode(.insert)

        XCTAssertEqual(model.insertionMode, .clipboard)
    }
}
