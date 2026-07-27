import Foundation

// A short history of what the app did and why.
//
// Answering "did it actually work while I was away?" otherwise means digging
// through `pmset -g log`, which is how a 2h15m battery drain went unnoticed
// until after the fact.
struct ActivityEntry: Codable, Identifiable {
    enum Kind: String, Codable {
        case held, released, slept, limit

        var symbol: String {
            switch self {
            case .held: return "lock.fill"
            case .released: return "lock.open"
            case .slept: return "moon.fill"
            case .limit: return "hourglass"
            }
        }

        var label: String {
            switch self {
            case .held: return "Held"
            case .released: return "Released"
            case .slept: return "Slept"
            case .limit: return "Limit hit"
            }
        }
    }

    let id: UUID
    let at: Date
    let kind: Kind
    let detail: String

    init(kind: Kind, detail: String, at: Date = Date()) {
        self.id = UUID()
        self.at = at
        self.kind = kind
        self.detail = detail
    }

    var time: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: at)
    }
}

enum ActivityLog {
    static let limit = 12

    private static var url: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("StayAwake/activity.json")
    }

    static func load() -> [ActivityEntry] {
        guard let data = try? Data(contentsOf: url),
              let entries = try? JSONDecoder().decode([ActivityEntry].self, from: data)
        else { return [] }
        return entries
    }

    /// Persisted, so the history survives a relaunch or a reboot. That is the
    /// case it exists for: reading it after being away from the machine.
    static func save(_ entries: [ActivityEntry]) {
        let trimmed = Array(entries.suffix(limit))
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(trimmed).write(to: url)
    }
}
