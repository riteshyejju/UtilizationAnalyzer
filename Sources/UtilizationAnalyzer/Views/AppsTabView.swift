import SwiftUI

public enum AppSortField: String, CaseIterable, Identifiable {
    case composite = "Overall Impact"
    case avgCpu = "Average CPU %"
    case peakCpu = "Peak CPU %"
    case avgMemory = "Average RAM"
    case peakMemory = "Peak RAM"
    case diskIO = "Disk Read/Write"

    public var id: String { rawValue }
}

public struct AppsTabView: View {
    @ObservedObject public var manager: MonitoringManager
    @State private var showLiveSnapshot: Bool = false
    @State private var searchText: String = ""
    @State private var sortBy: AppSortField = .composite

    public init(manager: MonitoringManager) {
        self.manager = manager
    }

    private var filteredHistoricalApps: [AggregatedAppUsage] {
        let base = manager.aggregatedApps.filter { app in
            searchText.isEmpty || app.displayName.localizedCaseInsensitiveContains(searchText)
        }
        return base.sorted { a, b in
            switch sortBy {
            case .composite:
                let sA = a.avgCpuPercent * 2.0 + Double(a.avgMemoryBytes) / 100_000_000.0
                let sB = b.avgCpuPercent * 2.0 + Double(b.avgMemoryBytes) / 100_000_000.0
                return sA > sB
            case .avgCpu:
                return a.avgCpuPercent > b.avgCpuPercent
            case .peakCpu:
                return a.peakCpuPercent > b.peakCpuPercent
            case .avgMemory:
                return a.avgMemoryBytes > b.avgMemoryBytes
            case .peakMemory:
                return a.peakMemoryBytes > b.peakMemoryBytes
            case .diskIO:
                return (a.avgDiskReadBytesPerSec + a.avgDiskWriteBytesPerSec) >
                       (b.avgDiskReadBytesPerSec + b.avgDiskWriteBytesPerSec)
            }
        }
    }

    private var filteredLiveApps: [AppUsageSnapshot] {
        let base = manager.liveTopApps.filter { app in
            searchText.isEmpty || app.displayName.localizedCaseInsensitiveContains(searchText)
        }
        return base.sorted { a, b in
            switch sortBy {
            case .composite:
                let sA = a.cpuPercent * 2.0 + Double(a.memoryBytes) / 100_000_000.0
                let sB = b.cpuPercent * 2.0 + Double(b.memoryBytes) / 100_000_000.0
                return sA > sB
            case .avgCpu, .peakCpu:
                return a.cpuPercent > b.cpuPercent
            case .avgMemory, .peakMemory:
                return a.memoryBytes > b.memoryBytes
            case .diskIO:
                return (a.diskReadBytesPerSec + a.diskWriteBytesPerSec) >
                       (b.diskReadBytesPerSec + b.diskWriteBytesPerSec)
            }
        }
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Controls Bar
            HStack(spacing: 12) {
                Picker("View Mode", selection: $showLiveSnapshot) {
                    Text("Historical (\(manager.selectedTimeRange.title))").tag(false)
                    Text("Live Right Now").tag(true)
                }
                .pickerStyle(.segmented)
                .frame(width: 310)

                TextField("Filter applications...", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 240)

                Spacer()

                Picker("Sort By", selection: $sortBy) {
                    ForEach(AppSortField.allCases) { field in
                        Text(field.rawValue).tag(field)
                    }
                }
                .frame(width: 210)
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)

            // Info Banner
            HStack(spacing: 8) {
                Image(systemName: "info.circle")
                    .foregroundStyle(.blue)
                Text("Child helper processes (browser renderers, GPU helpers, language servers) are automatically grouped into their parent application bundle so you see true per-app resource footprints.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 20)

            // Column Header
            HStack(spacing: 12) {
                Text("Application")
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("Procs")
                    .frame(width: 55, alignment: .trailing)
                Text(showLiveSnapshot ? "Live CPU" : "Avg CPU")
                    .frame(width: 80, alignment: .trailing)
                if !showLiveSnapshot {
                    Text("Peak CPU")
                        .frame(width: 80, alignment: .trailing)
                }
                Text(showLiveSnapshot ? "Live RAM" : "Avg RAM")
                    .frame(width: 90, alignment: .trailing)
                if !showLiveSnapshot {
                    Text("Peak RAM")
                        .frame(width: 90, alignment: .trailing)
                }
                Text("Disk R/W")
                    .frame(width: 135, alignment: .trailing)
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 28)
            .padding(.vertical, 6)
            .background(Color.secondary.opacity(0.08))

            // Rows
            ScrollView {
                LazyVStack(spacing: 8) {
                    if showLiveSnapshot {
                        ForEach(filteredLiveApps) { app in
                            liveAppRow(app)
                        }
                    } else {
                        ForEach(filteredHistoricalApps) { app in
                            historicalAppRow(app)
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
            }
        }
    }

    private func historicalAppRow(_ app: AggregatedAppUsage) -> some View {
        let ramShare = manager.hardware.physicalMemoryBytes > 0
            ? min(1.0, Double(app.peakMemoryBytes) / Double(manager.hardware.physicalMemoryBytes))
            : 0.0

        return VStack(spacing: 6) {
            HStack(spacing: 12) {
                HStack(spacing: 10) {
                    AppIconView(bundlePath: app.bundlePath, size: 26)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(app.displayName)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                        Text("\(app.sampleCount) samples\(app.bundlePath != nil ? " • App Bundle" : " • Background Daemon/CLI")")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Text("\(app.maxProcessCount)")
                    .font(.caption.monospacedDigit())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.14))
                    .clipShape(Capsule())
                    .frame(width: 55, alignment: .trailing)

                Text(String(format: "%.1f%%", app.avgCpuPercent))
                    .font(.subheadline.monospacedDigit().weight(.medium))
                    .foregroundStyle(app.avgCpuPercent > 40 ? .orange : .primary)
                    .frame(width: 80, alignment: .trailing)

                Text(String(format: "%.1f%%", app.peakCpuPercent))
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(app.peakCpuPercent > 100 ? .red : .secondary)
                    .frame(width: 80, alignment: .trailing)

                Text(ByteFormatter.formatBytes(app.avgMemoryBytes))
                    .font(.subheadline.monospacedDigit().weight(.medium))
                    .frame(width: 90, alignment: .trailing)

                Text(ByteFormatter.formatBytes(app.peakMemoryBytes))
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(ramShare > 0.25 ? .orange : .secondary)
                    .frame(width: 90, alignment: .trailing)

                Text("\(ByteFormatter.formatRate(app.avgDiskReadBytesPerSec)) / \(ByteFormatter.formatRate(app.avgDiskWriteBytesPerSec))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 135, alignment: .trailing)
            }

            // Subtle memory footprint bar relative to physical RAM
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.secondary.opacity(0.10))
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [.blue.opacity(0.65), .teal.opacity(0.75)],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: max(4, geo.size.width * CGFloat(ramShare)))
                }
            }
            .frame(height: 4)
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.primary.opacity(0.05), lineWidth: 1)
        )
    }

    private func liveAppRow(_ app: AppUsageSnapshot) -> some View {
        HStack(spacing: 12) {
            HStack(spacing: 10) {
                AppIconView(bundlePath: app.bundlePath, size: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(app.displayName)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    if let bp = app.bundlePath {
                        Text(bp)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text("\(app.processCount)")
                .font(.caption.monospacedDigit())
                .frame(width: 55, alignment: .trailing)

            Text(String(format: "%.1f%%", app.cpuPercent))
                .font(.subheadline.monospacedDigit().weight(.medium))
                .foregroundStyle(app.cpuPercent > 50 ? .orange : .primary)
                .frame(width: 80, alignment: .trailing)

            Text(ByteFormatter.formatBytes(app.memoryBytes))
                .font(.subheadline.monospacedDigit().weight(.medium))
                .frame(width: 90, alignment: .trailing)

            Text("\(ByteFormatter.formatRate(app.diskReadBytesPerSec)) / \(ByteFormatter.formatRate(app.diskWriteBytesPerSec))")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 135, alignment: .trailing)
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.primary.opacity(0.05), lineWidth: 1)
        )
    }
}
