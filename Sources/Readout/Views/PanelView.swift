import SwiftUI

/// The window that drops out of the menu bar item.
///
/// This is the at-a-glance view, so it carries only the readings worth
/// interrupting yourself for. Anything you would go looking for deliberately —
/// battery cycles, per-core load, every volume — lives in the details window.
struct PanelView: View {
    @Bindable var model: ReadoutModel
    @Bindable var updates: UpdateChecker
    @Environment(\.openWindow) private var openWindow

    /// Local, not observed state: the geometry reader below writes this from
    /// inside a layout pass, and writing observed state there re-invalidates
    /// the view every pass. Seeded from the last height the model saw so the
    /// panel opens at its real size instead of snapping to it.
    @State private var contentHeight: CGFloat

    @State private var launchAtLoginError: String?

    init(model: ReadoutModel, updates: UpdateChecker) {
        self.model = model
        self.updates = updates
        _contentHeight = State(initialValue: model.panelContentHeight)
    }

    private let width: CGFloat = 340
    private let maximumContentHeight: CGFloat = 620

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            ScrollView {
                // SwiftUI keeps a closed panel's views alive, and whatever they
                // read from the model re-renders them off screen with every
                // sample — every two seconds while the details window is open.
                // Reading the samples only while open means a closed panel no
                // longer depends on them.
                if model.isPanelOpen {
                    cards
                }
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(height: min(contentHeight, maximumContentHeight))

            Divider()
            if let release = updates.available {
                updateBanner(release)
                Divider()
            } else if updates.status != .idle {
                updateStatus
                Divider()
            }
            footer
        }
        .frame(width: width)
        .onAppear { model.isPanelOpen = true }
        .onDisappear {
            updates.clearStatus()
            model.isPanelOpen = false
            model.panelContentHeight = contentHeight
        }
    }

    private var cards: some View {
        VStack(spacing: 10) {
            ProcessorCard(
                cpu: model.sample.cpu,
                history: model.cpuHistory,
                performanceCores: model.host.performanceCores
            )
            AppListCard(
                processes: model.processes,
                sort: $model.processSort,
                limit: 4
            )
            MemoryCard(memory: model.sample.memory)
            if model.sample.thermals.socPeak != nil
                || !model.sample.thermals.fans.isEmpty {
                ThermalCard(thermals: model.sample.thermals)
            }
            if model.sample.thermals.systemWatts != nil {
                PowerCard(
                    watts: model.sample.thermals.systemWatts,
                    topEnergy: model.topEnergyProcess,
                    battery: model.sample.battery
                )
            }
            if let battery = model.sample.battery {
                BatteryCard(battery: battery)
            }
            if !model.sample.volumes.isEmpty {
                StorageCard(volumes: model.sample.volumes)
            }
            NetworkCard(network: model.sample.network, history: model.networkHistory)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
        .background(
            GeometryReader { proxy in
                Color.clear.onChange(of: proxy.size.height, initial: true) { _, height in
                    guard height > 0 else { return }
                    // Resizing the window is not something to ease into:
                    // animating it fights the menu bar's own open animation.
                    var transaction = Transaction()
                    transaction.disablesAnimations = true
                    withTransaction(transaction) { contentHeight = height }
                }
            }
        )
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "laptopcomputer")
                .font(.system(size: 18))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(model.host.name.isEmpty ? model.host.model : model.host.name)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private var subtitle: String {
        [model.host.chip, Format.memory(model.host.memoryBytes)]
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    private func updateBanner(_ release: UpdateChecker.Release) -> some View {
        Button {
            NSWorkspace.shared.open(release.page)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(.tint)
                Text("Readout \(release.version) is available")
                    .font(.system(size: 12, weight: .medium))
                Spacer(minLength: 0)
                Text("View Release")
                    .font(.system(size: 12))
                    .foregroundStyle(.tint)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// The answer to a check someone asked for. An available update is shown
    /// by the banner instead, so this covers everything else.
    private var updateStatus: some View {
        HStack(spacing: 8) {
            switch updates.status {
            case .checking:
                ProgressView()
                    .controlSize(.mini)
                    .frame(width: 14, height: 14)
                Text("Checking for Updates…")
            case .upToDate:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("Readout \(updates.currentVersion) is up to date")
            case .failed:
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text("Couldn’t check for updates")
            case .idle:
                EmptyView()
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 12))
        .symbolRenderingMode(.hierarchical)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button {
                NSApp.activate(ignoringOtherApps: true)
                openWindow(id: DetailsWindow.identifier)
            } label: {
                Label("Details", systemImage: "list.bullet.rectangle")
            }

            Spacer(minLength: 0)

            Menu {
                Text("Readout \(updates.currentVersion)")
                Button("Check for Updates…") {
                    Task { await updates.check(userInitiated: true) }
                }
                .disabled(updates.isBusy)
                Toggle("Check for Updates Automatically", isOn: $updates.checksAutomatically)
                Divider()
                Toggle("Open at Login", isOn: Binding(
                    get: { model.launchesAtLogin },
                    set: { launchAtLoginError = model.setLaunchAtLogin($0) }
                ))
                if let launchAtLoginError {
                    Text("Could not change it: \(launchAtLoginError)")
                }
                Divider()
                Button("Quit Readout") { NSApplication.shared.terminate(nil) }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .buttonStyle(.borderless)
        .font(.system(size: 12))
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }
}
