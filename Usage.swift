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

        // A window whose reset time has passed reports an obsolete percentage:
        // the last render predates the reset, and after a limit hit nothing
        // renders to overwrite it, so the file would show a red 100% for a
        // window that already emptied. The payload carries the proof of its
        // own staleness, so clamp to 0 until fresh work re-renders the truth.
        func window(_ key: String) -> (percent: Int, resetsAt: Date?)? {
            guard let value = percent(key) else { return nil }
            let reset = resetsAt(key)
            if let reset, reset <= Date() { return (0, nil) }
            return (value, reset)
        }

        let fiveHour = window("five_hour")
        let sevenDay = window("seven_day")
        guard fiveHour != nil || sevenDay != nil else { return nil }
        return UsageLimits(
            fiveHour: fiveHour?.percent,
            sevenDay: sevenDay?.percent,
            fiveHourResetsAt: fiveHour?.resetsAt,
            sevenDayResetsAt: sevenDay?.resetsAt,
            asOf: modified)
    }
}
