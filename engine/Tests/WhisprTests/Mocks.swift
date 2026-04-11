#if os(macOS)
@preconcurrency import AVFoundation
import Foundation
import os

@testable import WhisprLib

// MARK: - MockAsrSession

/// In-memory replacement for `StreamingNemotronAsrManager` that records
/// every method call for assertion and optionally blocks `finish()` on
/// a continuation so tests can control the drain ordering.
///
/// State is protected by `OSAllocatedUnfairLock` so it's safe to access
/// from any thread, including async contexts — Swift 6 rejects plain
/// `NSLock.lock()` from an async function.
final class MockAsrSession: AsrSession, @unchecked Sendable {
    private struct State {
        var calls: [String] = []
        var appendBufferSizes: [Int] = []
        var partialCallback: (@Sendable (String) -> Void)?
        var finishReturn: String = ""
        var blockFinish: Bool = false
        var finishGate: CheckedContinuation<Void, Never>?
    }
    private let state = OSAllocatedUnfairLock(initialState: State())

    // MARK: - Control knobs (test-side API)

    func setFinishReturn(_ value: String) {
        state.withLock { $0.finishReturn = value }
    }

    /// Block subsequent `finish()` calls until `releaseFinish()` is
    /// called. Useful for simulating a slow drain while a new session
    /// is being started.
    func blockNextFinish() {
        state.withLock { $0.blockFinish = true }
    }

    /// Release a finish() that was blocked by `blockNextFinish()`.
    func releaseFinish() {
        let cont: CheckedContinuation<Void, Never>? = state.withLock {
            let c = $0.finishGate
            $0.finishGate = nil
            $0.blockFinish = false
            return c
        }
        cont?.resume()
    }

    // MARK: - Read-side (assertion) API

    var calls: [String] {
        state.withLock { $0.calls }
    }

    var appendBufferCount: Int {
        state.withLock { $0.appendBufferSizes.count }
    }

    var appendBufferSizes: [Int] {
        state.withLock { $0.appendBufferSizes }
    }

    var partialCallback: (@Sendable (String) -> Void)? {
        state.withLock { $0.partialCallback }
    }

    func resetCallHistory() {
        state.withLock {
            $0.calls.removeAll()
            $0.appendBufferSizes.removeAll()
        }
    }

    // MARK: - AsrSession conformance

    func loadModels() async throws {
        state.withLock { $0.calls.append("loadModels") }
    }

    func reset() async {
        state.withLock { $0.calls.append("reset") }
    }

    func appendAudio(_ buffer: AVAudioPCMBuffer) async throws {
        let frames = Int(buffer.frameLength)
        state.withLock {
            $0.calls.append("appendAudio")
            $0.appendBufferSizes.append(frames)
        }
    }

    func processBufferedAudio() async throws {
        state.withLock { $0.calls.append("processBufferedAudio") }
    }

    func finish() async throws -> String {
        let shouldBlock: Bool = state.withLock {
            $0.calls.append("finish")
            return $0.blockFinish
        }
        if shouldBlock {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                state.withLock { $0.finishGate = cont }
            }
        }
        return state.withLock { $0.finishReturn }
    }

    func cleanup() async {
        state.withLock { $0.calls.append("cleanup") }
    }

    func setPartialTranscriptCallback(
        _ callback: @escaping @Sendable (String) -> Void
    ) async {
        state.withLock {
            $0.calls.append("setPartialTranscriptCallback")
            $0.partialCallback = callback
        }
    }
}

// MARK: - MockAudioCapture

/// In-memory replacement for `AudioCapture` that holds the tap-forwarder
/// closure and lets tests emit synthetic PCM buffers on demand. The
/// real `AudioCapture` owns an `AVAudioEngine`; this mock owns nothing.
final class MockAudioCapture: AudioCaptureSource, @unchecked Sendable {
    private struct State {
        var startCount = 0
        var stopCount = 0
        var onBuffer: (@Sendable (AVAudioPCMBuffer) -> Void)?
    }
    private let state = OSAllocatedUnfairLock(initialState: State())

    var startCount: Int {
        state.withLock { $0.startCount }
    }

    var stopCount: Int {
        state.withLock { $0.stopCount }
    }

    var isStarted: Bool {
        state.withLock { $0.onBuffer != nil }
    }

    func start(onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void) throws {
        state.withLock {
            $0.startCount += 1
            $0.onBuffer = onBuffer
        }
    }

    func stop() {
        state.withLock {
            $0.stopCount += 1
            $0.onBuffer = nil
        }
    }

    /// Test-side: deliver a buffer via the currently-installed tap
    /// callback. No-op if the tap is not started.
    func emit(_ buffer: AVAudioPCMBuffer) {
        let cb: (@Sendable (AVAudioPCMBuffer) -> Void)? = state.withLock { $0.onBuffer }
        cb?(buffer)
    }
}

// MARK: - Test fixtures

/// Build a tiny mono PCM buffer at the given sample rate. The tap in
/// real usage delivers 48 kHz hardware samples; tests can use any rate
/// because the daemon just deep-copies via `copyBuffer`.
func makeTestBuffer(
    frames: Int = 2400,
    sampleRate: Double = 48000
) -> AVAudioPCMBuffer {
    let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
    let buffer = AVAudioPCMBuffer(
        pcmFormat: format,
        frameCapacity: AVAudioFrameCount(frames)
    )!
    buffer.frameLength = AVAudioFrameCount(frames)
    if let data = buffer.floatChannelData {
        for i in 0..<frames {
            data[0][i] = Float(i % 100) / 100.0
        }
    }
    return buffer
}

/// Build a test `Config` with idle timeout disabled and vocabulary off,
/// so tests don't depend on filesystem state under `~/.whispr`.
func makeTestConfig(
    enabled: Bool = true,
    vocabularyEnabled: Bool = false
) -> Config {
    Config(
        enabled: enabled,
        hotkey: .option,
        outputMode: .keypress,
        idleTimeout: 0,
        chunkSize: .ms560,
        vocabularyEnabled: vocabularyEnabled
    )
}
#endif
