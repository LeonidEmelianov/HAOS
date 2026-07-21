#!/usr/bin/env bash
#
# Builds HAOS in Release, ad-hoc signs it, and installs it to /Applications.
#
# Ad-hoc signing (CODE_SIGN_IDENTITY="-") is all this app needs for personal
# use: com.apple.security.virtualization is honored without an Apple Developer
# account. Signing cannot be skipped altogether — an unsigned bundle carries no
# entitlements, and the VM then refuses to start.
#
# Usage:
#   ./scripts/install.sh              build, install, relaunch
#   ./scripts/install.sh --no-launch  build and install, but don't open the app
#   ./scripts/install.sh --build-only build and verify only, don't install
#
# Environment:
#   DEST_DIR        install location (default /Applications)
#   DEVELOPER_DIR   Xcode to build with (auto-detected when unset)

set -euo pipefail

readonly APP_NAME="HAOS"
readonly PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# Build products deliberately live outside the project. This repo may sit in
# iCloud Drive, where two things go wrong: the file provider stamps extended
# attributes that make codesign fail with "resource fork, Finder information,
# or similar detritus not allowed", and every intermediate would be uploaded.
readonly BUILD_DIR="${HOME}/Library/Caches/HAOS/DerivedData"
DEST_DIR="${DEST_DIR:-/Applications}"
readonly INSTALLED_APP="${DEST_DIR}/${APP_NAME}.app"

# The project targets macOS 27 and cannot be built against an older SDK.
readonly REQUIRED_SDK_MAJOR=27

# Seconds to wait for a running instance to quit. The app shuts the guest down
# over ACPI first, which its own terminate handler allows 30s for.
readonly QUIT_TIMEOUT=60

launch_after_install=true
install_after_build=true
for arg in "$@"; do
    case "$arg" in
        --no-launch)  launch_after_install=false ;;
        --build-only) install_after_build=false; launch_after_install=false ;;
        -h|--help) sed -n '2,17p' "${BASH_SOURCE[0]}" | cut -c3-; exit 0 ;;
        *) printf 'error: unknown option %s\n' "$arg" >&2; exit 2 ;;
    esac
done

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarning:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

# Finds a developer directory whose macOS SDK is new enough. Worth doing
# rather than trusting `xcode-select -p`: that often still points at Command
# Line Tools (which cannot build an .xcodeproj at all) or at a release Xcode
# too old for this project, while Xcode 27 sits in Xcode-beta.app.
find_developer_dir() {
    local candidates=() candidate selected
    [[ -n "${DEVELOPER_DIR:-}" ]] && candidates+=("$DEVELOPER_DIR")
    selected="$(xcode-select -p 2>/dev/null || true)"
    [[ -n "$selected" ]] && candidates+=("$selected")
    candidates+=(
        "/Applications/Xcode.app/Contents/Developer"
        "/Applications/Xcode-beta.app/Contents/Developer"
    )

    for candidate in "${candidates[@]}"; do
        [[ -d "$candidate" ]] || continue
        compgen -G "${candidate}/Platforms/MacOSX.platform/Developer/SDKs/MacOSX${REQUIRED_SDK_MAJOR}"'*.sdk' \
            >/dev/null 2>&1 || continue
        printf '%s' "$candidate"
        return 0
    done
    return 1
}

# Replacing the bundle underneath a running app corrupts it, so stop it first.
quit_running_instance() {
    pgrep -x "$APP_NAME" >/dev/null 2>&1 || return 0

    log "Quitting the running ${APP_NAME}…"
    osascript -e "quit app \"${APP_NAME}\"" >/dev/null 2>&1 || true

    local waited=0
    while pgrep -x "$APP_NAME" >/dev/null 2>&1; do
        if (( waited >= QUIT_TIMEOUT )); then
            warn "${APP_NAME} did not quit within ${QUIT_TIMEOUT}s — forcing it."
            warn "The guest may not have shut down cleanly."
            pkill -x "$APP_NAME" 2>/dev/null || true
            sleep 2
            break
        fi
        sleep 1
        waited=$(( waited + 1 ))
    done
}

developer_dir="$(find_developer_dir)" || die \
    "no Xcode with a macOS ${REQUIRED_SDK_MAJOR} SDK found. HAOS targets macOS
       ${REQUIRED_SDK_MAJOR}, which needs Xcode ${REQUIRED_SDK_MAJOR}; Command Line Tools alone cannot
       build it. Install Xcode ${REQUIRED_SDK_MAJOR} or point DEVELOPER_DIR at it."
export DEVELOPER_DIR="$developer_dir"
log "Using $(xcodebuild -version | head -1) at ${DEVELOPER_DIR%/Contents/Developer}"

log "Building ${APP_NAME} (Release, ad-hoc signed)…"
xcodebuild \
    -project "${PROJECT_DIR}/${APP_NAME}.xcodeproj" \
    -scheme "$APP_NAME" \
    -configuration Release \
    -derivedDataPath "$BUILD_DIR" \
    CODE_SIGN_IDENTITY="-" \
    CODE_SIGN_STYLE=Manual \
    DEVELOPMENT_TEAM="" \
    PROVISIONING_PROFILE_SPECIFIER="" \
    -quiet \
    build

built_app="${BUILD_DIR}/Build/Products/Release/${APP_NAME}.app"
[[ -d "$built_app" ]] || die "build reported success but ${built_app} is missing"

# Check the entitlement on the build product, before anything is installed —
# a bundle that lost it would launch fine and then fail to start the VM.
codesign --display --entitlements - "$built_app" 2>&1 \
    | grep -q "com.apple.security.virtualization" \
    || die "the virtualization entitlement is missing from the build; the VM would not start"

if [[ "$install_after_build" != true ]]; then
    log "Built and verified ${built_app}"
    exit 0
fi

quit_running_instance

[[ -d "$DEST_DIR" ]] || die "${DEST_DIR} does not exist"
[[ -w "$DEST_DIR" ]] || die "${DEST_DIR} is not writable by $(whoami)"

log "Installing to ${INSTALLED_APP}…"
# Replace rather than overlay: copying onto an existing bundle leaves stale
# files behind and invalidates the signature.
rm -rf "$INSTALLED_APP"
ditto "$built_app" "$INSTALLED_APP"

codesign --verify --strict "$INSTALLED_APP" \
    || die "the installed bundle failed signature verification"

log "Installed $(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
    "${INSTALLED_APP}/Contents/Info.plist") to ${DEST_DIR}"

if [[ "$launch_after_install" == true ]]; then
    log "Launching…"
    open "$INSTALLED_APP"
    # Only a copy running from /Applications registers itself for autostart.
    log "Look for the house icon in the menu bar."
    log "Autostart at login is registered on first launch; turn it off under"
    log "System Settings → General → Login Items."
fi
