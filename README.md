# Valve Index Microphone Fix for Linux (PipeWire / WirePlumber)

> **Warning:** This software is **EXPERIMENTAL**. Use at your own risk and back up your
> configs before applying it. It is not advised for production systems.

A working fix for the **Valve Index microphone producing complete silence** on Linux with
PipeWire/WirePlumber. The mic is detected by every layer of the stack but records nothing
(peak amplitude 0) unless the headset's own HDMI/DisplayPort audio output is kept active.

This README reflects the setup **currently running** on the development machine. It replaces
the earlier `pw-loopback` approach, which caused mic monitoring/echo.

---

## The Problem

The Valve Index is a **USB composite device** (`28de:2102`, "Valve VR Radio & HMD Mic") that
carries controller tracking, serial, **audio capture** (the mic), and **audio playback** (the
HMD speakers) over one USB connection. The audio endpoints use isochronous async transfer with
**implicit feedback** (`bSynchAddress=0`), so the speaker and mic share the device's audio
clock/power domain.

When the HDMI/DisplayPort playback endpoint is idle, PipeWire suspends it. That drops the whole
USB audio subsystem into a low-power state and **silently disables the capture endpoint too** —
so the mic reads pure silence even though it looks perfectly healthy.

### Symptoms

- The mic appears in `arecord -l`, PipeWire, and VRChat
- ALSA capture switches are ON
- `arecord` / `pw-record` produce 100% zeros (peak: 0)
- Setting the Index speakers (HDMI output) as the **default output** makes the mic work
- Using any other default output (e.g. Bluetooth headphones) kills the mic

### Hardware Details

| Field | Value |
|-------|-------|
| Vendor ID | `28de` (Valve Software) |
| Product ID | `2102` (Valve VR Radio & HMD Mic) |
| USB Audio Class | 1.0 |
| Capture format | 48 kHz, mono, 16-bit PCM |
| Endpoint | Isochronous, Asynchronous, Implicit feedback |
| ALSA card | `hw:X,0` (card number varies by USB port) |

---

## How It Works

The mic and the HMD speakers share one USB audio clock. If the speaker half sleeps, the mic half
sleeps with it. The fix therefore **keeps the speaker (HDMI) half busy with inaudible silence**
while SteamVR is running, so the shared clock — and the mic — stay alive. Your normal headphones
remain the default output; apps keep playing there directly.

```
SteamVR starts
  └─> vrserver runs
       └─> index-mic-keepalive.service notices vrserver
            ├─ 1. rewrites steamvr.vrsettings (force Index mic, mirror off)
            ├─ 2. finds the GPU HDMI sink from its active card profile
            ├─ 3. sets that HDMI sink to 0% volume
            └─ 4. loops: pw-play silence.wav -> HDMI sink
                 └─ HDMI endpoint stays RUNNING
                      └─ shared USB audio clock stays alive
                           └─ Index mic capture stays alive  ✅

SteamVR closes
  └─> vrserver gone -> keepalive stops; HDMI may suspend (fine, no mic needed)
```

### Why `pw-play`, not `pw-loopback`

The original version of this guide used `pw-loopback -P <hdmi-sink>` to keep HDMI active. The
problem: `pw-loopback` **captures from the default source** (your mic) and routes it to the sink,
causing mic monitoring/echo. `pw-play` only *plays* — no capture — so it keeps the sink in
`RUNNING` state without any monitoring. **Do not use `pw-loopback` here.**

---

## What's On This System

| File | Purpose |
|------|---------|
| `~/.config/wireplumber/wireplumber.conf.d/51-index-fix.conf` | WirePlumber rules: stop mic + HDMI from suspending |
| `~/.config/index-mic-keepalive.sh` | HDMI keep-alive script (runs only while SteamVR runs) |
| `~/.config/silence.wav` | 1 s of silence, required because `pw-play` needs a real WAV |
| `~/.config/systemd/user/index-mic-keepalive.service` | systemd user service that runs the script |
| `~/.local/share/Steam/config/steamvr.vrsettings` | SteamVR audio settings (mic forced, mirror off) |
| `/etc/udev/rules.d/50-valve-mic.rules` | Forces USB `power/control=on` for `28de:2102` (best-effort) |
| `~/.local/state/wireplumber/default-nodes` | Persisted default sink/source |

---

## Install / Reproduce

### 1. WirePlumber rules

`~/.config/wireplumber/wireplumber.conf.d/51-index-fix.conf`:

```lua
monitor.alsa.rules = [
  {
    matches = [ { node.name = "~alsa_output.*" } ]
    actions = {
      update-props = {
        session.suspend-timeout-seconds = 0
        api.alsa.period-size = 1024
        api.alsa.headroom = 2048
      }
    }
  }
  {
    matches = [ { node.name = "~alsa_input.*Valve*" } ]
    actions = {
      update-props = {
        session.suspend-timeout-seconds = 0
        node.pause-on-idle = false
        api.alsa.period-size = 128
        api.alsa.headroom = 128
      }
    }
  }
  {
    matches = [ { node.name = "~alsa_output.*hdmi*" } ]
    actions = {
      update-props = {
        session.suspend-timeout-seconds = 0
        node.pause-on-idle = false
      }
    }
  }
]
```

- `~alsa_output.*` — never auto-suspend any output
- `~alsa_input.*Valve*` — keep the mic hot even with no capture client
- `~alsa_output.*hdmi*` — **critical:** never suspend/pause the HDMI endpoint

> These rules prevent suspend *after* activity but don't force initial activation —
> that's what the keepalive service is for.

### 2. Generate the silence file

`pw-play` cannot read `/dev/zero`; it needs a valid WAV.

```bash
python3 -c "
import wave, struct
f = wave.open('/home/$USER/.config/silence.wav', 'w')
f.setnchannels(2); f.setsampwidth(2); f.setframerate(48000)
f.writeframes(struct.pack('<' + 'h' * (48000 * 2), *([0] * (48000 * 2))))
f.close(); print('Created silence.wav')
"
```

### 3. The keepalive script

The full script is [`index-mic-keepalive.sh`](./index-mic-keepalive.sh) in this repo.
What it does each loop, while `vrserver` is running:

1. **`fix_steamvr_settings()`** — re-asserts the SteamVR `audio` block (force the Index mic,
   disable mirroring), because SteamVR resets those on update/exit.
2. **Detects the HDMI sink dynamically** — reads the AMD GPU audio card's *active profile*,
   strips `output:` and its suffix, then matches the sink whose name ends in that suffix
   (`hdmi-stereo`, `-extra1`, `-extra2`, … depending on the physical DP port). Falls back to
   any `RUNNING` `hdmi-stereo` sink.
3. **Forces that sink to 0% volume** — nothing leaks through the HMD speakers.
4. **Loops `pw-play --target=<HDMI_SINK> ~/.config/silence.wav`** — keeps the HDMI endpoint
   `RUNNING`, which keeps the shared USB audio clock (and the mic) alive. No capture = no echo.

```bash
chmod +x ~/.config/index-mic-keepalive.sh
```

> The script detects the HDMI sink dynamically, so it survives GPU/PCI address changes
> (e.g. an earlier rebuild moved the card from `pci-0000_03_00.1` to `pci-0000_12_00.1`),
> and it re-asserts the SteamVR audio settings each loop because SteamVR resets them.

### 4. systemd user service

`~/.config/systemd/user/index-mic-keepalive.service`:

```ini
[Unit]
Description=Keep Valve Index HDMI active for mic (only when SteamVR runs)
After=pipewire.service wireplumber.service
Requires=pipewire.service

[Service]
ExecStartPre=/bin/sleep 3
ExecStart=/home/YOUR_USERNAME/.config/index-mic-keepalive.sh
Restart=always
RestartSec=5

[Install]
WantedBy=default.target
```

```bash
systemctl --user daemon-reload
systemctl --user enable --now index-mic-keepalive.service
```

### 5. SteamVR audio settings

`~/.local/share/Steam/config/steamvr.vrsettings`:

```json
"audio" : {
    "enablePlaybackDeviceOverride" : true,
    "enableRecordingDeviceOverride" : true,
    "enableSpatializeGlobal" : false,
    "enableSpatializeSurround" : false,
    "enablePlaybackMirror" : false,
    "playbackMirrorDevice" : "",
    "recordingDevice" : "alsa_input.usb-Valve_Corporation_Valve_VR_Radio___HMD_Mic_0B6A1BCC1B-LYM-01.mono-fallback"
}
```

| Setting | Value | Why |
|---------|-------|-----|
| `enableRecordingDeviceOverride` | `true` | Force SteamVR to use the Index mic |
| `recordingDevice` | Valve mic source name | Pin the exact mic device |
| `enablePlaybackDeviceOverride` | `true` | Allow routing to a specific playback device |
| `enablePlaybackMirror` | `false` | No mic monitoring (no echo) |
| `playbackMirrorDevice` | `""` | No mirror target |

Find your mic name: `pactl list sources short | grep -i valve`

> ⚠️ **SteamVR resets these on update/exit.** The keepalive script rewrites them every loop to
> compensate. Edit this file **with SteamVR closed**, or the script may overwrite your changes.

### 6. USB power (optional)

`/etc/udev/rules.d/50-valve-mic.rules`:

```
ATTRS{idVendor}=="28de", ATTRS{idProduct}=="2102", ACTION=="add", RUN+="/bin/sh -c 'echo on > /sys/bus/usb/devices/%k/power/control'"
```

```bash
sudo cp 50-valve-mic.rules /etc/udev/rules.d/
sudo udevadm control --reload-rules
```

Best-effort only: `%k` with `ATTRS` may not resolve to the right path on every system.

### 7. Default devices

```bash
# Headphones/Bluetooth as default output
pactl set-default-sink "$(pactl list sinks short | grep -i 'creative\|bluetooth\|headphone' | head -1 | awk '{print $2}')"
# Valve Index mic as default source
pactl set-default-source "$(pactl list sources short | grep -i valve | head -1 | awk '{print $2}')"
```

Defaults persist in `~/.local/state/wireplumber/default-nodes`.

---

## Verify

```bash
# SteamVR up + service reacting
pgrep -a vrserver
systemctl --user status index-mic-keepalive.service

# HDMI should be RUNNING (not SUSPENDED) while SteamVR runs
pactl list sinks short | grep hdmi

# Default devices
pactl get-default-sink      # your headphones
pactl get-default-source    # the Index mic

# Live mic test
timeout 3 pw-record --target="$(pactl list sources short | grep -i valve | awk '{print $2}')" \
  --rate=48000 --channels=1 /tmp/test.wav
python3 -c "
import wave, struct
w = wave.open('/tmp/test.wav'); f = w.readframes(w.getnframes()); w.close()
s = struct.unpack('<%dh' % (len(f)//2), f); p = max(abs(x) for x in s)
print('MIC WORKING' if p > 100 else 'MIC SILENT', 'peak', p)"
```

---

## Troubleshooting

**Mic silent**
1. `pactl list sinks short | grep hdmi` → must be `RUNNING`
2. `systemctl --user status index-mic-keepalive.service`
3. `pgrep -a vrserver` → SteamVR must be running
4. Manual test: `pw-play --target=<hdmi-sink> ~/.config/silence.wav`

**Echo / hearing yourself**
1. Confirm `enablePlaybackMirror: false` and `playbackMirrorDevice: ""`, then **restart SteamVR**
2. Kill stray loopbacks: `pkill -f pw-loopback`
3. Check for old routing: `pactl list modules short | grep loopback`
4. The script must use `pw-play`, never `pw-loopback`

**HDMI name changed after a rebuild/DP swap**
The script detects it dynamically. Check what's available:
`pactl list sinks short | grep hdmi`

**Crackling / stutter**
Raise `api.alsa.period-size` / `api.alsa.headroom` in `51-index-fix.conf`.
Larger = more latency, less crackle.

**Disable when not using VR**
```bash
systemctl --user disable --now index-mic-keepalive.service
```

---

## Technical Details

1. `28de:2102` is a composite USB device: HID (tracking), UAC 1.0 control + capture,
   and CDC-ACM (serial).
2. The capture endpoint uses isochronous async transfer with implicit feedback
   (`bSynchAddress=0`): the host supplies clock sync and there is no explicit feedback endpoint.
3. Mic and HDMI audio live in the same clock/power domain on the device. Suspending HDMI puts the
   audio subsystem to sleep, which disables capture too.
4. `pw-play` plays silence to the HDMI sink, keeping it `RUNNING` and the clock alive. It captures
   from nothing, so there is no monitoring.
5. HDMI volume is forced to 0% so nothing is audible through the HMD speakers.
6. Your headphones remain the default; the mic works because HDMI is active in the background,
   not because it is the default.

## System Information

Tested on:
- Arch Linux, PipeWire 1.6.7, WirePlumber
- AMD Radeon RX 7800 XT (RADV NAVI32)
- Valve Index HMD (LHR-4CF6852C)
- Creative BT-W5 Bluetooth adapter for output
- SteamVR (lighthouse driver)
