#!/usr/bin/env python3
"""whispr — Lightweight push-to-talk transcription for macOS.

Hold Option to record, release to transcribe. Text streams as you speak.
Uses whisper.cpp locally — your audio never leaves your machine.
"""

import io
import json
import logging
import signal
import socket
import subprocess
import sys
import threading
import time
import wave
from dataclasses import dataclass
from pathlib import Path
from urllib.request import Request, urlopen

import numpy as np
import sounddevice as sd
import yaml
import Quartz

log = logging.getLogger("whispr")

WHISPR_DIR = Path.home() / ".whispr"
MODELS_DIR = WHISPR_DIR / "models"
CONFIG_FILE = WHISPR_DIR / "config.yaml"


# ---------------------------------------------------------------------------
# Permission requests
# ---------------------------------------------------------------------------

def _ensure_permissions():
    """Request Accessibility and Microphone permissions at startup."""
    _ensure_accessibility()
    _ensure_microphone()


def _ensure_accessibility():
    """Prompt for Accessibility permission and wait until granted."""
    try:
        from ApplicationServices import AXIsProcessTrusted, AXIsProcessTrustedWithOptions
    except ImportError:
        log.warning("Cannot auto-request Accessibility (pyobjc-framework-ApplicationServices missing)")
        return

    if AXIsProcessTrusted():
        log.info("Accessibility ✓")
        return

    # Adds our binary to the Accessibility list and shows a one-time system dialog
    AXIsProcessTrustedWithOptions({"AXTrustedCheckOptionPrompt": True})
    log.info("Waiting for Accessibility — please toggle on in System Settings")
    while not AXIsProcessTrusted():
        time.sleep(2)
    log.info("Accessibility ✓")


def _ensure_microphone():
    """Trigger the standard macOS microphone permission dialog."""
    try:
        from AVFoundation import AVCaptureDevice, AVMediaTypeAudio
    except ImportError:
        log.warning("Cannot auto-request Microphone (pyobjc-framework-AVFoundation missing)")
        return

    if AVCaptureDevice.authorizationStatusForMediaType_(AVMediaTypeAudio) == 3:
        log.info("Microphone ✓")
        return

    log.info("Requesting microphone permission...")
    done = threading.Event()
    AVCaptureDevice.requestAccessForMediaType_completionHandler_(
        AVMediaTypeAudio, lambda granted: done.set()
    )
    done.wait(timeout=120)
    if AVCaptureDevice.authorizationStatusForMediaType_(AVMediaTypeAudio) == 3:
        log.info("Microphone ✓")
    else:
        log.warning("Microphone permission not granted — recording may fail")


# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

@dataclass
class Config:
    model: str = "base.en"
    language: str = "en"
    server_port: int = 8178
    output_mode: str = "keypress"   # "keypress" or "clipboard"
    idle_timeout: int = 600         # seconds; 0 = never unload model
    stream_interval: float = 0.25   # seconds between progressive requests

    @classmethod
    def load(cls) -> "Config":
        if CONFIG_FILE.exists():
            data = yaml.safe_load(CONFIG_FILE.read_text()) or {}
            return cls(**{k: v for k, v in data.items() if k in cls.__dataclass_fields__})
        return cls()


# ---------------------------------------------------------------------------
# Whisper server lifecycle
# ---------------------------------------------------------------------------

class WhisperServer:
    """Manages a whisper-server subprocess that keeps the model hot in RAM."""

    def __init__(self, config: Config):
        self.config = config
        self.process: subprocess.Popen | None = None
        self._timer: threading.Timer | None = None

    @property
    def model_path(self) -> Path:
        return MODELS_DIR / f"ggml-{self.config.model}.bin"

    @property
    def url(self) -> str:
        return f"http://127.0.0.1:{self.config.server_port}"

    def ensure_running(self):
        """Start the server if it isn't already up, and wait until ready."""
        self._cancel_timer()
        if self.process and self.process.poll() is None:
            return
        log.info("Starting whisper-server on :%d", self.config.server_port)
        self.process = subprocess.Popen(
            ["whisper-server",
             "-m", str(self.model_path),
             "--port", str(self.config.server_port),
             "-l", self.config.language],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        self._wait_ready()
        log.info("whisper-server ready")

    def _wait_ready(self, timeout=30):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            try:
                with socket.create_connection(
                    ("127.0.0.1", self.config.server_port), timeout=1
                ):
                    return
            except OSError:
                time.sleep(0.1)
        raise TimeoutError("whisper-server did not start within %ds" % timeout)

    def stop(self):
        """Kill the server to free RAM."""
        self._cancel_timer()
        if self.process and self.process.poll() is None:
            log.info("Stopping whisper-server")
            self.process.terminate()
            try:
                self.process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.process.kill()
            self.process = None

    def reset_idle_timer(self):
        """After this many idle seconds, stop the server to reclaim memory."""
        if self.config.idle_timeout <= 0:
            return
        self._cancel_timer()
        self._timer = threading.Timer(self.config.idle_timeout, self.stop)
        self._timer.daemon = True
        self._timer.start()

    def _cancel_timer(self):
        if self._timer:
            self._timer.cancel()
            self._timer = None

    def transcribe(self, audio: np.ndarray) -> str:
        """POST audio to /inference and return the transcribed text."""
        wav = _to_wav(audio)
        boundary = b"----whispr"
        body = (
            b"--" + boundary + b"\r\n"
            b'Content-Disposition: form-data; name="file"; filename="a.wav"\r\n'
            b"Content-Type: audio/wav\r\n\r\n" + wav + b"\r\n"
            b"--" + boundary + b"--\r\n"
        )
        req = Request(
            f"{self.url}/inference",
            data=body,
            headers={"Content-Type": f"multipart/form-data; boundary={boundary.decode()}"},
        )
        text = json.loads(urlopen(req, timeout=30).read()).get("text", "").strip()
        # Filter whisper artifacts like [BLANK_AUDIO], [MUSIC], etc.
        if text.startswith("[") and text.endswith("]"):
            return ""
        return text


# ---------------------------------------------------------------------------
# Audio recording
# ---------------------------------------------------------------------------

class Recorder:
    """Captures microphone audio at 16 kHz mono into a growing buffer."""

    def __init__(self):
        self._chunks: list[np.ndarray] = []
        self._stream: sd.InputStream | None = None
        self._lock = threading.Lock()

    def start(self):
        self._chunks = []
        self._stream = sd.InputStream(
            samplerate=16000, channels=1, dtype="float32",
            callback=self._on_audio,
        )
        self._stream.start()

    def stop(self) -> np.ndarray:
        if self._stream:
            self._stream.stop()
            self._stream.close()
            self._stream = None
        return self.snapshot()

    def snapshot(self) -> np.ndarray:
        """Return a copy of all audio captured so far."""
        with self._lock:
            if self._chunks:
                return np.concatenate(self._chunks)
            return np.empty(0, dtype=np.float32)

    def _on_audio(self, indata, frames, time_info, status):
        with self._lock:
            self._chunks.append(indata[:, 0].copy())


# ---------------------------------------------------------------------------
# Text output
# ---------------------------------------------------------------------------

class TextOutput:
    """Types or pastes transcription text into the active application."""

    def __init__(self, mode: str):
        self.mode = mode
        self._prev = ""

    def update(self, text: str, final: bool = False):
        """Output transcription text, diffing against what's already on screen.

        During streaming (final=False): only append — never delete text, to
        avoid flicker when whisper revises earlier words.  If whisper changed
        its mind about earlier text, skip this update entirely and wait.

        On key release (final=True): apply full diff with backspaces so the
        final output is accurate.
        """
        if not text:
            return

        if final:
            # Full diff: backspace divergent suffix, type corrected text
            common = 0
            for a, b in zip(self._prev, text):
                if a != b:
                    break
                common += 1
            to_delete = len(self._prev) - common
            suffix = text[common:]
            if to_delete:
                _backspace(to_delete)
            if suffix:
                self._output(suffix)
            self._prev = text
        else:
            # Streaming: only append if new text extends what we already typed
            if text.startswith(self._prev):
                suffix = text[len(self._prev):]
                if suffix:
                    self._output(suffix)
                self._prev = text
            # else: whisper revised earlier words — skip, final pass will fix it

    def clear(self):
        self._prev = ""

    def _output(self, text: str):
        _paste(text) if self.mode == "clipboard" else _type(text)


# ---------------------------------------------------------------------------
# Main daemon
# ---------------------------------------------------------------------------

class Whispr:
    """Glues key events, recording, transcription, and text output together."""

    def __init__(self, config: Config):
        self.config = config
        self.server = WhisperServer(config)
        self.recorder = Recorder()
        self.output = TextOutput(config.output_mode)
        self._active = False
        self._stop = threading.Event()
        self._lock = threading.Lock()  # serialises recording sessions

    # -- Key event handlers (called on main thread, must not block) --

    def on_key_down(self):
        if self._active:
            return
        self._active = True
        self.output.clear()
        self.recorder.start()
        self._stop.clear()
        threading.Thread(target=self._session, daemon=True).start()

    def on_key_up(self):
        if not self._active:
            return
        self._stop.set()

    # -- Recording session (runs in worker thread) --

    def _session(self):
        with self._lock:
            try:
                self.server.ensure_running()
            except Exception:
                log.exception("Server startup failed")
                self.recorder.stop()
                self._active = False
                return

            # Progressive streaming: send growing audio buffer every interval
            while not self._stop.wait(self.config.stream_interval):
                self._try_transcribe(self.recorder.snapshot(), final=False)

            # Final pass with complete audio — applies corrections
            audio = self.recorder.stop()
            self._try_transcribe(audio, final=True)
            self.server.reset_idle_timer()
            self._active = False

    def _try_transcribe(self, audio: np.ndarray, final: bool = False):
        if len(audio) < 4000:  # < 0.25 s — too short
            return
        try:
            text = self.server.transcribe(audio)
            self.output.update(text, final=final)
        except Exception:
            log.debug("Transcription failed", exc_info=True)

    # -- Run loop --

    def run(self):
        app = self
        tap_port = [None]  # mutable closure for re-enabling disabled taps

        def on_event(proxy, etype, event, refcon):
            if etype == Quartz.kCGEventTapDisabledByTimeout:
                Quartz.CGEventTapEnable(tap_port[0], True)
                return event
            flags = Quartz.CGEventGetFlags(event)
            option_held = bool(flags & Quartz.kCGEventFlagMaskAlternate)
            if option_held and not app._active:
                app.on_key_down()
            elif not option_held and app._active:
                app.on_key_up()
            return event

        mask = Quartz.CGEventMaskBit(Quartz.kCGEventFlagsChanged)
        tap = Quartz.CGEventTapCreate(
            Quartz.kCGSessionEventTap,
            Quartz.kCGHeadInsertEventTap,
            0,  # kCGEventTapOptionDefault — return event unchanged
            mask,
            on_event,
            None,
        )
        if tap is None:
            log.error(
                "Cannot create event tap. "
                "Grant Accessibility permission in System Settings → "
                "Privacy & Security → Accessibility."
            )
            sys.exit(1)
        tap_port[0] = tap

        src = Quartz.CFMachPortCreateRunLoopSource(None, tap, 0)
        loop = Quartz.CFRunLoopGetCurrent()
        Quartz.CFRunLoopAddSource(loop, src, Quartz.kCFRunLoopCommonModes)

        def shutdown(*_):
            log.info("Shutting down")
            app.server.stop()
            Quartz.CFRunLoopStop(loop)

        signal.signal(signal.SIGTERM, shutdown)
        signal.signal(signal.SIGINT, shutdown)

        log.info("whispr ready — hold Option to record")
        Quartz.CFRunLoopRun()


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _to_wav(audio: np.ndarray) -> bytes:
    """Convert float32 samples at 16 kHz to 16-bit PCM WAV bytes."""
    buf = io.BytesIO()
    with wave.open(buf, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(16000)
        w.writeframes((audio * 32767).astype(np.int16).tobytes())
    return buf.getvalue()


def _backspace(n: int):
    """Simulate n backspace key presses."""
    for _ in range(n):
        for pressed in (True, False):
            ev = Quartz.CGEventCreateKeyboardEvent(None, 51, pressed)
            Quartz.CGEventPost(Quartz.kCGHIDEventTap, ev)


def _type(text: str):
    """Simulate typing by posting keyboard events with unicode strings."""
    for ch in text:
        for pressed in (True, False):
            ev = Quartz.CGEventCreateKeyboardEvent(None, 0, pressed)
            Quartz.CGEventKeyboardSetUnicodeString(ev, 1, ch)
            Quartz.CGEventPost(Quartz.kCGHIDEventTap, ev)


def _paste(text: str):
    """Copy text to clipboard and simulate Cmd+V."""
    subprocess.run(["pbcopy"], input=text.encode(), check=True)
    for pressed in (True, False):
        ev = Quartz.CGEventCreateKeyboardEvent(None, 9, pressed)  # 9 = V
        Quartz.CGEventSetFlags(ev, Quartz.kCGEventFlagMaskCommand)
        Quartz.CGEventPost(Quartz.kCGHIDEventTap, ev)


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

def main():
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s [%(levelname)s] %(message)s",
    )
    config = Config.load()
    log.info("Config: %s", config)
    _ensure_permissions()
    Whispr(config).run()


if __name__ == "__main__":
    main()
