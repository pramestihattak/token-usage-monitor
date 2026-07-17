import Foundation
import Testing
@testable import TokenMonitorCore

@Test func parsesCodexAppServerRateLimits() throws {
    let response = #"{"jsonrpc":"2.0","id":2,"result":{"rateLimits":{"primary":{"usedPercent":42,"windowDurationMins":300,"resetsAt":1784257200},"secondary":{"usedPercent":17,"windowDurationMins":10080,"resetsAt":1784858400}}}}"#
    let result = try CodexQuotaParser.parseAppServer(response)
    #expect(result.count == 2)
    #expect(result[0].kind == .session)
    #expect(result[0].usedPercent == 42)
    #expect(result[1].kind == .weekly)
}

@Test func codexCollectorFallsBackToLatestHistoryRateLimit() async throws {
    let root = try temporaryDirectory()
    let fake = try writeFile("#!/bin/sh\necho broken >&2\nexit 1\n", at: root.appendingPathComponent("codex"), executable: true)
    let log = #"{"timestamp":"2026-07-17T01:00:00Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":31,"window_minutes":300,"resets_at":1784257200},"secondary":{"used_percent":9,"window_minutes":10080,"resets_at":1784858400}}}}"#
    try writeFile(log, at: root.appendingPathComponent("history/session.jsonl"))
    let result = try await CodexQuotaCollector(executable: fake, historyRoots: [root.appendingPathComponent("history")], timeout: 5).fetch()
    #expect(result.map(\.usedPercent) == [31, 9])
}

@Test func codexCollectorUsesFakeAppServer() async throws {
    let root = try temporaryDirectory()
    let response = #"{"jsonrpc":"2.0","id":2,"result":{"rateLimits":{"primary":{"usedPercent":12,"windowDurationMins":300}}}}"#
    let fake = try writeFile("#!/bin/sh\nprintf '%s\\n' '\(response)'\n", at: root.appendingPathComponent("codex"), executable: true)
    let result = try await CodexQuotaCollector(executable: fake, historyRoots: [], timeout: 5).fetch()
    #expect(result.first?.usedPercent == 12)
}

@Test func parsesClaudeTerminalTranscriptAndRelativeReset() throws {
    let now = DateParsing.iso8601("2026-07-17T00:00:00Z")!
    let transcript = "\u{001B}[32mCurrent session (5 hours)\u{001B}[0m\n42% used · Resets in 2 hours 15 minutes\nCurrent week (7 days)\n81% used · Resets in 3 days"
    let result = try ClaudeUsageParser.parse(transcript, now: now)
    #expect(result.count == 2)
    #expect(result[0].usedPercent == 42)
    #expect(result[0].resetsAt == now.addingTimeInterval(8_100))
    #expect(result[1].usedPercent == 81)
    #expect(result[1].resetsAt == now.addingTimeInterval(259_200))
}

@Test func claudeParserReportsAuthenticationFailure() {
    do {
        _ = try ClaudeUsageParser.parse("Authentication required. Please log in.")
        Issue.record("Expected parser to reject authentication output")
    } catch let error as MonitorError {
        #expect(error.errorDescription?.contains("not signed in") == true)
    } catch {
        Issue.record("Unexpected error: \(error)")
    }
}

@Test func claudeAPIUsageBillingIsAValidQuotaFreeState() throws {
    let transcript = "Claude Code · API Usage Billing\nSettings Status Config Usage Stats\nSession\nTotal cost: $1.25\nUsage: 10 input, 20 output, 30 cache read, 40 cache write"
    #expect(try ClaudeUsageParser.parse(transcript).isEmpty)
}

@Test func claudeProUsagePrefersQuotaRowsOverSessionCostAndPreservesOverage() throws {
    let transcript = """
    Settings Status Config Usage Stats
    Session
    Total cost: $0.0000
    Usage: 0 input, 0 output, 0 cache read, 0 cache write
    Current session
    100% 108% used
    Resets 11:40am (Asia/Jakarta)
    Current week (all models)
    32% 32% used
    Resets Jul 21 at 8am (Asia/Jakarta)
    Usage credits are off
    """
    let result = try ClaudeUsageParser.parse(transcript)
    #expect(result.count == 2)
    #expect(result[0].kind == .session)
    #expect(result[0].usedPercent == 108)
    #expect(result[1].kind == .weekly)
    #expect(result[1].usedPercent == 32)
}
