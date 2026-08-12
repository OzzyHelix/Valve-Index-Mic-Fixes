#!/bin/bash
# Keep Valve Index HDMI active for mic while SteamVR runs
# Your headphones stay as default - apps play there directly
HDMI_SINK="alsa_output.pci-0000_12_00.1.hdmi-stereo"
SILENCE="/home/$USER/.config/silence.wav"

while true; do
    if pgrep -x vrserver > /dev/null 2>&1; then
        # Set HDMI volume to 0 so no audio leaks through Index speakers
        pactl set-sink-volume "$HDMI_SINK" 0% 2>/dev/null

        # Start loopback playing silence to keep HDMI in RUNNING state
        if ! pgrep -f "pw-loopback.*hdmi-keepalive" > /dev/null 2>&1; then
            pw-loopback -n hdmi-keepalive -P "$HDMI_SINK" -c 2 -m "[ FL FR ]" 2>/dev/null &
            sleep 2
            pactl set-sink-volume "$HDMI_SINK" 0% 2>/dev/null
            pw-play --target=hdmi-keepalive "$SILENCE" 2>/dev/null &
        fi

        # Wait while vrserver is running
        while pgrep -x vrserver > /dev/null 2>&1; do
            sleep 1
        done

        # Cleanup
        pkill -f "pw-loopback.*hdmi-keepalive" 2>/dev/null
        pkill -f "pw-play.*silence" 2>/dev/null
    else
        sleep 2
    fi
done
