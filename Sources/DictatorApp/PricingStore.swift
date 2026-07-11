import Combine
import DictatorCore

@MainActor
final class PricingStore: ObservableObject {
    @Published private(set) var snapshot: PricingSnapshot?
    @Published private(set) var isRefreshing = false
    @Published private(set) var errorMessage: String?

    private let service: PricingService

    init(service: PricingService = PricingService()) {
        self.service = service
    }

    func refresh(force: Bool = false) async {
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            snapshot = try await service.refreshIfNeeded(force: force)
            errorMessage = nil
        } catch {
            snapshot = await service.current()
            errorMessage = "Could not refresh pricing. Showing the last available catalog."
        }
    }
}
