#if os(macOS)
import AVFoundation
import Foundation

/// Always-on microphone capture. Started once at app launch and kept
/// running for the whole process lifetime (until shutdown or
/// `setEnabled(false)`). The tap is decoupled from session boundaries:
/// audio is flowing through the callback continuously, and `Whispr`
/// routes it to the active session — or discards it — on each buffer.
///
/// Running the engine continuously means "press Option" is a pointer
/// flip inside a closure, not a hardware spin-up. There is no warmup
/// window where the first audio is silence from the input gate ramping,
/// which was the cause of "beginning gets cut off" for very short
/// presses in the previous per-session-engine design.
///
/// Trade-off: the macOS microphone-use indicator stays on as long as the
/// engine is running. For a dictation app this matches user expectation.
/// Users can fully tear it down via `setEnabled(false)`.
final class AudioCapture: AudioCaptureSource, @unchecked Sendable {
    /// Tap callback interval. 100 ms is within Apple's documented range
    /// for `installTap` and small enough that even a sub-second press
    /// still produces multiple buffers. The downstream
    /// `StreamingNemotronAsrManager` already accumulates its own
    /// 560 ms chunks before running CoreML inference, so this doesn't
    /// affect the decoder cadence.
    static let tapBufferDuration: TimeInterval = 0.1

    private let engine = AVAudioEngine()
    private var onBuffer: (@Sendable (AVAudioPCMBuffer) -> Void)?
    private var started = false

    init() {}

    /// Start the engine and install the tap. Idempotent — calling again
    /// while already started just swaps the callback. Called once from
    /// `Whispr.install()` at app launch.
    func start(onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void) throws {
        if started {
            self.onBuffer = onBuffer
            return
        }
        self.onBuffer = onBuffer

        let input = engine.inputNode
        let hwFormat = input.outputFormat(forBus: 0)
        let bufferSize = AVAudioFrameCount(hwFormat.sampleRate * Self.tapBufferDuration)

        input.installTap(onBus: 0, bufferSize: bufferSize, format: hwFormat) {
            [weak self] buffer, _ in
            self?.onBuffer?(buffer)
        }

        engine.prepare()
        do {
            try engine.start()
            started = true
        } catch {
            // Clean up partial setup so a retry doesn't leak a tap.
            engine.inputNode.removeTap(onBus: 0)
            self.onBuffer = nil
            throw error
        }
    }

    /// Stop the engine and remove the tap. Called only on app shutdown
    /// or when the user disables Whispr — NOT on session release.
    func stop() {
        guard started else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        onBuffer = nil
        started = false
    }
}
#endif
