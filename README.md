# whispr

Push-to-talk voice transcription for macOS. Hold **Option**, speak, release — text appears wherever your cursor is, streaming in real time as you talk.

Runs entirely on-device using [FluidAudio](https://github.com/FluidInference/FluidAudio)'s streaming implementation of NVIDIA's [Nemotron Speech Streaming 0.6B](https://huggingface.co/FluidInference/nemotron-speech-streaming-en-0.6b-coreml) on Apple's Neural Engine. Your audio never leaves your machine.

## Install

### One-liner

```bash
git clone https://github.com/stjepanvrbic/whispr.git && cd whispr && ./setup.sh
```

### Manual

If you'd rather inspect the setup script before running it:

```bash
git clone https://github.com/stjepanvrbic/whispr.git
cd whispr
less setup.sh          # have a look
bash setup.sh          # then run it
```

### With Claude Code

Paste this into a Claude Code session and it'll install everything for you:

> Clone https://github.com/stjepanvrbic/whispr.git into `~/whispr` and run `bash setup.sh` inside it. When setup.sh prints the permission instructions, stop and tell me exactly which permissions I need to grant in System Settings before continuing. Once I've confirmed, verify the LaunchAgent is running with `launchctl print gui/$(id -u)/com.whispr.daemon` and tail `/tmp/whispr.log` until you see "Models loaded ✓". Then tell me what's in the menu bar icon's menu.

---

The setup script builds the Swift engine, creates a stable code signing identity, installs the `.app` bundle into `~/.whispr`, and registers the LaunchAgent. The Nemotron model (~600 MB) downloads automatically on first launch.

On first launch, macOS will prompt for **Accessibility** and **Microphone** permissions — grant both. After that, permissions persist across all future updates (the stable code signing identity makes sure of it).

### Requirements

- macOS 14+ on Apple Silicon
- Xcode or Xcode Command Line Tools (`xcode-select --install`)

## Using it

Once installed, look for the **waveform icon in your menu bar** — that's Whispr.

| Action | What happens |
|---|---|
| **Hold Option** | Starts recording. Text streams into the active app as you speak. |
| **Release Option** | Finalizes the transcript — any trailing words are appended. |
| **Press Escape** | Cancels the current recording and deletes any streamed text. |
| **Click the menu bar icon** | Opens the menu (left or right click both work). |

### The menu

```
Whispr
Status: Ready | Recording… | Loading model… | Idle (model unloaded) | Disabled
─────────
Enabled  ✓           ← click to toggle recording on/off
─────────
Preferences…         ← opens a settings window
Update Whispr…       ← git pull + rebuild + restart
─────────
Quit Whispr
```

Toggling **Enabled** off unloads the model from RAM and disables the hotkey, but keeps the icon in your menu bar. Toggling back on re-enables the hotkey — the model is reloaded on your next press (fast, about a second).

## Configuration

Open **Preferences…** from the menu bar icon to change any of these live:

| Field | Default | Description |
|---|---|---|
| **Hotkey** | Option | The modifier key you hold to record. Choices: Option, Command, Control, Shift, Fn, Right Option, Right Command. |
| **Output** | Type keys | `Type keys` simulates each character; `Paste via clipboard` uses NSPasteboard + Cmd+V (faster for long transcripts). |
| **Idle timeout** | 3600 s (1 hour) | Seconds of inactivity before Whispr unloads the model to free RAM. `0` = never unload. |
| **Chunk size** | 560 ms | Nemotron streaming chunk: `560` (balanced) or `1120` (best accuracy). Applies on next model load. |

Changes are applied immediately and saved to `~/.whispr/config.json` — no restart needed. You can also edit the JSON directly if you prefer.

**About the idle timeout:** Whispr unloads the Nemotron model after 1 hour of inactivity to free RAM. The next press after that reloads the model in the background (~1 second on an M-series Mac) while your audio is captured in memory — you won't lose the first words.

## Updating

Click **Update Whispr…** from the menu bar icon. Whispr will `git pull --ff-only` in the directory you originally cloned into, re-run `setup.sh`, and restart the daemon. A small window streams the output so you can watch it go.

If the updater says it can't find your clone, run `bash setup.sh` once from the clone directory — that records the location for future updates.

Prefer the command line? Just `cd` into your clone and `bash setup.sh` — same thing.

## Architecture

Single pure-Swift process. No Python, no IPC, no polling — true streaming with the Nemotron RNNT encoder's cache-aware state propagation.

```
┌──────────────────────────────────────────────────────────────────────┐
│  whispr-engine (LaunchAgent, inside Whispr.app)                      │
│  ─ NSApplication main loop (.accessory — no Dock, menu bar only)     │
│                                                                      │
│  ┌──────────────┐   ┌──────────────┐   ┌────────────────┐            │
│  │  StatusBar   │   │  CGEventTap  │   │  AVAudioEngine │            │
│  │  (menu,      │   │  (Hotkey +   │   │  (mic input)   │            │
│  │   Preferences│   │   Escape)    │   └───────┬────────┘            │
│  │   Updater)   │   └──────┬───────┘           ▼                     │
│  └──────────────┘          │            ┌──────────────┐             │
│                            ▼            │  StreamingNem│             │
│                     ┌──────────────┐    │  otronAsr-   │             │
│                     │   Whispr     │───►│   Manager    │             │
│                     │ (orchestrator│    │ (FluidAudio) │             │
│                     │  + load gate)│    └──────┬───────┘             │
│                     └──────┬───────┘           │                     │
│                            ▼                   │                     │
│                     ┌──────────────┐◄──────────┘                     │
│                     │  CGEvent     │   partial transcript callback   │
│                     │  keypresses  │                                 │
│                     └──────────────┘                                 │
└──────────────────────────────────────────────────────────────────────┘
```

Audio flows from `AVAudioEngine` through an `AsyncStream` into `StreamingNemotronAsrManager`. The manager processes 560 ms chunks with encoder cache states, emitting partial transcripts as RNNT tokens are decoded. Each new token is typed into the active app immediately — because RNNT is monotonic, tokens never revise, so no backspacing or flickering.

When the model is unloaded (idle timeout), a key press kicks off an on-demand reload while audio is captured in an `AsyncStream` buffer. The processing task awaits the load, then drains the buffered chunks — the user's first words are preserved.

Benchmarks (Apple M2): 2.12% WER, 8.5× RTFx on LibriSpeech test-clean.

## Development

```bash
# Build the engine
swift build --package-path engine -c release --product whispr-engine

# Run the tests
swift test --package-path engine

# Reinstall after code changes
bash setup.sh
```

Source layout:

```
engine/
├── Package.swift
├── Sources/
│   ├── WhisprEngine/          # thin executable target — main.swift
│   └── WhisprLib/             # library with everything else
│       ├── Config.swift            # JSON config, enums, save()/load()
│       ├── HotkeyModifier.swift    # modifier enum + CGEventFlags mapping
│       ├── Logging.swift           # stderr log helper
│       ├── AudioBuffer.swift       # AVAudioPCMBuffer ↔ AudioChunk helpers
│       ├── AudioCapture.swift      # AVAudioEngine mic input
│       ├── KeyboardMonitor.swift   # CGEventTap for the hotkey + Escape
│       ├── TextOutput.swift        # keypress + clipboard output
│       ├── WhisprDaemon.swift      # Whispr class: session orchestration
│       ├── WhisprApp.swift         # NSApplication entry + AppDelegate
│       ├── StatusBar.swift         # menu bar NSStatusItem + menu
│       ├── PreferencesWindow.swift # SwiftUI preferences form
│       └── Updater.swift           # git pull + setup.sh self-update
└── Tests/
    └── WhisprTests/                # Swift Testing suites
```

## Troubleshooting

**Nothing happens when I hold the hotkey**

```bash
tail -f /tmp/whispr.log
```

If the log says "Accessibility permission required", grant it in System Settings > Privacy & Security > Accessibility (look for "Whispr"). The daemon polls and will pick it up automatically within a few seconds.

**The menu bar icon isn't showing**

The daemon may not be running. Check:

```bash
launchctl print gui/$(id -u)/com.whispr.daemon
tail -n 50 /tmp/whispr.log
```

Kickstart it manually: `launchctl kickstart -k gui/$(id -u)/com.whispr.daemon`

**"Update Whispr" says it can't find my clone**

Whispr remembers the path by writing it to `~/.whispr/source_path` during `setup.sh`. If that file is missing or points to a directory you've moved, re-run `bash setup.sh` once from your clone directory and future in-app updates will work.

**First launch is slow (~15 seconds)**

That's one-time CoreML shader compilation. After the first warmup, subsequent sessions respond instantly. `setup.sh` shows a "Warming up CoreML" message during this.

**Text appears in the wrong app**

Whispr types into whatever app has focus. Click the target text field before holding the hotkey.

## Uninstall

```bash
./setup.sh --uninstall
```

Removes the LaunchAgent, `.app` bundle, config, and cached model. The self-signed code signing certificate in your login keychain is left in place (harmless; can be deleted via Keychain Access if desired).

## License

[MIT](LICENSE)
