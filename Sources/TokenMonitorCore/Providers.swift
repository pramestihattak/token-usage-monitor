import Foundation

public struct ClaudeUsageProvider: UsageProvider {
    public let providerID: ProviderID = .claude
    public var executable: URL?
    public var historyScanner: ClaudeHistoryScanner
    public var timeout: TimeInterval

    public init(executable: URL?, historyScanner: ClaudeHistoryScanner = .init(), timeout: TimeInterval = 15) {
        self.executable = executable
        self.historyScanner = historyScanner
        self.timeout = timeout
    }

    public func fetchQuota() async throws -> [QuotaWindow] {
        guard let executable else { throw MonitorError.executableMissing("Claude Code") }
        return try await ClaudeQuotaCollector(
            executable: executable,
            timeout: timeout,
            workingDirectory: historyScanner.recentWorkingDirectory() ?? FileManager.default.homeDirectoryForCurrentUser
        ).fetch()
    }

    public func scanHistory(now: Date, calendar: Calendar) async throws -> [DailyUsage] {
        let scanner = historyScanner
        return try await Task.detached { try scanner.scan(now: now, calendar: calendar) }.value
    }
}

public struct CodexUsageProvider: UsageProvider {
    public let providerID: ProviderID = .codex
    public var executable: URL?
    public var historyScanner: CodexHistoryScanner
    public var timeout: TimeInterval

    public init(executable: URL?, historyScanner: CodexHistoryScanner = .init(), timeout: TimeInterval = 12) {
        self.executable = executable
        self.historyScanner = historyScanner
        self.timeout = timeout
    }

    public func fetchQuota() async throws -> [QuotaWindow] {
        guard let executable else {
            if let fallback = CodexQuotaLogScanner(roots: historyScanner.roots).latest() { return fallback }
            throw MonitorError.executableMissing("Codex")
        }
        return try await CodexQuotaCollector(
            executable: executable,
            historyRoots: historyScanner.roots,
            timeout: timeout
        ).fetch()
    }

    public func scanHistory(now: Date, calendar: Calendar) async throws -> [DailyUsage] {
        let scanner = historyScanner
        return try await Task.detached { try scanner.scan(now: now, calendar: calendar) }.value
    }
}

public extension UsageSnapshot {
    func usage(lastDays days: Int, now: Date = .now, calendar: Calendar = .current) -> TokenUsage {
        let start = calendar.date(byAdding: .day, value: -(max(1, days) - 1), to: calendar.startOfDay(for: now)) ?? .distantPast
        return dailyUsage.filter { $0.date >= start }.reduce(TokenUsage()) { $0 + $1.tokens }
    }

    func estimatedCost(lastDays days: Int, now: Date = .now, calendar: Calendar = .current) -> Double? {
        let start = calendar.date(byAdding: .day, value: -(max(1, days) - 1), to: calendar.startOfDay(for: now)) ?? .distantPast
        let values = dailyUsage.filter { $0.date >= start }.map(\.estimatedCostUSD)
        guard !values.isEmpty, values.allSatisfy({ $0 != nil }) else { return nil }
        return values.compactMap { $0 }.reduce(0, +)
    }
}
