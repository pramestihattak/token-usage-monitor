import Darwin
import Foundation

public struct CodexQuotaCollector: Sendable {
    public var executable: URL
    public var historyRoots: [URL]
    public var timeout: TimeInterval

    public init(executable: URL, historyRoots: [URL], timeout: TimeInterval = 12) {
        self.executable = executable
        self.historyRoots = historyRoots
        self.timeout = timeout
    }

    public func fetch() async throws -> [QuotaWindow] {
        do {
            return try await Task.detached {
                let requests = [
                    #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"clientInfo":{"name":"token-monitor","version":"1.0"},"capabilities":{}}}"#,
                    #"{"jsonrpc":"2.0","method":"initialized"}"#,
                    #"{"jsonrpc":"2.0","id":2,"method":"account/rateLimits/read","params":null}"#,
                ].joined(separator: "\n") + "\n"
                let output = try ProcessRunner.run(
                    executable: executable,
                    arguments: ["app-server", "--listen", "stdio://"],
                    input: requests,
                    timeout: timeout
                )
                return try CodexQuotaParser.parseAppServer(output.stdout)
            }.value
        } catch {
            if let fallback = CodexQuotaLogScanner(roots: historyRoots).latest() {
                return fallback
            }
            throw error
        }
    }
}

public enum CodexQuotaParser {
    public static func parseAppServer(_ text: String) throws -> [QuotaWindow] {
        for line in text.split(separator: "\n") {
            guard let data = String(line).data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  (object["id"] as? NSNumber)?.intValue == 2,
                  let result = object["result"] as? [String: Any],
                  let limits = result["rateLimits"] as? [String: Any] else { continue }
            let windows = windows(from: limits, camelCase: true)
            if !windows.isEmpty { return windows }
        }
        throw MonitorError.incompatibleOutput("Codex returned no recognizable quota windows.")
    }

    static func windows(from limits: [String: Any], camelCase: Bool) -> [QuotaWindow] {
        let primaryKey = "primary"
        let secondaryKey = "secondary"
        var result: [QuotaWindow] = []
        if let primary = limits[primaryKey] as? [String: Any],
           let window = window(from: primary, fallbackKind: .session, fallbackLabel: "Session", camelCase: camelCase) {
            result.append(window)
        }
        if let secondary = limits[secondaryKey] as? [String: Any],
           let window = window(from: secondary, fallbackKind: .weekly, fallbackLabel: "Weekly", camelCase: camelCase) {
            result.append(window)
        }
        return result
    }

    private static func window(
        from object: [String: Any],
        fallbackKind: QuotaKind,
        fallbackLabel: String,
        camelCase: Bool
    ) -> QuotaWindow? {
        let usedKey = camelCase ? "usedPercent" : "used_percent"
        let minutesKey = camelCase ? "windowDurationMins" : "window_minutes"
        let resetKey = camelCase ? "resetsAt" : "resets_at"
        guard let used = number(object[usedKey]) else { return nil }
        let minutes = number(object[minutesKey]).map(Int.init)
        let resets = number(object[resetKey]).map { Date(timeIntervalSince1970: $0) }
        let kind: QuotaKind
        if let minutes, minutes <= 360 { kind = .session }
        else if let minutes, minutes >= 6 * 24 * 60 { kind = .weekly }
        else { kind = fallbackKind }
        return QuotaWindow(
            kind: kind,
            label: kind == .session ? "Session" : (kind == .weekly ? "Weekly" : fallbackLabel),
            usedPercent: min(100, max(0, used)),
            windowMinutes: minutes,
            resetsAt: resets
        )
    }
}

public struct CodexQuotaLogScanner: Sendable {
    public var roots: [URL]

    public init(roots: [URL]) {
        self.roots = roots
    }

    public func latest() -> [QuotaWindow]? {
        let manager = FileManager.default
        var files: [(URL, Date)] = []
        for root in roots where manager.fileExists(atPath: root.path) {
            guard let enumerator = manager.enumerator(
                at: root,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for case let file as URL in enumerator where file.pathExtension == "jsonl" {
                let date = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                files.append((file, date))
            }
        }
        for (file, _) in files.sorted(by: { $0.1 > $1.1 }).prefix(20) {
            guard let contents = try? String(contentsOf: file, encoding: .utf8) else { continue }
            for line in contents.split(separator: "\n").reversed() {
                guard line.contains("\"rate_limits\"") || line.contains("\"rateLimits\"") else { continue }
                guard let data = String(line).data(using: .utf8),
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let payload = object["payload"] as? [String: Any],
                      let limits = (payload["rate_limits"] ?? payload["rateLimits"]) as? [String: Any] else { continue }
                let windows = CodexQuotaParser.windows(from: limits, camelCase: payload["rateLimits"] != nil)
                if !windows.isEmpty { return windows }
            }
        }
        return nil
    }
}

public struct ClaudeQuotaCollector: Sendable {
    public var executable: URL
    public var timeout: TimeInterval
    public var workingDirectory: URL

    public init(
        executable: URL,
        timeout: TimeInterval = 15,
        workingDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        self.executable = executable
        self.timeout = timeout
        self.workingDirectory = workingDirectory
    }

    public func fetch() async throws -> [QuotaWindow] {
        try await Task.detached {
            let output = try PTYRunner.runClaudeUsage(
                executable: executable,
                workingDirectory: workingDirectory,
                timeout: timeout
            )
            return try ClaudeUsageParser.parse(output, now: .now)
        }.value
    }
}

public enum ClaudeUsageParser {
    public static func parse(_ rawText: String, now: Date = .now) throws -> [QuotaWindow] {
        let text = stripTerminalCodes(rawText)
        let lines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let lowerText = text.lowercased()
        var windows: [QuotaWindow] = []
        for (index, line) in lines.enumerated() {
            let lower = line.lowercased()
            let isWeekly = lower.contains("week") || lower.contains("7 day") || lower.contains("7-day")
            let isSession = lower.contains("session") || lower.contains("5 hour") || lower.contains("5-hour")
            guard isWeekly || isSession else { continue }
            let neighborhood = lines[index..<min(lines.count, index + 6)].joined(separator: " ")
            guard let percent = usedPercent(in: neighborhood) else { continue }
            let kind: QuotaKind = isWeekly ? .weekly : .session
            if windows.contains(where: { $0.kind == kind }) { continue }
            windows.append(QuotaWindow(
                kind: kind,
                label: kind == .weekly ? "Weekly" : "Session",
                usedPercent: max(0, percent),
                windowMinutes: kind == .weekly ? 10_080 : 300,
                resetsAt: parseReset(in: neighborhood, now: now)
            ))
        }

        if windows.isEmpty {
            if lowerText.contains("api usage billing") || (lowerText.contains("total cost:") && lowerText.contains("cache write")) {
                return []
            }
            if lowerText.contains("authentication required") || lowerText.contains("please log in to claude") || lowerText.contains("unauthorized") {
                throw MonitorError.commandFailed("Claude Code is not signed in. Run `claude` and authenticate first.")
            }
            throw MonitorError.incompatibleOutput("Claude Code returned an unrecognized `/usage` screen.")
        }
        return windows.sorted { $0.kind == .session && $1.kind != .session }
    }

    public static func stripTerminalCodes(_ text: String) -> String {
        let patterns = [
            #"\u001B\[[0-?]*[ -/]*[@-~]"#,
            #"\u001B\][^\u0007]*(?:\u0007|\u001B\\)"#,
            #"[\u0000-\u0008\u000B\u000C\u000E-\u001F\u007F]"#,
        ]
        return patterns.reduce(text) { result, pattern in
            result.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
    }

    private static func usedPercent(in text: String) -> Double? {
        if let match = text.firstMatch(of: /(?i:([0-9]{1,3}(?:\.[0-9]+)?)\s*%\s*used)/) {
            return Double(match.1)
        }
        guard let match = text.firstMatch(of: /([0-9]{1,3}(?:\.[0-9]+)?)\s*%/) else { return nil }
        return Double(match.1)
    }

    private static func parseReset(in text: String, now: Date) -> Date? {
        let lower = text.lowercased()
        guard let resetRange = lower.range(of: "reset") else { return nil }
        var tail = String(lower[resetRange.lowerBound...])
        for boundary in [" current ", " weekly ", " session "] {
            if let range = tail.range(of: boundary) {
                tail = String(tail[..<range.lowerBound])
            }
        }
        var seconds: TimeInterval = 0
        if let days = tail.firstMatch(of: /([0-9]+)\s*d(?:ay)?s?/) { seconds += (Double(days.1) ?? 0) * 86_400 }
        if let hours = tail.firstMatch(of: /([0-9]+)\s*h(?:our)?s?/) { seconds += (Double(hours.1) ?? 0) * 3_600 }
        if let minutes = tail.firstMatch(of: /([0-9]+)\s*m(?:in(?:ute)?)?s?/) { seconds += (Double(minutes.1) ?? 0) * 60 }
        return seconds > 0 ? now.addingTimeInterval(seconds) : nil
    }
}

struct ProcessOutput: Sendable {
    var stdout: String
    var stderr: String
    var exitCode: Int32
}

enum ProcessRunner {
    static func run(
        executable: URL,
        arguments: [String],
        input: String? = nil,
        timeout: TimeInterval
    ) throws -> ProcessOutput {
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        let stdin = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = stdin
        try process.run()
        if let input, let data = input.data(using: .utf8) {
            try stdin.fileHandleForWriting.write(contentsOf: data)
        }
        try? stdin.fileHandleForWriting.close()

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline { usleep(50_000) }
        if process.isRunning {
            process.terminate()
            usleep(100_000)
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            throw MonitorError.commandTimedOut(executable.lastPathComponent)
        }
        let outputData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errorData = stderr.fileHandleForReading.readDataToEndOfFile()
        let result = ProcessOutput(
            stdout: String(decoding: outputData, as: UTF8.self),
            stderr: String(decoding: errorData, as: UTF8.self),
            exitCode: process.terminationStatus
        )
        if result.exitCode != 0 && result.stdout.isEmpty {
            throw MonitorError.commandFailed(result.stderr.isEmpty ? "\(executable.lastPathComponent) exited with code \(result.exitCode)." : result.stderr)
        }
        return result
    }
}

enum PTYRunner {
    static func runClaudeUsage(executable: URL, workingDirectory: URL, timeout: TimeInterval) throws -> String {
        var master: Int32 = 0
        var slave: Int32 = 0
        var size = winsize(ws_row: 45, ws_col: 180, ws_xpixel: 0, ws_ypixel: 0)
        guard openpty(&master, &slave, nil, nil, &size) == 0 else {
            throw MonitorError.commandFailed("Unable to create a terminal for Claude Code.")
        }
        defer { close(master) }

        let process = Process()
        process.executableURL = executable
        process.arguments = ["--safe-mode", "--ax-screen-reader"]
        process.currentDirectoryURL = workingDirectory
        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "xterm-256color"
        environment["NO_COLOR"] = "1"
        process.environment = environment
        let slaveHandle = FileHandle(fileDescriptor: slave, closeOnDealloc: true)
        process.standardInput = slaveHandle
        process.standardOutput = slaveHandle
        process.standardError = slaveHandle
        try process.run()
        try? slaveHandle.close()
        _ = fcntl(master, F_SETFL, fcntl(master, F_GETFL) | O_NONBLOCK)

        var data = Data()
        let readinessDeadline = Date().addingTimeInterval(min(4, timeout / 2))
        while Date() < readinessDeadline && process.isRunning {
            readAvailable(from: master, into: &data)
            let current = ClaudeUsageParser.stripTerminalCodes(String(decoding: data, as: UTF8.self)).lowercased()
            if current.contains("effort:") || current.contains("manual mode") || current.contains("permission required") {
                break
            }
            usleep(80_000)
        }
        let commandOutputOffset = data.count
        writeString("/usage\r", to: master)
        let deadline = Date().addingTimeInterval(timeout)
        var parsed = false
        while Date() < deadline && process.isRunning {
            readAvailable(from: master, into: &data)
            let current = String(decoding: data.dropFirst(commandOutputOffset), as: UTF8.self)
            if (try? ClaudeUsageParser.parse(current)) != nil {
                parsed = true
                break
            }
            usleep(80_000)
        }
        readAvailable(from: master, into: &data)
        writeString("/exit\r", to: master)
        usleep(250_000)
        if process.isRunning { process.terminate() }
        let output = String(decoding: data.dropFirst(commandOutputOffset), as: UTF8.self)
        if !parsed && Date() >= deadline { throw MonitorError.commandTimedOut("Claude Code") }
        return output
    }

    private static func writeString(_ string: String, to descriptor: Int32) {
        let bytes = Array(string.utf8)
        bytes.withUnsafeBytes { buffer in
            _ = Darwin.write(descriptor, buffer.baseAddress, buffer.count)
        }
    }

    private static func readAvailable(from descriptor: Int32, into data: inout Data) {
        var buffer = [UInt8](repeating: 0, count: 8_192)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count > 0 { data.append(contentsOf: buffer[0..<count]) }
            else { break }
        }
    }
}

private func number(_ value: Any?) -> Double? {
    if let value = value as? NSNumber { return value.doubleValue }
    if let value = value as? Double { return value }
    if let value = value as? Int { return Double(value) }
    if let value = value as? String { return Double(value) }
    return nil
}
