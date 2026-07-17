import Foundation
import Testing
@testable import TokenMonitorCore

@Test func claudeHistoryDeduplicatesMessagesAndIncludesSubagents() throws {
    let root = try temporaryDirectory()
    let main = root.appendingPathComponent("project/session.jsonl")
    let subagent = root.appendingPathComponent("project/session/subagents/agent.jsonl")
    let repeated = #"{"type":"assistant","sessionId":"s1","requestId":"r1","timestamp":"2026-07-17T01:00:00.000Z","message":{"id":"m1","model":"claude-sonnet-5","usage":{"input_tokens":10,"cache_read_input_tokens":20,"cache_creation_input_tokens":30,"output_tokens":40}}}"#
    let synthetic = #"{"type":"assistant","sessionId":"s1","timestamp":"2026-07-17T01:30:00Z","message":{"id":"synthetic","model":"<synthetic>","usage":{"input_tokens":9999,"output_tokens":9999}}}"#
    try writeFile(repeated + "\n" + repeated + "\n" + synthetic + "\n{malformed\n", at: main)
    try writeFile(#"{"type":"assistant","sessionId":"s1","timestamp":"2026-07-17T02:00:00Z","message":{"id":"m2","model":"claude-sonnet-5","usage":{"input_tokens":1,"cache_read_input_tokens":2,"cache_creation_input_tokens":3,"output_tokens":4}}}"# + "\n", at: subagent)

    let now = DateParsing.iso8601("2026-07-17T12:00:00Z")!
    let result = try ClaudeHistoryScanner(roots: [root]).scan(now: now, calendar: utcCalendar())
    #expect(result.count == 1)
    #expect(result[0].tokens == TokenUsage(input: 11, cachedInput: 22, cacheCreation: 33, output: 44))
    #expect(result[0].tokens.total == 110)
}

@Test func codexHistoryUsesCounterDeltasAndDeduplicatesArchives() throws {
    let root = try temporaryDirectory()
    let active = root.appendingPathComponent("sessions/rollout.jsonl")
    let archived = root.appendingPathComponent("archived/rollout.jsonl")
    let fixture = [
        #"{"timestamp":"2026-07-17T00:00:00Z","type":"session_meta","payload":{"id":"same-session"}}"#,
        #"{"timestamp":"2026-07-17T00:00:01Z","type":"turn_context","payload":{"model":"gpt-5.6-sol"}}"#,
        #"{"timestamp":"2026-07-17T00:01:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"cached_input_tokens":20,"cache_write_input_tokens":0,"output_tokens":10,"reasoning_output_tokens":5}}}}"#,
        #"{"timestamp":"2026-07-17T00:02:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":160,"cached_input_tokens":50,"cache_write_input_tokens":0,"output_tokens":25,"reasoning_output_tokens":7}}}}"#,
        #"{"timestamp":"2026-07-17T00:03:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":10,"cached_input_tokens":0,"cache_write_input_tokens":0,"output_tokens":2,"reasoning_output_tokens":1}}}}"#,
    ].joined(separator: "\n") + "\n"
    try writeFile(fixture, at: active)
    try writeFile(fixture, at: archived)

    let now = DateParsing.iso8601("2026-07-17T12:00:00Z")!
    let result = try CodexHistoryScanner(roots: [root.appendingPathComponent("sessions"), root.appendingPathComponent("archived")])
        .scan(now: now, calendar: utcCalendar())
    #expect(result.count == 1)
    #expect(result[0].tokens.input == 120)
    #expect(result[0].tokens.cachedInput == 50)
    #expect(result[0].tokens.output == 27)
    #expect(result[0].tokens.reasoning == 8)
    #expect(result[0].tokens.total == 197)
}

@Test func historyAggregationHonorsCalendarDayBoundaries() throws {
    let root = try temporaryDirectory()
    let fixture = [
        #"{"type":"assistant","sessionId":"s","timestamp":"2026-07-16T23:59:59Z","message":{"id":"a","model":"claude-sonnet-5","usage":{"input_tokens":1,"output_tokens":1}}}"#,
        #"{"type":"assistant","sessionId":"s","timestamp":"2026-07-17T00:00:01Z","message":{"id":"b","model":"claude-sonnet-5","usage":{"input_tokens":2,"output_tokens":2}}}"#,
    ].joined(separator: "\n")
    try writeFile(fixture, at: root.appendingPathComponent("session.jsonl"))
    let now = DateParsing.iso8601("2026-07-17T12:00:00Z")!
    let result = try ClaudeHistoryScanner(roots: [root]).scan(now: now, calendar: utcCalendar())
    #expect(result.count == 2)
    #expect(result.map(\.tokens.total) == [2, 4])
}

@Test func claudeScannerFindsARecentTrustedWorkingDirectory() throws {
    let root = try temporaryDirectory()
    let project = root.appendingPathComponent("trusted-project")
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    let fixture = #"{"type":"assistant","cwd":"\#(project.path)","sessionId":"s","timestamp":"2026-07-17T00:00:00Z","message":{"id":"m","model":"claude-sonnet-5","usage":{"input_tokens":1}}}"#
    try writeFile(fixture, at: root.appendingPathComponent("history/session.jsonl"))
    #expect(ClaudeHistoryScanner(roots: [root.appendingPathComponent("history")]).recentWorkingDirectory()?.path == project.path)
}
