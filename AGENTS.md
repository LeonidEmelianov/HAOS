# HAOS — notes for agents

A macOS menu bar app that runs Home Assistant OS in a Virtualization.framework
VM, bridged onto the physical LAN with vmnet. Swift + AppKit, no external
dependencies, no package manager. Read [README.md](README.md) first for what the
app does and why; this file covers working in the code.

## Build and verify

```bash
make build
```

Builds Release, ad-hoc signs, and verifies — the check to run after any change.
`make install` additionally installs to `/Applications` and relaunches; it
shuts down the running guest first, so don't run it casually while the user's
Home Assistant is up. Ask before starting, stopping or replacing the installed
app.

Things that trip up a build:

- **Xcode 27+ is required** (macOS 27 deployment target, and you can't build
  against an older SDK). `xcode-select -p` often points at Command Line Tools
  or an older Xcode; the scripts find a usable one themselves, so prefer
  `make build` over a bare `xcodebuild`.
- **Build products go to `~/Library/Caches/HAOS`**, never into the repo. The
  repo lives in iCloud Drive, where the file provider stamps extended
  attributes that make `codesign` fail and where intermediates would be
  synced.
- **Signing can't be skipped.** An unsigned bundle carries no entitlements and
  the VM refuses to start. Ad-hoc (`CODE_SIGN_IDENTITY="-"`) is enough.
- There are **no tests**. Verification is a build plus, where it matters,
  reasoning about the runtime path — or a small `swiftc` harness over a few
  files for something like window layout.

The Xcode project uses a file-system-synchronized group: files and folders
added under `HAOS/` are picked up automatically, and `project.pbxproj` does not
need editing.

## Architecture

```
HAOS/
  App/       AppDelegate, MenuBarController, ConsoleWindowController, AboutPanel, main.swift
  Settings/  SettingsWindowController, SettingsGrid
  Support/   HAOSError, SleepAssertion, ClosureMenuItem
  VM/        VMController, VMState, VMSettings, VMFeature
    Features/DiskImage, Network, SharedFolder, PowerButton, Display
```

`VMController` builds only the bare machine — CPU count, memory, firmware,
entropy, balloon — and drives start/stop. Every other capability the guest has
is a `VMFeature`, and each feature folder holds everything that capability
needs: its settings, its host-side work, the devices it adds, and its own
Settings UI if it has one (see `SharedFolderSettingsSection`).

The contract, in `VM/VMFeature.swift`:

- `prepare(in:)` — host-side work before the machine is configured (download
  the image, edit the guest's boot files). Runs on `VMController`'s start
  queue, off the main thread, and may block. Throwing fails the start.
- `configure(_:in:)` — add devices. **Append**, never assign, or features
  clobber each other.
- `tearDown()` — release host resources. Called on *every* stop path,
  including a start that failed halfway, so it must tolerate being called
  twice and when the feature never started.

All `prepare` calls run before any `configure`, each in the order
`VMController.features` lists them. That order matters today: the disk image
must be downloaded before `SharedFolderVMFeature` and `PowerButtonVMFeature`
can edit `cmdline.txt` inside it. Each feature that edits the command line
owns one parameter, identified by a prefix that runs through its virtiofs
tag (`systemd.mount-extra=haos-shared:`, `systemd.mount-extra=haos-logind:`);
a prefix that stopped short of the tag would delete the other feature's
parameter. (Growing the image leaves its GPT backup header in the wrong place
until the guest's next boot fixes it, but `hdiutil` attaches such an image
without complaint — verified on macOS 27 — which is what lets the Settings
window grow it in place while the VM is stopped.)

To add a capability: new folder under `VM/Features/`, a type conforming to
`VMFeature`, one line in `VMController.features`. Nothing else in the
controller should need to change.

## Conventions

- **Comments say why, not what.** The existing ones explain non-obvious
  constraints (why the kernel command line is the only durable place for the
  mount, why the sleep assertion exists, why bridging skips interfaces with no
  link). Match that density; don't narrate the code.
- **UserDefaults keys are load-bearing.** `VMCPUCount`, `VMMemorySize`,
  `VMDiskSize`, `NetworkMode`, `SharedFolderEnabled`, `SharedFolderPath`,
  `SharedFolderGuestPath`, `SharedFolderReadOnly` are what installed copies
  already store. Renaming one silently resets a user's settings.
- **Errors the user will read** are `HAOSError("plain sentence")` — they land
  in the menu's status line or a start-failure alert. Don't invent new error
  domains and codes.
- **State changes reach the UI on the main queue.** `VMController.report(_:)`
  guarantees that; keep new call sites going through it. A feature that
  notices something wrong with the *running* guest (bridged DHCP going
  unanswered) says so through `VMFeatureContext.reportProblem`, which takes
  over the status line until cleared with nil.
- Settings are written the moment a control changes (no OK button, per macOS
  convention) and take effect at the next VM start. The disk size is the one
  exception — growing the image can't be undone, so it waits for its Resize
  button.
- Menus and pop-up buttons are built with `ClosureMenuItem` rather than
  `@objc` target/action pairs.
- Settings rows are described declaratively (`SettingsRow`) and laid out by
  `SettingsGrid`; never index grid rows by number.

## Runtime gotchas

- `GuestBootConfig` attaches the disk image with `hdiutil` and mounts its FAT
  boot partition. It requires no privileges but the VM **must be stopped**.
- `VZVirtualMachine.requestStop()` is a *short* power-button press, which
  Home Assistant OS's generic image ignores (`HandlePowerKey=ignore`; only a
  long press powers off). `PowerButtonVMFeature` mounts a logind drop-in into
  the guest to change that. If shutdowns start taking the full grace period
  again, that mount is the first thing to check.
- vmnet bridging triggers a one-time system authorization prompt on first
  start, and `vmnet_start_interface` can block for a while, which is why the
  whole start path runs off the main thread.
- A first launch downloads several hundred MB. `ImageDownloader` blocks the
  start queue for the duration and reports progress into the menu.
- The app registers as a login item only when running from `/Applications`, so
  Debug builds don't add DerivedData paths to the user's login items.
