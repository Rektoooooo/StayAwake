import AppKit
import IOKit.ps
import IOKit.pwr_mgt

// A menu bar toggle for `pmset disablesleep`, the only flag that actually
// keeps a Mac running with the lid shut. caffeinate can't do this: it holds
// off idle sleep, but clamshell sleep overrides power assertions.

enum Shell {
    @discardableResult
    static func run(_ path: String, _ args: [String]) -> (out: String, status: Int32) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: path)
        task.arguments = args
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        do { try task.run() } catch { return ("", -1) }
        // Drain before waiting, or a chatty child deadlocks on a full pipe.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        return (String(data: data, encoding: .utf8) ?? "", task.terminationStatus)
    }
}

@MainActor
final class PowerController: ObservableObject {
    @Published private(set) var sleepDisabled = false
    @Published private(set) var onBattery = false
    @Published private(set) var batteryLevel: String?
    @Published private(set) var batteryPercent: Int?
    @Published private(set) var lastError: String?
    /// Main sessions and background subagents, counted separately so the
    /// caption can say "1 session + 6 agents" instead of "7 sessions".
    @Published private(set) var claims = ClaimCounts()
    @Published private(set) var activity: [ActivityEntry] = ActivityLog.load()
    /// When the last working claim disappeared. The panel derives the live
    /// countdown from this; refresh() releases once it exceeds the grace.
    @Published private(set) var idleSince: Date?
    /// When the poll loop last completed. Surfaced in the panel so a stalled
    /// loop shows as a warning rather than quietly serving stale readings,
    /// which is how a frozen battery percentage once drained the machine.
    @Published private(set) var lastRefresh = Date()

    /// Safety net: below the threshold on battery, hand sleep back even if
    /// Claude is working. Running the machine flat in a bag helps nobody.
    @Published var batteryGuard: Bool = UserDefaults.standard.object(forKey: batteryGuardKey) as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(batteryGuard, forKey: Self.batteryGuardKey)
            refresh()
        }
    }

    var batteryThreshold: Int {
        UserDefaults.standard.object(forKey: "batteryThreshold") as? Int ?? 20
    }
    /// True when the sudoers rule is installed. Without it every automatic
    /// transition would pop an authentication dialog, so auto mode needs it.
    @Published private(set) var passwordless = false

    @Published var autoMode: Bool = UserDefaults.standard.bool(forKey: autoModeKey) {
        didSet {
            UserDefaults.standard.set(autoMode, forKey: Self.autoModeKey)
            evaluateAuto()
        }
    }

    /// Seconds of quiet before auto mode hands sleep back. Override with
    /// `defaults write cz.sebastiankucera.stayawake graceSeconds 120`.
    static var grace: TimeInterval {
        UserDefaults.standard.object(forKey: "graceSeconds") as? Double ?? 300
    }

    private static let autoModeKey = "autoMode"
    private static let batteryGuardKey = "batteryGuard"
    private var ticker: DispatchSourceTimer?
    private var claimWatcher: DispatchSourceFileSystemObject?
    private var powerSourceWatcher: CFRunLoopSource?
    private var appNapToken: NSObjectProtocol?

    #if PREVIEW
    /// Stops the offscreen renderer's onAppear from overwriting stub state.
    var frozen = false
    #endif

    init() {
        #if !PREVIEW
        // Launching at login is the whole point of an always-available status
        // item, so opt in once on first run rather than waiting to be asked.
        // Excluded from preview builds, which would otherwise register the
        // render tool itself as a login item.
        if !UserDefaults.standard.bool(forKey: "didRegisterLogin") {
            UserDefaults.standard.set(true, forKey: "didRegisterLogin")
            LoginItem.set(true)
        }
        #endif
        // A menu bar app with no visible window is prime App Nap material, and
        // the first thing App Nap suspends is timers. That once froze the
        // battery reading for two and a half hours: the guard never got to
        // evaluate, the idle countdown never expired, and sleep stayed held
        // until the battery was flat.
        //
        // ...AllowingIdleSystemSleep matters. Plain .userInitiated would hold
        // sleep off by itself, which is the opposite of the job.
        appNapToken = ProcessInfo.processInfo.beginActivity(
            options: .userInitiatedAllowingIdleSystemSleep,
            reason: "Tracking Claude Code sessions and battery level")

        passwordless = Self.checkPasswordless()
        refresh()
        startTicker()
        watchClaims()
        watchWake()
        watchPowerSource()
    }

    /// A dispatch timer rather than a run loop Timer: it keeps firing whatever
    /// mode the run loop is in, including while the panel is open. Two seconds
    /// is affordable because state reads are now in-process IOKit calls, not
    /// spawned pmset processes.
    private func startTicker() {
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + 2, repeating: 2, leeway: .milliseconds(500))
        timer.setEventHandler { [weak self] in
            Task { @MainActor in self?.refresh() }
        }
        timer.resume()
        ticker = timer
    }

    /// Plug/unplug and battery-percentage changes push a refresh immediately,
    /// so the battery guard reacts to an unplug in milliseconds instead of at
    /// the next poll.
    private func watchPowerSource() {
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let controller = Unmanaged<PowerController>.fromOpaque(context).takeUnretainedValue()
            Task { @MainActor in controller.refresh() }
        }, context)?.takeRetainedValue() else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        powerSourceWatcher = source
    }

    /// Waking can mean hours have passed and the battery is somewhere else
    /// entirely, so re-read at once rather than waiting for the next tick.
    private func watchWake() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    /// Reacts to a hook writing a claim within milliseconds; the timer above is
    /// only a backstop.
    private func watchClaims() {
        try? FileManager.default.createDirectory(at: ClaimStore.directory, withIntermediateDirectories: true)
        let descriptor = open(ClaimStore.directory.path, O_EVTONLY)
        guard descriptor >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: [.write], queue: .main)
        source.setEventHandler { [weak self] in
            Task { @MainActor in self?.refresh() }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        claimWatcher = source
    }

    private static func checkPasswordless() -> Bool {
        // -l asks "may I?" without running anything and without prompting.
        Shell.run("/usr/bin/sudo", ["-n", "-l", "/usr/bin/pmset", "-a", "disablesleep", "1"]).status == 0
    }

    func refresh() {
        #if PREVIEW
        if frozen { return }
        #endif
        readState()
        claims = ClaimStore.counts()
        lastRefresh = Date()
        heartbeat()
        // The guard outranks both auto mode and a manual hold: it is the one
        // rule that exists to protect the machine from the app.
        if enforceBatteryGuard() { return }
        evaluateAuto()
    }

    private func enforceBatteryGuard() -> Bool {
        guard batteryGuard, onBattery, let percent = batteryPercent, percent <= batteryThreshold
        else { return false }
        if sleepDisabled {
            apply(false, reason: "battery \(percent)%")
            sleepNowIfShut()
        }
        return true
    }

    /// IOPMCopySystemPowerSettings is public IOKit C API (it is what pmset -g
    /// itself calls) but is missing from the Swift module map, so it is
    /// resolved by symbol at startup.
    private typealias CopySettings = @convention(c) () -> Unmanaged<CFDictionary>?
    private static let copySystemPowerSettings: CopySettings? = {
        guard let handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY),
              let symbol = dlsym(handle, "IOPMCopySystemPowerSettings")
        else { return nil }
        return unsafeBitCast(symbol, to: CopySettings.self)
    }()

    /// In-process IOKit reads, the same sources pmset itself uses. No spawned
    /// processes, so this is microseconds and safe to call often; parsing
    /// pmset's text output at 5s intervals is what these replaced.
    private func readState() {
        if let copy = Self.copySystemPowerSettings {
            let settings = copy()?.takeRetainedValue() as? [String: Any]
            sleepDisabled = settings?["SleepDisabled"] as? Bool ?? false
        } else {
            // Symbol lookup failed (unexpected): fall back to parsing pmset.
            sleepDisabled = Shell.run("/usr/bin/pmset", ["-g"]).out
                .split(separator: "\n")
                .first { $0.contains("SleepDisabled") }?
                .contains("1") ?? false
        }

        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef]
        else {
            onBattery = false
            batteryLevel = nil
            batteryPercent = nil
            return
        }

        let providing = IOPSGetProvidingPowerSourceType(snapshot)?.takeUnretainedValue() as String?
        onBattery = providing == kIOPSBatteryPowerValue

        batteryPercent = sources.compactMap { source -> Int? in
            guard let description = IOPSGetPowerSourceDescription(snapshot, source)?
                    .takeUnretainedValue() as? [String: Any],
                  let current = description[kIOPSCurrentCapacityKey] as? Int,
                  let max = description[kIOPSMaxCapacityKey] as? Int, max > 0
            else { return nil }
            return Int((Double(current) / Double(max) * 100).rounded())
        }.first
        batteryLevel = batteryPercent.map { "\($0)%" }
    }

    /// Off by default. `defaults write cz.sebastiankucera.stayawake debugHeartbeat -bool true`
    /// touches a file on every refresh, so a stalled poll loop can be seen from
    /// outside the app. Worth having: a silently stalled loop is what let the
    /// battery run down once.
    private func heartbeat() {
        guard UserDefaults.standard.bool(forKey: "debugHeartbeat") else { return }
        let url = ClaimStore.directory
            .deletingLastPathComponent()
            .appendingPathComponent("heartbeat")
        try? Data("\(Date())\n".utf8).write(to: url)
    }

    private func log(_ kind: ActivityEntry.Kind, _ detail: String) {
        activity.append(ActivityEntry(kind: kind, detail: detail))
        activity = Array(activity.suffix(ActivityLog.limit))
        ActivityLog.save(activity)
    }

    /// In auto mode the claim count owns the flag: any working session holds it
    /// on, and the last one to finish hands sleep back after a grace period.
    ///
    /// The grace matters because a turn ending is not the same as you being
    /// done. It covers the gap between turns, keeps a scheduled follow-up from
    /// landing on a sleeping Mac, and stops `pmset` churning at every turn
    /// boundary of an interactive session.
    private func evaluateAuto() {
        guard autoMode else { idleSince = nil; return }

        if claims.total > 0 {
            idleSince = nil
            if !sleepDisabled {
                apply(true, reason: "\(claims.label) working")
            }
            return
        }

        guard sleepDisabled else {
            idleSince = nil
            return
        }

        let since = idleSince ?? Date()
        idleSince = since

        if Date().timeIntervalSince(since) >= Self.grace {
            idleSince = nil
            let quiet = Self.grace >= 60 ? "\(Int(Self.grace / 60))m" : "\(Int(Self.grace))s"
            apply(false, reason: "idle \(quiet)")
            sleepNowIfShut()
        }
    }

    /// Clearing the flag is not enough to put a lid-shut Mac to sleep. Clamshell
    /// sleep fires on the lid-close *event*; re-allowing sleep afterwards never
    /// replays it. Idle sleep does not save us either, because Claude, browsers,
    /// coreaudiod and caffeinate routinely hold idle-sleep assertions. Without
    /// this the machine sits awake on battery until something else sleeps it.
    private func sleepNowIfShut() {
        #if PREVIEW
        if frozen { return }   // never sleep the machine from a render
        #endif
        guard Self.lidIsShut() else { return }
        // Lid shut with an external display is desk clamshell mode: the machine
        // is in use, so leave it alone.
        guard !Self.hasExternalDisplay() else { return }
        log(.slept, "lid shut")
        Shell.run("/usr/bin/pmset", ["sleepnow"])
    }

    static func lidIsShut() -> Bool {
        Shell.run("/usr/sbin/ioreg", ["-r", "-k", "AppleClamshellState", "-d", "4"])
            .out.contains("\"AppleClamshellState\" = Yes")
    }

    static func hasExternalDisplay() -> Bool {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return false }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return false }
        return ids.prefix(Int(count)).contains { CGDisplayIsBuiltin($0) == 0 }
    }

    func setSleepDisabled(_ enabled: Bool) {
        apply(enabled, reason: "by hand")
    }

    private func apply(_ enabled: Bool, reason: String) {
        #if PREVIEW
        // The offscreen renderer must never touch the real machine. Assigning
        // autoMode on a stub fires evaluateAuto, which would otherwise run
        // pmset for real and write to the activity log.
        if frozen { sleepDisabled = enabled; return }
        #endif
        let value = enabled ? "1" : "0"

        // Fast path: the narrowly scoped NOPASSWD rule installed by Setup.
        // Without it this fails silently and we fall back to a GUI auth prompt.
        var result = Shell.run("/usr/bin/sudo", ["-n", "/usr/bin/pmset", "-a", "disablesleep", value])

        if result.status != 0 {
            let script = "do shell script \"/usr/bin/pmset -a disablesleep \(value)\" with administrator privileges"
            result = Shell.run("/usr/bin/osascript", ["-e", script])
        }

        lastError = result.status == 0 ? nil : "Couldn't change the setting"
        if result.status == 0 {
            log(enabled ? .held : .released, reason)
        }
        // Read back only: re-running the full refresh here would recurse
        // through evaluateAuto.
        readState()
    }

    /// Leaving the flag set after quitting is the footgun this app exists to avoid.
    func restoreSleepAndQuit() {
        if sleepDisabled { setSleepDisabled(false) }
        NSApplication.shared.terminate(nil)
    }
}

#if PREVIEW
// Compiled only into the offscreen render tool (-DPREVIEW), never the app.
// Lives in this file because private(set) setters are file-scoped.
extension PowerController {
    static func stub(
        sleepDisabled: Bool,
        onBattery: Bool,
        batteryLevel: String?,
        autoMode: Bool = false,
        activeSessions: Int = 0,
        activeAgents: Int = 0,
        passwordless: Bool = true
    ) -> PowerController {
        let controller = PowerController()
        controller.sleepDisabled = sleepDisabled
        controller.onBattery = onBattery
        controller.batteryLevel = batteryLevel
        controller.batteryPercent = batteryLevel.flatMap { Int($0.dropLast()) }
        controller.claims = ClaimCounts(sessions: activeSessions, agents: activeAgents)
        controller.passwordless = passwordless
        controller.frozen = true
        controller.autoMode = autoMode
        return controller
    }
}
#endif
