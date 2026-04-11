#if os(macOS)
@preconcurrency import AVFoundation
import FluidAudio
import Foundation
import Testing

@testable import WhisprLib

/// Regression tests for the "short press cuts off / transcribes
/// nothing" bug.
///
/// The root cause was per-session `AVAudioEngine` start/stop with a
/// 560 ms tap buffer: presses shorter than one tap period never
/// fired the tap, and engine.stop() never flushed pending audio, so
/// the beginning of every recording contained warmup silence and the
/// end was clipped by up to 560 ms. The fix:
///
///   1. `AudioCapture` runs the engine for the whole app lifetime —
///      `start()` is called once at install() and `stop()` only on
///      shutdown or `setEnabled(false)`. No per-session teardown.
///   2. Tap buffer is 100 ms (see `AudioCapture.tapBufferDuration`),
///      well within Apple's documented range and short enough that
///      a sub-second press still fires the tap multiple times.
///   3. On release, `onKeyUp` schedules a grace-period close instead
///      of finishing the session immediately, so any tap buffer that
///      was mid-flight when the user released still gets delivered.
///
/// These tests exercise those invariants using the in-memory
/// `MockAsrSession` / `MockAudioCapture` doubles.
@Suite("Whispr short press handling")
struct WhisprShortPressTests {

    private func makeWhispr(
        graceCloseDelay: TimeInterval = 0.02
    ) -> (Whispr, MockAsrSession, MockAudioCapture) {
        let asr = MockAsrSession()
        let capture = MockAudioCapture()
        let whispr = Whispr(
            config: makeTestConfig(),
            manager: asr,
            audioCapture: capture,
            graceCloseDelay: graceCloseDelay,
            persistConfig: false
        )
        whispr._testMarkModelsLoaded()
        whispr.install()
        asr.resetCallHistory()
        return (whispr, asr, capture)
    }

    @Test("Tap buffer duration is small enough for sub-second presses")
    func tapBufferIsSmallEnoughForShortPresses() {
        // Regression guard: if this value creeps back up to something
        // like 0.56, short presses will start failing again.
        #expect(AudioCapture.tapBufferDuration <= 0.1)
    }

    @Test("Install starts the audio capture exactly once")
    func installStartsCaptureOnce() {
        let asr = MockAsrSession()
        let capture = MockAudioCapture()
        let whispr = Whispr(
            config: makeTestConfig(),
            manager: asr,
            audioCapture: capture,
            persistConfig: false
        )
        whispr._testMarkModelsLoaded()

        #expect(capture.startCount == 0)
        whispr.install()
        #expect(capture.startCount == 1)
        #expect(capture.isStarted == true)
    }

    @Test("Per-session onKeyDown / onKeyUp does NOT restart the tap")
    func perSessionKeyEventsDoNotRestartTap() async {
        let (whispr, _, capture) = makeWhispr()

        let initialStart = capture.startCount
        let initialStop = capture.stopCount

        whispr.onKeyDown()
        whispr.onKeyUp()
        await whispr._testWaitUntilIdle()

        // The whole point: press/release is a pointer flip, not an
        // engine start/stop. No warmup, no tail drop.
        #expect(capture.startCount == initialStart)
        #expect(capture.stopCount == initialStop)
    }

    @Test("Shutdown tears down the audio capture")
    func shutdownStopsCapture() async {
        let (whispr, _, capture) = makeWhispr()
        #expect(capture.isStarted == true)

        whispr.shutdown()
        #expect(capture.stopCount >= 1)
    }

    @Test("Buffers emitted while no session is active are discarded")
    func buffersEmittedOutsideSessionAreDiscarded() async {
        let (whispr, asr, capture) = makeWhispr()

        // No session active — emit some buffers via the always-on tap.
        capture.emit(makeTestBuffer())
        capture.emit(makeTestBuffer())
        capture.emit(makeTestBuffer())

        // Give the (non-existent) routing any time to fire spuriously.
        try? await Task.sleep(nanoseconds: 30_000_000)   // 30 ms

        #expect(asr.appendBufferCount == 0,
                "Buffers emitted outside a session must be discarded, not routed to the manager")
        #expect(!asr.calls.contains("appendAudio"))
    }

    @Test("Buffers emitted during an active session are appended")
    func buffersEmittedDuringSessionAreAppended() async {
        let (whispr, asr, capture) = makeWhispr()

        whispr.onKeyDown()
        capture.emit(makeTestBuffer())
        capture.emit(makeTestBuffer())
        capture.emit(makeTestBuffer())
        whispr.onKeyUp()

        await whispr._testWaitUntilIdle()

        // At least the three real buffers + trailing silence at end.
        #expect(asr.appendBufferCount >= 4,
                "Expected at least 3 real buffers + trailing silence, got \(asr.appendBufferCount)")
        #expect(asr.calls.contains("finish"))
    }

    @Test("Grace period captures a buffer emitted AFTER release")
    func gracePeriodCapturesPostReleaseBuffer() async {
        // Longer grace so the test reliably gets the post-release
        // buffer in before the close fires.
        let (whispr, asr, capture) = makeWhispr(graceCloseDelay: 0.1)

        whispr.onKeyDown()
        capture.emit(makeTestBuffer())   // during press
        whispr.onKeyUp()

        // User has released, but the tap is still forwarding into the
        // session's continuation during the grace window. Emit one
        // more buffer as if the tap fired with audio that was in
        // flight at the moment of release.
        capture.emit(makeTestBuffer())

        await whispr._testWaitUntilIdle()

        // Expect at least 2 real buffers + trailing silence.
        #expect(asr.appendBufferCount >= 3,
                "Tail buffer from grace period was dropped. Got appendBufferCount=\(asr.appendBufferCount)")
    }

    @Test("Empty press (no buffers) still calls finish cleanly")
    func emptyPressStillCallsFinish() async {
        let (whispr, asr, capture) = makeWhispr()
        _ = capture  // unused — the point is to emit nothing

        whispr.onKeyDown()
        whispr.onKeyUp()
        await whispr._testWaitUntilIdle()

        // finish() must still run so the drain task completes. Empty
        // transcript is fine — this is just guarding against a stall.
        #expect(asr.calls.contains("finish"))
    }

    @Test("onKeyDown during grace period closes old session cleanly")
    func onKeyDownDuringGraceCleansUpOldSession() async {
        // Longer grace than usual so we have time to fire onKeyDown
        // inside the window deterministically.
        let (whispr, asr, capture) = makeWhispr(graceCloseDelay: 0.15)

        // Session 1
        whispr.onKeyDown()
        capture.emit(makeTestBuffer())
        whispr.onKeyUp()
        #expect(whispr._testHasPendingGraceClose == true)

        // Session 2 — re-press inside grace window.
        whispr.onKeyDown()
        #expect(whispr._testHasPendingGraceClose == false,
                "Grace work item was not cancelled when a new session started")
        #expect(whispr._testIsActive == true)

        capture.emit(makeTestBuffer())
        whispr.onKeyUp()

        await whispr._testWaitUntilIdle()

        // Both sessions must have called finish(), in order.
        let interesting = asr.calls.filter { $0 == "reset" || $0 == "finish" }
        #expect(interesting == ["reset", "finish", "reset", "finish"])
    }

    @Test("Short-press call ordering is reset → setPartialTranscriptCallback → append... → finish")
    func shortPressCallOrderingIsCorrect() async {
        let (whispr, asr, capture) = makeWhispr()

        whispr.onKeyDown()
        capture.emit(makeTestBuffer())
        whispr.onKeyUp()
        await whispr._testWaitUntilIdle()

        // The callback may be set before or after reset() depending on
        // actor scheduling, but both must appear before appendAudio,
        // and finish must come last.
        let calls = asr.calls
        let firstAppendIdx = calls.firstIndex(of: "appendAudio") ?? Int.max
        let resetIdx = calls.firstIndex(of: "reset") ?? Int.max
        let callbackIdx = calls.firstIndex(of: "setPartialTranscriptCallback") ?? Int.max
        let finishIdx = calls.firstIndex(of: "finish") ?? Int.max

        #expect(resetIdx < firstAppendIdx, "reset() must run before any appendAudio")
        #expect(callbackIdx < firstAppendIdx, "setPartialTranscriptCallback must run before any appendAudio")
        #expect(firstAppendIdx < finishIdx, "appendAudio must run before finish")
    }
}
#endif
