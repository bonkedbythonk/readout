import Foundation
import SwiftUI

/// Formatting shared across the panel, so a byte count looks the same
/// everywhere it appears.
enum Format {
    static func bytes(_ value: UInt64) -> String {
        bytes(Double(value))
    }

    static func bytes(_ value: Double) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var value = value
        var unit = 0
        while value >= 1000, unit < units.count - 1 {
            value /= 1000
            unit += 1
        }
        let decimals = unit >= 3 ? (value < 10 ? 2 : 1) : 0
        return String(format: "%.\(decimals)f %@", value, units[unit])
    }

    /// Memory is quoted in binary units, the way Activity Monitor does it,
    /// while storage and network stay decimal to match Finder and the system's
    /// own network readouts.
    static func memory(_ value: UInt64) -> String {
        var value = Double(value)
        let units = ["B", "KB", "MB", "GB", "TB"]
        var unit = 0
        while value >= 1024, unit < units.count - 1 {
            value /= 1024
            unit += 1
        }
        let decimals = unit >= 3 ? (value < 10 ? 2 : 1) : 0
        return String(format: "%.\(decimals)f %@", value, units[unit])
    }

    static func rate(_ bytesPerSecond: Double) -> String {
        bytes(bytesPerSecond) + "/s"
    }

    static func percent(_ fraction: Double) -> String {
        "\(Int((fraction * 100).rounded()))%"
    }

    static func temperature(_ celsius: Double) -> String {
        String(format: "%.0f°", celsius)
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        let days = total / 86_400
        let hours = (total % 86_400) / 3_600
        let minutes = (total % 3_600) / 60
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }

    static func minutes(_ value: Int) -> String {
        let hours = value / 60
        let minutes = value % 60
        return hours > 0 ? "\(hours)h \(minutes)m" : "\(minutes)m"
    }
}

/// One palette for the whole app.
///
/// The default state is the user's accent colour, the same as the rest of the
/// system. Colour is spent only where it carries meaning: a value close to a
/// limit, or a temperature that is genuinely high. A panel that is calm at a
/// glance is what makes a reading stand out when it is not.
enum Palette {
    static let accent = Color.accentColor

    /// Accent while a value is unremarkable, warming up as it approaches its
    /// limit.
    static func level(_ fraction: Double) -> Color {
        switch fraction {
        case ..<0.75: return accent
        case ..<0.90: return .yellow
        case ..<0.97: return .orange
        default: return .red
        }
    }

    /// Apple silicon runs hot by design and only throttles near 100 °C, so
    /// anything under 80 is left uncoloured.
    static func temperature(_ celsius: Double) -> Color {
        switch celsius {
        case ..<80: return accent
        case ..<90: return .yellow
        case ..<100: return .orange
        default: return .red
        }
    }

    /// Values in a section header stay plain until they are worth noticing.
    static func emphasis(_ fraction: Double) -> Color {
        fraction < 0.90 ? .primary : level(fraction)
    }

    static func temperatureEmphasis(_ celsius: Double) -> Color {
        celsius < 90 ? .primary : temperature(celsius)
    }
}
