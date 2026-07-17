import Foundation
import TokenMonitorCore

actor ExchangeRateService {
    private let endpoint = URL(string: "https://api.frankfurter.dev/v2/rate/USD/IDR")!
    private let cache: ExchangeRateCache
    private var quote: ExchangeRateQuote?

    init(cache: ExchangeRateCache = .default()) {
        self.cache = cache
        quote = cache.load()
    }

    func latest(force: Bool = false, now: Date = .now) async -> ExchangeRateQuote? {
        if !force, let quote, now.timeIntervalSince(quote.fetchedAt) < 6 * 60 * 60 {
            return quote
        }
        do {
            var request = URLRequest(url: endpoint)
            request.timeoutInterval = 10
            request.cachePolicy = .reloadIgnoringLocalCacheData
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                return quote ?? cache.load()
            }
            let fresh = try ExchangeRateParser.decodeUSDToIDR(data, fetchedAt: now)
            quote = fresh
            try? cache.save(fresh)
            return fresh
        } catch {
            return quote ?? cache.load()
        }
    }
}
