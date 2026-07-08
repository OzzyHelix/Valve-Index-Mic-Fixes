>Warning: Use at your own risk. This software is **EXPERIMENTAL** and is not advised for use in production systems. Backing up your data before use is strongly recommended.

>I don't think this is the best way it could have been handled. I would happily accept if someone did this better and made it public

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

### File: `~/.config/systemd/user/index-mic-keepalive.service`

```ini
[Unit]
Description=Keep Valve Index HDMI active for mic (only when SteamVR runs)
After=pipewire.service wireplumber.service
Requires=pipewire.service

[Service]
ExecStartPre=/bin/sleep 3
ExecStart=/bin/sh -c '\
  while true; do \
    if pgrep -x vrserver > /dev/null 2>&1; then \
      pw-loopback -n hdmi-keepalive -P alsa_output.pci-0000_03_00.1.hdmi-stereo-extra2 -c 2 -m "[ FL FR ]" 2>/dev/null & \
      sleep 2; \
      pactl set-sink-volume alsa_output.pci-0000_03_00.1.hdmi-stereo-extra2 0%% 2>/dev/null; \
      while pgrep -x vrserver > /dev/null 2>&1; do \
        pw-play --target=hdmi-keepalive /dev/zero 2>/dev/null; \
      done; \
      pkill -f "pw-loopback.*hdmi-keepalive" 2>/dev/null; \
    else \
      sleep 2; \
    fi; \
  done'
Restart=always
RestartSec=5

[Install]
WantedBy=default.target
```

### What this does

1. Waits 3 seconds for PipeWire to start
2. Checks if `vrserver` (SteamVR) is running
3. If SteamVR is running:
   - Creates a `pw-loopback` that routes a null sink to the HDMI audio output
   - Sets HDMI volume to 0% so no audio is heard through the headset speakers
   - Continuously plays silence (`/dev/zero`) to keep the HDMI endpoint active
4. When SteamVR stops:
   - Kills the loopback
   - Sleeps and waits for SteamVR to start again

### Important: Find Your HDMI Device Name

The HDMI device name in the service file may differ on your system. Find yours with:

```bash
pactl list sinks short | grep hdmi
```

Look for the device containing `hdmi-stereo-extra2` or similar. Update the service file with your actual device name.

### Install and Enable

```bash
mkdir -p ~/.config/systemd/user
# Copy the service file to ~/.config/systemd/user/index-mic-keepalive.service
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
4. Try manually: `pw-loopback -P <hdmi-sink-name> & sleep 2 && pw-play --target=<loopback-name> /dev/zero`

### Hearing mic audio through headphones

- Set `enablePlaybackMirror` to `false` in `steamvr.vrsettings`
- Set `playbackMirrorDevice` to `""` (empty)
- Make sure the HDMI device name in `playbackMirrorDevice` matches your actual device if you do want mirroring

### HDMI device name changes after reboot

The HDMI device number can change. Use a stable name in the service:

```bash
# Find stable device path
pactl list sinks | grep -B5 "hdmi-stereo-extra" | grep "Name:"
```

### SteamVR not starting the keepalive service

The service watches for `vrserver` process. Make sure SteamVR starts vrserver:

```bash
pgrep -a vrserver
# Should show: vrserver -waitformonitor ...
```

### Audio crackling or stuttering

Adjust the `api.alsa.period-size` and `api.alsa.headroom` values in the WirePlumber config. Larger values = more latency but less crackling.

## How It Works (Technical Details)

1. The Valve Index USB device (`28de:2102`) is a composite device containing:
   - HID interface for controller tracking
   - USB Audio Class 1.0 control interface
   - USB Audio Class 1.0 streaming interface (capture only)
   - CDC ACM interface for serial communication

2. The audio streaming endpoint uses isochronous async transfer with implicit feedback mode (`bSynchAddress=0`). This means the device expects the host to provide clock synchronization, but there's no explicit feedback endpoint defined.

3. The mic audio and HDMI audio share the same USB device and implicitly share the same clock domain. When the HDMI output endpoint is suspended, the USB device's audio subsystem enters a low-power state that also disables the capture endpoint.

4. The `pw-loopback` creates a null sink and routes its playback to the HDMI output. Playing silence to this sink keeps the HDMI audio endpoint in RUNNING state, which in turn keeps the mic capture endpoint active.

5. Setting HDMI volume to 0% prevents any audible output through the headset speakers while maintaining the active USB audio stream.

## System Information

This guide was developed on:
- Arch Linux with PipeWire 1.6.7 and WirePlumber
- AMD Radeon RX 7800 XT (RADV NAVI32)
- Valve Index HMD (LHR-4CF6852C)
- Creative BT-W5 Bluetooth adapter for audio output
- SteamVR (lighthouse driver)

## File Locations Summary

| File | Purpose |
|------|---------|
| `~/.config/wireplumber/wireplumber.conf.d/51-index-fix.conf` | WirePlumber rules to prevent device suspension |
| `~/.config/systemd/user/index-mic-keepalive.service` | HDMI keep-alive service |
| `~/.local/share/Steam/config/steamvr.vrsettings` | SteamVR audio configuration |
| `/etc/udev/rules.d/50-valve-mic.rules` | USB power management rule |
| `~/.local/state/wireplumber/default-nodes` | Default audio device state |
