#!/usr/bin/env python3
"""
lva_2mic_leds.py — LED control for ReSpeaker 2-Mic Pi HAT
Watches LVA's systemd journal for pipeline events and drives 3 APA102 LEDs.

HTTP API on port 2702:
  POST /leds/on              -> enable LED updates (day mode)
  POST /leds/off             -> disable LEDs, turn dark (night mode)
  POST /leds/brightness      -> set brightness multiplier {"brightness": 0.0-1.0}
  POST /muted                -> red LED (muted)
  POST /unmuted              -> dim blue LED (unmuted)
  GET  /leds/state           -> {"leds": "on"|"off", "muted": bool, "brightness": N}
  GET  /health               -> {"status": "ok", "uptime": N}
"""

import http.server
import json
import logging
import subprocess
import threading
import time

_LOG = logging.getLogger(__name__)

API_PORT  = 2702
VOICE_UID = 1000

COLORS = {
    "detect":     (0,   0, 100,   0),   # dim blue  — idle
    "wake":       (0, 255,   0,   0),   # green     — wake word heard
    "listening":  (0,   0, 200,   0),   # blue      — streaming to HA
    "processing": (150, 75,   0,   0),  # amber     — waiting for response
    "speaking":   (0, 100, 100,   0),   # cyan      — playing TTS
    "error":      (200,  0,   0,   0),  # red       — error
    "muted":      (200,  0,   0,   0),  # red       — muted
}
BRIGHTNESS = {
    "detect": 4, "wake": 20, "listening": 15,
    "processing": 10, "speaking": 15, "error": 15, "muted": 1,
}

# ── Optional config override ───────────────────────────────────────────────────
# /etc/lva-leds.json may override COLORS and/or BRIGHTNESS per state.
# Written by voice-setup.sh from LED_COLOR_* / LED_BRIGHTNESS_* in voice.conf.
# Can also be edited directly — restart lva-2mic-leds to pick up changes.
_CFG_PATH = "/etc/lva-leds.json"
try:
    with open(_CFG_PATH) as _f:
        _cfg = json.load(_f)
    for _state, _rgb in _cfg.get("colors", {}).items():
        if _state in COLORS and len(_rgb) >= 3:
            COLORS[_state] = (int(_rgb[0]), int(_rgb[1]), int(_rgb[2]), 0)
    for _state, _br in _cfg.get("brightness", {}).items():
        if _state in BRIGHTNESS:
            BRIGHTNESS[_state] = max(0, min(31, int(_br)))
except FileNotFoundError:
    pass
except Exception as _e:
    import sys as _sys
    print(f"[leds] Warning: could not load {_CFG_PATH}: {_e}", file=_sys.stderr)

NUM_LEDS = 3
SPI_DEV  = 0
SPI_CS   = 0


class APA102:
    def __init__(self):
        try:
            import spidev
            self.spi = spidev.SpiDev()
            self.spi.open(SPI_DEV, SPI_CS)
            self.spi.max_speed_hz = 1000000
            self._ok = True
        except Exception as e:
            _LOG.warning("SPI/APA102 not available: %s", e)
            self._ok = False

    def set_all(self, r, g, b, brightness=8):
        if not self._ok:
            return
        start  = [0x00] * 4
        end    = [0xFF] * 4
        bright = 0xE0 | min(brightness, 31)
        pixels = [bright, b, g, r] * NUM_LEDS
        try:
            self.spi.xfer2(start + pixels + end)
        except Exception:
            pass

    def off(self):
        self.set_all(0, 0, 0, 0)

    def close(self):
        if self._ok:
            self.off()
            self.spi.close()


_enabled          = True
_muted            = False
_brightness_scale = 1.0
_state_lock       = threading.Lock()
_leds             = None
_reset_timer      = None
START_TIME        = time.time()


def _apply(state):
    global _reset_timer
    if _reset_timer is not None:
        _reset_timer.cancel()
        _reset_timer = None
    with _state_lock:
        if not _enabled or _leds is None:
            return
        if _muted and state != "muted":
            return
        color = COLORS.get(state, COLORS["detect"])
        raw = BRIGHTNESS.get(state, 8)
        scaled = max(1, min(31, int(round(raw * _brightness_scale))))
        _leds.set_all(*color[:3], brightness=scaled)
    if state == "speaking":
        _reset_timer = threading.Timer(15.0, _apply, args=["detect"])
        _reset_timer.daemon = True
        _reset_timer.start()


_JOURNAL_RULES = [
    (["mute_switch_on"],                                                   "muted"),
    (["mute_switch_off"],                                                  "unmuted"),
    (["wake_word_triggered", "wake word", "wakeword", "keyword found"],    "wake"),
    (["streaming start", "streaming audio", "run pipeline", "listening"],  "listening"),
    (["processing.wav", "stt", "transcrib", "speech-to-text"],            "processing"),
    (["tts_proxy", "tts", "synthesiz", "text-to-speech"],                 "speaking"),
    (["pipeline done", "streaming stop", "finished", "idle", "ready"],    "detect"),
    (["error", "exception", "traceback", "failed"],                       "error"),
]


def _journal_watcher():
    global _muted
    cmd = ["journalctl", f"_UID={VOICE_UID}", "-f", "-n", "0", "--output=cat"]
    while True:
        try:
            proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
            _LOG.info("Journal watcher started (UID=%s)", VOICE_UID)
            for raw in proc.stdout:
                line = raw.decode("utf-8", errors="replace").lower()
                for keywords, state in _JOURNAL_RULES:
                    if any(k in line for k in keywords):
                        if state == "muted":
                            with _state_lock:
                                _muted = True
                        elif state == "unmuted":
                            with _state_lock:
                                _muted = False
                            state = "detect"
                        _apply(state)
                        if state == "error":
                            time.sleep(2)
                            _apply("detect")
                        break
        except Exception as e:
            _LOG.error("Journal watcher error: %s — restarting in 5s", e)
        time.sleep(5)


class _ApiHandler(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        global _enabled, _muted, _brightness_scale
        if self.path == "/leds/brightness":
            length = int(self.headers.get("Content-Length", 0))
            body = self.rfile.read(length) if length else b"{}"
            try:
                val = float(json.loads(body).get("brightness", _brightness_scale))
                val = max(0.0, min(1.0, val))
            except (ValueError, KeyError):
                self._json(400, {"error": "brightness must be 0.0-1.0"})
                return
            with _state_lock:
                _brightness_scale = val
            _LOG.info("Brightness scale set to %.2f", val)
            self._json(200, {"brightness": val})
        elif self.path == "/leds/on":
            with _state_lock:
                _enabled = True
            _apply("detect")
            self._json(200, {"leds": "on"})
        elif self.path == "/leds/off":
            with _state_lock:
                _enabled = False
            if _leds:
                _leds.off()
            self._json(200, {"leds": "off"})
        elif self.path == "/muted":
            with _state_lock:
                _muted = True
            _apply("muted")
            self._json(200, {"muted": True})
        elif self.path == "/unmuted":
            with _state_lock:
                _muted = False
            _apply("detect")
            self._json(200, {"muted": False})
        else:
            self._json(404, {"error": "not found"})

    def do_GET(self):
        if self.path == "/leds/state":
            self._json(200, {"leds": "on" if _enabled else "off", "muted": _muted, "brightness": _brightness_scale})
        elif self.path == "/health":
            self._json(200, {"status": "ok", "uptime": int(time.time() - START_TIME)})
        else:
            self._json(404, {"error": "not found"})

    def _json(self, code, body):
        data = json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", len(data))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, fmt, *args):
        _LOG.debug("API: " + fmt, *args)


def main():
    global _leds
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s [leds] %(message)s",
        datefmt="%H:%M:%S",
    )
    _leds = APA102()
    _apply("detect")

    watcher = threading.Thread(target=_journal_watcher, daemon=True)
    watcher.start()

    server = http.server.HTTPServer(("0.0.0.0", API_PORT), _ApiHandler)
    _LOG.info("LED API listening on port %s", API_PORT)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        _leds.close()


if __name__ == "__main__":
    main()
