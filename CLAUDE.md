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

**LED feedback (2-Mic HAT only):** When `VOICE_ENABLE_LEDS=true`, installs `lva_2mic_leds.py` and a TCP bridge service (`lva-2mic-leds.service`). State colors: dim blue = idle, green = wake word, blue = listening, amber = processing, cyan = TTS playing, red = error.

---

## Active hardware — VoicePi4

- **Pi 4**, hostname `VoicePi4`, IP `192.168.1.191`, user `pi`
- **HAT:** ReSpeaker 2-Mic Pi HAT **V1.0** (NOT V2 — the overlay name and driver differ)
- **Speaker:** Single speaker wired to HAT speaker screw terminals
- **OS:** Debian 13 Trixie, PulseAudio 17.0 standalone (PipeWire currently removed)
- **HA satellite name:** `office-satellite`, HA at `http://192.168.1.149:8123`

---

## Blocking issue — WM8960 mic capture (as of 2026-03-31)

**Root cause:** The WM8960 codec cannot be opened as two separate ALSA streams simultaneously. `module-alsa-sink` + `module-alsa-source` compete for `hw:seeed2micvoicec` — source always fails.

**Current broken state:** LVA is running and connected to HA but using `seeed_speaker.monitor` (output loopback) as its mic source. Wake word never triggers.

**What works:**
- ALSA direct recording: `arecord -D "plughw:seeed2micvoicec,0" -f S16_LE -r 16000 -c 2`
- Speaker via mpv: `mpv --audio-device=pulse/alsa_output.platform-soc_sound.stereo-fallback`
- When PipeWire was installed, wpctl showed `input_FL/FR [active]` — PipeWire handles WM8960 correctly
- HA Assist button triggers full pipeline and plays TTS

**Pending fix — reinstall PipeWire:**
```bash
sudo apt install pipewire pipewire-alsa pipewire-pulse wireplumber -y

sudo -u pi XDG_RUNTIME_DIR=/run/user/1000 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus \
  systemctl --user disable --now pulseaudio pulseaudio.socket 2>/dev/null || true

sudo -u pi XDG_RUNTIME_DIR=/run/user/1000 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus \
  systemctl --user daemon-reload

sudo reboot
```

**After reboot, verify:**
```bash
# Must show both sink AND source
sudo -u pi XDG_RUNTIME_DIR=/run/user/1000 pactl list sources short
sudo -u pi XDG_RUNTIME_DIR=/run/user/1000 pactl list sinks short

# Must show input_FL and input_FR [active] under linux_voice_assistant
sudo -u pi XDG_RUNTIME_DIR=/run/user/1000 wpctl status | grep -A15 "Streams"
```

**Critical rules:**
- **Never test mic with interactive `sudo -u pi python3` scripts** — `soundcard` 0.4.5 `recorder()` deadlocks with PipeWire 1.4.x interactively. Test only via the actual `linux-voice-assistant` service.
- **`lva-audio-wait.sh` must never use `arecord`** — it holds the ALSA device and blocks LVA from starting.

**If wake word still doesn't trigger after PipeWire reinstall:**
```bash
# Use pw-record to verify mic audio amplitude (NOT arecord, NOT python recorder)
sudo -u pi XDG_RUNTIME_DIR=/run/user/1000 \
  pw-record --target=alsa_input.platform-soc_sound.stereo-fallback /tmp/test.wav &
sleep 3; kill %1
ls -la /tmp/test.wav   # 400KB+ = mic working; 44 bytes = capture still broken
```
If 400KB+ but wake word still fails, lower `probability_cutoff` in `wakewords/okay_nabu.json` to `0.10`.

---

## LVA patches applied on Pi

1. **`~/linux-voice-assistant/linux_voice_assistant/__main__.py`** (~line 241): falls back to `default_microphone()` on `IndexError` when named mic device not found
2. **`~/linux-voice-assistant/.venv/.../soundcard/pulseaudio.py`** (~line 114): patched `sys.argv` bug — returns `"lva"` instead of `sys.argv[1][:30]`
3. **`~/linux-voice-assistant/wakewords/okay_nabu.json`**: `probability_cutoff` lowered `0.85` → `0.30`

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
LVA_MIC=alsa_input.platform-soc_sound.stereo-fallback
LVA_SPK=pulse/alsa_output.platform-soc_sound.stereo-fallback
LVA_WAKE_WORD=okay_nabu
LVA_DIR=/home/pi/linux-voice-assistant
PULSE_RUNTIME_PATH=/run/user/1000
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
