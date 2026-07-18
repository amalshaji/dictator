import Combine
import Foundation
import Sparkle

@MainActor
protocol UpdateEngine: AnyObject {
    var canCheckForUpdatesPublisher: AnyPublisher<Bool, Never> { get }
    var automaticallyChecksForUpdates: Bool { get set }
    var receivesCanaryUpdates: Bool { get set }
    func checkForUpdates()
}

@MainActor
final class SparkleUpdateDelegate: NSObject, SPUUpdaterDelegate {
    var receivesCanaryUpdates: Bool

    init(receivesCanaryUpdates: Bool) {
        self.receivesCanaryUpdates = receivesCanaryUpdates
    }

    var allowedChannels: Set<String> {
        receivesCanaryUpdates ? ["canary"] : []
    }

    func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        allowedChannels
    }
}

@MainActor
private final class SparkleUpdateEngine: UpdateEngine {
    private let updateDelegate: SparkleUpdateDelegate
    private let controller: SPUStandardUpdaterController

    init(receivesCanaryUpdates: Bool) {
        updateDelegate = SparkleUpdateDelegate(receivesCanaryUpdates: receivesCanaryUpdates)
        controller = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: updateDelegate,
            userDriverDelegate: nil
        )
        controller.startUpdater()
    }

    var canCheckForUpdatesPublisher: AnyPublisher<Bool, Never> {
        controller.updater.publisher(for: \.canCheckForUpdates, options: [.initial, .new])
            .eraseToAnyPublisher()
    }

    var automaticallyChecksForUpdates: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }

    var receivesCanaryUpdates: Bool {
        get { updateDelegate.receivesCanaryUpdates }
        set {
            guard newValue != updateDelegate.receivesCanaryUpdates else { return }
            updateDelegate.receivesCanaryUpdates = newValue
            controller.updater.resetUpdateCycleAfterShortDelay()
        }
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }
}

@MainActor
final class AppUpdater: ObservableObject {
    private static let receivesCanaryUpdatesKey = "receiveCanaryUpdates"

    @Published private(set) var canCheckForUpdates = false
    @Published var automaticallyChecksForUpdates: Bool {
        didSet {
            guard automaticallyChecksForUpdates != oldValue else { return }
            engine.automaticallyChecksForUpdates = automaticallyChecksForUpdates
        }
    }
    @Published var receivesCanaryUpdates: Bool {
        didSet {
            guard receivesCanaryUpdates != oldValue else { return }
            defaults.set(receivesCanaryUpdates, forKey: Self.receivesCanaryUpdatesKey)
            engine.receivesCanaryUpdates = receivesCanaryUpdates
        }
    }

    let version: String
    let build: String

    private let engine: any UpdateEngine
    private let defaults: UserDefaults
    private var canCheckForUpdatesSubscription: AnyCancellable?

    convenience init() {
        let defaults = UserDefaults.standard
        let receivesCanaryUpdates = defaults.bool(forKey: Self.receivesCanaryUpdatesKey)
        self.init(
            engine: SparkleUpdateEngine(receivesCanaryUpdates: receivesCanaryUpdates),
            bundle: .main,
            defaults: defaults
        )
    }

    init(
        engine: any UpdateEngine,
        bundle: Bundle,
        defaults: UserDefaults = .standard
    ) {
        self.engine = engine
        self.defaults = defaults
        automaticallyChecksForUpdates = engine.automaticallyChecksForUpdates
        receivesCanaryUpdates = defaults.bool(forKey: Self.receivesCanaryUpdatesKey)
        version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown"
        build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "Unknown"
        if engine.receivesCanaryUpdates != receivesCanaryUpdates {
            engine.receivesCanaryUpdates = receivesCanaryUpdates
        }
        canCheckForUpdatesSubscription = engine.canCheckForUpdatesPublisher
            .sink { [weak self] canCheckForUpdates in
                self?.canCheckForUpdates = canCheckForUpdates
            }
    }

    var versionDescription: String {
        "Version \(version) (\(build))"
    }

    func checkForUpdates() {
        engine.checkForUpdates()
    }
}
