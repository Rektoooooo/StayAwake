import Foundation

// Auto mode's shared state: one small file per working Claude Code session.
// Claude Code hooks write these (see stayawake-claim), the app reads them.
//
// A bare process check can't drive this: the `claude` process stays alive the
// whole time a session sits idle at the prompt, so "running" and "working"
// are different things. Hook events tell us which.
enum ClaimStore {
    /// Backstop for sessions that died without firing Stop or SessionEnd.
    /// Generous, because a long tool-free response must not expire mid-turn;
    /// PostToolUse refreshes the claim throughout normal work anyway.
    static let maxAge: TimeInterval = 45 * 60

    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("StayAwake/claims", isDirectory: true)
    }

    private static func url(for sessionID: String) -> URL {
        let safe = sessionID.map { $0.isLetter || $0.isNumber || $0 == "-" ? $0 : "_" }
        return directory.appendingPathComponent(String(safe))
    }

    static func acquire(sessionID: String, note: String) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? Data(note.utf8).write(to: url(for: sessionID))
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

    /// Count of sessions currently working. Sweeps expired claims as it goes.
    static func activeSessions() -> Int {
        let manager = FileManager.default
        guard let entries = try? manager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        var live = 0
        for entry in entries {
            let modified = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            if Date().timeIntervalSince(modified) > maxAge {
                try? manager.removeItem(at: entry)
            } else {
                live += 1
            }
        }
        return live
    }
}
