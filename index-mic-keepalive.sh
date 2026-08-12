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
