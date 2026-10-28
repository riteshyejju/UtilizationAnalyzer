import SwiftUI
import AppKit

public struct MenuBarPopoverView: View {
    @ObservedObject public var manager: MonitoringManager
    @Environment(\.openWindow) private var openWindow

    public init(manager: MonitoringManager) {
        self.manager = manager
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack(spacing: 10) {
                Image(systemName: "gauge.with.dots.needle.67percent")
                    .font(.title2)
                    .foregroundStyle(.blue)

                VStack(alignment: .leading, spacing: 2) {
                    Text("UtilizationAnalyzer")
                        .font(.headline)
                    Text("\(manager.hardware.chipName) • \(Int(round(manager.hardware.physicalMemoryGB))) GB RAM")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                // Sufficiency Pill
                HStack(spacing: 4) {
                    Image(systemName: manager.evaluation.verdictLevel.iconName)
                    Text("\(manager.evaluation.overallScore)/100")
                        .fontWeight(.bold)
                }
                .font(.caption)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(manager.evaluation.verdictLevel.color.opacity(0.16))
                .foregroundStyle(manager.evaluation.verdictLevel.color)
                .clipShape(Capsule())
            }

            Divider()

            // Live Metrics Grid
            if let s = manager.latestSample {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                    miniTile(
                        title: "CPU Load",
                        value: String(format: "%.1f%%", s.cpuTotalPercent),
                        detail: String(format: "Peak Core %.0f%% • Load %.1f", s.peakCorePercent, s.loadAvg1m),
                        icon: "cpu",
                        color: s.cpuTotalPercent > 80 ? .orange : .blue
                    )

                    miniTile(
                        title: "Unified Memory",
                        value: "\(ByteFormatter.formatBytes(s.memoryUsedBytes))",
                        detail: "Swap \(ByteFormatter.formatBytes(s.swapUsedBytes)) • \(s.memoryPressure.shortLabel)",
                        icon: "memorychip",
                        color: s.memoryPressure.color
                    )

                    miniTile(
                        title: "GPU & Thermal",
                        value: String(format: "%.0f%% GPU", s.gpuUtilizationPercent),
                        detail: "Thermal: \(s.thermalState.shortLabel)",
                        icon: "thermometer.medium",
                        color: s.thermalState.color
                    )

                    miniTile(
                        title: "Power & Battery",
                        value: String(format: "%.1f W", s.powerWatts),
                        detail: String(format: "%.0f%% %@", s.batteryPercent, s.isOnACPower ? "(AC)" : "(Batt)"),
                        icon: s.isCharging ? "bolt.batteryblock.fill" : "battery.100",
                        color: .green
                    )
                }

                // I/O Bar
                HStack {
                    Label(
                        "Disk R/W: \(ByteFormatter.formatRate(s.diskReadBytesPerSec)) / \(ByteFormatter.formatRate(s.diskWriteBytesPerSec))",
                        systemImage: "internaldrive"
                    )
                    Spacer()
                    Label(
                        "Net: ↓\(ByteFormatter.formatRate(s.netRxBytesPerSec)) ↑\(ByteFormatter.formatRate(s.netTxBytesPerSec))",
                        systemImage: "network"
                    )
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
            } else {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Sampling system telemetry...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 8)
            }

            Divider()

            // Top Active Apps
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Top Active Apps (Live)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("CPU • RAM")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                ForEach(manager.liveTopApps.prefix(5)) { app in
                    HStack(spacing: 8) {
                        AppIconView(bundlePath: app.bundlePath, size: 18)
                        Text(app.displayName)
                            .font(.caption.weight(.medium))
                            .lineLimit(1)
                        if app.processCount > 1 {
                            Text("(\(app.processCount))")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(String(format: "%.1f%%", app.cpuPercent))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(app.cpuPercent > 50 ? .orange : .primary)
                            .frame(width: 48, alignment: .trailing)
                        Text(ByteFormatter.formatBytes(app.memoryBytes))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 58, alignment: .trailing)
                    }
                }
            }

            if let toast = manager.statusToast {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text(toast)
                        .font(.caption)
                        .lineLimit(1)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.green.opacity(0.14))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            Divider()

            // Footer Actions
            HStack(spacing: 8) {
                Button {
                    openDashboardWindow()
                } label: {
                    Label("Open Dashboard", systemImage: "chart.xyaxis.line")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)

                ExportMenuButton(manager: manager, compact: true)
                    .controlSize(.regular)

                Button {
                    manager.isPaused.toggle()
                } label: {
                    Image(systemName: manager.isPaused ? "play.fill" : "pause.fill")
                }
                .help(manager.isPaused ? "Resume background sampling" : "Pause background sampling")

                Button {
                    NSApplication.shared.terminate(nil)
                } label: {
                    Image(systemName: "power")
                }
                .help("Quit UtilizationAnalyzer")
            }
        }
        .padding(14)
        .frame(width: 375)
    }

    private func openDashboardWindow() {
        openWindow(id: "dashboard")
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        for window in NSApp.windows where window.title.contains("UtilizationAnalyzer") {
            window.makeKeyAndOrderFront(nil)
        }
    }

    private func miniTile(title: String, value: String, detail: String, icon: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .foregroundStyle(color)
                Text(title)
                    .foregroundStyle(.secondary)
            }
            .font(.caption2.weight(.medium))

            Text(value)
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .lineLimit(1)

            Text(detail)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 9))
        .overlay(
            RoundedRectangle(cornerRadius: 9)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }
}
