#if os(macOS)
import AVFoundation
import CoreGraphics
import FluidAudio
import Foundation

/// Coarse state the UI cares about. Derived from `enabled`, `modelsLoaded`,
/// `modelLoadTask`, and `active` — don't mutate directly.
public enum SessionState: Sendable, Equatable {
    case disabled       // enabled == false
    case loading        // first-time or on-demand model load in progress
    case recording      // audio capture + transcription in flight
    case idle           // model unloaded after idleTimeout expired
    case ready          // model loaded, waiting for a press
}

/// Session orchestrator. Owns the audio capture, ASR manager, keyboard
/// tap wiring, text output, and idle timer. One instance per running daemon.
public final class Whispr: @unchecked Sendable {
    // Config is mutable so PreferencesWindow can push live updates.
    public private(set) var config: Config

    // Manager is `var` because changing `chunkSize` requires recreating it —
    // the Nemotron chunk size is set at construction time.
    private var manager: any AsrSession

    public let textOutput: TextOutput
    let keyboard: KeyboardMonitor
    private let audioCapture: any AudioCaptureSource

    // Grace period between `onKeyUp` and the session actually closing,
    // during which the always-on tap keeps forwarding buffers into the
    // session. This captures any audio that was mid-flight when the user
    // released. Injected so tests can run with a shorter window.
    let graceCloseDelay: TimeInterval

    // Whether to persist config changes to `~/.whispr/config.json`.
    // Tests pass `false` so they don't clobber the developer's real
    // config while exercising `setEnabled` or `applyConfigUpdate`.
    private let persistConfig: Bool

    // Model lifecycle
    private var modelsLoaded = false
    private var modelLoadTask: Task<Void, Never>?
    private var warmupDone = false

    // Session state
    private var active = false
    private var cancelled = false
    private var sessionStart: Date?
    private var audioContinuation: AsyncStream<AudioChunk>.Continuation?
    private var processingTask: Task<Void, Never>?
    private var chunksReceived: Int = 0

    // Drain state — `drainTask` chains previous sessions' finish() work
    // so session N+1's `reset()` can't clobber session N's accumulated
    // token state. `drainTaskId` is a sentinel the task body uses to
    // check whether it's still the current drain when it wakes up on
    // main (a later session may have replaced `drainTask` in the
    // meantime). `graceCloseWork` is the pending grace-period close
    // scheduled by `onKeyUp`; cancelled + run-immediately if a new
    // `onKeyDown` fires inside the grace window.
    private var drainTask: Task<Void, Never>?
    private var drainTaskId: UUID?
    private var graceCloseWork: DispatchWorkItem?

    // Idle timeout
    private var idleTimer: DispatchSourceTimer?

    // Custom vocabulary (nil when disabled or file missing/empty)
    private var vocabulary: Vocabulary?

    // UI notification — called on main queue whenever the computed state
    // might have changed.
    public var onStateChange: ((SessionState) -> Void)?

    public init(
        config: Config,
        manager: any AsrSession,
        audioCapture: any AudioCaptureSource,
        graceCloseDelay: TimeInterval = 0.15,
        persistConfig: Bool = true
    ) {
        self.config = config
        self.manager = manager
        self.audioCapture = audioCapture
        self.graceCloseDelay = graceCloseDelay
        self.persistConfig = persistConfig
        self.textOutput = TextOutput(mode: config.outputMode)
        self.keyboard = KeyboardMonitor(modifier: config.hotkey)
    }

    private func saveConfigIfEnabled() {
        guard persistConfig else { return }
        try? config.save()
    }

    /// Derived UI state. Cheap — just reads a handful of Bool flags.
    public var state: SessionState {
        if !config.enabled { return .disabled }
        if active          { return .recording }
        if modelLoadTask != nil { return .loading }
        if !modelsLoaded   { return .idle }
        return .ready
    }

    // MARK: - Lifecycle

    /// Wire the keyboard monitor callbacks, install the event tap, and
    /// start the always-on microphone capture.
    /// Called once by AppDelegate during applicationDidFinishLaunching.
    public func install() {
        keyboard.onKeyDown = { [weak self] in self?.onKeyDown() }
        keyboard.onKeyUp   = { [weak self] in self?.onKeyUp() }
        keyboard.onEscape  = { [weak self] in self?.onEscape() }
        keyboard.install()
        loadVocabularyIfEnabled()
        startAudioCaptureIfEnabled()
    }

    /// Start the always-on tap if Whispr is currently enabled. The
    /// engine runs for the whole process lifetime so "press Option" is
    /// just a pointer flip inside the tap callback — no audio warmup,
    /// no first-word clipping.
    private func startAudioCaptureIfEnabled() {
        guard config.enabled else { return }
        do {
            try audioCapture.start { [weak self] buffer in
                guard let self else { return }
                guard let chunk = copyBuffer(buffer) else { return }
                // Writes to `audioContinuation` only happen on the main
                // thread; a stale read from the audio render thread is
                // at worst a slightly-delayed route. `.yield` on an
                // unbounded AsyncStream is non-blocking — safe to call
                // from the render thread.
                self.audioContinuation?.yield(chunk)
            }
        } catch {
            log("Audio capture start failed: \(error)")
        }
    }

    /// Load (or drop) the vocabulary from `~/.whispr/vocabulary.txt`
    /// according to `config.vocabularyEnabled`. Safe to call repeatedly.
    public func reloadVocabulary() {
        loadVocabularyIfEnabled()
    }

    private func loadVocabularyIfEnabled() {
        guard config.vocabularyEnabled else {
            if vocabulary != nil {
                log("Vocabulary disabled — unloading")
            }
            vocabulary = nil
            return
        }
        if let vocab = Vocabulary.load() {
            vocabulary = vocab
            log("Vocabulary loaded: \(vocab.entries.count) entries from \(Vocabulary.vocabularyFile.path)")
        } else {
            vocabulary = nil
            log("Vocabulary: no file at \(Vocabulary.vocabularyFile.path) — substitution disabled")
        }
    }

    /// Called by AppDelegate at startup. Idempotent — safe to call repeatedly.
    public func loadModelsIfNeeded() {
        guard config.enabled, !modelsLoaded, modelLoadTask == nil else { return }

        log("Loading Nemotron \(config.chunkSize.rawValue)ms models...")
        let task = Task { [self] in
            do {
                try await manager.loadModels()
                log("Models loaded ✓")
                if !warmupDone {
                    await warmup()
                    warmupDone = true
                }
            } catch {
                log("ERROR loading models: \(error)")
            }
            await MainActor.run {
                self.modelsLoaded = true
                self.modelLoadTask = nil
                self.notifyState()
            }
        }
        modelLoadTask = task
        notifyState()
    }

    /// Run a silent chunk through the pipeline to trigger CoreML shader
    /// compilation. Takes 10-20s on the first-ever launch; near-instant
    /// afterwards because CoreML caches compiled shaders on disk.
    private func warmup() async {
        let chunkSamples = config.chunkSize == .ms1120 ? 17920 : 8960
        guard let pcm = silentBuffer(frames: chunkSamples + 1600) else { return }
        do {
            try await manager.appendAudio(pcm)
            try await manager.processBufferedAudio()
            _ = try await manager.finish()
            await manager.reset()
        } catch {
            log("Warmup error (non-fatal): \(error)")
        }
    }

    /// Called by AppDelegate on termination. Tears the audio engine down
    /// cleanly; the manager cleanup is fire-and-forget because macOS
    /// will nuke the process either way.
    public func shutdown() {
        audioCapture.stop()
        Task { [manager] in await manager.cleanup() }
    }

    // MARK: - Enable / disable

    public func setEnabled(_ value: Bool) {
        guard config.enabled != value else { return }
        config.enabled = value
        saveConfigIfEnabled()

        if !value {
            // If a session is in flight, cancel it cleanly. The escape
            // path tears down the current session and chains into
            // drainTask.
            if active { onEscape() }
            // Also cancel any pending grace-period close from a prior
            // release that hasn't yet fired.
            graceCloseWork?.cancel()
            graceCloseWork = nil
            cancelIdleTimer()
            unloadModelsAfterDrain()
            // Release the mic indicator when disabled.
            audioCapture.stop()
        } else {
            // Re-enable: restart the always-on tap. Models reload lazily
            // on next key press (same path as post-idle-timeout recovery).
            startAudioCaptureIfEnabled()
        }
        notifyState()
    }

    // MARK: - Live config updates

    /// Apply a config change from the Preferences window. Writes to disk
    /// and mutates live state so effects are immediate.
    public func applyConfigUpdate(_ new: Config) {
        let old = config
        config = new
        saveConfigIfEnabled()

        if new.outputMode != old.outputMode {
            textOutput.setMode(new.outputMode)
        }
        if new.hotkey != old.hotkey {
            keyboard.setModifier(new.hotkey)
        }
        if new.idleTimeout != old.idleTimeout {
            // Reschedule only if a timer is currently running.
            if idleTimer != nil { startIdleTimer() }
        }
        if new.chunkSize != old.chunkSize {
            // Chunk size is baked into the manager at construction. Tear
            // down the current manager and build a new one — next keyDown
            // will kick off a fresh load at the new chunk size.
            unloadModelsAfterDrain()
            manager = StreamingNemotronAsrManager(
                requestedChunkSize: new.chunkSize.nemotron
            )
            warmupDone = false
        }
        if new.vocabularyEnabled != old.vocabularyEnabled {
            loadVocabularyIfEnabled()
        }
        if new.enabled != old.enabled {
            setEnabled(new.enabled)
        }
        notifyState()
    }

    // MARK: - Keyboard callbacks

    func onKeyDown() {
        guard config.enabled else {
            log("onKeyDown ignored — disabled")
            return
        }

        // If the user tapped Option during the grace period after a
        // release, cancel the pending close and finalise the old session
        // immediately. This preserves the drain-task chain: the new
        // session's processingTask will await the just-spawned drain
        // before touching the manager.
        if let pending = graceCloseWork {
            pending.cancel()
            graceCloseWork = nil
            finishCurrentSession()
        }

        guard !active else {
            // This is the smoking-gun log for the "middle gets dropped"
            // bug from before the drain-task chain — if it ever fires
            // again we want to see it immediately.
            log("SESSION: onKeyDown dropped — session still active")
            return
        }

        // Kick off an on-demand model load if needed. The processing task
        // below will await it before consuming audio, and the audio stream
        // buffers chunks in the meantime so no words are lost.
        if !modelsLoaded { loadModelsIfNeeded() }
        let loadTask = modelLoadTask

        active = true
        cancelled = false
        sessionStart = Date()
        chunksReceived = 0
        cancelIdleTimer()

        let (stream, continuation) = AsyncStream.makeStream(of: AudioChunk.self)
        audioContinuation = continuation
        // Capture the existing drain (if any) into a local so this new
        // processingTask has a stable snapshot. Subsequent sessions may
        // replace `self.drainTask` while we're mid-session.
        let previousDrain = drainTask

        processingTask = Task { [self] in
            // Wait for model load if one is in flight.
            if let loadTask { await loadTask.value }
            // Wait for any previous session's drain to fully complete
            // before touching the manager. This enforces the critical
            // ordering invariant: session N+1's reset() must strictly
            // follow session N's finish(), otherwise we'd clobber N's
            // accumulated token state while finish() is still decoding.
            await previousDrain?.value
            guard !cancelled, modelsLoaded else { return }

            // Clear the text-output cursor now that any previous drain
            // has finished typing. Doing this before reset() means a
            // partial-callback fired during the old drain lands against
            // the old cursor, and our new session starts from a clean
            // slate.
            await MainActor.run { [self] in self.textOutput.clear() }

            await manager.setPartialTranscriptCallback { [weak self] transcript in
                // Dispatch the typing work off the ASR actor so its
                // processChunk isn't blocked while we post CGEvents.
                // DispatchQueue.main is FIFO, so monotonic partials stay
                // in order.
                DispatchQueue.main.async { [weak self] in
                    guard let self, !self.cancelled else { return }
                    if let vocab = self.vocabulary {
                        self.textOutput.sync(to: vocab.correct(transcript))
                    } else {
                        let newText = String(transcript.dropFirst(self.textOutput.len))
                        if !newText.isEmpty { self.textOutput.append(newText) }
                    }
                }
            }
            await manager.reset()

            for await chunk in stream {
                guard !cancelled else { break }
                chunksReceived += 1
                guard let pcm = makeBuffer(from: chunk) else { continue }
                do {
                    try await manager.appendAudio(pcm)
                    try await manager.processBufferedAudio()
                } catch {
                    log("Audio processing error: \(error)")
                }
            }
            log("SESSION: stream closed chunks=\(chunksReceived)")
        }

        log("SESSION: start draining=\(previousDrain != nil)")
        notifyState()
    }

    func onKeyUp() {
        guard active else { return }

        let duration = sessionStart.map { Date().timeIntervalSince($0) } ?? 0
        log("SESSION: onKeyUp durationMs=\(Int(duration * 1000))")

        // Flip the capture-active state synchronously so a quick
        // re-press is NOT rejected by the `!active` guard. `onKeyDown`
        // only looks at `active`; the drain task is tracked separately
        // via `drainTask`.
        active = false
        notifyState()
        startIdleTimer()

        // Schedule the actual session close for after the grace window.
        // During that window the always-on tap keeps forwarding buffers
        // into `audioContinuation`, so any audio still in flight when
        // the user released gets captured. A new `onKeyDown` inside the
        // grace window cancels this work item and runs
        // `finishCurrentSession()` synchronously before starting the
        // next session.
        let work = DispatchWorkItem { [weak self] in
            self?.finishCurrentSession()
        }
        graceCloseWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + graceCloseDelay, execute: work)
    }

    /// Close the currently-open session: yield trailing silence, finish
    /// the stream, and spawn a drain task that awaits processing, calls
    /// `manager.finish()`, types the final transcript, and logs. Called
    /// either from the grace-period work item or synchronously from
    /// `onKeyDown` when a new session supersedes the pending close.
    ///
    /// Runs on the main thread.
    private func finishCurrentSession() {
        graceCloseWork = nil

        // Capture locals so the spawned task has a stable snapshot even
        // if a subsequent session replaces these fields.
        guard let continuation = audioContinuation else { return }
        let drained = processingTask
        let previousDrain = drainTask
        let wasCancelledAtRelease = cancelled
        // Capture the manager by value in case `applyConfigUpdate`
        // reassigns `self.manager` (on chunk-size change) while this
        // drain is still in flight — we need to finish the old manager,
        // not the new one.
        let mgr = manager
        let sessionChunks = chunksReceived
        _ = sessionStart

        // Append trailing silence so the decoder has enough context to
        // finish decoding any speech sitting in a partial chunk. Without
        // this the last word or two get cut off.
        let trailingSilence = AudioChunk(
            samples: [Float](repeating: 0, count: 8000),   // 500ms at 16kHz
            sampleRate: 16000
        )
        continuation.yield(trailingSilence)
        continuation.finish()

        audioContinuation = nil
        processingTask = nil
        sessionStart = nil

        // UUID token lets the finished task check whether it's still
        // the "current" drain when it wakes up on main — a subsequent
        // session may have replaced `drainTask` with its own reference.
        let thisDrainId = UUID()
        drainTaskId = thisDrainId
        drainTask = Task { [self] in
            // Serialise against any previous drain so finish() calls on
            // the manager strictly overlap: finish1 → reset2 → finish2.
            await previousDrain?.value
            await drained?.value

            let drainStart = Date()
            var transcript = ""
            do {
                transcript = try await mgr.finish()
            } catch {
                log("ERROR: Finish failed: \(error)")
            }

            let drainMs = Int(Date().timeIntervalSince(drainStart) * 1000)
            log("SESSION: drainMs=\(drainMs) chunks=\(sessionChunks)")
            log("SESSION: finish transcript=\"\(transcript)\"")

            if !wasCancelledAtRelease, !transcript.isEmpty {
                // Final transcript typing goes through the main queue,
                // same serial FIFO as the partial callbacks, so it
                // lands strictly after any still-pending partials.
                // Copy transcript to an immutable local so the main
                // closure captures a Sendable value without crossing
                // the task's mutable-variable isolation boundary.
                let finalTranscript = transcript
                await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                    DispatchQueue.main.async { [weak self] in
                        guard let self else { cont.resume(); return }
                        if let vocab = self.vocabulary {
                            self.textOutput.sync(to: vocab.correct(finalTranscript))
                        } else {
                            let remaining = String(finalTranscript.dropFirst(self.textOutput.len))
                            if !remaining.isEmpty { self.textOutput.append(remaining) }
                        }
                        cont.resume()
                    }
                }
            }

            await MainActor.run { [self] in
                // Only clear drainTask if it still points at this task —
                // a later session may have already replaced it.
                if self.drainTaskId == thisDrainId {
                    self.drainTask = nil
                    self.drainTaskId = nil
                    self.notifyState()
                }
            }
        }
    }

    func onEscape() {
        guard active || graceCloseWork != nil else { return }
        log("Escape — cancelling")
        cancelled = true

        // Cancel any pending grace-period close.
        graceCloseWork?.cancel()
        graceCloseWork = nil

        let drained = processingTask
        let previousDrain = drainTask
        let mgr = manager

        audioContinuation?.finish()
        audioContinuation = nil
        processingTask = nil
        active = false
        sessionStart = nil
        textOutput.cancel()

        let thisDrainId = UUID()
        drainTaskId = thisDrainId
        drainTask = Task { [self] in
            await previousDrain?.value
            await drained?.value
            await mgr.reset()
            await MainActor.run { [self] in
                if self.drainTaskId == thisDrainId {
                    self.drainTask = nil
                    self.drainTaskId = nil
                    self.notifyState()
                }
            }
        }
        startIdleTimer()
        notifyState()
    }

    // MARK: - Idle timeout

    private func startIdleTimer() {
        guard config.idleTimeout > 0 else { return }
        cancelIdleTimer()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + .seconds(config.idleTimeout))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            log("Idle timeout — unloading models")
            self.unloadModelsAfterDrain()
        }
        timer.resume()
        idleTimer = timer
    }

    private func cancelIdleTimer() {
        idleTimer?.cancel()
        idleTimer = nil
    }

    /// Tear down the ASR model to free RAM. Waits for any in-flight
    /// drain to complete before calling `manager.cleanup()` — otherwise
    /// the cleanup could race against a still-running `finish()`. Safe
    /// to call when nothing is loaded (no-op).
    private func unloadModelsAfterDrain() {
        cancelIdleTimer()
        guard modelsLoaded else { return }
        modelsLoaded = false
        let pendingDrain = drainTask
        Task { [manager] in
            await pendingDrain?.value
            await manager.cleanup()
        }
        notifyState()
    }

    // MARK: - Test hooks
    //
    // These are `internal` (not private) so tests can reach them via
    // `@testable import WhisprLib`. They are not part of the public API
    // and should never be called from production code.

    /// Test helper: synthesise the post-load state without running the
    /// real model load + warmup. Lets tests drive onKeyDown without
    /// polluting mock call histories with warmup bookkeeping.
    func _testMarkModelsLoaded() {
        modelsLoaded = true
        warmupDone = true
        modelLoadTask = nil
    }

    /// Test helper: return the current active-session flag. The normal
    /// `state` getter folds this into a derived enum; tests may want to
    /// assert on the raw flag directly.
    var _testIsActive: Bool { active }

    /// Test helper: return the current drain task (or nil) so tests
    /// can await pending work.
    var _testDrainTask: Task<Void, Never>? { drainTask }

    /// Test helper: return whether a grace-period close is pending.
    var _testHasPendingGraceClose: Bool { graceCloseWork != nil }

    /// Test helper: wait until there is no grace-period work pending
    /// and no drain task in flight. Polls with a short sleep — not
    /// bulletproof against wake-up races, but good enough for the
    /// deterministic mock-driven tests we run.
    func _testWaitUntilIdle() async {
        let deadline = Date().addingTimeInterval(2.0)
        while Date() < deadline {
            let pendingGrace = graceCloseWork != nil
            let pendingDrain = drainTask != nil
            if !pendingGrace && !pendingDrain { break }
            try? await Task.sleep(nanoseconds: 5_000_000)  // 5ms
        }
        // Give MainActor hops inside the completed drain one more
        // tick to write `drainTask = nil` before the test asserts.
        try? await Task.sleep(nanoseconds: 20_000_000)  // 20ms
    }

    // MARK: - State notification

    private func notifyState() {
        let s = state
        if Thread.isMainThread {
            onStateChange?(s)
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.onStateChange?(s)
            }
        }
    }
}

// MARK: - ChunkSize ↔ FluidAudio

extension ChunkSize {
    var nemotron: NemotronChunkSize {
        switch self {
        case .ms560:  return .ms560
        case .ms1120: return .ms1120
        }
    }
}
#endif
