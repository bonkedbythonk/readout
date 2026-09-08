import CoreGraphics
import Foundation
import Observation
import ServiceManagement
import SwiftUI

/// Drives sampling and holds everything the UI reads.
///
/// The menu bar item is visible all day, so the timer slows right down while
/// the panel is closed and only the cheap readings keep running.
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
            if isDetailOpen {
                processRefreshes = 0
                Task { await refreshProcesses() }
            }
        }
    }

    var isPanelOpen = false {
        didSet {
            guard isPanelOpen != oldValue else { return }
            restartTimer()
            if isPanelOpen {
                processRefreshes = 0
                Task { await refreshProcesses() }
            }
        }
    }

    private let sampler = Sampler()
    private var timer: Task<Void, Never>?
    private var tick = 0
    private var processRefreshes = 0

    private static let historyLength = 60
    private let openInterval = Duration.seconds(1)
    /// The details window redraws roughly forty rows and two graphs per
    /// sample, so it reads on a slower beat than the panel: it is a reference
    /// view, not something you watch for a spike.
    private let detailInterval = Duration.milliseconds(2000)
    private let closedInterval = Duration.seconds(5)

    init() {
        Task {
            host = await sampler.host()
            await refresh()
            restartTimer()
        }
    }

    private var isVisible: Bool { isPanelOpen || isDetailOpen }

    private func restartTimer() {
        timer?.cancel()
        let interval = switch (isPanelOpen, isDetailOpen) {
        case (true, _): openInterval
        case (false, true): detailInterval
        default: closedInterval
        }
        timer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled, let self else { return }
                await self.refresh()
            }
        }
    }

    private func refresh() async {
        let latest = await sampler.sample()
        sample = latest

        append(latest.cpu.total, to: &cpuHistory)
        append(latest.memory.fraction, to: &memoryHistory)
        append(
            max(latest.network.downloadBytesPerSecond, latest.network.uploadBytesPerSecond),
            to: &networkHistory
        )

        tick += 1
        // Walking every process is the costly read, so it only runs while
        // someone is looking, and then only every few samples.
        // Walking every process is the costly read, so it only runs while
        // someone is looking, and then only every few samples. The first
        // sample of a delta reads as zero, so the opening tick gets a second
        // pass — bounded, because an unbounded "until it lands" retry would
        // walk the whole process table every second forever.
        if isVisible, tick % 3 == 0 || processRefreshes < 2 {
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
