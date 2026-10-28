import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public final class MetricsDatabase: @unchecked Sendable {
    public let dbPath: String
    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "com.riteshyejju.UtilizationAnalyzer.sqlite", qos: .utility)

    public init(customPath: String? = nil) {
        if let customPath {
            self.dbPath = customPath
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            let dir = appSupport.appendingPathComponent("UtilizationAnalyzer", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            self.dbPath = dir.appendingPathComponent("metrics.sqlite").path
        }

        queue.sync {
            openAndMigrate()
        }
    }

    deinit {
        if let db {
            sqlite3_close(db)
        }
    }

    private func openAndMigrate() {
        guard sqlite3_open(dbPath, &db) == SQLITE_OK else {
            return
        }

        execSQL("PRAGMA journal_mode=WAL;")
        execSQL("PRAGMA synchronous=NORMAL;")
        execSQL("PRAGMA foreign_keys=ON;")

        let createSystemTable = """
        CREATE TABLE IF NOT EXISTS system_samples (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            timestamp REAL NOT NULL,
            cpu_user REAL NOT NULL,
            cpu_system REAL NOT NULL,
            cpu_idle REAL NOT NULL,
            cpu_total REAL NOT NULL,
            peak_core REAL NOT NULL,
            load_1m REAL NOT NULL,
            load_5m REAL NOT NULL,
            load_15m REAL NOT NULL,
            mem_used INTEGER NOT NULL,
            mem_app INTEGER NOT NULL,
            mem_wired INTEGER NOT NULL,
            mem_compressed INTEGER NOT NULL,
            mem_cached INTEGER NOT NULL,
            mem_total INTEGER NOT NULL,
            swap_used INTEGER NOT NULL,
            swap_total INTEGER NOT NULL,
            pageouts_ps REAL NOT NULL,
            mem_pressure INTEGER NOT NULL,
            thermal_state INTEGER NOT NULL,
            gpu_util REAL NOT NULL,
            gpu_mem INTEGER NOT NULL,
            disk_read_bps REAL NOT NULL,
            disk_write_bps REAL NOT NULL,
            disk_used INTEGER NOT NULL,
            disk_total INTEGER NOT NULL,
            net_rx_bps REAL NOT NULL,
            net_tx_bps REAL NOT NULL,
            battery_pct REAL NOT NULL,
            is_charging INTEGER NOT NULL,
            is_ac_power INTEGER NOT NULL,
            power_watts REAL NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_system_samples_timestamp ON system_samples(timestamp);
        """

        let createAppsTable = """
        CREATE TABLE IF NOT EXISTS app_samples (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            sample_id INTEGER NOT NULL,
            timestamp REAL NOT NULL,
            app_id TEXT NOT NULL,
            display_name TEXT NOT NULL,
            bundle_path TEXT,
            process_count INTEGER NOT NULL,
            cpu_percent REAL NOT NULL,
            memory_bytes INTEGER NOT NULL,
            disk_read_bps REAL NOT NULL,
            disk_write_bps REAL NOT NULL,
            FOREIGN KEY(sample_id) REFERENCES system_samples(id) ON DELETE CASCADE
        );
        CREATE INDEX IF NOT EXISTS idx_app_samples_timestamp ON app_samples(timestamp);
        CREATE INDEX IF NOT EXISTS idx_app_samples_app_id ON app_samples(app_id);
        """

        execSQL(createSystemTable)
        execSQL(createAppsTable)
    }

    private func execSQL(_ sql: String) {
        guard let db else { return }
        sqlite3_exec(db, sql, nil, nil, nil)
    }

    // MARK: - Insert Sample & App Breakdown

    public func insertSample(_ sample: SystemSample, apps: [AppUsageSnapshot]) {
        queue.sync {
            guard let db else { return }
            execSQL("BEGIN TRANSACTION;")

            let sysSQL = """
            INSERT INTO system_samples (
                timestamp, cpu_user, cpu_system, cpu_idle, cpu_total, peak_core,
                load_1m, load_5m, load_15m,
                mem_used, mem_app, mem_wired, mem_compressed, mem_cached, mem_total,
                swap_used, swap_total, pageouts_ps, mem_pressure,
                thermal_state, gpu_util, gpu_mem,
                disk_read_bps, disk_write_bps, disk_used, disk_total,
                net_rx_bps, net_tx_bps,
                battery_pct, is_charging, is_ac_power, power_watts
            ) VALUES (
                ?, ?, ?, ?, ?, ?,
                ?, ?, ?,
                ?, ?, ?, ?, ?, ?,
                ?, ?, ?, ?,
                ?, ?, ?,
                ?, ?, ?, ?,
                ?, ?,
                ?, ?, ?, ?
            );
            """

            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sysSQL, -1, &stmt, nil) == SQLITE_OK else {
                execSQL("ROLLBACK;")
                return
            }

            let ts = sample.timestamp.timeIntervalSince1970
            sqlite3_bind_double(stmt, 1, ts)
            sqlite3_bind_double(stmt, 2, sample.cpuUserPercent)
            sqlite3_bind_double(stmt, 3, sample.cpuSystemPercent)
            sqlite3_bind_double(stmt, 4, sample.cpuIdlePercent)
            sqlite3_bind_double(stmt, 5, sample.cpuTotalPercent)
            sqlite3_bind_double(stmt, 6, sample.peakCorePercent)
            sqlite3_bind_double(stmt, 7, sample.loadAvg1m)
            sqlite3_bind_double(stmt, 8, sample.loadAvg5m)
            sqlite3_bind_double(stmt, 9, sample.loadAvg15m)
            sqlite3_bind_int64(stmt, 10, Int64(bitPattern: sample.memoryUsedBytes))
            sqlite3_bind_int64(stmt, 11, Int64(bitPattern: sample.memoryAppBytes))
            sqlite3_bind_int64(stmt, 12, Int64(bitPattern: sample.memoryWiredBytes))
            sqlite3_bind_int64(stmt, 13, Int64(bitPattern: sample.memoryCompressedBytes))
            sqlite3_bind_int64(stmt, 14, Int64(bitPattern: sample.memoryCachedBytes))
            sqlite3_bind_int64(stmt, 15, Int64(bitPattern: sample.memoryTotalBytes))
            sqlite3_bind_int64(stmt, 16, Int64(bitPattern: sample.swapUsedBytes))
            sqlite3_bind_int64(stmt, 17, Int64(bitPattern: sample.swapTotalBytes))
            sqlite3_bind_double(stmt, 18, sample.pageoutsPerSec)
            sqlite3_bind_int(stmt, 19, Int32(sample.memoryPressure.rawValue))
            sqlite3_bind_int(stmt, 20, Int32(sample.thermalState.rawValue))
            sqlite3_bind_double(stmt, 21, sample.gpuUtilizationPercent)
            sqlite3_bind_int64(stmt, 22, Int64(bitPattern: sample.gpuMemoryBytes))
            sqlite3_bind_double(stmt, 23, sample.diskReadBytesPerSec)
            sqlite3_bind_double(stmt, 24, sample.diskWriteBytesPerSec)
            sqlite3_bind_int64(stmt, 25, Int64(bitPattern: sample.diskUsedBytes))
            sqlite3_bind_int64(stmt, 26, Int64(bitPattern: sample.diskTotalBytes))
            sqlite3_bind_double(stmt, 27, sample.netRxBytesPerSec)
            sqlite3_bind_double(stmt, 28, sample.netTxBytesPerSec)
            sqlite3_bind_double(stmt, 29, sample.batteryPercent)
            sqlite3_bind_int(stmt, 30, sample.isCharging ? 1 : 0)
            sqlite3_bind_int(stmt, 31, sample.isOnACPower ? 1 : 0)
            sqlite3_bind_double(stmt, 32, sample.powerWatts)

            guard sqlite3_step(stmt) == SQLITE_DONE else {
                sqlite3_finalize(stmt)
                execSQL("ROLLBACK;")
                return
            }
            sqlite3_finalize(stmt)

            let sampleId = sqlite3_last_insert_rowid(db)

            if !apps.isEmpty {
                let appSQL = """
                INSERT INTO app_samples (
                    sample_id, timestamp, app_id, display_name, bundle_path,
                    process_count, cpu_percent, memory_bytes, disk_read_bps, disk_write_bps
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
                """
                var appStmt: OpaquePointer?
                if sqlite3_prepare_v2(db, appSQL, -1, &appStmt, nil) == SQLITE_OK {
                    for app in apps {
                        sqlite3_reset(appStmt)
                        sqlite3_clear_bindings(appStmt)
                        sqlite3_bind_int64(appStmt, 1, sampleId)
                        sqlite3_bind_double(appStmt, 2, ts)
                        sqlite3_bind_text(appStmt, 3, app.appIdentifier, -1, SQLITE_TRANSIENT)
                        sqlite3_bind_text(appStmt, 4, app.displayName, -1, SQLITE_TRANSIENT)
                        if let bp = app.bundlePath {
                            sqlite3_bind_text(appStmt, 5, bp, -1, SQLITE_TRANSIENT)
                        } else {
                            sqlite3_bind_null(appStmt, 5)
                        }
                        sqlite3_bind_int(appStmt, 6, Int32(app.processCount))
                        sqlite3_bind_double(appStmt, 7, app.cpuPercent)
                        sqlite3_bind_int64(appStmt, 8, Int64(bitPattern: app.memoryBytes))
                        sqlite3_bind_double(appStmt, 9, app.diskReadBytesPerSec)
                        sqlite3_bind_double(appStmt, 10, app.diskWriteBytesPerSec)
                        _ = sqlite3_step(appStmt)
                    }
                    sqlite3_finalize(appStmt)
                }
            }

            execSQL("COMMIT;")
        }
    }

    // MARK: - Query System Samples

    public func fetchSystemSamples(since startDate: Date, until endDate: Date = .distantFuture, maxPoints: Int = 500) -> [SystemSample] {
        queue.sync {
            guard let db else { return [] }
            let sql = """
            SELECT
                id, timestamp, cpu_user, cpu_system, cpu_idle, cpu_total, peak_core,
                load_1m, load_5m, load_15m,
                mem_used, mem_app, mem_wired, mem_compressed, mem_cached, mem_total,
                swap_used, swap_total, pageouts_ps, mem_pressure,
                thermal_state, gpu_util, gpu_mem,
                disk_read_bps, disk_write_bps, disk_used, disk_total,
                net_rx_bps, net_tx_bps,
                battery_pct, is_charging, is_ac_power, power_watts
            FROM system_samples
            WHERE timestamp >= ? AND timestamp <= ?
            ORDER BY timestamp ASC;
            """

            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }

            sqlite3_bind_double(stmt, 1, startDate.timeIntervalSince1970)
            sqlite3_bind_double(stmt, 2, endDate.timeIntervalSince1970)

            var allSamples: [SystemSample] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                let s = SystemSample(
                    id: sqlite3_column_int64(stmt, 0),
                    timestamp: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 1)),
                    cpuUserPercent: sqlite3_column_double(stmt, 2),
                    cpuSystemPercent: sqlite3_column_double(stmt, 3),
                    cpuIdlePercent: sqlite3_column_double(stmt, 4),
                    cpuTotalPercent: sqlite3_column_double(stmt, 5),
                    peakCorePercent: sqlite3_column_double(stmt, 6),
                    loadAvg1m: sqlite3_column_double(stmt, 7),
                    loadAvg5m: sqlite3_column_double(stmt, 8),
                    loadAvg15m: sqlite3_column_double(stmt, 9),
                    memoryUsedBytes: UInt64(bitPattern: sqlite3_column_int64(stmt, 10)),
                    memoryAppBytes: UInt64(bitPattern: sqlite3_column_int64(stmt, 11)),
                    memoryWiredBytes: UInt64(bitPattern: sqlite3_column_int64(stmt, 12)),
                    memoryCompressedBytes: UInt64(bitPattern: sqlite3_column_int64(stmt, 13)),
                    memoryCachedBytes: UInt64(bitPattern: sqlite3_column_int64(stmt, 14)),
                    memoryTotalBytes: UInt64(bitPattern: sqlite3_column_int64(stmt, 15)),
                    swapUsedBytes: UInt64(bitPattern: sqlite3_column_int64(stmt, 16)),
                    swapTotalBytes: UInt64(bitPattern: sqlite3_column_int64(stmt, 17)),
                    pageoutsPerSec: sqlite3_column_double(stmt, 18),
                    memoryPressure: MemoryPressureLevel.from(rawLevel: Int(sqlite3_column_int(stmt, 19))),
                    thermalState: ThermalLevel(rawValue: Int(sqlite3_column_int(stmt, 20))) ?? .nominal,
                    gpuUtilizationPercent: sqlite3_column_double(stmt, 21),
                    gpuMemoryBytes: UInt64(bitPattern: sqlite3_column_int64(stmt, 22)),
                    diskReadBytesPerSec: sqlite3_column_double(stmt, 23),
                    diskWriteBytesPerSec: sqlite3_column_double(stmt, 24),
                    diskUsedBytes: UInt64(bitPattern: sqlite3_column_int64(stmt, 25)),
                    diskTotalBytes: UInt64(bitPattern: sqlite3_column_int64(stmt, 26)),
                    netRxBytesPerSec: sqlite3_column_double(stmt, 27),
                    netTxBytesPerSec: sqlite3_column_double(stmt, 28),
                    batteryPercent: sqlite3_column_double(stmt, 29),
                    isCharging: sqlite3_column_int(stmt, 30) != 0,
                    isOnACPower: sqlite3_column_int(stmt, 31) != 0,
                    powerWatts: sqlite3_column_double(stmt, 32)
                )
                allSamples.append(s)
            }

            if maxPoints > 0 && allSamples.count > maxPoints {
                return downsample(allSamples, targetCount: maxPoints)
            }
            return allSamples
        }
    }

    private func downsample(_ samples: [SystemSample], targetCount: Int) -> [SystemSample] {
        guard targetCount > 2, samples.count > targetCount else { return samples }
        let strideSize = Double(samples.count) / Double(targetCount)
        var result: [SystemSample] = []
        result.reserveCapacity(targetCount)

        for i in 0..<targetCount {
            let startIdx = Int(Double(i) * strideSize)
            let endIdx = min(samples.count, max(startIdx + 1, Int(Double(i + 1) * strideSize)))
            let slice = samples[startIdx..<endIdx]
            // Pick the sample in the bucket with the highest CPU+Memory stress so peaks are preserved in charts!
            if let representative = slice.max(by: {
                ($0.cpuTotalPercent + Double($0.swapUsedBytes) / 100_000_000.0) <
                ($1.cpuTotalPercent + Double($1.swapUsedBytes) / 100_000_000.0)
            }) {
                result.append(representative)
            }
        }
        return result
    }

    // MARK: - Query Aggregated App Usage

    public func fetchAggregatedApps(since startDate: Date, until endDate: Date = .distantFuture, limit: Int = 50) -> [AggregatedAppUsage] {
        queue.sync {
            guard let db else { return [] }
            let sql = """
            SELECT
                app_id,
                MAX(display_name) as display_name,
                MAX(bundle_path) as bundle_path,
                COUNT(*) as sample_count,
                MAX(process_count) as max_procs,
                AVG(cpu_percent) as avg_cpu,
                MAX(cpu_percent) as peak_cpu,
                AVG(memory_bytes) as avg_mem,
                MAX(memory_bytes) as peak_mem,
                AVG(disk_read_bps) as avg_read,
                AVG(disk_write_bps) as avg_write
            FROM app_samples
            WHERE timestamp >= ? AND timestamp <= ?
            GROUP BY app_id
            ORDER BY (AVG(cpu_percent) * 2.0 + (AVG(memory_bytes) / 100000000.0)) DESC
            LIMIT ?;
            """

            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }

            sqlite3_bind_double(stmt, 1, startDate.timeIntervalSince1970)
            sqlite3_bind_double(stmt, 2, endDate.timeIntervalSince1970)
            sqlite3_bind_int(stmt, 3, Int32(limit))

            var results: [AggregatedAppUsage] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                let appId = columnString(stmt, 0) ?? "Unknown"
                let displayName = columnString(stmt, 1) ?? appId
                let bundlePath = columnString(stmt, 2)
                let sampleCount = Int(sqlite3_column_int(stmt, 3))
                let maxProcs = Int(sqlite3_column_int(stmt, 4))
                let avgCpu = sqlite3_column_double(stmt, 5)
                let peakCpu = sqlite3_column_double(stmt, 6)
                let avgMem = UInt64(max(0, sqlite3_column_double(stmt, 7)))
                let peakMem = UInt64(bitPattern: sqlite3_column_int64(stmt, 8))
                let avgRead = sqlite3_column_double(stmt, 9)
                let avgWrite = sqlite3_column_double(stmt, 10)

                results.append(
                    AggregatedAppUsage(
                        appIdentifier: appId,
                        displayName: displayName,
                        bundlePath: bundlePath,
                        sampleCount: sampleCount,
                        maxProcessCount: maxProcs,
                        avgCpuPercent: avgCpu,
                        peakCpuPercent: peakCpu,
                        avgMemoryBytes: avgMem,
                        peakMemoryBytes: peakMem,
                        avgDiskReadBytesPerSec: avgRead,
                        avgDiskWriteBytesPerSec: avgWrite
                    )
                )
            }
            return results
        }
    }

    // MARK: - Query Per-Sample App Breakdown (for Spike Attribution & Per-Row CSV/JSON)

    public func fetchAppsBySampleId(since startDate: Date, until endDate: Date = .distantFuture) -> [Int64: [AppUsageSnapshot]] {
        queue.sync {
            guard let db else { return [:] }
            let sql = """
            SELECT
                sample_id,
                app_id,
                display_name,
                bundle_path,
                process_count,
                cpu_percent,
                memory_bytes,
                disk_read_bps,
                disk_write_bps
            FROM app_samples
            WHERE timestamp >= ? AND timestamp <= ?
            ORDER BY sample_id ASC, cpu_percent DESC;
            """

            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [:] }
            defer { sqlite3_finalize(stmt) }

            sqlite3_bind_double(stmt, 1, startDate.timeIntervalSince1970)
            sqlite3_bind_double(stmt, 2, endDate.timeIntervalSince1970)

            var map: [Int64: [AppUsageSnapshot]] = [:]
            while sqlite3_step(stmt) == SQLITE_ROW {
                let sampleId = sqlite3_column_int64(stmt, 0)
                let appId = columnString(stmt, 1) ?? "Unknown"
                let displayName = columnString(stmt, 2) ?? appId
                let bundlePath = columnString(stmt, 3)
                let procCount = Int(sqlite3_column_int(stmt, 4))
                let cpuPct = sqlite3_column_double(stmt, 5)
                let memBytes = UInt64(bitPattern: sqlite3_column_int64(stmt, 6))
                let readBps = sqlite3_column_double(stmt, 7)
                let writeBps = sqlite3_column_double(stmt, 8)

                let snap = AppUsageSnapshot(
                    appIdentifier: appId,
                    displayName: displayName,
                    bundlePath: bundlePath,
                    processCount: procCount,
                    cpuPercent: cpuPct,
                    memoryBytes: memBytes,
                    diskReadBytesPerSec: readBps,
                    diskWriteBytesPerSec: writeBps
                )
                map[sampleId, default: []].append(snap)
            }
            return map
        }
    }

    // MARK: - Maintenance & Stats

    /// Deletes samples older than `days`. A value of 0 or less means "keep forever" (no pruning).
    public func pruneOldSamples(olderThanDays days: Int) {
        guard days > 0 else { return }
        let cutoff = Date().addingTimeInterval(-Double(days) * 86400.0).timeIntervalSince1970
        queue.async { [weak self] in
            guard let self, let db = self.db else { return }
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, "DELETE FROM system_samples WHERE timestamp < ?;", -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_double(stmt, 1, cutoff)
                _ = sqlite3_step(stmt)
                sqlite3_finalize(stmt)
            }
        }
    }

    public func clearAllData() {
        queue.sync {
            execSQL("DELETE FROM app_samples;")
            execSQL("DELETE FROM system_samples;")
            execSQL("VACUUM;")
        }
    }

    public func oldestSampleDate() -> Date? {
        queue.sync {
            guard let db else { return nil }
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT MIN(timestamp) FROM system_samples;", -1, &stmt, nil) == SQLITE_OK else {
                return nil
            }
            defer { sqlite3_finalize(stmt) }
            if sqlite3_step(stmt) == SQLITE_ROW, sqlite3_column_type(stmt, 0) != SQLITE_NULL {
                return Date(timeIntervalSince1970: sqlite3_column_double(stmt, 0))
            }
            return nil
        }
    }

    public func totalSampleCount() -> Int {
        queue.sync {
            guard let db else { return 0 }
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM system_samples;", -1, &stmt, nil) == SQLITE_OK else {
                return 0
            }
            defer { sqlite3_finalize(stmt) }
            if sqlite3_step(stmt) == SQLITE_ROW {
                return Int(sqlite3_column_int64(stmt, 0))
            }
            return 0
        }
    }

    public func databaseSizeBytes() -> UInt64 {
        if let attrs = try? FileManager.default.attributesOfItem(atPath: dbPath),
           let size = attrs[.size] as? NSNumber {
            return size.uint64Value
        }
        return 0
    }

    private func columnString(_ stmt: OpaquePointer?, _ index: Int32) -> String? {
        guard let cStr = sqlite3_column_text(stmt, index) else { return nil }
        return String(cString: cStr)
    }
}
