#if os(macOS)
import Foundation
import Testing

@testable import WhisprLib

@Suite("Partial transcript diffing")
struct PartialTranscriptTests {

    // This tests the core logic from the partialCallback in WhisprDaemon.swift:
    //   let newText = String(transcript.dropFirst(lastOutputLen))
    // The diff logic determines what new text to type based on the
    // full transcript and how much we've already output.

    func computeNewText(transcript: String, lastOutputLen: Int) -> (newText: String, newLen: Int) {
        let newText = String(transcript.dropFirst(lastOutputLen))
        return (newText, transcript.count)
    }

    @Test("First partial from empty state")
    func firstPartial() {
        let (text, len) = computeNewText(transcript: "Hello", lastOutputLen: 0)
        #expect(text == "Hello")
        #expect(len == 5)
    }

    @Test("Incremental append from existing text")
    func incrementalAppend() {
        let (text, len) = computeNewText(transcript: "Hello world", lastOutputLen: 5)
        #expect(text == " world")
        #expect(len == 11)
    }

    @Test("No new text when transcript unchanged")
    func noChange() {
        let (text, _) = computeNewText(transcript: "Hello", lastOutputLen: 5)
        #expect(text == "")
    }

    @Test("Multiple incremental steps")
    func multipleSteps() {
        var lastLen = 0

        let (t1, l1) = computeNewText(transcript: "The", lastOutputLen: lastLen)
        #expect(t1 == "The")
        lastLen = l1

        let (t2, l2) = computeNewText(transcript: "The quick", lastOutputLen: lastLen)
        #expect(t2 == " quick")
        lastLen = l2

        let (t3, l3) = computeNewText(transcript: "The quick brown fox", lastOutputLen: lastLen)
        #expect(t3 == " brown fox")
        lastLen = l3

        #expect(lastLen == 19)
    }

    @Test("Single character increments")
    func singleCharSteps() {
        var lastLen = 0
        for (i, char) in "abc".enumerated() {
            let full = String("abc".prefix(i + 1))
            let (text, newLen) = computeNewText(transcript: full, lastOutputLen: lastLen)
            #expect(text == String(char))
            lastLen = newLen
        }
        #expect(lastLen == 3)
    }

    @Test("Final transcript extends partials — no replace needed")
    func finalExtendsPartials() {
        // Simulates a full session: partials stream in, then finish() returns final.
        // Since RNNT is monotonic, final only extends what was already output.
        var lastLen = 0

        // Partials during recording
        let partials = ["Wait,", "Wait, does this", "Wait, does this actually work"]
        for partial in partials {
            let (text, newLen) = computeNewText(transcript: partial, lastOutputLen: lastLen)
            #expect(!text.isEmpty)
            lastLen = newLen
        }
        #expect(lastLen == "Wait, does this actually work".count)

        // Final from finish() — same or longer than last partial
        let final = "Wait, does this actually work?"
        let (remaining, _) = computeNewText(transcript: final, lastOutputLen: lastLen)
        // Only the "?" needs to be appended, not the whole thing
        #expect(remaining == "?")
    }

    @Test("Final identical to last partial appends nothing")
    func finalIdenticalToLastPartial() {
        var lastLen = 0
        let (_, l) = computeNewText(transcript: "Hello world", lastOutputLen: lastLen)
        lastLen = l

        let (remaining, _) = computeNewText(transcript: "Hello world", lastOutputLen: lastLen)
        #expect(remaining == "")
    }
}
#endif
