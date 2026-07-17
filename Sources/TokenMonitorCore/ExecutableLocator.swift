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
            if let trusted = validatedExecutable(url) { return trusted }
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
        if let known = candidates.compactMap(validatedExecutable).first {
            return known
        }

        let executableName = provider == .claude ? "claude" : "codex"
        for directory in environmentPath.split(separator: ":", omittingEmptySubsequences: true) {
            let path = String(directory)
            guard path.hasPrefix("/") else { continue }
            let candidate = URL(fileURLWithPath: path).appendingPathComponent(executableName)
            if let trusted = validatedExecutable(candidate) { return trusted }
        }
        return nil
    }

    private func validatedExecutable(_ url: URL) -> URL? {
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL
        let manager = FileManager.default
        guard manager.isExecutableFile(atPath: resolved.path),
              let attributes = try? manager.attributesOfItem(atPath: resolved.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue,
              permissions & 0o022 == 0 else {
            return nil
        }
        return resolved
    }
}
