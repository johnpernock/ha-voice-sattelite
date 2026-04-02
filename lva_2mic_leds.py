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
  GET  /leds/state           -> {"leds": "on"|"off", "muted": bool, "brightness": N, "button": "enabled"|"disabled"|"unavailable"}
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

# ── Button defaults (overridable via /etc/lva-leds.json "button" key) ─────────
BUTTON_GPIO      = 17     # BCM pin — physical button on the 2-Mic HAT
BUTTON_THRESHOLD = 0.20   # seconds — min hold time to count as a real press
                           # WM8960 IRQ pulses are typically < 10ms so 200ms
                           # gives plenty of headroom; raise if false triggers
                           # persist, lower if the button feels sluggish
BUTTON_ENABLED   = True

# ── Optional config override ───────────────────────────────────────────────────
# /etc/lva-leds.json may override COLORS, BRIGHTNESS, and/or button settings.
# Written by voice-setup.sh from voice.conf variables.
# Can also be edited directly on the Pi — restart lva-2mic-leds to pick up.
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
    _btn_cfg = _cfg.get("button", {})
    if "gpio" in _btn_cfg:
        BUTTON_GPIO = int(_btn_cfg["gpio"])
    if "press_threshold" in _btn_cfg:
        BUTTON_THRESHOLD = max(0.05, float(_btn_cfg["press_threshold"]))
    if "enabled" in _btn_cfg:
        BUTTON_ENABLED = bool(_btn_cfg["enabled"])
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
_button_status    = "disabled"   # "enabled" | "disabled" | "unavailable"
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


def _toggle_mute():
    global _muted
    with _state_lock:
        _muted = not _muted
        new_muted = _muted
    if new_muted:
        _LOG.info("Button: muted")
        _apply("muted")
    else:
        _LOG.info("Button: unmuted")
        _apply("detect")


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


def _button_watcher():
    """
    Watch GPIO BUTTON_GPIO for mute-toggle button presses.

    The WM8960 codec on the 2-Mic HAT shares GPIO 17 as its IRQ output and
    drives it low briefly during audio activity.  We filter these out by only
    acting on pulses that stay low for at least BUTTON_THRESHOLD seconds.
    Typical WM8960 IRQ pulses are < 10ms; a deliberate tap is > 50ms.

    If RPi.GPIO is not installed, or BUTTON_ENABLED is False, this thread
    exits silently so the rest of the service is unaffected.
    """
    global _button_status

    if not BUTTON_ENABLED:
        _LOG.info("Button watcher disabled via config")
        _button_status = "disabled"
        return

    try:
        import RPi.GPIO as GPIO
    except ImportError:
        _LOG.warning("RPi.GPIO not available — button watcher disabled "
                     "(install with: pip install RPi.GPIO)")
        _button_status = "unavailable"
        return

    try:
        GPIO.setmode(GPIO.BCM)
        GPIO.setup(BUTTON_GPIO, GPIO.IN, pull_up_down=GPIO.PUD_UP)

        _fall_time = [0.0]   # list so the nested callback can mutate it

        def _on_edge(channel):
            if GPIO.input(BUTTON_GPIO) == GPIO.LOW:
                # Falling edge — pin just went low; record when
                _fall_time[0] = time.time()
            else:
                # Rising edge — pin released; check how long it was held
                if _fall_time[0] > 0:
                    duration = time.time() - _fall_time[0]
                    if duration >= BUTTON_THRESHOLD:
                        _LOG.info(
                            "Button press on GPIO %d (held %.0fms) — toggling mute",
                            BUTTON_GPIO, duration * 1000,
                        )
                        _toggle_mute()
                    else:
                        _LOG.debug(
                            "GPIO %d pulse ignored (%.1fms < threshold %.0fms) — "
                            "likely WM8960 IRQ",
                            BUTTON_GPIO, duration * 1000, BUTTON_THRESHOLD * 1000,
                        )
                _fall_time[0] = 0.0

        GPIO.add_event_detect(
            BUTTON_GPIO, GPIO.BOTH, callback=_on_edge, bouncetime=10
        )
        _button_status = "enabled"
        _LOG.info(
            "Button watcher started — GPIO %d, press threshold %.0fms",
            BUTTON_GPIO, BUTTON_THRESHOLD * 1000,
        )

        # Keep thread alive; GPIO callbacks fire on their own
        while True:
            time.sleep(1)

    except Exception as e:
        _LOG.error("Button watcher error: %s", e)
        _button_status = "unavailable"
    finally:
        try:
            GPIO.cleanup(BUTTON_GPIO)
        except Exception:
            pass


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
            self._json(200, {
                "leds":       "on" if _enabled else "off",
                "muted":      _muted,
                "brightness": _brightness_scale,
                "button":     _button_status,
            })
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

    btn_thread = threading.Thread(target=_button_watcher, daemon=True)
    btn_thread.start()

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
