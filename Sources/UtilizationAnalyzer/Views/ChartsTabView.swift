import SwiftUI
import Charts

public struct ChartsTabView: View {
    @ObservedObject public var manager: MonitoringManager

    public init(manager: MonitoringManager) {
        self.manager = manager
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if manager.historicalSamples.isEmpty {
                    ContentUnavailableView(
                        "Collecting Telemetry Samples...",
                        systemImage: "chart.xyaxis.line",
                        description: Text("Charts will populate automatically every \(Int(manager.samplingIntervalSeconds)) seconds.")
                    )
                    .frame(height: 320)
                } else {
                    // 1. CPU & Single-Core Peak Chart
                    chartCard(
                        title: "CPU Utilization (Multi-Core Total vs. Peak Single Core)",
                        subtitle: String(
                            format: "Avg: %.1f%% • p95: %.1f%% • Peak Multi-Core: %.1f%% • Peak Single Core: %.1f%%",
                            manager.evaluation.avgCpuPercent,
                            manager.evaluation.p95CpuPercent,
                            manager.evaluation.peakCpuPercent,
                            manager.evaluation.peakSingleCorePercent
                        ),
                        icon: "cpu"
                    ) {
                        Chart {
                            ForEach(manager.historicalSamples) { sample in
                                AreaMark(
                                    x: .value("Time", sample.timestamp),
                                    y: .value("Total CPU %", sample.cpuTotalPercent)
                                )
                                .foregroundStyle(
                                    LinearGradient(
                                        colors: [.blue.opacity(0.38), .blue.opacity(0.04)],
                                        startPoint: .top,
                                        endPoint: .bottom
                                    )
                                )

                                LineMark(
                                    x: .value("Time", sample.timestamp),
                                    y: .value("Total CPU %", sample.cpuTotalPercent),
                                    series: .value("Metric", "Total CPU %")
                                )
                                .foregroundStyle(.blue)
                                .lineStyle(StrokeStyle(lineWidth: 2))

                                LineMark(
                                    x: .value("Time", sample.timestamp),
                                    y: .value("Peak Core %", sample.peakCorePercent),
                                    series: .value("Metric", "Peak Core %")
                                )
                                .foregroundStyle(.purple.opacity(0.75))
                                .lineStyle(StrokeStyle(lineWidth: 1.3, dash: [4, 3]))
                            }
                        }
                        .chartYScale(domain: 0...100)
                        .chartYAxis {
                            AxisMarks(position: .leading) { val in
                                AxisGridLine()
                                if let v = val.as(Double.self) {
                                    AxisValueLabel("\(Int(v))%")
                                }
                            }
                        }
                        .frame(height: 190)

                        HStack(spacing: 16) {
                            legendDot(color: .blue, label: "System-Wide CPU %")
                            legendDot(color: .purple, label: "Peak Single-Core % ( Dashed )")
                        }
                        .font(.caption)
                    }

                    // 2. Unified Memory, Compressed RAM & Swap Chart
                    let totalRamGB = max(8.0, manager.hardware.physicalMemoryGB)
                    chartCard(
                        title: "Unified Memory, Compressed RAM & SSD Swap",
                        subtitle: "Avg Used: \(ByteFormatter.formatBytes(manager.evaluation.avgMemoryUsedBytes)) • Peak Used: \(ByteFormatter.formatBytes(manager.evaluation.peakMemoryUsedBytes)) • Peak Swap: \(ByteFormatter.formatBytes(manager.evaluation.peakSwapUsedBytes))",
                        icon: "memorychip"
                    ) {
                        Chart {
                            ForEach(manager.historicalSamples) { sample in
                                let usedGB = Double(sample.memoryUsedBytes) / 1_073_741_824.0
                                let compGB = Double(sample.memoryCompressedBytes) / 1_073_741_824.0
                                let swapGB = Double(sample.swapUsedBytes) / 1_073_741_824.0

                                AreaMark(
                                    x: .value("Time", sample.timestamp),
                                    y: .value("Used GB", usedGB)
                                )
                                .foregroundStyle(
                                    LinearGradient(
                                        colors: [.teal.opacity(0.35), .teal.opacity(0.04)],
                                        startPoint: .top,
                                        endPoint: .bottom
                                    )
                                )

                                LineMark(
                                    x: .value("Time", sample.timestamp),
                                    y: .value("Used GB", usedGB),
                                    series: .value("Memory", "Used RAM")
                                )
                                .foregroundStyle(.teal)
                                .lineStyle(StrokeStyle(lineWidth: 2))

                                LineMark(
                                    x: .value("Time", sample.timestamp),
                                    y: .value("Compressed GB", compGB),
                                    series: .value("Memory", "Compressed")
                                )
                                .foregroundStyle(.orange)
                                .lineStyle(StrokeStyle(lineWidth: 1.6))

                                LineMark(
                                    x: .value("Time", sample.timestamp),
                                    y: .value("Swap GB", swapGB),
                                    series: .value("Memory", "Swap Used")
                                )
                                .foregroundStyle(.red)
                                .lineStyle(StrokeStyle(lineWidth: 1.8))
                            }

                            RuleMark(y: .value("Physical RAM", totalRamGB))
                                .foregroundStyle(.secondary.opacity(0.5))
                                .lineStyle(StrokeStyle(lineWidth: 1, dash: [5, 5]))
                        }
                        .chartYScale(domain: 0...(totalRamGB * 1.1))
                        .chartYAxis {
                            AxisMarks(position: .leading) { val in
                                AxisGridLine()
                                if let v = val.as(Double.self) {
                                    AxisValueLabel(String(format: "%.0f GB", v))
                                }
                            }
                        }
                        .frame(height: 195)

                        HStack(spacing: 16) {
                            legendDot(color: .teal, label: "Used Unified Memory (GB)")
                            legendDot(color: .orange, label: "Compressed Memory (GB)")
                            legendDot(color: .red, label: "SSD Swap Used (GB)")
                        }
                        .font(.caption)
                    }

                    // 3. GPU & System Power / Thermal Chart
                    HStack(alignment: .top, spacing: 16) {
                        chartCard(
                            title: "Apple Silicon GPU Utilization",
                            subtitle: String(
                                format: "Avg: %.1f%% • p95: %.1f%% • Peak: %.1f%%",
                                manager.evaluation.avgGpuPercent,
                                manager.evaluation.p95GpuPercent,
                                manager.evaluation.peakGpuPercent
                            ),
                            icon: "sparkles.tv"
                        ) {
                            Chart(manager.historicalSamples) { sample in
                                AreaMark(
                                    x: .value("Time", sample.timestamp),
                                    y: .value("GPU %", sample.gpuUtilizationPercent)
                                )
                                .foregroundStyle(
                                    LinearGradient(
                                        colors: [.indigo.opacity(0.38), .indigo.opacity(0.04)],
                                        startPoint: .top,
                                        endPoint: .bottom
                                    )
                                )

                                LineMark(
                                    x: .value("Time", sample.timestamp),
                                    y: .value("GPU %", sample.gpuUtilizationPercent)
                                )
                                .foregroundStyle(.indigo)
                                .lineStyle(StrokeStyle(lineWidth: 2))
                            }
                            .chartYScale(domain: 0...100)
                            .frame(height: 160)
                        }

                        chartCard(
                            title: "Power Draw (Watts) & Thermal Headroom",
                            subtitle: String(
                                format: "Avg Power: %.1f W • Peak: %.1f W • Elevated Thermal: %.1f%% of time",
                                manager.evaluation.avgPowerWatts,
                                manager.evaluation.peakPowerWatts,
                                manager.evaluation.thermalElevatedPercentTime
                            ),
                            icon: "bolt.fill"
                        ) {
                            Chart(manager.historicalSamples) { sample in
                                AreaMark(
                                    x: .value("Time", sample.timestamp),
                                    y: .value("Watts", sample.powerWatts)
                                )
                                .foregroundStyle(
                                    LinearGradient(
                                        colors: [.green.opacity(0.35), .green.opacity(0.04)],
                                        startPoint: .top,
                                        endPoint: .bottom
                                    )
                                )

                                LineMark(
                                    x: .value("Time", sample.timestamp),
                                    y: .value("Watts", sample.powerWatts)
                                )
                                .foregroundStyle(sample.thermalState == .nominal ? Color.green : Color.orange)
                                .lineStyle(StrokeStyle(lineWidth: 2))
                            }
                            .frame(height: 160)
                        }
                    }

                    // 4. Disk I/O & Network Throughput
                    HStack(alignment: .top, spacing: 16) {
                        chartCard(
                            title: "Disk I/O Throughput (MB/s)",
                            subtitle: String(
                                format: "Peak Read: %.1f MB/s • Peak Write: %.1f MB/s",
                                manager.evaluation.peakDiskReadMBps,
                                manager.evaluation.peakDiskWriteMBps
                            ),
                            icon: "internaldrive"
                        ) {
                            Chart {
                                ForEach(manager.historicalSamples) { sample in
                                    LineMark(
                                        x: .value("Time", sample.timestamp),
                                        y: .value("Read MB/s", sample.diskReadBytesPerSec / 1_048_576.0),
                                        series: .value("IO", "Read")
                                    )
                                    .foregroundStyle(.blue)

                                    LineMark(
                                        x: .value("Time", sample.timestamp),
                                        y: .value("Write MB/s", sample.diskWriteBytesPerSec / 1_048_576.0),
                                        series: .value("IO", "Write")
                                    )
                                    .foregroundStyle(.pink)
                                }
                            }
                            .frame(height: 150)

                            HStack(spacing: 14) {
                                legendDot(color: .blue, label: "Read MB/s")
                                legendDot(color: .pink, label: "Write MB/s")
                            }
                            .font(.caption)
                        }

                        chartCard(
                            title: "Network Throughput (MB/s)",
                            subtitle: "Live Download (Rx) & Upload (Tx) Rate",
                            icon: "network"
                        ) {
                            Chart {
                                ForEach(manager.historicalSamples) { sample in
                                    LineMark(
                                        x: .value("Time", sample.timestamp),
                                        y: .value("Rx MB/s", sample.netRxBytesPerSec / 1_048_576.0),
                                        series: .value("Net", "Download")
                                    )
                                    .foregroundStyle(.cyan)

                                    LineMark(
                                        x: .value("Time", sample.timestamp),
                                        y: .value("Tx MB/s", sample.netTxBytesPerSec / 1_048_576.0),
                                        series: .value("Net", "Upload")
                                    )
                                    .foregroundStyle(.mint)
                                }
                            }
                            .frame(height: 150)

                            HStack(spacing: 14) {
                                legendDot(color: .cyan, label: "Download (Rx MB/s)")
                                legendDot(color: .mint, label: "Upload (Tx MB/s)")
                            }
                            .font(.caption)
                        }
                    }
                }
            }
            .padding(20)
        }
    }

    private func chartCard<Content: View>(
        title: String,
        subtitle: String,
        icon: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(title, systemImage: icon)
                    .font(.headline)
                Spacer()
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }

    private func legendDot(color: Color, label: String) -> some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(label)
                .foregroundStyle(.secondary)
        }
    }
}
