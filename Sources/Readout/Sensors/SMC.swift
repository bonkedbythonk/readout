import Foundation
import IOKit

/// Minimal read-only client for the System Management Controller.
///
/// The AppleSMC user client takes a fixed 80-byte request struct. Swift makes
/// no promises about struct layout, so the buffer is assembled by hand at the
/// offsets the C definition uses.
///
/// Only reads are implemented, deliberately: writing SMC keys can override fan
/// behaviour and nothing here has any business doing that.
final class SMC {
    private enum Offset {
        static let key = 0
        static let dataSize = 28
        static let dataType = 32
        static let result = 40
        static let data8 = 42
        static let bytes = 48
        static let total = 80
    }

    private enum Selector: UInt8 {
        case readKey = 5
        case keyFromIndex = 8
        case keyInfo = 9
    }

    private struct KeyInfo {
        let size: Int
        let type: UInt32
    }

    private var connection: io_connect_t = 0
    private var infoCache: [UInt32: KeyInfo?] = [:]
    /// A fan's count and its minimum and maximum speeds are fixed for the
    /// machine, so only the live speed is worth re-reading.
    private var fanLimits: [(minimum: Double, maximum: Double)]?

    init?() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard IOServiceOpen(service, mach_task_self_, 0, &connection) == kIOReturnSuccess,
              connection != 0
        else { return nil }
    }

    deinit {
        if connection != 0 { IOServiceClose(connection) }
    }

    /// Reads a four-character key, decoding the numeric SMC types.
    func read(_ key: String) -> Double? {
        guard let code = Self.fourCharCode(key), let info = keyInfo(for: code) else { return nil }

        var request = [UInt8](repeating: 0, count: Offset.total)
        writeUInt32(code, into: &request, at: Offset.key)
        writeUInt32(UInt32(info.size), into: &request, at: Offset.dataSize)
        writeUInt32(info.type, into: &request, at: Offset.dataType)
        request[Offset.data8] = Selector.readKey.rawValue

        guard let response = call(request) else { return nil }
        let payload = Array(response[Offset.bytes ..< Offset.total])
        return Self.decode(payload, size: info.size, type: info.type)
    }

    /// Every key this Mac's SMC publishes, in its own order.
    func allKeys() -> [String] {
        guard let count = read("#KEY").map({ Int($0) }), count > 0 else { return [] }
        return (0 ..< count).compactMap { index in
            var request = [UInt8](repeating: 0, count: Offset.total)
            writeUInt32(UInt32(index), into: &request, at: Offset.dataSize)
            request[Offset.data8] = Selector.keyFromIndex.rawValue
            guard let response = call(request) else { return nil }
            let code = readUInt32(response, at: Offset.key)
            return Self.string(from: code)
        }
    }

    private func keyInfo(for code: UInt32) -> KeyInfo? {
        if let cached = infoCache[code] { return cached }

        var request = [UInt8](repeating: 0, count: Offset.total)
        writeUInt32(code, into: &request, at: Offset.key)
        request[Offset.data8] = Selector.keyInfo.rawValue

        var info: KeyInfo?
        if let response = call(request) {
            let size = readUInt32(response, at: Offset.dataSize)
            let type = readUInt32(response, at: Offset.dataType)
            if size > 0, size <= 32 {
                info = KeyInfo(size: Int(size), type: type)
            }
        }
        infoCache[code] = info
        return info
    }

    private func call(_ request: [UInt8]) -> [UInt8]? {
        var response = [UInt8](repeating: 0, count: Offset.total)
        var responseSize = Offset.total
        let status = request.withUnsafeBytes { input -> kern_return_t in
            response.withUnsafeMutableBytes { output in
                IOConnectCallStructMethod(
                    connection,
                    2, // kSMCHandleYPCEvent
                    input.baseAddress,
                    Offset.total,
                    output.baseAddress,
                    &responseSize
                )
            }
        }
        guard status == kIOReturnSuccess, response[Offset.result] == 0 else { return nil }
        return response
    }

    private static func fourCharCode(_ key: String) -> UInt32? {
        let bytes = Array(key.utf8)
        guard bytes.count == 4 else { return nil }
        return bytes.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }

    private static func string(from code: UInt32) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8((code >> UInt32($0)) & 0xff) }
        return String(decoding: bytes, as: UTF8.self)
    }

    private static func decode(_ bytes: [UInt8], size: Int, type: UInt32) -> Double? {
        guard size <= bytes.count else { return nil }
        switch Self.string(from: type) {
        case "flt ":
            guard size == 4 else { return nil }
            let raw = UInt32(bytes[0]) | UInt32(bytes[1]) << 8
                | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24
            return Double(Float(bitPattern: raw))
        case "ui8 ", "si8 ":
            return Double(bytes[0])
        case "ui16":
            return Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1]))
        case "ui32":
            return Double((UInt32(bytes[0]) << 24) | (UInt32(bytes[1]) << 16)
                | (UInt32(bytes[2]) << 8) | UInt32(bytes[3]))
        case "sp78":
            // Signed fixed point: 7 integer bits, 8 fractional.
            return Double(Int16(bitPattern: UInt16(bytes[0]) << 8 | UInt16(bytes[1]))) / 256.0
        case "fpe2":
            return Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1])) / 4.0
        default:
            return nil
        }
    }
}

extension SMC {
    struct Fan {
        let index: Int
        let rpm: Double
        let minimum: Double
        let maximum: Double

        /// How hard the fan is working between its own limits.
        var fraction: Double {
            guard maximum > minimum else { return 0 }
            return ((rpm - minimum) / (maximum - minimum)).clamped(to: 0 ... 1)
        }
    }

    /// Every fan the SMC reports. Fanless Macs return an empty array.
    func fans() -> [Fan] {
        if fanLimits == nil {
            guard let count = read("FNum"), count > 0, count < 10 else {
                fanLimits = []
                return []
            }
            fanLimits = (0 ..< Int(count)).map { index in
                (minimum: read("F\(index)Mn") ?? 0, maximum: read("F\(index)Mx") ?? 0)
            }
        }
        guard let limits = fanLimits else { return [] }

        return limits.enumerated().compactMap { index, limit in
            guard let rpm = read("F\(index)Ac") else { return nil }
            return Fan(index: index, rpm: rpm, minimum: limit.minimum, maximum: limit.maximum)
        }
    }
}

/// The request buffer is little-endian on every Mac these run on; the byte
/// order is spelled out rather than inherited from struct layout.
private func writeUInt32(_ value: UInt32, into buffer: inout [UInt8], at offset: Int) {
    buffer[offset] = UInt8(truncatingIfNeeded: value)
    buffer[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
    buffer[offset + 2] = UInt8(truncatingIfNeeded: value >> 16)
    buffer[offset + 3] = UInt8(truncatingIfNeeded: value >> 24)
}

private func readUInt32(_ buffer: [UInt8], at offset: Int) -> UInt32 {
    UInt32(buffer[offset])
        | UInt32(buffer[offset + 1]) << 8
        | UInt32(buffer[offset + 2]) << 16
        | UInt32(buffer[offset + 3]) << 24
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
