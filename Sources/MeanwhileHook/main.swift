// Called by agent hooks as `meanwhile-hook <agent> <event>`.
//
// Reads the agent's event JSON from stdin, sends it to the app's socket, and
// spools it if the app isn't running.
//
// Contract with the agents: always exit 0 and print nothing to stdout,
// so no agent ever reads this program's output as a decision.
import Foundation
import MeanwhileIPC

let environment = ProcessInfo.processInfo.environment

// Meanwhile's own `claude -p` / `codex exec` calls must not feed back into Meanwhile.
if environment[Wire.internalCallVariable] == "1" { exit(0) }

let arguments = CommandLine.arguments
let agent = arguments.count > 1 ? arguments[1] : "unknown"
let event = arguments.count > 2 ? arguments[2] : "unknown"

let payload = FileHandle.standardInput.readDataToEndOfFile()
let line = Wire.envelope(agent: agent, event: event, payload: payload,
                         environment: environment, parentPID: getppid())

if !UnixSocket.send(line, to: MeanwhilePaths.socket.path) {
    Spool.append(line)
}
exit(0)
