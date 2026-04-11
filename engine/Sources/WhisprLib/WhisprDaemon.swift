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

/// Session orchestrator. Owns the audio capture, Nemotron manager, keyboard
/// tap wiring, text output, and idle timer. One instance per running daemon.
public final class Whispr: @unchecked Sendable {
    // Config is mutable so PreferencesWindow can push live updates.
    public private(set) var config: Config

    // Manager is `var` because changing `chunkSize` requires recreating it —
    // the Nemotron chunk size is set at construction time.
    private var manager: StreamingNemotronAsrManager

    public let textOutput: TextOutput
    let keyboard: KeyboardMonitor
    private let audioCapture = AudioCapture()

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

    // Idle timeout
    private var idleTimer: DispatchSourceTimer?

    // Custom vocabulary (nil when disabled or file missing/empty)
    private var vocabulary: Vocabulary?

    // UI notification — called on main queue whenever the computed state
    // might have changed.
    public var onStateChange: ((SessionState) -> Void)?

    public init(config: Config, manager: StreamingNemotronAsrManager) {
        self.config = config
        self.manager = manager
        self.textOutput = TextOutput(mode: config.outputMode)
        self.keyboard = KeyboardMonitor(modifier: config.hotkey)
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

    /// Wire the keyboard monitor callbacks and install the event tap.
    /// Called once by AppDelegate during applicationDidFinishLaunching.
    public func install() {
        keyboard.onKeyDown = { [weak self] in self?.onKeyDown() }
        keyboard.onKeyUp   = { [weak self] in self?.onKeyUp() }
        keyboard.onEscape  = { [weak self] in self?.onEscape() }
        keyboard.install()
        loadVocabularyIfEnabled()
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

    /// Called by AppDelegate on termination. Fire-and-forget — macOS will
    /// nuke the process either way.
    public func shutdown() {
        Task { [manager] in await manager.cleanup() }
    }

    // MARK: - Enable / disable

    public func setEnabled(_ value: Bool) {
        guard config.enabled != value else { return }
        config.enabled = value
        try? config.save()

        if !value {
            // If a session is in flight, cancel it cleanly.
            if active { onEscape() }
            cancelIdleTimer()
            unloadModels()
        }
        // Re-enable is lazy: no eager reload. Next keyDown triggers load,
        // exactly matching the post-idle-timeout path.
        notifyState()
    }

    // MARK: - Live config updates

    /// Apply a config change from the Preferences window. Writes to disk
    /// and mutates live state so effects are immediate.
    public func applyConfigUpdate(_ new: Config) {
        let old = config
        config = new
        try? new.save()

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
            unloadModels()
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
        guard !active else { return }

        // Kick off an on-demand model load if needed. The processing task
        // below will await it before consuming audio, and the audio stream
        // buffers chunks in the meantime so no words are lost.
        if !modelsLoaded { loadModelsIfNeeded() }
        let loadTask = modelLoadTask

        active = true
        cancelled = false
        sessionStart = Date()
        textOutput.clear()
        cancelIdleTimer()

        let (stream, continuation) = AsyncStream.makeStream(of: AudioChunk.self)
        audioContinuation = continuation

        processingTask = Task { [self] in
            // Wait for model load if one is in flight.
            if let loadTask { await loadTask.value }
            guard !cancelled, modelsLoaded else { return }

            await manager.setPartialTranscriptCallback { [weak self] transcript in
                guard let self, !self.cancelled else { return }
                // RNNT is monotonic — every new partial is a prefix-extension
                // of the previous one. When vocabulary is disabled we can
                // take the pure-append fast path; when enabled, vocabulary
                // substitution may change characters that were already typed
                // so we have to let `sync(to:)` rewind-and-retype.
                if let vocab = self.vocabulary {
                    self.textOutput.sync(to: vocab.correct(transcript))
                } else {
                    let newText = String(transcript.dropFirst(self.textOutput.len))
                    if !newText.isEmpty { self.textOutput.append(newText) }
                }
            }
            await manager.reset()

            for await chunk in stream {
                guard !cancelled else { break }
                guard let pcm = makeBuffer(from: chunk) else { continue }
                do {
                    try await manager.appendAudio(pcm)
                    try await manager.processBufferedAudio()
                } catch {
                    log("Audio processing error: \(error)")
                }
            }
        }

        // Start capture last so audio doesn't begin flowing until the
        // processing task is ready to receive it.
        audioCapture.start { [weak self] buffer in
            guard let self, !self.cancelled else { return }
            guard let chunk = copyBuffer(buffer) else { return }
            self.audioContinuation?.yield(chunk)
        }

        log("SESSION: start")
        notifyState()
    }

    func onKeyUp() {
        guard active else { return }

        let duration = sessionStart.map { Date().timeIntervalSince($0) } ?? 0
        log("SESSION: onKeyUp durationMs=\(Int(duration * 1000))")
        audioCapture.stop()

        // Append trailing silence so the decoder has enough context to
        // finish decoding any speech sitting in a partial chunk. Without
        // this the last word or two get cut off.
        let trailingSilence = AudioChunk(
            samples: [Float](repeating: 0, count: 8000),   // 500ms at 16kHz
            sampleRate: 16000
        )
        audioContinuation?.yield(trailingSilence)
        audioContinuation?.finish()
        audioContinuation = nil

        Task { [self] in
            await processingTask?.value
            processingTask = nil

            do {
                let transcript = try await manager.finish()
                log("SESSION: finish transcript=\"\(transcript)\"")
                if !cancelled, !transcript.isEmpty {
                    // Finish() only extends the last partial. When vocab is
                    // active, apply corrections to the full transcript and
                    // let `sync(to:)` handle any divergence with what we've
                    // already typed.
                    if let vocab = vocabulary {
                        textOutput.sync(to: vocab.correct(transcript))
                    } else {
                        let remaining = String(transcript.dropFirst(textOutput.len))
                        if !remaining.isEmpty { textOutput.append(remaining) }
                    }
                }
            } catch {
                log("ERROR: Finish failed: \(error)")
            }
            await MainActor.run {
                self.active = false
                self.startIdleTimer()
                self.notifyState()
            }
        }
    }

    func onEscape() {
        guard active else { return }
        log("Escape — cancelling")
        cancelled = true
        audioCapture.stop()
        audioContinuation?.finish()
        audioContinuation = nil
        textOutput.cancel()

        Task { [self] in
            await processingTask?.value
            processingTask = nil
            await manager.reset()
            await MainActor.run {
                self.active = false
                self.startIdleTimer()
                self.notifyState()
            }
        }
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
            self.unloadModels()
        }
        timer.resume()
        idleTimer = timer
    }

    private func cancelIdleTimer() {
        idleTimer?.cancel()
        idleTimer = nil
    }

    /// Tear down the Nemotron model to free RAM. Callable from any state;
    /// safe to call when nothing is loaded (no-op).
    private func unloadModels() {
        cancelIdleTimer()
        let wasLoaded = modelsLoaded
        modelsLoaded = false
        if wasLoaded {
            Task { [manager] in await manager.cleanup() }
        }
        notifyState()
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
