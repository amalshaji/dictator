import Combine
import Foundation
import Sparkle

@MainActor
protocol UpdateEngine: AnyObject {
    var canCheckForUpdatesPublisher: AnyPublisher<Bool, Never> { get }
    var automaticallyChecksForUpdates: Bool { get set }
    func checkForUpdates()
}

@MainActor
private final class SparkleUpdateEngine: UpdateEngine {
    private let controller: SPUStandardUpdaterController

    init() {
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    var canCheckForUpdatesPublisher: AnyPublisher<Bool, Never> {
        controller.updater.publisher(for: \.canCheckForUpdates, options: [.initial, .new])
            .eraseToAnyPublisher()
    }

    var automaticallyChecksForUpdates: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }
}

@MainActor
final class AppUpdater: ObservableObject {
    @Published private(set) var canCheckForUpdates = false
    @Published var automaticallyChecksForUpdates: Bool {
        didSet {
            guard automaticallyChecksForUpdates != oldValue else { return }
            engine.automaticallyChecksForUpdates = automaticallyChecksForUpdates
        }
    }

    let version: String
    let build: String

    private let engine: any UpdateEngine
    private var canCheckForUpdatesSubscription: AnyCancellable?

    convenience init() {
        self.init(engine: SparkleUpdateEngine(), bundle: .main)
    }

    init(engine: any UpdateEngine, bundle: Bundle) {
        self.engine = engine
        automaticallyChecksForUpdates = engine.automaticallyChecksForUpdates
        version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown"
        build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "Unknown"
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
