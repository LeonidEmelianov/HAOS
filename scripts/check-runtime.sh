#!/usr/bin/env bash
# Small regression harness; never boots a VM or opens the user's disk image.
# Uses the same Xcode as `make build` (DEVELOPER_DIR overrides).
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
# shellcheck source=lib/xcode.sh
source scripts/lib/xcode.sh
use_developer_dir
check_dir="$(mktemp -d /private/tmp/haos-checks.XXXXXX)"
trap 'rm -rf "$check_dir"' EXIT
sources=(HAOS/VM/*.swift HAOS/VM/Features/*/*.swift HAOS/Support/*.swift HAOS/Settings/*.swift)
xcrun swiftc -swift-version 5 -module-cache-path "$check_dir/modules" \
    -o "$check_dir/runtime-checks" "${sources[@]}" scripts/checks/RuntimeChecks.swift
"$check_dir/runtime-checks"
