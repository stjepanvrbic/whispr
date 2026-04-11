#if os(macOS)
import Foundation

/// One entry from the vocabulary file: the canonical spelling plus every
/// alias (mis-transcription) that should be rewritten to it.
public struct VocabularyEntry: Sendable, Equatable {
    public let canonical: String
    public let aliases: [String]

    public init(canonical: String, aliases: [String]) {
        self.canonical = canonical
        self.aliases = aliases
    }
}

/// Literal alias → canonical substitution layer applied to the streaming
/// transcript that `StreamingNemotronAsrManager` emits.
///
/// The user curates a plain-text file at `~/.whispr/vocabulary.txt` where
/// each line is `canonical|alias1|alias2|…`. Whispr loads this at startup
/// and runs `correct(_:)` on every partial and on the finalised transcript
/// before the text reaches the active app.
///
/// Matching is case-insensitive and word-boundary aware (via
/// `NSRegularExpression` with `\b`), so an alias only rewrites when it
/// appears as a whole word — `clawed` does not match `clawedup`. The
/// canonical form's exact spelling is preserved in the output.
///
/// Aliases are applied in order of **descending character length** so that
/// longer aliases win over shorter ones they might contain — matching
/// `get hub` before `get`, for example.
public final class Vocabulary: @unchecked Sendable {
    public static let vocabularyFile = Config.configDir
        .appendingPathComponent("vocabulary.txt")

    public let entries: [VocabularyEntry]

    /// Precompiled (regex, canonical replacement template) pairs, sorted so
    /// that longer aliases are tried first.
    private let rules: [(regex: NSRegularExpression, template: String)]

    public init(entries: [VocabularyEntry]) {
        self.entries = entries
        self.rules = Self.buildRules(from: entries)
    }

    // MARK: - Loading

    /// Parse the vocabulary file at `url`. Returns `nil` if the file is
    /// missing, unreadable, or contains zero usable entries. Malformed
    /// lines are logged and skipped — one bad line does not poison the
    /// whole file.
    public static func load(from url: URL = vocabularyFile) -> Vocabulary? {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else {
            log("Vocabulary: could not read \(url.path)")
            return nil
        }
        let entries = parse(contents)
        guard !entries.isEmpty else { return nil }
        return Vocabulary(entries: entries)
    }

    /// Parse vocabulary file contents into entries. Exposed internally so
    /// tests can round-trip strings without touching the filesystem.
    static func parse(_ contents: String) -> [VocabularyEntry] {
        var byCanonical: [String: [String]] = [:]
        // Preserve first-seen order so the file's author controls ordering
        // when canonicals are duplicated across sections.
        var order: [String] = []

        for (index, rawLine) in contents.split(
            omittingEmptySubsequences: false,
            whereSeparator: { $0 == "\n" || $0 == "\r\n" || $0 == "\r" }
        ).enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }

            let parts = line.split(separator: "|", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }

            guard let canonical = parts.first, !canonical.isEmpty else {
                log("Vocabulary: skipping malformed line \(index + 1): \"\(line)\"")
                continue
            }

            let aliases = parts.dropFirst().filter { !$0.isEmpty }
            if aliases.isEmpty {
                log("Vocabulary: entry \"\(canonical)\" on line \(index + 1) has no aliases — ignored")
                continue
            }

            if byCanonical[canonical] == nil {
                order.append(canonical)
                byCanonical[canonical] = []
            }
            byCanonical[canonical]?.append(contentsOf: aliases)
        }

        return order.map { canonical in
            // De-duplicate aliases while preserving order.
            var seen = Set<String>()
            let unique = (byCanonical[canonical] ?? []).filter { alias in
                seen.insert(alias.lowercased()).inserted
            }
            return VocabularyEntry(canonical: canonical, aliases: unique)
        }
    }

    // MARK: - Rule compilation

    private static func buildRules(
        from entries: [VocabularyEntry]
    ) -> [(regex: NSRegularExpression, template: String)] {
        // Flatten to (alias, canonical) pairs, then sort by descending
        // alias length so `get hub` beats `get`.
        var pairs: [(alias: String, canonical: String)] = []
        for entry in entries {
            for alias in entry.aliases {
                pairs.append((alias: alias, canonical: entry.canonical))
            }
        }
        pairs.sort { $0.alias.count > $1.alias.count }

        var rules: [(regex: NSRegularExpression, template: String)] = []
        for pair in pairs {
            let escaped = NSRegularExpression.escapedPattern(for: pair.alias)
            let pattern = "\\b" + escaped + "\\b"
            guard let regex = try? NSRegularExpression(
                pattern: pattern,
                options: [.caseInsensitive]
            ) else {
                log("Vocabulary: failed to compile regex for alias \"\(pair.alias)\" — skipping")
                continue
            }
            let template = NSRegularExpression.escapedTemplate(for: pair.canonical)
            rules.append((regex: regex, template: template))
        }
        return rules
    }

    // MARK: - Substitution

    /// Apply every alias rule to `text`, returning the corrected string.
    /// Idempotent — running `correct` on an already-corrected string is a
    /// no-op, because canonical forms don't themselves match any alias in
    /// a well-formed vocabulary.
    public func correct(_ text: String) -> String {
        guard !rules.isEmpty, !text.isEmpty else { return text }
        var result = text
        for rule in rules {
            let range = NSRange(result.startIndex..., in: result)
            result = rule.regex.stringByReplacingMatches(
                in: result,
                options: [],
                range: range,
                withTemplate: rule.template
            )
        }
        return result
    }
}
#endif
