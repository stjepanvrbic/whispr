# whispr

Push-to-talk voice transcription for macOS. Hold **Option**, speak, release — text appears wherever your cursor is, streaming in real time as you talk.

Runs entirely on-device using [FluidAudio](https://github.com/FluidInference/FluidAudio) (Parakeet TDT v3) on Apple's Neural Engine. Your audio never leaves your machine.

## Install

```bash
git clone https://github.com/stjepanvrbic/whispr.git && cd whispr && ./setup.sh
```

That's it. The setup script handles everything: Homebrew, Python, Swift engine build, LaunchAgent registration. The speech model (~1.5 GB) downloads automatically on first use.

On first launch, macOS will prompt for **Accessibility** and **Microphone** permissions — grant both.

### Requirements

- macOS 14+ on Apple Silicon
- Xcode or [Xcode Command Line Tools](https://developer.apple.com/xcode/) (`xcode-select --install`)

## Usage

| Action | What happens |
|---|---|
| **Hold Option** | Starts recording. Text streams into the active app as you speak. |
| **Release Option** | Final transcription pass — corrects and replaces the streamed text. |
| **Press Escape** | Cancels the current recording and deletes any streamed text. |

whispr runs as a background service (LaunchAgent). It starts on boot, restarts on crash, and keeps the model hot in RAM for instant response.

## Configuration

Edit `~/.whispr/config.yaml`:

| Option | Default | Description |
|---|---|---|
| `output_mode` | `keypress` | `keypress` (simulates typing) or `clipboard` (pastes via Cmd+V) |
| `idle_timeout` | `3600` | Seconds before unloading model from RAM. `0` = never unload. |
| `stream_interval` | `0.01` | Seconds between streaming updates. `0.01` = as fast as inference allows. |

Restart after editing:

```bash
launchctl kickstart -k gui/$(id -u)/com.whispr.daemon
```

## How it works

```
whispr.py (LaunchAgent)                   whispr-engine (Swift/CoreML)
┌─────────────────────────┐               ┌─────────────────────────┐
│ Option held → record    │  raw float32  │ Parakeet TDT v3         │
│ audio → send new samples├──── stdin ───►│ accumulates audio       │
│ read result → type text │◄── stdout ────┤ transcribes full buffer │
│ Option released → final │               │ returns JSON            │
│ Escape → cancel         │               │ model stays in RAM      │
└─────────────────────────┘               └─────────────────────────┘
```

- **Streaming**: full audio is re-transcribed each pass (~100ms on Apple Silicon). Only new, stable words are typed — the word-level two-pass confirmation prevents flickering from punctuation changes.
- **Final pass**: on key release, one complete transcription replaces the streamed text for maximum accuracy.
- **Idle unload**: after 1 hour of no use, the engine process exits to free RAM. Next press restarts it transparently.

## Troubleshooting

**Nothing happens when I hold Option**
- Check logs: `cat /tmp/whispr.log`
- Verify the service is running: `launchctl list | grep whispr`
- Make sure Accessibility is granted in System Settings

**First press is slow**
- The model downloads on first use (~1.5 GB). Subsequent starts load from cache in ~1 second.

**Text appears in wrong app**
- whispr types into whatever app has focus. Click the target text field before holding Option.

**Restart the service**
```bash
launchctl kickstart -k gui/$(id -u)/com.whispr.daemon
```

## Uninstall

```bash
./setup.sh --uninstall
```

Removes the LaunchAgent, engine binary, config, and cached packages. Homebrew packages (Python, portaudio) are left installed.

## License

[MIT](LICENSE)
