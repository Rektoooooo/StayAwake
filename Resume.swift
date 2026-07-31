import Foundation

// Auto-resume: when a usage limit stops work, wake the Mac at the reset and
// re-prompt the interrupted sessions so the task finishes unattended.
//
// The pending state is a file, not memory: the whole point is surviving a
// sleep, and possibly an app restart, between scheduling and firing.
struct PendingResume: Codable {
    var fireAt: Date
    /// The exact date string given to `pmset schedule wake`, kept verbatim so
    /// the schedule can be cancelled by matching it.
    var wakeDate: String
    var sessions: [ResumeSession]
}

struct ResumeSession: Codable {
    var id: String
    var cwd: String
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

    /// Where each resumed session's output lands, for post-mortems.
    static func logURL(for sessionID: String) -> URL {
        let safe = sessionID.map { $0.isLetter || $0.isNumber || $0 == "-" ? $0 : "_" }
        return ClaimStore.directory.deletingLastPathComponent()
            .appendingPathComponent("resume-\(String(safe)).log")
    }
}
