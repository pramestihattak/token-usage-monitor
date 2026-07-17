import Foundation

public struct ModelPrice: Codable, Equatable, Sendable {
    public var pattern: String
    public var inputPerMillion: Double
    public var cachedInputPerMillion: Double
    public var cacheCreationPerMillion: Double
    public var outputPerMillion: Double
    public var reasoningPerMillion: Double
    public var validBefore: Date?
    public var validFrom: Date?

    public init(
        pattern: String,
        inputPerMillion: Double,
        cachedInputPerMillion: Double,
        cacheCreationPerMillion: Double,
        outputPerMillion: Double,
        reasoningPerMillion: Double? = nil,
        validBefore: Date? = nil,
        validFrom: Date? = nil
    ) {
        self.pattern = pattern
        self.inputPerMillion = inputPerMillion
        self.cachedInputPerMillion = cachedInputPerMillion
        self.cacheCreationPerMillion = cacheCreationPerMillion
        self.outputPerMillion = outputPerMillion
        self.reasoningPerMillion = reasoningPerMillion ?? outputPerMillion
        self.validBefore = validBefore
        self.validFrom = validFrom
    }

    public func matches(model: String, at date: Date) -> Bool {
        guard model.lowercased().contains(pattern.lowercased()) else { return false }
        if let validBefore, date >= validBefore { return false }
        if let validFrom, date < validFrom { return false }
        return true
    }

    public func estimate(_ usage: TokenUsage) -> Double {
        let million = 1_000_000.0
        return Double(usage.input) * inputPerMillion / million
            + Double(usage.cachedInput) * cachedInputPerMillion / million
            + Double(usage.cacheCreation) * cacheCreationPerMillion / million
            + Double(usage.output) * outputPerMillion / million
    }
}

public struct PricingCatalog: Sendable {
    public static let publishedAt = "2026-07-17"
    public let prices: [ModelPrice]

    public init(prices: [ModelPrice] = PricingCatalog.defaultPrices) {
        self.prices = prices
    }

    public func price(for model: String, at date: Date) -> ModelPrice? {
        prices.first { $0.matches(model: model, at: date) }
    }

    public func estimate(models: [ModelUsage], at date: Date) -> Double? {
        guard !models.isEmpty else { return 0 }
        var total = 0.0
        for usage in models {
            guard let price = price(for: usage.model, at: date) else { return nil }
            total += price.estimate(usage.tokens)
        }
        return total
    }

    public func applyingPrices(to days: [DailyUsage]) -> [DailyUsage] {
        days.map { day in
            var copy = day
            copy.estimatedCostUSD = estimate(models: day.models, at: day.date)
            return copy
        }
    }

    public static let defaultPrices: [ModelPrice] = {
        let calendar = Calendar(identifier: .gregorian)
        let september2026 = calendar.date(from: DateComponents(year: 2026, month: 9, day: 1))!
        return [
            // Anthropic public prices, USD per million tokens. Cache creation uses the
            // one-hour rate because current Claude Code histories predominantly mark it so.
            ModelPrice(pattern: "claude-sonnet-5", inputPerMillion: 2, cachedInputPerMillion: 0.2, cacheCreationPerMillion: 4, outputPerMillion: 10, validBefore: september2026),
            ModelPrice(pattern: "claude-sonnet-5", inputPerMillion: 3, cachedInputPerMillion: 0.3, cacheCreationPerMillion: 6, outputPerMillion: 15, validFrom: september2026),
            ModelPrice(pattern: "claude-sonnet-4-6", inputPerMillion: 3, cachedInputPerMillion: 0.3, cacheCreationPerMillion: 6, outputPerMillion: 15),
            ModelPrice(pattern: "claude-sonnet-4-5", inputPerMillion: 3, cachedInputPerMillion: 0.3, cacheCreationPerMillion: 6, outputPerMillion: 15),
            ModelPrice(pattern: "claude-fable-5", inputPerMillion: 10, cachedInputPerMillion: 1, cacheCreationPerMillion: 20, outputPerMillion: 50),
            ModelPrice(pattern: "claude-opus-4-8", inputPerMillion: 5, cachedInputPerMillion: 0.5, cacheCreationPerMillion: 10, outputPerMillion: 25),
            ModelPrice(pattern: "claude-opus-4-7", inputPerMillion: 5, cachedInputPerMillion: 0.5, cacheCreationPerMillion: 10, outputPerMillion: 25),
            ModelPrice(pattern: "claude-opus-4-6", inputPerMillion: 5, cachedInputPerMillion: 0.5, cacheCreationPerMillion: 10, outputPerMillion: 25),
            ModelPrice(pattern: "claude-haiku-4-5", inputPerMillion: 1, cachedInputPerMillion: 0.1, cacheCreationPerMillion: 2, outputPerMillion: 5),

            // OpenAI public prices. Reasoning tokens are billed as output tokens.
            ModelPrice(pattern: "gpt-5.6-sol", inputPerMillion: 5, cachedInputPerMillion: 0.5, cacheCreationPerMillion: 6.25, outputPerMillion: 30),
            ModelPrice(pattern: "gpt-5.6", inputPerMillion: 5, cachedInputPerMillion: 0.5, cacheCreationPerMillion: 6.25, outputPerMillion: 30),
            ModelPrice(pattern: "gpt-5.5", inputPerMillion: 5, cachedInputPerMillion: 0.5, cacheCreationPerMillion: 6.25, outputPerMillion: 30),
            ModelPrice(pattern: "gpt-5.4", inputPerMillion: 2.5, cachedInputPerMillion: 0.25, cacheCreationPerMillion: 3.125, outputPerMillion: 15),
        ]
    }()
}
