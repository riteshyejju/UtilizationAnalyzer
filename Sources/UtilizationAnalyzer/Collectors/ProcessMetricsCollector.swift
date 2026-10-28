import Foundation
import Darwin

public final class ProcessMetricsCollector: @unchecked Sendable {
    private struct ProcessCounterState {
        let cpuNanoseconds: UInt64
        let diskReadBytes: UInt64
        let diskWriteBytes: UInt64
    }

    private var previousProcessCounters: [pid_t: ProcessCounterState] = [:]
    private var previousSampleTime: Date?
    private var pathCache: [pid_t: (appId: String, displayName: String, bundlePath: String?)] = [:]
    private let timebaseNumer: UInt64
    private let timebaseDenom: UInt64

    public init() {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        self.timebaseNumer = UInt64(max(1, info.numer))
        self.timebaseDenom = UInt64(max(1, info.denom))
        // Prime initial snapshot
        _ = collectTopApps(limit: 20)
    }

    public func collectTopApps(limit: Int = 25) -> [AppUsageSnapshot] {
        let now = Date()
        let elapsed = max(0.2, previousSampleTime.map { now.timeIntervalSince($0) } ?? 1.0)
        previousSampleTime = now

        let pids = listAllPids()
        var currentCounters: [pid_t: ProcessCounterState] = [:]
        currentCounters.reserveCapacity(pids.count)

        struct GroupAccumulator {
            var appId: String
            var displayName: String
            var bundlePath: String?
            var processCount: Int = 0
            var cpuPercent: Double = 0
            var memoryBytes: UInt64 = 0
            var diskReadBps: Double = 0
            var diskWriteBps: Double = 0
        }

        var groups: [String: GroupAccumulator] = [:]

        for pid in pids where pid > 0 {
            var rusage = rusage_info_v4()
            let rusageResult = withUnsafeMutablePointer(to: &rusage) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                    proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
                }
            }

            var cpuTicks: UInt64 = 0
            var memoryFootprint: UInt64 = 0
            var diskRead: UInt64 = 0
            var diskWrite: UInt64 = 0

            if rusageResult == 0 {
                cpuTicks = rusage.ri_user_time &+ rusage.ri_system_time
                memoryFootprint = rusage.ri_phys_footprint
                diskRead = rusage.ri_diskio_bytesread
                diskWrite = rusage.ri_diskio_byteswritten
            } else {
                // Fallback to PROC_PIDTASKINFO if rusage is restricted
                var taskInfo = proc_taskinfo()
                let size = MemoryLayout<proc_taskinfo>.size
                let readBytes = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &taskInfo, Int32(size))
                guard readBytes == Int32(size) else { continue }
                cpuTicks = taskInfo.pti_total_user &+ taskInfo.pti_total_system
                memoryFootprint = taskInfo.pti_resident_size
            }

            let cpuNs = (cpuTicks &* timebaseNumer) / timebaseDenom
            currentCounters[pid] = ProcessCounterState(
                cpuNanoseconds: cpuNs,
                diskReadBytes: diskRead,
                diskWriteBytes: diskWrite
            )

            var cpuPct: Double = 0
            var readBps: Double = 0
            var writeBps: Double = 0

            if let prev = previousProcessCounters[pid] {
                if cpuNs >= prev.cpuNanoseconds {
                    let deltaNs = Double(cpuNs - prev.cpuNanoseconds)
                    cpuPct = (deltaNs / (elapsed * 1_000_000_000.0)) * 100.0
                }
                if diskRead >= prev.diskReadBytes {
                    readBps = Double(diskRead - prev.diskReadBytes) / elapsed
                }
                if diskWrite >= prev.diskWriteBytes {
                    writeBps = Double(diskWrite - prev.diskWriteBytes) / elapsed
                }
            }

            // Skip completely idle tiny background processes
            if memoryFootprint < 2 * 1024 * 1024 && cpuPct < 0.05 {
                continue
            }

            let identity = resolveAppIdentity(for: pid)
            var group = groups[identity.appId] ?? GroupAccumulator(
                appId: identity.appId,
                displayName: identity.displayName,
                bundlePath: identity.bundlePath
            )
            group.processCount += 1
            group.cpuPercent += cpuPct
            group.memoryBytes &+= memoryFootprint
            group.diskReadBps += readBps
            group.diskWriteBps += writeBps
            if group.bundlePath == nil, let bp = identity.bundlePath {
                group.bundlePath = bp
            }
            groups[identity.appId] = group
        }

        // Prune dead PIDs from pathCache
        if pathCache.count > 2000 {
            let activeSet = Set(currentCounters.keys)
            pathCache = pathCache.filter { activeSet.contains($0.key) }
        }
        previousProcessCounters = currentCounters

        // Rank by composite score of CPU + Memory so both CPU-heavy and RAM-heavy apps are captured
        let sorted = groups.values.sorted { a, b in
            let scoreA = (a.cpuPercent * 2.0) + (Double(a.memoryBytes) / 100_000_000.0)
            let scoreB = (b.cpuPercent * 2.0) + (Double(b.memoryBytes) / 100_000_000.0)
            return scoreA > scoreB
        }

        return sorted.prefix(limit).map { g in
            AppUsageSnapshot(
                appIdentifier: g.appId,
                displayName: g.displayName,
                bundlePath: g.bundlePath,
                processCount: g.processCount,
                cpuPercent: g.cpuPercent,
                memoryBytes: g.memoryBytes,
                diskReadBytesPerSec: g.diskReadBps,
                diskWriteBytesPerSec: g.diskWriteBps
            )
        }
    }

    private func listAllPids() -> [pid_t] {
        let estimatedCount = proc_listallpids(nil, 0)
        guard estimatedCount > 0 else { return [] }
        let capacity = Int(estimatedCount) + 64
        var buffer = [pid_t](repeating: 0, count: capacity)
        let byteSize = Int32(capacity * MemoryLayout<pid_t>.stride)
        let actualBytes = proc_listallpids(&buffer, byteSize)
        guard actualBytes > 0 else { return [] }
        let count = Int(actualBytes)
        return Array(buffer.prefix(min(count, capacity)))
    }

    private func resolveAppIdentity(for pid: pid_t) -> (appId: String, displayName: String, bundlePath: String?) {
        if let cached = pathCache[pid] {
            return cached
        }

        var pathBuffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let pathLen = proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count))
        if pathLen > 0 {
            let fullPath = String(cString: pathBuffer)
            // Group helper processes into their outermost .app bundle
            // e.g. /Applications/Google Chrome.app/Contents/Frameworks/... -> /Applications/Google Chrome.app
            if let appRange = fullPath.range(of: ".app/") ?? (fullPath.hasSuffix(".app") ? fullPath.range(of: ".app") : nil) {
                let bundleEnd = fullPath.index(appRange.lowerBound, offsetBy: 4)
                let bundlePath = String(fullPath[..<bundleEnd])
                let appName = URL(fileURLWithPath: bundlePath).deletingPathExtension().lastPathComponent
                let result = (appId: bundlePath, displayName: appName, bundlePath: Optional(bundlePath))
                pathCache[pid] = result
                return result
            } else {
                let execName = URL(fileURLWithPath: fullPath).lastPathComponent
                let cleanName = cleanProcessName(execName)
                let result = (appId: cleanName, displayName: cleanName, bundlePath: Optional<String>.none)
                pathCache[pid] = result
                return result
            }
        }

        // Fallback to proc_name
        var nameBuffer = [CChar](repeating: 0, count: 256)
        let nameLen = proc_name(pid, &nameBuffer, UInt32(nameBuffer.count))
        let fallbackName = nameLen > 0 ? cleanProcessName(String(cString: nameBuffer)) : "PID \(pid)"
        let result = (appId: fallbackName, displayName: fallbackName, bundlePath: Optional<String>.none)
        pathCache[pid] = result
        return result
    }

    private func cleanProcessName(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let helperRange = trimmed.range(of: " Helper") {
            return String(trimmed[..<helperRange.lowerBound])
        }
        return trimmed.isEmpty ? "Unknown Process" : trimmed
    }
}
