import SwiftUI

/// The panel and the details window show the same readings at two levels of
/// depth, so each reading is one view here rather than two copies.
///
/// Splitting them into separate structs also matters for scrolling: a sample
/// arrives every second, and if every card were a computed property of one big
/// body then each tick would re-evaluate the entire page — including the parts
/// whose numbers did not change. Taking only the value it draws lets SwiftUI
/// skip a card whose slice of the sample is unchanged.

struct ProcessorCard: View {
    let cpu: CPUSample
    let history: [Double]
    let performanceCores: Int
    var detailed = false

    var body: some View {
        Card(
            title: "Processor",
            symbol: "cpu",
            value: Format.percent(cpu.total),
            valueColor: Palette.emphasis(cpu.total)
        ) {
            Sparkline(values: history, color: Palette.accent)
                .frame(height: detailed ? 54 : 40)
            if detailed {
                CoreGrid(cores: cpu.cores, performanceCores: performanceCores)
                StatRow(label: "User", value: Format.percent(cpu.user))
                StatRow(label: "System", value: Format.percent(cpu.system))
                StatRow(label: "Idle", value: Format.percent(cpu.idle))
                StatRow(
                    label: "Load average",
                    value: cpu.loadAverage.map { String(format: "%.2f", $0) }
                        .joined(separator: "   ")
                )
            } else {
                HStack(spacing: 14) {
                    LegendItem(
                        color: Palette.accent,
                        label: "User",
                        value: Format.percent(cpu.user)
                    )
                    LegendItem(
                        color: Palette.accent.opacity(0.5),
                        label: "System",
                        value: Format.percent(cpu.system)
                    )
                    Spacer(minLength: 0)
                }
            }
        }
    }
}

struct MemoryCard: View {
    let memory: MemorySample
    var detailed = false

    var body: some View {
        Card(
            title: "Memory",
            symbol: "memorychip",
            value: Format.percent(memory.fraction),
            valueColor: Palette.emphasis(memory.fraction)
        ) {
            StackedBar(
                segments: [
                    .init(value: Double(memory.app), color: Palette.accent),
                    .init(value: Double(memory.wired), color: Palette.accent.opacity(0.6)),
                    .init(value: Double(memory.compressed), color: Palette.accent.opacity(0.32)),
                    .init(value: Double(memory.cached), color: Color.secondary.opacity(0.3)),
                ],
                total: Double(memory.total)
            )
            if detailed {
                StatRow(label: "App memory", value: Format.memory(memory.app))
                StatRow(label: "Wired", value: Format.memory(memory.wired))
                StatRow(label: "Compressed", value: Format.memory(memory.compressed))
                StatRow(label: "Cached files", value: Format.memory(memory.cached))
            }
            StatRow(
                label: "Used",
                value: "\(Format.memory(memory.used)) of \(Format.memory(memory.total))"
            )
            StatRow(
                label: "Pressure",
                value: pressure,
                valueColor: memory.pressureLevel > 1 ? .orange : .primary
            )
            if detailed {
                StatRow(
                    label: "Swap",
                    value: memory.swapTotal > 0
                        ? "\(Format.memory(memory.swapUsed)) of \(Format.memory(memory.swapTotal))"
                        : "Not in use"
                )
            } else if memory.swapUsed > 0 {
                StatRow(label: "Swap used", value: Format.memory(memory.swapUsed))
            }
        }
    }

    /// The kernel's own pressure state, with the figure that drives it.
    ///
    /// Warning is a normal steady state on a Mac whose memory is mostly spoken
    /// for — macOS runs there deliberately rather than leaving RAM idle — so it
    /// is reported plainly and only Critical is coloured.
    private var pressure: String {
        let state = switch memory.pressureLevel {
        case 2: "Critical"
        case 1: "Warning"
        default: "Normal"
        }
        return state
    }
}

struct GraphicsCard: View {
    let gpu: GPUSample

    var body: some View {
        Card(
            title: "Graphics",
            symbol: "cube.transparent",
            value: Format.percent(gpu.utilisation),
            valueColor: Palette.emphasis(gpu.utilisation)
        ) {
            MeterBar(fraction: gpu.utilisation, color: Palette.accent)
            StatRow(label: gpu.name, value: gpu.coreCount > 0 ? "\(gpu.coreCount) cores" : "")
            if gpu.inUseMemory > 0 {
                StatRow(label: "In use", value: Format.memory(gpu.inUseMemory))
            }
        }
    }
}

struct ThermalCard: View {
    let thermals: ThermalSample
    var detailed = false

    var body: some View {
        Card(
            title: detailed ? "Temperature & Power" : "Temperature",
            symbol: "thermometer.medium",
            value: thermals.socPeak.map(Format.temperature) ?? "—",
            valueColor: thermals.socPeak.map(Palette.temperatureEmphasis) ?? .primary
        ) {
            if let peak = thermals.socPeak {
                // 30 °C is about as cool as the die gets; 100 is where Apple
                // silicon starts to hold itself back.
                MeterBar(fraction: (peak - 30) / 70, color: Palette.temperature(peak))
            }
            if detailed {
                if let average = thermals.socAverage {
                    StatRow(label: "SoC average", value: Format.temperature(average))
                }
                if let drive = thermals.driveTemperature {
                    StatRow(label: "SSD", value: Format.temperature(drive))
                }
                if let battery = thermals.batteryTemperature {
                    StatRow(label: "Battery", value: Format.temperature(battery))
                }
                if let enclosure = thermals.enclosureTemperature {
                    StatRow(label: "Enclosure", value: Format.temperature(enclosure))
                }
                if let watts = thermals.systemWatts {
                    StatRow(label: "System power", value: String(format: "%.1f W", watts))
                }
            }
            ForEach(thermals.fans) { fan in
                if detailed {
                    VStack(alignment: .leading, spacing: 5) {
                        StatRow(label: fanLabel(fan), value: "\(Int(fan.rpm)) rpm")
                        MeterBar(fraction: fan.fraction, color: Palette.accent, height: 5)
                    }
                } else {
                    StatRow(label: fanLabel(fan), value: "\(Int(fan.rpm)) rpm")
                }
            }
        }
    }

    private func fanLabel(_ fan: FanSample) -> String {
        thermals.fans.count > 1 ? "Fan \(fan.id + 1)" : "Fan"
    }
}

struct PowerCard: View {
    let watts: Double?
    let topEnergy: ProcessSample?
    let battery: BatterySample?

    var body: some View {
        Card(
            title: "Power",
            symbol: "bolt",
            value: watts.map { String(format: "%.0f W", $0) } ?? "—"
        ) {
            if let topEnergy {
                StatRow(label: "Most energy", value: topEnergy.name)
            }
            if let battery, !battery.isCharging, battery.watts > 0 {
                StatRow(label: "From battery", value: String(format: "%.1f W", battery.watts))
            }
        }
    }
}

struct BatteryCard: View {
    let battery: BatterySample
    var detailed = false

    var body: some View {
        Card(
            title: "Battery",
            symbol: symbol,
            value: Format.percent(battery.charge),
            valueColor: isLow ? .red : .primary
        ) {
            MeterBar(fraction: battery.charge, color: isLow ? .red : Palette.accent)
            StatRow(label: "State", value: state)
            if let minutes = battery.minutesRemaining {
                StatRow(
                    label: battery.isCharging ? "Until full" : "Remaining",
                    value: Format.minutes(minutes)
                )
            }
            if detailed {
                StatRow(label: "Maximum capacity", value: Format.percent(battery.health))
                StatRow(label: "Cycle count", value: "\(battery.cycleCount)")
                StatRow(label: "Power flow", value: String(format: "%.1f W", abs(battery.watts)))
            }
        }
    }

    private var isLow: Bool { battery.charge < 0.2 && !battery.isCharging }

    private var state: String {
        if battery.isCharging { return "Charging" }
        return battery.isPluggedIn ? "Plugged in" : "On battery"
    }

    private var symbol: String {
        if battery.isCharging { return "battery.100percent.bolt" }
        switch battery.charge {
        case ..<0.15: return "battery.0percent"
        case ..<0.45: return "battery.25percent"
        case ..<0.8: return "battery.50percent"
        default: return "battery.100percent"
        }
    }
}

struct StorageCard: View {
    let volumes: [VolumeSample]
    var detailed = false

    var body: some View {
        Card(
            title: "Storage",
            symbol: "internaldrive",
            value: detailed ? nil : volumes.first.map { Format.bytes($0.free) },
            valueColor: volumes.first.map { Palette.emphasis($0.fraction) } ?? .primary
        ) {
            ForEach(shown) { volume in
                VStack(alignment: .leading, spacing: 5) {
                    StatRow(
                        label: volume.name,
                        value: detailed
                            ? "\(Format.bytes(volume.free)) free of \(Format.bytes(volume.total))"
                            : "\(Format.bytes(volume.used)) of \(Format.bytes(volume.total)) used"
                    )
                    MeterBar(fraction: volume.fraction, color: Palette.level(volume.fraction))
                }
            }
        }
    }

    private var shown: [VolumeSample] {
        detailed ? volumes : Array(volumes.prefix(1))
    }
}

struct NetworkCard: View {
    let network: NetworkSample
    let history: [Double]
    var detailed = false

    var body: some View {
        Card(title: "Network", symbol: "arrow.up.arrow.down") {
            Sparkline(values: history, color: Palette.accent, ceiling: 1)
                .frame(height: detailed ? 44 : 30)
            if detailed {
                StatRow(label: "Download", value: Format.rate(network.downloadBytesPerSecond))
                StatRow(label: "Upload", value: Format.rate(network.uploadBytesPerSecond))
                StatRow(label: "Received since boot", value: Format.bytes(network.downloadTotal))
                StatRow(label: "Sent since boot", value: Format.bytes(network.uploadTotal))
            } else {
                HStack(spacing: 16) {
                    Label(Format.rate(network.downloadBytesPerSecond), systemImage: "arrow.down")
                    Label(Format.rate(network.uploadBytesPerSecond), systemImage: "arrow.up")
                    Spacer(minLength: 0)
                }
                .font(.system(size: 12, weight: .medium))
                .monospacedDigit()
            }
        }
    }
}

/// What is using the Mac, by app rather than by process.
struct AppListCard: View {
    let processes: [ProcessSample]
    @Binding var sort: ProcessSort
    let limit: Int

    var body: some View {
        Card(title: "Top Apps", symbol: "square.stack.3d.up") {
            Picker("", selection: $sort) {
                ForEach(ProcessSort.allCases) { option in
                    Text(option.title).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)

            if processes.isEmpty {
                Text("Measuring…")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(processes.prefix(limit)) { process in
                    StatRow(label: process.name, value: value(for: process))
                }
            }

            if sort == .energy {
                Text("Energy is a relative score — CPU time weighted with idle wake-ups — not watts.")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func value(for process: ProcessSample) -> String {
        switch sort {
        case .cpu: return Format.percent(process.cpu)
        case .memory: return Format.memory(process.memory)
        case .energy: return String(format: "%.0f", process.energyImpact)
        }
    }
}

struct OverviewCard: View {
    let host: HostSample
    let uptimeMinutes: Int
    let processCount: Int

    var body: some View {
        Card(title: "Overview", symbol: "laptopcomputer") {
            StatRow(label: "Name", value: host.name)
            StatRow(label: "Model", value: host.model)
            StatRow(label: "Chip", value: host.chip)
            StatRow(label: "Cores", value: cores)
            StatRow(label: "Memory", value: Format.memory(host.memoryBytes))
            StatRow(label: "macOS", value: "\(host.osVersion) (\(host.osBuild))")
            StatRow(label: "Hostname", value: host.hostname)
            StatRow(label: "Uptime", value: Format.duration(TimeInterval(uptimeMinutes * 60)))
            StatRow(label: "Processes", value: "\(processCount)")
        }
    }

    private var cores: String {
        guard host.performanceCores > 0 || host.efficiencyCores > 0 else {
            return "\(host.logicalCores)"
        }
        return "\(host.logicalCores) · \(host.performanceCores)P + \(host.efficiencyCores)E"
    }
}
