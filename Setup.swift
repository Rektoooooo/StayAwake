import AppKit

// Everything a fresh install needs that the app cannot just do for itself:
// a privileged rule so toggling sleep never prompts, and the Claude Code
// hooks that drive auto mode.
//
// Both are written to be idempotent and to re-point themselves if the app
// moves, so onboarding can be re-run at any time without making a mess.
enum Setup {

    enum Step: String, CaseIterable, Identifiable {
        case sleepControl, claudeHooks, loginItem
        var id: String { rawValue }

        var title: String {
            switch self {
            case .sleepControl: return "Allow sleep control"
            case .claudeHooks: return "Connect Claude Code"
            case .loginItem: return "Launch at login"
            }
        }

        var detail: String {
            switch self {
            case .sleepControl:
                return "Changing the lid-close sleep setting needs administrator rights. This grants exactly two commands, nothing else."
            case .claudeHooks:
                return "Adds hooks so the Mac stays awake only while Claude Code is actually working. Existing hooks are left alone."
            case .loginItem:
                return "Without this the app stops running after a restart and auto mode silently stops working."
            }
        }

        var symbol: String {
            switch self {
            case .sleepControl: return "lock.shield"
            case .claudeHooks: return "terminal"
            case .loginItem: return "arrow.up.forward.app"
            }
        }
    }

    static func isDone(_ step: Step) -> Bool {
        switch step {
        case .sleepControl: return sudoersInstalled()
        case .claudeHooks: return hooksInstalled()
        case .loginItem: return LoginItem.isEnabled
        }
    }

    /// Returns nil on success, or a message to show the user.
    static func perform(_ step: Step) -> String? {
        switch step {
        case .sleepControl: return installSudoers()
        case .claudeHooks: return installHooks()
        case .loginItem: return LoginItem.set(true)
        }
    }

    static var isComplete: Bool { Step.allCases.allSatisfy(isDone) }

    // MARK: - Privileged sleep control

    static func sudoersInstalled() -> Bool {
        // Parse the actual NOPASSWD grants. `sudo -l <command>` is a trap: it
        // answers "could this user run it with a password", which for an admin
        // is yes for everything, so it reports grants that do not exist.
        let listing = Shell.run("/usr/bin/sudo", ["-n", "-l"]).out
        return listing.contains("disablesleep") && listing.contains("pmset schedule wake")
    }

    private static func installSudoers() -> String? {
        let user = NSUserName()
        // Refuse anything that would need quoting inside the shell command.
        guard !user.isEmpty,
              user.range(of: "^[A-Za-z0-9._-]+$", options: .regularExpression) != nil
        else { return "Unexpected user name, install the rule by hand" }

        // disablesleep drives the lid-close flag; schedule wake/cancel lets
        // auto-resume wake the Mac when a usage limit resets. Nothing else.
        let rule = "\(user) ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 1, /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset schedule wake *, /usr/bin/pmset schedule cancel *"
        // Staged inside /etc/sudoers.d, which only root can write, so nothing
        // can swap the file between validation and install. The leading dot
        // keeps sudo from reading the file while it is still a draft.
        let draft = "/etc/sudoers.d/.stayawake.draft"
        let final = "/etc/sudoers.d/stayawake"
        let command = [
            "/bin/echo '\(rule)' > \(draft)",
            "/usr/sbin/visudo -cf \(draft)",
            "/usr/sbin/chown root:wheel \(draft)",
            "/bin/chmod 0440 \(draft)",
            "/bin/mv \(draft) \(final)",
        ].joined(separator: " && ") + " || { /bin/rm -f \(draft); exit 1; }"

        if let failure = runPrivileged(command) { return failure }
        return sudoersInstalled() ? nil : "The rule was written but sudo still asks for a password"
    }

    private static func runPrivileged(_ command: String) -> String? {
        let escaped = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let result = Shell.run("/usr/bin/osascript", [
            "-e", "do shell script \"\(escaped)\" with administrator privileges",
        ])
        return result.status == 0 ? nil : "Cancelled, or the password was wrong"
    }

    // MARK: - Claude Code hooks

    /// The StopFailure timeout is the auto-resume feature: on a usage limit
    /// the hook waits out the reset inside the hook (up to 6h) and then
    /// un-fails the session in its own terminal. The default 600s timeout
    /// would kill the wait.
    private static let wiring: [(event: String, action: String, timeout: Int?)] = [
        ("UserPromptSubmit", "acquire", nil),   // a turn started
        ("SubagentStart", "acquire", nil),      // background agent started
        ("PostToolUse", "acquire", nil),        // still working, keeps the claim young
        ("Stop", "release", nil),               // turn finished
        ("StopFailure", "release", 23400),      // turn DIED (API error, usage limit)
        ("SubagentStop", "release", nil),       // background agent finished
        ("SessionEnd", "release", nil),         // session gone
    ]

    static var claudeDirectory: URL {
        // Overridable so the hook rewriting can be tested against a scratch
        // copy instead of someone's live configuration.
        if let override = ProcessInfo.processInfo.environment["STAYAWAKE_CLAUDE_DIR"] {
            return URL(fileURLWithPath: override)
        }
        return URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude")
    }

    static var claudeInstalled: Bool {
        FileManager.default.fileExists(atPath: claudeDirectory.path)
    }

    private static var settingsURL: URL {
        claudeDirectory.appendingPathComponent("settings.json")
    }

    /// Absolute path of the helper inside whichever copy of the app is running.
    static var helperPath: String {
        Bundle.main.bundleURL
            .appendingPathComponent("Contents/MacOS/stayawake-claim").path
    }

    private static func command(for action: String) -> String {
        // Guarded and always exit 0: a missing binary must never break a hook.
        "/bin/sh -c 'B=\"\(helperPath)\"; [ -x \"$B\" ] && \"$B\" \(action); exit 0'"
    }

    static func hooksInstalled() -> Bool {
        guard let settings = readSettings(),
              let hooks = settings["hooks"] as? [String: Any]
        else { return false }

        return wiring.allSatisfy { entry in
            guard let groups = hooks[entry.event] as? [[String: Any]] else { return false }
            return groups.contains { group in
                (group["hooks"] as? [[String: Any]] ?? []).contains {
                    ($0["command"] as? String) == command(for: entry.action)
                }
            }
        }
    }

    private static func readSettings() -> [String: Any]? {
        guard let data = try? Data(contentsOf: settingsURL) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func installHooks() -> String? {
        guard claudeInstalled else { return "Claude Code not found in ~/.claude" }

        var settings: [String: Any] = [:]
        if FileManager.default.fileExists(atPath: settingsURL.path) {
            guard let existing = readSettings() else {
                return "~/.claude/settings.json is not valid JSON, fix it first"
            }
            settings = existing
            // Never edit someone's settings without a way back.
            try? FileManager.default.removeItem(at: backupURL)
            try? FileManager.default.copyItem(at: settingsURL, to: backupURL)
        }

        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        for entry in wiring {
            var groups = hooks[entry.event] as? [[String: Any]] ?? []
            groups = strippingOurs(from: groups)
            var hook: [String: Any] = ["type": "command", "command": command(for: entry.action)]
            if let timeout = entry.timeout { hook["timeout"] = timeout }
            groups.append(["matcher": "*", "hooks": [hook]])
            hooks[entry.event] = groups
        }
        settings["hooks"] = hooks

        // Usage percentages ride the statusline stream and nowhere else, so
        // tap it: prepend a tee that copies each payload to a file on its way
        // into whatever statusline the user already runs. Only when one is
        // configured — installing a statusline they didn't have would change
        // their UI, so without one the usage section simply stays hidden.
        if var statusline = settings["statusLine"] as? [String: Any],
           statusline["type"] as? String == "command",
           let command = statusline["command"] as? String,
           !command.contains("StayAwake/statusline.json") {
            statusline["command"] = UsageStore.teePrefix + command
            settings["statusLine"] = statusline
        }

        guard let data = try? JSONSerialization.data(
            withJSONObject: settings, options: [.prettyPrinted, .withoutEscapingSlashes, .sortedKeys])
        else { return "Could not encode settings.json" }

        do { try data.write(to: settingsURL) } catch { return "Could not write settings.json" }
        return hooksInstalled() ? nil : "Hooks were written but did not verify"
    }

    /// Drops our own hooks, leaving every other hook in the group untouched.
    private static func strippingOurs(from groups: [[String: Any]]) -> [[String: Any]] {
        groups.compactMap { group in
            var group = group
            let kept = (group["hooks"] as? [[String: Any]] ?? []).filter {
                !(($0["command"] as? String) ?? "").contains("stayawake-claim")
            }
            if kept.isEmpty { return nil }
            group["hooks"] = kept
            return group
        }
    }

    static var backupURL: URL {
        claudeDirectory.appendingPathComponent("settings.json.bak-stayawake")
    }
}
