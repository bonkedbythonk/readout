import CReadoutCore
import Foundation
import SystemConfiguration

/// Owns every reader and takes readings off the main thread.
///
/// The Rust sampler keeps the previous counters needed to turn totals into
/// rates, so it must be touched from one place at a time; being an actor is
/// what guarantees that.
actor Sampler {
    /// Owns the Rust sampler so that freeing it happens in this object's own
    /// deinit rather than the actor's, which Swift will not let reach isolated
    /// state. The pointer is immutable and only ever dereferenced from inside
    /// the actor, which is what makes the unchecked conformance true.
    private final class Handle: @unchecked Sendable {
        let pointer: OpaquePointer?
        init() { pointer = ro_sampler_new() }
        deinit { if let pointer { ro_sampler_free(pointer) } }
    }

    private let sampler = Handle()
    private let hid = HIDSensors()
    private let smc = SMC()
    private let gpu = GPUReader()
    private let batteryReader = BatteryReader()

    /// Sensors that move slowly are read on their own, longer cadence: even
    /// deduplicated, the thermal sensors cost far more than everything else in
    /// a sample put together, and neither a die temperature nor a battery
    /// percentage changes meaningfully within a second.
    private var cachedThermals = ThermalSample()
    private var thermalsReadAt: Date?
    private var cachedBattery: BatterySample?
    private var batteryReadAt: Date?

    private let thermalInterval: TimeInterval = 3
    private let batteryInterval: TimeInterval = 5

    func host() -> HostSample {
        var info = RoHostInfo()
        ro_host_info(&info)
        let hostname = text(of: info.hostname)
        return HostSample(
            name: computerName ?? hostname,
            model: text(of: info.model),
            chip: text(of: info.chip),
            osVersion: text(of: info.os_version),
            osBuild: text(of: info.os_build),
            hostname: hostname,
            performanceCores: Int(info.performance_cores),
            efficiencyCores: Int(info.efficiency_cores),
            logicalCores: Int(info.logical_cores),
            memoryBytes: info.memory_bytes
        )
    }

    func sample() -> SystemSample {
        guard let handle = sampler.pointer else { return SystemSample() }

        var raw = RoSnapshot()
        ro_sample(handle, &raw)

        var sample = SystemSample()
        sample.cpu = CPUSample(
            total: raw.cpu_total,
            user: raw.cpu_user,
            system: raw.cpu_system,
            cores: withUnsafeBytes(of: raw.cores) {
                Array($0.bindMemory(to: Double.self).prefix(Int(raw.core_count)))
            },
            loadAverage: [raw.load_average.0, raw.load_average.1, raw.load_average.2]
        )
        sample.memory = MemorySample(
            total: raw.memory_total,
            used: raw.memory_used,
            app: raw.memory_app,
            wired: raw.memory_wired,
            compressed: raw.memory_compressed,
            cached: raw.memory_cached,
            pressure: raw.memory_pressure,
            pressureLevel: raw.memory_pressure_level,
            swapUsed: raw.swap_used,
            swapTotal: raw.swap_total
        )
        sample.network = NetworkSample(
            downloadBytesPerSecond: raw.network_rx_bytes_per_sec,
            uploadBytesPerSecond: raw.network_tx_bytes_per_sec,
            downloadTotal: raw.network_rx_total,
            uploadTotal: raw.network_tx_total
        )
        sample.uptime = TimeInterval(raw.uptime_seconds)
        sample.processCount = Int(raw.process_count)
        sample.volumes = volumes()
        sample.thermals = thermals()
        sample.battery = battery()
        sample.gpu = gpu.read().map {
            GPUSample(
                name: $0.name,
                coreCount: $0.coreCount,
                utilisation: $0.utilisation,
                inUseMemory: $0.inUseMemory
            )
        }
        return sample
    }

    /// Reads only to reset the counters that rates are measured against, after
    /// a stretch with nothing sampled. The sensors are left alone: they report
    /// levels rather than rates, so they have nothing to catch up on.
    func prime() {
        guard let handle = sampler.pointer else { return }
        var raw = RoSnapshot()
        ro_sample(handle, &raw)
        var process = RoProcess()
        _ = ro_top_processes(handle, &process, 1, ProcessSort.cpu.rawValue)
    }

    /// Walking every process is the expensive read here, so it is deliberately
    /// a separate call the UI makes less often.
    func processes(limit: Int, sort: ProcessSort) -> [ProcessSample] {
        guard let handle = sampler.pointer else { return [] }
        var buffer = [RoProcess](repeating: RoProcess(), count: limit)
        let count = ro_top_processes(handle, &buffer, UInt32(limit), sort.rawValue)
        return buffer.prefix(Int(count)).map {
            ProcessSample(
                pid: $0.pid,
                name: text(of: $0.name),
                cpu: $0.cpu,
                memory: $0.memory,
                energyImpact: $0.energy_impact
            )
        }
    }

    private func volumes() -> [VolumeSample] {
        var buffer = [RoVolume](repeating: RoVolume(), count: 12)
        let count = ro_volumes(&buffer, 12)
        return buffer.prefix(Int(count)).map {
            VolumeSample(
                name: text(of: $0.name),
                mountPoint: text(of: $0.mount_point),
                total: $0.total,
                free: $0.free_bytes
            )
        }
    }

    private func battery() -> BatterySample? {
        if let readAt = batteryReadAt, Date().timeIntervalSince(readAt) < batteryInterval {
            return cachedBattery
        }
        batteryReadAt = Date()
        cachedBattery = batteryReader.read().map {
            BatterySample(
                charge: $0.charge,
                isCharging: $0.isCharging,
                isPluggedIn: $0.isPluggedIn,
                minutesRemaining: $0.minutesRemaining,
                cycleCount: $0.cycleCount,
                health: $0.health,
                watts: $0.watts
            )
        }
        return cachedBattery
    }

    private func thermals() -> ThermalSample {
        if let readAt = thermalsReadAt, Date().timeIntervalSince(readAt) < thermalInterval {
            return cachedThermals
        }
        thermalsReadAt = Date()

        var sample = ThermalSample()

        if let readings = hid?.readAll(), !readings.isEmpty {
            let die = readings.filter { $0.name.hasPrefix("PMU tdie") }.map(\.celsius)
            if !die.isEmpty {
                sample.socPeak = die.max()
                sample.socAverage = die.reduce(0, +) / Double(die.count)
            }
            let drive = readings.filter { $0.name.contains("NAND") }.map(\.celsius)
            if !drive.isEmpty { sample.driveTemperature = drive.max() }
            let cells = readings.filter { $0.name.contains("gas gauge") }.map(\.celsius)
            if !cells.isEmpty { sample.batteryTemperature = cells.reduce(0, +) / Double(cells.count) }
        }

        if let smc {
            sample.fans = smc.fans().map {
                FanSample(id: $0.index, rpm: $0.rpm, fraction: $0.fraction)
            }
            // PSTR is the whole machine's draw, which is the number worth showing.
            if let watts = smc.read("PSTR"), watts > 0, watts < 500 {
                sample.systemWatts = watts
            }
            let enclosure = ["Ts0P", "Ts1P"].compactMap { smc.read($0) }.filter { $0 > 1 && $0 < 100 }
            if !enclosure.isEmpty {
                sample.enclosureTemperature = enclosure.max()
            }
        }

        cachedThermals = sample
        return sample
    }
}

/// The Mac's name as the user set it, which is not the same as its hostname:
/// "Thomas's MacBook Pro" versus "mac.home".
private var computerName: String? {
    guard let name = SCDynamicStoreCopyComputerName(nil, nil) as String?, !name.isEmpty else {
        return nil
    }
    return name
}

/// Pulls a Swift string out of one of the C ABI's fixed char arrays.
private func text<T>(of value: T) -> String {
    withUnsafeBytes(of: value) { raw in
        guard let base = raw.baseAddress else { return "" }
        return String(cString: base.assumingMemoryBound(to: CChar.self))
    }
}
