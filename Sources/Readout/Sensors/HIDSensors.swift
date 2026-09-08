import Foundation
import IOKit

/// Reads Apple's on-die thermal sensors through the HID event system.
///
/// None of these functions appear in a public header, so they are resolved at
/// run time and every step is allowed to fail: a Mac that publishes nothing,
/// or an OS that drops the symbols, must end up with zero readings rather than
/// a crash.
final class HIDSensors {
    struct Reading {
        let name: String
        let celsius: Double
    }

    private typealias CreateClient = @convention(c) (CFAllocator?) -> Unmanaged<AnyObject>?
    private typealias SetMatching = @convention(c) (AnyObject, CFDictionary) -> Void
    private typealias CopyServices = @convention(c) (AnyObject) -> Unmanaged<CFArray>?
    private typealias CopyProperty = @convention(c) (AnyObject, CFString) -> Unmanaged<AnyObject>?
    private typealias CopyEvent = @convention(c) (AnyObject, Int32, UInt32, UInt64) -> Unmanaged<AnyObject>?
    private typealias EventFloatValue = @convention(c) (AnyObject, UInt32) -> Double

    /// kHIDPage_AppleVendor.
    private static let applePage = 0xff00
    /// kHIDUsage_AppleVendor_TemperatureSensor.
    private static let temperatureUsage = 0x0005
    /// kIOHIDEventTypeTemperature, and the field base derived from it.
    private static let temperatureEvent: Int32 = 15
    private static let temperatureField = UInt32(temperatureEvent) << 16

    private let createClient: CreateClient
    private let setMatching: SetMatching
    private let copyServices: CopyServices
    private let copyProperty: CopyProperty
    private let copyEvent: CopyEvent
    private let eventFloatValue: EventFloatValue

    /// The client owns its service objects, so it has to outlive them.
    private var client: AnyObject?
    private var services: [(name: String, service: AnyObject)] = []

    init?() {
        guard let handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY) else {
            return nil
        }
        func symbol<T>(_ name: String, as type: T.Type) -> T? {
            guard let pointer = dlsym(handle, name) else { return nil }
            return unsafeBitCast(pointer, to: type)
        }
        guard let create = symbol("IOHIDEventSystemClientCreate", as: CreateClient.self),
              let matching = symbol("IOHIDEventSystemClientSetMatching", as: SetMatching.self),
              let services = symbol("IOHIDEventSystemClientCopyServices", as: CopyServices.self),
              let property = symbol("IOHIDServiceClientCopyProperty", as: CopyProperty.self),
              let event = symbol("IOHIDServiceClientCopyEvent", as: CopyEvent.self),
              let floatValue = symbol("IOHIDEventGetFloatValue", as: EventFloatValue.self)
        else { return nil }

        createClient = create
        setMatching = matching
        copyServices = services
        copyProperty = property
        copyEvent = event
        eventFloatValue = floatValue
        connect()
    }

    private func connect() {
        guard let client = createClient(kCFAllocatorDefault)?.takeRetainedValue() else { return }
        setMatching(client, [
            "PrimaryUsagePage": Self.applePage,
            "PrimaryUsage": Self.temperatureUsage,
        ] as CFDictionary)

        guard let found = copyServices(client)?.takeRetainedValue() as? [AnyObject] else { return }
        self.client = client

        // This Mac publishes each die sensor through several services under
        // the same product name, reporting the same value to within a few
        // tenths. Reading one of each is what makes a sample affordable:
        // every service costs an IPC round trip, and reading all of them took
        // 80 ms — a menu bar app cannot spend that every second.
        var seen = Set<String>()
        services = found.compactMap { service in
            guard let name = copyProperty(service, "Product" as CFString)?
                .takeRetainedValue() as? String,
                seen.insert(name).inserted
            else { return nil }
            return (name: name, service: service)
        }
    }

    var isAvailable: Bool { !services.isEmpty }

    /// All plausible temperature readings, in °C.
    ///
    /// Some sensors are calibration or unpopulated channels that report values
    /// far outside anything physical, so they are dropped here rather than at
    /// every call site.
    func readAll() -> [Reading] {
        services.compactMap { entry in
            guard let event = copyEvent(entry.service, Self.temperatureEvent, 0, 0)?
                .takeRetainedValue()
            else { return nil }
            let celsius = eventFloatValue(event, Self.temperatureField)
            guard celsius.isFinite, celsius > 1, celsius < 150 else { return nil }
            return Reading(name: entry.name, celsius: celsius)
        }
    }
}
