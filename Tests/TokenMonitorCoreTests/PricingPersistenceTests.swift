import Foundation
import Testing
@testable import TokenMonitorCore

@Test func pricingUsesEffectiveDatedSonnetRateAndDoesNotDoubleCountReasoning() {
    let catalog = PricingCatalog()
    let july = DateParsing.iso8601("2026-07-17T00:00:00Z")!
    let usage = ModelUsage(
        model: "claude-sonnet-5",
        tokens: TokenUsage(input: 1_000_000, cachedInput: 1_000_000, cacheCreation: 1_000_000, output: 1_000_000, reasoning: 500_000)
    )
    #expect(catalog.estimate(models: [usage], at: july) == 16.2)

    let gpt = ModelUsage(model: "gpt-5.6-sol", tokens: TokenUsage(output: 1_000_000, reasoning: 500_000))
    #expect(catalog.estimate(models: [gpt], at: july) == 30)
}

@Test func unknownModelHasUnavailablePrice() {
    let catalog = PricingCatalog()
    let usage = ModelUsage(model: "future-model", tokens: TokenUsage(input: 100))
    #expect(catalog.estimate(models: [usage], at: .now) == nil)
}

@Test func cacheRoundTripsAndRecoversFromCorruption() throws {
    let root = try temporaryDirectory()
    let cache = SnapshotCache(fileURL: root.appendingPathComponent("nested/snapshots.json"))
    let snapshot = UsageSnapshot(
        provider: .claude,
        source: "test",
        quotaWindows: [QuotaWindow(kind: .session, label: "Session", usedPercent: 5)],
        updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
    try cache.save([snapshot])
    #expect(cache.load() == [snapshot])
    let directoryPermissions = try FileManager.default
        .attributesOfItem(atPath: cache.fileURL.deletingLastPathComponent().path)[.posixPermissions] as? NSNumber
    let filePermissions = try FileManager.default
        .attributesOfItem(atPath: cache.fileURL.path)[.posixPermissions] as? NSNumber
    #expect(directoryPermissions?.intValue == 0o700)
    #expect(filePermissions?.intValue == 0o600)
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o755],
        ofItemAtPath: cache.fileURL.deletingLastPathComponent().path
    )
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: cache.fileURL.path)
    #expect(cache.load() == [snapshot])
    let migratedDirectoryPermissions = try FileManager.default
        .attributesOfItem(atPath: cache.fileURL.deletingLastPathComponent().path)[.posixPermissions] as? NSNumber
    let migratedFilePermissions = try FileManager.default
        .attributesOfItem(atPath: cache.fileURL.path)[.posixPermissions] as? NSNumber
    #expect(migratedDirectoryPermissions?.intValue == 0o700)
    #expect(migratedFilePermissions?.intValue == 0o600)
    try writeFile("not json", at: cache.fileURL)
    #expect(cache.load().isEmpty)
}

@Test func notificationsAreDeliveredOncePerResetWindow() {
    let reset = DateParsing.iso8601("2026-07-18T00:00:00Z")!
    let snapshot = UsageSnapshot(provider: .codex, source: "test", quotaWindows: [
        QuotaWindow(kind: .session, label: "Session", usedPercent: 96, resetsAt: reset),
    ])
    var deduplicator = NotificationDeduplicator()
    #expect(deduplicator.newEvents(for: [snapshot]).map(\.threshold) == [80, 95])
    #expect(deduplicator.newEvents(for: [snapshot]).isEmpty)

    var next = snapshot
    next.quotaWindows[0].resetsAt = reset.addingTimeInterval(300)
    #expect(deduplicator.newEvents(for: [next]).count == 2)
}

@Test func executableLocatorUsesOverrideAndKnownPaths() throws {
    let root = try temporaryDirectory()
    let executable = try writeFile("#!/bin/sh\n", at: root.appendingPathComponent("custom-claude"), executable: true)
    let locator = ExecutableLocator(environmentPath: "", homeDirectory: root)
    #expect(locator.locate(.claude, override: executable.path) == executable)
}

@Test func executableLocatorPrefersKnownSafePathAndRejectsWritableExecutables() throws {
    let root = try temporaryDirectory()
    let known = try writeFile("#!/bin/sh\n", at: root.appendingPathComponent(".local/bin/claude"), executable: true)
    let pathDirectory = root.appendingPathComponent("path-bin")
    let pathExecutable = try writeFile("#!/bin/sh\n", at: pathDirectory.appendingPathComponent("claude"), executable: true)
    try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: pathExecutable.path)

    let locator = ExecutableLocator(environmentPath: pathDirectory.path, homeDirectory: root)
    #expect(locator.locate(.claude) == known)

    try FileManager.default.removeItem(at: known)
    #expect(locator.locate(.claude) == nil)
}
