#if os(macOS)
import AppKit
import Foundation

/// Self-updates Whispr from its original git clone.
///
/// Flow: read `~/.whispr/source_path` (written by setup.sh), cd there,
/// run `git fetch && git pull --ff-only && bash setup.sh` via a single
/// bash process. Stdout/stderr stream into a scrollable NSTextView.
/// setup.sh ends by `launchctl kickstart -k`ing the daemon, which
/// replaces this process with the freshly built binary.
@MainActor
final class Updater {
    private var runner: ProcessRunner = RealProcessRunner()
    private var window: UpdaterWindow?

    func run() {
        if let window {
            window.bringToFront()
            return
        }
        let w = UpdaterWindow()
        w.onClose = { [weak self] in self?.window = nil }
        w.show()
        window = w

        guard let source = UpdaterPaths.sourcePath() else {
            w.append("""
                Can't find the Whispr source clone.

                Whispr looks for your clone path in:
                    \(UpdaterPaths.sourcePathFile().path)

                Re-run `bash setup.sh` once from your clone directory and
                updates will work from this menu from then on.
                """)
            w.markFinished(success: false)
            return
        }

        w.append("Updating from \(source)…\n")

        // Bridge the background-thread line callbacks from ProcessRunner
        // into a main-actor-safe stream consumed by the window.
        let (lineStream, lineCont) = AsyncStream.makeStream(of: String.self)
        let runner = self.runner
        let script = "git fetch && git pull --ff-only && bash setup.sh"

        Task { [weak w] in
            for await line in lineStream {
                w?.append(line + "\n")
            }
        }

        Task { [weak self, weak w] in
            do {
                let code = try await runner.runBash(
                    script: script,
                    cwd: source,
                    onLine: { line in lineCont.yield(line) }
                )
                if code == 0 {
                    lineCont.yield("\n✓ Update complete. Whispr is restarting…")
                } else {
                    lineCont.yield("\n✗ Update failed with exit code \(code)")
                }
                lineCont.finish()
                await self?.markDone(success: code == 0, window: w)
            } catch {
                lineCont.yield("\n✗ Update failed: \(error)")
                lineCont.finish()
                await self?.markDone(success: false, window: w)
            }
        }
    }

    private func markDone(success: Bool, window: UpdaterWindow?) {
        window?.markFinished(success: success)
    }
}

// MARK: - Pure path helpers (unit-testable)

enum UpdaterPaths {
    static let defaultBase = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".whispr")

    static func sourcePathFile(in baseDir: URL = defaultBase) -> URL {
        baseDir.appendingPathComponent("source_path")
    }

    static func sourcePath(in baseDir: URL = defaultBase) -> String? {
        let url = sourcePathFile(in: baseDir)
        guard
            let data = try? Data(contentsOf: url),
            let raw = String(data: data, encoding: .utf8)
        else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

// MARK: - Process runner (protocol + real impl)

protocol ProcessRunner: Sendable {
    func runBash(
        script: String,
        cwd: String,
        onLine: @escaping @Sendable (String) -> Void
    ) async throws -> Int32
}

struct RealProcessRunner: ProcessRunner {
    func runBash(
        script: String,
        cwd: String,
        onLine: @escaping @Sendable (String) -> Void
    ) async throws -> Int32 {
        try await withCheckedThrowingContinuation { cont in
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/bin/bash")
            proc.arguments = ["-lc", script]
            proc.currentDirectoryURL = URL(fileURLWithPath: cwd)

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            proc.standardOutput = stdoutPipe
            proc.standardError = stderrPipe

            let emit: @Sendable (Data) -> Void = { data in
                guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
                text.split(whereSeparator: { $0 == "\n" || $0 == "\r" })
                    .forEach { onLine(String($0)) }
            }
            let forwarder: @Sendable (FileHandle) -> Void = { handle in
                emit(handle.availableData)
            }
            stdoutPipe.fileHandleForReading.readabilityHandler = forwarder
            stderrPipe.fileHandleForReading.readabilityHandler = forwarder

            proc.terminationHandler = { p in
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                stderrPipe.fileHandleForReading.readabilityHandler = nil
                // Drain anything the readability handler missed between its
                // last callback and the process exiting.
                emit(stdoutPipe.fileHandleForReading.readDataToEndOfFile())
                emit(stderrPipe.fileHandleForReading.readDataToEndOfFile())
                cont.resume(returning: p.terminationStatus)
            }

            do {
                try proc.run()
            } catch {
                cont.resume(throwing: error)
            }
        }
    }
}

// MARK: - Updater window

@MainActor
private final class UpdaterWindow {
    var onClose: (() -> Void)?
    private let window: NSWindow
    private let textView: NSTextView
    private let closeButton: NSButton

    init() {
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 420),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        w.title = "Updating Whispr"
        w.isReleasedWhenClosed = false

        let container = NSView(frame: w.contentView!.bounds)
        container.autoresizingMask = [.width, .height]

        let scroll = NSScrollView(frame: NSRect(
            x: 12, y: 48, width: container.bounds.width - 24, height: container.bounds.height - 60
        ))
        scroll.autoresizingMask = [.width, .height]
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder

        let tv = NSTextView(frame: scroll.bounds)
        tv.autoresizingMask = [.width]
        tv.isEditable = false
        tv.isRichText = false
        tv.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        tv.textContainerInset = NSSize(width: 6, height: 6)
        scroll.documentView = tv

        container.addSubview(scroll)

        let close = NSButton(
            frame: NSRect(x: container.bounds.width - 92, y: 12, width: 80, height: 28)
        )
        close.autoresizingMask = [.minXMargin]
        close.bezelStyle = .rounded
        close.title = "Close"
        close.isEnabled = false
        container.addSubview(close)

        w.contentView = container

        self.window = w
        self.textView = tv
        self.closeButton = close

        close.target = self
        close.action = #selector(handleClose)
    }

    func show() {
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func bringToFront() {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func append(_ line: String) {
        textView.textStorage?.append(NSAttributedString(
            string: line,
            attributes: [.font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)]
        ))
        textView.scrollToEndOfDocument(nil)
    }

    func markFinished(success: Bool) {
        closeButton.isEnabled = true
    }

    @objc private func handleClose() {
        window.close()
        onClose?()
    }
}
#endif
