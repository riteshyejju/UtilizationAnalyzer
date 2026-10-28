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
            if exportRangeMode == .dashboard { refreshExportPreview() }
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

    // Export range settings (independent of the dashboard chart window)
    @Published public var exportRangeMode: ExportRangeMode = .lastN { didSet { saveExportSettings() } }
    @Published public var exportLastNValue: Int = 7 { didSet { saveExportSettings() } }
    @Published public var exportLastNUnit: ExportRangeUnit = .days { didSet { saveExportSettings() } }
    @Published public var exportCustomStart: Date = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date() {
        didSet { refreshExportPreview() }
    }
    @Published public var exportCustomEnd: Date = Date() { didSet { refreshExportPreview() } }
    @Published public private(set) var isExporting: Bool = false
    @Published public private(set) var exportPreviewMarkdown: String = ""
    @Published public private(set) var exportPreviewSampleCount: Int = 0
    @Published public private(set) var oldestSampleDate: Date?

    public init(database: MetricsDatabase = MetricsDatabase()) {
        let hw = HardwareProfile.current()
        self.hardware = hw
        self.database = database
        self.systemCollector = SystemMetricsCollector(hardware: hw)
        self.processCollector = ProcessMetricsCollector()
        self.evaluation = SufficiencyAnalyzer.evaluate(hardware: hw, samples: [], topApps: [])

        let savedInterval = UserDefaults.standard.double(forKey: "samplingIntervalSeconds")
        self.samplingIntervalSeconds = savedInterval >= 2.0 ? savedInterval : 5.0

        // 0 = keep forever; default 90 days so "last N months" exports have data to work with
        if UserDefaults.standard.object(forKey: "retentionDays") != nil {
            self.retentionDays = max(0, UserDefaults.standard.integer(forKey: "retentionDays"))
        } else {
            self.retentionDays = 90
        }

        if UserDefaults.standard.object(forKey: "showLiveStatsInMenuBar") != nil {
            self.showLiveStatsInMenuBar = UserDefaults.standard.bool(forKey: "showLiveStatsInMenuBar")
        } else {
            self.showLiveStatsInMenuBar = true
        }

        self.userContextNotes = UserDefaults.standard.string(forKey: "userContextNotes") ?? ""
        self.launchAtLogin = (SMAppService.mainApp.status == .enabled)

        let d = UserDefaults.standard
        if let raw = d.string(forKey: "exportRangeMode"), let mode = ExportRangeMode(rawValue: raw) {
            self.exportRangeMode = mode
        }
        if d.object(forKey: "exportLastNValue") != nil {
            self.exportLastNValue = max(1, d.integer(forKey: "exportLastNValue"))
        }
        if let raw = d.string(forKey: "exportLastNUnit"), let unit = ExportRangeUnit(rawValue: raw) {
            self.exportLastNUnit = unit
        }

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

    // MARK: - Export Range

    /// The concrete interval the next export will cover.
    public var exportInterval: ExportInterval {
        ExportInterval.resolve(
            mode: exportRangeMode,
            dashboardRange: selectedTimeRange,
            lastNValue: exportLastNValue,
            lastNUnit: exportLastNUnit,
            customStart: exportCustomStart,
            customEnd: exportCustomEnd
        )
    }

    private func saveExportSettings() {
        let d = UserDefaults.standard
        d.set(exportRangeMode.rawValue, forKey: "exportRangeMode")
        d.set(exportLastNValue, forKey: "exportLastNValue")
        d.set(exportLastNUnit.rawValue, forKey: "exportLastNUnit")
        refreshExportPreview()
    }

    // MARK: - Export Actions (Option 1: LLM Markdown | Option 2: Raw Data)

    private enum ExportKind { case markdown, json, csv }

    /// Builds export content on the background queue so large ranges don't freeze the UI.
    private func buildExport(_ kind: ExportKind, interval: ExportInterval) async -> (data: Data, sampleCount: Int)? {
        let hw = hardware
        let db = database
        let notes = userContextNotes
        return await withCheckedContinuation { continuation in
            collectorQueue.async {
                let samples = db.fetchSystemSamples(since: interval.start, until: interval.end, maxPoints: 0)
                let apps = db.fetchAggregatedApps(since: interval.start, until: interval.end, limit: 40)
                let appsBySampleId = db.fetchAppsBySampleId(since: interval.start, until: interval.end)
                let eval = SufficiencyAnalyzer.evaluate(hardware: hw, samples: samples, topApps: apps)
                var data: Data?
                switch kind {
                case .markdown:
                    data = DataExporter.generateLLMMarkdownReport(
                        hardware: hw, rangeLabel: interval.label, samples: samples,
                        topApps: apps, evaluation: eval, appsBySampleId: appsBySampleId, userNotes: notes
                    ).data(using: .utf8)
                case .json:
                    data = DataExporter.generateRawJSON(
                        hardware: hw, rangeLabel: interval.label, samples: samples,
                        topApps: apps, evaluation: eval, appsBySampleId: appsBySampleId
                    )
                case .csv:
                    data = DataExporter.generateRawCSV(samples: samples, appsBySampleId: appsBySampleId).data(using: .utf8)
                }
                continuation.resume(returning: data.map { ($0, samples.count) })
            }
        }
    }

    private func runExport(_ kind: ExportKind, toClipboard: Bool = false) {
        guard !isExporting else { return }
        let interval = exportInterval
        isExporting = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.isExporting = false }
            guard let result = await self.buildExport(kind, interval: interval) else {
                self.showToast("Export failed.")
                return
            }
            if result.sampleCount == 0 {
                self.showToast("No data recorded in \(interval.label) — exporting an empty report.")
            }
            if toClipboard, let text = String(data: result.data, encoding: .utf8) {
                DataExporter.copyToClipboard(text)
                self.showToast("Copied LLM report (\(interval.label)) to clipboard!")
                return
            }
            let ext: String
            let prefix: String
            switch kind {
            case .markdown: ext = "md"; prefix = "Mac-Sufficiency-LLM-Report"
            case .json: ext = "json"; prefix = "UtilizationAnalyzer-RawData"
            case .csv: ext = "csv"; prefix = "UtilizationAnalyzer-RawData"
            }
            DataExporter.saveFileInteractively(
                defaultFilename: "\(prefix)-\(interval.fileTag).\(ext)",
                content: result.data
            ) { [weak self] url in
                if let url {
                    self?.showToast("Saved \(url.lastPathComponent) (\(result.sampleCount) samples)")
                }
            }
        }
    }

    public func copyLLMMarkdownToClipboard() { runExport(.markdown, toClipboard: true) }
    public func saveLLMMarkdownToFile() { runExport(.markdown) }
    public func exportRawJSONToFile() { runExport(.json) }
    public func exportRawCSVToFile() { runExport(.csv) }

    /// Regenerates the Markdown preview for the current export range in the background.
    public func refreshExportPreview() {
        let interval = exportInterval
        Task { @MainActor [weak self] in
            guard let self else { return }
            if let result = await self.buildExport(.markdown, interval: interval),
               let text = String(data: result.data, encoding: .utf8) {
                self.exportPreviewMarkdown = text
                self.exportPreviewSampleCount = result.sampleCount
            }
            self.oldestSampleDate = self.database.oldestSampleDate()
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
