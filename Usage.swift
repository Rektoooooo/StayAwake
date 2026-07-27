import Foundation

// The 5-hour and 7-day usage percentages, as Claude Code reports them.
//
// Claude Code pipes `rate_limits` into the configured statusline command's
// stdin on every render. That stream is the only official local source of
// these numbers — hooks carry none of it — so Setup wraps the user's
// statusline command with a `tee` that copies each payload to a file on its
// way through, and this reads the copy. No statusline, no numbers: the panel
// simply hides the section.
struct UsageLimits: Equatable {
    var fiveHour: Int?
    var sevenDay: Int?
    var fiveHourResetsAt: Date?
    var sevenDayResetsAt: Date?
    var asOf: Date
}

enum UsageStore {
    static var url: URL {
        ClaimStore.directory.deletingLastPathComponent()
            .appendingPathComponent("statusline.json")
    }

    /// Shell fragment Setup prepends to the statusline command. The 2>/dev/null
    /// matters: if the directory is missing, tee must complain silently and
    /// keep piping, never break the user's statusline.
    static let teePrefix =
        "tee \"$HOME/Library/Application Support/StayAwake/statusline.json\" 2>/dev/null | "

    /// nil on missing, stale or partially-written files. A tee mid-write can
    /// hand us truncated JSON; the caller keeps its previous value for that.
    static func read(maxAge: TimeInterval = 24 * 3600) -> UsageLimits? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let modified = attributes[.modificationDate] as? Date,
              Date().timeIntervalSince(modified) < maxAge,
              let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let limits = object["rate_limits"] as? [String: Any]
        else { return nil }

        func percent(_ key: String) -> Int? {
            guard let window = limits[key] as? [String: Any],
                  let value = window["used_percentage"] as? NSNumber
            else { return nil }
            return min(100, max(0, Int(value.doubleValue.rounded())))
        }
        func resetsAt(_ key: String) -> Date? {
            guard let window = limits[key] as? [String: Any],
                  let epoch = window["resets_at"] as? NSNumber
            else { return nil }
            return Date(timeIntervalSince1970: epoch.doubleValue)
        }

        let fiveHour = percent("five_hour")
        let sevenDay = percent("seven_day")
        guard fiveHour != nil || sevenDay != nil else { return nil }
        return UsageLimits(
            fiveHour: fiveHour,
            sevenDay: sevenDay,
            fiveHourResetsAt: resetsAt("five_hour"),
            sevenDayResetsAt: resetsAt("seven_day"),
            asOf: modified)
    }
}
