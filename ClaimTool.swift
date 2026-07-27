import Foundation

// `stayawake-claim <acquire|refresh|release>`
//
// Invoked by Claude Code hooks with the hook payload on stdin. It must stay
// silent: stdout from a UserPromptSubmit hook is injected into Claude's
// context, so anything printed here would end up in the conversation. It must
// also always exit 0, so a failure here can never break a hook.
@main
struct ClaimTool {
    static func main() {
        let action = CommandLine.arguments.dropFirst().first ?? "acquire"
        let raw = readRawPayload()
        let payload = (try? JSONSerialization.jsonObject(with: raw) as? [String: Any]) ?? [:]

        let event = payload["hook_event_name"] as? String ?? "manual"
        let cwd = payload["cwd"] as? String ?? "?"

        // Background subagents outlive the main loop's Stop, so each one holds
        // its own claim. Otherwise Stop would hand sleep back while an agent
        // was still working.
        var sessionID = payload["session_id"] as? String ?? "unknown-session"
        let isAgent = payload["agent_id"] != nil
        if let agentID = payload["agent_id"] as? String {
            sessionID += "-" + agentID
        }

        switch action {
        case "acquire":
            ClaimStore.acquire(
                sessionID: sessionID,
                isAgent: isAgent,
                ownerPID: owningProcess(),
                note: "\(event) \(cwd)")
            // Fresh work proves any recorded usage limit no longer binds.
            ClaimStore.clearLimit()
        case "refresh":
            ClaimStore.refresh(sessionID: sessionID)
        case "release":
            ClaimStore.release(sessionID: sessionID)
            // A turn that ends in failure fires StopFailure, not Stop. When
            // the failure is a usage limit, the whole account is blocked, so
            // record it and sweep every claim. Sniffed only on StopFailure:
            // a successful turn's payload can quote limit phrases innocently
            // (a conversation about limits, say) without any limit being hit.
            if event == "StopFailure" || event == "SubagentStop" {
                sniffUsageLimit(in: raw)
            }
        default:
            break
        }

        exit(0)
    }

    private static func sniffUsageLimit(in raw: Data) {
        guard let text = String(data: raw, encoding: .utf8) else { return }
        let lowered = text.lowercased()
        let phrases = ["hit your session limit", "hit your usage limit",
                       "usage limit reached", "hit your weekly limit"]
        guard phrases.contains(where: lowered.contains) else { return }

        // Pull the human "resets 3am (Europe/Prague)" fragment if present.
        var detail = "resets soon"
        if let range = lowered.range(of: "resets") {
            let tail = text[range.lowerBound...]
            let fragment = tail.prefix { !"\"\\\n".contains($0) }.prefix(48)
            let cleaned = fragment
                .replacingOccurrences(of: "\\u{2022}", with: "")
                .trimmingCharacters(in: .whitespaces)
            if cleaned.count > 6 { detail = cleaned }
        }
        ClaimStore.recordLimit(detail: detail)
    }

    /// The claude process this hook belongs to, so the app can prune the claim
    /// the moment that process dies instead of waiting out a timeout.
    ///
    /// Hooks run as `sh -c '...'` spawned by claude, so the ancestry here is
    /// stayawake-claim -> sh -> claude. Walk up, preferring an ancestor
    /// actually named claude; failing that, the first thing above the shell
    /// layer (covers a renamed binary or another harness). 0 = unknown, which
    /// falls back to age-based expiry.
    private static func owningProcess() -> pid_t {
        let shells: Set<String> = ["sh", "bash", "zsh", "dash", "fish"]
        var pid = getppid()
        var fallback: pid_t = 0
        for _ in 0..<12 {
            guard pid > 1, let info = processInfo(pid) else { break }
            let name = processName(info)
            if name == "claude" { return pid }
            if fallback == 0 && !shells.contains(name) { fallback = pid }
            pid = info.kp_eproc.e_ppid
        }
        return fallback
    }

    private static func processInfo(_ pid: pid_t) -> kinfo_proc? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return info
    }

    private static func processName(_ info: kinfo_proc) -> String {
        var comm = info.kp_proc.p_comm
        return withUnsafePointer(to: &comm) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXCOMLEN) + 1) {
                String(cString: $0)
            }
        }
    }

    /// Hooks always pipe JSON in, but never block if run by hand with no stdin.
    private static func readRawPayload() -> Data {
        guard isatty(FileHandle.standardInput.fileDescriptor) == 0,
              let data = try? FileHandle.standardInput.readToEnd()
        else { return Data() }
        return data
    }
}
