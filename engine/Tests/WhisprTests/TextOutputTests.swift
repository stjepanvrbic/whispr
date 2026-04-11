#if os(macOS)
import Foundation
import Testing

@testable import WhisprLib

@Suite("TextOutput state tracking")
struct TextOutputTests {

    // We test the length tracking and rewind logic, not the actual
    // CGEvent posting (which requires Accessibility permission and a
    // display session).
    //
    // TextOutput.typed is the single source of truth for "what's on
    // screen right now" — WhisprDaemon uses `len` for the pure-append
    // fast path and `sync(to:)` when vocabulary substitution changes
    // characters that were already typed.

    @Test("Initial state is empty")
    func initialState() {
        let out = TextOutput(mode: .keypress)
        #expect(out.len == 0)
        #expect(out.typed == "")
    }

    @Test("Append extends typed and length")
    func appendLen() {
        let out = TextOutput(mode: .keypress)
        out.append("hello")
        #expect(out.len == 5)
        #expect(out.typed == "hello")
        out.append(" world")
        #expect(out.len == 11)
        #expect(out.typed == "hello world")
    }

    @Test("Append with empty string is a no-op")
    func appendEmpty() {
        let out = TextOutput(mode: .keypress)
        out.append("abc")
        out.append("")
        #expect(out.len == 3)
        #expect(out.typed == "abc")
    }

    @Test("cancel() resets typed to empty")
    func cancelLen() {
        let out = TextOutput(mode: .keypress)
        out.append("hello world")
        out.cancel()
        #expect(out.len == 0)
        #expect(out.typed == "")
    }

    @Test("cancel() on empty is a no-op")
    func cancelEmpty() {
        let out = TextOutput(mode: .keypress)
        out.cancel()
        #expect(out.len == 0)
    }

    @Test("clear() resets typed without backspacing")
    func clearLen() {
        let out = TextOutput(mode: .keypress)
        out.append("hello")
        out.clear()
        #expect(out.len == 0)
        #expect(out.typed == "")
    }

    @Test("setMode swaps mode in place")
    func setModeSwaps() {
        let out = TextOutput(mode: .keypress)
        #expect(out.mode == .keypress)
        out.setMode(.clipboard)
        #expect(out.mode == .clipboard)
    }

    @Test("Simulated streaming partials track monotonically via len")
    func streamingSimulation() {
        // Mirrors the Whispr.onKeyDown diff path:
        //   newText = String(transcript.dropFirst(textOutput.len))
        let out = TextOutput(mode: .keypress)
        let partials = ["The", "The quick", "The quick brown fox"]
        for partial in partials {
            let newText = String(partial.dropFirst(out.len))
            out.append(newText)
            #expect(out.len == partial.count)
        }
        #expect(out.typed == "The quick brown fox")
    }

    @Test("Unicode grapheme-cluster counting is correct")
    func unicodeLen() {
        let out = TextOutput(mode: .keypress)
        // café with combining accent → 4 grapheme clusters
        out.append("cafe\u{0301}")
        #expect(out.len == 4)

        out.clear()
        out.append("Hello 🌍")
        #expect(out.len == 7)
    }

    @Test("Append after clear starts from zero")
    func appendAfterClear() {
        let out = TextOutput(mode: .keypress)
        out.append("first")
        out.clear()
        out.append("second")
        #expect(out.len == 6)
        #expect(out.typed == "second")
    }

    // MARK: - sync(to:)

    @Test("sync to identical string is a no-op")
    func syncIdentical() {
        let out = TextOutput(mode: .keypress)
        out.append("hello")
        out.sync(to: "hello")
        #expect(out.typed == "hello")
        #expect(out.len == 5)
    }

    @Test("sync to pure extension behaves like append")
    func syncPureExtension() {
        let out = TextOutput(mode: .keypress)
        out.append("The quick")
        out.sync(to: "The quick brown fox")
        #expect(out.typed == "The quick brown fox")
        #expect(out.len == "The quick brown fox".count)
    }

    @Test("sync with divergent suffix rewinds and retypes")
    func syncDivergentSuffix() {
        let out = TextOutput(mode: .keypress)
        out.append("clawed code")
        // Vocabulary has substituted — common prefix is 0 characters
        // (C vs c differs), so the full 11 characters should rewind.
        out.sync(to: "Claude Code")
        #expect(out.typed == "Claude Code")
        #expect(out.len == 11)
    }

    @Test("sync with partial common prefix rewinds only the divergent tail")
    func syncPartialCommonPrefix() {
        let out = TextOutput(mode: .keypress)
        out.append("I have an in video GPU")
        out.sync(to: "I have an NVIDIA GPU")
        #expect(out.typed == "I have an NVIDIA GPU")
    }

    @Test("sync from empty state fills to desired")
    func syncFromEmpty() {
        let out = TextOutput(mode: .keypress)
        out.sync(to: "hello world")
        #expect(out.typed == "hello world")
        #expect(out.len == 11)
    }

    @Test("sync to empty rewinds everything")
    func syncToEmpty() {
        let out = TextOutput(mode: .keypress)
        out.append("hello")
        out.sync(to: "")
        #expect(out.typed == "")
        #expect(out.len == 0)
    }

    @Test("sync is idempotent when run repeatedly on the same target")
    func syncIdempotent() {
        let out = TextOutput(mode: .keypress)
        out.append("clawed code")
        out.sync(to: "Claude Code")
        out.sync(to: "Claude Code")
        out.sync(to: "Claude Code")
        #expect(out.typed == "Claude Code")
    }

    @Test("sync across a streaming sequence with a late correction")
    func syncStreamingSequence() {
        // Simulates partials arriving, with the alias only recognisable
        // once the full phrase is present. Mirrors what the WhisprDaemon
        // partial callback does with `vocab.correct(transcript)`.
        let out = TextOutput(mode: .keypress)
        // First partial: "clawed" alone does not match "clawed code"
        // (which is what the vocab rewrites), so it stays as-is.
        out.sync(to: "clawed")
        #expect(out.typed == "clawed")
        // Second partial: now "clawed code" is present — after vocab
        // substitution the desired text is "Claude Code".
        out.sync(to: "Claude Code")
        #expect(out.typed == "Claude Code")
    }

    @Test("sync handles grapheme clusters correctly")
    func syncUnicode() {
        let out = TextOutput(mode: .keypress)
        out.append("cafe\u{0301}")             // "café" as 4 graphemes
        out.sync(to: "cafe\u{0301} latte")     // extend by " latte"
        #expect(out.len == 10)
    }
}
#endif
