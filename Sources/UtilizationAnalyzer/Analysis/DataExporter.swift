import Foundation
import AppKit

public struct SampleWithApps: Codable, Sendable {
    public let sample: SystemSample
    public let topApps: [AppUsageSnapshot]
}

public struct RawExportPayload: Codable, Sendable {
    public let exportedAt: Date
    public let timeRange: String
    public let hardware: HardwareProfile
    public let evaluation: SufficiencyEvaluation
    public let systemSamples: [SystemSample]
    public let aggregatedApps: [AggregatedAppUsage]
    public let samplesWithApps: [SampleWithApps]
}

public enum DataExporter {

    // MARK: - Option 1: LLM-Ready Markdown Summary

    public static func generateLLMMarkdownReport(
        hardware: HardwareProfile,
        rangeLabel: String,
        samples: [SystemSample],
        topApps: [AggregatedAppUsage],
        evaluation: SufficiencyEvaluation,
        appsBySampleId: [Int64: [AppUsageSnapshot]] = [:],
        userNotes: String = ""
    ) -> String {
        let df = ISO8601DateFormatter()
        df.formatOptions = [.withInternetDateTime]

        let firstDate = samples.first.map { df.string(from: $0.timestamp) } ?? "N/A"
        let lastDate = samples.last.map { df.string(from: $0.timestamp) } ?? "N/A"

        let cpuTotals = samples.map(\.cpuTotalPercent).sorted()
        let cpuP50 = SufficiencyAnalyzer.percentile(cpuTotals, p: 0.50)

        let memUsed = samples.map(\.memoryUsedBytes).sorted()
        let memP50 = SufficiencyAnalyzer.percentileUInt64(memUsed, p: 0.50)

        let compBytes = samples.map(\.memoryCompressedBytes).sorted()
        let compAvg = samples.isEmpty ? 0 : UInt64(compBytes.map { Double($0) }.reduce(0, +) / Double(samples.count))
        let compP50 = SufficiencyAnalyzer.percentileUInt64(compBytes, p: 0.50)
        let compP95 = SufficiencyAnalyzer.percentileUInt64(compBytes, p: 0.95)

        let swapBytes = samples.map(\.swapUsedBytes).sorted()
        let swapP50 = SufficiencyAnalyzer.percentileUInt64(swapBytes, p: 0.50)
        let swapP95 = SufficiencyAnalyzer.percentileUInt64(swapBytes, p: 0.95)

        let gpuTotals = samples.map(\.gpuUtilizationPercent).sorted()
        let gpuP50 = SufficiencyAnalyzer.percentile(gpuTotals, p: 0.50)

        let diskReads = samples.map(\.diskReadBytesPerSec).sorted()
        let diskWrites = samples.map(\.diskWriteBytesPerSec).sorted()
        let avgDiskRead = samples.isEmpty ? 0 : diskReads.reduce(0, +) / Double(samples.count)
        let avgDiskWrite = samples.isEmpty ? 0 : diskWrites.reduce(0, +) / Double(samples.count)
        let p95DiskRead = SufficiencyAnalyzer.percentile(diskReads, p: 0.95)
        let p95DiskWrite = SufficiencyAnalyzer.percentile(diskWrites, p: 0.95)

        let powers = samples.map(\.powerWatts).sorted()
        let powerP50 = SufficiencyAnalyzer.percentile(powers, p: 0.50)
        let powerP95 = SufficiencyAnalyzer.percentile(powers, p: 0.95)

        let latestDiskTotal = samples.last?.diskTotalBytes ?? 0
        let latestDiskUsed = samples.last?.diskUsedBytes ?? 0
        let latestDiskPct = samples.last?.diskUsedPercent ?? 0

        var md: [String] = []

        md.append("# MacBook Hardware Sufficiency & Utilization Report")
        md.append("")
        md.append("> **Instructions for the AI / LLM Assistant:**")
        md.append("> I am evaluating whether my current Mac (`\(hardware.chipName)`, `\(Int(round(hardware.physicalMemoryGB))) GB Unified Memory`, model `\(hardware.modelIdentifier)`) is sufficient for my real-world workload, or if I should upgrade to a higher Unified Memory tier or an actively cooled system.")
        md.append("> Please analyze the telemetry below—paying close attention to **Unified Memory pressure**, **Swap & Compressed RAM**, **Thermal States**, **CPU/GPU p95 bursts**, **per-application resource consumption**, and **exact app attribution during peak spikes**—and give me a clear, data-backed recommendation.")
        md.append("")

        if !userNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            md.append("## User Context & Workload Notes")
            md.append(userNotes.trimmingCharacters(in: .whitespacesAndNewlines))
            md.append("")
        }

        md.append("## 1. Hardware & Monitoring Window")
        md.append("- **Chip / Processor:** \(hardware.chipName)")
        md.append("- **Model Identifier:** `\(hardware.modelIdentifier)`")
        md.append("- **Unified Memory (RAM):** \(Int(round(hardware.physicalMemoryGB))) GB (\(ByteFormatter.formatBytes(hardware.physicalMemoryBytes)))")
        md.append("- **CPU Cores:** \(hardware.totalCores) Total (\(hardware.performanceCores) Performance + \(hardware.efficiencyCores) Efficiency)")
        md.append("- **macOS Version:** \(hardware.osVersion)")
        md.append("- **Time Window:** \(rangeLabel) (`\(firstDate)` to `\(lastDate)`)")
        md.append("- **Monitored Duration:** \(ByteFormatter.formatDuration(evaluation.durationSeconds)) (\(evaluation.sampleCount) samples)")
        if latestDiskTotal > 0 {
            md.append(String(format: "- **Internal SSD Usage:** %@ / %@ (%.1f%% used)",
                             ByteFormatter.formatBytes(latestDiskUsed),
                             ByteFormatter.formatBytes(latestDiskTotal),
                             latestDiskPct))
        }
        md.append("")

        md.append("## 2. Automated Sufficiency Scorecard")
        md.append("- **Overall Sufficiency Score:** **\(evaluation.overallScore) / 100** (\(evaluation.verdictLevel.rawValue))")
        md.append("- **Memory Headroom Score:** \(evaluation.memoryScore) / 100")
        md.append("- **CPU & Thermal Headroom Score:** \(evaluation.cpuThermalScore) / 100")
        md.append("- **GPU Headroom Score:** \(evaluation.gpuScore) / 100")
        md.append("- **Disk & I/O Score:** \(evaluation.ioStorageScore) / 100")
        md.append("- **Automated Summary:** \(evaluation.headline) \(evaluation.recommendation)")
        md.append("")

        md.append("## 3. System Telemetry Distribution (Mean / p50 / p95 / Peak)")
        md.append("| Metric | Average | Median (p50) | 95th Percentile (p95) | Peak (Max) |")
        md.append("| :--- | :---: | :---: | :---: | :---: |")
        md.append(String(format: "| **Total CPU Utilization** | %.1f%% | %.1f%% | %.1f%% | %.1f%% |",
                         evaluation.avgCpuPercent, cpuP50, evaluation.p95CpuPercent, evaluation.peakCpuPercent))
        md.append(String(format: "| **Peak Single-Core CPU** | — | — | — | %.1f%% |",
                         evaluation.peakSingleCorePercent))
        md.append(String(format: "| **GPU Utilization** | %.1f%% | %.1f%% | %.1f%% | %.1f%% |",
                         evaluation.avgGpuPercent, gpuP50, evaluation.p95GpuPercent, evaluation.peakGpuPercent))
        md.append("| **Unified Memory Used** | \(ByteFormatter.formatBytes(evaluation.avgMemoryUsedBytes)) | \(ByteFormatter.formatBytes(memP50)) | \(ByteFormatter.formatBytes(evaluation.p95MemoryUsedBytes)) | \(ByteFormatter.formatBytes(evaluation.peakMemoryUsedBytes)) |")
        md.append("| **Compressed Memory** | \(ByteFormatter.formatBytes(compAvg)) | \(ByteFormatter.formatBytes(compP50)) | \(ByteFormatter.formatBytes(compP95)) | \(ByteFormatter.formatBytes(evaluation.peakCompressedBytes)) |")
        md.append("| **Swap Used on SSD** | \(ByteFormatter.formatBytes(evaluation.avgSwapUsedBytes)) | \(ByteFormatter.formatBytes(swapP50)) | \(ByteFormatter.formatBytes(swapP95)) | \(ByteFormatter.formatBytes(evaluation.peakSwapUsedBytes)) |")
        md.append("| **Disk Read Throughput** | \(ByteFormatter.formatRate(avgDiskRead)) | — | \(ByteFormatter.formatRate(p95DiskRead)) | \(String(format: "%.1f MB/s", evaluation.peakDiskReadMBps)) |")
        md.append("| **Disk Write Throughput** | \(ByteFormatter.formatRate(avgDiskWrite)) | — | \(ByteFormatter.formatRate(p95DiskWrite)) | \(String(format: "%.1f MB/s", evaluation.peakDiskWriteMBps)) |")
        md.append(String(format: "| **System Power Draw** | %.1f W | %.1f W | %.1f W | %.1f W |",
                         evaluation.avgPowerWatts, powerP50, powerP95, evaluation.peakPowerWatts))
        md.append("")

        md.append("## 4. Critical Bottleneck & Throttling Indicators")
        let nominalMemPct = max(0.0, 100.0 - evaluation.memoryYellowPercentTime - evaluation.memoryRedPercentTime)
        let nominalThermPct = max(0.0, 100.0 - evaluation.thermalElevatedPercentTime)
        md.append(String(format: "- **Memory Pressure Breakdown:** `%.1f%%` Nominal (Green) | `%.1f%%` Elevated (Yellow) | `%.1f%%` Critical (Red)",
                         nominalMemPct, evaluation.memoryYellowPercentTime, evaluation.memoryRedPercentTime))
        md.append(String(format: "- **Thermal State Breakdown:** `%.1f%%` Nominal (Cool) | `%.1f%%` Elevated (Fair/Warm) | `%.1f%%` Throttling (Serious/Critical)",
                         nominalThermPct, evaluation.thermalElevatedPercentTime, evaluation.thermalSeriousOrCriticalPercentTime))
        for f in evaluation.findings {
            md.append("- **[\(f.severity) — \(f.category)] \(f.title):** \(f.detail)")
        }
        md.append("")

        md.append("## 5. Top Applications by Resource Consumption")
        md.append("*(Note: Helper processes such as browser renderers and IDE language servers are grouped into their parent application bundle. Per-app CPU % uses standard macOS Activity Monitor scaling where 100% = 1 full core.)*")
        md.append("")
        md.append("| Application | Max Procs | Avg CPU % | Peak CPU % | Avg RAM | Peak RAM | Avg Disk R/W | Samples |")
        md.append("| :--- | :---: | :---: | :---: | :---: | :---: | :---: | :---: |")
        for app in topApps.prefix(20) {
            let ioStr = "\(ByteFormatter.formatRate(app.avgDiskReadBytesPerSec)) / \(ByteFormatter.formatRate(app.avgDiskWriteBytesPerSec))"
            md.append(String(
                format: "| **%@** | %d | %.1f%% | %.1f%% | %@ | %@ | %@ | %d |",
                app.displayName,
                app.maxProcessCount,
                app.avgCpuPercent,
                app.peakCpuPercent,
                ByteFormatter.formatBytes(app.avgMemoryBytes),
                ByteFormatter.formatBytes(app.peakMemoryBytes),
                ioStr,
                app.sampleCount
            ))
        }
        md.append("")

        // Section 6: Spike & Burst Attribution
        if !samples.isEmpty {
            md.append("## 6. Peak & Spike Attribution (Exact Apps Behind Top Bursts)")
            md.append("| Event | Timestamp | System State | Top Apps at Exact Timestamp |")
            md.append("| :--- | :---: | :--- | :--- |")

            // Top 3 distinct CPU spikes
            let topCpuSamples = samples.sorted { $0.cpuTotalPercent > $1.cpuTotalPercent }.prefix(3)
            for (idx, s) in topCpuSamples.enumerated() {
                let apps = appsBySampleId[s.id] ?? []
                let topCpuApps = apps.sorted { $0.cpuPercent > $1.cpuPercent }.prefix(3)
                    .map { String(format: "%@ (%.1f%% CPU, %@)", $0.displayName, $0.cpuPercent, ByteFormatter.formatBytes($0.memoryBytes)) }
                    .joined(separator: "; ")
                let sysDesc = String(format: "CPU %.1f%% (Peak Core %.0f%%), RAM %@, %@",
                                     s.cpuTotalPercent, s.peakCorePercent,
                                     ByteFormatter.formatBytes(s.memoryUsedBytes), s.thermalState.shortLabel)
                md.append("| **CPU Burst #\(idx + 1)** | `\(df.string(from: s.timestamp))` | \(sysDesc) | \(topCpuApps.isEmpty ? "N/A" : topCpuApps) |")
            }

            // Peak Memory sample
            if let peakMemSample = samples.max(by: { $0.memoryUsedBytes < $1.memoryUsedBytes }) {
                let apps = appsBySampleId[peakMemSample.id] ?? []
                let topMemApps = apps.sorted { $0.memoryBytes > $1.memoryBytes }.prefix(3)
                    .map { String(format: "%@ (%@ RAM, %.1f%% CPU)", $0.displayName, ByteFormatter.formatBytes($0.memoryBytes), $0.cpuPercent) }
                    .joined(separator: "; ")
                let sysDesc = "RAM \(ByteFormatter.formatBytes(peakMemSample.memoryUsedBytes)) (Comp \(ByteFormatter.formatBytes(peakMemSample.memoryCompressedBytes)), Swap \(ByteFormatter.formatBytes(peakMemSample.swapUsedBytes)), \(peakMemSample.memoryPressure.shortLabel))"
                md.append("| **Peak Memory** | `\(df.string(from: peakMemSample.timestamp))` | \(sysDesc) | \(topMemApps.isEmpty ? "N/A" : topMemApps) |")
            }

            // Peak Disk I/O sample
            if let peakDiskSample = samples.max(by: {
                ($0.diskReadBytesPerSec + $0.diskWriteBytesPerSec) < ($1.diskReadBytesPerSec + $1.diskWriteBytesPerSec)
            }), (peakDiskSample.diskReadBytesPerSec + peakDiskSample.diskWriteBytesPerSec) > 0 {
                let apps = appsBySampleId[peakDiskSample.id] ?? []
                let topDiskApps = apps.sorted {
                    ($0.diskReadBytesPerSec + $0.diskWriteBytesPerSec) > ($1.diskReadBytesPerSec + $1.diskWriteBytesPerSec)
                }.prefix(3)
                    .map { "\($0.displayName) (R: \(ByteFormatter.formatRate($0.diskReadBytesPerSec)), W: \(ByteFormatter.formatRate($0.diskWriteBytesPerSec)))" }
                    .joined(separator: "; ")
                let sysDesc = "Read \(ByteFormatter.formatRate(peakDiskSample.diskReadBytesPerSec)) / Write \(ByteFormatter.formatRate(peakDiskSample.diskWriteBytesPerSec))"
                md.append("| **Peak Disk I/O** | `\(df.string(from: peakDiskSample.timestamp))` | \(sysDesc) | \(topDiskApps.isEmpty ? "N/A" : topDiskApps) |")
            }
            md.append("")
        }

        md.append("## 7. Questions for Your Analysis")
        md.append("1. **Unified Memory Sizing:** Based on my compressed RAM, swap usage, and memory pressure percentages, is `\(Int(round(hardware.physicalMemoryGB))) GB` enough for the next 3–4 years, or should I upgrade to a higher RAM configuration?")
        md.append("2. **Thermal & Sustained Load Headroom:** Based on my CPU p95/peak load, thermal state distribution, and wattage, am I losing meaningful performance to thermal throttling?")
        md.append("3. **Application Bottlenecks:** Which specific apps in Sections 5 and 6 are driving the highest memory or CPU pressure during spikes, and what concrete steps can I take to optimize them?")

        return md.joined(separator: "\n")
    }

    // MARK: - Option 2: Raw Data Export (JSON & CSV with Per-Sample Process Attribution)

    public static func generateRawJSON(
        hardware: HardwareProfile,
        rangeLabel: String,
        samples: [SystemSample],
        topApps: [AggregatedAppUsage],
        evaluation: SufficiencyEvaluation,
        appsBySampleId: [Int64: [AppUsageSnapshot]] = [:]
    ) -> Data? {
        let samplesWithApps = samples.map { s in
            SampleWithApps(sample: s, topApps: appsBySampleId[s.id] ?? [])
        }
        let payload = RawExportPayload(
            exportedAt: Date(),
            timeRange: rangeLabel,
            hardware: hardware,
            evaluation: evaluation,
            systemSamples: samples,
            aggregatedApps: topApps,
            samplesWithApps: samplesWithApps
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try? encoder.encode(payload)
    }

    public static func generateRawCSV(
        samples: [SystemSample],
        appsBySampleId: [Int64: [AppUsageSnapshot]] = [:]
    ) -> String {
        let df = ISO8601DateFormatter()
        var lines: [String] = []
        lines.append([
            "timestamp",
            "cpu_user_pct",
            "cpu_system_pct",
            "cpu_total_pct",
            "peak_core_pct",
            "load_1m",
            "load_5m",
            "load_15m",
            "mem_used_bytes",
            "mem_app_bytes",
            "mem_wired_bytes",
            "mem_compressed_bytes",
            "mem_cached_bytes",
            "mem_total_bytes",
            "swap_used_bytes",
            "swap_total_bytes",
            "pageouts_per_sec",
            "memory_pressure",
            "thermal_state",
            "gpu_utilization_pct",
            "gpu_memory_bytes",
            "disk_read_bps",
            "disk_write_bps",
            "disk_used_bytes",
            "disk_total_bytes",
            "net_rx_bps",
            "net_tx_bps",
            "battery_pct",
            "is_charging",
            "is_on_ac_power",
            "power_watts",
            "top_cpu_app_1",
            "top_cpu_app_1_pct",
            "top_cpu_app_1_mem_mb",
            "top_cpu_app_2",
            "top_cpu_app_2_pct",
            "top_cpu_app_2_mem_mb",
            "top_cpu_app_3",
            "top_cpu_app_3_pct",
            "top_cpu_app_3_mem_mb",
            "top_mem_app_1",
            "top_mem_app_1_mb",
            "top_mem_app_2",
            "top_mem_app_2_mb",
            "top_mem_app_3",
            "top_mem_app_3_mb",
            "top_disk_app_1",
            "top_disk_app_1_rw_bps",
            "top_apps_breakdown"
        ].joined(separator: ","))

        for s in samples {
            let apps = appsBySampleId[s.id] ?? []
            let byCpu = apps.sorted { $0.cpuPercent > $1.cpuPercent }
            let byMem = apps.sorted { $0.memoryBytes > $1.memoryBytes }
            let byDisk = apps.sorted {
                ($0.diskReadBytesPerSec + $0.diskWriteBytesPerSec) > ($1.diskReadBytesPerSec + $1.diskWriteBytesPerSec)
            }

            func cpuSlot(_ idx: Int) -> [String] {
                guard idx < byCpu.count else { return ["", "0.00", "0.0"] }
                let a = byCpu[idx]
                return [
                    escapeCSV(a.displayName),
                    String(format: "%.2f", a.cpuPercent),
                    String(format: "%.1f", Double(a.memoryBytes) / 1_048_576.0)
                ]
            }

            func memSlot(_ idx: Int) -> [String] {
                guard idx < byMem.count else { return ["", "0.0"] }
                let a = byMem[idx]
                return [
                    escapeCSV(a.displayName),
                    String(format: "%.1f", Double(a.memoryBytes) / 1_048_576.0)
                ]
            }

            let diskSlot: [String]
            if let d = byDisk.first, (d.diskReadBytesPerSec + d.diskWriteBytesPerSec) > 0 {
                diskSlot = [
                    escapeCSV(d.displayName),
                    String(format: "%.1f", d.diskReadBytesPerSec + d.diskWriteBytesPerSec)
                ]
            } else {
                diskSlot = ["", "0.0"]
            }

            // Compact top-5 apps breakdown for this exact timestamp
            let breakdown = apps.prefix(5).map { a in
                String(
                    format: "%@(cpu=%.1f%%,ram=%.0fMB,rw=%.0fKB/s,procs=%d)",
                    a.displayName.replacingOccurrences(of: "\"", with: "'"),
                    a.cpuPercent,
                    Double(a.memoryBytes) / 1_048_576.0,
                    (a.diskReadBytesPerSec + a.diskWriteBytesPerSec) / 1024.0,
                    a.processCount
                )
            }.joined(separator: "; ")

            var row: [String] = [
                df.string(from: s.timestamp),
                String(format: "%.2f", s.cpuUserPercent),
                String(format: "%.2f", s.cpuSystemPercent),
                String(format: "%.2f", s.cpuTotalPercent),
                String(format: "%.2f", s.peakCorePercent),
                String(format: "%.2f", s.loadAvg1m),
                String(format: "%.2f", s.loadAvg5m),
                String(format: "%.2f", s.loadAvg15m),
                "\(s.memoryUsedBytes)",
                "\(s.memoryAppBytes)",
                "\(s.memoryWiredBytes)",
                "\(s.memoryCompressedBytes)",
                "\(s.memoryCachedBytes)",
                "\(s.memoryTotalBytes)",
                "\(s.swapUsedBytes)",
                "\(s.swapTotalBytes)",
                String(format: "%.2f", s.pageoutsPerSec),
                s.memoryPressure.shortLabel,
                s.thermalState.shortLabel,
                String(format: "%.2f", s.gpuUtilizationPercent),
                "\(s.gpuMemoryBytes)",
                String(format: "%.1f", s.diskReadBytesPerSec),
                String(format: "%.1f", s.diskWriteBytesPerSec),
                "\(s.diskUsedBytes)",
                "\(s.diskTotalBytes)",
                String(format: "%.1f", s.netRxBytesPerSec),
                String(format: "%.1f", s.netTxBytesPerSec),
                String(format: "%.1f", s.batteryPercent),
                s.isCharging ? "true" : "false",
                s.isOnACPower ? "true" : "false",
                String(format: "%.2f", s.powerWatts)
            ]
            row.append(contentsOf: cpuSlot(0))
            row.append(contentsOf: cpuSlot(1))
            row.append(contentsOf: cpuSlot(2))
            row.append(contentsOf: memSlot(0))
            row.append(contentsOf: memSlot(1))
            row.append(contentsOf: memSlot(2))
            row.append(contentsOf: diskSlot)
            row.append(escapeCSV(breakdown))

            lines.append(row.joined(separator: ","))
        }

        return lines.joined(separator: "\n")
    }

    private static func escapeCSV(_ value: String) -> String {
        if value.contains(",") || value.contains("\"") || value.contains(";") || value.contains(" ") {
            let escaped = value.replacingOccurrences(of: "\"", with: "\"\"")
            return "\"\(escaped)\""
        }
        return value
    }

    // MARK: - Clipboard & Save Panel Helpers

    @MainActor
    public static func copyToClipboard(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    @MainActor
    public static func saveFileInteractively(
        defaultFilename: String,
        content: Data,
        completion: ((URL?) -> Void)? = nil
    ) {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = defaultFilename
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false

        let response = panel.runModal()
        if response == .OK, let url = panel.url {
            try? content.write(to: url, options: .atomic)
            completion?(url)
        } else {
            completion?(nil)
        }
    }
}
