import Foundation

struct ClaimCounts: Equatable {
    var sessions = 0
    var agents = 0
    var total: Int { sessions + agents }

    /// "1 session", "2 sessions + 1 agent", "3 agents" — the panel caption.
    var label: String {
        func plural(_ n: Int, _ word: String) -> String { "\(n) \(word)\(n == 1 ? "" : "s")" }
        switch (sessions, agents) {
        case (0, let a): return plural(a, "agent")
        case (let s, 0): return plural(s, "session")
        case (let s, let a): return "\(plural(s, "session")) + \(plural(a, "agent"))"
        }
    }
}

// Auto mode's shared state: one small file per working Claude Code claim.
// Claude Code hooks write these (see stayawake-claim), the app reads them.
//
// A bare process check can't drive this: the `claude` process stays alive the
// whole time a session sits idle at the prompt, so "running" and "working"
// are different things. Hook events tell us which.
//
// File format (v2):
//   pid=<owning claude process, 0 if unknown>
//   kind=<session|agent>
//   <event> <cwd>
// v1 files were just the last line; they are read as sessions with pid 0.
enum ClaimStore {
    /// Backstop for claims whose owner cannot be liveness-checked (pid=0) or
    /// whose owner is alive but leaked the claim (a Stop hook that never ran
    /// on a session now sitting idle at the prompt). PostToolUse re-acquires
    /// during real work, so genuine activity never ages out.
    static let maxAge: TimeInterval = 45 * 60

    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("StayAwake/claims", isDirectory: true)
    }

    private static func url(for sessionID: String) -> URL {
        let safe = sessionID.map { $0.isLetter || $0.isNumber || $0 == "-" ? $0 : "_" }
        return directory.appendingPathComponent(String(safe))
    }

    static func acquire(sessionID: String, isAgent: Bool, ownerPID: pid_t, note: String) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let body = "pid=\(ownerPID)\nkind=\(isAgent ? "agent" : "session")\n\(note)\n"
        try? Data(body.utf8).write(to: url(for: sessionID))
    }

    /// Keeps a live claim from ageing out, without resurrecting a released one.
    static func refresh(sessionID: String) {
        let target = url(for: sessionID)
        guard FileManager.default.fileExists(atPath: target.path) else { return }
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: target.path)
    }

    static func release(sessionID: String) {
        try? FileManager.default.removeItem(at: url(for: sessionID))
    }

    /// What is working right now. Sweeps dead and expired claims as it goes:
    /// a claim whose owning process is gone is removed immediately, which is
    /// what keeps the count honest after a Ctrl+C'd or crashed session that
    /// never fired its Stop hook.
    static func counts() -> ClaimCounts {
        let manager = FileManager.default
        guard let entries = try? manager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return ClaimCounts() }

        var counts = ClaimCounts()
        for entry in entries {
            let modified = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            if Date().timeIntervalSince(modified) > maxAge {
                try? manager.removeItem(at: entry)
                continue
            }

            var pid: pid_t = 0
            var isAgent: Bool?
            if let body = try? String(contentsOf: entry, encoding: .utf8) {
                for line in body.split(separator: "\n").prefix(2) {
                    if line.hasPrefix("pid="), let value = Int32(line.dropFirst(4)) { pid = value }
                    if line.hasPrefix("kind=") { isAgent = line == "kind=agent" }
                }
            }
            if isAgent == nil {
                // Legacy v1 claim with no kind marker, present for up to 45
                // minutes after upgrading. Its name is the session UUID (36
                // chars) with the agent id appended after a dash, so anything
                // longer than a bare UUID belongs to an agent. Without this,
                // a leftover agent claim gets miscounted as a session.
                let name = entry.lastPathComponent
                isAgent = name.count > 36 && Array(name)[safe: 36] == "-"
            }

            // kill(pid, 0) probes liveness without sending a signal. ESRCH
            // means the owner is gone; EPERM would mean alive-but-not-ours.
            if pid > 0, kill(pid, 0) != 0, errno == ESRCH {
                try? manager.removeItem(at: entry)
                continue
            }

            if isAgent == true { counts.agents += 1 } else { counts.sessions += 1 }
        }
        return counts
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
