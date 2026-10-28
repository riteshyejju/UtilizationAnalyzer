import SwiftUI
import AppKit

public final class AppDelegate: NSObject, NSApplicationDelegate {
    public func applicationDidFinishLaunching(_ notification: Notification) {
        // Ensure app activates and shows the dashboard window on first launch,
        // while keeping the MenuBarExtra running in the background when windows close.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Switch to accessory mode when dashboard window is closed so it runs silently in the menu bar!
        NSApp.setActivationPolicy(.accessory)
        return false
    }
}

@main
public struct UtilizationAnalyzerMain {
    public static func main() {
        let args = CommandLine.arguments
        if args.contains("--self-test") {
            let success = SelfTestRunner.runAllTests()
            exit(success ? 0 : 1)
        } else if args.contains("--print-llm-report") {
            SelfTestRunner.printLiveLLMReport()
            exit(0)
        } else {
            UtilizationAnalyzerApp.main()
        }
    }
}

public struct UtilizationAnalyzerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var manager = MonitoringManager()

    public init() {}

    public var body: some Scene {
        Window("UtilizationAnalyzer — MacBook Sizing & Telemetry", id: "dashboard") {
            DashboardView(manager: manager)
        }
        .defaultSize(width: 1080, height: 740)

        MenuBarExtra {
            MenuBarPopoverView(manager: manager)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "gauge.with.dots.needle.67percent")
                if !manager.menuBarTitleText.isEmpty {
                    Text(manager.menuBarTitleText)
                        .font(.system(.caption, design: .monospaced))
                }
            }
        }
        .menuBarExtraStyle(.window)
    }
}

// MARK: - Self-Test & CLI Verification Runner

public enum SelfTestRunner {
    public static func runAllTests() -> Bool {
        print("=== UtilizationAnalyzer Self-Test Suite ===")

        // 1. Hardware Profile
        let hw = HardwareProfile.current()
        print("[1/7] Hardware Profile: \(hw.formattedSummary)")
        guard hw.physicalMemoryBytes > 0 && hw.totalCores > 0 else {
            print("FAIL: Invalid hardware profile")
            return false
        }

        // 2. System Metrics Collector
        let sysCollector = SystemMetricsCollector(hardware: hw)
        let procCollector = ProcessMetricsCollector()
        usleep(250_000) // 250ms delta for real CPU/IO rate calculation
        let sample1 = sysCollector.collectSample()
        let apps1 = procCollector.collectTopApps(limit: 15)
        usleep(250_000)
        let sample2 = sysCollector.collectSample()
        let apps2 = procCollector.collectTopApps(limit: 15)

        print(String(
            format: "[2/7] System Sample: CPU=%.1f%% (PeakCore=%.1f%%), MemUsed=%@ (Comp=%@, Swap=%@, Pressure=%@), GPU=%.1f%%, Thermal=%@, Power=%.1fW",
            sample2.cpuTotalPercent,
            sample2.peakCorePercent,
            ByteFormatter.formatBytes(sample2.memoryUsedBytes),
            ByteFormatter.formatBytes(sample2.memoryCompressedBytes),
            ByteFormatter.formatBytes(sample2.swapUsedBytes),
            sample2.memoryPressure.shortLabel,
            sample2.gpuUtilizationPercent,
            sample2.thermalState.shortLabel,
            sample2.powerWatts
        ))
        guard sample2.memoryTotalBytes == hw.physicalMemoryBytes else {
            print("FAIL: Sample memory total mismatch")
            return false
        }

        print("[3/7] Process Collector: Captured \(apps2.count) grouped applications.")
        if let firstApp = apps2.first {
            print("      Top App: \(firstApp.displayName) (Procs=\(firstApp.processCount), CPU=\(String(format: "%.1f%%", firstApp.cpuPercent)), RAM=\(ByteFormatter.formatBytes(firstApp.memoryBytes)))")
        }

        // 3. SQLite Database Persistence
        let tempDBPath = NSTemporaryDirectory() + "ua_selftest_\(UUID().uuidString).sqlite"
        defer {
            try? FileManager.default.removeItem(atPath: tempDBPath)
            try? FileManager.default.removeItem(atPath: tempDBPath + "-wal")
            try? FileManager.default.removeItem(atPath: tempDBPath + "-shm")
        }

        let db = MetricsDatabase(customPath: tempDBPath)
        db.insertSample(sample1, apps: apps1)
        db.insertSample(sample2, apps: apps2)

        let fetchedSamples = db.fetchSystemSamples(since: Date().addingTimeInterval(-60), maxPoints: 100)
        let fetchedApps = db.fetchAggregatedApps(since: Date().addingTimeInterval(-60), limit: 15)
        print("[4/7] SQLite Persistence: Stored & queried \(fetchedSamples.count) system samples and \(fetchedApps.count) aggregated apps.")
        guard fetchedSamples.count == 2 else {
            print("FAIL: Expected 2 system samples in DB, got \(fetchedSamples.count)")
            return false
        }

        // 4. Sufficiency Analyzer
        let evaluation = SufficiencyAnalyzer.evaluate(
            hardware: hw,
            samples: fetchedSamples,
            topApps: fetchedApps
        )
        print("[5/7] Sufficiency Evaluation: Overall=\(evaluation.overallScore)/100 (\(evaluation.verdictLevel.rawValue)) | Mem=\(evaluation.memoryScore) | CPU/Therm=\(evaluation.cpuThermalScore) | GPU=\(evaluation.gpuScore)")
        guard (0...100).contains(evaluation.overallScore) else {
            print("FAIL: Invalid sufficiency score")
            return false
        }

        // 5. Exporters (Option 1: LLM Markdown | Option 2: Raw JSON & CSV with Per-Sample App Attribution)
        let appsBySample = db.fetchAppsBySampleId(since: Date().addingTimeInterval(-60))
        let markdown = DataExporter.generateLLMMarkdownReport(
            hardware: hw,
            rangeLabel: "Last 1 Hour",
            samples: fetchedSamples,
            topApps: fetchedApps,
            evaluation: evaluation,
            appsBySampleId: appsBySample,
            userNotes: "Self-test validation run."
        )
        let jsonData = DataExporter.generateRawJSON(
            hardware: hw,
            rangeLabel: "Last 1 Hour",
            samples: fetchedSamples,
            topApps: fetchedApps,
            evaluation: evaluation,
            appsBySampleId: appsBySample
        )
        let csvString = DataExporter.generateRawCSV(samples: fetchedSamples, appsBySampleId: appsBySample)

        guard markdown.contains("# MacBook Hardware Sufficiency & Utilization Report"),
              markdown.contains("## 6. Peak & Spike Attribution"),
              csvString.contains("top_cpu_app_1"),
              csvString.contains("top_apps_breakdown"),
              let jsonData, jsonData.count > 100,
              csvString.components(separatedBy: "\n").count >= 3 else {
            print("FAIL: Export validation failed")
            return false
        }
        print("[6/7] Exporters Verified: Markdown (\(markdown.count) chars), JSON (\(jsonData.count) bytes), CSV (\(csvString.count) chars).")
        // 6. Export range resolution & bounded queries
        let cal = Calendar.current
        let now = Date()
        let threeMonths = ExportInterval.resolve(
            mode: .lastN, dashboardRange: .last1h, lastNValue: 3, lastNUnit: .months,
            customStart: now, customEnd: now, now: now
        )
        let expectedStart = cal.date(byAdding: .month, value: -3, to: now)!
        guard abs(threeMonths.start.timeIntervalSince(expectedStart)) < 1,
              threeMonths.label == "Last 3 Months", threeMonths.fileTag == "3mo" else {
            print("FAIL: Last-N-months resolution incorrect (\(threeMonths.label), \(threeMonths.fileTag))")
            return false
        }
        let oneDay = ExportInterval.resolve(
            mode: .lastN, dashboardRange: .last1h, lastNValue: 1, lastNUnit: .days,
            customStart: now, customEnd: now, now: now
        )
        guard oneDay.label == "Last 1 Day" else {
            print("FAIL: Singular unit label incorrect (\(oneDay.label))")
            return false
        }
        // Custom range given in reverse order should be normalized to whole days
        let tenDaysAgo = cal.date(byAdding: .day, value: -10, to: now)!
        let custom = ExportInterval.resolve(
            mode: .custom, dashboardRange: .last1h, lastNValue: 1, lastNUnit: .days,
            customStart: now, customEnd: tenDaysAgo, now: now
        )
        guard custom.start == cal.startOfDay(for: tenDaysAgo),
              custom.end > now, custom.end < cal.startOfDay(for: now).addingTimeInterval(86400),
              custom.fileTag.contains("_to_") else {
            print("FAIL: Custom range normalization incorrect")
            return false
        }
        // `until` bound must exclude samples after the end date
        let bounded = db.fetchSystemSamples(since: .distantPast, until: Date().addingTimeInterval(-3600), maxPoints: 0)
        guard bounded.isEmpty, db.oldestSampleDate() != nil else {
            print("FAIL: Bounded query returned \(bounded.count) samples, expected 0")
            return false
        }
        print("[7/7] Export Ranges Verified: '\(threeMonths.label)', '\(oneDay.label)', '\(custom.label)'; bounded queries OK.")

        print("=== ALL SELF-TESTS PASSED ===")
        return true
    }

    public static func printLiveLLMReport() {
        let hw = HardwareProfile.current()
        let db = MetricsDatabase()
        var samples = db.fetchSystemSamples(since: Date().addingTimeInterval(-86400), maxPoints: 0)
        var apps = db.fetchAggregatedApps(since: Date().addingTimeInterval(-86400), limit: 25)
        if samples.isEmpty {
            let sys = SystemMetricsCollector(hardware: hw)
            let proc = ProcessMetricsCollector()
            usleep(300_000)
            let s = sys.collectSample()
            let a = proc.collectTopApps(limit: 20)
            db.insertSample(s, apps: a)
            samples = db.fetchSystemSamples(since: Date().addingTimeInterval(-86400), maxPoints: 0)
            apps = db.fetchAggregatedApps(since: Date().addingTimeInterval(-86400), limit: 25)
        }
        let since = Date().addingTimeInterval(-86400)
        let appsBySample = db.fetchAppsBySampleId(since: since)
        let eval = SufficiencyAnalyzer.evaluate(hardware: hw, samples: samples, topApps: apps)
        let report = DataExporter.generateLLMMarkdownReport(
            hardware: hw,
            rangeLabel: "Last 24 Hours",
            samples: samples,
            topApps: apps,
            evaluation: eval,
            appsBySampleId: appsBySample
        )
        print(report)
    }
}
