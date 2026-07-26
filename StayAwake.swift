import SwiftUI
import Combine

// NSStatusItem + NSPopover instead of SwiftUI's MenuBarExtra, deliberately.
//
// MenuBarExtra produced three distinct bug classes here: it does not reliably
// re-render on ObservableObject changes (the panel went hours stale), it shows
// its window without making it key (dimmed switches, swallowed first clicks,
// gestures dying after an auth dialog), and the every-second re-render used to
// paper over the first problem re-fired NSSwitch actions, flipping toggles the
// user had just set. A popover from a status item is the boring, proven path:
// it becomes key, hosts SwiftUI normally, and observation just works.
@main
struct StayAwakeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        // No scene windows; the status item owns all UI.
        Settings { EmptyView() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var power: PowerController!
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var iconSink: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        power = PowerController()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = StatusIcon.image(on: power.sleepDisabled)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePanel)

        popover.contentViewController = NSHostingController(rootView: PanelView(power: power))
        popover.behavior = .transient   // closes on any outside click

        iconSink = power.$sleepDisabled
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] on in
                self?.statusItem.button?.image = StatusIcon.image(on: on)
            }

        // First run, or a run where setup is still incomplete: offer to finish
        // it rather than silently doing nothing useful.
        if !Setup.isComplete {
            SetupWindow.shared.show()
        }
    }

    /// Without MenuBarExtra's scene keeping the app alive, closing the last
    /// window (the Setup window, say) must not take the whole app with it.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        NSLog("StayAwake terminating")
    }

    @objc private func togglePanel() {
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        guard let button = statusItem.button else { return }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        // Key focus is what MenuBarExtra never gave this panel, and its absence
        // was the root of every interaction bug. NSPopover grants it willingly.
        popover.contentViewController?.view.window?.makeKey()
        NSApp.activate(ignoringOtherApps: true)
    }
}
