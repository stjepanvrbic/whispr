#if os(macOS)
import Foundation

/// Serialises transcript rendering and coalesces rapid-fire partial
/// updates down to the latest desired text. This keeps the live output
/// path from building an unbounded main-queue backlog during a long
/// dictation session.
actor TranscriptOutputCoordinator {
    private var currentSessionID: UInt64 = 0
    private var pendingDesired: String?
    private var isFlushing = false

    func beginSession(
        sessionID: UInt64,
        textOutput: TextOutput
    ) async {
        currentSessionID = sessionID
        pendingDesired = nil

        while isFlushing {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }

        guard sessionID == currentSessionID else { return }
        await MainActor.run { textOutput.clear() }
    }

    func submitPartial(
        _ transcript: String,
        sessionID: UInt64,
        vocabulary: Vocabulary?,
        textOutput: TextOutput
    ) async {
        guard sessionID == currentSessionID else { return }
        pendingDesired = vocabulary?.correct(transcript) ?? transcript
        await flushIfNeeded(sessionID: sessionID, textOutput: textOutput)
    }

    func finishSession(
        finalTranscript: String,
        cancelled: Bool,
        sessionID: UInt64,
        vocabulary: Vocabulary?,
        textOutput: TextOutput
    ) async {
        guard sessionID == currentSessionID else { return }

        if !cancelled {
            pendingDesired = vocabulary?.correct(finalTranscript) ?? finalTranscript
        }

        await flushIfNeeded(sessionID: sessionID, textOutput: textOutput)
        while isFlushing {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }

        guard sessionID == currentSessionID else { return }
        await MainActor.run { textOutput.finishSession() }
        pendingDesired = nil
    }

    func cancelSession(
        sessionID: UInt64,
        textOutput: TextOutput
    ) async {
        guard sessionID == currentSessionID else { return }
        currentSessionID = 0
        pendingDesired = nil

        while isFlushing {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }

        await MainActor.run { textOutput.cancel() }
    }

    private func flushIfNeeded(
        sessionID: UInt64,
        textOutput: TextOutput
    ) async {
        guard sessionID == currentSessionID else { return }
        guard !isFlushing else { return }

        isFlushing = true
        defer { isFlushing = false }

        while sessionID == currentSessionID, let desired = pendingDesired {
            pendingDesired = nil
            await MainActor.run { textOutput.sync(to: desired) }
        }
    }
}
#endif
