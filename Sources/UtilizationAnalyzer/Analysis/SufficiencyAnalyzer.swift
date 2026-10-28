import Foundation

public enum SufficiencyAnalyzer {
    public static func evaluate(
        hardware: HardwareProfile,
        samples: [SystemSample],
        topApps: [AggregatedAppUsage]
    ) -> SufficiencyEvaluation {
        guard !samples.isEmpty else {
            return emptyEvaluation(hardware: hardware)
        }

        let count = samples.count
        let firstTS = samples.first?.timestamp ?? Date()
        let lastTS = samples.last?.timestamp ?? Date()
        let duration = max(1.0, lastTS.timeIntervalSince(firstTS))

        // Extract arrays for percentile math
        let cpuTotals = samples.map(\.cpuTotalPercent).sorted()
        let peakCores = samples.map(\.peakCorePercent).sorted()
        let memUsed = samples.map(\.memoryUsedBytes).sorted()
        let memCompressed = samples.map(\.memoryCompressedBytes).sorted()
        let swapUsed = samples.map(\.swapUsedBytes).sorted()
        let gpus = samples.map(\.gpuUtilizationPercent).sorted()
        let powers = samples.map(\.powerWatts).sorted()
        let diskReadsMB = samples.map { $0.diskReadBytesPerSec / 1_048_576.0 }.sorted()
        let diskWritesMB = samples.map { $0.diskWriteBytesPerSec / 1_048_576.0 }.sorted()

        let avgCpu = cpuTotals.reduce(0, +) / Double(count)
        let p95Cpu = percentile(cpuTotals, p: 0.95)
        let peakCpu = cpuTotals.last ?? 0
        let peakSingleCore = peakCores.last ?? 0

        let avgMem = UInt64(memUsed.map { Double($0) }.reduce(0, +) / Double(count))
        let p95Mem = percentileUInt64(memUsed, p: 0.95)
        let peakMem = memUsed.last ?? 0
        let peakComp = memCompressed.last ?? 0
        let peakSwap = swapUsed.last ?? 0
        let avgSwap = UInt64(swapUsed.map { Double($0) }.reduce(0, +) / Double(count))

        let yellowCount = samples.filter { $0.memoryPressure == .warning }.count
        let redCount = samples.filter { $0.memoryPressure == .critical }.count
        let yellowPct = (Double(yellowCount) / Double(count)) * 100.0
        let redPct = (Double(redCount) / Double(count)) * 100.0

        let thermalElevatedCount = samples.filter { $0.thermalState != .nominal }.count
        let thermalSeriousCount = samples.filter {
            $0.thermalState == .serious || $0.thermalState == .critical
        }.count
        let thermalElevatedPct = (Double(thermalElevatedCount) / Double(count)) * 100.0
        let thermalSeriousPct = (Double(thermalSeriousCount) / Double(count)) * 100.0

        let avgGpu = gpus.reduce(0, +) / Double(count)
        let p95Gpu = percentile(gpus, p: 0.95)
        let peakGpu = gpus.last ?? 0

        let avgPower = powers.reduce(0, +) / Double(count)
        let peakPower = powers.last ?? 0

        let peakDiskReadMB = diskReadsMB.last ?? 0
        let peakDiskWriteMB = diskWritesMB.last ?? 0

        // 1. Score Memory (0 - 100)
        var memScore = 100.0
        let ramBytes = max(1, Double(hardware.physicalMemoryBytes))
        let peakSwapGB = Double(peakSwap) / 1_073_741_824.0
        let peakCompRatio = Double(peakComp) / ramBytes

        memScore -= min(40.0, redPct * 2.5)
        memScore -= min(25.0, yellowPct * 0.8)
        if peakSwapGB > 0.5 {
            memScore -= min(30.0, (peakSwapGB - 0.5) * 6.0)
        }
        if peakCompRatio > 0.20 {
            memScore -= min(15.0, (peakCompRatio - 0.20) * 40.0)
        }
        let finalMemScore = Int(max(10, min(100, round(memScore))))

        // 2. Score CPU & Thermal (0 - 100)
        var cpuScore = 100.0
        cpuScore -= min(45.0, thermalSeriousPct * 2.5)
        cpuScore -= min(20.0, max(0, thermalElevatedPct - thermalSeriousPct) * 0.6)
        if p95Cpu > 65.0 {
            cpuScore -= min(25.0, (p95Cpu - 65.0) * 0.8)
        }
        if avgCpu > 45.0 {
            cpuScore -= min(15.0, (avgCpu - 45.0) * 0.5)
        }
        let finalCpuScore = Int(max(10, min(100, round(cpuScore))))

        // 3. Score GPU (0 - 100)
        var gpuScore = 100.0
        if p95Gpu > 70.0 {
            gpuScore -= min(30.0, (p95Gpu - 70.0) * 1.0)
        }
        if avgGpu > 50.0 {
            gpuScore -= min(20.0, (avgGpu - 50.0) * 0.6)
        }
        let finalGpuScore = Int(max(15, min(100, round(gpuScore))))

        // 4. Score Disk & Storage (0 - 100)
        var ioScore = 100.0
        if let latest = samples.last, latest.diskTotalBytes > 0 {
            let freePct = 100.0 - latest.diskUsedPercent
            if freePct < 10.0 {
                ioScore -= 35.0
            } else if freePct < 20.0 {
                ioScore -= 15.0
            }
        }
        let finalIoScore = Int(max(20, min(100, round(ioScore))))

        // Weighted Overall Score (Memory and CPU/Thermal carry highest weight on MacBook Air)
        let overall = Int(round(
            Double(finalMemScore) * 0.42 +
            Double(finalCpuScore) * 0.36 +
            Double(finalGpuScore) * 0.12 +
            Double(finalIoScore) * 0.10
        ))

        let verdict: SufficiencyVerdictLevel
        if overall >= 85 {
            verdict = .optimal
        } else if overall >= 70 {
            verdict = .comfortable
        } else if overall >= 52 {
            verdict = .borderline
        } else {
            verdict = .constrained
        }

        // Build actionable findings
        var findings: [BottleneckEvent] = []
        let totalRamGB = Int(round(hardware.physicalMemoryGB))

        // Memory Finding
        if redPct > 1.0 || peakSwapGB >= 4.0 {
            findings.append(BottleneckEvent(
                category: "Unified Memory",
                severity: "Critical",
                title: "Significant Memory Pressure & Swap Usage",
                detail: String(
                    format: "Peak swap reached %@ with %.1f%% time in Yellow and %.1f%% in Red pressure. %d GB Unified RAM is tight for this workload; upgrading to the next RAM tier would reduce SSD swap wear and stutters.",
                    ByteFormatter.formatBytes(peakSwap), yellowPct, redPct, totalRamGB
                )
            ))
        } else if yellowPct > 5.0 || peakSwapGB >= 1.0 {
            findings.append(BottleneckEvent(
                category: "Unified Memory",
                severity: "Warning",
                title: "Moderate Memory Compression / Swap Activity",
                detail: String(
                    format: "Peak swap reached %@ (peak compressed RAM: %@). %d GB RAM handles daily tasks but has limited headroom during heavy multitasking.",
                    ByteFormatter.formatBytes(peakSwap), ByteFormatter.formatBytes(peakComp), totalRamGB
                )
            ))
        } else {
            findings.append(BottleneckEvent(
                category: "Unified Memory",
                severity: "Info",
                title: "\(totalRamGB) GB Unified Memory is Well-Sized",
                detail: String(
                    format: "Memory pressure stayed Nominal %.1f%% of the time with only %@ peak swap and %@ p95 memory usage.",
                    max(0, 100.0 - yellowPct - redPct),
                    ByteFormatter.formatBytes(peakSwap),
                    ByteFormatter.formatBytes(p95Mem)
                )
            ))
        }

        // Thermal & Sustained CPU Finding
        if thermalSeriousPct > 2.0 {
            findings.append(BottleneckEvent(
                category: "Thermal & CPU",
                severity: "Critical",
                title: "Sustained Thermal Throttling Detected",
                detail: String(
                    format: "System spent %.1f%% of monitored time in Serious/Critical thermal state (p95 CPU: %.1f%%). A fanless MacBook Air will throttle under this sustained load; an actively cooled MacBook Pro would sustain higher clocks.",
                    thermalSeriousPct, p95Cpu
                )
            ))
        } else if thermalElevatedPct > 10.0 || p95Cpu > 70.0 {
            findings.append(BottleneckEvent(
                category: "Thermal & CPU",
                severity: "Warning",
                title: "Warm Sustained CPU Bursts",
                detail: String(
                    format: "95th percentile CPU was %.1f%% (peak %.1f%%) with %.1f%% time in Fair/Warm thermal state. Short bursts are fast, though prolonged multi-core renders may warm the chassis.",
                    p95Cpu, peakCpu, thermalElevatedPct
                )
            ))
        } else {
            findings.append(BottleneckEvent(
                category: "Thermal & CPU",
                severity: "Info",
                title: "Cool & Quiet Fanless Operation",
                detail: String(
                    format: "Average CPU utilization was %.1f%% (p95: %.1f%%, single-core peak: %.1f%%) with %.1f%% of time in Nominal (Cool) thermal state.",
                    avgCpu, p95Cpu, peakSingleCore, 100.0 - thermalElevatedPct
                )
            ))
        }

        // GPU Finding
        if p95Gpu > 75.0 {
            findings.append(BottleneckEvent(
                category: "GPU",
                severity: "Warning",
                title: "Heavy GPU Utilization",
                detail: String(
                    format: "GPU p95 utilization reached %.1f%% (peak %.1f%%). Graphics/ML workloads are actively stressing the integrated GPU cores.",
                    p95Gpu, peakGpu
                )
            ))
        } else {
            findings.append(BottleneckEvent(
                category: "GPU",
                severity: "Info",
                title: "Ample GPU Headroom",
                detail: String(
                    format: "Average GPU utilization was %.1f%% (p95: %.1f%%, peak: %.1f%%).",
                    avgGpu, p95Gpu, peakGpu
                )
            ))
        }

        // Top App Finding
        if let topApp = topApps.first {
            findings.append(BottleneckEvent(
                category: "Top Workload",
                severity: "Info",
                title: "Primary Resource Consumer: \(topApp.displayName)",
                detail: String(
                    format: "%@ averaged %.1f%% CPU (peak %.1f%%) and %@ RAM (peak %@) across up to %d processes.",
                    topApp.displayName,
                    topApp.avgCpuPercent,
                    topApp.peakCpuPercent,
                    ByteFormatter.formatBytes(topApp.avgMemoryBytes),
                    ByteFormatter.formatBytes(topApp.peakMemoryBytes),
                    topApp.maxProcessCount
                )
            ))
        }

        let headline: String
        let recommendation: String
        switch verdict {
        case .optimal:
            headline = "Your \(hardware.chipName) (\(totalRamGB) GB) handles this workload effortlessly."
            recommendation = "Both unified memory and fanless thermal headroom remain well within safe limits. You do not need a higher spec machine for this usage pattern."
        case .comfortable:
            headline = "Your \(hardware.chipName) is a solid match with occasional heavy bursts."
            recommendation = "Your Mac handles day-to-day workflows well, with minor compression or warm bursts during peak multitasking. Keep monitoring during your heaviest work sessions."
        case .borderline:
            headline = "Noticeable memory or thermal pressure during peak usage."
            recommendation = finalMemScore < finalCpuScore
                ? "Unified memory is your primary constraint. If you plan to keep this Mac for 3+ years or grow your workflow, consider upgrading to the next RAM tier."
                : "Sustained multi-core CPU load is warming the fanless chassis. If you run long builds/renders daily, an actively cooled MacBook Pro may suit you better."
        case .constrained:
            headline = "This workload frequently pushes past your Mac's comfortable limits."
            recommendation = finalMemScore < finalCpuScore
                ? "Frequent swap usage and elevated memory pressure indicate \(totalRamGB) GB RAM is insufficient for your active apps. Upgrading Unified Memory is strongly recommended."
                : "Heavy sustained CPU/GPU load and thermal throttling indicate your workload would benefit from a MacBook Pro with active cooling and more cores."
        }

        return SufficiencyEvaluation(
            overallScore: overall,
            memoryScore: finalMemScore,
            cpuThermalScore: finalCpuScore,
            gpuScore: finalGpuScore,
            ioStorageScore: finalIoScore,
            verdictLevel: verdict,
            headline: headline,
            recommendation: recommendation,
            findings: findings,
            sampleCount: count,
            durationSeconds: duration,
            avgCpuPercent: avgCpu,
            p95CpuPercent: p95Cpu,
            peakCpuPercent: peakCpu,
            peakSingleCorePercent: peakSingleCore,
            avgMemoryUsedBytes: avgMem,
            p95MemoryUsedBytes: p95Mem,
            peakMemoryUsedBytes: peakMem,
            peakCompressedBytes: peakComp,
            peakSwapUsedBytes: peakSwap,
            avgSwapUsedBytes: avgSwap,
            memoryYellowPercentTime: yellowPct,
            memoryRedPercentTime: redPct,
            thermalElevatedPercentTime: thermalElevatedPct,
            thermalSeriousOrCriticalPercentTime: thermalSeriousPct,
            avgGpuPercent: avgGpu,
            p95GpuPercent: p95Gpu,
            peakGpuPercent: peakGpu,
            avgPowerWatts: avgPower,
            peakPowerWatts: peakPower,
            peakDiskReadMBps: peakDiskReadMB,
            peakDiskWriteMBps: peakDiskWriteMB
        )
    }

    public static func percentile(_ sorted: [Double], p: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let clampedP = min(1.0, max(0.0, p))
        let idx = Int(round(clampedP * Double(sorted.count - 1)))
        return sorted[min(sorted.count - 1, max(0, idx))]
    }

    public static func percentileUInt64(_ sorted: [UInt64], p: Double) -> UInt64 {
        guard !sorted.isEmpty else { return 0 }
        let clampedP = min(1.0, max(0.0, p))
        let idx = Int(round(clampedP * Double(sorted.count - 1)))
        return sorted[min(sorted.count - 1, max(0, idx))]
    }

    private static func emptyEvaluation(hardware: HardwareProfile) -> SufficiencyEvaluation {
        SufficiencyEvaluation(
            overallScore: 100,
            memoryScore: 100,
            cpuThermalScore: 100,
            gpuScore: 100,
            ioStorageScore: 100,
            verdictLevel: .optimal,
            headline: "Collecting initial telemetry on \(hardware.chipName)...",
            recommendation: "Keep UtilizationAnalyzer running in the menu bar while you go through your normal workday to build an accurate sizing profile.",
            findings: [],
            sampleCount: 0,
            durationSeconds: 0,
            avgCpuPercent: 0,
            p95CpuPercent: 0,
            peakCpuPercent: 0,
            peakSingleCorePercent: 0,
            avgMemoryUsedBytes: 0,
            p95MemoryUsedBytes: 0,
            peakMemoryUsedBytes: 0,
            peakCompressedBytes: 0,
            peakSwapUsedBytes: 0,
            avgSwapUsedBytes: 0,
            memoryYellowPercentTime: 0,
            memoryRedPercentTime: 0,
            thermalElevatedPercentTime: 0,
            thermalSeriousOrCriticalPercentTime: 0,
            avgGpuPercent: 0,
            p95GpuPercent: 0,
            peakGpuPercent: 0,
            avgPowerWatts: 0,
            peakPowerWatts: 0,
            peakDiskReadMBps: 0,
            peakDiskWriteMBps: 0
        )
    }
}
