# Changelog

All notable changes to this project are documented here.

---

## [1.2.0] — 2026-03-27

### Added

- **PulseAudio/PipeWire socket wait** — `lva-audio-wait.sh` is installed to `/usr/local/bin/` and wired as `ExecStartPre` in the systemd service. Waits up to 30 seconds for the user audio session socket (`/run/user/UID/pipewire-0` or `pulse/native`) to be ready before starting LVA. Prevents `Connection refused` errors at boot when the service starts before the audio session is up. Accepts either PipeWire or PulseAudio socket.
- **`--list-wake-words` flag** — lists all available wake word models from the LVA `wakewords/` directory and any custom `.tflite` files in the `local/` download directory. Shows the currently active model and links to the community wake words collection.
- **LED feedback for ReSpeaker 2-Mic HAT V2.0** — when `VOICE_HARDWARE=2mic_hat` and `VOICE_ENABLE_LEDS=true` (default), installs `lva_2mic_leds.py` and a TCP bridge service (`lva-2mic-leds.service`). The 3 APA102 RGB LEDs change color based on satellite state via LVA's `--event-uri` event hook:
  - Dim blue — idle / waiting for wake word
  - Green — wake word detected
  - Blue — listening / streaming audio
  - Amber — processing / waiting for response
  - Cyan — playing TTS response
  - Red — error (2s, then returns to idle)
- **`VOICE_ENABLE_LEDS`** config option in `voice.conf` — set `false` to skip LED install on 2-Mic HAT.
- **`XDG_RUNTIME_DIR` and `PULSE_RUNTIME_PATH`** properly set in service environment using resolved UID.

---

## [1.1.0] — 2026-03-27

### Added

- **`--factory-reset`** — stops and removes the LVA service, wipes the Python venv and clone, removes the ReSpeaker 2-Mic HAT device tree overlay from `/boot/firmware/config.txt` and `/boot/firmware/overlays/`, then offers a reboot. Full clean slate over SSH — no SD card removal needed.
- **`--remove-hat`** — removes the 2-Mic HAT driver only, leaving LVA untouched. Use when swapping to a different mic hardware.
- **Enhanced `--reset`** — detects if the 2-Mic HAT driver is installed and prompts to remove it too (factory reset) or keep it (LVA-only reset).
- **`_remove_hat_driver()` function** — removes `dtoverlay=respeaker-2mic-v2_0` from config.txt, deletes the `.dtbo` overlay file, and removes the seeed-linux-dtoverlays source directory.
- **Remote management section in README** — documents all reset/cleanup flows for wall-mounted or encased satellites that can't have their SD cards easily removed.

---

## [1.0.0] — 2026-03-27

### Added

- **`voice-setup.sh`** — full bare-metal installer for [OHF-Voice/linux-voice-assistant](https://github.com/OHF-Voice/linux-voice-assistant) as a systemd service connecting to Home Assistant via the ESPHome protocol (auto-discovered, no manual HA config needed)
- **`voice.conf` / `voice.conf.example`** — git-ignored local config file; personal settings survive every `git pull` without merge conflicts
- **Multi-hardware support** — single script handles four hardware types:
  - `2mic_hat` — ReSpeaker 2-Mic Pi HAT V2.0 (GPIO, device tree overlay driver, two-stage install with reboot)
  - `respeaker_lite` — ReSpeaker Lite (USB, plug and play, XMOS DSP)
  - `usb` — any generic USB microphone/speaker combo
  - `custom` — explicit ALSA device names for non-standard setups
  - `auto` — auto-detects what's connected
- **`VOICE_SPEAKER_OUTPUT`** — separate speaker routing so mic and speaker can use different audio devices:
  - `hdmi` — HDMI 1 (vc4hdmi0 on Pi 4/5, bcm2835 on Pi 3)
  - `hdmi2` — HDMI 2 (Pi 4/5 only)
  - `headphone` — 3.5mm jack
  - `usb_speaker` — first USB audio output
  - any literal ALSA device name (e.g. `plughw:2,0`)
- **`--detect` flag** — lists all ALSA playback and capture devices with guidance on setting manual device names
- **`--status` flag** — shows systemd service status and last 30 log lines
- **`--update` flag** — pulls latest LVA from GitHub and restarts the service without a full reinstall
- **`--reset` flag** — wipes the service, Python venv, and install marker for a clean reinstall
- **Existing install guard** — detects previous install and presents options instead of silently overwriting
- **2-Mic HAT V2.0 driver** — device tree overlay approach (no kernel compilation); two-stage install detects reboot automatically and resumes on second run
- **systemd environment file** — `/etc/linux-voice-assistant.env` keeps all config out of the service unit for easy inspection and updates
- **`loginctl enable-linger`** — service starts on boot without requiring a logged-in user session
- **End-of-install summary** — prints satellite name, hardware, mic/speaker devices, ESPHome port, and HA discovery instructions
