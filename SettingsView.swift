import SwiftUI

// Every tunable the app has, in one window: sidebar navigation in the System
// Settings idiom. The bindings write straight to UserDefaults because the
// controller and the hook helper read those keys on every use, so changes
// apply live with no restart and no plumbing.
//
// Layout is plain views throughout (no Form, no List, no ScrollView): the
// AppKit-backed containers cannot be drawn by the offscreen render
// verification this project relies on, and have misbehaved inside
// NSHostingView before. Plain views render everywhere.
struct SettingsView: View {
    @ObservedObject var power: PowerController
    @State var tab: SettingsTab
    var onClose: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            content
        }
        .frame(width: 680, height: 790)
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach([SettingsTab.general, .resume, .setup]) { candidate in
                sidebarItem(candidate)
            }
            Spacer()
            sidebarItem(.about)
        }
        .padding(10)
        .frame(width: 160)
        .background(Color.primary.opacity(0.03))
    }

    private func sidebarItem(_ candidate: SettingsTab) -> some View {
        Button {
            tab = candidate
        } label: {
            HStack(spacing: 9) {
                IconBadge(symbol: candidate.symbol, color: candidate.badgeColor)
                Text(candidate.rawValue)
                    .font(.system(size: 13))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(tab == candidate ? Color.primary.opacity(0.12) : .clear))
    }

    // MARK: Content

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                IconBadge(symbol: tab.symbol, color: tab.badgeColor, size: 26, symbolSize: 13)
                Text(tab.rawValue)
                    .font(.system(size: 17, weight: .semibold))
                Spacer()
            }
            .padding(.horizontal, 22)
            .padding(.top, 18)
            .padding(.bottom, 12)

            Group {
                switch tab {
                case .general: GeneralTab(power: power)
                case .resume: ResumeTab(power: power)
                case .setup: SetupView(onFinish: onClose, embedded: true)
                case .about: AboutTab()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .clipped()
        }
    }
}

extension SettingsTab {
    var badgeColor: Color {
        switch self {
        case .general: return Color(red: 0.55, green: 0.57, blue: 0.60)
        case .resume: return Color(red: 0.35, green: 0.52, blue: 0.95)
        case .setup: return Color(red: 0.30, green: 0.72, blue: 0.42)
        case .about: return Color(red: 0.58, green: 0.42, blue: 0.90)
        }
    }
}

// MARK: - Building blocks

struct IconBadge: View {
    let symbol: String
    let color: Color
    var size: CGFloat = 22
    var symbolSize: CGFloat = 11

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
            .fill(color)
            .frame(width: size, height: size)
            .overlay(
                Image(systemName: symbol)
                    .font(.system(size: symbolSize, weight: .semibold))
                    .foregroundStyle(.white))
    }
}

private struct SectionHeader: View {
    let title: String
    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title)
            .font(.system(size: 13, weight: .semibold))
            .padding(.leading, 2)
    }
}

/// The grouped card: rows separated by inset dividers, System Settings style.
private struct Card<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content
        }
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.055)))
    }
}

private struct CardDivider: View {
    var body: some View {
        Divider().padding(.leading, 14)
    }
}

/// One row: title, optional caption beneath it, trailing control.
private struct CardRow<Trailing: View>: View {
    let title: String
    var caption: String?
    var captionTint: Color = .secondary
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 13))
                if let caption {
                    Text(caption)
                        .font(.system(size: 11))
                        .foregroundStyle(captionTint)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            trailing
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

private struct RowToggle: View {
    @Binding var isOn: Bool

    var body: some View {
        Toggle("", isOn: $isOn)
            .toggleStyle(.switch)
            .labelsHidden()
            .controlSize(.small)
    }
}

// MARK: - General

private struct GeneralTab: View {
    @ObservedObject var power: PowerController

    @AppStorage("graceSeconds") private var graceSeconds: Double = 300
    @AppStorage("batteryThreshold") private var batteryThreshold = 20
    @AppStorage("thermalTrigger") private var thermalTrigger = "serious"
    @AppStorage("thermalTemperature") private var thermalTemperature = 95
    @AppStorage("showUsageLimits") private var showUsageLimits = true
    @AppStorage("debugHeartbeat") private var debugHeartbeat = false

    @State private var loginEnabled = false
    @State private var loginError: String?

    private var thermalTriggerCaption: String {
        switch thermalTrigger {
        case "critical":
            return "Critical pressure: the machine must cool down now. Serious pressure is tolerated."
        case "temperature":
            return "A fixed reading of the hottest CPU sensor: stricter than the pressure levels macOS throttles on, and chip-specific."
        default:
            return "Serious pressure as macOS reports it: fans flat out, performance cut. Applies even while Claude works."
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader("System")
            Card {
                CardRow(title: "Launch at login",
                        caption: loginError ?? (loginEnabled ? nil :
                            "Without this the app stops after a restart and auto mode silently stops working."),
                        captionTint: .orange) {
                    RowToggle(isOn: Binding(
                        get: { loginEnabled },
                        set: { loginError = LoginItem.set($0); loginEnabled = LoginItem.isEnabled }))
                }
            }

            SectionHeader("Sleep")
            Card {
                CardRow(title: "Hand sleep back after",
                        caption: "Quiet time after Claude finishes before sleep is allowed again.") {
                    Picker("", selection: $graceSeconds) {
                        Text("1 minute").tag(60.0)
                        Text("2 minutes").tag(120.0)
                        Text("5 minutes").tag(300.0)
                        Text("10 minutes").tag(600.0)
                        Text("15 minutes").tag(900.0)
                    }
                    .labelsHidden()
                    .frame(width: 118)
                }
            }

            SectionHeader("Guards")
            Card {
                CardRow(title: "Battery guard") {
                    RowToggle(isOn: Binding(
                        get: { power.batteryGuard },
                        set: { power.batteryGuard = $0 }))
                }
                if power.batteryGuard {
                    CardDivider()
                    CardRow(title: "Release below",
                            caption: "On battery below \(batteryThreshold)%, sleep is handed back even while Claude works. The drain warning shows from \(batteryThreshold * 2)%.") {
                        HStack(spacing: 8) {
                            Slider(value: Binding(
                                get: { Double(batteryThreshold) },
                                set: { batteryThreshold = Int($0) }
                            ), in: 5...50, step: 5)
                            .frame(width: 150)
                            Text("\(batteryThreshold)%")
                                .font(.system(size: 12).monospacedDigit())
                                .frame(width: 32, alignment: .trailing)
                        }
                    }
                }
                CardDivider()
                CardRow(title: "Thermal guard") {
                    RowToggle(isOn: Binding(
                        get: { power.thermalGuard },
                        set: { power.thermalGuard = $0 }))
                }
                if power.thermalGuard {
                    CardDivider()
                    CardRow(title: "Release at", caption: thermalTriggerCaption) {
                        Picker("", selection: $thermalTrigger) {
                            Text("Serious").tag("serious")
                            Text("Critical").tag("critical")
                            Text("Temperature").tag("temperature")
                        }
                        .labelsHidden()
                        .frame(width: 128)
                    }
                    if thermalTrigger == "temperature" {
                        CardDivider()
                        CardRow(title: "Release above",
                                caption: power.cpuTemperature.map {
                                    "Hottest CPU sensor, now \($0)°. Holds again once it has cooled \(PowerController.temperatureHysteresis)° below the limit."
                                } ?? "No CPU sensor is readable on this Mac, so the serious pressure level applies instead.",
                                captionTint: power.cpuTemperature == nil ? .orange : .secondary) {
                            HStack(spacing: 8) {
                                Slider(value: Binding(
                                    get: { Double(thermalTemperature) },
                                    set: { thermalTemperature = Int($0) }
                                ), in: 70...105, step: 5)
                                .frame(width: 150)
                                Text("\(thermalTemperature)°")
                                    .font(.system(size: 12).monospacedDigit())
                                    .frame(width: 32, alignment: .trailing)
                            }
                        }
                    }
                }
            }

            SectionHeader("Panel")
            Card {
                CardRow(title: "Show usage limits") {
                    RowToggle(isOn: $showUsageLimits)
                }
                CardDivider()
                CardRow(title: "Debug heartbeat file",
                        caption: "Touches a file on every poll so a stalled loop is observable from outside the app.") {
                    RowToggle(isOn: $debugHeartbeat)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 22)
        .padding(.bottom, 16)
        .onAppear {
            // XPC call; never during a render pass.
            DispatchQueue.main.async { loginEnabled = LoginItem.isEnabled }
        }
    }
}

// MARK: - Auto-resume

private struct ResumeTab: View {
    @ObservedObject var power: PowerController

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Card {
                CardRow(title: "Resume after limit",
                        caption: "When a usage limit stops work, wake the Mac before the reset so Claude Code's own continuation lands on an awake machine.") {
                    RowToggle(isOn: Binding(
                        get: { power.autoResume },
                        set: { power.autoResume = $0 }))
                }
            }

            if power.autoResume {
                SectionHeader("How it works")
                Card {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Claude Code continues an interrupted session by itself when the limit resets (its “Continue automatically at usage limit” setting, on by default), but only if it is awake to see the reset. A Mac that sleeps through it wakes to a “press enter to continue” prompt instead.")
                        Text("StayAwake schedules a hardware wake \(Int(PowerController.wakeLead / 60)) minutes before the reset and holds sleep off for \(Int(PowerController.resumeHold / 60)) minutes so the continuation can get going. From there Follow Claude Code takes over: the continued work holds the Mac awake until it finishes, then the usual grace hands sleep back.")
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(12)
                }

                if !power.autoMode || !power.claudeAutoContinue {
                    SectionHeader("Needs attention")
                    Card {
                        if !power.autoMode {
                            CardRow(title: "Follow Claude Code is off",
                                    caption: "The wake relies on auto mode to hold sleep for the continuation and hand it back afterwards. Turn it on in the panel.",
                                    captionTint: .orange) { EmptyView() }
                        }
                        if !power.autoMode && !power.claudeAutoContinue {
                            CardDivider()
                        }
                        if !power.claudeAutoContinue {
                            CardRow(title: "Claude Code's automatic continue is off",
                                    caption: "Turn on “Continue automatically at usage limit” in Claude Code's /config, or the wake has nothing to serve.",
                                    captionTint: .orange) { EmptyView() }
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 22)
        .padding(.bottom, 16)
        .onAppear {
            // Reads a file off the main thread; never inside a render pass.
            power.recheckSetup()
        }
    }
}

// MARK: - About

private struct AboutTab: View {
    private var version: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
        return "Version \(short) (\(build))"
    }

    var body: some View {
        VStack(spacing: 8) {
            Spacer(minLength: 30)
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 84, height: 84)

            Text("StayAwake")
                .font(.system(size: 20, weight: .semibold))
            Text(version)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            Text("Keeps your Mac awake with the lid closed —\nonly while Claude Code is actually working.")
                .font(.system(size: 12))
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.top, 2)

            HStack(spacing: 14) {
                Link("GitHub", destination: URL(string: "https://github.com/Rektoooooo/StayAwake")!)
                Link("Releases", destination: URL(string: "https://github.com/Rektoooooo/StayAwake/releases")!)
                Link("Report an issue", destination: URL(string: "https://github.com/Rektoooooo/StayAwake/issues")!)
            }
            .font(.system(size: 12))
            .padding(.top, 8)

            Spacer()
            Text("MIT licensed · © 2026 Sebastián Kučera")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .padding(.bottom, 14)
        }
        .frame(maxWidth: .infinity)
    }
}
