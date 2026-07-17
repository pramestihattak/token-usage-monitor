import Foundation

public enum DateParsing {
    public static func iso8601(_ string: String) -> Date? {
        if let value = try? Date(string, strategy: .iso8601) { return value }
        let fractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
        return try? Date(string, strategy: fractional)
    }
}

private struct UsageEvent {
    var id: String
    var timestamp: Date
    var model: String
    var usage: TokenUsage
}

public struct ClaudeHistoryScanner: Sendable {
    public var roots: [URL]

    public init(roots: [URL]? = nil, homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.roots = roots ?? [
            homeDirectory.appendingPathComponent(".config/claude/projects"),
            homeDirectory.appendingPathComponent(".claude/projects"),
        ]
    }

    public func scan(now: Date = .now, calendar: Calendar = .current, days: Int = 30) throws -> [DailyUsage] {
        let cutoff = calendar.date(byAdding: .day, value: -days, to: calendar.startOfDay(for: now)) ?? .distantPast
        var events: [String: UsageEvent] = [:]

        for file in jsonlFiles(under: roots) {
            if let modified = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
               modified < cutoff {
                continue
            }
            guard let contents = BoundedTextFile.read(file) else { continue }
            for line in contents.split(separator: "\n", omittingEmptySubsequences: true) {
                guard let object = jsonObject(line),
                      object["type"] as? String == "assistant",
                      let message = object["message"] as? [String: Any],
                      let usageObject = message["usage"] as? [String: Any],
                      let timestampString = object["timestamp"] as? String,
                      let timestamp = DateParsing.iso8601(timestampString),
                      timestamp >= cutoff else { continue }

                let session = object["sessionId"] as? String ?? file.deletingPathExtension().lastPathComponent
                let messageID = message["id"] as? String
                    ?? object["requestId"] as? String
                    ?? object["uuid"] as? String
                    ?? "\(timestamp.timeIntervalSince1970)"
                let key = "\(session):\(messageID)"
                let model = message["model"] as? String ?? "unknown"
                guard model != "<synthetic>" else { continue }
                events[key] = UsageEvent(
                    id: key,
                    timestamp: timestamp,
                    model: model,
                    usage: TokenUsage(
                        input: int64(usageObject["input_tokens"]),
                        cachedInput: int64(usageObject["cache_read_input_tokens"]),
                        cacheCreation: int64(usageObject["cache_creation_input_tokens"]),
                        output: int64(usageObject["output_tokens"])
                    )
                )
            }
        }
        return aggregate(Array(events.values), calendar: calendar)
    }

    public func recentWorkingDirectory() -> URL? {
        let files = jsonlFiles(under: roots).compactMap { file -> (URL, Date)? in
            let modified = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            return (file, modified ?? .distantPast)
        }.sorted { $0.1 > $1.1 }

        for (file, _) in files.prefix(25) {
            guard let handle = try? FileHandle(forReadingFrom: file),
                  let data = try? handle.read(upToCount: 262_144) else { continue }
            let text = String(decoding: data, as: UTF8.self)
            try? handle.close()
            for line in text.split(separator: "\n") {
                guard let object = jsonObject(line), let path = object["cwd"] as? String else { continue }
                var isDirectory: ObjCBool = false
                if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue {
                    return URL(fileURLWithPath: path, isDirectory: true)
                }
            }
        }
        return nil
    }
}

private struct CodexCounterEvent {
    var timestamp: Date
    var model: String
    var raw: TokenUsage
}

private struct CodexSession {
    var id: String
    var modifiedAt: Date
    var events: [CodexCounterEvent]
}

public struct CodexHistoryScanner: Sendable {
    public var roots: [URL]

    public init(roots: [URL]? = nil, homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        let codexHome = ProcessInfo.processInfo.environment["CODEX_HOME"].map {
            URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath)
        } ?? homeDirectory.appendingPathComponent(".codex")
        self.roots = roots ?? [
            codexHome.appendingPathComponent("sessions"),
            codexHome.appendingPathComponent("archived_sessions"),
        ]
    }

    public func scan(now: Date = .now, calendar: Calendar = .current, days: Int = 30) throws -> [DailyUsage] {
        let cutoff = calendar.date(byAdding: .day, value: -days, to: calendar.startOfDay(for: now)) ?? .distantPast
        var sessions: [String: CodexSession] = [:]

        for file in jsonlFiles(under: roots) {
            guard let contents = BoundedTextFile.read(file) else { continue }
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            var sessionID = file.deletingPathExtension().lastPathComponent
            var currentModel = "unknown"
            var counters: [CodexCounterEvent] = []

            for line in contents.split(separator: "\n", omittingEmptySubsequences: true) {
                guard let object = jsonObject(line) else { continue }
                let type = object["type"] as? String
                let payload = object["payload"] as? [String: Any]
                if type == "session_meta", let id = payload?["id"] as? String { sessionID = id }
                if type == "turn_context", let model = payload?["model"] as? String { currentModel = model }
                guard type == "event_msg",
                      payload?["type"] as? String == "token_count",
                      let info = payload?["info"] as? [String: Any],
                      let total = info["total_token_usage"] as? [String: Any],
                      let timestampString = object["timestamp"] as? String,
                      let timestamp = DateParsing.iso8601(timestampString),
                      timestamp >= cutoff else { continue }

                let cached = int64(total["cached_input_tokens"])
                let cacheWrite = int64(total["cache_write_input_tokens"])
                let reportedInput = int64(total["input_tokens"])
                counters.append(CodexCounterEvent(
                    timestamp: timestamp,
                    model: currentModel,
                    raw: TokenUsage(
                        input: max(0, reportedInput - cached - cacheWrite),
                        cachedInput: cached,
                        cacheCreation: cacheWrite,
                        output: int64(total["output_tokens"]),
                        reasoning: int64(total["reasoning_output_tokens"])
                    )
                ))
            }

            guard !counters.isEmpty else { continue }
            let candidate = CodexSession(id: sessionID, modifiedAt: modified, events: counters)
            if sessions[sessionID] == nil || modified > sessions[sessionID]!.modifiedAt {
                sessions[sessionID] = candidate
            }
        }

        var normalized: [UsageEvent] = []
        for session in sessions.values {
            var previous: TokenUsage?
            for (index, counter) in session.events.sorted(by: { $0.timestamp < $1.timestamp }).enumerated() {
                let delta: TokenUsage
                if let previous, !counterReset(from: previous, to: counter.raw) {
                    delta = counter.raw - previous
                } else {
                    delta = counter.raw
                }
                previous = counter.raw
                guard delta.total > 0 else { continue }
                normalized.append(UsageEvent(
                    id: "\(session.id):\(index)",
                    timestamp: counter.timestamp,
                    model: counter.model,
                    usage: delta
                ))
            }
        }
        return aggregate(normalized, calendar: calendar)
    }
}

private func counterReset(from old: TokenUsage, to new: TokenUsage) -> Bool {
    new.input < old.input
        || new.cachedInput < old.cachedInput
        || new.cacheCreation < old.cacheCreation
        || new.output < old.output
        || new.reasoning < old.reasoning
}

private func aggregate(_ events: [UsageEvent], calendar: Calendar) -> [DailyUsage] {
    var buckets: [Date: [String: TokenUsage]] = [:]
    for event in events {
        let day = calendar.startOfDay(for: event.timestamp)
        buckets[day, default: [:]][event.model, default: TokenUsage()] =
            buckets[day, default: [:]][event.model, default: TokenUsage()] + event.usage
    }
    return buckets.keys.sorted().map { day in
        let models = buckets[day, default: [:]].keys.sorted().map { model in
            ModelUsage(model: model, tokens: buckets[day]![model]!)
        }
        return DailyUsage(date: day, models: models)
    }
}

private func jsonlFiles(under roots: [URL]) -> [URL] {
    let manager = FileManager.default
    let keys: [URLResourceKey] = [.isRegularFileKey, .contentModificationDateKey]
    var result: Set<URL> = []
    for root in roots where manager.fileExists(atPath: root.path) {
        let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL
        let rootPrefix = resolvedRoot.path.hasSuffix("/") ? resolvedRoot.path : resolvedRoot.path + "/"
        guard let enumerator = manager.enumerator(
            at: resolvedRoot,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { continue }
        for case let candidate as URL in enumerator where candidate.pathExtension == "jsonl" {
            let file = candidate.resolvingSymlinksInPath().standardizedFileURL
            guard file.path.hasPrefix(rootPrefix),
                  (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
                continue
            }
            result.insert(file)
        }
    }
    return Array(result)
}

enum BoundedTextFile {
    static let maximumBytes = 256 * 1_024 * 1_024

    static func read(_ url: URL) -> String? {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true,
              let size = values.fileSize,
              size <= maximumBytes,
              let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }
}

private func jsonObject(_ line: Substring) -> [String: Any]? {
    guard let data = String(line).data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
    return object
}

private func int64(_ value: Any?) -> Int64 {
    if let value = value as? NSNumber { return value.int64Value }
    if let value = value as? Int64 { return value }
    if let value = value as? Int { return Int64(value) }
    if let value = value as? String { return Int64(value) ?? 0 }
    return 0
}
