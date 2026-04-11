#if os(macOS)
import Foundation
import Testing

@testable import WhisprLib

@Suite("UpdaterPaths")
struct UpdaterPathsTests {

    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("whispr-updater-\(UUID())")
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("Missing source_path returns nil")
    func missingFile() {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(UpdaterPaths.sourcePath(in: dir) == nil)
    }

    @Test("Empty source_path returns nil")
    func emptyFile() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try "".write(
            to: UpdaterPaths.sourcePathFile(in: dir),
            atomically: true, encoding: .utf8
        )
        #expect(UpdaterPaths.sourcePath(in: dir) == nil)
    }

    @Test("Whitespace-only source_path returns nil")
    func whitespaceOnly() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try "   \n\n  ".write(
            to: UpdaterPaths.sourcePathFile(in: dir),
            atomically: true, encoding: .utf8
        )
        #expect(UpdaterPaths.sourcePath(in: dir) == nil)
    }

    @Test("Valid source_path returns trimmed contents")
    func validPath() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try "/Users/alice/whispr\n".write(
            to: UpdaterPaths.sourcePathFile(in: dir),
            atomically: true, encoding: .utf8
        )
        #expect(UpdaterPaths.sourcePath(in: dir) == "/Users/alice/whispr")
    }

    @Test("Trailing newlines and surrounding whitespace are trimmed")
    func trimming() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try "  /var/tmp/w  \n".write(
            to: UpdaterPaths.sourcePathFile(in: dir),
            atomically: true, encoding: .utf8
        )
        #expect(UpdaterPaths.sourcePath(in: dir) == "/var/tmp/w")
    }
}

@Suite("ProcessRunner (real runner, safe commands only)")
struct ProcessRunnerTests {

    // Sanity test that the real bash runner correctly captures stdout
    // and returns the exit code. Uses only safe, read-only commands.
    @Test("Runs bash, captures stdout, returns exit code 0")
    func runsBashAndCapturesOutput() async throws {
        let runner = RealProcessRunner()
        let lines = LineCollector()
        let code = try await runner.runBash(
            script: "echo hello; echo world",
            cwd: FileManager.default.temporaryDirectory.path,
            onLine: { line in lines.append(line) }
        )
        #expect(code == 0)
        let collected = lines.all()
        #expect(collected.contains("hello"))
        #expect(collected.contains("world"))
    }

    @Test("Non-zero exit code is returned")
    func nonZeroExit() async throws {
        let runner = RealProcessRunner()
        let code = try await runner.runBash(
            script: "exit 7",
            cwd: FileManager.default.temporaryDirectory.path,
            onLine: { _ in }
        )
        #expect(code == 7)
    }
}

/// Thread-safe line collector for async tests.
private final class LineCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    func append(_ s: String) { lock.lock(); lines.append(s); lock.unlock() }
    func all() -> [String] { lock.lock(); defer { lock.unlock() }; return lines }
}
#endif
