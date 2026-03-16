#!/bin/bash
# take-screenshots.sh — Capture profile settings screenshots in all locales.
#
# Opens the profile settings panel for each category and takes a screenshot
# of just that window, for every supported locale.
#
# Usage: ./scripts/take-screenshots.sh
#
# Prerequisites:
#   - Bromure.app running
#   - A profile named "Private Browsing" exists
#
# Output: Resources/prefs_{category}_{locale}.jpg

set -euo pipefail

PROFILE="Private Browsing"
OUTPUT_DIR="Resources"
mkdir -p "$OUTPUT_DIR"

CATEGORIES=(general performance media fileTransfer privacy network vpnAds enterprise advanced)
LOCALES=(en fr de es pt ja zh_TW zh_CN)
LOCALE_NAMES=(en fr de es pt ja zh-TW zh-CN)

# Get the window ID for a window with the given title substring
get_window_id() {
    local title="$1"
    # Use CGWindowListCopyWindowInfo to find windows by title
    python3 -c "
import Quartz, sys
wl = Quartz.CGWindowListCopyWindowInfo(Quartz.kCGWindowListOptionOnScreenOnly, Quartz.kCGNullWindowID)
for w in wl:
    name = w.get('kCGWindowName', '')
    owner = w.get('kCGWindowOwnerName', '')
    if owner == 'Bromure' and '$title' in name:
        print(w['kCGWindowNumber'])
        sys.exit(0)
sys.exit(1)
" 2>/dev/null
}

# Wait for a window with the given title to appear
wait_for_window() {
    local title="$1"
    for i in $(seq 1 20); do
        if wid=$(get_window_id "$title"); then
            echo "$wid"
            return 0
        fi
        sleep 0.25
    done
    echo "TIMEOUT waiting for window: $title" >&2
    return 1
}

echo "=== Bromure Screenshot Tool ==="
echo "Profile: $PROFILE"
echo "Output: $OUTPUT_DIR/"
echo ""

for locale_idx in "${!LOCALES[@]}"; do
    locale="${LOCALES[$locale_idx]}"
    locale_name="${LOCALE_NAMES[$locale_idx]}"

    echo "--- Locale: $locale ---"

    # Set the app locale by relaunching with -AppleLanguages
    # (This changes the UI language for the running app)
    osascript -e 'tell application "Bromure" to quit' 2>/dev/null || true
    sleep 2
    open -a "$(pwd)/.build/arm64-apple-macosx/release/Bromure.app" --args -AppleLanguages "($locale)"
    sleep 5

    # Wait for app to be ready
    for i in $(seq 1 30); do
        state=$(osascript -e 'tell application "Bromure" to get app state' 2>/dev/null || echo '{}')
        if echo "$state" | grep -q '"ready"'; then
            break
        fi
        sleep 1
    done

    for category in "${CATEGORIES[@]}"; do
        echo -n "  $category... "

        # Open profile settings to the specific category
        osascript -e "tell application \"Bromure\" to open profile settings \"$PROFILE\" category \"$category\""
        sleep 1

        # Find the settings window and capture it
        if wid=$(wait_for_window "Profile Settings"); then
            outfile="$OUTPUT_DIR/prefs_${category}_${locale_name}.jpg"
            screencapture -l "$wid" -t jpg "$outfile"
            echo "OK → $outfile"
        else
            echo "SKIP (window not found)"
        fi

        # Close the panel
        osascript -e '
            tell application "System Events"
                tell process "Bromure"
                    keystroke "w" using command down
                end tell
            end tell
        ' 2>/dev/null || true
        sleep 0.5
    done

    echo ""
done

echo "=== Done ==="
echo "Screenshots saved to $OUTPUT_DIR/prefs_*_*.jpg"
ls -1 "$OUTPUT_DIR"/prefs_*_*.jpg 2>/dev/null | wc -l | xargs -I{} echo "{} screenshots captured"
