import Foundation

public enum ProviderID: String, Codable, CaseIterable, Sendable, Identifiable {
    case claude
    case codex

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .claude: "Claude"
        case .codex: "Codex"
        }
    }

    public var shortName: String {
        switch self {
        case .claude: "C"
        case .codex: "O"
        }
    }
}

public enum QuotaKind: String, Codable, Sendable {
    case session
    case weekly
    case other
}

public struct QuotaWindow: Codable, Equatable, Sendable, Identifiable {
    public var kind: QuotaKind
    public var label: String
    public var usedPercent: Double
    public var windowMinutes: Int?
    public var resetsAt: Date?

    public var id: String { "\(kind.rawValue)-\(label)" }

    public init(
        kind: QuotaKind,
        label: String,
        usedPercent: Double,
        windowMinutes: Int? = nil,
        resetsAt: Date? = nil
    ) {
        self.kind = kind
        self.label = label
        self.usedPercent = usedPercent
        self.windowMinutes = windowMinutes
        self.resetsAt = resetsAt
    }
}

public struct TokenUsage: Codable, Equatable, Sendable {
    public var input: Int64
    public var cachedInput: Int64
    public var cacheCreation: Int64
    public var output: Int64
    public var reasoning: Int64

    public init(
        input: Int64 = 0,
        cachedInput: Int64 = 0,
        cacheCreation: Int64 = 0,
        output: Int64 = 0,
        reasoning: Int64 = 0
    ) {
        self.input = input
        self.cachedInput = cachedInput
        self.cacheCreation = cacheCreation
        self.output = output
        self.reasoning = reasoning
    }

    public var total: Int64 {
        // Reasoning is an informational subset of output in Codex histories.
        input + cachedInput + cacheCreation + output
    }

    public static func + (lhs: TokenUsage, rhs: TokenUsage) -> TokenUsage {
        TokenUsage(
            input: lhs.input + rhs.input,
            cachedInput: lhs.cachedInput + rhs.cachedInput,
            cacheCreation: lhs.cacheCreation + rhs.cacheCreation,
            output: lhs.output + rhs.output,
            reasoning: lhs.reasoning + rhs.reasoning
        )
    }

    public static func - (lhs: TokenUsage, rhs: TokenUsage) -> TokenUsage {
        TokenUsage(
            input: max(0, lhs.input - rhs.input),
            cachedInput: max(0, lhs.cachedInput - rhs.cachedInput),
            cacheCreation: max(0, lhs.cacheCreation - rhs.cacheCreation),
            output: max(0, lhs.output - rhs.output),
            reasoning: max(0, lhs.reasoning - rhs.reasoning)
        )
    }
}

public struct ModelUsage: Codable, Equatable, Sendable {
    public var model: String
    public var tokens: TokenUsage

    public init(model: String, tokens: TokenUsage) {
        self.model = model
        self.tokens = tokens
    }
}

public struct DailyUsage: Codable, Equatable, Sendable, Identifiable {
    public var date: Date
    public var models: [ModelUsage]
    public var estimatedCostUSD: Double?

    public var id: Date { date }

    public init(date: Date, models: [ModelUsage], estimatedCostUSD: Double? = nil) {
        self.date = date
        self.models = models
        self.estimatedCostUSD = estimatedCostUSD
    }

    public var tokens: TokenUsage {
        models.reduce(TokenUsage()) { $0 + $1.tokens }
    }
}

public struct UsageSnapshot: Codable, Equatable, Sendable, Identifiable {
    public var provider: ProviderID
    public var source: String
    public var quotaWindows: [QuotaWindow]
    public var dailyUsage: [DailyUsage]
    public var updatedAt: Date
    public var errorMessage: String?

    public var id: ProviderID { provider }

    public init(
        provider: ProviderID,
        source: String,
        quotaWindows: [QuotaWindow] = [],
        dailyUsage: [DailyUsage] = [],
        updatedAt: Date = .now,
        errorMessage: String? = nil
    ) {
        self.provider = provider
        self.source = source
        self.quotaWindows = quotaWindows
        self.dailyUsage = dailyUsage
        self.updatedAt = updatedAt
        self.errorMessage = errorMessage
    }

    public var primaryPercent: Double? {
        quotaWindows.first(where: { $0.kind == .session })?.usedPercent
            ?? quotaWindows.first?.usedPercent
    }
}

public protocol UsageProvider: Sendable {
    var providerID: ProviderID { get }
    func fetchQuota() async throws -> [QuotaWindow]
    func scanHistory(now: Date, calendar: Calendar) async throws -> [DailyUsage]
}

public enum MonitorError: LocalizedError, Equatable {
    case executableMissing(String)
    case commandTimedOut(String)
    case commandFailed(String)
    case incompatibleOutput(String)
    case historyUnavailable(String)

    public var errorDescription: String? {
        switch self {
        case let .executableMissing(name): "\(name) is not installed or its path is not configured."
        case let .commandTimedOut(name): "\(name) did not return usage data before the timeout."
        case let .commandFailed(message): message
        case let .incompatibleOutput(message): message
        case let .historyUnavailable(message): message
        }
    }
}
