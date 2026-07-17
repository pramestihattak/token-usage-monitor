import Foundation
import Testing
@testable import TokenMonitorCore

@Test func parsesAndConvertsLiveUSDIDRResponse() throws {
    let fetchedAt = DateParsing.iso8601("2026-07-17T00:00:00Z")!
    let data = Data(#"{"date":"2026-07-17","base":"USD","quote":"IDR","rate":18005}"#.utf8)
    let quote = try ExchangeRateParser.decodeUSDToIDR(data, fetchedAt: fetchedAt)
    #expect(quote.rate == 18_005)
    #expect(quote.rateDate == "2026-07-17")
    #expect(quote.convert(usd: 10) == 180_050)
}

@Test func rejectsWrongOrInvalidCurrencyQuote() {
    let wrong = Data(#"{"date":"2026-07-17","base":"EUR","quote":"IDR","rate":20597}"#.utf8)
    let invalid = Data(#"{"date":"2026-07-17","base":"USD","quote":"IDR","rate":0}"#.utf8)
    #expect(throws: MonitorError.self) { try ExchangeRateParser.decodeUSDToIDR(wrong) }
    #expect(throws: MonitorError.self) { try ExchangeRateParser.decodeUSDToIDR(invalid) }
}

@Test func exchangeRateCacheRoundTripsAndIgnoresCorruption() throws {
    let root = try temporaryDirectory()
    let cache = ExchangeRateCache(fileURL: root.appendingPathComponent("nested/rate.json"))
    let quote = ExchangeRateQuote(
        base: "USD",
        quote: "IDR",
        rate: 18_005,
        rateDate: "2026-07-17",
        fetchedAt: Date(timeIntervalSince1970: 1_784_252_800)
    )
    try cache.save(quote)
    #expect(cache.load() == quote)
    try writeFile("not-json", at: cache.fileURL)
    #expect(cache.load() == nil)
}
