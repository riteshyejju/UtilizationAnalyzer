import Foundation
import Combine
import AppKit
import ServiceManagement

@MainActor
public final class MonitoringManager: ObservableObject {
    public nonisolated let hardware: HardwareProfile
    public nonisolated let database: MetricsDatabase

    private nonisolated let systemCollector: SystemMetricsCollector
    private nonisolated let processCollector: ProcessMetricsCollector
    private nonisolated let collectorQueue = DispatchQueue(label: "com.riteshyejju.UtilizationAnalyzer.collector", qos: .utility)
    private var timer: DispatchSourceTimer?

    // Published Live & Historical State
    @Published public private(set) var latestSample: SystemSample?
    @Published public private(set) var liveTopApps: [AppUsageSnapshot] = []
    @Published public private(set) var historicalSamples: [SystemSample] = []
    @Published public private(set) var aggregatedApps: [AggregatedAppUsage] = []
    @Published public private(set) var evaluation: SufficiencyEvaluation
    @Published public private(set) var totalStoredSamples: Int = 0
    @Published public private(set) var databaseSizeBytes: UInt64 = 0

    // User Controls & Preferences
    @Published public var selectedTimeRange: TimeRangeOption = .last1h {
        didSet {
            refreshHistoricalData()
        }
    }

    @Published public var isPaused: Bool = false {
        didSet {
            if isPaused {
                stopTimer()
            } else {
                startTimer()
            }
        }
    }

    @Published public var samplingIntervalSeconds: Double {
        didSet {
            UserDefaults.standard.set(samplingIntervalSeconds, forKey: "samplingIntervalSeconds")
            if !isPaused {
                startTimer()
            }
        }
    }

    @Published public var retentionDays: Int {
        didSet {
            UserDefaults.standard.set(retentionDays, forKey: "retentionDays")
            database.pruneOldSamples(olderThanDays: retentionDays)
        }
    }

    @Published public var showLiveStatsInMenuBar: Bool {
        didSet {
            UserDefaults.standard.set(showLiveStatsInMenuBar, forKey: "showLiveStatsInMenuBar")
        }
    }

    @Published public var userContextNotes: String {
        didSet {
            UserDefaults.standard.set(userContextNotes, forKey: "userContextNotes")
        }
    }

    @Published public var launchAtLogin: Bool = false
    @Published public var statusToast: String?

    public init(database: MetricsDatabase = MetricsDatabase()) {
        let hw = HardwareProfile.current()
        self.hardware = hw
        self.database = database
        self.systemCollector = SystemMetricsCollector(hardware: hw)
        self.processCollector = ProcessMetricsCollector()
        self.evaluation = SufficiencyAnalyzer.evaluate(hardware: hw, samples: [], topApps: [])

        let savedInterval = UserDefaults.standard.double(forKey: "samplingIntervalSeconds")
        self.samplingIntervalSeconds = savedInterval >= 2.0 ? savedInterval : 5.0

        let savedRetention = UserDefaults.standard.integer(forKey: "retentionDays")
        self.retentionDays = savedRetention > 0 ? savedRetention : 30

        if UserDefaults.standard.object(forKey: "showLiveStatsInMenuBar") != nil {
            self.showLiveStatsInMenuBar = UserDefaults.standard.bool(forKey: "showLiveStatsInMenuBar")
        } else {
            self.showLiveStatsInMenuBar = true
        }

        self.userContextNotes = UserDefaults.standard.string(forKey: "userContextNotes") ?? ""
        self.launchAtLogin = (SMAppService.mainApp.status == .enabled)

        database.pruneOldSamples(olderThanDays: self.retentionDays)
        refreshHistoricalData()
        collectOnceNow()
        startTimer()
    }

    public func startTimer() {
        stopTimer()
        let interval = max(2.0, samplingIntervalSeconds)
        let newTimer = DispatchSource.makeTimerSource(queue: collectorQueue)
        newTimer.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(250))
        newTimer.setEventHandler { [weak self] in
            self?.performBackgroundCollection()
        }
        newTimer.resume()
        self.timer = newTimer
    }

    public func stopTimer() {
        timer?.cancel()
        timer = nil
    }

    public func collectOnceNow() {
        collectorQueue.async { [weak self] in
            self?.performBackgroundCollection()
        }
    }

    private nonisolated func performBackgroundCollection() {
        let sysSample = systemCollector.collectSample()
        let topApps = processCollector.collectTopApps(limit: 25)
        database.insertSample(sysSample, apps: topApps)

        let totalSamples = database.totalSampleCount()
        let dbSize = database.databaseSizeBytes()

        Task { @MainActor [weak self] in
            guard let self else { return }
            self.latestSample = sysSample
            self.liveTopApps = topApps
            self.totalStoredSamples = totalSamples
            self.databaseSizeBytes = dbSize
            self.refreshHistoricalData()
        }
    }

    public func refreshHistoricalData() {
        let startDate = selectedTimeRange.startDate
        let hw = hardware
        let db = database

        collectorQueue.async { [weak self] in
            let samples = db.fetchSystemSamples(since: startDate, maxPoints: 360)
            let apps = db.fetchAggregatedApps(since: startDate, limit: 40)
            let eval = SufficiencyAnalyzer.evaluate(hardware: hw, samples: samples, topApps: apps)
            let totalCount = db.totalSampleCount()
            let dbSize = db.databaseSizeBytes()

            Task { @MainActor [weak self] in
                guard let self else { return }
                self.historicalSamples = samples
                self.aggregatedApps = apps
                self.evaluation = eval
                self.totalStoredSamples = totalCount
                self.databaseSizeBytes = dbSize
            }
        }
    }

    public func clearAllHistory() {
        database.clearAllData()
        refreshHistoricalData()
        showToast("Cleared all historical telemetry.")
    }

    public func toggleLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLogin = (SMAppService.mainApp.status == .enabled)
            showToast(launchAtLogin ? "Enabled Launch at Login." : "Disabled Launch at Login.")
        } catch {
            launchAtLogin = (SMAppService.mainApp.status == .enabled)
            showToast("Launch at Login requires running from /Applications bundle.")
        }
    }

    // MARK: - Export Actions (Option 1: LLM Markdown | Option 2: Raw Data)

    public func generateCurrentLLMMarkdown() -> String {
        let allRangeSamples = database.fetchSystemSamples(since: selectedTimeRange.startDate, maxPoints: 0)
        let eval = SufficiencyAnalyzer.evaluate(hardware: hardware, samples: allRangeSamples, topApps: aggregatedApps)
        return DataExporter.generateLLMMarkdownReport(
            hardware: hardware,
            timeRange: selectedTimeRange,
            samples: allRangeSamples,
            topApps: aggregatedApps,
            evaluation: eval,
            userNotes: userContextNotes
        )
    }

    public func copyLLMMarkdownToClipboard() {
        let md = generateCurrentLLMMarkdown()
        DataExporter.copyToClipboard(md)
        showToast("Copied LLM-Ready Markdown Report to Clipboard!")
    }

    public func saveLLMMarkdownToFile() {
        let md = generateCurrentLLMMarkdown()
        guard let data = md.data(using: .utf8) else { return }
        let filename = "MacBook-Sufficiency-LLM-Report-\(selectedTimeRange.rawValue).md"
        DataExporter.saveFileInteractively(defaultFilename: filename, content: data) { [weak self] url in
            if let url {
                self?.showToast("Saved LLM Report to \(url.lastPathComponent)")
            }
        }
    }

    public func exportRawJSONToFile() {
        let rawSamples = database.fetchSystemSamples(since: selectedTimeRange.startDate, maxPoints: 0)
        let eval = SufficiencyAnalyzer.evaluate(hardware: hardware, samples: rawSamples, topApps: aggregatedApps)
        guard let data = DataExporter.generateRawJSON(
            hardware: hardware,
            timeRange: selectedTimeRange,
            samples: rawSamples,
            topApps: aggregatedApps,
            evaluation: eval
        ) else { return }

        let filename = "UtilizationAnalyzer-RawData-\(selectedTimeRange.rawValue).json"
        DataExporter.saveFileInteractively(defaultFilename: filename, content: data) { [weak self] url in
            if let url {
                self?.showToast("Saved Raw JSON to \(url.lastPathComponent)")
            }
        }
    }

    public func exportRawCSVToFile() {
        let rawSamples = database.fetchSystemSamples(since: selectedTimeRange.startDate, maxPoints: 0)
        let csv = DataExporter.generateRawCSV(samples: rawSamples)
        guard let data = csv.data(using: .utf8) else { return }

        let filename = "UtilizationAnalyzer-RawData-\(selectedTimeRange.rawValue).csv"
        DataExporter.saveFileInteractively(defaultFilename: filename, content: data) { [weak self] url in
            if let url {
                self?.showToast("Saved Raw CSV to \(url.lastPathComponent)")
            }
        }
    }

    public func showToast(_ message: String) {
        statusToast = message
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 3_500_000_000)
            if self?.statusToast == message {
                self?.statusToast = nil
            }
        }
    }

    public var menuBarTitleText: String {
        guard showLiveStatsInMenuBar, let s = latestSample else {
            return ""
        }
        let cpuInt = Int(round(s.cpuTotalPercent))
        let memGB = String(format: "%.1fG", Double(s.memoryUsedBytes) / 1_073_741_824.0)
        return " \(cpuInt)% • \(memGB)"
    }
}
