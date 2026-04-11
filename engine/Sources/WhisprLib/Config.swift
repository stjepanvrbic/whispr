#if os(macOS)
import Foundation

/// How Whispr types the transcribed text into the active app.
public enum OutputMode: String, Codable, Sendable, CaseIterable {
    case keypress     // per-character unicode keydown/up events
    case clipboard    // NSPasteboard + Cmd+V

    public var displayName: String {
        switch self {
        case .keypress:  return "Type keys"
        case .clipboard: return "Paste via clipboard"
        }
    }
}

/// Nemotron streaming chunk size. Raw value is the duration in milliseconds.
public enum ChunkSize: Int, Codable, Sendable, CaseIterable {
    case ms560  = 560     // balanced latency / accuracy
    case ms1120 = 1120    // best accuracy, slightly higher latency

    public var displayName: String {
        switch self {
        case .ms560:  return "560 ms (balanced)"
        case .ms1120: return "1120 ms (best accuracy)"
        }
    }
}

/// On-disk configuration. Lives at `~/.whispr/config.json`.
///
/// All fields are optional in the JSON — missing keys fall back to the
/// defaults declared here, and invalid values are tolerated per-field
/// (the field reverts to default instead of failing the whole load).
public struct Config: Codable, Sendable, Equatable {
    public var enabled: Bool            = true
    public var hotkey: HotkeyModifier   = .option
    public var outputMode: OutputMode   = .keypress
    public var idleTimeout: Int         = 3600       // seconds; 0 = never unload
    public var chunkSize: ChunkSize     = .ms560

    public init(
        enabled: Bool = true,
        hotkey: HotkeyModifier = .option,
        outputMode: OutputMode = .keypress,
        idleTimeout: Int = 3600,
        chunkSize: ChunkSize = .ms560
    ) {
        self.enabled = enabled
        self.hotkey = hotkey
        self.outputMode = outputMode
        self.idleTimeout = idleTimeout
        self.chunkSize = chunkSize
    }

    enum CodingKeys: String, CodingKey {
        case enabled
        case hotkey
        case outputMode  = "output_mode"
        case idleTimeout = "idle_timeout"
        case chunkSize   = "chunk_size"
    }

    // Per-field tolerant decoding: a malformed value for one field falls
    // back to that field's default instead of nuking the whole config.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.enabled     = (try? c.decodeIfPresent(Bool.self,           forKey: .enabled))     ?? true
        self.hotkey      = (try? c.decodeIfPresent(HotkeyModifier.self, forKey: .hotkey))      ?? .option
        self.outputMode  = (try? c.decodeIfPresent(OutputMode.self,     forKey: .outputMode))  ?? .keypress
        self.idleTimeout = (try? c.decodeIfPresent(Int.self,            forKey: .idleTimeout)) ?? 3600
        self.chunkSize   = (try? c.decodeIfPresent(ChunkSize.self,      forKey: .chunkSize))   ?? .ms560
    }

    // MARK: - Filesystem

    public static let configDir  = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".whispr")
    public static let configFile = configDir.appendingPathComponent("config.json")

    /// Load from the canonical path, returning defaults if the file is
    /// missing or unreadable.
    public static func load() -> Config {
        load(from: configFile)
    }

    public static func load(from url: URL) -> Config {
        guard
            FileManager.default.fileExists(atPath: url.path),
            let data = try? Data(contentsOf: url),
            let config = try? JSONDecoder().decode(Config.self, from: data)
        else {
            return Config()
        }
        return config
    }

    /// Write the config atomically to the canonical path.
    public func save() throws {
        try save(to: Self.configFile)
    }

    public func save(to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        try data.write(to: url, options: .atomic)
    }
}
#endif
