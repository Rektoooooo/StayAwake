import SwiftUI

// First-run onboarding. A real window rather than the menu bar panel, because
// the privileged step opens a system auth dialog and needs somewhere to
// explain itself first.
struct SetupView: View {
    @State private var done: [Setup.Step: Bool] = [:]
    @State private var errors: [Setup.Step: String] = [:]
    @State private var busy: Setup.Step?

    var onFinish: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()

            VStack(spacing: 0) {
                ForEach(Array(Setup.Step.allCases.enumerated()), id: \.element.id) { index, step in
                    if index > 0 { Divider().padding(.leading, 52) }
                    row(step)
                }
            }

            Divider()
            footer
        }
        .frame(width: 460)
        .onAppear(perform: refresh)
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(nsImage: StatusIcon.image(on: true))
                .interpolation(.none)
                .frame(width: 40, height: 36)

            VStack(alignment: .leading, spacing: 3) {
                Text("Set up StayAwake")
                    .font(.system(size: 16, weight: .semibold))
                Text("Three one-time steps. You can change any of them later.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
    }

    private func row(_ step: Setup.Step) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: done[step] == true ? "checkmark.circle.fill" : step.symbol)
                .font(.system(size: 15))
                .foregroundStyle(done[step] == true ? Color.green : .secondary)
                .frame(width: 20)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 3) {
                Text(step.title).font(.system(size: 13, weight: .medium))
                Text(step.detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let error = errors[step] {
                    Text(error)
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if step == .claudeHooks && !Setup.claudeInstalled {
                    Text("Claude Code is not installed, so this step can be skipped.")
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                }
            }

            Spacer(minLength: 12)

            Group {
                if busy == step {
                    ProgressView().controlSize(.small)
                } else if done[step] == true {
                    Text("Done").font(.system(size: 11)).foregroundStyle(.secondary)
                } else {
                    Button("Set up") { perform(step) }
                        .disabled(step == .claudeHooks && !Setup.claudeInstalled)
                }
            }
            .frame(width: 64, alignment: .trailing)
            .padding(.top, 1)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    /// From the cached dict only. Setup.isComplete probes disk and spawns a
    /// sudo subprocess; doing that inside a render pass caused AttributeGraph
    /// cycles and a progress spinner that never cleared.
    private var allDone: Bool {
        Setup.Step.allCases.allSatisfy { done[$0] == true }
    }

    private var footer: some View {
        HStack {
            if allDone {
                Label("All set", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.green)
            } else {
                Text("StayAwake works without these, but auto mode needs the first two.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(allDone ? "Done" : "Later") { onFinish() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private func refresh() {
        // isDone probes disk and spawns sudo; keep it off the main thread and
        // out of the render pass.
        DispatchQueue.global().async {
            let states = Dictionary(uniqueKeysWithValues:
                Setup.Step.allCases.map { ($0, Setup.isDone($0)) })
            DispatchQueue.main.async { done = states }
        }
    }

    private func perform(_ step: Setup.Step) {
        busy = step
        errors[step] = nil
        NSLog("Setup step %@ starting", step.rawValue)
        // Off the main thread: the privileged step blocks on a system dialog.
        DispatchQueue.global().async {
            let failure = Setup.perform(step)
            DispatchQueue.main.async {
                NSLog("Setup step %@ finished: %@", step.rawValue, failure ?? "ok")
                errors[step] = failure
                busy = nil
                refresh()
                // The panel caches the passwordless answer; tell it the world
                // changed so "Needs passwordless setup" clears immediately.
                NotificationCenter.default.post(name: .stayAwakeSetupDidChange, object: nil)
                // The auth dialog deactivates this app, which drops the setup
                // window behind whatever is frontmost. It never closed; it was
                // buried, which reads exactly like "the setup closed on me".
                // Re-front it so the user sees the step complete.
                SetupWindow.shared.show()
            }
        }
    }
}

/// Plain AppKit window: an LSUIElement app has no normal window plumbing, and
/// this needs to open on demand from the menu bar and on first run.
@MainActor
final class SetupWindow: NSObject, NSWindowDelegate {
    static let shared = SetupWindow()
    private var window: NSWindow?

    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 400),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false)
        window.title = "StayAwake"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = NSHostingView(rootView: SetupView(onFinish: { [weak self] in
            self?.window?.close()
        }))
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window
    }

    func windowWillClose(_ notification: Notification) {
        NSLog("Setup window closing; call stack: %@", Thread.callStackSymbols.prefix(8).joined(separator: " | "))
        window = nil
    }
}
