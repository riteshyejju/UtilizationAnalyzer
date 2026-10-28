import SwiftUI
import AppKit

// MARK: - Status Colors

extension MemoryPressureLevel {
    public var color: Color {
        switch self {
        case .nominal: return .green
        case .warning: return .orange
        case .critical: return .red
        }
    }
}

extension ThermalLevel {
    public var color: Color {
        switch self {
        case .nominal: return .green
        case .fair: return .yellow
        case .serious: return .orange
        case .critical: return .red
        }
    }
}

extension SufficiencyVerdictLevel {
    public var color: Color {
        switch self {
        case .optimal: return .green
        case .comfortable: return .blue
        case .borderline: return .orange
        case .constrained: return .red
        }
    }

    public var iconName: String {
        switch self {
        case .optimal: return "checkmark.seal.fill"
        case .comfortable: return "hand.thumbsup.fill"
        case .borderline: return "exclamationmark.triangle.fill"
        case .constrained: return "flame.fill"
        }
    }
}

// MARK: - Native App Icon View

public struct AppIconView: View {
    public let bundlePath: String?
    public let size: CGFloat

    public init(bundlePath: String?, size: CGFloat = 24) {
        self.bundlePath = bundlePath
        self.size = size
    }

    public var body: some View {
        if let path = bundlePath, FileManager.default.fileExists(atPath: path) {
            let nsImage = NSWorkspace.shared.icon(forFile: path)
            Image(nsImage: nsImage)
                .resizable()
                .interpolation(.high)
                .frame(width: size, height: size)
        } else {
            Image(systemName: "terminal.fill")
                .resizable()
                .scaledToFit()
                .padding(size * 0.18)
                .frame(width: size, height: size)
                .background(Color.secondary.opacity(0.15))
                .foregroundStyle(.secondary)
                .clipShape(RoundedRectangle(cornerRadius: size * 0.22))
        }
    }
}

// MARK: - Circular Score Ring

public struct ScoreRingView: View {
    public let score: Int
    public let title: String
    public let size: CGFloat

    public init(score: Int, title: String, size: CGFloat = 68) {
        self.score = score
        self.title = title
        self.size = size
    }

    private var ringColor: Color {
        if score >= 85 { return .green }
        if score >= 70 { return .blue }
        if score >= 52 { return .orange }
        return .red
    }

    public var body: some View {
        VStack(spacing: 6) {
            ZStack {
                Circle()
                    .stroke(Color.secondary.opacity(0.18), lineWidth: size * 0.11)
                Circle()
                    .trim(from: 0, to: CGFloat(max(0, min(100, score))) / 100.0)
                    .stroke(
                        ringColor,
                        style: StrokeStyle(lineWidth: size * 0.11, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                Text("\(score)")
                    .font(.system(size: size * 0.30, weight: .bold, design: .rounded))
                    .foregroundStyle(.primary)
            }
            .frame(width: size, height: size)

            Text(title)
                .font(.caption)
                .fontWeight(.medium)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}

// MARK: - Metric Stat Card

public struct StatMetricCard: View {
    public let title: String
    public let primaryValue: String
    public let subtitle: String
    public let icon: String
    public let accentColor: Color
    public let badgeText: String?
    public let badgeColor: Color?

    public init(
        title: String,
        primaryValue: String,
        subtitle: String,
        icon: String,
        accentColor: Color = .blue,
        badgeText: String? = nil,
        badgeColor: Color? = nil
    ) {
        self.title = title
        self.primaryValue = primaryValue
        self.subtitle = subtitle
        self.icon = icon
        self.accentColor = accentColor
        self.badgeText = badgeText
        self.badgeColor = badgeColor
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(title, systemImage: icon)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
                if let badgeText {
                    Text(badgeText)
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background((badgeColor ?? accentColor).opacity(0.16))
                        .foregroundStyle(badgeColor ?? accentColor)
                        .clipShape(Capsule())
                }
            }

            Text(primaryValue)
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .foregroundStyle(.primary)
                .lineLimit(1)

            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(nsColor: .controlBackgroundColor))
                .shadow(color: .black.opacity(0.05), radius: 2, y: 1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }
}

// MARK: - Two-Option Export Menu Button

public struct ExportMenuButton: View {
    @ObservedObject public var manager: MonitoringManager
    public var compact: Bool = false

    private static let quickPresets: [(Int, ExportRangeUnit)] = [
        (24, .hours), (7, .days), (30, .days), (3, .months), (6, .months), (12, .months)
    ]

    public init(manager: MonitoringManager, compact: Bool = false) {
        self.manager = manager
        self.compact = compact
    }

    public var body: some View {
        Menu {
            Section("Range: \(manager.exportInterval.label)") {
                Menu("Change Export Range") {
                    Button("Same as Dashboard (\(manager.selectedTimeRange.title))") {
                        manager.exportRangeMode = .dashboard
                    }
                    Divider()
                    ForEach(Array(Self.quickPresets.enumerated()), id: \.offset) { _, preset in
                        Button("Last \(preset.0) \(preset.1.rawValue)") {
                            manager.exportLastNValue = preset.0
                            manager.exportLastNUnit = preset.1
                            manager.exportRangeMode = .lastN
                        }
                    }
                    Divider()
                    Button("All Stored Data") { manager.exportRangeMode = .allTime }
                    Text("Custom dates: Dashboard → LLM & Raw Export")
                }
            }

            Section("Option 1: LLM-Ready Markdown Summary") {
                Button {
                    manager.copyLLMMarkdownToClipboard()
                } label: {
                    Label("Copy LLM Markdown Summary to Clipboard", systemImage: "doc.on.clipboard")
                }

                Button {
                    manager.saveLLMMarkdownToFile()
                } label: {
                    Label("Save LLM Markdown Summary (.md)...", systemImage: "sparkles")
                }
            }

            Section("Option 2: Raw Telemetry Data") {
                Button {
                    manager.exportRawJSONToFile()
                } label: {
                    Label("Export Raw Data as JSON (.json)...", systemImage: "curlybraces")
                }

                Button {
                    manager.exportRawCSVToFile()
                } label: {
                    Label("Export Raw Data as CSV (.csv)...", systemImage: "tablecells")
                }
            }
        } label: {
            Label(compact ? "Export" : "Export Data", systemImage: "square.and.arrow.up")
        }
    }
}
