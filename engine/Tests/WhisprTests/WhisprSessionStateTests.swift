#if os(macOS)
import AppKit
@preconcurrency import AVFoundation
import FluidAudio
import Foundation
import Testing

@testable import WhisprLib

/// Regression tests for the "long recording middle gets dropped" bug.
///
/// The root cause was that `active` only flipped false after an async
/// drain task completed `manager.finish()`, so a quick re-press during
/// the drain window was silently rejected by `guard !active` in
/// `onKeyDown`. The fix:
///
///   1. `active` flips false synchronously inside `onKeyUp`.
///   2. The drain work is tracked separately in `drainTask`.
///   3. The next session's `processingTask` explicitly awaits the
///      previous drain before calling `manager.reset()`, so we never
///      clobber session N's accumulated token state with a reset from
///      session N+1.
///
/// These tests exercise those invariants using the in-memory
/// `MockAsrSession` / `MockAudioCapture` doubles.
@Suite("Whispr session state machine")
struct WhisprSessionStateTests {

    /// Build a Whispr wired to mocks, with the model-load path pre-baked
    /// so the processingTask doesn't run warmup (which would pollute
    /// the mock's call history).
    private func makeWhispr(
        graceCloseDelay: TimeInterval = 0.02
    ) -> (Whispr, MockAsrSession, MockAudioCapture) {
        let asr = MockAsrSession()
        let capture = MockAudioCapture()
        let whispr = Whispr(
            config: makeTestConfig(),
            manager: asr,
            audioCapture: capture,
            textOutput: makeSilentTextOutput(mode: .keypress),
            graceCloseDelay: graceCloseDelay,
            persistConfig: false
        )
        whispr._testMarkModelsLoaded()
        try? capture.start { _ in }   // bare-minimum start so _testIsActive flips
        // Actually just install properly so the tap closure is wired.
        capture.stop()
        whispr.install()
        // Reset after install(): install() may call loadVocabularyIfEnabled
        // but won't touch the asr mock, so calls stays empty.
        asr.resetCallHistory()
        return (whispr, asr, capture)
    }

    @Test("onKeyUp flips active synchronously so onKeyDown isn't blocked")
    func activeFlipsFalseSynchronously() async throws {
        let (whispr, _, _) = makeWhispr()

        whispr.onKeyDown()
        #expect(whispr._testIsActive == true)

        whispr.onKeyUp()
        // The whole point of the bug 1 fix: after onKeyUp() returns,
        // `active` is already false, so a follow-up onKeyDown can
        // proceed immediately — no matter how long the drain takes.
        #expect(whispr._testIsActive == false)

        await whispr._testWaitUntilIdle()
    }

    @Test("Two sequential sessions ordering: reset1 → finish1 → reset2 → finish2")
    func sequentialSessionsOrderCorrectly() async throws {
        let (whispr, asr, capture) = makeWhispr()
        asr.setFinishReturn("one")

        // Session 1
        whispr.onKeyDown()
        capture.emit(makeTestBuffer())
        whispr.onKeyUp()

        // Session 2 (immediate re-press — the old bug's trigger)
        whispr.onKeyDown()
        capture.emit(makeTestBuffer())
        whispr.onKeyUp()

        await whispr._testWaitUntilIdle()

        // Filter to just the ordering markers we care about.
        let interesting = asr.calls.filter { $0 == "reset" || $0 == "finish" }
        #expect(interesting == ["reset", "finish", "reset", "finish"],
                "Got \(interesting) — session N+1's reset() must strictly follow session N's finish()")
    }

    @Test("Quick re-press during drain is not dropped")
    func quickRepressDuringDrainIsNotDropped() async throws {
        let (whispr, asr, capture) = makeWhispr(graceCloseDelay: 0.02)

        // Block the first session's finish() so the drain stays
        // pending across the second onKeyDown.
        asr.blockNextFinish()

        // Session 1
        whispr.onKeyDown()
        capture.emit(makeTestBuffer())
        whispr.onKeyUp()

        // Wait for the grace close work to fire so the drain spawns
        // and hits the blocked finish().
        try? await Task.sleep(nanoseconds: 50_000_000)  // 50 ms

        // Session 2 — the old bug would silently drop this because
        // the session 1 drain is still running.
        whispr.onKeyDown()
        #expect(whispr._testIsActive == true,
                "Second onKeyDown was silently dropped — state race returned")

        capture.emit(makeTestBuffer())
        whispr.onKeyUp()

        // Now release the first finish() so everything can drain.
        asr.releaseFinish()
        await whispr._testWaitUntilIdle()

        // Both sessions must have called finish(), in order.
        let interesting = asr.calls.filter { $0 == "reset" || $0 == "finish" }
        #expect(interesting == ["reset", "finish", "reset", "finish"])
    }

    @Test("Three back-to-back sessions serialize correctly")
    func threeBackToBackSessionsSerializeCorrectly() async throws {
        let (whispr, asr, capture) = makeWhispr(graceCloseDelay: 0.02)
        asr.setFinishReturn("x")

        for _ in 0..<3 {
            whispr.onKeyDown()
            capture.emit(makeTestBuffer())
            whispr.onKeyUp()
        }

        await whispr._testWaitUntilIdle()

        let interesting = asr.calls.filter { $0 == "reset" || $0 == "finish" }
        #expect(interesting == ["reset", "finish", "reset", "finish", "reset", "finish"])
    }

    @Test("Escape during a session cancels and allows the next session to run cleanly")
    func escapeThenNewSession() async throws {
        let (whispr, asr, capture) = makeWhispr(graceCloseDelay: 0.02)

        whispr.onKeyDown()
        capture.emit(makeTestBuffer())
        whispr.onEscape()
        #expect(whispr._testIsActive == false)

        await whispr._testWaitUntilIdle()

        // Escape must call reset on the old session but NOT finish.
        let afterEscape = asr.calls
        #expect(afterEscape.contains("reset"))
        #expect(!afterEscape.contains("finish"))

        asr.resetCallHistory()

        // New session must work.
        whispr.onKeyDown()
        capture.emit(makeTestBuffer())
        whispr.onKeyUp()
        await whispr._testWaitUntilIdle()

        let second = asr.calls.filter { $0 == "reset" || $0 == "finish" }
        #expect(second == ["reset", "finish"])
    }

    @Test("Escape restores the original clipboard in clipboard mode")
    @MainActor
    func escapeRestoresClipboard() async throws {
        let asr = MockAsrSession()
        let capture = MockAudioCapture()
        let whispr = Whispr(
            config: Config(
                enabled: true,
                hotkey: .option,
                outputMode: .clipboard,
                idleTimeout: 0,
                chunkSize: .ms560,
                vocabularyEnabled: false
            ),
            manager: asr,
            audioCapture: capture,
            textOutput: makeSilentTextOutput(mode: .clipboard),
            graceCloseDelay: 0.02,
            persistConfig: false
        )
        whispr._testMarkModelsLoaded()
        whispr.install()
        asr.resetCallHistory()

        await PasteboardTestSupport.withPreservedPasteboard { pasteboard in
            pasteboard.clearContents()
            pasteboard.setString("original clipboard", forType: .string)

            whispr.onKeyDown()
            capture.emit(makeTestBuffer())

            let callbackReady = Date().addingTimeInterval(1.0)
            while asr.partialCallback == nil, Date() < callbackReady {
                try? await Task.sleep(nanoseconds: 5_000_000)
            }

            guard let partialCallback = asr.partialCallback else {
                Issue.record("Partial transcript callback was never installed")
                return
            }

            partialCallback("streamed delta")
            try? await Task.sleep(nanoseconds: 20_000_000)

            whispr.onEscape()
            await whispr._testWaitUntilIdle()

            #expect(pasteboard.string(forType: .string) == "original clipboard")
        }
    }

    @Test("Dropped-keydown log message never fires under normal re-press")
    func noDroppedKeyDownLogUnderNormalRepress() async throws {
        // This test is a behavioural check that the state flip is
        // synchronous: we drive onKeyDown → onKeyUp → onKeyDown and
        // expect the second onKeyDown to enter the active state.
        // If the old bug were back, the second keydown would hit the
        // `guard !active` and early-return without flipping active.
        let (whispr, _, _) = makeWhispr(graceCloseDelay: 0.02)

        whispr.onKeyDown()
        whispr.onKeyUp()
        whispr.onKeyDown()
        #expect(whispr._testIsActive == true)
        whispr.onKeyUp()

        await whispr._testWaitUntilIdle()
    }
}
#endif
