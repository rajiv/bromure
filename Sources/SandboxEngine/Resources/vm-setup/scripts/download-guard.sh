#!/bin/sh
# download-guard.sh — Prevent file downloads inside the guest VM.
#
# Uses inotifywait to watch /home/chrome recursively for new files.
# Files created inside hidden (dot) directories are ignored — these are
# Chromium profile data (e.g. .config/, .<UUID>/, .cache/, .pki/).
# Any file created elsewhere (Downloads/, Desktop/, etc.) is immediately
# deleted to prevent the user from saving files to the VM.
#
# Started by config-agent.py when blockDownloads is enabled.

WATCH_DIR="/home/chrome"

exec inotifywait -m -r -q \
    --exclude '/home/chrome/\.' \
    -e create -e moved_to \
    --format '%w%f' \
    "$WATCH_DIR" 2>/dev/null | while read -r filepath; do
    [ -f "$filepath" ] && rm -f "$filepath" 2>/dev/null
done
