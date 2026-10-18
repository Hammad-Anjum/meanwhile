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

// Bound both startup latency and memory use for malformed or adversarial hook
// input. Ordinary agent events are much smaller; oversized input is represented
// by a valid diagnostic envelope rather than a partial JSON payload.
let maximumPayloadBytes = 8 * 1024 * 1024
var payload = Data()
while payload.count <= maximumPayloadBytes {
    let remaining = maximumPayloadBytes + 1 - payload.count
    let chunk = FileHandle.standardInput.readData(ofLength: min(64 * 1024, remaining))
    if chunk.isEmpty { break }
    payload.append(chunk)
}
let payloadWasTruncated = payload.count > maximumPayloadBytes
let line = Wire.envelope(agent: agent, event: event, payload: payload,
                         environment: environment, parentPID: getppid(),
                         payloadWasTruncated: payloadWasTruncated)

if !UnixSocket.send(line, to: MeanwhilePaths.socket.path) {
    Spool.append(line)
}
exit(0)
