#if os(macOS)
import Foundation

/// Write a timestamped line to stderr.
///
/// stderr is routed to /tmp/whispr.log by the LaunchAgent plist, so this
/// is how the running daemon leaves a trail for `tail -f /tmp/whispr.log`.
func log(_ message: String) {
    let ts = ISO8601DateFormatter().string(from: Date())
    fputs("\(ts) [whispr] \(message)\n", stderr)
    fflush(stderr)
}
#endif
