# whispr

Push-to-talk voice transcription for macOS. Hold **Option**, speak, release — text appears wherever your cursor is.

Runs entirely on-device with [whisper.cpp](https://github.com/ggerganov/whisper.cpp). Your audio never leaves your machine.

## Features

- **Push-to-talk** — hold the Option key to record, release to transcribe
- **Streaming output** — text appears as you speak, not just after you stop
- **Always on** — runs as a LaunchAgent, survives reboots and crashes
- **Hot model** — keeps whisper loaded in RAM for instant response; auto-unloads after inactivity to save memory
- **Two output modes** — type characters (keypress) or paste from clipboard
- **Minimal** — one Python file, ~250 lines, no frameworks

## Installation

```bash
git clone https://github.com/stjepanvrbic/whispr.git
cd whispr
chmod +x setup.sh
./setup.sh
```

The setup script handles everything from scratch: Homebrew, whisper-cpp, Python venv, model download, and LaunchAgent registration.

### Permissions

On first launch, whispr automatically requests the permissions it needs:

1. **Accessibility** — a system dialog opens System Settings; toggle whispr's Python binary **on**
2. **Microphone** — click **Allow** when the standard macOS prompt appears

whispr waits patiently for both — no restart required after granting.

> **Tip:** If something goes wrong, check `/tmp/whispr.log` for details.

## Configuration

Edit `~/.whispr/config.yaml`:

| Option | Default | Description |
|---|---|---|
| `model` | `base.en` | Whisper model (`tiny.en`, `base.en`, `small.en`, `medium.en`, `large-v3-turbo`) |
| `language` | `en` | Transcription language ([ISO 639-1](https://en.wikipedia.org/wiki/List_of_ISO_639-1_codes)) |
| `server_port` | `8178` | Local port for whisper-server |
| `output_mode` | `keypress` | `keypress` (types characters) or `clipboard` (pastes via Cmd+V) |
| `idle_timeout` | `600` | Seconds before unloading model from RAM. `0` = never unload |
| `stream_interval` | `0.25` | Seconds between streaming transcription updates |

Restart after editing:

```bash
launchctl kickstart -k gui/$(id -u)/com.whispr.daemon
```

### Choosing a model

| Model | Size | Speed | Accuracy |
|---|---|---|---|
| `tiny.en` | ~75 MB | Fastest | Basic |
| `base.en` | ~142 MB | Fast | Good (default) |
| `small.en` | ~466 MB | Moderate | Better |
| `large-v3-turbo` | ~1.5 GB | Slower | Best |

To use a different model, download it and update the config:

```bash
# Download (example: small.en)
curl -L -o ~/.whispr/models/ggml-small.en.bin \
  https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.en.bin

# Update config
sed -i '' 's/model: .*/model: small.en/' ~/.whispr/config.yaml

# Restart
launchctl kickstart -k gui/$(id -u)/com.whispr.daemon
```

## How it works

```
┌──────────────────────────────────────────────────┐
│  whispr.py (LaunchAgent — always running)        │
│                                                  │
│  Option held → record audio                      │
│              → stream chunks to whisper-server    │
│              → type/paste progressive results     │
│                                                  │
│  Option released → final transcription pass      │
│                  → reset idle timer               │
│                                                  │
│  Idle 10 min → stop whisper-server (free RAM)    │
│  Next press  → restart server transparently      │
└──────────────────────────────────────────────────┘
         │
         ▼  HTTP (localhost)
┌──────────────────────────────────────────────────┐
│  whisper-server (whisper.cpp)                    │
│  Keeps model hot in RAM · /inference endpoint    │
└──────────────────────────────────────────────────┘
```

## Troubleshooting

**Nothing happens when I press Option**
- Check logs: `cat /tmp/whispr.log`
- Verify the service is running: `launchctl list | grep whispr`
- Make sure Accessibility permission is granted (see above)

**Transcription is slow or inaccurate**
- Use a smaller/larger model (see [Choosing a model](#choosing-a-model))
- Check `/tmp/whispr.log` for errors from whisper-server

**Service isn't running after reboot**
- Re-register: `launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.whispr.daemon.plist`
- Check plist exists: `ls ~/Library/LaunchAgents/com.whispr.daemon.plist`

**Port conflict**
- Change `server_port` in `~/.whispr/config.yaml` and restart

## Uninstall

```bash
./setup.sh --uninstall
```

This removes the LaunchAgent, venv, models, and config. Homebrew packages (whisper-cpp, portaudio) are left installed in case other tools use them.

## License

[MIT](LICENSE)
