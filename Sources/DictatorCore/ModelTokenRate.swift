import Foundation

public struct ModelTokenRate: Codable, Equatable, Sendable {
    public let inputPerMillion: Decimal
    public let outputPerMillion: Decimal

    public init(inputPerMillion: Decimal, outputPerMillion: Decimal) {
        self.inputPerMillion = inputPerMillion
        self.outputPerMillion = outputPerMillion
    }
}
