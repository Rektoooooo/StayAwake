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
        if let agentID = payload["agent_id"] as? String {
            sessionID += "-" + agentID
        }

        switch action {
        case "acquire":
            ClaimStore.acquire(sessionID: sessionID, note: "\(event) \(cwd)\n")
        case "refresh":
            ClaimStore.refresh(sessionID: sessionID)
        case "release":
            ClaimStore.release(sessionID: sessionID)
        default:
            break
        }

        exit(0)
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
