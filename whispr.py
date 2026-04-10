#!/usr/bin/env python3
"""whispr — Lightweight push-to-talk transcription for macOS.

Hold Option to record, release to transcribe. Text streams as you speak.
Press Escape to cancel any active transcription.
Uses FluidAudio (Parakeet) locally — your audio never leaves your machine.
"""

import json
import logging
import signal
import subprocess
import sys
import threading
import time
from dataclasses import dataclass
from pathlib import Path

import numpy as np
import sounddevice as sd
import yaml
import Quartz

log = logging.getLogger("whispr")

WHISPR_DIR = Path.home() / ".whispr"
CONFIG_FILE = WHISPR_DIR / "config.yaml"
ENGINE_BIN = WHISPR_DIR / "whispr-engine"
SAMPLE_RATE = 16000


# ---------------------------------------------------------------------------
# Permission requests
# ---------------------------------------------------------------------------

def _ensure_permissions():
    _ensure_accessibility()
    _ensure_microphone()


def _ensure_accessibility():
    try:
        from ApplicationServices import AXIsProcessTrusted, AXIsProcessTrustedWithOptions
    except ImportError:
        return
    if AXIsProcessTrusted():
        log.info("Accessibility ✓")
        return
    AXIsProcessTrustedWithOptions({"AXTrustedCheckOptionPrompt": True})
    log.info("Waiting for Accessibility — please toggle on in System Settings")
    while not AXIsProcessTrusted():
        time.sleep(2)
    log.info("Accessibility ✓")


def _ensure_microphone():
    try:
        from AVFoundation import AVCaptureDevice, AVMediaTypeAudio
    except ImportError:
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
        log.warning("Microphone not granted — recording may fail")


# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

@dataclass
class Config:
    output_mode: str = "keypress"
    idle_timeout: int = 3600        # 1 hour; 0 = never unload
    stream_interval: float = 0.01   # 10ms — just enough to yield, inference is the bottleneck

    @classmethod
    def load(cls) -> "Config":
        if CONFIG_FILE.exists():
            data = yaml.safe_load(CONFIG_FILE.read_text()) or {}
            return cls(**{k: v for k, v in data.items() if k in cls.__dataclass_fields__})
        return cls()


# ---------------------------------------------------------------------------
# Transcription engine (FluidAudio via stdio)
# ---------------------------------------------------------------------------

class Engine:
    """Manages the whispr-engine process (FluidAudio / Parakeet CoreML).

    Communicates via stdio: write a WAV file path to stdin, read a JSON
    line from stdout.  The model stays hot in RAM between requests.
    """

    def __init__(self, config: Config):
        self.config = config
        self.process: subprocess.Popen | None = None
        self._timer: threading.Timer | None = None
        self._io_lock = threading.Lock()

    def ensure_running(self):
        self._cancel_timer()
        if self.process and self.process.poll() is None:
            return
        log.info("Starting whispr-engine...")
        self.process = subprocess.Popen(
            [str(ENGINE_BIN)],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
        )
        line = self.process.stdout.readline().decode().strip()
        if line != "READY":
            raise RuntimeError(f"Engine failed to start: {line}")
        log.info("whispr-engine ready")

    def stop(self):
        self._cancel_timer()
        if self.process and self.process.poll() is None:
            log.info("Stopping whispr-engine")
            self.process.terminate()
            try:
                self.process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.process.kill()
            self.process = None

    def reset_idle_timer(self):
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

    def reset(self):
        """Clear the engine's audio buffer (call at start of each recording)."""
        with self._io_lock:
            self.process.stdin.write((0).to_bytes(4, "little"))
            self.process.stdin.flush()
            self.process.stdout.readline()  # consume ack

    def transcribe(self, new_audio: np.ndarray) -> str:
        """Append new audio to engine buffer, transcribe the full buffer.

        Only send audio captured SINCE the last call — the engine
        accumulates internally, so we never re-send old samples.
        """
        samples = new_audio.astype(np.float32)
        with self._io_lock:
            self.process.stdin.write(len(samples).to_bytes(4, "little"))
            self.process.stdin.write(samples.tobytes())
            self.process.stdin.flush()
            line = self.process.stdout.readline().decode().strip()
        if not line:
            raise RuntimeError("Engine returned empty response")
        result = json.loads(line)
        text = result.get("text", "").strip()
        ms = result.get("ms", 0)
        log.info("%dms: %s", ms, text)
        return " ".join(text.split())


# ---------------------------------------------------------------------------
# Audio recording
# ---------------------------------------------------------------------------

class Recorder:
    def __init__(self):
        self._chunks: list[np.ndarray] = []
        self._stream: sd.InputStream | None = None
        self._lock = threading.Lock()

    def start(self):
        self._chunks = []
        self._stream = sd.InputStream(
            samplerate=SAMPLE_RATE, channels=1, dtype="float32",
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
    def __init__(self, mode: str):
        self.mode = mode
        self._len = 0

    def append(self, text: str):
        if not text:
            return
        self._emit(text)
        self._len += len(text)

    def replace(self, text: str):
        if self._len > 0:
            _backspace(self._len)
        self._emit(text)
        self._len = len(text)

    def cancel(self):
        """Delete everything typed in this session."""
        if self._len > 0:
            _backspace(self._len)
            self._len = 0

    def clear(self):
        self._len = 0

    def _emit(self, text: str):
        _paste(text) if self.mode == "clipboard" else _type(text)


# ---------------------------------------------------------------------------
# Main daemon
# ---------------------------------------------------------------------------

class Whispr:
    def __init__(self, config: Config):
        self.config = config
        self.engine = Engine(config)
        self.recorder = Recorder()
        self.output = TextOutput(config.output_mode)
        self._active = False
        self._cancel = threading.Event()
        self._stop = threading.Event()
        self._lock = threading.Lock()

    def on_key_down(self):
        if self._active:
            return
        self._active = True
        self.output.clear()
        self.recorder.start()
        self._stop.clear()
        self._cancel.clear()
        threading.Thread(target=self._session, daemon=True).start()

    def on_key_up(self):
        if not self._active:
            return
        self._stop.set()

    def on_escape(self):
        """Cancel the current transcription and delete streamed text."""
        if not self._active:
            return
        log.info("Escape — cancelling")
        self._cancel.set()
        self._stop.set()

    def _session(self):
        with self._lock:
            try:
                self.engine.ensure_running()
            except Exception:
                log.exception("Engine startup failed")
                self.recorder.stop()
                self._active = False
                return

            self.engine.reset()
            prev_words: list[str] = []
            typed_words = 0
            sent = 0

            while not self._stop.wait(self.config.stream_interval):
                if self._cancel.is_set():
                    break
                audio = self.recorder.snapshot()
                if len(audio) < SAMPLE_RATE or len(audio) == sent:
                    continue
                text = self._transcribe(audio[sent:])
                sent = len(audio)
                if not text:
                    prev_words = []
                    continue
                words = text.split()
                # Two-pass confirmation at WORD level, ignoring punctuation.
                # This prevents comma/case flip-flops from stalling streaming.
                stable = 0
                for a, b in zip(prev_words, words):
                    if _bare(a) != _bare(b):
                        break
                    stable += 1
                if stable > typed_words:
                    new = " ".join(words[typed_words:stable])
                    if typed_words > 0:
                        new = " " + new
                    self.output.append(new)
                    typed_words = stable
                prev_words = words

            # Final pass: send any remaining audio, replace with clean result
            audio = self.recorder.stop()
            remaining = audio[sent:]

            if self._cancel.is_set():
                self.output.cancel()
            else:
                if len(remaining) > 0:
                    text = self._transcribe(remaining)
                else:
                    text = " ".join(prev_words)
                if text:
                    self.output.replace(text)

            self.engine.reset_idle_timer()
            self._active = False

    def _transcribe(self, audio: np.ndarray) -> str:
        try:
            return self.engine.transcribe(audio)
        except Exception:
            log.debug("Transcription failed", exc_info=True)
            return ""

    def run(self):
        app = self
        tap_port = [None]

        def on_event(proxy, etype, event, refcon):
            if etype == Quartz.kCGEventTapDisabledByTimeout:
                Quartz.CGEventTapEnable(tap_port[0], True)
                return event

            # Escape key (keycode 53) — cancel active transcription
            if etype == Quartz.kCGEventKeyDown:
                keycode = Quartz.CGEventGetIntegerValueField(
                    event, Quartz.kCGKeyboardEventKeycode
                )
                if keycode == 53 and app._active:
                    app.on_escape()
                    return event

            # Option key — push to talk
            if etype == Quartz.kCGEventFlagsChanged:
                flags = Quartz.CGEventGetFlags(event)
                option_held = bool(flags & Quartz.kCGEventFlagMaskAlternate)
                if option_held and not app._active:
                    app.on_key_down()
                elif not option_held and app._active:
                    app.on_key_up()

            return event

        mask = (
            Quartz.CGEventMaskBit(Quartz.kCGEventFlagsChanged)
            | Quartz.CGEventMaskBit(Quartz.kCGEventKeyDown)
        )
        tap = Quartz.CGEventTapCreate(
            Quartz.kCGSessionEventTap,
            Quartz.kCGHeadInsertEventTap,
            0,
            mask,
            on_event,
            None,
        )
        if tap is None:
            log.error(
                "Cannot create event tap. "
                "Grant Accessibility permission in System Settings."
            )
            sys.exit(1)
        tap_port[0] = tap

        src = Quartz.CFMachPortCreateRunLoopSource(None, tap, 0)
        loop = Quartz.CFRunLoopGetCurrent()
        Quartz.CFRunLoopAddSource(loop, src, Quartz.kCFRunLoopCommonModes)

        def shutdown(*_):
            log.info("Shutting down")
            app.engine.stop()
            Quartz.CFRunLoopStop(loop)

        signal.signal(signal.SIGTERM, shutdown)
        signal.signal(signal.SIGINT, shutdown)

        log.info("whispr ready — hold Option to record, Escape to cancel")
        Quartz.CFRunLoopRun()


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _bare(word: str) -> str:
    """Strip punctuation and lowercase for fuzzy word comparison."""
    return word.strip(".,!?;:'-\"").lower()


def _backspace(n: int):
    for _ in range(n):
        for pressed in (True, False):
            ev = Quartz.CGEventCreateKeyboardEvent(None, 51, pressed)
            Quartz.CGEventPost(Quartz.kCGHIDEventTap, ev)


def _type(text: str):
    for ch in text:
        for pressed in (True, False):
            ev = Quartz.CGEventCreateKeyboardEvent(None, 0, pressed)
            Quartz.CGEventKeyboardSetUnicodeString(ev, 1, ch)
            Quartz.CGEventPost(Quartz.kCGHIDEventTap, ev)


def _paste(text: str):
    subprocess.run(["pbcopy"], input=text.encode(), check=True)
    for pressed in (True, False):
        ev = Quartz.CGEventCreateKeyboardEvent(None, 9, pressed)
        Quartz.CGEventSetFlags(ev, Quartz.kCGEventFlagMaskCommand)
        Quartz.CGEventPost(Quartz.kCGHIDEventTap, ev)


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
