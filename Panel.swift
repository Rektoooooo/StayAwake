import SwiftUI

/// The same mascot as the menu bar, so the panel echoes what you just clicked.
struct StatusLight: View {
    let on: Bool

    var body: some View {
        Image(nsImage: StatusIcon.image(on: on))
            .interpolation(.high)
            .frame(width: 18, height: 18)
    }
}

/// A labelled switch row, used for every setting in the panel.
struct SettingRow: View {
    let symbol: String
    let tint: Color
    let title: String
    let caption: String
    let captionTint: Color
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 11))
                .foregroundStyle(tint)
                .frame(width: 14)

            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 12))
                Text(caption).font(.system(size: 11)).foregroundStyle(captionTint)
            }
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)

            Spacer(minLength: 8)

            Toggle("", isOn: $isOn)
                .toggleStyle(.switch)
                .labelsHidden()
                .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }
}

/// A menu-style row: transparent until hovered, then accent-filled the way
/// AppKit menu items highlight.
struct MenuRow<Label: View>: View {
    let action: () -> Void
    @ViewBuilder var label: Label

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            label
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(hovering ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(hovering ? Color.accentColor : .clear)
        )
        .onHover { hovering = $0 }
    }
}

struct PanelView: View {
    @ObservedObject var power: PowerController

    @State private var loginEnabled = LoginItem.isEnabled
    @State private var loginError: String?

    /// Re-evaluates the body while the panel is on screen.
    ///
    /// MenuBarExtra builds its window content once and does not reliably
    /// re-render it when the observed object changes, so the panel would sit
    /// showing whatever was true when it was first built: an activity list
    /// hours out of date, a stale battery reading, a countdown frozen at
    /// whatever it said at launch. `.common` mode so it keeps firing while the
    /// panel is being tracked.
    @State private var tick = Date()
    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var isOn: Binding<Bool> {
        Binding(get: { power.sleepDisabled }, set: { power.setSleepDisabled($0) })
    }

    var body: some View {
        // Reading tick here is what ties the body to the timer above.
        VStack(alignment: .leading, spacing: 0) {
            let _ = tick
            header
            separator
            autoRow
            separator
            batteryGuardRow
            separator
            statusRow
            separator
            recent
            separator
            loginRow
            separator
            MenuRow {
                SetupWindow.shared.show()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: Setup.isComplete
                          ? "checkmark.circle" : "exclamationmark.circle.fill")
                        .foregroundStyle(Setup.isComplete ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.orange))
                        .frame(width: 14)
                    Text(Setup.isComplete ? "Setup" : "Finish setup")
                        .font(.system(size: 12))
                    Spacer(minLength: 0)
                }
            }
            .padding(.horizontal, 6)
            separator
            MenuRow {
                power.restoreSleepAndQuit()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "power")
                        .frame(width: 14)
                    Text("Quit and restore sleep")
                        .font(.system(size: 12))
                    Spacer(minLength: 8)
                    Text("⌘Q")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 6)
        }
        .padding(.vertical, 6)
        .frame(width: 260)
        .onAppear { power.refresh() }
        .onReceive(ticker) { now in
            tick = now
            loginEnabled = LoginItem.isEnabled
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            StatusLight(on: power.sleepDisabled)
                .padding(.leading, 2)

            VStack(alignment: .leading, spacing: 1) {
                Text("Keep awake")
                    .font(.system(size: 13, weight: .semibold))
                Text(power.sleepDisabled ? "Lid can stay closed" : "Sleeps on lid close")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)

            Spacer(minLength: 8)

            Toggle("", isOn: isOn)
                .toggleStyle(.switch)
                .labelsHidden()
                .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.top, 4)
        .padding(.bottom, 10)
    }

    private var separator: some View {
        Divider().padding(.horizontal, 12)
    }

    private var autoRow: some View {
        SettingRow(
            symbol: "terminal.fill",
            tint: power.autoMode && power.claims.total > 0 ? .green : .secondary,
            title: "Follow Claude Code",
            caption: autoCaption,
            captionTint: power.autoMode && !power.passwordless ? .orange : .secondary,
            isOn: Binding(get: { power.autoMode }, set: { power.autoMode = $0 }))
    }

    private var batteryGuardRow: some View {
        SettingRow(
            symbol: guardTripped ? "exclamationmark.triangle.fill" : "battery.25",
            tint: guardTripped ? .orange : .secondary,
            title: "Release below \(power.batteryThreshold)%",
            caption: guardCaption,
            captionTint: guardTripped ? .orange : .secondary,
            isOn: Binding(get: { power.batteryGuard }, set: { power.batteryGuard = $0 }))
    }

    private var loginRow: some View {
        SettingRow(
            symbol: "arrow.up.forward.app",
            tint: .secondary,
            title: "Launch at login",
            caption: loginError ?? (loginEnabled ? "On" : "Off, will not survive a restart"),
            captionTint: loginEnabled && loginError == nil ? .secondary : .orange,
            isOn: Binding(
                get: { loginEnabled },
                set: { loginError = LoginItem.set($0); loginEnabled = LoginItem.isEnabled }))
    }

    private var recent: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("RECENT")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.tertiary)
                .padding(.bottom, 1)

            if power.activity.isEmpty {
                Text("Nothing yet")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(power.activity.suffix(4).reversed()) { entry in
                    HStack(spacing: 8) {
                        Image(systemName: entry.kind.symbol)
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                            .frame(width: 14)
                        Text(entry.time)
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundStyle(.secondary)
                        Text("\(entry.kind.label), \(entry.detail)")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private var guardTripped: Bool {
        power.batteryGuard && power.onBattery
            && (power.batteryPercent ?? 100) <= power.batteryThreshold
    }

    private var guardCaption: String {
        guard power.batteryGuard else { return "Off, can run the battery flat" }
        return guardTripped ? "Holding off, battery low" : "Protects the battery"
    }

    private var autoCaption: String {
        guard power.autoMode else { return "Off" }
        // Without the sudoers rule each transition would prompt for a password,
        // which defeats the point of automating it.
        if !power.passwordless { return "Needs passwordless setup" }
        if power.claims.total > 0 { return "\(power.claims.label) working" }
        // Derived from idleSince and the panel's own clock, so it counts down
        // every second instead of jumping at whatever cadence refresh() runs.
        if power.sleepDisabled, let since = power.idleSince {
            let remaining = Int((PowerController.grace - tick.timeIntervalSince(since)).rounded(.up))
            if remaining > 0 {
                return remaining >= 60
                    ? "Idle, sleep in \(Int((Double(remaining) / 60).rounded(.up)))m"
                    : "Idle, sleep in \(remaining)s"
            }
        }
        return "Idle, sleep allowed"
    }

    private var statusRow: some View {
        HStack(spacing: 8) {
            Image(systemName: statusSymbol)
                .font(.system(size: 11))
                .foregroundStyle(statusTint)
                .frame(width: 14)
            Text(statusText)
                .font(.system(size: 11))
                .foregroundStyle(power.lastError == nil ? .secondary : .primary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    // Draining the battery flat with the lid shut is the one way this app
    // can bite, so that combination gets a warning rather than a status line.
    private var isDraining: Bool { power.sleepDisabled && power.onBattery }

    /// The poll loop runs every 5 seconds, so anything close to a minute old
    /// means it has stopped and every reading on screen is untrustworthy.
    private var isStalled: Bool {
        Date().timeIntervalSince(power.lastRefresh) > 60
    }

    private var statusSymbol: String {
        if isStalled { return "exclamationmark.triangle.fill" }
        if power.lastError != nil { return "exclamationmark.circle.fill" }
        if isDraining { return "exclamationmark.triangle.fill" }
        return power.onBattery ? "battery.75" : "powerplug.fill"
    }

    private var statusTint: Color {
        if isStalled { return .orange }
        if power.lastError != nil { return .red }
        return isDraining ? .orange : .secondary
    }

    private var statusText: String {
        if isStalled { return "Not updating, quit and reopen StayAwake" }
        if let error = power.lastError { return error }
        let level = power.batteryLevel.map { " \($0)" } ?? ""
        if isDraining { return "On battery\(level), plug in or it will drain" }
        return power.onBattery ? "On battery\(level)" : "On AC power"
    }
}
