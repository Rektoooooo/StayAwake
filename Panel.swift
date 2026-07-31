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

/// The native switch. It handles its own clicks, animates, and renders
/// correctly — PROVIDED the panel window is key, which activatePanel()
/// guarantees. A custom-drawn replacement was tried to work around the
/// dimmed-when-not-key rendering and caused nothing but trouble: dead first
/// clicks as a Button, dead gestures after an auth dialog, stale visuals.
/// The lesson stays here so nobody repeats it.
struct PanelToggle: View {
    @Binding var isOn: Bool

    var body: some View {
        Toggle("", isOn: $isOn)
            .toggleStyle(.switch)
            .labelsHidden()
            .controlSize(.small)
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
            // Truncate a long caption rather than letting it push this row's
            // toggle out of the shared column ("2 sessions + 2 agents working"
            // did exactly that).
            .lineLimit(1)
            .truncationMode(.tail)

            Spacer(minLength: 8)

            PanelToggle(isOn: $isOn)
        }
        .padding(.horizontal, 16)
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

    /// Captured when the panel opens. Setup.isComplete spawns a subprocess,
    /// which must never happen inside a render pass.
    @State private var setupComplete = true
    @AppStorage("showUsageLimits") private var showUsageLimits = true

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
            autoResumeRow
            separator
            batteryGuardRow
            separator
            if let notice = power.limitNotice {
                limitRow(notice)
                separator
            }
            statusRow
            separator
            if let usage = power.usage, showUsageLimits {
                usageSection(usage)
                separator
            }
            recent
            separator
            MenuRow {
                SettingsWindow.shared.show(tab: setupComplete ? .general : .setup)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: setupComplete
                          ? "gearshape" : "exclamationmark.circle.fill")
                        .foregroundStyle(setupComplete ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.orange))
                        .frame(width: 14)
                    Text(setupComplete ? "Settings…" : "Finish setup")
                        .font(.system(size: 12))
                    Spacer(minLength: 0)
                }
            }
            .padding(.horizontal, 8)
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
            .padding(.horizontal, 8)
        }
        .padding(.vertical, 6)
        .frame(width: 300)
        .onAppear {
            power.refresh()
            power.recheckPasswordless()
            DispatchQueue.global().async {
                let complete = Setup.isComplete
                DispatchQueue.main.async { setupComplete = complete }
            }
        }
        // The ticker only advances the clock for captions. State probes that
        // talk to other processes (login item XPC, sudo) happen on open, not
        // every second.
        .onReceive(ticker) { tick = $0 }
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
            .truncationMode(.tail)

            Spacer(minLength: 8)

            PanelToggle(isOn: isOn)
        }
        .padding(.horizontal, 16)
        .padding(.top, 4)
        .padding(.bottom, 10)
    }

    private var separator: some View {
        Divider().padding(.horizontal, 16)
    }

    /// The 5h and 7d windows as Claude Code reports them, tapped from the
    /// statusline stream. Colours match the claude-hud bars people already
    /// read these numbers from: green for the session window, purple weekly.
    private static let fiveHourColor = Color(red: 0.42, green: 0.85, blue: 0.30)
    private static let sevenDayColor = Color(red: 0.64, green: 0.13, blue: 0.94)

    private func usageSection(_ usage: UsageLimits) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("USAGE LIMITS")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.tertiary)
            if let percent = usage.fiveHour {
                usageBar(title: "Session", window: "5h", percent: percent,
                         resetsAt: usage.fiveHourResetsAt, color: Self.fiveHourColor)
            }
            if let percent = usage.sevenDay {
                usageBar(title: "Weekly", window: "7d", percent: percent,
                         resetsAt: usage.sevenDayResetsAt, color: Self.sevenDayColor)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
    }

    private func usageBar(title: String, window: String, percent: Int,
                          resetsAt: Date?, color: Color) -> some View {
        // A green bar at 100% says "fine" right under a row saying the limit
        // hit. Escalate instead: identity colour, then orange, then red.
        let barColor = percent >= 100 ? Color.red : (percent >= 90 ? .orange : color)
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                Text(window)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 8)
                if let resetsAt, let countdown = resetsIn(resetsAt) {
                    Text(countdown)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                Text("\(percent)%")
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundStyle(barColor)
            }
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.12))
                    Capsule()
                        .fill(barColor)
                        .frame(width: max(6, geometry.size.width * CGFloat(percent) / 100))
                }
            }
            .frame(height: 5)
        }
    }

    /// "resets in 4h 21m" style, live because it derives from the panel clock.
    private func resetsIn(_ date: Date) -> String? {
        let seconds = Int(date.timeIntervalSince(tick))
        guard seconds > 0 else { return nil }
        let days = seconds / 86400
        let hours = (seconds % 86400) / 3600
        let minutes = (seconds % 3600) / 60
        if days > 0 { return "resets in \(days)d \(hours)h" }
        if hours > 0 { return "resets in \(hours)h \(minutes)m" }
        return "resets in \(minutes)m"
    }

    /// Shown while a Claude usage limit is in force. Claims were swept when it
    /// hit, so without this row the panel would just say "Idle" and leave the
    /// user wondering why nothing is working.
    private func limitRow(_ notice: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "hourglass")
                .font(.system(size: 11))
                .foregroundStyle(.orange)
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 1) {
                Text("Claude usage limit hit")
                    .font(.system(size: 12))
                Text(notice)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .lineLimit(1)
            .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
    }

    private var autoRow: some View {
        SettingRow(
            symbol: "terminal.fill",
            tint: power.autoMode && power.claims.total > 0 && !power.autoSnoozed ? .green : .secondary,
            title: "Follow Claude Code",
            caption: autoCaption,
            captionTint: power.autoMode && !power.passwordless ? .orange : .secondary,
            isOn: Binding(get: { power.autoMode }, set: { power.autoMode = $0 }))
    }

    private var autoResumeRow: some View {
        SettingRow(
            symbol: "clock.arrow.circlepath",
            tint: power.pendingResume != nil ? .orange : .secondary,
            title: "Resume after limit",
            caption: autoResumeCaption,
            captionTint: power.pendingResume != nil ? .orange : .secondary,
            isOn: Binding(get: { power.autoResume }, set: { power.autoResume = $0 }))
    }

    private var autoResumeCaption: String {
        guard power.autoResume else { return "Off" }
        if let pending = power.pendingResume {
            let formatter = DateFormatter()
            formatter.timeStyle = .short
            let count = pending.sessions.count
            return "\(count) session\(count == 1 ? "" : "s") at \(formatter.string(from: pending.fireAt))"
        }
        return "Wakes the Mac, continues the work"
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
        .padding(.horizontal, 16)
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
        if power.autoSnoozed && power.claims.total > 0 {
            return "Paused for current work"
        }
        if power.claims.total > 0 { return "\(power.claims.label) working" }
        if power.limitNotice != nil { return "Waiting out the usage limit" }
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
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
    }

    // Draining the battery flat with the lid shut is the one way this app
    // can bite. But a warning shown at 96% is noise that teaches you to ignore
    // it, so the orange treatment waits until charge approaches the guard:
    // below twice the release threshold (40% by default).
    private var isDraining: Bool { power.sleepDisabled && power.onBattery }
    private var drainWarning: Bool {
        isDraining && (power.batteryPercent ?? 100) <= power.batteryThreshold * 2
    }

    /// The poll loop runs every 5 seconds, so anything close to a minute old
    /// means it has stopped and every reading on screen is untrustworthy.
    private var isStalled: Bool {
        Date().timeIntervalSince(power.lastRefresh) > 60
    }

    private var statusSymbol: String {
        if isStalled { return "exclamationmark.triangle.fill" }
        if power.lastError != nil { return "exclamationmark.circle.fill" }
        if drainWarning { return "exclamationmark.triangle.fill" }
        if power.isCharging { return "battery.100.bolt" }
        return power.onBattery ? "battery.75" : "powerplug.fill"
    }

    private var statusTint: Color {
        if isStalled { return .orange }
        if power.lastError != nil { return .red }
        return drainWarning ? .orange : .secondary
    }

    private var statusText: String {
        if isStalled { return "Not updating, quit and reopen StayAwake" }
        if let error = power.lastError { return error }
        let level = power.batteryLevel.map { " \($0)" } ?? ""
        if drainWarning { return "On battery\(level), plug in or it will drain" }
        // "5h 8m left" / "45m to full", omitted while macOS is recalculating.
        // Spelled out because "5:01" reads as a clock time, not a duration.
        let clock = power.minutesRemaining.map { minutes in
            minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m"
        }
        if power.onBattery {
            return clock.map { "On battery\(level), \($0) left" } ?? "On battery\(level)"
        }
        if power.isCharging {
            return clock.map { "Charging\(level), \($0) to full" } ?? "Charging\(level)"
        }
        if power.batteryPercent == 100 { return "On AC power, charged" }
        return "On AC power\(level)"
    }
}
