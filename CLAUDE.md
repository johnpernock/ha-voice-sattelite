# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

---

## What this project is

A single-script installer (`voice-setup.sh`) that turns a Raspberry Pi into a Home Assistant voice satellite. It installs [OHF-Voice/linux-voice-assistant](https://github.com/OHF-Voice/linux-voice-assistant) as a systemd user service and connects to HA via the ESPHome protocol (auto-discovered via mDNS — no manual HA config needed).

Companion to [ha-pi-smarthome](https://github.com/johnpernock/ha-pi-smarthome) but fully standalone.

---

## Running the script

```bash
sudo bash voice-setup.sh                    # fresh install
sudo bash voice-setup.sh --reset            # wipe LVA and reinstall
sudo bash voice-setup.sh --factory-reset    # wipe LVA + remove HAT driver
sudo bash voice-setup.sh --remove-hat       # remove 2-Mic HAT driver only
sudo bash voice-setup.sh --update           # pull latest LVA, restart service
sudo bash voice-setup.sh --detect           # list ALSA audio devices
sudo bash voice-setup.sh --list-wake-words  # list available wake word models
sudo bash voice-setup.sh --status           # service status + last 30 log lines
```

**Configuration:** Copy `voice.conf.example` to `voice.conf` and edit before running. `voice.conf` is git-ignored and survives `git pull`.

```bash
cp voice.conf.example voice.conf
nano voice.conf
sudo bash voice-setup.sh
```

---

## Architecture

The entire project is one Bash script (`voice-setup.sh`) plus a config template. There is no build system, no package manager, and no compiled code.

**Config loading:** The script defines all defaults at the top, then `source`s `voice.conf` if present — this means `voice.conf` values override the defaults without touching the script.

**Hardware detection flow (`VOICE_HARDWARE`):**
- `auto` — script probes ALSA (`aplay -l`, `arecord -l`) to identify connected hardware and selects the appropriate profile
- `2mic_hat` — two-stage install: first run installs the device tree overlay driver and reboots; second run detects the HAT and installs LVA
- `respeaker_lite` — USB plug-and-play, no driver needed
- `usb` — finds the first USB audio device automatically
- `custom` — user sets `VOICE_MIC_DEVICE` and `VOICE_SPEAKER_DEVICE` explicitly

**Speaker routing (`VOICE_SPEAKER_OUTPUT`):** Mic and speaker can be on different devices. Set to `hdmi`, `hdmi2`, `headphone`, `usb_speaker`, or a literal ALSA device name (e.g. `plughw:2,0`).

**What the installer creates on the Pi:**
```
/etc/linux-voice-assistant.env        env vars for the systemd service
/etc/voice-installed                  install marker (name, hardware, devices)
/etc/systemd/system/linux-voice-assistant.service
/usr/local/bin/lva-audio-wait.sh      waits for audio socket before starting LVA
~/linux-voice-assistant/              LVA git clone + Python venv
~/voice.log
```

**LED feedback (2-Mic HAT only):** When `VOICE_ENABLE_LEDS=true`, installs `lva_2mic_leds.py` as `lva-2mic-leds.service` (runs as root). Tails LVA's systemd journal for pipeline events — no `--event-uri` dependency. Mute state is detected automatically from LVA's journal (`mute_switch_on.flac` / `mute_switch_off.flac` log lines) — no HA automation needed.

**Button watcher:** Uses `lgpio` (not `RPi.GPIO` — edge detection is broken on Trixie/kernel 6.6+). Polls GPIO 17 at 5ms intervals, filters WM8960 IRQ pulses under 200ms. Context-aware behavior:
- **Idle / muted** → sends `SIGUSR1` to LVA → `_set_muted()` → plays mute sound, updates HA
- **Active pipeline** (wake/listening/processing/speaking) → sends `SIGUSR2` to LVA → clears `_is_streaming_audio` + calls `stop()` → returns to idle

No HA credentials or satellite name needed. `lgpio` must be installed in the LVA venv: `pip install lgpio`.

HTTP API on port 2702:
- `POST /leds/on` — enable LEDs (day mode)
- `POST /leds/off` — disable LEDs, go dark (night mode)
- `POST /leds/brightness` — set brightness multiplier `{"brightness": 0.0-1.0}` (scales all states proportionally)
- `POST /muted` — force red muted LED (also auto-detected from journal)
- `POST /unmuted` — return to idle (also auto-detected from journal)
- `GET /leds/state` — `{"leds": "on"|"off", "muted": bool, "brightness": float}`
- `GET /health` — `{"status": "ok", "uptime": N}`

State colors: dim blue = idle, green = wake word, amber = processing, cyan = TTS playing, dim red = muted. HA schedule automations in `ha-custom-automation/voice/`; REST command config in `ha-led-config.yaml`.

---

## Active hardware — VoicePi4

- **Pi Zero 2W**, hostname `VoicePi4`, IP `192.168.1.191`, user `pi`
- **HAT:** ReSpeaker 2-Mic Pi HAT **V1.0** (NOT V2 — the overlay name and driver differ)
- **Speaker:** Single speaker wired to HAT speaker screw terminals
- **OS:** Debian 13 Trixie, **PipeWire 1.4.2** + WirePlumber (PulseAudio removed)
- **HA satellite name:** `office-satellite`, HA at `http://192.168.1.149:8123`

---

## Resolved issues (2026-03-31 session)

### Things that were broken and how they were fixed

- **`libavcodec61` missing:** `sudo apt install libavcodec61 -y`
- **`wyoming-satellite.service`** was installed and holding the ALSA capture device open with `arecord`. Stopped and disabled: `sudo systemctl disable --now wyoming-satellite`
- **Stale user service** at `~/.config/systemd/user/linux-voice-assistant.service` had hardcoded `--audio-input-device default`. Disabled: `sudo -u pi XDG_RUNTIME_DIR=/run/user/1000 systemctl --user disable --now linux-voice-assistant`
- **`PULSE_RUNTIME_PATH`** must be `/run/user/1000/pulse` (not `/run/user/1000`) — both in `/etc/linux-voice-assistant.env` AND in the `Environment=` line of the system service file
- **`LVA_MIC`** correct value: `alsa_input.platform-soc_sound.HiFi__Mic__source` (PipeWire UCM profile name, not `stereo-fallback`)
- **`/run/user/1000/pulse/` ownership:** If this directory becomes owned by root (e.g. from running `pactl` as root), LVA fails with `AssertionError` in soundcard. Fix: `sudo chown pi:pi /run/user/1000/pulse/`
- **GPIO 17 / WM8960 IRQ:** GPIO 17 is the physical button pin BUT the WM8960 codec also drives it low during audio activity. Do not use `when_pressed` — it causes false mute triggers on wake word. **Workaround implemented in `feature/gpio-button` branch:** `_button_watcher()` uses `RPi.GPIO` edge detection on both edges, measures pulse duration, and only calls `_toggle_mute()` if the pin stayed low for ≥ `BUTTON_THRESHOLD` seconds (default 200ms). WM8960 IRQ pulses are typically < 10ms. Needs live testing on VoicePi4 before merging to main.

### GPIO button — WORKING (2026-04-03)

Physical mute button on GPIO 17 is fully functional:
- `lgpio` replaces `RPi.GPIO` (edge detection broken on Trixie kernel 6.6+)
- 5ms polling loop detects press/release; WM8960 IRQ pulses (<10ms) are ignored
- On valid press: sends `SIGUSR1` to LVA → `_set_muted()` → plays mute sound + updates HA
- LED switches immediately (dim red = muted, dim blue = unmuted)

**Critical:** Never restart via `sudo -u pi ... systemctl --user restart linux-voice-assistant`. This re-activates the stale user service at `~/.config/systemd/user/linux-voice-assistant.service` which has hardcoded `--audio-input-device default` and crash-loops. Always use the system service: `sudo systemctl restart linux-voice-assistant`.

### TODO: Expanded button behavior (not yet implemented)

Desired button behavior beyond the current mute-toggle:

| Current state | Button action | Expected outcome |
|--------------|---------------|-----------------|
| Idle / muted | Press | Toggle mute (current behavior — implemented) |
| Speaking (TTS playing) | Press | **Interrupt TTS** and restart the listening pipeline |

The "interrupt TTS" case requires investigating how LVA exposes pipeline control:
- Does LVA have a REST endpoint or socket command to cancel mid-stream TTS?
- Alternatively, can the systemd service be `SIGHUP`d / restarted cleanly mid-speech?
- The `_state` variable in `lva_2mic_leds.py` tracks `"speaking"` — the button watcher can check this before deciding whether to mute or interrupt.

Implementation approach (when ready):
1. Track current LED state in a module-level variable accessible to `_button_watcher`
2. In `_on_edge` rising-edge handler: if state is `"speaking"`, call an interrupt function instead of `_toggle_mute()`
3. The interrupt function should signal LVA to cancel the current TTS and re-enter the listening state

### LED service (lva-2mic-leds)

The LED script at `/home/pi/linux-voice-assistant/lva_2mic_leds.py` is **custom** (not from upstream LVA). It was written by Claude and SCPed directly — it is NOT regenerated by `voice-setup.sh`. If `--reset` is run, the file will be emptied (LVA clones fresh). Re-SCP from `ha-voice-sattelite/` repo or re-run the LED install flow.

Current LED states: dim blue = idle, green = wake word, amber = processing, cyan = TTS playing, red = muted/error.

See Architecture section above for full HTTP API reference.

**Critical:** Never run `pactl` as root with the user's PipeWire socket — it corrupts `/run/user/1000/pulse/` ownership.

---

## WM8960 mic capture — RESOLVED (2026-03-31)

**Status: Fixed.** PipeWire reinstalled, LVA running and detecting wake word correctly.

**Root cause (historical):** WM8960 couldn't be opened simultaneously for playback + capture under PulseAudio. PipeWire handles it correctly.

**Current working state:**
- PipeWire 1.4.2 + WirePlumber running as pi user service
- LVA connected to HA, wake word "okay nabu" triggering at `probability_cutoff: 0.30`
- Mic node: `alsa_input.platform-soc_sound.HiFi__Mic__source`
- Speaker node: `pulse/alsa_output.platform-soc_sound.stereo-fallback`

**Critical rules (still apply):**
- **Never test mic with interactive `sudo -u pi python3` scripts** — `soundcard` 0.4.5 deadlocks with PipeWire 1.4.x interactively.
- **`lva-audio-wait.sh` must never use `arecord`** — it holds the ALSA device and blocks LVA from starting.
- **Never lower threshold below 0.10** — false positives become constant.

---

## LVA patches applied on Pi

All patches are applied directly on the Pi — they are not in upstream LVA and are not regenerated by `voice-setup.sh`. Re-apply after `--reset`.

1. **`__main__.py`** — `import signal` added to imports

2. **`__main__.py`** — `signal.signal(signal.SIGUSR1, signal.SIG_IGN)` at the very top of `main()`, before argument parsing. Prevents SIGUSR1 from killing LVA during slow startup before the real handler is installed.

3. **`__main__.py`** — After `loop = asyncio.get_running_loop()`, two signal handlers:
   ```python
   # SIGUSR1 — toggle mute
   def _handle_sigusr1(signum, frame):
       new_muted = not state.muted
       if state.satellite is not None:
           loop.call_soon_threadsafe(state.satellite._set_muted, new_muted)
       else:
           state.muted = new_muted
   signal.signal(signal.SIGUSR1, _handle_sigusr1)

   # SIGUSR2 — cancel active pipeline
   def _handle_sigusr2(signum, frame):
       if state.satellite is not None:
           def _cancel():
               state.satellite._is_streaming_audio = False
               state.satellite.stop()
           loop.call_soon_threadsafe(_cancel)
   signal.signal(signal.SIGUSR2, _handle_sigusr2)
   ```

4. **`satellite.py` — `play_tts()`**: guard added so a cancelled pipeline doesn't play its response when HA finishes processing:
   ```python
   def play_tts(self) -> None:
       if (not self._tts_url) or self._tts_played:
           return
       if not self._pipeline_active:   # ← added
           return
   ```

5. **`__main__.py`** (~line 247): falls back to `default_microphone()` on `IndexError` when named mic device not found

6. **`soundcard/pulseaudio.py`** (~line 114): patched `sys.argv` bug — returns `"lva"` instead of `sys.argv[1][:30]`

7. **`wakewords/okay_nabu.json`**: `probability_cutoff` lowered `0.85` → `0.30`

---

## Pi config files (current state)

**`/boot/firmware/config.txt`** — must include:
```
dtparam=i2c_arm=on
dtparam=spi=on
dtoverlay=respeaker-2mic-v1_0
```

**`/etc/linux-voice-assistant.env`:**
```
LVA_NAME=office-satellite
LVA_PORT=6053
LVA_MIC=alsa_input.platform-soc_sound.HiFi__Mic__source
LVA_SPK=pulse/alsa_output.platform-soc_sound.stereo-fallback
LVA_WAKE_WORD=okay_nabu
LVA_DIR=/home/pi/linux-voice-assistant
PULSE_RUNTIME_PATH=/run/user/1000/pulse
PULSE_COOKIE=/home/pi/.config/pulse/cookie
```

**UCM2 files** (in place, confirmed `alsaucm` returns `HiFi` verb):
```
/usr/share/alsa/ucm2/seeed2micvoicec/seeed2micvoicec.conf
/usr/share/alsa/ucm2/seeed2micvoicec/HiFi.conf
/usr/share/alsa/ucm2/conf.d/simple-card/seeed2micvoicec.conf
```

**Seeed mixer init** (enabled at boot):
```
/etc/systemd/system/seeed-mixer-init.service
/usr/local/bin/seeed-mixer-init.sh
```

---

## Useful on-Pi commands

```bash
# LVA runs as user service — use _UID=1000 for journalctl
sudo journalctl _UID=1000 -f
sudo journalctl _UID=1000 -n 30 --no-pager

# Service management (user service, not system)
sudo -u pi XDG_RUNTIME_DIR=/run/user/1000 systemctl --user status linux-voice-assistant
sudo -u pi XDG_RUNTIME_DIR=/run/user/1000 systemctl --user restart linux-voice-assistant

# Inspect running config
cat /etc/linux-voice-assistant.env

# Audio device discovery
arecord -l
aplay -l

# Test speaker
mpv --audio-device=pulse/alsa_output.platform-soc_sound.stereo-fallback \
  /usr/share/sounds/alsa/Front_Center.wav

# Verify HAT detected
dmesg | grep -i seeed
grep respeaker /boot/firmware/config.txt
```
