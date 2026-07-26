import SwiftUI

@main
struct StayAwakeApp: App {
    @StateObject private var power = PowerController()

    init() {
        // First run, or a run where setup is still incomplete: offer to finish
        // it rather than silently doing nothing useful.
        if !Setup.isComplete {
            DispatchQueue.main.async { SetupWindow.shared.show() }
        }
    }

    var body: some Scene {
        MenuBarExtra {
            PanelView(power: power)
        } label: {
            Image(nsImage: StatusIcon.image(on: power.sleepDisabled))
        }
        // .window gives a real panel with material chrome; .menu would flatten
        // everything back into plain menu items.
        .menuBarExtraStyle(.window)
    }
}
