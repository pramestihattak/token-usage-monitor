import Foundation

public struct SnapshotCache: Sendable {
    public var fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public static func `default`(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> SnapshotCache {
        SnapshotCache(fileURL: homeDirectory
            .appendingPathComponent("Library/Application Support/Token Monitor", isDirectory: true)
            .appendingPathComponent("snapshots.json"))
    }

    public func load() -> [UsageSnapshot] {
        SecureStorage.hardenExisting(fileURL)
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return (try? JSONDecoder.monitorDecoder.decode([UsageSnapshot].self, from: data)) ?? []
    }

    public func save(_ snapshots: [UsageSnapshot]) throws {
        let data = try JSONEncoder.monitorEncoder.encode(snapshots)
        try SecureStorage.write(data, to: fileURL)
    }
}

enum SecureStorage {
    static func hardenExisting(_ fileURL: URL) {
        let manager = FileManager.default
        let directory = fileURL.deletingLastPathComponent()
        if manager.fileExists(atPath: directory.path) {
            try? manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        }
        if manager.fileExists(atPath: fileURL.path) {
            try? manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        }
    }

    static func write(_ data: Data, to fileURL: URL) throws {
        let manager = FileManager.default
        let directory = fileURL.deletingLastPathComponent()
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        try data.write(to: fileURL, options: .atomic)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
}

public struct NotificationEvent: Equatable, Sendable {
    public var provider: ProviderID
    public var window: QuotaWindow
    public var threshold: Int

    public init(provider: ProviderID, window: QuotaWindow, threshold: Int) {
        self.provider = provider
        self.window = window
        self.threshold = threshold
    }
}

public struct NotificationDeduplicator: Codable, Sendable {
    public private(set) var deliveredKeys: Set<String>

    public init(deliveredKeys: Set<String> = []) {
        self.deliveredKeys = deliveredKeys
    }

    public mutating func newEvents(
        for snapshots: [UsageSnapshot],
        thresholds: [Int] = [80, 95]
    ) -> [NotificationEvent] {
        var result: [NotificationEvent] = []
        for snapshot in snapshots {
            for window in snapshot.quotaWindows {
                for threshold in thresholds.sorted() where window.usedPercent >= Double(threshold) {
                    let key = eventKey(provider: snapshot.provider, window: window, threshold: threshold)
                    if deliveredKeys.insert(key).inserted {
                        result.append(NotificationEvent(provider: snapshot.provider, window: window, threshold: threshold))
                    }
                }
            }
        }
        if deliveredKeys.count > 512 {
            deliveredKeys = Set(deliveredKeys.sorted().suffix(256))
        }
        return result
    }

    private func eventKey(provider: ProviderID, window: QuotaWindow, threshold: Int) -> String {
        let reset = window.resetsAt.map { Int($0.timeIntervalSince1970) } ?? 0
        return "\(provider.rawValue)|\(window.id)|\(threshold)|\(reset)"
    }
}

public extension JSONEncoder {
    static var monitorEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

public extension JSONDecoder {
    static var monitorDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }
}
