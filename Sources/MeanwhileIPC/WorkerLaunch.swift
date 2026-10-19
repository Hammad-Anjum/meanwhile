import Foundation

/// When and how `meanwhile-hook` starts the worker (`meanwhile work`).
///
/// The worker indexes repos and generates questions. It is started by the hook, not by the
/// app, because a process started from the agent's terminal inherits that terminal's access
/// to ~/Desktop, ~/Documents and ~/Downloads, which macOS hides from the login item
/// (docs/phase2-plan.md). Started detached, so the hook never waits for it.
public enum WorkerLaunch {
    /// Tools whose use changes files: worth a live-diff pass.
    static let editTools: Set<String> = ["Edit", "MultiEdit", "Write", "NotebookEdit", "apply_patch"]

    /// Why to start the worker for this hook event, or nil to not start it.
    public static func reason(event: String, payload: Data) -> String? {
        switch event {
        case "UserPromptSubmit": return "turn-start"
        case "Stop", "StopFailure": return "turn-end"
        case "PostToolUse":
            guard let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
                  let tool = object["tool_name"] as? String, editTools.contains(tool) else { return nil }
            return "edit"
        default: return nil
        }
    }

    /// The `meanwhile work` arguments for this event, or nil if it lacks a working directory.
    public static func arguments(reason: String, agent: String, payload: Data) -> [String]? {
        guard let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let cwd = object["cwd"] as? String else { return nil }
        var arguments = ["work", "--repo", cwd, "--reason", reason, "--agent", agent]
        if let session = object["session_id"] as? String { arguments += ["--session", session] }
        return arguments
    }

    /// Starts `executable` with `arguments` in its own session, stdio closed, without waiting.
    @discardableResult
    public static func spawnDetached(_ executable: String, _ arguments: [String]) -> Bool {
        guard FileManager.default.isExecutableFile(atPath: executable) else { return false }
        var attributes = posix_spawnattr_t(nil as OpaquePointer?)
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID))

        var actions = posix_spawn_file_actions_t(nil as OpaquePointer?)
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        for fd in [STDIN_FILENO, STDOUT_FILENO, STDERR_FILENO] {
            posix_spawn_file_actions_addopen(&actions, fd, "/dev/null", fd == STDIN_FILENO ? O_RDONLY : O_WRONLY, 0)
        }

        let argv = ([executable] + arguments).map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        var pid: pid_t = 0
        return posix_spawn(&pid, executable, &actions, &attributes, argv, environ) == 0
    }
}
