> Warning: Use at your own risk. This software is **EXPERIMENTAL** and is not advised for use in production systems. Backing up your data before use is strongly recommended.

> I don't think this is the best way it could have been handled. I would happily accept if someone did this better and made it public

# Summary of Changes (Update)

Changes from the original guide based on additional testing and a PC rebuild:

### Breaking Changes
- **`pw-play /dev/zero` does not work** - `pw-play` requires a valid audio file format. A `silence.wav` file must be generated and used instead. See [Generate Silence File](#generate-silence-file).
- **HDMI device names change between systems** - After a PC rebuild, the GPU PCI address changed from `pci-0000_03_00.1` to `pci-0000_12_00.1`, and the HDMI output changed from `hdmi-stereo-extra2` to `hdmi-stereo`. The script now detects the HDMI sink name dynamically, so you don't need to hardcode it.

### New Approach
- **Separate script file** (`index-mic-keepalive.sh`) instead of inline shell in the systemd unit file. This avoids complex quoting issues in systemd that caused `Unbalanced quoting` errors.
- **Your headphones stay as the default output** - The old approach tried to route HDMI monitor audio to headphones via `module-loopback`, which caused mic monitoring/echo. The new approach simply keeps HDMI active in the background while your headphones remain default. Apps play directly to your headphones.
- **No `pw-loopback` at all** - The old approach used `pw-loopback -P <hdmi-sink>` to keep HDMI active. The problem is that `pw-loopback` without a `-C` capture source captures from the **default source** (your mic), routing mic audio to HDMI and causing monitoring/echo. The new approach uses `pw-play` to play silence directly to the HDMI sink, keeping it active without any mic capture.
- **No `module-loopback` for audio routing** - The old approach used `module-loopback source=hdmi.monitor sink=headphones` which routed ALL HDMI audio (including mic monitoring from SteamVR) to your headphones, causing echo. This is no longer needed.

### SteamVR Settings
- **SteamVR resets audio settings on update** - The `enablePlaybackMirror`, `playbackMirrorDevice`, and `recordingDevice` settings in `steamvr.vrsettings` may be removed or reset by SteamVR updates. If mic monitoring returns, re-add these settings and restart SteamVR.
- **Restart SteamVR after changing audio settings** - Settings changes don't take effect until SteamVR is restarted.

### New Troubleshooting
- Added echo/monitoring troubleshooting section
- Added guidance on finding correct HDMI device name after hardware changes
- Added note about SteamVR resetting settings

### Files Changed
- `index-mic-keepalive.sh` (new) - Separate script file for the keepalive logic
- `index-mic-keepalive.service` - Now calls the script instead of inline shell
- `silence.wav` (new) - Required for `pw-play` to function

---

## Quick Start

If you just want to get this working, here's the short version:

1. **Generate silence file:**
   ```bash
   python3 -c "
   import wave, struct
   f = wave.open('$HOME/.config/silence.wav', 'w')
   f.setnchannels(2)
   f.setsampwidth(2)
   f.setframerate(48000)
   data = struct.pack('<' + 'h' * (48000 * 2), *([0] * (48000 * 2)))
   f.writeframes(data)
   f.close()
   print('Created silence.wav')
   "
   ```

2. **Copy the script and make it executable:**
   ```bash
   cp index-mic-keepalive.sh ~/.config/index-mic-keepalive.sh
   chmod +x ~/.config/index-mic-keepalive.sh
   ```

3. **Create the systemd service** (replace `YOUR_USERNAME` in the service file):
   ```bash
   mkdir -p ~/.config/systemd/user
   # Edit the service file with your username, then:
   cp index-mic-keepalive.service ~/.config/systemd/user/index-mic-keepalive.service
   systemctl --user daemon-reload
   systemctl --user enable index-mic-keepalive.service
   ```

4. **Set your default audio devices:**
   ```bash
   # Set your headphones as default output
   pactl set-default-sink $(pactl list sinks short | grep -i "creative\|bluetooth\|headphone" | head -1 | awk '{print $2}')

   # Set Valve Index mic as default source
   pactl set-default-source $(pactl list sources short | grep -i valve | head -1 | awk '{print $2}')
   ```

5. **Update SteamVR audio settings** in `~/.local/share/Steam/config/steamvr.vrsettings`:
   ```json
   "audio" : {
       "enablePlaybackDeviceOverride" : true,
       "enableRecordingDeviceOverride" : true,
       "enablePlaybackMirror" : false,
       "playbackMirrorDevice" : "",
       "recordingDevice" : "YOUR_MIC_SOURCE_NAME"
   }
   ```
   Find your mic source name with: `pactl list sources short | grep -i valve`

6. **Start SteamVR** - the service auto-starts when vrserver runs.

That's it. Your headphones stay as default, mic works in VRChat, no echo.

---

# Valve Index Microphone Fix for Linux (PipeWire)

A comprehensive guide to fixing the Valve Index microphone not producing audio on Linux systems using PipeWire/WirePlumber. The mic is detected by the system but records complete silence (peak amplitude: 0).

## The Problem

The Valve Index mic is part of a USB composite device (`28de:2102`) that also handles controller communication. The mic audio endpoint is isochronous async with implicit feedback. The mic hardware only produces audio when the HDMI/DisplayPort audio output on the same USB device is in an active (RUNNING) state. When the HDMI output suspends (which happens automatically when it's not the default output), the mic stops producing audio entirely.

### Symptoms

- Mic is detected in `arecord -l`, PipeWire, and VRChat
- ALSA mixer shows capture switches are ON
- Direct recording via `arecord` or `pw-record` produces 100% silence (peak: 0, zero non-zero samples)
- Setting the Valve Index as the default audio output makes the mic work
- Using a different default output (e.g. Bluetooth headphones) kills the mic

### Hardware Details

- Vendor ID: `28de` (Valve Software)
- Product ID: `2102` (Valve VR Radio & HMD Mic)
- USB Audio Class 1.0
- Capture: 48kHz, mono, 16-bit PCM
- Endpoint: Isochronous, Asynchronous, Implicit feedback Data
- ALSA card: `hw:X,0` (card number varies by USB port)

## Prerequisites

- Linux distribution using PipeWire (1.0+) and WirePlumber
- SteamVR installed via Steam
- Valve Index headset connected via USB
- Basic familiarity with systemd user services

## Step 1: WirePlumber Configuration

Create or edit the WirePlumber ALSA rules to prevent the mic and HDMI output from suspending.

### File: `~/.config/wireplumber/wireplumber.conf.d/51-index-fix.conf`

```lua
monitor.alsa.rules = [
  {
    matches = [
      {
        node.name = "~alsa_output.*"
      }
    ]
    actions = {
      update-props = {
        session.suspend-timeout-seconds = 0
        api.alsa.period-size = 1024
        api.alsa.headroom = 2048
      }
    }
  }
  {
    matches = [
      {
        node.name = "~alsa_input.*Valve*"
      }
    ]
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
    matches = [
      {
        node.name = "~alsa_output.*hdmi*"
      }
    ]
    actions = {
      update-props = {
        session.suspend-timeout-seconds = 0
        node.pause-on-idle = false
      }
    }
  }
]
```

### What each rule does

- **`~alsa_output.*`**: Prevents all audio outputs from auto-suspending after inactivity
- **`~alsa_input.*Valve*`**: Prevents the Valve Index mic from suspending and disables pause-on-idle so it stays active even when no app is capturing
- **`~alsa_output.*hdmi*`**: Specifically prevents the HDMI/DP audio output from suspending - this is critical because the mic requires it to be active

## Step 2: HDMI Keep-Alive Service

Since WirePlumber's suspend-timeout alone isn't enough to keep the HDMI output running (it only prevents suspend after activity, not initial suspend), we need a systemd service that keeps the HDMI output active with silence while SteamVR is running.

### Generate Silence File

`pw-play` cannot play `/dev/zero` directly - it needs a valid WAV file. Generate one:

```bash
python3 -c "
import wave, struct
f = wave.open('/home/$USER/.config/silence.wav', 'w')
f.setnchannels(2)
f.setsampwidth(2)
f.setframerate(48000)
data = struct.pack('<' + 'h' * (48000 * 2), *([0] * (48000 * 2)))
f.writeframes(data)
f.close()
print('Created silence.wav')
"
```

### Script: `~/.config/index-mic-keepalive.sh`

Using a separate script avoids quoting issues with systemd unit files.

**Important:** Do NOT use `pw-loopback` to keep HDMI active. `pw-loopback -P <sink>` captures from the default source (your mic) and routes it to HDMI, causing mic monitoring/echo. Instead, use `pw-play` to play silence directly to the HDMI sink.

```bash
#!/bin/bash
# Keep Valve Index HDMI active for mic while SteamVR runs
# Your headphones stay as default - apps play there directly
SILENCE="/home/$USER/.config/silence.wav"

while true; do
    if pgrep -x vrserver > /dev/null 2>&1; then
        # Find the active HDMI sink dynamically
        HDMI_SINK=$(pactl list sinks short 2>/dev/null | grep "hdmi-stereo" | grep -v monitor | head -1 | awk '{print $2}')

        if [ -z "$HDMI_SINK" ]; then
            sleep 2
            continue
        fi

        # Set HDMI volume to 0 so no audio leaks through Index speakers
        pactl set-sink-volume "$HDMI_SINK" 0% 2>/dev/null

        # Play silence directly to HDMI - keeps it in RUNNING state
        # No loopback needed = no mic capture = no monitoring
        while pgrep -x vrserver > /dev/null 2>&1; do
            pactl set-sink-volume "$HDMI_SINK" 0% 2>/dev/null
            pw-play --target="$HDMI_SINK" "$SILENCE" 2>/dev/null
        done
    else
        sleep 2
    fi
done
```

```bash
chmod +x ~/.config/index-mic-keepalive.sh
```

### Service: `~/.config/systemd/user/index-mic-keepalive.service`

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

**Replace `YOUR_USERNAME` with your actual username.**

### HDMI Device Name

The script now automatically detects the HDMI sink name at runtime, so you don't need to hardcode it. It finds whichever `hdmi-stereo` output is active.

If you need to check manually:
```bash
pactl list sinks short | grep hdmi
```

### Install and Enable

```bash
mkdir -p ~/.config/systemd/user
chmod +x ~/.config/index-mic-keepalive.sh
systemctl --user daemon-reload
systemctl --user enable index-mic-keepalive.service
```

## Step 3: SteamVR Audio Settings

Edit `~/.local/share/Steam/config/steamvr.vrsettings` and update the `audio` section:

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

### Key settings explained

| Setting | Value | Why |
|---------|-------|-----|
| `enablePlaybackDeviceOverride` | `true` | Allows SteamVR to route audio to a specific device |
| `enableRecordingDeviceOverride` | `true` | Allows SteamVR to use a specific mic device |
| `enablePlaybackMirror` | `false` | Disables mic monitoring (hearing yourself through headphones) |
| `playbackMirrorDevice` | `""` | No mirror target, prevents mic audio leaking to headphones |
| `recordingDevice` | Valve mic name | Forces SteamVR to use the Valve Index mic |

**Important:** SteamVR may reset these settings. If mic monitoring returns, re-check that `enablePlaybackMirror` is `false` and restart SteamVR.

### Finding Your Mic Device Name

```bash
pactl list sources short | grep -i valve
```

Use the full source name as the `recordingDevice` value.

## Step 4: Set Default Audio Devices

```bash
# Find your devices
pactl list sinks short | grep -i "creative\|bluetooth\|headphone"
pactl list sources short | grep -i valve

# Set defaults (replace with your actual device names)
pactl set-default-sink alsa_output.usb-Creative_Creative_BT-W5_XXXXXXXX-XX.analog-stereo
pactl set-default-source alsa_input.usb-Valve_Corporation_Valve_VR_Radio___HMD_Mic_XXXXXXXX-XX.mono-fallback
```

These persist via WirePlumber's state files at `~/.local/state/wireplumber/default-nodes`.

## Step 5: USB Power Management (Optional)

Create a udev rule to prevent the USB device from entering power-saving mode:

### File: `/etc/udev/rules.d/50-valve-mic.rules`

```
ATTRS{idVendor}=="28de", ATTRS{idProduct}=="2102", ACTION=="add", RUN+="/bin/sh -c 'echo on > /sys/bus/usb/devices/%k/power/control'"
```

```bash
sudo cp 50-valve-mic.rules /etc/udev/rules.d/
sudo udevadm control --reload-rules
```

Note: This udev rule has a known issue where `%k` may not resolve to the correct USB device path when using `ATTRS` (which traverses the device tree). It may not work on all systems.

## Step 6: Restart Services

```bash
# Restart PipeWire/WirePlumber
systemctl --user restart wireplumber pipewire

# Start the keepalive service
systemctl --user start index-mic-keepalive.service

# Verify HDMI is running
pactl list sinks short | grep hdmi
# Should show: RUNNING (not SUSPENDED)

# Verify mic is working
pw-record --target="alsa_input.usb-Valve_Corporation_Valve_VR_Radio___HMD_Mic_XXXXXXXX-XX.mono-fallback" --rate=48000 --channels=1 /tmp/test.wav
```

## Verification

Run this to check everything is working:

```bash
# Check HDMI output is active
pactl list sinks short | grep hdmi
# Expected: RUNNING state

# Check mic has signal
timeout 3 pw-record --target=<mic-source-name> --rate=48000 --channels=1 /tmp/test.wav
python3 -c "
import wave, struct
w = wave.open('/tmp/test.wav','r')
frames = w.readframes(w.getnframes())
w.close()
samples = struct.unpack('<%dh' % (len(frames)//2), frames)
peak = max(abs(s) for s in samples)
nonzero = sum(1 for s in samples if abs(s) > 100)
print(f'Peak: {peak}, Non-zero: {nonzero}/{len(samples)} ({100*nonzero/len(samples):.1f}%)')
print('MIC WORKING' if peak > 100 else 'MIC SILENT')
"

# Check defaults
pactl get-default-sink      # Should be your BT/headphones
pactl get-default-source    # Should be Valve Index mic
```

## Troubleshooting

### Mic is still silent

1. Check if HDMI output is RUNNING: `pactl list sinks short | grep hdmi`
2. Check if the keepalive service is running: `systemctl --user status index-mic-keepalive.service`
3. Check if vrserver is running: `pgrep -a vrserver`
4. Try manually: `pw-play --target=<hdmi-sink-name> ~/.config/silence.wav`

### Hearing mic audio through headphones

- Set `enablePlaybackMirror` to `false` in `steamvr.vrsettings`
- Set `playbackMirrorDevice` to `""` (empty)
- **Restart SteamVR** after changing these settings
- SteamVR may reset these settings on update - recheck if monitoring returns

### HDMI device name changes after reboot

The script now detects the HDMI sink name dynamically, so this should not be an issue. If the mic still doesn't work, check which HDMI sink is available:

```bash
pactl list sinks short | grep hdmi
```

### SteamVR not starting the keepalive service

The service watches for `vrserver` process. Make sure SteamVR starts vrserver:

```bash
pgrep -a vrserver
# Should show: vrserver -waitformonitor ...
```

### Audio crackling or stuttering

Adjust the `api.alsa.period-size` and `api.alsa.headroom` values in the WirePlumber config. Larger values = more latency but less crackling.

### Mic works but echo/monitoring persists

If you hear yourself after confirming `enablePlaybackMirror: false`:

1. **Check for `pw-loopback` processes** - `pw-loopback -P <sink>` captures from the default source (your mic) and causes monitoring. Kill any: `pkill -f pw-loopback`
2. Make sure you restarted SteamVR after changing the setting
3. Check that no `module-loopback` is routing HDMI monitor to your headphones: `pactl list modules short | grep loopback`
4. The keepalive script should use `pw-play` directly to HDMI, NOT `pw-loopback`. If your script uses `pw-loopback`, update it to the version in this guide.

## How It Works (Technical Details)

1. The Valve Index USB device (`28de:2102`) is a composite device containing:
   - HID interface for controller tracking
   - USB Audio Class 1.0 control interface
   - USB Audio Class 1.0 streaming interface (capture only)
   - CDC ACM interface for serial communication

2. The audio streaming endpoint uses isochronous async transfer with implicit feedback mode (`bSynchAddress=0`). This means the device expects the host to provide clock synchronization, but there's no explicit feedback endpoint defined.

3. The mic audio and HDMI audio share the same USB device and implicitly share the same clock domain. When the HDMI output endpoint is suspended, the USB device's audio subsystem enters a low-power state that also disables the capture endpoint.

4. `pw-play` plays silence directly to the HDMI output. This keeps the HDMI audio endpoint in RUNNING state, which in turn keeps the mic capture endpoint active. Unlike `pw-loopback`, `pw-play` does not capture from any source - it only plays audio, so it does not interfere with the mic.

5. Setting HDMI volume to 0% prevents any audible output through the headset speakers while maintaining the active USB audio stream.

6. Your headphones stay as the default audio output - apps play there directly. The mic works because HDMI is active in the background, not because it's the default.

## System Information

This guide was tested on:
- Arch Linux with PipeWire 1.6.7 and WirePlumber
- AMD Radeon RX 7800 XT (RADV NAVI32)
- Valve Index HMD (LHR-4CF6852C)
- Creative BT-W5 Bluetooth adapter for audio output
- SteamVR (lighthouse driver)

## File Locations Summary

| File | Purpose |
|------|---------|
| `~/.config/wireplumber/wireplumber.conf.d/51-index-fix.conf` | WirePlumber rules to prevent device suspension |
| `~/.config/index-mic-keepalive.sh` | HDMI keep-alive script |
| `~/.config/silence.wav` | Silence audio file for keep-alive |
| `~/.config/systemd/user/index-mic-keepalive.service` | Systemd service to run keep-alive |
| `~/.local/share/Steam/config/steamvr.vrsettings` | SteamVR audio configuration |
| `/etc/udev/rules.d/50-valve-mic.rules` | USB power management rule |
| `~/.local/state/wireplumber/default-nodes` | Default audio device state |
