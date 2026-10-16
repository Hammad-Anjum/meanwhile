// Called by agent hooks as `meanwhile-hook <agent> <event>`.
//
// Task 0.2 adds the real work: read the event JSON from stdin, forward it to the
// app's socket, and spool it if the app isn't running.
//
// Contract with the agents: always exit 0 and print nothing to stdout,
// so no agent ever reads this program's output as a decision.
import Foundation

exit(0)
