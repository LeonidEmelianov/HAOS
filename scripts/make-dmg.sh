#!/usr/bin/env bash
#
# Builds a styled HAOS-<version>.dmg: the app on the left, an Applications
# symlink on the right, big icons, and a rendered background behind them.
#
# Usage:
#   ./scripts/make-dmg.sh              write to ~/Library/Caches/HAOS
#   ./scripts/make-dmg.sh <directory>  write there instead
#
# Styling drives Finder over AppleScript, so the first run may ask for
# permission to control Finder, and a Finder window flashes open while the
# layout is applied.

set -euo pipefail

readonly APP_NAME="HAOS"
readonly PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
readonly BUILD_DIR="${HOME}/Library/Caches/HAOS"
readonly OUTPUT_DIR="${1:-$BUILD_DIR}"

# Window geometry and icon placement. Must match scripts/dmg-background.swift,
# which draws the halos and the arrow at these same coordinates.
readonly WINDOW_WIDTH=700
readonly WINDOW_HEIGHT=420
# Finder's window `bounds` include the title bar, so the frame has to be taller
# than the background by exactly that much or the bottom of the image is cut off.
readonly TITLE_BAR_HEIGHT=28
readonly ICON_SIZE=128
readonly APP_ICON_X=190
readonly APP_ICON_Y=215
readonly APPLICATIONS_ICON_X=510
readonly APPLICATIONS_ICON_Y=215

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

# SetFile ships inside Xcode, not with the Command Line Tools, so `xcrun` only
# finds it when xcode-select points at a full Xcode — which install.sh does not
# guarantee for this shell.
find_setfile() {
    local candidate
    candidate="$(xcrun --find SetFile 2>/dev/null || true)"
    [[ -x "$candidate" ]] && { printf '%s' "$candidate"; return; }
    for candidate in /Applications/Xcode.app /Applications/Xcode-beta.app; do
        candidate="${candidate}/Contents/Developer/usr/bin/SetFile"
        [[ -x "$candidate" ]] && { printf '%s' "$candidate"; return; }
    done
    die "SetFile not found; it ships with Xcode, which this script needs anyway"
}

# Reads the icon view settings back out of a volume's .DS_Store. Finder keeps
# them in an `icvp` record holding a binary plist; nothing else on the system
# reports what actually got saved, and Finder is happy to show a styled window
# while having persisted nothing.
check_layout() {
    python3 - "$1" "$ICON_SIZE" <<'PYTHON'
import plistlib, struct, sys

try:
    data = open(sys.argv[1], 'rb').read()
except FileNotFoundError:
    sys.exit("no .DS_Store was written")
marker = data.find(b'icvpblob')
if marker < 0:
    sys.exit("no icon view settings were saved")
start = marker + 8
length = struct.unpack('>I', data[start:start + 4])[0]
settings = plistlib.loads(data[start + 4:start + 4 + length])

problems = []
if settings.get('iconSize') != float(sys.argv[2]):
    problems.append(f"icon size is {settings.get('iconSize')}")
if settings.get('arrangeBy') != 'none':
    problems.append(f"icons are arranged by {settings.get('arrangeBy')}")
if settings.get('backgroundType') != 2 or \
        b'background.tiff' not in settings.get('backgroundImageAlias', b''):
    problems.append("the background picture is not set")
if problems:
    sys.exit("; ".join(problems))
PYTHON
}

# The same Release build `make install` produces, ad-hoc signed and checked
# for the virtualization entitlement.
log "Building the app…"
"${PROJECT_DIR}/scripts/install.sh" --build-only

readonly APP="${BUILD_DIR}/DerivedData/Build/Products/Release/${APP_NAME}.app"
[[ -d "$APP" ]] || die "no built app at ${APP}"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
    "${APP}/Contents/Info.plist")"
readonly VERSION
readonly VOLUME_NAME="${APP_NAME} ${VERSION}"
readonly DMG="${OUTPUT_DIR}/${APP_NAME}-${VERSION}.dmg"

staging="$(mktemp -d)"
scratch_dmg="$(mktemp -u).dmg"
mounted=""
layout_backup=""
cleanup() {
    [[ -n "$mounted" ]] && hdiutil detach "$mounted" -quiet -force 2>/dev/null || true
    rm -rf "$staging" "$scratch_dmg" ${layout_backup:+"$layout_backup"}
}
trap cleanup EXIT

log "Staging ${VOLUME_NAME}…"
ditto "$APP" "${staging}/${APP_NAME}.app"
ln -s /Applications "${staging}/Applications"

mkdir -p "${staging}/.background"
DEVELOPER_DIR="${DEVELOPER_DIR:-}" xcrun swift "${PROJECT_DIR}/scripts/dmg-background.swift" \
    "${staging}/.background"
# One TIFF holding both scales: Finder picks the 2x representation on a Retina
# display, so the background stays sharp instead of being upscaled.
tiffutil -cathidpicheck \
    "${staging}/.background/background.png" \
    "${staging}/.background/background@2x.png" \
    -out "${staging}/.background/background.tiff" >/dev/null
rm "${staging}/.background/background.png" "${staging}/.background/background@2x.png"

log "Creating the disk image…"
# A read-write image first: Finder has to write the layout into .DS_Store
# before the final, compressed read-only image is made from it.
rm -f "$scratch_dmg"
hdiutil create -srcfolder "$staging" -volname "$VOLUME_NAME" \
    -fs HFS+ -format UDRW -quiet "$scratch_dmg"

mount_output="$(hdiutil attach "$scratch_dmg" -readwrite -noverify -noautoopen)"
mounted="$(awk -F'\t' '/\/Volumes\//{print $NF}' <<<"$mount_output" | tail -1)"
[[ -d "$mounted" ]] || die "could not mount the scratch image"

log "Applying the window layout…"
# Finder is picky here, and quietly keeps its defaults when it isn't happy:
# it needs to be frontmost, the background has to be a real alias (a
# ".background:background.tiff" file reference is accepted and then ignored),
# and the view options must be read back from the same object they were set
# on. The read-back at the end is the check that any of it took.
applied="$(osascript - "$VOLUME_NAME" <<APPLESCRIPT
on run argv
    set volumeName to item 1 of argv
    set backgroundFile to POSIX file ("/Volumes/" & volumeName & "/.background/background.tiff") as alias
    tell application "Finder"
        activate
        tell disk volumeName
            open
            delay 1
            set dmgWindow to container window
            set current view of dmgWindow to icon view
            set toolbar visible of dmgWindow to false
            set statusbar visible of dmgWindow to false
            set the bounds of dmgWindow to {200, 140, ${WINDOW_WIDTH} + 200, ${WINDOW_HEIGHT} + ${TITLE_BAR_HEIGHT} + 140}
            set options to the icon view options of dmgWindow
            set arrangement of options to not arranged
            set icon size of options to ${ICON_SIZE}
            set text size of options to 13
            set label position of options to bottom
            set background picture of options to backgroundFile
            set position of item "${APP_NAME}.app" of dmgWindow to {${APP_ICON_X}, ${APP_ICON_Y}}
            set position of item "Applications" of dmgWindow to {${APPLICATIONS_ICON_X}, ${APPLICATIONS_ICON_Y}}
            update without registering applications
            delay 2
            -- Not "result": that name is reserved in AppleScript and assigning
            -- to it silently returns nothing.
            set applied to (icon size of options as string) & " " & (arrangement of options as string)
            close
            return applied
        end tell
    end tell
end run
APPLESCRIPT
)" || die "Finder refused to style the window (check System Settings → Privacy & Security → Automation)"
[[ "$applied" == "${ICON_SIZE} not arranged" ]] \
    || die "Finder kept its own view settings (got '${applied}'); the window would open unstyled"

# Finder writes .DS_Store on its own schedule after the window closes, and
# detaching before it does leaves an unstyled image behind.
log "Waiting for Finder to save the layout…"
for attempt in {1..15}; do
    layout_error="$(check_layout "${mounted}/.DS_Store" 2>&1)" && break
    sleep 1
done
[[ -z "${layout_error:-}" ]] || die "Finder never saved the layout: ${layout_error}"

# Keep a copy: Finder flushes its own cached window state over .DS_Store when
# the volume is ejected, which puts the defaults back. The layout is restored
# below on a mount Finder never sees.
layout_backup="$(mktemp)"
cp "${mounted}/.DS_Store" "$layout_backup"

sync
hdiutil detach "$mounted" -quiet
mounted=""

# -nobrowse keeps Finder out of this mount, so nothing overwrites the layout
# being put back.
log "Restoring the saved layout…"
mount_output="$(hdiutil attach "$scratch_dmg" -readwrite -noverify -noautoopen -nobrowse)"
mounted="$(awk -F'\t' '/\/Volumes\//{print $NF}' <<<"$mount_output" | tail -1)"
[[ -d "$mounted" ]] || die "could not remount the scratch image"
cp "$layout_backup" "${mounted}/.DS_Store"
# The volume icon goes on here rather than in the staging folder: `hdiutil
# create -srcfolder` drops a staged .VolumeIcon.icns on the floor. The custom
# icon bit on the volume root is what makes Finder look for the file at all.
cp "${APP}/Contents/Resources/AppIcon.icns" "${mounted}/.VolumeIcon.icns"
"$(find_setfile)" -a C "$mounted" || die "could not mark the volume as having a custom icon"
check_layout "${mounted}/.DS_Store" || die "the restored layout did not take"
sync
hdiutil detach "$mounted" -quiet
mounted=""

log "Compressing…"
mkdir -p "$OUTPUT_DIR"
rm -f "$DMG"
hdiutil convert "$scratch_dmg" -format UDZO -imagekey zlib-level=9 -quiet -o "$DMG"

log "Verifying the finished image…"
# Finder writes the layout into .DS_Store asynchronously, so read it back out
# of the image that will actually ship rather than trusting the live window.
verify_mount="$(hdiutil attach "$DMG" -readonly -noverify -noautoopen -nobrowse \
    | awk -F'\t' '/\/Volumes\//{print $NF}' | tail -1)"
[[ -d "$verify_mount" ]] || die "could not mount ${DMG} to verify it"
mounted="$verify_mount"
check_layout "${verify_mount}/.DS_Store" || die "the finished image lost its window layout"
[[ -f "${verify_mount}/.background/background.tiff" ]] \
    || die "the finished image is missing the background image"
[[ -f "${verify_mount}/.VolumeIcon.icns" ]] \
    || die "the finished image is missing the volume icon"
[[ -d "${verify_mount}/${APP_NAME}.app" && -L "${verify_mount}/Applications" ]] \
    || die "the finished image is missing the app or the Applications link"
hdiutil detach "$verify_mount" -quiet
mounted=""

log "Wrote ${DMG} ($(du -h "$DMG" | cut -f1))"
