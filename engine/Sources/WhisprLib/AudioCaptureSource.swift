#if os(macOS)
@preconcurrency import AVFoundation
import Foundation

/// Abstract interface over a live microphone source. `Whispr` uses this
/// instead of holding `AudioCapture` directly so tests can swap in a fake
/// that emits buffers on demand.
///
/// Lifetime: `start(onBuffer:)` is called once at app launch and
/// installs the permanent tap-forwarder closure. `stop()` tears the
/// engine down — only called on full shutdown or `setEnabled(false)`.
/// Per-session start/stop is deliberately NOT part of this protocol:
/// the engine must keep running across press/release so audio is flowing
/// the instant the user presses their hotkey, with no hardware warmup.
public protocol AudioCaptureSource: Sendable {
    func start(onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void) throws
    func stop()
}
#endif
