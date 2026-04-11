#if os(macOS)
import Foundation
import Testing

@testable import WhisprLib

@Suite("TextOutput length tracking")
struct TextOutputTests {

    // We test the length tracking logic, not the actual CGEvent posting
    // (which requires Accessibility permission and a display session).
    //
    // TextOutput.len is the single source of truth for "how much of the
    // current transcript we've already typed" — Whispr.onKeyDown uses it
    // to compute the monotonic diff for partial callbacks.

    @Test("Initial length is zero")
    func initialLen() {
        #expect(TextOutput(mode: .keypress).len == 0)
    }

    @Test("Append increases length by grapheme-cluster count")
    func appendLen() {
        let out = TextOutput(mode: .keypress)
        out.append("hello")
        #expect(out.len == 5)
        out.append(" world")
        #expect(out.len == 11)
    }

    @Test("Append with empty string is a no-op")
    func appendEmpty() {
        let out = TextOutput(mode: .keypress)
        out.append("abc")
        out.append("")
        #expect(out.len == 3)
    }

    @Test("cancel() resets length to zero")
    func cancelLen() {
        let out = TextOutput(mode: .keypress)
        out.append("hello world")
        out.cancel()
        #expect(out.len == 0)
    }

    @Test("cancel() on empty is a no-op")
    func cancelEmpty() {
        let out = TextOutput(mode: .keypress)
        out.cancel()
        #expect(out.len == 0)
    }

    @Test("clear() resets length without backspacing")
    func clearLen() {
        let out = TextOutput(mode: .keypress)
        out.append("hello")
        out.clear()
        #expect(out.len == 0)
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
        #expect(out.len == "The quick brown fox".count)
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
    }
}
#endif
