import Foundation

public struct ExchangeRateQuote: Codable, Equatable, Sendable {
    public var base: String
    public var quote: String
    public var rate: Double
    public var rateDate: String
    public var fetchedAt: Date

    public init(base: String, quote: String, rate: Double, rateDate: String, fetchedAt: Date = .now) {
        self.base = base
        self.quote = quote
        self.rate = rate
        self.rateDate = rateDate
        self.fetchedAt = fetchedAt
    }

    public func convert(usd: Double) -> Double {
        usd * rate
    }
}

public enum ExchangeRateParser {
    private struct Response: Decodable {
        var date: String
        var base: String
        var quote: String
        var rate: Double
    }

    public static func decodeUSDToIDR(_ data: Data, fetchedAt: Date = .now) throws -> ExchangeRateQuote {
        let response = try JSONDecoder().decode(Response.self, from: data)
        guard response.base == "USD", response.quote == "IDR", response.rate > 0 else {
            throw MonitorError.incompatibleOutput("The exchange-rate service returned an invalid USD/IDR quote.")
        }
        return ExchangeRateQuote(
            base: response.base,
            quote: response.quote,
            rate: response.rate,
            rateDate: response.date,
            fetchedAt: fetchedAt
        )
    }
}

public struct ExchangeRateCache: Sendable {
    public var fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public static func `default`(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> ExchangeRateCache {
        ExchangeRateCache(fileURL: homeDirectory
            .appendingPathComponent("Library/Application Support/Token Monitor", isDirectory: true)
            .appendingPathComponent("exchange-rate.json"))
    }

    public func load() -> ExchangeRateQuote? {
        SecureStorage.hardenExisting(fileURL)
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder.monitorDecoder.decode(ExchangeRateQuote.self, from: data)
    }

    public func save(_ quote: ExchangeRateQuote) throws {
        try SecureStorage.write(JSONEncoder.monitorEncoder.encode(quote), to: fileURL)
    }
}
