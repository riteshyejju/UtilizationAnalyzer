import Foundation
import Darwin
import IOKit

public final class SystemMetricsCollector: @unchecked Sendable {
    private var previousCoreTicks: [(user: UInt64, system: UInt64, idle: UInt64, nice: UInt64)] = []
    private var previousSampleTime: Date?
    private var previousPageouts: UInt64?
    private var previousDiskReadBytes: UInt64?
    private var previousDiskWriteBytes: UInt64?
    private var previousNetRxBytes: UInt64?
    private var previousNetTxBytes: UInt64?

    public let hardware: HardwareProfile

    public init(hardware: HardwareProfile = .current()) {
        self.hardware = hardware
        // Prime initial counters so the first real sample has valid deltas
        _ = readCpuPercentages()
        let diskIO = readRawDiskCounters()
        self.previousDiskReadBytes = diskIO.readBytes
        self.previousDiskWriteBytes = diskIO.writeBytes
        let netIO = readRawNetworkCounters()
        self.previousNetRxBytes = netIO.rxBytes
        self.previousNetTxBytes = netIO.txBytes
        self.previousSampleTime = Date()
    }

    public func collectSample() -> SystemSample {
        let now = Date()
        let elapsed = max(0.2, previousSampleTime.map { now.timeIntervalSince($0) } ?? 1.0)
        previousSampleTime = now

        // 1. CPU & Load Averages
        let cpu = readCpuPercentages()
        var loadAvg = [Double](repeating: 0.0, count: 3)
        getloadavg(&loadAvg, 3)

        // 2. Memory & Swap
        let mem = readMemoryAndSwap(elapsed: elapsed)

        // 3. Thermal State
        let thermal = ThermalLevel.from(ProcessInfo.processInfo.thermalState)

        // 4. GPU (Apple Silicon IOAccelerator)
        let gpu = readGpuMetrics()

        // 5. Disk I/O & Volume Space
        let rawDisk = readRawDiskCounters()
        var diskReadBps: Double = 0
        var diskWriteBps: Double = 0
        if let prevR = previousDiskReadBytes, rawDisk.readBytes >= prevR {
            diskReadBps = Double(rawDisk.readBytes - prevR) / elapsed
        }
        if let prevW = previousDiskWriteBytes, rawDisk.writeBytes >= prevW {
            diskWriteBps = Double(rawDisk.writeBytes - prevW) / elapsed
        }
        previousDiskReadBytes = rawDisk.readBytes
        previousDiskWriteBytes = rawDisk.writeBytes
        let diskSpace = readDiskSpace()

        // 6. Network I/O
        let rawNet = readRawNetworkCounters()
        var netRxBps: Double = 0
        var netTxBps: Double = 0
        if let prevRx = previousNetRxBytes, rawNet.rxBytes >= prevRx {
            netRxBps = Double(rawNet.rxBytes - prevRx) / elapsed
        }
        if let prevTx = previousNetTxBytes, rawNet.txBytes >= prevTx {
            netTxBps = Double(rawNet.txBytes - prevTx) / elapsed
        }
        previousNetRxBytes = rawNet.rxBytes
        previousNetTxBytes = rawNet.txBytes

        // 7. Battery & Power
        let power = readBatteryAndPower()

        return SystemSample(
            id: 0,
            timestamp: now,
            cpuUserPercent: cpu.user,
            cpuSystemPercent: cpu.system,
            cpuIdlePercent: cpu.idle,
            cpuTotalPercent: cpu.total,
            peakCorePercent: cpu.peakCore,
            loadAvg1m: loadAvg[0],
            loadAvg5m: loadAvg[1],
            loadAvg15m: loadAvg[2],
            memoryUsedBytes: mem.usedBytes,
            memoryAppBytes: mem.appBytes,
            memoryWiredBytes: mem.wiredBytes,
            memoryCompressedBytes: mem.compressedBytes,
            memoryCachedBytes: mem.cachedBytes,
            memoryTotalBytes: hardware.physicalMemoryBytes,
            swapUsedBytes: mem.swapUsedBytes,
            swapTotalBytes: mem.swapTotalBytes,
            pageoutsPerSec: mem.pageoutsPerSec,
            memoryPressure: mem.pressure,
            thermalState: thermal,
            gpuUtilizationPercent: gpu.utilizationPercent,
            gpuMemoryBytes: gpu.inUseMemoryBytes,
            diskReadBytesPerSec: diskReadBps,
            diskWriteBytesPerSec: diskWriteBps,
            diskUsedBytes: diskSpace.usedBytes,
            diskTotalBytes: diskSpace.totalBytes,
            netRxBytesPerSec: netRxBps,
            netTxBytesPerSec: netTxBps,
            batteryPercent: power.batteryPercent,
            isCharging: power.isCharging,
            isOnACPower: power.isOnACPower,
            powerWatts: power.watts
        )
    }

    // MARK: - CPU via host_processor_info

    private func readCpuPercentages() -> (user: Double, system: Double, idle: Double, total: Double, peakCore: Double) {
        var numCPUsU: natural_t = 0
        var cpuInfo: processor_info_array_t?
        var numCpuInfo: mach_msg_type_number_t = 0

        let result = host_processor_info(
            mach_host_self(),
            PROCESSOR_CPU_LOAD_INFO,
            &numCPUsU,
            &cpuInfo,
            &numCpuInfo
        )

        guard result == KERN_SUCCESS, let info = cpuInfo else {
            return (0, 0, 100, 0, 0)
        }

        defer {
            let deallocSize = vm_size_t(numCpuInfo) * vm_size_t(MemoryLayout<integer_t>.stride)
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), deallocSize)
        }

        let coreCount = Int(numCPUsU)
        var currentCores: [(user: UInt64, system: UInt64, idle: UInt64, nice: UInt64)] = []
        currentCores.reserveCapacity(coreCount)

        for i in 0..<coreCount {
            let offset = Int(CPU_STATE_MAX) * i
            let u = UInt64(UInt32(bitPattern: info[offset + Int(CPU_STATE_USER)]))
            let s = UInt64(UInt32(bitPattern: info[offset + Int(CPU_STATE_SYSTEM)]))
            let idl = UInt64(UInt32(bitPattern: info[offset + Int(CPU_STATE_IDLE)]))
            let n = UInt64(UInt32(bitPattern: info[offset + Int(CPU_STATE_NICE)]))
            currentCores.append((u, s, idl, n))
        }

        guard previousCoreTicks.count == currentCores.count, !currentCores.isEmpty else {
            previousCoreTicks = currentCores
            return (0, 0, 100, 0, 0)
        }

        var totalUserDelta: UInt64 = 0
        var totalSysDelta: UInt64 = 0
        var totalIdleDelta: UInt64 = 0
        var totalNiceDelta: UInt64 = 0
        var peakCoreUsage: Double = 0

        for i in 0..<coreCount {
            let prev = previousCoreTicks[i]
            let curr = currentCores[i]
            let dUser = curr.user >= prev.user ? curr.user - prev.user : 0
            let dSys = curr.system >= prev.system ? curr.system - prev.system : 0
            let dIdle = curr.idle >= prev.idle ? curr.idle - prev.idle : 0
            let dNice = curr.nice >= prev.nice ? curr.nice - prev.nice : 0

            totalUserDelta += dUser
            totalSysDelta += dSys
            totalIdleDelta += dIdle
            totalNiceDelta += dNice

            let coreTotal = dUser + dSys + dIdle + dNice
            if coreTotal > 0 {
                let coreActive = Double(dUser + dSys + dNice) / Double(coreTotal) * 100.0
                if coreActive > peakCoreUsage {
                    peakCoreUsage = coreActive
                }
            }
        }

        previousCoreTicks = currentCores

        let allTicks = totalUserDelta + totalSysDelta + totalIdleDelta + totalNiceDelta
        guard allTicks > 0 else {
            return (0, 0, 100, 0, 0)
        }

        let userPct = Double(totalUserDelta + totalNiceDelta) / Double(allTicks) * 100.0
        let sysPct = Double(totalSysDelta) / Double(allTicks) * 100.0
        let idlePct = Double(totalIdleDelta) / Double(allTicks) * 100.0
        let totalPct = min(100.0, userPct + sysPct)

        return (userPct, sysPct, idlePct, totalPct, min(100.0, peakCoreUsage))
    }

    // MARK: - Memory, Swap & Pressure

    private func readMemoryAndSwap(elapsed: TimeInterval) -> (
        usedBytes: UInt64,
        appBytes: UInt64,
        wiredBytes: UInt64,
        compressedBytes: UInt64,
        cachedBytes: UInt64,
        swapUsedBytes: UInt64,
        swapTotalBytes: UInt64,
        pageoutsPerSec: Double,
        pressure: MemoryPressureLevel
    ) {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let kerr = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }

        let pageSize = UInt64(vm_kernel_page_size)
        var appBytes: UInt64 = 0
        var wiredBytes: UInt64 = 0
        var compressedBytes: UInt64 = 0
        var cachedBytes: UInt64 = 0
        var usedBytes: UInt64 = 0
        var pageoutsRate: Double = 0

        if kerr == KERN_SUCCESS {
            let internalPages = UInt64(stats.internal_page_count)
            let purgeablePages = UInt64(stats.purgeable_count)
            let wiredPages = UInt64(stats.wire_count)
            let compressorPages = UInt64(stats.compressor_page_count)
            let externalPages = UInt64(stats.external_page_count)

            appBytes = (internalPages > purgeablePages ? (internalPages - purgeablePages) : internalPages) * pageSize
            wiredBytes = wiredPages * pageSize
            compressedBytes = compressorPages * pageSize
            cachedBytes = (externalPages + purgeablePages) * pageSize
            usedBytes = min(hardware.physicalMemoryBytes, appBytes + wiredBytes + compressedBytes)

            let currentPageouts = UInt64(stats.pageouts)
            if let prev = previousPageouts, currentPageouts >= prev {
                pageoutsRate = Double(currentPageouts - prev) / elapsed
            }
            previousPageouts = currentPageouts
        }

        // Swap via sysctl vm.swapusage
        var swapUsage = xsw_usage()
        var swapSize = MemoryLayout<xsw_usage>.size
        var swapUsed: UInt64 = 0
        var swapTotal: UInt64 = 0
        if sysctlbyname("vm.swapusage", &swapUsage, &swapSize, nil, 0) == 0 {
            swapUsed = UInt64(swapUsage.xsu_used)
            swapTotal = UInt64(swapUsage.xsu_total)
        }

        // Memory pressure via sysctl kern.memorystatus_vm_pressure_level
        var pressureRaw: Int32 = 1
        var pressureSize = MemoryLayout<Int32>.size
        _ = sysctlbyname("kern.memorystatus_vm_pressure_level", &pressureRaw, &pressureSize, nil, 0)
        var pressure = MemoryPressureLevel.from(rawLevel: Int(pressureRaw))

        // Heuristic enhancement if kernel reports nominal but swap/compression is heavily active
        if pressure == .nominal && hardware.physicalMemoryBytes > 0 {
            let compressedRatio = Double(compressedBytes) / Double(hardware.physicalMemoryBytes)
            if swapUsed > 4 * 1_073_741_824 || compressedRatio > 0.35 {
                pressure = .warning
            }
        }

        return (
            usedBytes,
            appBytes,
            wiredBytes,
            compressedBytes,
            cachedBytes,
            swapUsed,
            swapTotal,
            pageoutsRate,
            pressure
        )
    }

    // MARK: - Apple Silicon GPU via IOKit IOAccelerator

    private func readGpuMetrics() -> (utilizationPercent: Double, inUseMemoryBytes: UInt64) {
        guard let matching = IOServiceMatching("IOAccelerator") else {
            return (0, 0)
        }

        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            return (0, 0)
        }
        defer { IOObjectRelease(iterator) }

        var maxUtilization: Double = 0
        var totalGpuMem: UInt64 = 0

        var service = IOIteratorNext(iterator)
        while service != 0 {
            defer {
                IOObjectRelease(service)
                service = IOIteratorNext(iterator)
            }

            var propsRef: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(service, &propsRef, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                  let props = propsRef?.takeRetainedValue() as? [String: Any],
                  let perfStats = props["PerformanceStatistics"] as? [String: Any] else {
                continue
            }

            if let devUtil = numberToDouble(perfStats["Device Utilization %"]) ??
                             numberToDouble(perfStats["GPU Activity(%)"]) ??
                             numberToDouble(perfStats["Renderer Utilization %"]) {
                if devUtil > maxUtilization {
                    maxUtilization = devUtil
                }
            }

            if let inUseMem = numberToUInt64(perfStats["In use system memory"]) ??
                              numberToUInt64(perfStats["Alloc system memory"]) {
                totalGpuMem = max(totalGpuMem, inUseMem)
            }
        }

        return (min(100.0, max(0.0, maxUtilization)), totalGpuMem)
    }

    // MARK: - Disk I/O Counters & Space

    private func readRawDiskCounters() -> (readBytes: UInt64, writeBytes: UInt64) {
        guard let matching = IOServiceMatching("IOBlockStorageDriver") else {
            return (0, 0)
        }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            return (0, 0)
        }
        defer { IOObjectRelease(iterator) }

        var totalRead: UInt64 = 0
        var totalWrite: UInt64 = 0

        var drive = IOIteratorNext(iterator)
        while drive != 0 {
            defer {
                IOObjectRelease(drive)
                drive = IOIteratorNext(iterator)
            }

            var propsRef: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(drive, &propsRef, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                  let props = propsRef?.takeRetainedValue() as? [String: Any],
                  let stats = props["Statistics"] as? [String: Any] else {
                continue
            }

            if let r = numberToUInt64(stats["Bytes (Read)"]) {
                totalRead &+= r
            }
            if let w = numberToUInt64(stats["Bytes (Write)"]) {
                totalWrite &+= w
            }
        }

        return (totalRead, totalWrite)
    }

    private func readDiskSpace() -> (usedBytes: UInt64, totalBytes: UInt64) {
        let rootURL = URL(fileURLWithPath: "/")
        if let values = try? rootURL.resourceValues(forKeys: [
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey
        ]) {
            let total = UInt64(max(0, values.volumeTotalCapacity ?? 0))
            let availImportant = values.volumeAvailableCapacityForImportantUsage.map { UInt64(max(0, $0)) }
            let availStandard = values.volumeAvailableCapacity.map { UInt64(max(0, $0)) }
            let avail = availImportant ?? availStandard ?? 0
            let used = total > avail ? (total - avail) : 0
            return (used, total)
        }
        return (0, 0)
    }

    // MARK: - Network Counters via getifaddrs

    private func readRawNetworkCounters() -> (rxBytes: UInt64, txBytes: UInt64) {
        var ifaddrPtr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrPtr) == 0, let firstAddr = ifaddrPtr else {
            return (0, 0)
        }
        defer { freeifaddrs(ifaddrPtr) }

        var rxTotal: UInt64 = 0
        var txTotal: UInt64 = 0

        var cursor: UnsafeMutablePointer<ifaddrs>? = firstAddr
        while let ifa = cursor?.pointee {
            defer { cursor = ifa.ifa_next }

            guard let addr = ifa.ifa_addr, Int32(addr.pointee.sa_family) == AF_LINK else {
                continue
            }
            let name = String(cString: ifa.ifa_name)
            // Exclude loopback and virtual tunnel noise to avoid double counting
            if name.hasPrefix("lo") {
                continue
            }
            if let data = ifa.ifa_data?.assumingMemoryBound(to: if_data.self) {
                rxTotal &+= UInt64(data.pointee.ifi_ibytes)
                txTotal &+= UInt64(data.pointee.ifi_obytes)
            }
        }

        return (rxTotal, txTotal)
    }

    // MARK: - Battery & Power via AppleSmartBattery

    private func readBatteryAndPower() -> (batteryPercent: Double, isCharging: Bool, isOnACPower: Bool, watts: Double) {
        guard let matching = IOServiceMatching("AppleSmartBattery") else {
            return (100, false, true, 0)
        }
        let entry = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard entry != 0 else {
            return (100, false, true, 0)
        }
        defer { IOObjectRelease(entry) }

        var propsRef: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(entry, &propsRef, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let props = propsRef?.takeRetainedValue() as? [String: Any] else {
            return (100, false, true, 0)
        }

        let currentCap = numberToDouble(props["CurrentCapacity"]) ?? 100.0
        let maxCap = numberToDouble(props["MaxCapacity"]) ?? 100.0
        let batteryPct: Double
        if maxCap > 0 && currentCap <= maxCap && maxCap <= 100 {
            batteryPct = currentCap
        } else if maxCap > 0 {
            batteryPct = min(100.0, (currentCap / maxCap) * 100.0)
        } else {
            batteryPct = 100.0
        }

        let isCharging = (props["IsCharging"] as? Bool) ?? false
        let externalConnected = (props["ExternalConnected"] as? Bool) ?? false
        let voltageMV = numberToDouble(props["Voltage"]) ?? 0.0
        let amperageMA = numberToDouble(props["InstantAmperage"]) ?? 0.0

        var watts = abs(voltageMV * amperageMA) / 1_000_000.0
        if watts > 250 {
            // Guard against unsigned wraparound if InstantAmperage wasn't sign-extended
            watts = 0
        }

        return (batteryPct, isCharging, externalConnected, watts)
    }

    private func numberToDouble(_ value: Any?) -> Double? {
        if let n = value as? NSNumber {
            return n.doubleValue
        }
        return nil
    }

    private func numberToUInt64(_ value: Any?) -> UInt64? {
        if let n = value as? NSNumber {
            let i = n.int64Value
            return i >= 0 ? UInt64(i) : nil
        }
        return nil
    }
}
