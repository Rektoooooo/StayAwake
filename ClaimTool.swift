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
        let payload = readPayload()

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
        case "refresh":
            ClaimStore.refresh(sessionID: sessionID)
        case "release":
            ClaimStore.release(sessionID: sessionID)
        default:
            break
        }

        exit(0)
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
    private static func readPayload() -> [String: Any] {
        guard isatty(FileHandle.standardInput.fileDescriptor) == 0,
              let data = try? FileHandle.standardInput.readToEnd(),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return object
    }
}
