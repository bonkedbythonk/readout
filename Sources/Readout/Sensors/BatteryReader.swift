import Foundation
import IOKit

/// Battery state, read from the smart battery's IORegistry entry.
///
/// Desktops have no such entry, which is a normal outcome: the caller hides
/// the section rather than showing zeroes.
struct BatteryReader {
    struct Reading {
        let charge: Double            // 0...1
        let isCharging: Bool
        let isPluggedIn: Bool
        let minutesRemaining: Int?    // nil while the estimate is still settling
        let cycleCount: Int
        /// Current full-charge capacity against the design capacity.
        let health: Double
        let temperature: Double       // °C
        let watts: Double             // positive charging, negative discharging
    }

    func read() -> Reading? {
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("AppleSmartBattery")
        )
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }

        var unmanaged: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &unmanaged, kCFAllocatorDefault, 0)
            == kIOReturnSuccess,
            let properties = unmanaged?.takeRetainedValue() as? [String: Any]
        else { return nil }

        func number(_ key: String) -> Double? {
            (properties[key] as? NSNumber)?.doubleValue
        }

        guard let percentage = number("CurrentCapacity") else { return nil }

        let isCharging = properties["IsCharging"] as? Bool ?? false
        // The estimate reads as a sentinel while macOS is still working it out.
        let rawMinutes = number("TimeRemaining").map(Int.init)
        let minutes = rawMinutes.flatMap { $0 > 0 && $0 < 60 * 24 ? $0 : nil }

        let design = number("DesignCapacity") ?? 0
        let nominal = number("NominalChargeCapacity") ?? number("AppleRawMaxCapacity") ?? 0

        let millivolts = number("Voltage") ?? 0
        let milliamps = number("InstantAmperage") ?? number("Amperage") ?? 0

        return Reading(
            charge: (percentage / 100).clamped(to: 0 ... 1),
            isCharging: isCharging,
            isPluggedIn: properties["ExternalConnected"] as? Bool ?? false,
            minutesRemaining: minutes,
            cycleCount: Int(number("CycleCount") ?? 0),
            health: design > 0 ? (nominal / design).clamped(to: 0 ... 1) : 0,
            // The registry reports hundredths of a degree.
            temperature: (number("Temperature") ?? 0) / 100,
            watts: millivolts * milliamps / 1_000_000
        )
    }
}
