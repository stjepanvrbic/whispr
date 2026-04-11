#if os(macOS)
@preconcurrency import AVFoundation
import FluidAudio
import Foundation

/// Abstract interface over a streaming ASR engine, covering exactly the
/// methods `Whispr` calls on its manager. Exists so tests can drive the
/// daemon against a lightweight in-memory mock instead of the real
/// FluidAudio `StreamingNemotronAsrManager` actor.
///
/// All methods are `async` so an actor-backed implementation can conform
/// transparently — the compiler inserts the actor hop at the call site.
/// Non-actor implementations (test doubles) can just run their bodies
/// directly; they pay nothing for the async-ness.
public protocol AsrSession: Sendable {
    func loadModels() async throws
    func reset() async
    func appendAudio(_ buffer: AVAudioPCMBuffer) async throws
    func processBufferedAudio() async throws
    func finish() async throws -> String
    func cleanup() async
    func setPartialTranscriptCallback(
        _ callback: @escaping @Sendable (String) -> Void
    ) async
}

extension StreamingNemotronAsrManager: AsrSession {}
#endif
