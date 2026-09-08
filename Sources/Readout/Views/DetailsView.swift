import SwiftUI

enum DetailsWindow {
    static let identifier = "details"
}

/// The full readout: everything the quick panel deliberately leaves out.
struct DetailsView: View {
    @Bindable var model: ReadoutModel

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                OverviewCard(
                    host: model.host,
                    // Passing whole seconds would invalidate this card every
                    // tick to redraw a figure that only changes each minute.
                    uptimeMinutes: Int(model.sample.uptime) / 60,
                    processCount: model.sample.processCount
                )
                ProcessorCard(
                    cpu: model.sample.cpu,
                    history: model.cpuHistory,
                    performanceCores: model.host.performanceCores,
                    detailed: true
                )
                AppListCard(
                    processes: model.processes,
                    sort: $model.processSort,
                    limit: 12
                )
                MemoryCard(memory: model.sample.memory, detailed: true)
                if let gpu = model.sample.gpu {
                    GraphicsCard(gpu: gpu)
                }
                if model.sample.thermals.hasAnything {
                    ThermalCard(thermals: model.sample.thermals, detailed: true)
                }
                if let battery = model.sample.battery {
                    BatteryCard(battery: battery, detailed: true)
                }
                StorageCard(volumes: model.sample.volumes, detailed: true)
                NetworkCard(
                    network: model.sample.network,
                    history: model.networkHistory,
                    detailed: true
                )
                Text("Readout can only see processes owned by you; inspecting other users' processes needs privileges it does not ask for.")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(16)
        }
        .frame(minWidth: 420, idealWidth: 460, minHeight: 480, idealHeight: 720)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { model.isDetailOpen = true }
        .onDisappear { model.isDetailOpen = false }
    }
}
