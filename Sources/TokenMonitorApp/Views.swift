import AppKit
import SwiftUI
import TokenMonitorCore

struct TokenUsageMark: View {
    var size: CGFloat = 17

    var body: some View {
        ZStack {
            Circle()
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.13, green: 0.86, blue: 1.00),
                            Color(red: 0.48, green: 0.25, blue: 0.98),
                            Color(red: 1.00, green: 0.24, blue: 0.66)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            Circle()
                .stroke(.white.opacity(0.75), lineWidth: max(0.8, size * 0.055))
            Image(systemName: "bolt.fill")
                .font(.system(size: size * 0.48, weight: .black))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.24), radius: 0.6, y: 0.5)
        }
        .frame(width: size, height: size)
        .shadow(color: Color(red: 0.48, green: 0.25, blue: 0.98).opacity(0.45), radius: size * 0.11, y: 1)
        .accessibilityHidden(true)
    }
}

struct StatusLabel: View {
    @ObservedObject var coordinator: MonitorCoordinator

    var body: some View {
        TokenUsageMark()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Token Usage Monitor, \(accessibilitySummary)")
    }

    private var accessibilitySummary: String {
        ProviderID.allCases.map { provider in
            let value = coordinator.snapshots[provider]?.primaryPercent
            return "\(provider.displayName) \(value.map { "\(Int($0.rounded())) percent" } ?? "unavailable")"
        }.joined(separator: ", ")
    }
}

struct MonitorPopover: View {
    @ObservedObject var coordinator: MonitorCoordinator

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                TokenUsageMark(size: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Token Usage Monitor").font(.headline)
                    Text("Subscription quota and local token history")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if coordinator.isRefreshing { ProgressView().controlSize(.small) }
            }

            ForEach(ProviderID.allCases) { provider in
                ProviderCard(
                    snapshot: coordinator.snapshot(for: provider),
                    exchangeRate: coordinator.exchangeRate
                )
            }

            Divider()
            HStack {
                Button {
                    Task { await coordinator.refreshAll(includeQuota: true) }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(coordinator.isRefreshing)

                Spacer()
                SettingsLink { Image(systemName: "gearshape") }
                    .help("Settings")
                Button {
                    NSApplication.shared.terminate(nil)
                } label: {
                    Image(systemName: "power")
                }
                .help("Quit Token Usage Monitor")
            }
        }
        .padding(14)
        .frame(width: 390)
        .task { await coordinator.popoverOpened() }
    }
}

private struct ProviderCard: View {
    let snapshot: UsageSnapshot
    let exchangeRate: ExchangeRateQuote?

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Image(systemName: snapshot.provider == .claude ? "sparkles" : "terminal")
                Text(snapshot.provider.displayName).font(.headline)
                Spacer()
                Text(snapshot.source)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if snapshot.quotaWindows.isEmpty {
                Text("Quota unavailable")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(snapshot.quotaWindows) { window in
                    QuotaRow(window: window)
                }
            }

            HStack(spacing: 0) {
                StatCell(title: "Today", value: formatTokens(snapshot.usage(lastDays: 1).total), subtitle: formatCost(snapshot.estimatedCost(lastDays: 1), rate: exchangeRate))
                Divider().frame(height: 34).padding(.horizontal, 12)
                StatCell(title: "7 days", value: formatTokens(snapshot.usage(lastDays: 7).total), subtitle: formatCost(snapshot.estimatedCost(lastDays: 7), rate: exchangeRate))
                Divider().frame(height: 34).padding(.horizontal, 12)
                StatCell(title: "30 days", value: formatTokens(snapshot.usage(lastDays: 30).total), subtitle: formatCost(snapshot.estimatedCost(lastDays: 30), rate: exchangeRate))
            }

            if let error = snapshot.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text(footerText)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(12)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 12))
    }

    private var footerText: String {
        guard let exchangeRate else {
            return "Updated recently · Waiting for USD/IDR rate"
        }
        return "USD/IDR \(formatRate(exchangeRate.rate)) · \(exchangeRate.rateDate) · API-equivalent estimate"
    }
}

private struct QuotaRow: View {
    let window: QuotaWindow

    var body: some View {
        VStack(spacing: 3) {
            HStack {
                Text(window.label).font(.caption)
                Spacer()
                Text("\(Int(window.usedPercent.rounded()))% used")
                    .font(.caption).monospacedDigit()
                if let reset = window.resetsAt {
                    Text("· resets in \(reset, style: .relative)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            ProgressView(value: min(100, window.usedPercent), total: 100)
                .tint(window.usedPercent >= 95 ? .red : (window.usedPercent >= 80 ? .orange : .accentColor))
        }
    }
}

private struct StatCell: View {
    let title: String
    let value: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.subheadline).monospacedDigit()
            Text(subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct PreferencesView: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject var coordinator: MonitorCoordinator

    var body: some View {
        Form {
            Section("General") {
                Toggle("Notify at 80% and 95%", isOn: $settings.notificationsEnabled)
                Toggle("Launch at login", isOn: Binding(
                    get: { settings.launchAtLogin },
                    set: { settings.setLaunchAtLogin($0) }
                ))
                if let error = settings.launchAtLoginError {
                    Text(error).font(.caption).foregroundStyle(.orange)
                }
                Picker("Quota refresh", selection: $settings.refreshInterval) {
                    Text("1 minute").tag(TimeInterval(60))
                    Text("5 minutes").tag(TimeInterval(300))
                    Text("15 minutes").tag(TimeInterval(900))
                }
            }
            Section("Executable overrides") {
                TextField("Claude path (automatic)", text: $settings.claudePath)
                TextField("Codex path (automatic)", text: $settings.codexPath)
                Text("Leave blank to search PATH and standard installation locations.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Privacy") {
                Text("Token Usage Monitor reads only usage fields from local histories and asks installed CLIs for quota data. It stores no prompts, credentials, analytics, or telemetry.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(width: 480, height: 390)
        .onChange(of: settings.notificationsEnabled) {
            Task { await coordinator.notificationsSettingChanged() }
        }
    }
}

private func formatTokens(_ tokens: Int64) -> String {
    if tokens >= 1_000_000 { return String(format: "%.1fM", Double(tokens) / 1_000_000) }
    if tokens >= 1_000 { return String(format: "%.1fK", Double(tokens) / 1_000) }
    return "\(tokens)"
}

private func formatCost(_ cost: Double?, rate: ExchangeRateQuote?) -> String {
    guard let cost else { return "Price unavailable" }
    guard let rate else { return "Rate unavailable" }
    let formatter = NumberFormatter()
    formatter.locale = Locale(identifier: "id_ID")
    formatter.numberStyle = .currency
    formatter.currencyCode = "IDR"
    formatter.maximumFractionDigits = 0
    formatter.minimumFractionDigits = 0
    return (formatter.string(from: NSNumber(value: rate.convert(usd: cost))) ?? "Rp—") + " est."
}

private func formatRate(_ rate: Double) -> String {
    let formatter = NumberFormatter()
    formatter.locale = Locale(identifier: "id_ID")
    formatter.numberStyle = .decimal
    formatter.maximumFractionDigits = 2
    return formatter.string(from: NSNumber(value: rate)) ?? String(format: "%.2f", rate)
}
