import AppKit
import SwiftUI

enum SettingsTab: String, CaseIterable, Identifiable {
    case general = "General"
    case resume = "Auto-resume"
    case setup = "Setup"
    case about = "About"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .resume: return "clock.arrow.circlepath"
        case .setup: return "checklist"
        case .about: return "info.circle"
        }
    }
}

/// Plain AppKit window hosting the settings tabs: an LSUIElement app has no
/// normal window plumbing, and this needs to open on demand from the menu bar
/// panel, on first run (Setup tab), and re-front itself after auth dialogs.
@MainActor
final class SettingsWindow: NSObject, NSWindowDelegate {
    static let shared = SettingsWindow()

    private var window: NSWindow?
    private var hosting: NSHostingView<SettingsView>?
    private weak var power: PowerController?

    /// Called once at launch; the settings tabs bind to live controller state.
    func configure(power: PowerController) {
        self.power = power
    }

    func show(tab: SettingsTab = .general) {
        guard let power else { return }

        let root = SettingsView(power: power, tab: tab) { [weak self] in
            self?.window?.close()
        }

        if let window, let hosting {
            hosting.rootView = root
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let hosting = NSHostingView(rootView: root)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 460),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false)
        window.title = "StayAwake Settings"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = hosting
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window
        self.hosting = hosting
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
        hosting = nil
    }
}
