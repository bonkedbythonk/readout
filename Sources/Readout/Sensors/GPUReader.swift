import Foundation
import IOKit

/// Reads the integrated GPU's utilisation from its IOAccelerator entry.
///
/// The numbers live in a dictionary the driver publishes; if a future driver
/// stops publishing them, this reports nothing rather than guessing.
struct GPUReader {
    struct Reading {
        let name: String
        let coreCount: Int
        let utilisation: Double      // 0...1
        let inUseMemory: UInt64
    }

    func read() -> Reading? {
        let matching = IOServiceMatching("IOAccelerator")
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == kIOReturnSuccess
        else { return nil }
        defer { IOObjectRelease(iterator) }

        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }

            guard let properties = copyProperties(of: entry) else { continue }
            guard let statistics = properties["PerformanceStatistics"] as? [String: Any] else {
                continue
            }

            let utilisation = (statistics["Device Utilization %"] as? NSNumber)?.doubleValue
                ?? (statistics["Renderer Utilization %"] as? NSNumber)?.doubleValue
            guard let utilisation else { continue }

            return Reading(
                name: properties["model"] as? String ?? "GPU",
                coreCount: (properties["gpu-core-count"] as? NSNumber)?.intValue ?? 0,
                utilisation: (utilisation / 100).clamped(to: 0 ... 1),
                inUseMemory: (statistics["In use system memory"] as? NSNumber)?.uint64Value ?? 0
            )
        }
        return nil
    }

    private func copyProperties(of entry: io_registry_entry_t) -> [String: Any]? {
        var unmanaged: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(entry, &unmanaged, kCFAllocatorDefault, 0)
            == kIOReturnSuccess,
            let properties = unmanaged?.takeRetainedValue() as? [String: Any]
        else { return nil }
        return properties
    }
}
