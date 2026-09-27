import Foundation

public func seconds(since instant: ContinuousClock.Instant) -> TimeInterval {
    let duration = instant.duration(to: .now)
    return Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
}
