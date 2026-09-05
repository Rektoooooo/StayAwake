import Foundation

// Auto-resume: when a usage limit stops work, wake the Mac shortly before the
// reset so Claude Code's own continuation lands on an awake machine.
//
// The pending state is a file, not memory: the whole point is surviving a
// sleep, and possibly an app restart, between scheduling and firing.
struct PendingResume: Codable {
    var fireAt: Date
    /// The exact date string given to `pmset schedule wake`, kept verbatim so
    /// the schedule can be cancelled by matching it. Empty if scheduling failed.
    var wakeDate: String
}

enum ResumeStore {
    static var url: URL {
        ClaimStore.directory.deletingLastPathComponent()
            .appendingPathComponent("pending-resume.json")
    }

    static func load() -> PendingResume? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(PendingResume.self, from: data)
    }

    static func save(_ pending: PendingResume) {
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(pending).write(to: url)
    }

    static func clear() {
        try? FileManager.default.removeItem(at: url)
    }

    /// `pmset schedule wake` wants "MM/dd/yy HH:mm:ss" in local time.
    static func wakeDateString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "MM/dd/yy HH:mm:ss"
        return formatter.string(from: date)
    }
}
