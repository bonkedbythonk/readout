import Foundation

/// Plain values handed from the sampling actor to the UI. Everything here is
/// a snapshot: no lazy reads, no references back into IOKit or Rust.

struct CPUSample: Sendable, Equatable {
    var total = 0.0
    var user = 0.0
    var system = 0.0
    var cores: [Double] = []
    var loadAverage: [Double] = [0, 0, 0]

    var idle: Double { max(0, 1 - total) }
}

struct MemorySample: Sendable, Equatable {
    var total: UInt64 = 0
    var used: UInt64 = 0
    var app: UInt64 = 0
    var wired: UInt64 = 0
    var compressed: UInt64 = 0
    var cached: UInt64 = 0
    var pressure = 0.0
    var pressureLevel: UInt32 = 0
    var swapUsed: UInt64 = 0
    var swapTotal: UInt64 = 0

    var fraction: Double { total > 0 ? Double(used) / Double(total) : 0 }
}

struct NetworkSample: Sendable, Equatable {
    var downloadBytesPerSecond = 0.0
    var uploadBytesPerSecond = 0.0
    var downloadTotal: UInt64 = 0
    var uploadTotal: UInt64 = 0
}

struct FanSample: Sendable, Equatable, Identifiable {
    var id: Int
    var rpm: Double
    var fraction: Double
}

struct ThermalSample: Sendable, Equatable {
    /// Hottest of the SoC die sensors, which is what throttling tracks.
    var socPeak: Double?
    var socAverage: Double?
    var driveTemperature: Double?
    var batteryTemperature: Double?
    var enclosureTemperature: Double?
    var systemWatts: Double?
    var fans: [FanSample] = []

    var hasAnything: Bool {
        socPeak != nil || driveTemperature != nil || !fans.isEmpty || systemWatts != nil
    }
}

struct GPUSample: Sendable, Equatable {
    var name: String
    var coreCount: Int
    var utilisation: Double
    var inUseMemory: UInt64
}

struct BatterySample: Sendable, Equatable {
    var charge: Double
    var isCharging: Bool
    var isPluggedIn: Bool
    var minutesRemaining: Int?
    var cycleCount: Int
    var health: Double
    var watts: Double
}

struct VolumeSample: Sendable, Equatable, Identifiable {
    var id: String { mountPoint }
    var name: String
    var mountPoint: String
    var total: UInt64
    var free: UInt64

    var used: UInt64 { total > free ? total - free : 0 }
    var fraction: Double { total > 0 ? Double(used) / Double(total) : 0 }
}

struct ProcessSample: Sendable, Equatable, Identifiable {
    var id: Int32 { pid }
    var pid: Int32
    var name: String
    var cpu: Double
    var memory: UInt64
    /// Relative energy impact: CPU time weighted with idle wake-ups, the same
    /// idea as Activity Monitor's Energy column. Not watts.
    var energyImpact: Double
}

struct HostSample: Sendable, Equatable {
    /// The name shown in Sharing settings, e.g. "Thomas's MacBook Pro".
    var name = ""
    var model = "Mac"
    var chip = ""
    var osVersion = ""
    var osBuild = ""
    var hostname = ""
    var performanceCores = 0
    var efficiencyCores = 0
    var logicalCores = 0
    var memoryBytes: UInt64 = 0
}

struct SystemSample: Sendable, Equatable {
    var cpu = CPUSample()
    var memory = MemorySample()
    var network = NetworkSample()
    var thermals = ThermalSample()
    var gpu: GPUSample?
    var battery: BatterySample?
    var volumes: [VolumeSample] = []
    var uptime: TimeInterval = 0
    var processCount = 0
}

/// Ordering for the process list, matching the C ABI's RO_SORT_* values.
enum ProcessSort: UInt32, CaseIterable, Identifiable, Sendable {
    case cpu = 0
    case memory = 1
    case energy = 2

    var id: UInt32 { rawValue }

    var title: String {
        switch self {
        case .cpu: return "CPU"
        case .memory: return "Memory"
        case .energy: return "Energy"
        }
    }
}
