import AppKit
import Combine
import Foundation

enum HotkeyLifecycleState: Equatable {
    case stopped
    case available
    case unavailable(String)
}

@MainActor
final class HotkeyLifecycleController {
    typealias RecoveryScheduler = @MainActor (@escaping @MainActor () -> Bool) -> AnyCancellable

    var onPress: ((pid_t?) -> Void)? {
        get { monitor.onPress }
        set { monitor.onPress = newValue }
    }
    var onRelease: (() -> Void)? {
        get { monitor.onRelease }
        set { monitor.onRelease = newValue }
    }
    var onPasteLatest: (() -> Void)? {
        get { monitor.onPasteLatest }
        set { monitor.onPasteLatest = newValue }
    }
    var onOpenClipboard: (() -> Void)? {
        get { monitor.onOpenClipboard }
        set { monitor.onOpenClipboard = newValue }
    }
    var onWillSleep: (() -> Void)?
    var onStateChange: ((HotkeyLifecycleState) -> Void)? {
        didSet { onStateChange?(state) }
    }

    private(set) var state = HotkeyLifecycleState.stopped {
        didSet {
            guard state != oldValue else { return }
            onStateChange?(state)
        }
    }

    private let monitor: any HotkeyMonitoring
    private let notificationCenter: NotificationCenter
    private let scheduleRecovery: RecoveryScheduler
    private var observers = [NSObjectProtocol]()
    private var recovery: AnyCancellable?

    init(
        monitor: any HotkeyMonitoring = HotkeyMonitor(),
        notificationCenter: NotificationCenter = NSWorkspace.shared.notificationCenter,
        scheduleRecovery: @escaping RecoveryScheduler = HotkeyLifecycleController.scheduleEverySecond
    ) {
        self.monitor = monitor
        self.notificationCenter = notificationCenter
        self.scheduleRecovery = scheduleRecovery
        observeWorkspaceLifecycle()
    }

    isolated deinit {
        recovery?.cancel()
        observers.forEach(notificationCenter.removeObserver)
    }

    func configure(dictate: GlobalShortcut, pasteLatest: GlobalShortcut, openClipboard: GlobalShortcut) {
        monitor.configure(dictate: dictate, pasteLatest: pasteLatest, openClipboard: openClipboard)
    }

    func start() {
        recoverIfNeeded()
    }

    func retry() {
        recoverIfNeeded()
    }

    private func observeWorkspaceLifecycle() {
        observers.append(notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.prepareForSleep() }
        })
        observers.append(notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.recoverAfterWake() }
        })
    }

    private func prepareForSleep() {
        cancelRecovery()
        onWillSleep?()
        monitor.stop()
        state = .stopped
    }

    private func recoverAfterWake() {
        cancelRecovery()
        monitor.stop()
        state = .stopped
        recoverIfNeeded()
    }

    private func recoverIfNeeded() {
        if startMonitor() {
            cancelRecovery()
        } else if recovery == nil {
            recovery = scheduleRecovery { [weak self] in
                guard let self else { return true }
                guard self.startMonitor() else { return false }
                self.recovery = nil
                return true
            }
        }
    }

    private func startMonitor() -> Bool {
        if monitor.isRunning {
            state = .available
            return true
        }
        do {
            try monitor.start()
            guard monitor.isRunning else {
                state = .unavailable(HotkeyError.permissionRequired.localizedDescription)
                return false
            }
            state = .available
            return true
        } catch {
            state = .unavailable(error.localizedDescription)
            return false
        }
    }

    private func cancelRecovery() {
        recovery?.cancel()
        recovery = nil
    }

    private static func scheduleEverySecond(
        _ recovery: @escaping @MainActor () -> Bool
    ) -> AnyCancellable {
        let task = Task { @MainActor in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) }
                catch { return }
                if recovery() { return }
            }
        }
        return AnyCancellable { task.cancel() }
    }
}
