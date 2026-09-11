import SwiftUI

@main
struct ReadoutApp: App {
    @State private var model = ReadoutModel()
    @State private var updates = UpdateChecker()

    init() {
        Benchmark.runIfRequested()
        // AppKit reads the scroll view's class flag at creation time, so this
        // has to land before the first scene builds any views.
        _ = ResponsiveScrolling.enable
    }

    var body: some Scene {
        MenuBarExtra {
            PanelView(model: model, updates: updates)
        } label: {
            // Just the mark. Readings belong in the panel, not crowded into
            // the menu bar beside the system's own items.
            Image(systemName: "gauge.with.dots.needle.bottom.50percent")
        }
        .menuBarExtraStyle(.window)

        Window("Readout", id: DetailsWindow.identifier) {
            DetailsView(model: model)
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 520, height: 720)
    }
}

