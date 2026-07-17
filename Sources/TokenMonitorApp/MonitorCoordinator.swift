import AppKit
import Combine
import Foundation
import TokenMonitorCore

@MainActor
final class MonitorCoordinator: ObservableObject {
    @Published private(set) var snapshots: [ProviderID: UsageSnapshot] = [:]
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastRefresh: Date?
    @Published private(set) var exchangeRate: ExchangeRateQuote?

    let settings: SettingsStore
    private let cache: SnapshotCache
    private let locator = ExecutableLocator()
    private let pricing = PricingCatalog()
    private let notifications = NotificationManager()
    private let exchangeRateService: ExchangeRateService
    private var refreshTask: Task<Void, Never>?
    private var historyPollTask: Task<Void, Never>?
    private var watcher: HistoryWatcher?
    private var started = false
    private var lastHistoryFingerprint: Int?

    init(
        settings: SettingsStore,
        cache: SnapshotCache = .default(),
        exchangeRateCache: ExchangeRateCache = .default()
    ) {
        self.settings = settings
        self.cache = cache
        exchangeRate = exchangeRateCache.load()
        exchangeRateService = ExchangeRateService(cache: exchangeRateCache)
        snapshots = Dictionary(uniqueKeysWithValues: cache.load().map { ($0.provider, $0) })
    }

    func start() async {
        guard !started else { return }
        started = true
        await notifications.requestAuthorizationIfNeeded(enabled: settings.notificationsEnabled)
        setupWatcher()
        lastHistoryFingerprint = await computeHistoryFingerprint()
        await refreshAll(includeQuota: true)
        scheduleTimers()
    }

    func popoverOpened() async {
        await start()
        if lastRefresh.map({ Date().timeIntervalSince($0) > 30 }) ?? true {
            await refreshAll(includeQuota: true)
        }
    }

    func refreshAll(includeQuota: Bool = true) async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        let providers = makeProviders()
        let priorClaude = snapshots[.claude]
        let priorCodex = snapshots[.codex]
        async let rate = exchangeRateService.latest()
        async let claude = refresh(providers.0, prior: priorClaude, includeQuota: includeQuota)
        async let codex = refresh(providers.1, prior: priorCodex, includeQuota: includeQuota)
        let results = await [claude, codex]
        exchangeRate = await rate
        for result in results { snapshots[result.provider] = result }
        lastRefresh = .now
        try? cache.save(ProviderID.allCases.compactMap { snapshots[$0] })
        await notifications.evaluate(Array(snapshots.values), enabled: settings.notificationsEnabled)
    }

    func snapshot(for provider: ProviderID) -> UsageSnapshot {
        snapshots[provider] ?? UsageSnapshot(
            provider: provider,
            source: "Waiting for first refresh",
            errorMessage: nil
        )
    }

    func notificationsSettingChanged() async {
        await notifications.requestAuthorizationIfNeeded(enabled: settings.notificationsEnabled)
        await notifications.evaluate(Array(snapshots.values), enabled: settings.notificationsEnabled)
    }

    private func makeProviders() -> (ClaudeUsageProvider, CodexUsageProvider) {
        let claudeURL = locator.locate(.claude, override: settings.claudePath)
        let codexURL = locator.locate(.codex, override: settings.codexPath)
        return (
            ClaudeUsageProvider(executable: claudeURL),
            CodexUsageProvider(executable: codexURL)
        )
    }

    private func refresh<P: UsageProvider>(
        _ provider: P,
        prior: UsageSnapshot?,
        includeQuota: Bool
    ) async -> UsageSnapshot {
        var daily = prior?.dailyUsage ?? []
        var quotas = prior?.quotaWindows ?? []
        var errors: [String] = []
        do {
            daily = pricing.applyingPrices(to: try await provider.scanHistory(now: .now, calendar: .current))
        } catch {
            errors.append("History: \(error.localizedDescription)")
        }
        if includeQuota {
            do {
                quotas = try await provider.fetchQuota()
            } catch {
                errors.append("Quota: \(error.localizedDescription)")
            }
        }
        return UsageSnapshot(
            provider: provider.providerID,
            source: quotas.isEmpty ? "Local history" : "CLI + local history",
            quotaWindows: quotas,
            dailyUsage: daily,
            updatedAt: .now,
            errorMessage: errors.isEmpty ? nil : errors.joined(separator: "\n")
        )
    }

    private func setupWatcher() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let codexHome = ProcessInfo.processInfo.environment["CODEX_HOME"].map(URL.init(fileURLWithPath:))
            ?? home.appendingPathComponent(".codex")
        watcher = HistoryWatcher(paths: [
            home.appendingPathComponent(".claude/projects"),
            home.appendingPathComponent(".config/claude/projects"),
            codexHome.appendingPathComponent("sessions"),
            codexHome.appendingPathComponent("archived_sessions"),
        ]) { [weak self] in
            Task {
                await self?.refreshAll(includeQuota: false)
                self?.lastHistoryFingerprint = await self?.computeHistoryFingerprint()
            }
        }
    }

    private func scheduleTimers() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                let seconds = max(60, self?.settings.refreshInterval ?? 300)
                try? await Task.sleep(for: .seconds(seconds))
                guard !Task.isCancelled else { return }
                await self?.refreshAll(includeQuota: true)
            }
        }
        historyPollTask?.cancel()
        historyPollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled else { return }
                guard let self else { return }
                let fingerprint = await self.computeHistoryFingerprint()
                if fingerprint != self.lastHistoryFingerprint {
                    self.lastHistoryFingerprint = fingerprint
                    await self.refreshAll(includeQuota: false)
                }
            }
        }
    }

    private func computeHistoryFingerprint() async -> Int {
        let roots = makeProviders().0.historyScanner.roots + makeProviders().1.historyScanner.roots
        return await Task.detached(priority: .utility) { Self.historyFingerprint(roots) }.value
    }

    nonisolated private static func historyFingerprint(_ roots: [URL]) -> Int {
        var hasher = Hasher()
        let manager = FileManager.default
        for root in roots where manager.fileExists(atPath: root.path) {
            guard let enumerator = manager.enumerator(
                at: root,
                includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for case let file as URL in enumerator where file.pathExtension == "jsonl" {
                let values = try? file.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
                hasher.combine(file.path)
                hasher.combine(values?.contentModificationDate?.timeIntervalSince1970 ?? 0)
                hasher.combine(values?.fileSize ?? 0)
            }
        }
        return hasher.finalize()
    }
}
