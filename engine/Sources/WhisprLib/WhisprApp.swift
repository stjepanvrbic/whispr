#if os(macOS)
import AppKit
import AVFoundation
import FluidAudio
import Foundation

/// Public entry point. Replaces the old `WhisprLib.run()` free function.
///
/// Drives the process via NSApplication so we can install an NSStatusItem.
/// `LSUIElement=true` stays in Info.plist — that's the correct setting for
/// a menu-bar-only app (no Dock icon, status item still works).
public enum WhisprApp {
    @MainActor
    public static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}

/// Owns the long-lived components for the whole process. Deliberately
/// holds strong references so nothing gets deallocated while the app runs.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var whispr: Whispr!
    private var statusBar: StatusBar!
    private var signalSources: [DispatchSourceSignal] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        let config = Config.load()
        log("Config: enabled=\(config.enabled) hotkey=\(config.hotkey.rawValue) " +
            "output=\(config.outputMode.rawValue) idle=\(config.idleTimeout)s " +
            "chunk=\(config.chunkSize.rawValue)ms")

        ensureMicrophone()

        let manager = StreamingNemotronAsrManager(
            requestedChunkSize: config.chunkSize.nemotron
        )

        whispr = Whispr(config: config, manager: manager)
        statusBar = StatusBar(whispr: whispr)
        whispr.onStateChange = { [weak statusBar] state in
            statusBar?.setState(state)
        }
        statusBar.setState(whispr.state)

        whispr.install()
        whispr.loadModelsIfNeeded()

        // Clean shutdown on SIGTERM / SIGINT — NSApp.terminate unwinds
        // NSApp.run() so applicationWillTerminate gets a chance to fire.
        signalSources = [
            installShutdownSignal(SIGTERM),
            installShutdownSignal(SIGINT),
        ]

        log("whispr ready — hold \(config.hotkey.displayName) to record, Escape to cancel")
    }

    func applicationWillTerminate(_ notification: Notification) {
        log("Shutting down")
        whispr?.shutdown()
    }
}

// MARK: - Permissions

/// Request microphone access if not already determined.
///
/// Accessibility permission is not pre-checked here — CGEvent.tapCreate
/// fails loudly and `KeyboardMonitor.install()` polls for it with clear
/// user-facing instructions in the log.
private func ensureMicrophone() {
    switch AVCaptureDevice.authorizationStatus(for: .audio) {
    case .authorized:
        log("Microphone ✓")
    case .notDetermined:
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            log(granted ? "Microphone ✓" : "Microphone permission denied")
        }
    default:
        log("""
            WARNING: Microphone permission denied. Grant it manually:
              1. Open System Settings > Privacy & Security > Microphone
              2. Find 'Whispr' and toggle it ON
              3. Restart whispr: launchctl kickstart -k gui/$(id -u)/com.whispr.daemon
            """)
    }
}

// MARK: - Signal handling

@MainActor
private func installShutdownSignal(_ sig: Int32) -> DispatchSourceSignal {
    let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    src.setEventHandler {
        log("Received signal \(sig)")
        // The handler runs on the main queue, so we're actually on the
        // main actor — just need to tell the compiler.
        MainActor.assumeIsolated { NSApp.terminate(nil) }
    }
    src.resume()
    signal(sig, SIG_IGN)    // swallow the default handler
    return src
}
#endif
