import Foundation

public struct PricingSnapshot: Codable, Equatable, Sendable {
    public var fetchedAt: Date
    public var rates: [String: ModelTokenRate]

    public init(fetchedAt: Date, rates: [String: ModelTokenRate]) {
        self.fetchedAt = fetchedAt
        self.rates = rates
    }
}
