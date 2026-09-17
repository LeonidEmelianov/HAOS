# HAOS 0.2.6

Shuts Home Assistant down properly. Until now every Quit and every *Shut Down* ended in a hard power-off.

## Fixed

- **The guest actually shuts down when asked.** Quitting the app, choosing *Shut Down*, and logging out all ask the guest to power off by pressing its virtual power button (`VZVirtualMachine.requestStop()`), then wait for it to go away before forcing it. The guest never went away: Home Assistant OS's `generic-aarch64` image is built for bare-metal boards, where a bumped power button mustn't take the house down, so its systemd-logind ignores a short press and powers off only on a long one — and a short press is all the host can send. Every stop therefore waited out the 30-second grace period and pulled the plug — the web UI kept answering right up to the kill.

  The app now hands the guest a one-line logind drop-in (`HandlePowerKey=poweroff`) the same way it hands it the shared folder: a read-only virtiofs share tagged `haos-logind`, mounted over `/run/systemd/logind.conf.d` by a `systemd.mount-extra=` entry on the kernel command line, early enough that logind reads it on its way up. Measured on a fresh guest, the web UI is gone within a second of the request and the machine is off in about 14 seconds; a restored instance with six add-ons took 25. The drop-in lives at `~/Library/Application Support/HAOS/logind.conf.d/haos.conf` and is rewritten on every start.

- **The grace period is 60 seconds, up from 30.** Now that shutdowns are real, 30 seconds left a loaded instance five seconds of margin before the force stop. The extra time only costs anything when the guest is genuinely hung.

- **A shutdown request that can't be delivered is logged** instead of being swallowed, so a stop that falls back to the grace period says why.

- **Settings no longer promises that a read-only Backups share can be restored from.** The Supervisor unpacks a backup into a temporary directory next to the `.tar` before restoring, which a read-only share refuses, so a read-only Backups share lists backups but can't restore them. The caption under the popup and the README now say so, and point at turning read-only off. Restoring also needs as much free space in the folder as the backup itself.

## Changed

- Each feature that edits the guest's kernel command line now owns its parameter by a prefix that runs through its virtiofs tag (`systemd.mount-extra=haos-shared:`, `systemd.mount-extra=haos-logind:`), so the two can't delete each other's entry. A `haos-shared` entry written by an earlier version is recognised and replaced as before.

## Installing from the .dmg

Requires **macOS 27 or later** on **Apple Silicon**. Download `HAOS-0.2.6.dmg` from this release, open it, and drag **HAOS** to **Applications**.

The app is ad-hoc signed, not notarized, so Gatekeeper will refuse the downloaded copy until the quarantine flag is removed:

```sh
xattr -dr com.apple.quarantine /Applications/HAOS.app
```

Then launch it once from Finder. Building from source with `make install` (see the [README](README.md)) avoids the quarantine step entirely.

---

# HAOS 0.2.5

Tells you what a first boot is doing instead of letting the guest's console look like it failed.

## Changed

- **The status line follows Home Assistant, not just the guest.** *Running* used to appear the moment the virtual machine was up, which on a first boot is minutes before Home Assistant is: the Supervisor still has to download Home Assistant's containers, and meanwhile the console drops into an "emergency console" warning that the CLI isn't starting — Home Assistant OS being impatient with itself, not a failure. The menu now says *Running — installing Home Assistant (first start; takes several minutes)* for that stretch, *Running — starting Home Assistant…* on later boots, and plain *Running* (with the menu icon lit) once the web UI actually answers. The app tells the phases apart by what answers on port 8123: the Supervisor's placeholder page while it's installing, Home Assistant itself once it's up, nothing in between. A guest quit halfway through its install is reported as still installing on the boot after.

## Fixed

- **Nothing of macOS's is left on the guest's boot partition.** Editing `cmdline.txt` for the shared folder mounts the boot partition on the Mac, and macOS marks any writable volume it mounts with an `.fseventsd` directory. The AppleDouble sidecar `._cmdline.txt` was already being removed, but only when the file changed; both are now removed on every mount, before the unmount, where the removal sticks.

## Installing from the .dmg

Requires **macOS 27 or later** on **Apple Silicon**. Download `HAOS-0.2.5.dmg` from this release, open it, and drag **HAOS** to **Applications**.

The app is ad-hoc signed, not notarized, so Gatekeeper will refuse the downloaded copy until the quarantine flag is removed:

```sh
xattr -dr com.apple.quarantine /Applications/HAOS.app
```

Then launch it once from Finder. Building from source with `make install` (see the [README](README.md)) avoids the quarantine step entirely.

---

# HAOS 0.2.4

Lets you grow the guest's disk from Settings instead of being stuck with the 48 GB it's created at.

## Added

- **Disk size in Settings.** A new *Disk* section with a popup of sizes — 32 GB to 256 GB in 16 GB steps — and a **Resize** button. Unlike the other settings, the size doesn't apply the moment the popup changes: growing a disk can't be undone, so it waits for the button. Press it while Home Assistant is stopped and the image is grown on the spot; press it while Home Assistant is running and the growth happens at the next start, which the caption under the popup says. Either way Home Assistant OS expands its data partition into the new space on its next boot, and the file on the Mac stays sparse, so a bigger disk costs nothing until the guest actually writes to it.

  A disk can be made bigger but not smaller — a raw image can't be cut down without losing the partitions at its end — so sizes below the current one are disabled in the popup, as are sizes beyond the free space on the Mac. An image you've grown by hand to a size that isn't on the list shows up as its own entry.

## Installing from the .dmg

Requires **macOS 27 or later** on **Apple Silicon**. Download `HAOS-0.2.4.dmg` from this release, open it, and drag **HAOS** to **Applications**.

The app is ad-hoc signed, not notarized, so Gatekeeper will refuse the downloaded copy until the quarantine flag is removed:

```sh
xattr -dr com.apple.quarantine /Applications/HAOS.app
```

Then launch it once from Finder. Building from source with `make install` (see the [README](README.md)) avoids the quarantine step entirely.

---

# HAOS 0.2.3

Drops the upgrade carve-out that kept an existing shared folder writable. Every install now follows the same rule: a share is read-only unless you say otherwise.

## Changed

- **Read-only is the default everywhere.** 0.2.2 shipped a one-time migration that left write access on for anyone who already had a folder picked, so a Backups share wouldn't quietly stop taking backups. With no installs old enough to need it, the special case is gone — the setting has one meaning, and the checkbox in Settings is the only thing that decides it. If you were running 0.2.2 with a folder shared read-write, turn **Read-only** off again after updating.

## Installing from the .dmg

Requires **macOS 27 or later** on **Apple Silicon**. Download `HAOS-0.2.3.dmg` from this release, open it, and drag **HAOS** to **Applications**.

The app is ad-hoc signed, not notarized, so Gatekeeper will refuse the downloaded copy until the quarantine flag is removed:

```sh
xattr -dr com.apple.quarantine /Applications/HAOS.app
```

Then launch it once from Finder. Building from source with `make install` (see the [README](README.md)) avoids the quarantine step entirely.

---

# HAOS 0.2.2

Gives the shared folder a **Read-only** setting, so a folder on the Mac can be handed to Home Assistant without Home Assistant being able to change what's in it.

## Added

- **Read-only shared folders.** A new checkbox under **Use as:** in Settings. With it on, Home Assistant sees the folder's contents but can't write to it: nothing in the guest can rewrite or delete a file on the Mac. Turn it off for the cases that need writing — backups Home Assistant creates itself, or an add-on writing into `/share`. The caption under the popup says what the current combination means, since what read-only costs depends on the folder: backups become restore-only, media still plays.

  Both halves of the share follow the setting. The virtiofs device is offered read-only, and `systemd.mount-extra=haos-shared:<directory>:virtiofs:ro,nofail` replaces the `rw` form on the guest's kernel command line. The host side is what actually enforces it; the mount option only decides what the guest asks for.

## Changed

- **New setups share read-only by default.** A folder on the Mac is yours, and write access is now something you grant rather than something a share comes with.

  **Upgrading keeps write access.** If you already have a folder picked, this release leaves it writable — it was shared read-write, in most cases with Home Assistant writing backups into it, and switching that off on upgrade would stop the backups without anyone asking for it. The checkbox is there if you want it.

## Installing from the .dmg

Requires **macOS 27 or later** on **Apple Silicon**. Download `HAOS-0.2.2.dmg` from this release, open it, and drag **HAOS** to **Applications**.

The app is ad-hoc signed, not notarized, so Gatekeeper will refuse the downloaded copy until the quarantine flag is removed:

```sh
xattr -dr com.apple.quarantine /Applications/HAOS.app
```

Then launch it once from Finder. Building from source with `make install` (see the [README](README.md)) avoids the quarantine step entirely.

---

# HAOS 0.2.1

Tidies the Settings window and rebuilds the app around one file per capability. The app does the same things it did in 0.2.0.

## Changed

- **The Settings window has proper sections.** *System* and *Shared folder* now sit under headings with a separator between them, and the shared-folder controls — labels included — dim as a group when sharing is off, the way macOS shows controls a checkbox has switched off. The window no longer resizes under the pointer when you change what the guest uses the folder as: it reserves the height of the longest caption up front.
- **The VM is assembled from features.** `VMController` builds only the bare machine — CPU count, memory, firmware, entropy, balloon — and every other capability is a `VMFeature` that owns everything it needs: the disk image (download, grow, attach), the network (the vmnet bridge), the shared folder (its settings, the guest's kernel command line, the virtiofs device and its own Settings UI), and the console display. Adding a capability is a new folder plus one line in the controller. Sources are grouped into `App/`, `Settings/`, `Support/` and `VM/Features/`, and the menu bar, console window and about panel moved out of `AppDelegate` into files of their own.
- **A first launch reads as one straight line.** Downloading the image, editing the guest's boot files and building the configuration now run in sequence on the VM's own start queue instead of a chain of nested callbacks, and every state change reaches the menu on the main queue through a single funnel.

## Fixed

- **The menu stopped updating while the app was quitting.** Quitting replaced the handler that drives the menu, so the status line froze on whatever it last said while the guest was shutting down. It now keeps reporting until the app exits.
- **A guest stuck part-way through shutdown could keep the app from quitting.** If the guest was neither running nor stopped when the 30-second grace period ran out, nothing finished the termination and the app stayed up. It now stops waiting and quits.

## Installing from the .dmg

Requires **macOS 27 or later** on **Apple Silicon**. Download `HAOS-0.2.1.dmg` from this release, open it, and drag **HAOS** to **Applications**.

The app is ad-hoc signed, not notarized, so Gatekeeper will refuse the downloaded copy until the quarantine flag is removed:

```sh
xattr -dr com.apple.quarantine /Applications/HAOS.app
```

Then launch it once from Finder. Building from source with `make install` (see the [README](README.md)) avoids the quarantine step entirely.

---

# HAOS 0.2.0

Adds a shared folder: a folder on the Mac, mounted inside the guest, so Home Assistant's backups live in the Finder instead of inside the disk image.

## Added

- **A folder shared with Home Assistant.** Off by default. Turn on **Share a folder with Home Assistant** in Settings, pick a folder, and choose what the guest should use it as — **Backups** (the default), **Media** or **Share**. With Backups selected, every backup Home Assistant writes — manual, automatic, or the one it takes before an update — lands on the Mac, where Time Machine can reach it. Deleting a backup from the Home Assistant UI deletes the file on the Mac, and vice versa.

  The folder is offered to the guest as a virtiofs share tagged `haos-shared`, and `systemd.mount-extra=haos-shared:<directory>:virtiofs:rw,nofail` is added to the guest's kernel command line, which mounts it early enough that Docker and the Supervisor see it. Nothing in Home Assistant OS mounts a virtiofs share on its own, and its root filesystem is read-only, so the kernel command line is the only durable place to ask for the mount: it lives in `cmdline.txt` on the image's FAT boot partition, which the app edits by attaching the image while the VM is stopped, and which the RAUC update hook carries across Home Assistant OS updates. `nofail` keeps a guest that boots without the share from stalling.

  The guest directory is a fixed list rather than a free path on purpose — mounting over the Home Assistant configuration would hide the running instance. Whatever the guest already keeps in the directory isn't moved or deleted; it's hidden underneath the mount and reappears if you turn sharing off.

## Installing from the .dmg

Requires **macOS 27 or later** on **Apple Silicon**. Download `HAOS-0.2.0.dmg` from this release, open it, and drag **HAOS** to **Applications**.

The app is ad-hoc signed, not notarized, so Gatekeeper will refuse the downloaded copy until the quarantine flag is removed:

```sh
xattr -dr com.apple.quarantine /Applications/HAOS.app
```

Then launch it once from Finder. Building from source with `make install` (see the [README](README.md)) avoids the quarantine step entirely.

---

# HAOS 0.1.2

Fixes the VM failing to start after a Mac restart, and ships a proper installer window in the `.dmg`.

## Fixed

- **"No physical interface with an active link" right after a reboot.** The app starts at login, which on a fresh boot happens before Wi-Fi has associated or an Ethernet link has trained — so bridged networking found nothing to attach to and the start failed with an alert waiting on the desktop. A start now waits for a usable interface instead of giving up on the first look. The wait is event-driven: it listens to configd for interface link changes and begins the moment the link comes up, so a Mac that's already online starts exactly as fast as before.

## Changed

- **The automatic start at login retries quietly.** If an attempt still fails — a transient vmnet error, or a network that's more than a minute away — the app tries again a few times instead of stopping at the first failure. Only a start you asked for from the menu reports failure in an alert; an automatic one puts the reason in the menu's status line, so a Mac you aren't sitting at no longer greets you with a modal dialog. A pending retry is cancelled if you start or shut down the VM yourself.
- **The `.dmg` has a real installer window** — the app on the left, Applications on the right, drag across. `make dmg` builds it.

## Installing from the .dmg

Requires **macOS 27 or later** on **Apple Silicon**. Download `HAOS-0.1.2.dmg` from this release, open it, and drag **HAOS** to **Applications**.

The app is ad-hoc signed, not notarized, so Gatekeeper will refuse the downloaded copy until the quarantine flag is removed:

```sh
xattr -dr com.apple.quarantine /Applications/HAOS.app
```

Then launch it once from Finder. Building from source with `make install` (see the [README](README.md)) avoids the quarantine step entirely.

---

# HAOS 0.1.1

Fixes bridged networking on Macs whose built-in Ethernet port has no cable plugged in, and adds a downloadable `.dmg`.

## Fixed

- **Bridge interface auto-selection ignored link state.** vmnet lists a built-in Ethernet port even with nothing plugged into it, and the wired-over-Wi-Fi preference would bridge the guest onto that dead port — the VM started fine but never got a DHCP lease. On a Mac mini running on Wi-Fi this made networking silently fail. Auto-selection now only considers interfaces whose link is actually up, so a Wi-Fi-only machine bridges onto Wi-Fi, and plugging in an Ethernet cable makes the wired port win again on the next VM start.

## Installing from the .dmg

Requires **macOS 27 or later** on **Apple Silicon**. Download `HAOS-0.1.1.dmg` from this release, open it, and drag **HAOS** to **Applications**.

The app is ad-hoc signed, not notarized, so Gatekeeper will refuse the downloaded copy until the quarantine flag is removed:

```sh
xattr -dr com.apple.quarantine /Applications/HAOS.app
```

Then launch it once from Finder. Building from source with `make install` (see the [README](README.md)) avoids the quarantine step entirely.

---

# HAOS 0.1.0

First release. HAOS is a macOS menu bar app that runs [Home Assistant OS](https://www.home-assistant.io/) in a virtual machine, bridged onto your local network. No Dock icon, no window to keep open — a house icon in the menu bar, and the VM starts at login.

## Highlights

- **Zero-setup first run.** On first launch the app fetches the latest `haos_generic-aarch64` release from GitHub, unpacks the `.img.xz` in-process, and boots it. Nothing to download or convert by hand.
- **Real presence on your LAN.** The guest is bridged onto your physical network with `vmnet.framework`, in-process — no privileged helper. It gets an address from your router's DHCP and joins multicast, which is what mDNS, SSDP and Matter discovery need to find your devices. The vmnet interface ID is persisted, so the guest keeps the same MAC and DHCP lease across restarts.
- **Menu bar control.** Start, shut down, open the guest console, or jump to the web UI at `homeassistant.local:8123`. The icon is a filled house while running and a dimmed outline otherwise.
- **Clean shutdown.** Quitting sends an ACPI power-button event and waits up to 30 seconds for Home Assistant to power off properly before forcing it.
- **Stays awake.** While the VM runs, the app holds a power assertion so an idle host doesn't freeze the guest and drop your automations.
- **Adjustable resources.** CPU cores and memory are set in Settings, clamped to what the host allows; changes apply on the next start.

## Installing

Requires **macOS 27 or later** on **Apple Silicon**.

```sh
git clone https://github.com/LeonidEmelianov/HAOS.git
cd HAOS
make install
```

This builds a Release configuration, ad-hoc signs it (no Apple Developer account needed), installs it to `/Applications`, and launches it. First launch asks for local network access and a one-time bridged-networking authorization.

See the [README](README.md) for the full build and usage details.

## Known limitations

- **macOS 27 minimum.** Bridged `vmnet` without a privileged helper relies on entitlement behavior introduced in recent macOS; the deployment target is 27 and there is no fallback for older systems.
- **No USB passthrough.** Zigbee, Z-Wave and Matter USB sticks can't be handed to the guest. Use a network-attached coordinator (a Zigbee/Z-Wave-to-Ethernet bridge, or SkyConnect over a USB-to-IP server) instead. Network-based integrations work normally.
- **Bridged networking only.** No NAT/shared-networking fallback; if no interface is available to bridge, the VM won't start.
- **One VM, one image.** No snapshots, multiple instances or UTM import. Home Assistant updates itself from inside the guest, as usual.
- **Apple Silicon only.** The app boots the `aarch64` build of Home Assistant OS.

## Notes

- Guest disk image: `~/Library/HAOS/HAOS.img` (48 GiB virtual, sparse on APFS).
- VM state (machine identity, EFI store, vmnet interface ID): `~/Library/Application Support/HAOS/`.

Home Assistant and Home Assistant OS are projects of the [Open Home Foundation](https://www.openhomefoundation.org/); this app downloads and boots their published images and is not affiliated with them.
