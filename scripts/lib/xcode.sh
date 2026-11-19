# Sourced by the build and check scripts so they agree on which Xcode to use.

# The project targets macOS 27 and cannot be built against an older SDK.
readonly REQUIRED_SDK_MAJOR=27

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

# Exports DEVELOPER_DIR, or exits with an explanation.
use_developer_dir() {
    local found
    found="$(find_developer_dir)" || {
        printf '\033[1;31merror:\033[0m %s\n' \
            "no Xcode with a macOS ${REQUIRED_SDK_MAJOR} SDK found. HAOS targets macOS
       ${REQUIRED_SDK_MAJOR}, which needs Xcode ${REQUIRED_SDK_MAJOR}; Command Line Tools alone cannot
       build it. Install Xcode ${REQUIRED_SDK_MAJOR} or point DEVELOPER_DIR at it." >&2
        exit 1
    }
    export DEVELOPER_DIR="$found"
}
