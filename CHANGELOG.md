# Changelog

All notable changes to this project are documented here.

---

## [1.3.0] — 2026-03-31

### Added

- **`lva_2mic_leds.py`** — custom LED controller for ReSpeaker 2-Mic Pi HAT V1.0. Watches LVA's systemd journal for pipeline events and drives 3 APA102 LEDs via SPI. Runs as `lva-2mic-leds.service` (root, system service). No dependency on LVA's `--event-uri` hook.
  - LED states: dim blue (idle), green (wake word), amber (processing), cyan (TTS playing), dim red (muted), red (error)
  - **Mute auto-detection** — detects `mute_switch_on.flac` / `mute_switch_off.flac` in LVA's journal. Mute LED syncs to HA's mute toggle automatically — no HA automation required.
  - **Brightness API** — `POST /leds/brightness {"brightness": 0.0-1.0}` scales all state brightnesses proportionally.
  - Full HTTP API on port 2702: `/leds/on`, `/leds/off`, `/leds/brightness`, `/muted`, `/unmuted`, `/leds/state`, `/health`
- **`ha-led-config.yaml`** — HA `rest_command` snippets for LED on/off/brightness control and a REST sensor for LED state. Paste into `configuration.yaml` to enable HA automations.
- **`ha-custom-automation/voice/`** — day/night LED schedule automations (7am on, 10pm off).

### Fixed (VoicePi4 — ReSpeaker 2-Mic HAT V1.0 on Debian Trixie)

- **PipeWire reinstalled** — standalone PulseAudio cannot expose capture for WM8960 (sink and source compete for the device). PipeWire handles full-duplex correctly. LVA now captures mic audio and detects wake word reliably.
- **`PULSE_RUNTIME_PATH`** must be `/run/user/1000/pulse` (not `/run/user/1000`) — corrected in both `/etc/linux-voice-assistant.env` and the `Environment=` line of the system service unit.
- **`LVA_MIC`** correct PipeWire UCM node name: `alsa_input.platform-soc_sound.HiFi__Mic__source` (not `stereo-fallback`).
- **`wyoming-satellite.service`** was holding the ALSA capture device open with `arecord`. Stopped and disabled.
- **Stale user service** at `~/.config/systemd/user/linux-voice-assistant.service` had hardcoded `--audio-input-device default`. Disabled.
- **`libavcodec61` missing** — installed via `sudo apt install libavcodec61 -y`.
- **`spidev` .so corrupt** — fixed with `pip install --force-reinstall spidev`.

### Known hardware limitation

- **GPIO 17 / WM8960 IRQ conflict** — GPIO 17 is the physical button pin on the ReSpeaker 2-Mic HAT V1.0, but the WM8960 codec also drives it low during audio activity. Hardware button mute is not implemented — any `when_pressed` listener causes false mute triggers on every wake word. Deferred.

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

---

## [Mar 2026] — ReSpeaker 2-Mic HAT V1 audio stack investigation

### Root cause findings

**Device tree overlay was missing** — The V1 overlay (`respeaker-2mic-v1_0`) was not in `/boot/firmware/config.txt`. This caused the WM8960 codec to be partially initialized. Fixed by adding `dtoverlay=respeaker-2mic-v1_0` to config.txt.

**WirePlumber 0.4.13 PulseAudio compat layer broken for capture** — PipeWire sees the seeed card and wpctl shows LVA actively capturing from `capture_FL/FR`, but `parecord`, `pw-record`, and soundcard's PulseAudio bindings all fail to open a capture stream (write only 44 bytes / WAV header). Output works fine.

**Speaker output** — Works correctly via `mpv --audio-device=pulse/alsa_output.platform-soc_sound.stereo-fallback`. LVA SPK must use `pulse/` prefix.

**Wake word model** — `okay_nabu.tflite` loads correctly, threshold lowered from 0.85 to 0.30 for better sensitivity.

### Current state
- LVA connects to HA successfully
- Speaker/TTS plays through HAT speaker pins
- Mic capture via PulseAudio compat layer broken — LVA receives silence
- Pending fix: ALSA loopback or WirePlumber upgrade

### Known working config
```
/boot/firmware/config.txt:
  dtparam=i2c_arm=on
  dtparam=spi=on
  dtoverlay=respeaker-2mic-v1_0

/etc/linux-voice-assistant.env:
  LVA_MIC=alsa_input.platform-soc_sound.stereo-fallback
  LVA_SPK=pulse/alsa_output.platform-soc_sound.stereo-fallback
```

---

## [Mar-Apr 2026] — Trixie upgrade + deeper audio investigation

### What was tried
- Upgraded Pi to Trixie (Debian 13) — WirePlumber 0.5.8 now available
- soundcard 0.4.5 deadlocks with PipeWire 1.4.2 on `recorder()` calls
- Removed PipeWire, switched to standalone PulseAudio 17
- PulseAudio ACP only exposes output profile for WM8960 — no input
- module-alsa-sink and module-alsa-source cannot share hw:seeed2micvoicec simultaneously
- Patched LVA __main__.py to fall back to default_microphone() on IndexError
- lva-audio-wait.sh was locking ALSA device via arecord — fixed

### Root cause
The WM8960 codec needs to be opened as a single full-duplex ALSA stream.
PulseAudio's separate sink/source modules compete for the device.
PipeWire handles this correctly but soundcard deadlocks with PipeWire 1.4.x.

### Pending fix options
1. **UCM2 config** — create proper UCM2 for seeed2micvoicec that defines
   both playback and capture paths so PulseAudio ACP exposes input profile
2. **PipeWire + soundcard workaround** — use pw-cat for capture and mpv for
   playback, bypassing soundcard's PulseAudio bindings entirely
3. **PyAudio instead of soundcard** — patch LVA to use PyAudio which uses
   ALSA directly and doesn't have the PulseAudio compat issue

### Current Pi state (Trixie)
- OS: Debian 13 Trixie
- PulseAudio 17.0 standalone (PipeWire removed)
- LVA runs as user service (not system service)
- LVA patched to fall back to default_microphone()
- default_microphone() returns monitor (output loopback) not mic
- Speaker works via mpv with PULSE_SERVER env var
- Wake word never triggers because LVA is hearing speaker output not mic

---

## [Mar-Apr 2026] Session 2 — UCM investigation, PipeWire reinstall pending

### UCM2 attempt summary
- UCM files placed at `/usr/share/alsa/ucm2/seeed2micvoicec/`
- `alsaucm -c seeed2micvoicec list _verbs` failed with error -2 (parse error)
- Fixed by adding entry to `/usr/share/alsa/ucm2/conf.d/simple-card/seeed2micvoicec.conf`
  which maps the `snd_soc_simple_card` driver to our UCM files
- `alsaucm` now returns `HiFi` verb correctly — UCM is found and parsed
- BUT: `module-alsa-card` still reports "Failed to find a working profile"
  because PulseAudio ACP can't initialize the ALSA card with our UCM
- Various EnableSequence cset formats tried — all fail at profile init stage

### Key findings
- The WM8960 cannot be opened as two separate ALSA streams simultaneously
  (module-alsa-sink + module-alsa-source both trying hw:seeed2micvoicec fails)
- `module-alsa-card` with UCM is the correct approach but profile init fails
- PipeWire handles the WM8960 correctly — wpctl confirmed both capture channels
  active when LVA was running with PipeWire
- soundcard 0.4.5 deadlocks with PipeWire 1.4.x recorder() — interactive tests hang
  BUT the deadlock may only affect interactive/sudo contexts not systemd services

### Current state (session end)
- PulseAudio 17.0 standalone still in place
- UCM files in place at /usr/share/alsa/ucm2/seeed2micvoicec/
- conf.d/simple-card/seeed2micvoicec.conf in place
- PipeWire reinstall pending (decided to try PipeWire again after PulseAudio dead end)

### Next session plan
1. `sudo apt install pipewire pipewire-alsa pipewire-pulse wireplumber -y`
2. Disable standalone PulseAudio user service
3. Reboot
4. Verify both sink AND source appear in wpctl/pactl
5. Start LVA and verify wpctl shows input_FL/FR [active] under linux_voice_assistant
6. Test wake word with threshold at 0.30
7. If wake word still doesn't trigger — record mic audio using pw-record
   and verify amplitude is non-zero before debugging further
8. DO NOT test with interactive `sudo -u pi python3` recorder — those hang
   regardless and are misleading. Test via the actual LVA service only.

### Config files to restore after PipeWire reinstall
```
/etc/linux-voice-assistant.env:
  LVA_MIC=alsa_input.platform-soc_sound.stereo-fallback
  LVA_SPK=pulse/alsa_output.platform-soc_sound.stereo-fallback

/home/pi/.config/systemd/user/linux-voice-assistant.service:
  User service (not system service)
  PULSE_SERVER=unix:%t/pulse/native
  PULSE_COOKIE=%h/.config/pulse/cookie

/home/pi/linux-voice-assistant/wakewords/okay_nabu.json:
  probability_cutoff: 0.30 (lowered from 0.85)

/home/pi/linux-voice-assistant/linux_voice_assistant/__main__.py:
  Patched to fall back to default_microphone() on IndexError

/usr/local/bin/lva-audio-wait.sh:
  Checks for PulseAudio socket only — NO arecord test (arecord held device)

/boot/firmware/config.txt:
  dtparam=i2c_arm=on
  dtparam=spi=on
  dtoverlay=respeaker-2mic-v1_0
```
