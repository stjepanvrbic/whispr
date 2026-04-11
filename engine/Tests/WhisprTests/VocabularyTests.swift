#if os(macOS)
import Foundation
import Testing

@testable import WhisprLib

@Suite("Vocabulary")
struct VocabularyTests {

    // MARK: - Parsing

    @Test("Empty contents parses to zero entries")
    func parseEmpty() {
        #expect(Vocabulary.parse("") == [])
    }

    @Test("Only comments and blanks parses to zero entries")
    func parseCommentsOnly() {
        let source = """
            # comment
            # another comment

            """
        #expect(Vocabulary.parse(source) == [])
    }

    @Test("Single canonical with no aliases is skipped")
    func parseCanonicalNoAliases() {
        let source = "Claude"
        #expect(Vocabulary.parse(source) == [])
    }

    @Test("Canonical plus aliases parses correctly")
    func parseWithAliases() {
        let source = "Claude|clawed|clode"
        let entries = Vocabulary.parse(source)
        #expect(entries.count == 1)
        #expect(entries[0].canonical == "Claude")
        #expect(entries[0].aliases == ["clawed", "clode"])
    }

    @Test("Leading and trailing whitespace is trimmed from parts")
    func parseWhitespaceTrimmed() {
        let source = "  Claude  |  clawed  |  clode  "
        let entries = Vocabulary.parse(source)
        #expect(entries[0].canonical == "Claude")
        #expect(entries[0].aliases == ["clawed", "clode"])
    }

    @Test("Comments and blank lines are ignored")
    func parseMixedLines() {
        let source = """
            # leading comment
            Claude|clawed
            # another comment

            NVIDIA|in video|invidia
            """
        let entries = Vocabulary.parse(source)
        #expect(entries.count == 2)
        #expect(entries[0].canonical == "Claude")
        #expect(entries[1].canonical == "NVIDIA")
        #expect(entries[1].aliases == ["in video", "invidia"])
    }

    @Test("Duplicate canonicals have their aliases merged in file order")
    func parseMergeDuplicates() {
        let source = """
            Claude|clawed
            Claude|clode
            Claude|cloud|clawed
            """
        let entries = Vocabulary.parse(source)
        #expect(entries.count == 1)
        #expect(entries[0].canonical == "Claude")
        // clawed appears twice in the file but should only be kept once
        #expect(entries[0].aliases == ["clawed", "clode", "cloud"])
    }

    @Test("Malformed empty-canonical line is skipped without poisoning the rest")
    func parseMalformedTolerated() {
        let source = """
            Claude|clawed
            |just aliases
            NVIDIA|in video
            """
        let entries = Vocabulary.parse(source)
        #expect(entries.count == 2)
        #expect(entries[0].canonical == "Claude")
        #expect(entries[1].canonical == "NVIDIA")
    }

    // MARK: - Substitution

    @Test("correct returns input unchanged when no rules match")
    func correctNoMatch() {
        let vocab = Vocabulary(entries: [
            VocabularyEntry(canonical: "Claude", aliases: ["clawed"])
        ])
        #expect(vocab.correct("the quick brown fox") == "the quick brown fox")
    }

    @Test("Case-insensitive alias preserves canonical case in output")
    func correctPreservesCanonicalCase() {
        let vocab = Vocabulary(entries: [
            VocabularyEntry(canonical: "Claude", aliases: ["clawed"])
        ])
        #expect(vocab.correct("I use clawed daily") == "I use Claude daily")
        #expect(vocab.correct("I use Clawed daily") == "I use Claude daily")
        #expect(vocab.correct("I use CLAWED daily") == "I use Claude daily")
    }

    @Test("Word boundary prevents substring matches")
    func correctWordBoundary() {
        let vocab = Vocabulary(entries: [
            VocabularyEntry(canonical: "Claude", aliases: ["clawed"])
        ])
        // "clawedup" should NOT match "clawed" as a substring
        #expect(vocab.correct("clawedup") == "clawedup")
        // But "clawed" as a full word should
        #expect(vocab.correct("clawed") == "Claude")
        // And on a boundary like punctuation
        #expect(vocab.correct("clawed.") == "Claude.")
    }

    @Test("Multi-word alias substitutes the whole phrase")
    func correctMultiWordAlias() {
        let vocab = Vocabulary(entries: [
            VocabularyEntry(canonical: "NVIDIA", aliases: ["in video"])
        ])
        #expect(vocab.correct("I have an in video GPU") == "I have an NVIDIA GPU")
    }

    @Test("Longer alias wins over shorter one when both are registered")
    func correctLengthOrdering() {
        let vocab = Vocabulary(entries: [
            VocabularyEntry(canonical: "Git",    aliases: ["get"]),
            VocabularyEntry(canonical: "GitHub", aliases: ["get hub"])
        ])
        // "get hub" should be matched first and replaced with "GitHub",
        // not "Git Hub" (which would happen if "get" were tried first).
        #expect(vocab.correct("I use get hub every day") == "I use GitHub every day")
    }

    @Test("Canonical form is idempotent under correct")
    func correctIdempotent() {
        let vocab = Vocabulary(entries: [
            VocabularyEntry(canonical: "Claude", aliases: ["clawed", "clode"])
        ])
        // Running on already-corrected text should not mangle it.
        #expect(vocab.correct("Claude") == "Claude")
        #expect(vocab.correct(vocab.correct("I use clawed")) == "I use Claude")
    }

    @Test("Multiple entries apply independently in the same input")
    func correctMultipleRules() {
        let vocab = Vocabulary(entries: [
            VocabularyEntry(canonical: "Claude Code", aliases: ["clawed code"]),
            VocabularyEntry(canonical: "NVIDIA",      aliases: ["in video"]),
            VocabularyEntry(canonical: "PyTorch",     aliases: ["pie torch"])
        ])
        let input = "I use clawed code with pie torch on my in video GPU"
        let expected = "I use Claude Code with PyTorch on my NVIDIA GPU"
        #expect(vocab.correct(input) == expected)
    }

    @Test("Special regex characters in canonical are preserved verbatim")
    func correctCanonicalWithRegexMetacharacters() {
        let vocab = Vocabulary(entries: [
            VocabularyEntry(canonical: "Next.js", aliases: ["next j s"])
        ])
        // The '.' in "Next.js" must appear literally, not as a regex wildcard.
        #expect(vocab.correct("I use next j s") == "I use Next.js")
    }

    @Test("Empty input returns empty output")
    func correctEmptyInput() {
        let vocab = Vocabulary(entries: [
            VocabularyEntry(canonical: "Claude", aliases: ["clawed"])
        ])
        #expect(vocab.correct("") == "")
    }

    @Test("Vocabulary with zero rules is a no-op correct")
    func correctEmptyVocab() {
        let vocab = Vocabulary(entries: [])
        #expect(vocab.correct("hello world") == "hello world")
    }

    // MARK: - File loading

    @Test("load from nonexistent file returns nil")
    func loadMissing() {
        let url = URL(fileURLWithPath: "/tmp/whispr-vocab-nonexistent-\(UUID()).txt")
        #expect(Vocabulary.load(from: url) == nil)
    }

    @Test("load from empty file returns nil")
    func loadEmpty() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("whispr-vocab-\(UUID()).txt")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try "".write(to: tmp, atomically: true, encoding: .utf8)
        #expect(Vocabulary.load(from: tmp) == nil)
    }

    @Test("load from comments-only file returns nil")
    func loadCommentsOnly() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("whispr-vocab-\(UUID()).txt")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try "# just a comment\n".write(to: tmp, atomically: true, encoding: .utf8)
        #expect(Vocabulary.load(from: tmp) == nil)
    }

    @Test("load from valid file correctly substitutes")
    func loadValidFile() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("whispr-vocab-\(UUID()).txt")
        defer { try? FileManager.default.removeItem(at: tmp) }

        try """
            # test vocab
            Claude Code|clawed code
            NVIDIA|in video
            """.write(to: tmp, atomically: true, encoding: .utf8)

        let vocab = Vocabulary.load(from: tmp)
        #expect(vocab != nil)
        #expect(vocab?.correct("clawed code on in video") == "Claude Code on NVIDIA")
    }
}
#endif
