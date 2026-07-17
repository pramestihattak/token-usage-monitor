import Foundation

public struct ExecutableLocator: Sendable {
    public var environmentPath: String
    public var homeDirectory: URL

    public init(
        environmentPath: String = ProcessInfo.processInfo.environment["PATH"] ?? "",
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        self.environmentPath = environmentPath
        self.homeDirectory = homeDirectory
    }

    public func locate(_ provider: ProviderID, override: String? = nil) -> URL? {
        if let override, !override.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let url = URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
            if FileManager.default.isExecutableFile(atPath: url.path) { return url }
        }

        let executableName = provider == .claude ? "claude" : "codex"
        for directory in environmentPath.split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(directory)).appendingPathComponent(executableName)
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
        }

        let candidates: [URL]
        switch provider {
        case .claude:
            candidates = [
                homeDirectory.appendingPathComponent(".local/bin/claude"),
                URL(fileURLWithPath: "/opt/homebrew/bin/claude"),
                URL(fileURLWithPath: "/usr/local/bin/claude"),
            ]
        case .codex:
            candidates = [
                URL(fileURLWithPath: "/Applications/ChatGPT.app/Contents/Resources/codex"),
                homeDirectory.appendingPathComponent(".local/bin/codex"),
                URL(fileURLWithPath: "/opt/homebrew/bin/codex"),
                URL(fileURLWithPath: "/usr/local/bin/codex"),
            ]
        }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }
}
