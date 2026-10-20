#!/bin/bash
# Keep Valve Index HDMI active for mic while SteamVR runs
# Your headphones stay as default - apps play there directly
SILENCE="/home/$USER/.config/silence.wav"
VRSETTINGS="/home/$USER/.local/share/Steam/config/steamvr.vrsettings"

fix_steamvr_settings() {
    # SteamVR resets audio settings on shutdown - restore them
    python3 -c "
import json, sys

path = '$VRSETTINGS'
try:
    with open(path, 'r') as f:
        data = json.load(f)
except:
    return

mic_source = 'alsa_input.usb-Valve_Corporation_Valve_VR_Radio___HMD_Mic_0B6A1BCC1B-LYM-01.mono-fallback'

audio = data.get('audio', {})
changed = False

if audio.get('enablePlaybackMirror') != False:
    audio['enablePlaybackMirror'] = False
    changed = True
if audio.get('playbackMirrorDevice') != '':
    audio['playbackMirrorDevice'] = ''
    changed = True
if audio.get('recordingDevice') != mic_source:
    audio['recordingDevice'] = mic_source
    changed = True
if audio.get('enablePlaybackDeviceOverride') != True:
    audio['enablePlaybackDeviceOverride'] = True
    changed = True
if audio.get('enableRecordingDeviceOverride') != True:
    audio['enableRecordingDeviceOverride'] = True
    changed = True

if changed:
    data['audio'] = audio
    with open(path, 'w') as f:
        json.dump(data, f, indent=3)
" 2>/dev/null
}

while true; do
    if pgrep -x vrserver > /dev/null 2>&1; then
        # Fix SteamVR settings first
        fix_steamvr_settings

        # Find the active HDMI sink dynamically.
        # The Index uses the GPU's HDMI/DP audio, which can be any of
        # hdmi-stereo / -extra1 / -extra2 / -extra3 depending on physical DP port.
        # Detect it from the active profile of the AMD GPU audio card.
        GPU_CARD=$(pactl list cards short 2>/dev/null | grep -i 'alsa_card.pci-' | awk '{print $1}' | head -1)
        ACTIVE_PROFILE=$(pactl list cards 2>/dev/null | awk -v c="$GPU_CARD" '
            $0 ~ "Card #"c {infound=1}
            infound && /Active Profile/ {print $3; exit}')
        ACTIVE_PROFILE=${ACTIVE_PROFILE#output:}
        ACTIVE_PROFILE=${ACTIVE_PROFILE%.*}

        # Find the sink whose name ends with the active profile suffix
        HDMI_SINK=""
        if [ -n "$ACTIVE_PROFILE" ]; then
            HDMI_SINK=$(pactl list sinks short 2>/dev/null | grep "hdmi-stereo" | grep -v monitor | awk -v p="$ACTIVE_PROFILE" '$2 ~ p"$" {print $2; exit}')
        fi

        # Fallback: any RUNNING hdmi-stereo sink
        if [ -z "$HDMI_SINK" ]; then
            HDMI_SINK=$(pactl list sinks short 2>/dev/null | grep "hdmi-stereo" | grep -v monitor | awk '$3=="RUNNING" {print $2; exit}')
        fi

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
