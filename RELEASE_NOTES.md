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
