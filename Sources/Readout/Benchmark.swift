import Foundation

/// Times each sensor read. Run with `READOUT_BENCH=1` against the built binary.
///
/// This exists because the readings' costs are wildly uneven and not guessable:
/// the thermal sensors turned out to cost more than everything else in a sample
/// put together — 80 ms, once a second, on a menu bar app — while the Rust core
/// samples CPU, memory, network and disks in under 0.05 ms. Anything added here
/// later should be measured the same way rather than assumed cheap.
@MainActor
enum Benchmark {
    static func runIfRequested() {
        guard ProcessInfo.processInfo.environment["READOUT_BENCH"] != nil else { return }

        func time(_ label: String, _ iterations: Int, _ work: () -> Void) {
            let start = DispatchTime.now().uptimeNanoseconds
            for _ in 0 ..< iterations { work() }
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start)
            print(String(format: "  %-16@ %8.3f ms", label as NSString,
                         elapsed / Double(iterations) / 1e6))
        }

        let hid = HIDSensors()
        let smc = SMC()
        let gpu = GPUReader()
        let battery = BatteryReader()

        print("responsive scrolling: \(ResponsiveScrolling.verify())")
        print("per call:")
        time("hid sensors", 20) { _ = hid?.readAll() }
        time("smc fans", 20) { _ = smc?.fans() }
        time("smc power", 20) { _ = smc?.read("PSTR") }
        time("gpu", 20) { _ = gpu.read() }
        time("battery", 20) { _ = battery.read() }
        exit(0)
    }
}
