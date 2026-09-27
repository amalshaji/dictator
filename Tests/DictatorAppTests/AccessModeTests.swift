import Foundation
import XCTest
@testable import Dictator

@MainActor
final class AccessModeTests: XCTestCase {
    func testMenuBarRecordingControlTracksRecordingPhase() {
        XCTAssertEqual(MenuBarRecordingControl(phase: .idle).title, "Start Dictation")
        XCTAssertTrue(MenuBarRecordingControl(phase: .idle).isEnabled)
        XCTAssertEqual(MenuBarRecordingControl(phase: .listening).title, "Stop Dictation")
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
            defaults: defaults
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
            defaults: defaults
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
            defaults: defaults
        )

        model.setAccessMode(.systemWide)

        let restored = AppModel(
            keychain: AppTestCredentialStore(),
            appleSpeechProvider: nil,
            defaults: defaults
        )
        XCTAssertEqual(restored.accessMode, .systemWide)
    }

    func testLeastPrivilegesAccessCapabilitiesAreClipboardOnly() {
        XCTAssertFalse(AppAccessMode.leastPrivileges.allowsGlobalShortcuts)
        XCTAssertFalse(AppAccessMode.leastPrivileges.allowsFocusedInsertion)
        XCTAssertTrue(AppAccessMode.leastPrivileges.deliversToClipboard)
    }

    func testAccessModePresentationExplainsItsPermissionBoundary() {
        XCTAssertEqual(AppAccessMode.leastPrivileges.title, "Use with least privileges")
        XCTAssertEqual(AppAccessMode.systemWide.title, "Use system-wide")
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
            defaults: defaults
        )
        model.setAccessMode(.leastPrivileges)

        XCTAssertEqual(model.insertionMode, .clipboard)
        XCTAssertEqual(defaults.string(forKey: "insertionMode"), InsertionMode.insert.rawValue)

        model.setAccessMode(.systemWide)

        XCTAssertEqual(model.insertionMode, .insert)
    }

    func testLeastPrivilegesOnboardingRequiresOnlyMicrophone() throws {
        let suiteName = "ai.dictator.tests.onboarding-permissions-least.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let model = AppModel(
            keychain: AppTestCredentialStore(),
            appleSpeechProvider: nil,
            defaults: defaults
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
            defaults: defaults
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
            defaults: defaults
        )

        model.setInsertionMode(.insert)

        XCTAssertEqual(model.insertionMode, .clipboard)
    }
}
