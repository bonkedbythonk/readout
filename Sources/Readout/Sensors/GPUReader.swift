import Foundation
import IOKit

/// Reads the integrated GPU's utilisation from its IOAccelerator entry.
///
/// The numbers live in a dictionary the driver publishes; if a future driver
/// stops publishing them, this reports nothing rather than guessing.
///
/// The entry is found once and kept, and only the statistics are read from it
/// each time. Copying the entry's whole property table, as this used to, drags
/// about 110 KB of IOReport legend across on every read to use a few numbers.
final class GPUReader {
    struct Reading {
        let name: String
        let coreCount: Int
        let utilisation: Double      // 0...1
        let inUseMemory: UInt64
    }

    private var entry: io_registry_entry_t = 0
    private var name = "GPU"
    private var coreCount = 0

    deinit {
        if entry != 0 { IOObjectRelease(entry) }
    }

    func read() -> Reading? {
        if entry == 0, !connect() { return nil }
        guard let statistics = self.statistics(of: entry) else {
            // The entry went away or stopped publishing; look again next time.
            IOObjectRelease(entry)
            entry = 0
            return nil
        }
        return reading(from: statistics)
    }

    private func connect() -> Bool {
        let matching = IOServiceMatching("IOAccelerator")
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == kIOReturnSuccess
        else { return false }
        defer { IOObjectRelease(iterator) }

        while case let candidate = IOIteratorNext(iterator), candidate != 0 {
            guard let statistics = statistics(of: candidate), reading(from: statistics) != nil else {
                IOObjectRelease(candidate)
                continue
            }
            entry = candidate
            name = property("model", of: candidate) as? String ?? "GPU"
            coreCount = (property("gpu-core-count", of: candidate) as? NSNumber)?.intValue ?? 0
            return true
        }
        return false
    }

    private func reading(from statistics: [String: Any]) -> Reading? {
        let utilisation = (statistics["Device Utilization %"] as? NSNumber)?.doubleValue
            ?? (statistics["Renderer Utilization %"] as? NSNumber)?.doubleValue
        guard let utilisation else { return nil }

        return Reading(
            name: name,
            coreCount: coreCount,
            utilisation: (utilisation / 100).clamped(to: 0 ... 1),
            inUseMemory: (statistics["In use system memory"] as? NSNumber)?.uint64Value ?? 0
        )
    }

    private func statistics(of entry: io_registry_entry_t) -> [String: Any]? {
        property("PerformanceStatistics", of: entry) as? [String: Any]
    }

    private func property(_ key: String, of entry: io_registry_entry_t) -> Any? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue()
    }
}
