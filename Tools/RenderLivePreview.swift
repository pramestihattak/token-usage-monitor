import AppKit
import Foundation
import SwiftUI

private struct Snapshot: Decodable, Identifiable {
    let provider: String
    let source: String
    let quotaWindows: [Window]
    let dailyUsage: [Day]
    let updatedAt: Date
    let errorMessage: String?
    var id: String { provider }

    func tokens(days: Int, now: Date = .now) -> Int64 {
        let calendar = Calendar.current
        let start = calendar.date(byAdding: .day, value: -(days - 1), to: calendar.startOfDay(for: now))!
        return dailyUsage.filter { $0.date >= start }.flatMap(\.models).reduce(0) { $0 + $1.tokens.total }
    }

    func cost(days: Int, now: Date = .now) -> Double? {
        let calendar = Calendar.current
        let start = calendar.date(byAdding: .day, value: -(days - 1), to: calendar.startOfDay(for: now))!
        let values = dailyUsage.filter { $0.date >= start }.map(\.estimatedCostUSD)
        guard !values.isEmpty, values.allSatisfy({ $0 != nil }) else { return nil }
        return values.compactMap { $0 }.reduce(0, +)
    }
}

private struct Window: Decodable, Identifiable {
    let kind: String
    let label: String
    let usedPercent: Double
    let resetsAt: Date?
    var id: String { kind + label }
}

private struct Day: Decodable {
    let date: Date
    let models: [Model]
    let estimatedCostUSD: Double?
}

private struct Model: Decodable {
    let tokens: Tokens
}

private struct Tokens: Decodable {
    let input: Int64
    let cachedInput: Int64
    let cacheCreation: Int64
    let output: Int64
    var total: Int64 { input + cachedInput + cacheCreation + output }
}

private struct RateQuote: Decodable {
    let rate: Double
    let rateDate: String
}

private struct PreviewTokenMark: View {
    var size: CGFloat

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
            Circle().stroke(.white.opacity(0.75), lineWidth: max(0.8, size * 0.055))
            Image(systemName: "bolt.fill")
                .font(.system(size: size * 0.48, weight: .black))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.24), radius: 0.6, y: 0.5)
        }
        .frame(width: size, height: size)
        .shadow(color: Color(red: 0.48, green: 0.25, blue: 0.98).opacity(0.45), radius: size * 0.11, y: 1)
    }
}

private struct Preview: View {
    let snapshots: [Snapshot]
    let exchangeRate: RateQuote?

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                PreviewTokenMark(size: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Token Usage Monitor").font(.headline)
                    Text("Subscription quota and local token history")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            ForEach(snapshots) { snapshot in Card(snapshot: snapshot, exchangeRate: exchangeRate) }
            Divider()
            HStack {
                Label("Refresh", systemImage: "arrow.clockwise")
                Spacer()
                Image(systemName: "gearshape")
                Image(systemName: "power")
            }
            .foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(width: 390)
        .background(Color(red: 0.11, green: 0.08, blue: 0.36))
        .environment(\.colorScheme, .dark)
    }
}

private struct Card: View {
    let snapshot: Snapshot
    let exchangeRate: RateQuote?

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Image(systemName: snapshot.provider == "claude" ? "sparkles" : "terminal")
                Text(snapshot.provider == "claude" ? "Claude" : "Codex").font(.headline)
                Spacer()
                Text(snapshot.source).font(.caption2).foregroundStyle(.secondary)
            }
            ForEach(snapshot.quotaWindows) { window in
                VStack(spacing: 3) {
                    HStack {
                        Text(window.label).font(.caption)
                        Spacer()
                        Text("\(Int(window.usedPercent.rounded()))% used").font(.caption).monospacedDigit()
                    }
                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            Capsule().fill(.white.opacity(0.14))
                            Capsule()
                                .fill(window.usedPercent >= 95 ? Color.red : (window.usedPercent >= 80 ? Color.orange : Color.accentColor))
                                .frame(width: geometry.size.width * min(1, window.usedPercent / 100))
                        }
                    }
                    .frame(height: 7)
                }
            }
            HStack(spacing: 0) {
                stat("Today", days: 1)
                Divider().frame(height: 34).padding(.horizontal, 12)
                stat("7 days", days: 7)
                Divider().frame(height: 34).padding(.horizontal, 12)
                stat("30 days", days: 30)
            }
            if let error = snapshot.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
            }
            Text(footerText)
                .font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(12)
        .background(.white.opacity(0.09), in: RoundedRectangle(cornerRadius: 12))
    }

    private func stat(_ title: String, days: Int) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(formatTokens(snapshot.tokens(days: days))).font(.subheadline).monospacedDigit()
            Text(formatCost(snapshot.cost(days: days), rate: exchangeRate)).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var footerText: String {
        guard let exchangeRate else { return "Waiting for USD/IDR rate" }
        return "USD/IDR \(formatRate(exchangeRate.rate)) · \(exchangeRate.rateDate) · API-equivalent estimate"
    }
}

private func formatTokens(_ tokens: Int64) -> String {
    if tokens >= 1_000_000 { return String(format: "%.1fM", Double(tokens) / 1_000_000) }
    if tokens >= 1_000 { return String(format: "%.1fK", Double(tokens) / 1_000) }
    return "\(tokens)"
}

private func formatCost(_ cost: Double?, rate: RateQuote?) -> String {
    guard let cost else { return "Price unavailable" }
    guard let rate else { return "Rate unavailable" }
    let formatter = NumberFormatter()
    formatter.locale = Locale(identifier: "id_ID")
    formatter.numberStyle = .currency
    formatter.currencyCode = "IDR"
    formatter.maximumFractionDigits = 0
    formatter.minimumFractionDigits = 0
    return (formatter.string(from: NSNumber(value: cost * rate.rate)) ?? "Rp—") + " est."
}

private func formatRate(_ rate: Double) -> String {
    let formatter = NumberFormatter()
    formatter.locale = Locale(identifier: "id_ID")
    formatter.numberStyle = .decimal
    formatter.maximumFractionDigits = 2
    return formatter.string(from: NSNumber(value: rate)) ?? String(format: "%.2f", rate)
}

@main
private struct RenderLivePreview {
    @MainActor
    static func main() throws {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let cache = home.appendingPathComponent("Library/Application Support/Token Monitor/snapshots.json")
        let rateCache = home.appendingPathComponent("Library/Application Support/Token Monitor/exchange-rate.json")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let snapshots = try decoder.decode([Snapshot].self, from: Data(contentsOf: cache))
        let rate = (try? Data(contentsOf: rateCache)).flatMap { try? decoder.decode(RateQuote.self, from: $0) }
        let renderer = ImageRenderer(content: Preview(snapshots: snapshots, exchangeRate: rate))
        renderer.scale = 2
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "token-usage-monitor-live-preview.png")
        try png.write(to: output, options: .atomic)
        print(output.path)
    }
}
