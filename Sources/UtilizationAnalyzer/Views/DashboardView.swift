import SwiftUI
import AppKit

public enum DashboardSection: String, CaseIterable, Identifiable {
    case overview = "Overview & Verdict"
    case charts = "Telemetry Charts"
    case apps = "App Breakdown"
    case export = "LLM & Raw Export"
    case settings = "Settings"

    public var id: String { rawValue }

    public var icon: String {
        switch self {
        case .overview: return "gauge.with.dots.needle.67percent"
        case .charts: return "chart.xyaxis.line"
        case .apps: return "square.stack.3d.up.fill"
        case .export: return "sparkles.rectangle.stack"
        case .settings: return "gearshape.fill"
        }
    }
}

public struct DashboardView: View {
    @ObservedObject public var manager: MonitoringManager
    @State private var selectedSection: DashboardSection = .overview

    public init(manager: MonitoringManager) {
        self.manager = manager
    }

    public var body: some View {
        NavigationSplitView {
            List(DashboardSection.allCases, selection: $selectedSection) { section in
                Label(section.rawValue, systemImage: section.icon)
                    .tag(section)
            }
            .navigationSplitViewColumnWidth(min: 195, ideal: 215, max: 240)
            .safeAreaInset(edge: .bottom) {
                VStack(alignment: .leading, spacing: 6) {
                    Divider()
                    HStack(spacing: 6) {
                        Circle()
                            .fill(manager.isPaused ? Color.orange : Color.green)
                            .frame(width: 8, height: 8)
                        Text(manager.isPaused ? "Monitoring Paused" : "Background Active (\(Int(manager.samplingIntervalSeconds))s)")
                            .font(.caption.weight(.medium))
                    }
                    Text("\(manager.totalStoredSamples) samples • \(ByteFormatter.formatBytes(manager.databaseSizeBytes))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(12)
            }
        } detail: {
            ZStack(alignment: .bottom) {
                Group {
                    switch selectedSection {
                    case .overview:
                        OverviewTabView(manager: manager, selectedSection: $selectedSection)
                    case .charts:
                        ChartsTabView(manager: manager)
                    case .apps:
                        AppsTabView(manager: manager)
                    case .export:
                        ExportTabView(manager: manager)
                    case .settings:
                        SettingsTabView(manager: manager)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                if let toast = manager.statusToast {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text(toast)
                            .font(.subheadline.weight(.medium))
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.regularMaterial)
                    .clipShape(Capsule())
                    .shadow(radius: 6, y: 2)
                    .padding(.bottom, 18)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .automatic) {
                Picker("Window", selection: $manager.selectedTimeRange) {
                    ForEach(TimeRangeOption.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .help("Select historical analysis window")

                Button {
                    manager.collectOnceNow()
                } label: {
                    Label("Sample Now", systemImage: "arrow.clockwise")
                }
                .help("Collect an immediate telemetry snapshot")

                Button {
                    manager.isPaused.toggle()
                } label: {
                    Label(
                        manager.isPaused ? "Resume" : "Pause",
                        systemImage: manager.isPaused ? "play.fill" : "pause.fill"
                    )
                }
                .help(manager.isPaused ? "Resume background collection" : "Pause background collection")

                ExportMenuButton(manager: manager, compact: false)
            }
        }
        .frame(minWidth: 960, minHeight: 650)
    }
}

// MARK: - 1. Overview & Sufficiency Verdict Tab

private struct OverviewTabView: View {
    @ObservedObject var manager: MonitoringManager
    @Binding var selectedSection: DashboardSection

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                // Hardware Profile Banner
                HStack(spacing: 14) {
                    Image(systemName: "laptopcomputer")
                        .font(.system(size: 28))
                        .foregroundStyle(.blue)
                        .frame(width: 48, height: 48)
                        .background(Color.blue.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 12))

                    VStack(alignment: .leading, spacing: 3) {
                        Text(manager.hardware.formattedSummary)
                            .font(.headline)
                        Text("macOS \(manager.hardware.osVersion) • Monitored Window: \(manager.selectedTimeRange.title) (\(ByteFormatter.formatDuration(manager.evaluation.durationSeconds)), \(manager.evaluation.sampleCount) samples)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Button {
                        selectedSection = .export
                    } label: {
                        Label("Export for LLM / Raw", systemImage: "sparkles")
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding(14)
                .background(Color(nsColor: .controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.primary.opacity(0.06), lineWidth: 1)
                )

                // MacBook Sufficiency Verdict Hero Card
                sufficiencyHeroCard

                // Live System Telemetry Cards
                if let s = manager.latestSample {
                    LazyVGrid(
                        columns: [
                            GridItem(.flexible()),
                            GridItem(.flexible()),
                            GridItem(.flexible()),
                            GridItem(.flexible())
                        ],
                        spacing: 14
                    ) {
                        StatMetricCard(
                            title: "CPU Load",
                            primaryValue: String(format: "%.1f%%", s.cpuTotalPercent),
                            subtitle: String(format: "Peak Core %.0f%% • p95 %.1f%%", s.peakCorePercent, manager.evaluation.p95CpuPercent),
                            icon: "cpu",
                            accentColor: .blue,
                            badgeText: String(format: "Load %.1f", s.loadAvg1m),
                            badgeColor: .blue
                        )

                        StatMetricCard(
                            title: "Unified Memory",
                            primaryValue: ByteFormatter.formatBytes(s.memoryUsedBytes),
                            subtitle: "Comp: \(ByteFormatter.formatBytes(s.memoryCompressedBytes)) • Swap: \(ByteFormatter.formatBytes(s.swapUsedBytes))",
                            icon: "memorychip",
                            accentColor: s.memoryPressure.color,
                            badgeText: s.memoryPressure.shortLabel,
                            badgeColor: s.memoryPressure.color
                        )

                        StatMetricCard(
                            title: "GPU & Thermal",
                            primaryValue: String(format: "%.1f%% GPU", s.gpuUtilizationPercent),
                            subtitle: "GPU Mem: \(ByteFormatter.formatBytes(s.gpuMemoryBytes)) • p95: \(String(format: "%.0f%%", manager.evaluation.p95GpuPercent))",
                            icon: "thermometer.medium",
                            accentColor: s.thermalState.color,
                            badgeText: s.thermalState.shortLabel,
                            badgeColor: s.thermalState.color
                        )

                        StatMetricCard(
                            title: "Power & Disk Space",
                            primaryValue: String(format: "%.1f W", s.powerWatts),
                            subtitle: "SSD Free: \(ByteFormatter.formatBytes(s.diskTotalBytes > s.diskUsedBytes ? s.diskTotalBytes - s.diskUsedBytes : 0))",
                            icon: "bolt.fill",
                            accentColor: .green,
                            badgeText: String(format: "%.0f%% %@", s.batteryPercent, s.isOnACPower ? "AC" : "Batt"),
                            badgeColor: .green
                        )
                    }
                }

                // Bottom Split: Bottleneck Findings & Top Apps
                HStack(alignment: .top, spacing: 16) {
                    // Bottleneck Findings
                    VStack(alignment: .leading, spacing: 10) {
                        Label("Hardware Sizing Findings & Bottleneck Checks", systemImage: "magnifyingglass.circle.fill")
                            .font(.headline)

                        ForEach(manager.evaluation.findings) { event in
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: iconForSeverity(event.severity))
                                    .foregroundStyle(colorForSeverity(event.severity))
                                    .font(.title3)
                                    .padding(.top, 2)

                                VStack(alignment: .leading, spacing: 3) {
                                    HStack {
                                        Text(event.title)
                                            .font(.subheadline.weight(.semibold))
                                        Spacer()
                                        Text(event.category)
                                            .font(.caption2.weight(.medium))
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(Color.secondary.opacity(0.14))
                                            .clipShape(Capsule())
                                    }
                                    Text(event.detail)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(10)
                            .background(Color.secondary.opacity(0.06))
                            .clipShape(RoundedRectangle(cornerRadius: 9))
                        }
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color.primary.opacity(0.06), lineWidth: 1)
                    )

                    // Top Resource-Intensive Apps Preview
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Label("Top Resource Consumers (\(manager.selectedTimeRange.title))", systemImage: "square.stack.3d.up.fill")
                                .font(.headline)
                            Spacer()
                            Button("See All") {
                                selectedSection = .apps
                            }
                            .font(.caption)
                        }

                        ForEach(manager.aggregatedApps.prefix(6)) { app in
                            HStack(spacing: 10) {
                                AppIconView(bundlePath: app.bundlePath, size: 22)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(app.displayName)
                                        .font(.subheadline.weight(.medium))
                                        .lineLimit(1)
                                    Text("Peak CPU \(String(format: "%.0f%%", app.peakCpuPercent)) • Peak RAM \(ByteFormatter.formatBytes(app.peakMemoryBytes))")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                VStack(alignment: .trailing, spacing: 1) {
                                    Text(String(format: "%.1f%% avg", app.avgCpuPercent))
                                        .font(.caption.monospacedDigit().weight(.semibold))
                                    Text("\(ByteFormatter.formatBytes(app.avgMemoryBytes)) avg")
                                        .font(.caption2.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                    .padding(16)
                    .frame(width: 360, alignment: .leading)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color.primary.opacity(0.06), lineWidth: 1)
                    )
                }
            }
            .padding(20)
        }
    }

    private var sufficiencyHeroCard: some View {
        let ev = manager.evaluation
        return HStack(spacing: 24) {
            ScoreRingView(score: ev.overallScore, title: "Overall Sizing", size: 84)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Image(systemName: ev.verdictLevel.iconName)
                        .foregroundStyle(ev.verdictLevel.color)
                    Text(ev.verdictLevel.rawValue)
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(ev.verdictLevel.color)
                }

                Text(ev.headline)
                    .font(.title3.weight(.bold))

                Text(ev.recommendation)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            HStack(spacing: 16) {
                ScoreRingView(score: ev.memoryScore, title: "Memory", size: 58)
                ScoreRingView(score: ev.cpuThermalScore, title: "CPU/Thermal", size: 58)
                ScoreRingView(score: ev.gpuScore, title: "GPU", size: 58)
                ScoreRingView(score: ev.ioStorageScore, title: "Disk/IO", size: 58)
            }
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(ev.verdictLevel.color.opacity(0.32), lineWidth: 1.5)
        )
    }

    private func iconForSeverity(_ severity: String) -> String {
        switch severity {
        case "Critical": return "exclamationmark.octagon.fill"
        case "Warning": return "exclamationmark.triangle.fill"
        default: return "checkmark.circle.fill"
        }
    }

    private func colorForSeverity(_ severity: String) -> Color {
        switch severity {
        case "Critical": return .red
        case "Warning": return .orange
        default: return .green
        }
    }
}

// MARK: - 4. Export Tab (LLM Markdown Summary & Raw Data)

private struct ExportTabView: View {
    @ObservedObject var manager: MonitoringManager

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                // Two Prominent Export Option Cards
                HStack(alignment: .top, spacing: 16) {
                    // Option 1 Card: LLM-Ready Markdown Summary
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Label("Option 1: LLM-Ready Markdown Summary", systemImage: "sparkles")
                                .font(.headline)
                                .foregroundStyle(.blue)
                            Spacer()
                            Text("Recommended for ChatGPT / Claude / Gemini")
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Color.blue.opacity(0.14))
                                .foregroundStyle(.blue)
                                .clipShape(Capsule())
                        }

                        Text("Generates a structured hardware sizing report with mean/p50/p95/peak telemetry, memory pressure & swap stats, fanless thermal headroom, top applications, and an embedded prompt asking the LLM if your MacBook is sufficient.")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        HStack(spacing: 10) {
                            Button {
                                manager.copyLLMMarkdownToClipboard()
                            } label: {
                                Label("Copy Markdown to Clipboard", systemImage: "doc.on.clipboard")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)

                            Button {
                                manager.saveLLMMarkdownToFile()
                            } label: {
                                Label("Save .md File...", systemImage: "arrow.down.doc")
                            }
                        }
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color.blue.opacity(0.30), lineWidth: 1.2)
                    )

                    // Option 2 Card: Raw Telemetry Data
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Label("Option 2: Raw Telemetry Data", systemImage: "tablecells")
                                .font(.headline)
                            Spacer()
                            Text("JSON & CSV")
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Color.secondary.opacity(0.15))
                                .clipShape(Capsule())
                        }

                        Text("Exports raw time-series system samples (CPU, single-core peak, memory breakdown, swap, pageouts, thermal state, GPU, disk R/W, network Rx/Tx, watts) and per-app aggregations for custom scripts or notebooks.")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        HStack(spacing: 10) {
                            Button {
                                manager.exportRawJSONToFile()
                            } label: {
                                Label("Export Raw JSON (.json)...", systemImage: "curlybraces")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)

                            Button {
                                manager.exportRawCSVToFile()
                            } label: {
                                Label("Export Raw CSV (.csv)...", systemImage: "tablecells")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                    )
                }

                // Optional User Context Notes
                VStack(alignment: .leading, spacing: 8) {
                    Text("Optional Context Notes for the LLM Report")
                        .font(.subheadline.weight(.semibold))
                    TextField(
                        "e.g., I bought a MacBook Air M5 (16GB) and want to know if I should keep it or upgrade to 24GB RAM / MacBook Pro before my return window ends...",
                        text: $manager.userContextNotes
                    )
                    .textFieldStyle(.roundedBorder)
                }
                .padding(14)
                .background(Color(nsColor: .controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 12))

                // Live Markdown Preview
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Label("Live Preview: LLM-Ready Markdown Report (\(manager.selectedTimeRange.title))", systemImage: "doc.text.magnifyingglass")
                            .font(.headline)
                        Spacer()
                        Button {
                            manager.copyLLMMarkdownToClipboard()
                        } label: {
                            Label("Copy Report", systemImage: "doc.on.clipboard")
                        }
                        .controlSize(.small)
                    }

                    let markdownText = manager.generateCurrentLLMMarkdown()
                    ScrollView {
                        Text(markdownText)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                    }
                    .frame(height: 360)
                    .background(Color(nsColor: .textBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                    )
                }
                .padding(16)
                .background(Color(nsColor: .controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .padding(20)
        }
    }
}

// MARK: - 5. Settings & Storage Tab

private struct SettingsTabView: View {
    @ObservedObject var manager: MonitoringManager
    @State private var confirmClearHistory: Bool = false

    var body: some View {
        Form {
            Section("Background Sampling & Menu Bar") {
                Picker("Sampling Interval", selection: $manager.samplingIntervalSeconds) {
                    Text("Every 2 seconds (High Resolution)").tag(2.0)
                    Text("Every 5 seconds (Recommended)").tag(5.0)
                    Text("Every 10 seconds (Balanced)").tag(10.0)
                    Text("Every 15 seconds").tag(15.0)
                    Text("Every 30 seconds (Ultra-Low Overhead)").tag(30.0)
                    Text("Every 60 seconds").tag(60.0)
                }

                Toggle("Show Live CPU % and RAM in Menu Bar", isOn: $manager.showLiveStatsInMenuBar)

                Toggle("Launch at Login", isOn: Binding(
                    get: { manager.launchAtLogin },
                    set: { manager.toggleLaunchAtLogin($0) }
                ))
            }

            Section("Local SQLite Database & Retention") {
                Picker("Keep Historical Telemetry For", selection: $manager.retentionDays) {
                    Text("7 Days").tag(7)
                    Text("14 Days").tag(14)
                    Text("30 Days (Recommended)").tag(30)
                    Text("90 Days").tag(90)
                }

                LabeledContent("Database Location") {
                    HStack {
                        Text(manager.database.dbPath)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button("Reveal in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: manager.database.dbPath)])
                        }
                        .controlSize(.small)
                    }
                }

                LabeledContent("Stored Samples") {
                    Text("\(manager.totalStoredSamples) system snapshots (\(ByteFormatter.formatBytes(manager.databaseSizeBytes)))")
                }

                Button(role: .destructive) {
                    confirmClearHistory = true
                } label: {
                    Label("Clear All Stored History...", systemImage: "trash")
                }
                .confirmationDialog(
                    "Are you sure you want to delete all historical telemetry?",
                    isPresented: $confirmClearHistory
                ) {
                    Button("Delete All History", role: .destructive) {
                        manager.clearAllHistory()
                    }
                    Button("Cancel", role: .cancel) {}
                }
            }

            Section("About UtilizationAnalyzer") {
                LabeledContent("Hardware Detected") {
                    Text(manager.hardware.formattedSummary)
                }
                LabeledContent("License") {
                    Text("MIT Open Source License")
                }
            }
        }
        .formStyle(.grouped)
        .padding(12)
    }
}
