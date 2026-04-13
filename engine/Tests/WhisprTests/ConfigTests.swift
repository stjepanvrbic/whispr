#if os(macOS)
import Foundation
import Testing

@testable import WhisprLib

@Suite("Config")
struct ConfigTests {

    private func decode(_ json: String) throws -> Config {
        try JSONDecoder().decode(Config.self, from: Data(json.utf8))
    }

    // MARK: - Defaults

    @Test("Default config has expected values")
    func defaults() {
        let c = Config()
        #expect(c.enabled == true)
        #expect(c.hotkey == .option)
        #expect(c.outputMode == .clipboard)
        #expect(c.idleTimeout == 3600)
        #expect(c.chunkSize == .ms560)
        #expect(c.vocabularyEnabled == true)
    }

    // MARK: - Decoding

    @Test("Decode full JSON")
    func decodeFull() throws {
        let c = try decode("""
            {"enabled":false,"hotkey":"command","output_mode":"clipboard","idle_timeout":0,"chunk_size":1120,"vocabulary_enabled":false}
            """)
        #expect(c.enabled == false)
        #expect(c.hotkey == .command)
        #expect(c.outputMode == .clipboard)
        #expect(c.idleTimeout == 0)
        #expect(c.chunkSize == .ms1120)
        #expect(c.vocabularyEnabled == false)
    }

    @Test("Missing keys fall back to defaults")
    func decodePartial() throws {
        let c = try decode(#"{"output_mode":"clipboard"}"#)
        #expect(c.outputMode == .clipboard)
        #expect(c.enabled == true)
        #expect(c.hotkey == .option)
        #expect(c.idleTimeout == 3600)
        #expect(c.chunkSize == .ms560)
        #expect(c.vocabularyEnabled == true)
    }

    @Test("Invalid per-field values fall back to defaults (tolerant decoding)")
    func decodeInvalidPerField() throws {
        // An invalid chunk_size and a valid idle_timeout — idle_timeout
        // should survive because each field decodes independently.
        let c = try decode(#"{"chunk_size":999,"idle_timeout":120,"vocabulary_enabled":"sure"}"#)
        #expect(c.chunkSize == .ms560)           // fell back
        #expect(c.idleTimeout == 120)            // preserved
        #expect(c.vocabularyEnabled == true)     // fell back (string, not bool)
    }

    @Test("Invalid hotkey and output_mode also tolerated")
    func decodeInvalidHotkey() throws {
        let c = try decode(#"{"hotkey":"bananas","output_mode":"yodel"}"#)
        #expect(c.hotkey == .option)
        #expect(c.outputMode == .clipboard)
    }

    @Test("Empty JSON object uses defaults")
    func decodeEmpty() throws {
        #expect(try decode("{}") == Config())
    }

    @Test("Invalid JSON root: load() returns defaults")
    func loadInvalid() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("whispr-\(UUID()).json")
        try "not json".write(to: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }
        #expect(Config.load(from: tmp) == Config())
    }

    // MARK: - File I/O

    @Test("Load from nonexistent file returns defaults")
    func loadMissing() {
        let url = URL(fileURLWithPath: "/tmp/whispr-nonexistent-\(UUID()).json")
        #expect(Config.load(from: url) == Config())
    }

    @Test("Load from a valid file round-trips")
    func loadFromFile() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("whispr-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: tmp) }

        try #"{"hotkey":"shift","idle_timeout":42}"#
            .write(to: tmp, atomically: true, encoding: .utf8)

        let c = Config.load(from: tmp)
        #expect(c.hotkey == .shift)
        #expect(c.idleTimeout == 42)
    }

    @Test("save() then load() round-trips all fields")
    func saveLoadRoundTrip() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("whispr-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let original = Config(
            enabled: false,
            hotkey: .rightOption,
            outputMode: .clipboard,
            idleTimeout: 120,
            chunkSize: .ms1120,
            vocabularyEnabled: false
        )
        try original.save(to: tmp)
        #expect(Config.load(from: tmp) == original)
    }

    // MARK: - Encoding

    @Test("Encoded JSON uses snake_case keys for compound names")
    func snakeCaseEncoding() throws {
        let c = Config(
            enabled: true,
            hotkey: .rightOption,
            outputMode: .clipboard,
            idleTimeout: 99,
            chunkSize: .ms1120,
            vocabularyEnabled: false
        )
        let data = try JSONEncoder().encode(c)
        let dict = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(dict["enabled"] as? Bool == true)
        #expect(dict["hotkey"] as? String == "right_option")
        #expect(dict["output_mode"] as? String == "clipboard")
        #expect(dict["idle_timeout"] as? Int == 99)
        #expect(dict["chunk_size"] as? Int == 1120)
        #expect(dict["vocabulary_enabled"] as? Bool == false)
        #expect(dict["outputMode"] == nil)
        #expect(dict["idleTimeout"] == nil)
        #expect(dict["vocabularyEnabled"] == nil)
    }

    @Test("Config round-trips through JSONEncoder/JSONDecoder")
    func encoderRoundTrip() throws {
        let original = Config(
            enabled: false,
            hotkey: .fn,
            outputMode: .keypress,
            idleTimeout: 42,
            chunkSize: .ms1120,
            vocabularyEnabled: false
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Config.self, from: data)
        #expect(decoded == original)
    }
}
#endif
