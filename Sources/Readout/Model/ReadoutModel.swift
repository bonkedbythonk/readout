import CoreGraphics
import Foundation
import Observation
import ServiceManagement
import SwiftUI

/// Drives sampling and holds everything the UI reads.
///
/// Nothing is sampled while neither the panel nor the details window is open.
/// The menu bar item shows no readings, so there is nobody to sample for, and
/// SwiftUI keeps a closed panel's views alive: every write to this model
/// re-renders them off screen. Sampling every five seconds while closed cost
/// 1.45% CPU once the panel had been opened, against 0.25% before it had.
@MainActor
@Observable
final class ReadoutModel {
    private(set) var host = HostSample()
    private(set) var sample = SystemSample()
    private(set) var processes: [ProcessSample] = []
    /// The single heaviest energy user, kept fresh even when the detailed
    /// process list is not on screen.
    private(set) var topEnergyProcess: ProcessSample?

    /// Remembered across openings: the panel is rebuilt from scratch every
    /// time the menu bar item is clicked, and starting from a guessed height
    /// makes it snap to its real size mid-animation.
    var panelContentHeight: CGFloat = 560

    private(set) var cpuHistory: [Double] = []
    private(set) var memoryHistory: [Double] = []
    private(set) var networkHistory: [Double] = []

    var processSort: ProcessSort = .cpu {
        didSet { Task { await refreshProcesses() } }
    }

    /// Set while the details window is open, so its tables keep updating.
    var isDetailOpen = false {
        didSet {
            guard isDetailOpen != oldValue else { return }
            restartTimer()
        }
    }

    var isPanelOpen = false {
        didSet {
            guard isPanelOpen != oldValue else { return }
            restartTimer()
        }
    }

    private let sampler = Sampler()
    private var timer: Task<Void, Never>?
    private var tick = 0
    private var processRefreshes = 0
    private var lastSampled: ContinuousClock.Instant?

    private static let historyLength = 60
    private let openInterval = Duration.seconds(1)
    /// The details window redraws roughly forty rows and two graphs per
    /// sample, so it reads on a slower beat than the panel: it is a reference
    /// view, not something you watch for a spike.
    private let detailInterval = Duration.milliseconds(2000)

    init() {
        Task {
            host = await sampler.host()
            // One reading up front, so the panel's first opening lays out the
            // cards this Mac actually has instead of an empty sample.
            await refresh()
        }
    }

    private var isVisible: Bool { isPanelOpen || isDetailOpen }

    private func restartTimer() {
        timer?.cancel()
        timer = nil
        guard isVisible else { return }

        let interval = isPanelOpen ? openInterval : detailInterval
        processRefreshes = 0
        timer = Task { [weak self] in
            await self?.catchUp(interval: interval)
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: interval)
            }
        }
    }

    /// Every rate here is a difference against the previous reading, so after
    /// a stretch with nothing sampled the first reading would be an average
    /// over the whole gap — an hour's CPU load, shown as the current one. A
    /// throwaway reading resets the counters and the real one follows shortly.
    /// The graphs start over for the same reason: an old tail spliced onto new
    /// samples draws the gap as if it were a second.
    private func catchUp(interval: Duration) async {
        if let lastSampled, ContinuousClock.now - lastSampled < interval * 2 {
            return
        }
        cpuHistory.removeAll()
        memoryHistory.removeAll()
        networkHistory.removeAll()
        await sampler.prime()
        try? await Task.sleep(for: .milliseconds(500))
    }

    private func refresh() async {
        let latest = await sampler.sample()
        sample = latest
        lastSampled = .now

        append(latest.cpu.total, to: &cpuHistory)
        append(latest.memory.fraction, to: &memoryHistory)
        append(
            max(latest.network.downloadBytesPerSecond, latest.network.uploadBytesPerSecond),
            to: &networkHistory
        )

        tick += 1
        // Walking every process is the costly read, so it only runs while
        // someone is looking, and then only every few samples — plus once
        // straight away, so the list is not a few seconds stale on opening.
        if isVisible, processRefreshes == 0 || tick % 3 == 0 {
            await refreshProcesses()
        }
    }

    private func refreshProcesses() async {
        processRefreshes += 1
        processes = await sampler.processes(limit: 12, sort: processSort)
        if processSort == .energy {
            topEnergyProcess = processes.first
        } else if let heaviest = processes.max(by: { $0.energyImpact < $1.energyImpact }) {
            topEnergyProcess = heaviest
        }
    }

    private func append(_ value: Double, to history: inout [Double]) {
        history.append(value)
        if history.count > Self.historyLength {
            history.removeFirst(history.count - Self.historyLength)
        }
    }
}

// MARK: - Login item

extension ReadoutModel {
    var launchesAtLogin: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Returns a message when the request could not be honoured, so the UI can
    /// say so instead of silently doing nothing.
    func setLaunchAtLogin(_ enabled: Bool) -> String? {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}
