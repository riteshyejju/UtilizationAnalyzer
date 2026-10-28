import Foundation
import Darwin

// MARK: - Memory Pressure Level

public enum MemoryPressureLevel: Int, Codable, CaseIterable, Sendable {
    case nominal = 1
    case warning = 2
    case critical = 4

    public var label: String {
        switch self {
        case .nominal: return "Nominal"
        case .warning: return "Elevated (Yellow)"
        case .critical: return "Critical (Red)"
        }
    }

    public var shortLabel: String {
        switch self {
        case .nominal: return "Normal"
        case .warning: return "Warning"
        case .critical: return "Critical"
        }
    }

    public static func from(rawLevel: Int) -> MemoryPressureLevel {
        switch rawLevel {
        case 4...: return .critical
        case 2...3: return .warning
        default: return .nominal
        }
    }
}

// MARK: - Thermal Level

public enum ThermalLevel: Int, Codable, CaseIterable, Sendable {
    case nominal = 0
    case fair = 1
    case serious = 2
    case critical = 3

    public var label: String {
        switch self {
        case .nominal: return "Nominal (Cool)"
        case .fair: return "Fair (Warm)"
        case .serious: return "Serious (Throttling Likely)"
        case .critical: return "Critical (Heavy Throttling)"
        }
    }

    public var shortLabel: String {
        switch self {
        case .nominal: return "Nominal"
        case .fair: return "Warm"
        case .serious: return "Serious"
        case .critical: return "Critical"
        }
    }

    public static func from(_ state: ProcessInfo.ThermalState) -> ThermalLevel {
        switch state {
        case .nominal: return .nominal
        case .fair: return .fair
        case .serious: return .serious
        case .critical: return .critical
        @unknown default: return .nominal
        }
    }
}

// MARK: - Hardware Profile

public struct HardwareProfile: Codable, Sendable {
    public let modelIdentifier: String
    public let chipName: String
    public let physicalMemoryBytes: UInt64
    public let totalCores: Int
    public let performanceCores: Int
    public let efficiencyCores: Int
    public let osVersion: String
    public let hostName: String

    public var physicalMemoryGB: Double {
        Double(physicalMemoryBytes) / 1_073_741_824.0
    }

    public var formattedSummary: String {
        let memGB = Int(round(physicalMemoryGB))
        let coreBreakdown: String
        if performanceCores > 0 && efficiencyCores > 0 {
            coreBreakdown = "\(totalCores) cores (\(performanceCores)P + \(efficiencyCores)E)"
        } else {
            coreBreakdown = "\(totalCores) cores"
        }
        return "\(chipName) • \(memGB) GB Unified Memory • \(coreBreakdown) • \(modelIdentifier)"
    }

    public static func current() -> HardwareProfile {
        let model = sysctlString("hw.model") ?? "Mac"
        let brand = sysctlString("machdep.cpu.brand_string") ?? "Apple Silicon"
        let mem = ProcessInfo.processInfo.physicalMemory
        let totalCores = ProcessInfo.processInfo.processorCount
        let pCores = sysctlInt("hw.perflevel0.physicalcpu") ?? 0
        let eCores = sysctlInt("hw.perflevel1.physicalcpu") ?? 0
        let osVer = ProcessInfo.processInfo.operatingSystemVersionString
        let host = ProcessInfo.processInfo.hostName

        return HardwareProfile(
            modelIdentifier: model,
            chipName: brand,
            physicalMemoryBytes: mem,
            totalCores: totalCores,
            performanceCores: pCores,
            efficiencyCores: eCores,
            osVersion: osVer,
            hostName: host
        )
    }

    private static func sysctlString(_ name: String) -> String? {
        var size: Int = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func sysctlInt(_ name: String) -> Int? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return Int(value)
    }
}

// MARK: - System Sample

public struct SystemSample: Codable, Identifiable, Sendable {
    public var id: Int64
    public let timestamp: Date

    // CPU
    public let cpuUserPercent: Double
    public let cpuSystemPercent: Double
    public let cpuIdlePercent: Double
    public let cpuTotalPercent: Double
    public let peakCorePercent: Double
    public let loadAvg1m: Double
    public let loadAvg5m: Double
    public let loadAvg15m: Double

    // Memory & Swap
    public let memoryUsedBytes: UInt64
    public let memoryAppBytes: UInt64
    public let memoryWiredBytes: UInt64
    public let memoryCompressedBytes: UInt64
    public let memoryCachedBytes: UInt64
    public let memoryTotalBytes: UInt64
    public let swapUsedBytes: UInt64
    public let swapTotalBytes: UInt64
    public let pageoutsPerSec: Double
    public let memoryPressure: MemoryPressureLevel

    // Thermal & GPU
    public let thermalState: ThermalLevel
    public let gpuUtilizationPercent: Double
    public let gpuMemoryBytes: UInt64

    // Disk Storage & I/O
    public let diskReadBytesPerSec: Double
    public let diskWriteBytesPerSec: Double
    public let diskUsedBytes: UInt64
    public let diskTotalBytes: UInt64

    // Network I/O
    public let netRxBytesPerSec: Double
    public let netTxBytesPerSec: Double

    // Battery & Power
    public let batteryPercent: Double
    public let isCharging: Bool
    public let isOnACPower: Bool
    public let powerWatts: Double

    public var memoryUsedPercent: Double {
        guard memoryTotalBytes > 0 else { return 0 }
        return min(100.0, (Double(memoryUsedBytes) / Double(memoryTotalBytes)) * 100.0)
    }

    public var diskUsedPercent: Double {
        guard diskTotalBytes > 0 else { return 0 }
        return min(100.0, (Double(diskUsedBytes) / Double(diskTotalBytes)) * 100.0)
    }
}

// MARK: - Per-App Snapshot & Aggregated Usage

public struct AppUsageSnapshot: Codable, Identifiable, Sendable {
    public var id: String { appIdentifier }
    public let appIdentifier: String
    public let displayName: String
    public let bundlePath: String?
    public let processCount: Int
    public let cpuPercent: Double
    public let memoryBytes: UInt64
    public let diskReadBytesPerSec: Double
    public let diskWriteBytesPerSec: Double

    public init(
        appIdentifier: String,
        displayName: String,
        bundlePath: String?,
        processCount: Int,
        cpuPercent: Double,
        memoryBytes: UInt64,
        diskReadBytesPerSec: Double,
        diskWriteBytesPerSec: Double
    ) {
        self.appIdentifier = appIdentifier
        self.displayName = displayName
        self.bundlePath = bundlePath
        self.processCount = processCount
        self.cpuPercent = cpuPercent
        self.memoryBytes = memoryBytes
        self.diskReadBytesPerSec = diskReadBytesPerSec
        self.diskWriteBytesPerSec = diskWriteBytesPerSec
    }
}

public struct AggregatedAppUsage: Codable, Identifiable, Sendable {
    public var id: String { appIdentifier }
    public let appIdentifier: String
    public let displayName: String
    public let bundlePath: String?
    public let sampleCount: Int
    public let maxProcessCount: Int
    public let avgCpuPercent: Double
    public let peakCpuPercent: Double
    public let avgMemoryBytes: UInt64
    public let peakMemoryBytes: UInt64
    public let avgDiskReadBytesPerSec: Double
    public let avgDiskWriteBytesPerSec: Double
}

// MARK: - Time Range Filter

public enum TimeRangeOption: String, CaseIterable, Identifiable, Sendable {
    case last15m = "15m"
    case last1h = "1h"
    case last6h = "6h"
    case last24h = "24h"
    case last7d = "7d"
    case allTime = "All"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .last15m: return "Last 15 Min"
        case .last1h: return "Last 1 Hour"
        case .last6h: return "Last 6 Hours"
        case .last24h: return "Last 24 Hours"
        case .last7d: return "Last 7 Days"
        case .allTime: return "All Time"
        }
    }

    public var seconds: TimeInterval? {
        switch self {
        case .last15m: return 15 * 60
        case .last1h: return 3600
        case .last6h: return 6 * 3600
        case .last24h: return 24 * 3600
        case .last7d: return 7 * 24 * 3600
        case .allTime: return nil
        }
    }

    public var startDate: Date {
        if let seconds {
            return Date().addingTimeInterval(-seconds)
        }
        return Date(timeIntervalSince1970: 0)
    }
}

// MARK: - Export Range (independent of the dashboard chart window)

public enum ExportRangeMode: String, CaseIterable, Identifiable, Sendable {
    case dashboard = "Same as Dashboard"
    case lastN = "Last N…"
    case custom = "Custom Dates"
    case allTime = "All Stored Data"

    public var id: String { rawValue }
}

public enum ExportRangeUnit: String, CaseIterable, Identifiable, Sendable {
    case hours = "Hours"
    case days = "Days"
    case weeks = "Weeks"
    case months = "Months"

    public var id: String { rawValue }

    var calendarComponent: Calendar.Component {
        switch self {
        case .hours: return .hour
        case .days: return .day
        case .weeks: return .weekOfYear
        case .months: return .month
        }
    }

    var fileTag: String {
        switch self {
        case .hours: return "h"
        case .days: return "d"
        case .weeks: return "w"
        case .months: return "mo"
        }
    }
}

/// A resolved, concrete export interval.
public struct ExportInterval: Sendable {
    public let start: Date
    public let end: Date
    /// Human-readable label used in the report, e.g. "Last 3 Months" or "Oct 1, 2026 – Oct 27, 2026".
    public let label: String
    /// Short filename-safe tag, e.g. "3mo" or "2026-10-01_to_2026-10-27".
    public let fileTag: String

    public static func resolve(
        mode: ExportRangeMode,
        dashboardRange: TimeRangeOption,
        lastNValue: Int,
        lastNUnit: ExportRangeUnit,
        customStart: Date,
        customEnd: Date,
        now: Date = Date()
    ) -> ExportInterval {
        let cal = Calendar.current
        switch mode {
        case .dashboard:
            return ExportInterval(start: dashboardRange.startDate, end: now,
                                  label: dashboardRange.title, fileTag: dashboardRange.rawValue)
        case .allTime:
            return ExportInterval(start: Date(timeIntervalSince1970: 0), end: now,
                                  label: "All Stored Data", fileTag: "All")
        case .lastN:
            let n = max(1, lastNValue)
            let start = cal.date(byAdding: lastNUnit.calendarComponent, value: -n, to: now) ?? now
            let unitName = n == 1 ? String(lastNUnit.rawValue.dropLast()) : lastNUnit.rawValue
            return ExportInterval(start: start, end: now,
                                  label: "Last \(n) \(unitName)", fileTag: "\(n)\(lastNUnit.fileTag)")
        case .custom:
            // Whole-day semantics: start of the first day through end of the last day.
            let lo = min(customStart, customEnd)
            let hi = max(customStart, customEnd)
            let start = cal.startOfDay(for: lo)
            let endOfDay = cal.date(byAdding: DateComponents(day: 1, second: -1), to: cal.startOfDay(for: hi)) ?? hi
            let display = DateFormatter()
            display.dateStyle = .medium
            display.timeStyle = .none
            let tagFmt = DateFormatter()
            tagFmt.dateFormat = "yyyy-MM-dd"
            return ExportInterval(
                start: start, end: endOfDay,
                label: "\(display.string(from: start)) – \(display.string(from: endOfDay))",
                fileTag: "\(tagFmt.string(from: start))_to_\(tagFmt.string(from: endOfDay))"
            )
        }
    }
}

// MARK: - Sufficiency Evaluation (macOS Hardware Sizing Analysis)

public enum SufficiencyVerdictLevel: String, Codable, Sendable {
    case optimal = "Optimal Match"
    case comfortable = "Good Headroom"
    case borderline = "Borderline / Occasional Bottlenecks"
    case constrained = "Hardware Constrained — Consider Upgrade"
}

public struct BottleneckEvent: Codable, Identifiable, Sendable {
    public var id: String { "\(category)-\(title)" }
    public let category: String
    public let severity: String // "Info", "Warning", "Critical"
    public let title: String
    public let detail: String
}

public struct SufficiencyEvaluation: Codable, Sendable {
    public let overallScore: Int // 0 - 100
    public let memoryScore: Int
    public let cpuThermalScore: Int
    public let gpuScore: Int
    public let ioStorageScore: Int
    public let verdictLevel: SufficiencyVerdictLevel
    public let headline: String
    public let recommendation: String
    public let findings: [BottleneckEvent]

    // Key stats
    public let sampleCount: Int
    public let durationSeconds: TimeInterval
    public let avgCpuPercent: Double
    public let p95CpuPercent: Double
    public let peakCpuPercent: Double
    public let peakSingleCorePercent: Double
    public let avgMemoryUsedBytes: UInt64
    public let p95MemoryUsedBytes: UInt64
    public let peakMemoryUsedBytes: UInt64
    public let peakCompressedBytes: UInt64
    public let peakSwapUsedBytes: UInt64
    public let avgSwapUsedBytes: UInt64
    public let memoryYellowPercentTime: Double
    public let memoryRedPercentTime: Double
    public let thermalElevatedPercentTime: Double
    public let thermalSeriousOrCriticalPercentTime: Double
    public let avgGpuPercent: Double
    public let p95GpuPercent: Double
    public let peakGpuPercent: Double
    public let avgPowerWatts: Double
    public let peakPowerWatts: Double
    public let peakDiskReadMBps: Double
    public let peakDiskWriteMBps: Double
}

// MARK: - Formatting Helpers

public enum ByteFormatter {
    public static func formatBytes(_ bytes: UInt64) -> String {
        let doubleBytes = Double(bytes)
        if doubleBytes >= 1_073_741_824 {
            return String(format: "%.1f GB", doubleBytes / 1_073_741_824.0)
        } else if doubleBytes >= 1_048_576 {
            return String(format: "%.0f MB", doubleBytes / 1_048_576.0)
        } else if doubleBytes >= 1024 {
            return String(format: "%.0f KB", doubleBytes / 1024.0)
        }
        return "\(bytes) B"
    }

    public static func formatRate(_ bytesPerSec: Double) -> String {
        if bytesPerSec >= 1_073_741_824 {
            return String(format: "%.2f GB/s", bytesPerSec / 1_073_741_824.0)
        } else if bytesPerSec >= 1_048_576 {
            return String(format: "%.1f MB/s", bytesPerSec / 1_048_576.0)
        } else if bytesPerSec >= 1024 {
            return String(format: "%.0f KB/s", bytesPerSec / 1024.0)
        }
        return String(format: "%.0f B/s", max(0, bytesPerSec))
    }

    public static func formatDuration(_ seconds: TimeInterval) -> String {
        let totalSeconds = Int(max(0, seconds))
        let days = totalSeconds / 86400
        let hours = (totalSeconds % 86400) / 3600
        let minutes = (totalSeconds % 3600) / 60
        let secs = totalSeconds % 60
        if days > 0 {
            return "\(days)d \(hours)h \(minutes)m"
        } else if hours > 0 {
            return "\(hours)h \(minutes)m"
        } else if minutes > 0 {
            return "\(minutes)m \(secs)s"
        } else {
            return "\(secs)s"
        }
    }
}
