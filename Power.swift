import AppKit
import IOKit.ps
import IOKit.pwr_mgt

// A menu bar toggle for `pmset disablesleep`, the only flag that actually
// keeps a Mac running with the lid shut. caffeinate can't do this: it holds
// off idle sleep, but clamshell sleep overrides power assertions.

extension Notification.Name {
    /// Posted by the setup window after any step completes.
    static let stayAwakeSetupDidChange = Notification.Name("StayAwakeSetupDidChange")
}

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
    @Published private(set) var isCharging = false
    /// Minutes to empty when on battery, minutes to full when charging.
    /// nil while macOS is still calculating, which it does for a minute or so
    /// after every plug/unplug; a sentinel shown as a number would be a lie.
    @Published private(set) var minutesRemaining: Int?
    @Published private(set) var lastError: String?
    /// Main sessions and background subagents, counted separately so the
    /// caption can say "1 session + 6 agents" instead of "7 sessions".
    @Published private(set) var claims = ClaimCounts()
    @Published private(set) var activity: [ActivityEntry] = ActivityLog.load()
    /// When the last working claim disappeared. The panel derives the live
    /// countdown from this; refresh() releases once it exceeds the grace.
    @Published private(set) var idleSince: Date?
    /// "resets 3am (Europe/Prague)" while a Claude usage limit is in force.
    /// Written by the hook helper when a turn dies on the limit; cleared the
    /// moment fresh work proves the limit lifted.
    @Published private(set) var limitNotice: String?
    /// 5h/7d usage percentages tapped from the statusline stream, nil when no
    /// statusline feed exists (no wrap installed, or no session rendered yet).
    @Published private(set) var usage: UsageLimits?
    /// A scheduled wake for a usage-limit reset, surviving sleep and app
    /// restarts on disk.
    @Published private(set) var pendingResume: PendingResume? = ResumeStore.load()
    /// Set when the reset wake fires: sleep is held until this passes so
    /// Claude Code's continuation has an awake machine to start on.
    @Published private(set) var resumeHoldUntil: Date?
    /// Claude Code's own "Continue automatically at usage limit" setting (on
    /// when absent). The wake serves that continuation, so the panel warns
    /// when it has been turned off.
    @Published private(set) var claudeAutoContinue = true
    /// macOS thermal pressure, the signal the thermal guard acts on.
    @Published private(set) var thermalState = ProcessInfo.processInfo.thermalState
    /// Hottest CPU sensor in °C for the panel; nil when the SMC gave nothing.
    @Published private(set) var cpuTemperature: Int?

    /// Opt-in: wake the Mac shortly before a usage limit resets, so Claude
    /// Code's own continuation of the interrupted session is not lost to a
    /// sleeping machine. Off by default: it schedules hardware wakes.
    @Published var autoResume: Bool = UserDefaults.standard.bool(forKey: autoResumeKey) {
        didSet {
            UserDefaults.standard.set(autoResume, forKey: Self.autoResumeKey)
            if !autoResume {
                cancelPendingResume(reason: "turned off")
                resumeHoldUntil = nil
            }
            refresh()
        }
    }
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

    /// Same rank as the battery guard, same reason: a lid-shut Mac with a
    /// build running has nowhere to put the heat, and sleep is the one thing
    /// that reliably stops it.
    @Published var thermalGuard: Bool = UserDefaults.standard.object(forKey: thermalGuardKey) as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(thermalGuard, forKey: Self.thermalGuardKey)
            refresh()
        }
    }

    /// What trips the thermal guard: a macOS pressure level, serious (fans
    /// flat out, performance cut) by default or critical, or a fixed reading
    /// of the hottest CPU sensor. `defaults write cz.sebastiankucera.stayawake
    /// thermalTrigger temperature` plus `thermalTemperature 90`.
    enum ThermalTrigger: String { case serious, critical, temperature }

    var thermalTrigger: ThermalTrigger {
        ThermalTrigger(rawValue: UserDefaults.standard.string(forKey: "thermalTrigger") ?? "") ?? .serious
    }

    var thermalTemperature: Int {
        UserDefaults.standard.object(forKey: "thermalTemperature") as? Int ?? 95
    }

    /// A raw reading needs its own hysteresis: the OS builds it into the
    /// pressure levels, but a CPU under sustained load hovers within a degree
    /// of any limit, and re-holding at 94° after releasing at 95° would flap.
    static let temperatureHysteresis = 5

    /// The single answer the guard and the panel both use.
    var thermalTripped: Bool {
        guard thermalGuard else { return false }
        switch thermalTrigger {
        case .serious: return pressureSerious
        case .critical: return thermalState == .critical
        case .temperature:
            // No readable sensor on this Mac: guard on pressure rather than
            // on nothing. Settings says so next to the slider.
            return cpuTemperature == nil ? pressureSerious : temperatureTripped
        }
    }

    private var pressureSerious: Bool {
        thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue
    }
    /// True when the sudoers rule is installed. Without it every automatic
    /// transition would pop an authentication dialog, so auto mode needs it.
    @Published private(set) var passwordless = false

    @Published var autoMode: Bool = UserDefaults.standard.bool(forKey: autoModeKey) {
        didSet {
            UserDefaults.standard.set(autoMode, forKey: Self.autoModeKey)
            autoSnoozed = false   // flipping the mode is a fresh decision
            // The reset wake's hold and release are auto mode's business.
            if !autoMode { cancelPendingResume(reason: "auto mode off") }
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
    private static let thermalGuardKey = "thermalGuard"
    private static let autoResumeKey = "autoResume"
    /// The SMC sensor reader, once discovery has finished off the main thread.
    private var smc: SMCTemperature?
    /// A full sensor sweep costs a few milliseconds, so the panel figure is
    /// sampled every 10s rather than on every 2s tick. The guard does not
    /// depend on it; thermal pressure is read every time.
    private var temperatureReadAt = Date.distantPast
    /// Latched by the sampler: set at the limit, cleared only once the
    /// reading has fallen the hysteresis margin below it.
    private var temperatureTripped = false
    /// The reset a wake already fired for, so the still-full usage window
    /// does not schedule it again.
    private var handledReset: Date?
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
        watchThermalState()
        recheckSetup()

        // Sensor discovery walks the whole SMC key table once (a couple of
        // thousand IOKit calls), so it runs off the main thread.
        DispatchQueue.global(qos: .utility).async {
            let smc = SMCTemperature()
            Task { @MainActor in self.smc = smc }
        }

        NotificationCenter.default.addObserver(
            forName: .stayAwakeSetupDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.recheckSetup()
                self?.refresh()
            }
        }
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

    /// Thermal pressure moves rarely and matters at once, and the OS says
    /// when, so the guard need not wait for the next tick.
    private func watchThermalState() {
        NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
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

    nonisolated private static func checkPasswordless() -> Bool {
        // Parse the NOPASSWD listing; `sudo -l <command>` reports what an
        // admin could do with a password, not what runs without one.
        Shell.run("/usr/bin/sudo", ["-n", "-l"]).out.contains("disablesleep")
    }

    /// The launch-time check goes stale the moment setup installs the sudoers
    /// rule: the panel then keeps saying "Needs passwordless setup" until the
    /// app restarts. Re-checked when the panel opens and when setup changes,
    /// together with Claude Code's own auto-continue setting, which lives in
    /// a file the user edits from /config, not from here.
    func recheckSetup() {
        DispatchQueue.global().async {
            let granted = Self.checkPasswordless()
            let continues = Setup.claudeAutoContinueEnabled()
            Task { @MainActor in
                self.passwordless = granted
                self.claudeAutoContinue = continues
            }
        }
    }

    func refresh() {
        #if PREVIEW
        if frozen { return }
        #endif
        readState()
        claims = ClaimStore.counts()
        // Keep the previous reading through a mid-write parse failure; drop it
        // only once it is genuinely old (feed gone, e.g. wrap removed).
        if let fresh = UsageStore.read() {
            usage = fresh
        } else if let current = usage, Date().timeIntervalSince(current.asOf) > 24 * 3600 {
            usage = nil
        }
        // The limit row must not outlive the limit. When every window sits
        // below 100 (including a clamped-to-0 window whose reset passed), the
        // limit no longer binds; waiting for the next acquire to clear it
        // would leave a stale "limit hit" showing between reset and the next
        // prompt.
        if limitNotice != nil, let usage,
           (usage.fiveHour ?? 0) < 100, (usage.sevenDay ?? 0) < 100 {
            ClaimStore.clearLimit()
        }
        let notice = ClaimStore.limitNotice()
        if notice != limitNotice {
            if let notice { log(.limit, notice) }
            limitNotice = notice
        }
        manageAutoResume()
        lastRefresh = Date()
        heartbeat()
        // The guards outrank both auto mode and a manual hold: they are the
        // rules that exist to protect the machine from the app.
        if enforceBatteryGuard() { return }
        if enforceThermalGuard() { return }
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

    private func enforceThermalGuard() -> Bool {
        guard thermalTripped else { return false }
        if sleepDisabled {
            let reason = thermalTrigger == .temperature && cpuTemperature != nil
                ? "CPU \(cpuTemperature!)°"
                : "\(thermalState.label) thermal pressure"
            apply(false, reason: reason)
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

        thermalState = ProcessInfo.processInfo.thermalState
        if let smc, Date().timeIntervalSince(temperatureReadAt) >= 10 {
            cpuTemperature = smc.hottestCPU().map { Int($0.rounded()) }
            temperatureReadAt = Date()
            if let reading = cpuTemperature {
                if reading >= thermalTemperature {
                    temperatureTripped = true
                } else if reading <= thermalTemperature - Self.temperatureHysteresis {
                    temperatureTripped = false
                }
            }
        }

        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef]
        else {
            onBattery = false
            batteryLevel = nil
            batteryPercent = nil
            isCharging = false
            minutesRemaining = nil
            return
        }

        let providing = IOPSGetProvidingPowerSourceType(snapshot)?.takeUnretainedValue() as String?
        onBattery = providing == kIOPSBatteryPowerValue

        let battery = sources.compactMap {
            IOPSGetPowerSourceDescription(snapshot, $0)?.takeUnretainedValue() as? [String: Any]
        }.first { $0[kIOPSTypeKey] as? String == kIOPSInternalBatteryType }

        if let current = battery?[kIOPSCurrentCapacityKey] as? Int,
           let max = battery?[kIOPSMaxCapacityKey] as? Int, max > 0 {
            batteryPercent = Int((Double(current) / Double(max) * 100).rounded())
        } else {
            batteryPercent = nil
        }
        batteryLevel = batteryPercent.map { "\($0)%" }
        isCharging = (battery?[kIOPSIsChargingKey] as? NSNumber)?.boolValue ?? false

        // Whichever direction applies. Raw values are minutes; -1, 0 and
        // absurdly large numbers all mean "still calculating", so anything
        // outside a sane day-long window is treated as unknown.
        let raw = onBattery
            ? battery?[kIOPSTimeToEmptyKey] as? Int
            : (isCharging ? battery?[kIOPSTimeToFullChargeKey] as? Int : nil)
        minutesRemaining = raw.flatMap { (1..<1440).contains($0) ? $0 : nil }
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
            // The user explicitly released while this work was running, so
            // holding again now would just fight them.
            if autoSnoozed { return }
            if !sleepDisabled {
                apply(true, reason: "\(claims.label) working")
            }
            return
        }
        autoSnoozed = false

        guard sleepDisabled else {
            idleSince = nil
            return
        }

        // The post-wake hold: no claims yet, but Claude Code's continuation
        // is about to produce them, and an idle release here would sleep the
        // Mac from under it.
        if resumeHoldActive {
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

    // MARK: - Auto-resume

    /// Claude Code continues an interrupted session by itself when the limit
    /// resets ("Continue automatically at usage limit", on by default since
    /// 2.1.234), but only if it is awake to see the reset. It queues the
    /// continuation 30–90s after the reset, and a process that wakes from a
    /// sleep of over 30 minutes to find that moment already past parks the
    /// session on "press enter to continue" instead. So the job here is
    /// timing, not resuming: wake the Mac a few minutes before the reset,
    /// hold sleep off long enough for the continuation to start and its own
    /// hooks to take over, then let the normal claim flow run.
    static let wakeLead: TimeInterval = 3 * 60
    static let resumeHold: TimeInterval = 15 * 60

    var resumeHoldActive: Bool {
        resumeHoldUntil.map { Date() < $0 } ?? false
    }

    private func manageAutoResume() {
        if let until = resumeHoldUntil, Date() >= until { resumeHoldUntil = nil }
        // The hold and the release after it are auto mode's business; without
        // it the wake would leave the flag set with nothing to clear it.
        guard autoResume, autoMode else { return }

        if let pending = pendingResume {
            // didWake or the ticker gets us here once the scheduled wake has
            // happened, or once the time simply passed with the Mac awake.
            if Date() >= pending.fireAt { fire(pending) }
            return
        }

        guard limitInForce else { return }
        // Whichever full window binds; its reset is when work becomes
        // possible. Claude Code only arms its continuation for a reset within
        // 24 hours, so a wake for a far-off weekly reset would serve nothing.
        let resets = [usage?.fiveHourResetsAt, usage?.sevenDayResetsAt]
            .compactMap { $0 }.filter { $0 > Date() }
        guard let reset = resets.min(), reset.timeIntervalSinceNow <= 24 * 3600 else { return }
        // Fired already for this reset: the usage window still reads full
        // until Claude Code re-renders after continuing.
        if let handled = handledReset, abs(reset.timeIntervalSince(handled)) < 60 { return }

        var pending = PendingResume(fireAt: reset.addingTimeInterval(-Self.wakeLead), wakeDate: "")
        if pending.fireAt <= Date() {
            // Closer than the lead: nothing to wake from, just stay up for it.
            fire(pending)
            return
        }
        let wakeDate = ResumeStore.wakeDateString(pending.fireAt)
        if Shell.run("/usr/bin/sudo", ["-n", "/usr/bin/pmset", "schedule", "wake", wakeDate]).status == 0 {
            pending.wakeDate = wakeDate
        } else {
            // Without the wake the hold still happens if the Mac is awake at
            // the time; say so rather than silently degrading.
            log(.resume, "wake schedule failed, redo Setup")
        }
        ResumeStore.save(pending)
        pendingResume = pending
        log(.resume, "wake at \(Self.clock(pending.fireAt)) for the \(Self.clock(reset)) reset")
    }

    /// A limit binds when a turn died on it (the hook's notice) or when a
    /// usage window reads full; the second covers a hit the hook never saw.
    private var limitInForce: Bool {
        limitNotice != nil || usage?.fiveHour == 100 || usage?.sevenDay == 100
    }

    private func fire(_ pending: PendingResume) {
        clearPendingResume()
        let reset = pending.fireAt.addingTimeInterval(Self.wakeLead)
        handledReset = reset
        // A scheduled wake on a shut lid can be a dark wake; simulated user
        // activity promotes it. Then hold sleep so the machine is still up
        // when Claude Code's continuation, and the claims it produces, arrive.
        Shell.run("/usr/bin/caffeinate", ["-u", "-t", "5"])
        resumeHoldUntil = Date().addingTimeInterval(Self.resumeHold)
        if !sleepDisabled { apply(true, reason: "limit resets \(Self.clock(reset))") }
        log(.resume, "holding \(Int(Self.resumeHold / 60))m for Claude Code to continue")
    }

    private static func clock(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private func cancelPendingResume(reason: String) {
        #if PREVIEW
        if frozen { return }   // never touch a real schedule from a render
        #endif
        guard let pending = pendingResume else { return }
        if !pending.wakeDate.isEmpty {
            Shell.run("/usr/bin/sudo", ["-n", "/usr/bin/pmset", "schedule", "cancel", "wake", pending.wakeDate])
        }
        clearPendingResume()
        log(.resume, "cancelled, \(reason)")
    }

    private func clearPendingResume() {
        ResumeStore.clear()
        pendingResume = nil
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

    /// Set when the user turns Keep awake off while auto mode is holding.
    /// Auto stays hands-off until the current work finishes; the next fresh
    /// turn re-engages it. Without this the toggle flips itself back within
    /// two seconds of being switched off, which reads as a bug.
    @Published private(set) var autoSnoozed = false

    func setSleepDisabled(_ enabled: Bool) {
        if enabled {
            autoSnoozed = false
        } else if autoMode && claims.total > 0 {
            autoSnoozed = true
        }
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
        autoSnoozed: Bool = false,
        passwordless: Bool = true,
        limitNotice: String? = nil,
        usage: UsageLimits? = nil,
        cpuTemperature: Int? = nil
    ) -> PowerController {
        let controller = PowerController()
        controller.frozen = true
        // autoMode first: its didSet runs evaluateAuto, which would otherwise
        // overwrite the stubbed sleepDisabled/claims below.
        controller.autoMode = autoMode
        controller.sleepDisabled = sleepDisabled
        controller.onBattery = onBattery
        controller.batteryLevel = batteryLevel
        controller.batteryPercent = batteryLevel.flatMap { Int($0.dropLast()) }
        controller.claims = ClaimCounts(sessions: activeSessions, agents: activeAgents)
        controller.autoSnoozed = autoSnoozed
        controller.passwordless = passwordless
        controller.limitNotice = limitNotice
        controller.usage = usage
        controller.cpuTemperature = cpuTemperature
        return controller
    }
}
#endif
